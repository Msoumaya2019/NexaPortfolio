import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct TradeRepublicSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var marketData: MarketDataStore

    @Query(sort: \Portfolio.createdAt) private var portfolios: [Portfolio]
    @Query(sort: \WatchlistItem.symbol) private var watchlistItems: [WatchlistItem]

    @AppStorage("traderepublic.portfolioID") private var selectedPortfolioID = ""
    @AppStorage("traderepublic.lastImportTimestamp") private var lastImportTimestamp = 0.0

    @State private var showingFileImporter = false
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var selectedPortfolio: Portfolio? {
        portfolios.first { $0.id.uuidString == selectedPortfolioID }
    }

    private var lastImportDate: Date? {
        lastImportTimestamp > 0 ? Date(timeIntervalSince1970: lastImportTimestamp) : nil
    }

    var body: some View {
        Form {
            Section("Import Trade Republic") {
                Label("Lecture locale des PDF officiels", systemImage: "lock.shield.fill")
                    .foregroundStyle(AppTheme.positive)
                Text("Trade Republic ne propose pas d’API publique pour le portefeuille. Nexa Portfolio lit uniquement le document que tu sélectionnes et ne demande jamais ton numéro, ton PIN ou ton code 2FA.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)

                Link(
                    "Consulter l’aide officielle Trade Republic",
                    destination: URL(string: "https://support.traderepublic.com/fr-fr/845")!
                )
            }

            Section("Destination") {
                if portfolios.isEmpty {
                    Text("Crée un portefeuille avant d’importer.")
                        .foregroundStyle(AppTheme.secondaryText)
                } else {
                    Picker("Portefeuille", selection: $selectedPortfolioID) {
                        ForEach(portfolios) { portfolio in
                            Text(portfolio.name).tag(portfolio.id.uuidString)
                        }
                    }
                }

                Button {
                    createDedicatedPortfolio()
                } label: {
                    Label("Créer un portefeuille Trade Republic", systemImage: "plus.rectangle.on.folder")
                }

                if selectedPortfolio?.transactions.contains(where: { $0.externalSource != "traderepublic:pdf" }) == true {
                    Label(
                        "Ce portefeuille contient déjà d’autres opérations. Un portefeuille Trade Republic séparé évite les doubles saisies.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }

            Section("Document à télécharger") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Profil > transaction > Documents", systemImage: "doc.text.magnifyingglass")
                    Text("Télécharge la confirmation d’exécution de l’achat ou de la vente, ou le relevé du dividende. N’utilise pas le document d’information préalable sur les coûts.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }

            Section("Import") {
                Button {
                    showingFileImporter = true
                } label: {
                    Label("Choisir un PDF Trade Republic", systemImage: "doc.badge.plus")
                }
                .disabled(isWorking || selectedPortfolio == nil)

                Text("Sélectionne un ou plusieurs PDF, puis appuie sur « Ouvrir ». Les doublons sont reconnus automatiquement.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)

                if let lastImportDate {
                    LabeledContent(
                        "Dernier import",
                        value: lastImportDate.formatted(date: .abbreviated, time: .shortened)
                    )
                }

                if let statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.positive)
                }
            }

            Section {
                Text("Seuls l’ISIN et le symbole du titre sont utilisés pour actualiser ensuite le cours. Le contenu du PDF et tes informations personnelles restent sur l’iPhone.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .navigationTitle("Trade Republic")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .overlay {
            if isWorking {
                ProgressView("Import Trade Republic…")
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task {
            if selectedPortfolio == nil {
                selectedPortfolioID = portfolios.first?.id.uuidString ?? ""
            }
        }
        .sheet(isPresented: $showingFileImporter) {
            LocalDocumentPicker(
                contentTypes: [.item],
                allowsMultipleSelection: true,
                onSelection: receiveDocuments,
                onCancel: { showingFileImporter = false }
            )
            .ignoresSafeArea()
        }
        .alert("Import Trade Republic impossible", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func createDedicatedPortfolio() {
        let portfolio = Portfolio(name: "Trade Republic", currencyCode: "EUR")
        modelContext.insert(portfolio)
        do {
            try modelContext.save()
            selectedPortfolioID = portfolio.id.uuidString
            statusMessage = "Portefeuille Trade Republic créé."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func receiveDocuments(_ urls: [URL]) {
        do {
            let stagedDocuments = try LocalDocumentStager.stage(urls)
            showingFileImporter = false
            Task {
                defer { LocalDocumentStager.remove(stagedDocuments) }
                await importDocuments(stagedDocuments.urls)
            }
        } catch {
            showingFileImporter = false
            errorMessage = "Le fichier sélectionné n’a pas pu être copié dans l’application : \(error.localizedDescription)"
        }
    }

    private func importDocuments(_ urls: [URL]) async {
        guard let portfolio = selectedPortfolio else { return }
        isWorking = true
        statusMessage = nil
        defer { isWorking = false }

        do {
            let summary = try await TradeRepublicPDFImporter.importDocuments(
                at: urls,
                into: portfolio,
                context: modelContext
            )
            lastImportTimestamp = Date.now.timeIntervalSince1970
            let ignored = summary.ignoredDocuments > 0
                ? " · \(summary.ignoredDocuments) document non compatible"
                : ""
            statusMessage = "\(summary.importedTrades) achat/vente et \(summary.importedDividends) dividende ajouté · \(summary.skippedDuplicates) doublon ignoré\(ignored)."
            await marketData.refresh(
                holdings: portfolios.flatMap(\.holdings),
                watchlistItems: watchlistItems,
                context: modelContext
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
