import SwiftUI

struct SecuritySearchView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var marketData: MarketDataStore

    let onSelect: (SymbolSearchResult) -> Void

    @State private var query = ""
    @State private var results: [SymbolSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.background.ignoresSafeArea()

                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "Rechercher un actif",
                        message: "Saisis un symbole ou un nom : AAPL, Air Liquide, Bitcoin…"
                    )
                } else if isSearching && results.isEmpty {
                    ProgressView("Recherche…")
                } else if results.isEmpty {
                    EmptyStateView(
                        icon: "questionmark.circle",
                        title: "Aucun résultat",
                        message: "Essaie le symbole exact ou un autre nom."
                    )
                } else {
                    List(results) { result in
                        Button {
                            onSelect(result)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                SymbolBadge(symbol: result.symbol)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(result.symbol)
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                    Text(result.displayName)
                                        .font(.subheadline)
                                        .foregroundStyle(AppTheme.secondaryText)
                                        .lineLimit(1)
                                    Text("\(result.exchange) · \(result.assetType)")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.secondaryText)
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(AppTheme.accent)
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(AppTheme.card)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Ajouter un titre")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Symbole ou entreprise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .task(id: query) {
                let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else {
                    results = []
                    return
                }

                isSearching = true
                errorMessage = nil
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    results = try await marketData.search(normalized)
                } catch is CancellationError {
                    return
                } catch {
                    errorMessage = error.localizedDescription
                    results = []
                }
                isSearching = false
            }
            .alert("Recherche impossible", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}
