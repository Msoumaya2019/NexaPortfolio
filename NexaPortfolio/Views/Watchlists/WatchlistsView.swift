import SwiftUI
import SwiftData

struct WatchlistsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var marketData: MarketDataStore

    @Query(sort: \Watchlist.createdAt) private var watchlists: [Watchlist]
    @Query(sort: \Holding.symbol) private var holdings: [Holding]
    @Query(sort: \Portfolio.createdAt) private var portfolios: [Portfolio]

    @AppStorage("aggregateCurrencyCode") private var aggregateCurrencyCode = "EUR"

    @State private var selectedWatchlistID: UUID?
    @State private var showingAddItem = false
    @State private var showingNewList = false
    @State private var showingDeleteConfirmation = false
    @State private var errorMessage: String?

    private var selectedWatchlist: Watchlist? {
        watchlists.first { $0.id == selectedWatchlistID } ?? watchlists.first
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            if let watchlist = selectedWatchlist {
                ScrollView {
                    LazyVStack(spacing: 18) {
                        listSelector(watchlist)

                        if watchlist.items.isEmpty {
                            EmptyStateView(
                                icon: "star",
                                title: "Liste vide",
                                message: "Ajoute autant d’actions, ETF, indices ou cryptos que tu veux."
                            )
                            .appCard()
                        } else {
                            VStack(spacing: 0) {
                                ForEach(watchlist.items.sorted { $0.symbol < $1.symbol }) { item in
                                    itemRow(item)
                                        .padding(.vertical, 10)
                                    if item.id != watchlist.items.sorted(by: { $0.symbol < $1.symbol }).last?.id {
                                        Divider().overlay(Color.white.opacity(0.06))
                                    }
                                }
                            }
                            .appCard()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 30)
                }
                .refreshable {
                    await marketData.refresh(
                        holdings: holdings,
                        watchlistItems: watchlist.items,
                        portfolios: portfolios,
                        aggregateCurrencyCode: aggregateCurrencyCode,
                        context: modelContext
                    )
                }
            } else {
                EmptyStateView(
                    icon: "star",
                    title: "Aucune liste",
                    message: "Crée une liste de suivi pour commencer."
                )
            }
        }
        .navigationTitle("Listes de suivi")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingNewList = true
                    } label: {
                        Label("Nouvelle liste", systemImage: "folder.badge.plus")
                    }

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Supprimer cette liste", systemImage: "trash")
                    }
                    .disabled(watchlists.count <= 1)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddItem = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(selectedWatchlist == nil)
                .accessibilityLabel("Ajouter à la liste")
            }
        }
        .task {
            if selectedWatchlistID == nil { selectedWatchlistID = watchlists.first?.id }
        }
        .onChange(of: watchlists.count) {
            if selectedWatchlist == nil { selectedWatchlistID = watchlists.first?.id }
        }
        .sheet(isPresented: $showingAddItem) {
            if let watchlist = selectedWatchlist {
                AddWatchlistItemSheet(watchlist: watchlist)
            }
        }
        .sheet(isPresented: $showingNewList) {
            NewWatchlistSheet { list in selectedWatchlistID = list.id }
        }
        .confirmationDialog(
            "Supprimer « \(selectedWatchlist?.name ?? "") » ?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Supprimer la liste", role: .destructive) { deleteSelectedList() }
            Button("Annuler", role: .cancel) {}
        }
        .alert("Erreur", isPresented: Binding(
            get: { errorMessage != nil || marketData.errorMessage != nil },
            set: {
                if !$0 {
                    errorMessage = nil
                    marketData.errorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                errorMessage = nil
                marketData.errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? marketData.errorMessage ?? "")
        }
    }

    private func listSelector(_ watchlist: Watchlist) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Liste active")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                Text(watchlist.name)
                    .font(.title3.weight(.bold))
            }
            Spacer()
            Menu {
                ForEach(watchlists) { list in
                    Button {
                        selectedWatchlistID = list.id
                    } label: {
                        if list.id == watchlist.id {
                            Label(list.name, systemImage: "checkmark")
                        } else {
                            Text(list.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Text("\(watchlist.items.count)")
                    Image(systemName: "chevron.up.chevron.down")
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.accent)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(AppTheme.accent.opacity(0.1), in: Capsule())
            }
        }
    }

    private func itemRow(_ item: WatchlistItem) -> some View {
        HStack(spacing: 12) {
            NavigationLink {
                SecurityDetailView(
                    symbol: item.symbol,
                    displayName: item.displayName,
                    currentPrice: item.currentPrice,
                    previousClose: item.previousClose,
                    currencyCode: item.currencyCode,
                    annualDividendPerShare: item.annualDividendPerShare,
                    dividendYieldPercent: item.dividendYieldPercent,
                    lastDividendPerShare: item.lastDividendPerShare,
                    lastDividendDate: item.lastDividendDate,
                    dividendPaymentsLastTwelveMonths: item.dividendPaymentsLastTwelveMonths
                )
            } label: {
                HStack(spacing: 12) {
                    SymbolBadge(symbol: item.symbol)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.symbol)
                            .font(.subheadline.weight(.bold))
                        Text(item.displayName)
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                        DividendBadge(yieldPercent: item.dividendYieldPercent)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(item.currentPrice > 0 ? item.currentPrice.currency(item.currencyCode) : "—")
                            .font(.subheadline.weight(.semibold))
                        if item.previousClose > 0 {
                            Text(item.dailyChangePercent / 100, format: .percent.precision(.fractionLength(2)))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(item.dailyChangePercent >= 0 ? AppTheme.positive : AppTheme.negative)
                        } else {
                            Text("Cours indisponible")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
            }
            .buttonStyle(.plain)

            Menu {
                Button("Supprimer", systemImage: "trash", role: .destructive) {
                    modelContext.delete(item)
                    try? modelContext.save()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(width: 24, height: 34)
            }
        }
    }

    private func deleteSelectedList() {
        guard watchlists.count > 1, let list = selectedWatchlist else { return }
        modelContext.delete(list)
        do {
            try modelContext.save()
            selectedWatchlistID = watchlists.first { $0.id != list.id }?.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AddWatchlistItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var marketData: MarketDataStore

    let watchlist: Watchlist

    @State private var symbol = ""
    @State private var displayName = ""
    @State private var currentPrice = ""
    @State private var currencyCode = "USD"
    @State private var showingSearch = false
    @State private var isLoadingQuote = false
    @State private var errorMessage: String?
    @State private var latestQuote: MarketQuote?

    private var canSave: Bool {
        !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Actif") {
                    Button {
                        showingSearch = true
                    } label: {
                        Label("Rechercher sur les marchés", systemImage: "magnifyingglass")
                    }
                    TextField("Symbole (ex. MC.PA)", text: $symbol)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Nom", text: $displayName)
                }

                Section("Cours initial facultatif") {
                    HStack {
                        TextField("Prix", text: $currentPrice)
                            .keyboardType(.decimalPad)
                        if isLoadingQuote { ProgressView() }
                    }
                    Picker("Devise", selection: $currencyCode) {
                        ForEach(["EUR", "USD", "GBP", "CHF", "CAD", "JPY"], id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            .navigationTitle("Ajouter à la liste")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter") { save() }
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showingSearch) {
                SecuritySearchView { result in
                    symbol = result.symbol
                    displayName = result.displayName
                    loadQuote(result.symbol)
                }
            }
            .alert("Ajout impossible", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func loadQuote(_ symbol: String) {
        isLoadingQuote = true
        Task {
            do {
                let quote = try await marketData.quote(for: symbol)
                latestQuote = quote
                currentPrice = quote.price.formatted(.number.precision(.fractionLength(2...6)))
                currencyCode = quote.currencyCode
                if displayName.isEmpty { displayName = quote.displayName }
            } catch {
                errorMessage = "Cours indisponible. Tu peux tout de même saisir le prix manuellement."
            }
            isLoadingQuote = false
        }
    }

    private func save() {
        let normalized = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !watchlist.items.contains(where: { $0.symbol == normalized }) else {
            errorMessage = "Ce symbole figure déjà dans cette liste."
            return
        }

        let price = Double(currentPrice.replacingOccurrences(of: ",", with: ".")) ?? 0
        let item = WatchlistItem(
            symbol: normalized,
            displayName: displayName.isEmpty ? normalized : displayName,
            currentPrice: price,
            previousClose: latestQuote?.previousClose ?? price,
            currencyCode: currencyCode,
            annualDividendPerShare: latestQuote?.annualDividendPerShare ?? 0,
            dividendYieldPercent: latestQuote?.dividendYieldPercent ?? 0,
            lastDividendPerShare: latestQuote?.lastDividendPerShare ?? 0,
            lastDividendDate: latestQuote?.lastDividendDate,
            dividendPaymentsLastTwelveMonths: latestQuote?.dividendPaymentsLastTwelveMonths ?? 0,
            watchlist: watchlist
        )
        item.lastUpdated = latestQuote?.timestamp
        modelContext.insert(item)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct NewWatchlistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let onCreate: (Watchlist) -> Void
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nom de la liste", text: $name)
            }
            .navigationTitle("Nouvelle liste")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func create() {
        let list = Watchlist(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        modelContext.insert(list)
        try? modelContext.save()
        onCreate(list)
        dismiss()
    }
}
