import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct RevolutSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var marketData: MarketDataStore

    @Query(sort: \Portfolio.createdAt) private var portfolios: [Portfolio]
    @Query(sort: \WatchlistItem.symbol) private var watchlistItems: [WatchlistItem]

    @AppStorage("revolut.portfolioID") private var selectedPortfolioID = ""
    @AppStorage("revolut.lastImportTimestamp") private var lastImportTimestamp = 0.0

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
            Section("Import Revolut") {
                Label("Lecture locale du CSV d’investissements", systemImage: "lock.shield.fill")
                    .foregroundStyle(AppTheme.positive)
                Text("Nexa lit uniquement le fichier que tu sélectionnes. Aucun numéro de téléphone, PIN, code 2FA ou jeton de session Revolut n’est demandé.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)

                Link(
                    "Consulter l’aide officielle Revolut",
                    destination: URL(string: "https://help.revolut.com/fr-FR/help/wealth/stocks/getting-started-with-trading/managing-your-trading-account/trading-statements/accessing-my-trading-statements-and-reports/")!
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
                    Label("Créer un portefeuille Revolut", systemImage: "plus.rectangle.on.folder")
                }

                if selectedPortfolio?.transactions.contains(where: {
                    $0.externalSource != "revolut:csv"
                }) == true {
                    Label(
                        "Ce portefeuille contient déjà d’autres opérations. Un portefeuille Revolut séparé évite les doubles saisies.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }

            Section("Export à télécharger") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Revolut > Investir > Plus > Documents", systemImage: "doc.text.magnifyingglass")
                    Text("Exporte l’historique d’investissements au format CSV sur la période la plus large possible. Le fichier doit contenir Date, Ticker, Type, Quantity, Price per share et Total Amount.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }

            Section("Import") {
                Button {
                    showingFileImporter = true
                } label: {
                    Label("Choisir un CSV Revolut", systemImage: "doc.badge.plus")
                }
                .disabled(isWorking || selectedPortfolio == nil)

                Text("Sélectionne un ou plusieurs exports, puis appuie sur « Ouvrir ». Les achats, ventes, dividendes, corrections fiscales, splits et fusions de titres sont traités sans doublons.")
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
                Text("Les dépôts, retraits, récompenses, frais de garde et mouvements internes sans titre sont ignorés. Les ajustements de titres à prix nul préservent le coût total de la position lorsque cela est possible.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .navigationTitle("Revolut")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .overlay {
            if isWorking {
                ProgressView("Import Revolut…")
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
        .alert("Import Revolut impossible", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func createDedicatedPortfolio() {
        let portfolio = Portfolio(name: "Revolut", currencyCode: "EUR")
        modelContext.insert(portfolio)
        do {
            try modelContext.save()
            selectedPortfolioID = portfolio.id.uuidString
            statusMessage = "Portefeuille Revolut créé."
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
            let summary = try await RevolutCSVImporter.importDocuments(
                at: urls,
                into: portfolio,
                context: modelContext
            )
            lastImportTimestamp = Date.now.timeIntervalSince1970
            statusMessage = "\(summary.importedTrades) achats/ventes, \(summary.importedDividends) dividendes et \(summary.importedCorporateActions) ajustements ajoutés · \(summary.skippedDuplicates) doublons et \(summary.ignoredRows) lignes ignorées."
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
