import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct DegiroSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var marketData: MarketDataStore

    @Query(sort: \Portfolio.createdAt) private var portfolios: [Portfolio]
    @Query(sort: \WatchlistItem.symbol) private var watchlistItems: [WatchlistItem]

    @AppStorage("degiro.portfolioID") private var selectedPortfolioID = ""
    @AppStorage("degiro.lastImportTimestamp") private var lastImportTimestamp = 0.0

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
            Section("Connexion DEGIRO") {
                Label("Import local sans mot de passe", systemImage: "lock.shield.fill")
                    .foregroundStyle(AppTheme.positive)

                Text("DEGIRO ne fournit pas d’API officielle et n’autorise pas les connecteurs non officiels. Nexa Portfolio utilise donc les relevés CSV exportés par toi depuis DEGIRO.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)

                Link(
                    "Consulter l’aide officielle DEGIRO",
                    destination: URL(string: "https://www.degiro.fr/helpdesk/fiscalite/quels-types-de-rapports-sont-disponibles-et-ou-puis-je-les-trouver")!
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
                    Label("Créer un portefeuille DEGIRO", systemImage: "plus.rectangle.on.folder")
                }

                if selectedPortfolio?.transactions.contains(where: { $0.externalSource != "degiro:csv" }) == true {
                    Label(
                        "Ce portefeuille contient déjà d’autres opérations. Utilise de préférence un portefeuille DEGIRO séparé pour éviter les doubles saisies.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }

            Section("Fichiers à exporter") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Courriel > Transactions > Exporter en CSV", systemImage: "1.circle.fill")
                    Text("Importe les achats et les ventes. Sélectionne la période la plus large possible lors du premier import.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Courriel > Compte > Exporter en CSV", systemImage: "2.circle.fill")
                    Text("Importe les dividendes versés. Les retenues fiscales sont volontairement ignorées.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }

            Section("Import") {
                Button {
                    showingFileImporter = true
                } label: {
                    Label("Choisir les fichiers CSV DEGIRO", systemImage: "doc.badge.plus")
                }
                .disabled(isWorking || selectedPortfolio == nil)

                Text("Tu peux sélectionner les deux relevés en une seule fois. Les opérations déjà importées sont reconnues automatiquement et ne sont pas ajoutées deux fois.")
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
                Text("L’import est en lecture seule : Nexa Portfolio lit uniquement les fichiers que tu sélectionnes. Il ne se connecte jamais au site DEGIRO et ne peut passer aucun ordre.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .navigationTitle("DEGIRO")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .overlay {
            if isWorking {
                ProgressView("Import DEGIRO…")
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task {
            if selectedPortfolio == nil {
                selectedPortfolioID = portfolios.first?.id.uuidString ?? ""
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                Task { await importDocuments(urls) }
            case let .failure(error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("Import DEGIRO impossible", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func createDedicatedPortfolio() {
        let portfolio = Portfolio(name: "DEGIRO", currencyCode: "EUR")
        modelContext.insert(portfolio)
        do {
            try modelContext.save()
            selectedPortfolioID = portfolio.id.uuidString
            statusMessage = "Portefeuille DEGIRO créé."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importDocuments(_ urls: [URL]) async {
        guard let portfolio = selectedPortfolio else { return }
        isWorking = true
        statusMessage = nil
        defer { isWorking = false }

        do {
            let summary = try await DegiroCSVImporter.importDocuments(
                at: urls,
                into: portfolio,
                context: modelContext
            )
            lastImportTimestamp = Date.now.timeIntervalSince1970
            statusMessage = "\(summary.importedTrades) achats/ventes et \(summary.importedDividends) dividendes ajoutés · \(summary.skippedDuplicates) doublons ignorés."
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
