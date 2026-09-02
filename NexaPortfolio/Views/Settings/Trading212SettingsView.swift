import SwiftUI
import SwiftData

struct Trading212SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var marketData: MarketDataStore

    @Query(sort: \Portfolio.createdAt) private var portfolios: [Portfolio]
    @Query(sort: \WatchlistItem.symbol) private var watchlistItems: [WatchlistItem]

    @AppStorage("trading212.environment") private var environmentRawValue = Trading212Environment.demo.rawValue
    @AppStorage("trading212.autoSync") private var autoSync = true

    @State private var selectedPortfolioID = ""
    @State private var lastSyncTimestamp = 0.0
    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var hasStoredCredentials = false
    @State private var accountSummary: Trading212AccountSummary?
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showingDisconnectConfirmation = false
    @State private var showingManualDataWarning = false

    private var environment: Trading212Environment {
        Trading212Environment(rawValue: environmentRawValue) ?? .demo
    }

    private var environmentSelection: Binding<Trading212Environment> {
        Binding(
            get: { environment },
            set: { environmentRawValue = $0.rawValue }
        )
    }

    private var selectedPortfolio: Portfolio? {
        portfolios.first { $0.id.uuidString == selectedPortfolioID }
    }

    private var selectedPortfolioContainsManualTransactions: Bool {
        selectedPortfolio?.transactions.contains { $0.externalSource == nil } == true
    }

    private var lastSyncDate: Date? {
        lastSyncTimestamp > 0 ? Date(timeIntervalSince1970: lastSyncTimestamp) : nil
    }

    var body: some View {
        Form {
            Section("Environnement") {
                Picker("Compte Trading 212", selection: environmentSelection) {
                    ForEach(Trading212Environment.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                Text(environment == .demo
                     ? "Utilise d’abord le compte Démo pour vérifier la connexion sans toucher au compte réel."
                     : "La connexion réelle reste strictement en lecture seule dans Nexa Portfolio.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Section("Clés API") {
                if hasStoredCredentials {
                    Label("Identifiants enregistrés dans le trousseau iOS", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(AppTheme.positive)
                }

                TextField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Secret", text: $apiSecret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    Task { await saveAndTestCredentials() }
                } label: {
                    actionLabel("Enregistrer et tester", systemImage: "key.fill")
                }
                .disabled(isWorking || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiSecret.isEmpty)

                if hasStoredCredentials {
                    Button {
                        Task { await testStoredCredentials() }
                    } label: {
                        actionLabel("Tester la connexion enregistrée", systemImage: "network")
                    }
                    .disabled(isWorking)
                }

                Text("Dans Trading 212, crée une clé avec uniquement les autorisations de lecture du compte, du portefeuille et de l’historique. N’active pas le passage d’ordres.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)

                Link(
                    "Ouvrir l’aide officielle Trading 212",
                    destination: URL(string: "https://helpcentre.trading212.com/hc/en-us/articles/14584770928157-Trading-212-API-key")!
                )
            }

            if let accountSummary {
                Section("Compte détecté") {
                    LabeledContent("Numéro", value: String(accountSummary.id))
                    LabeledContent("Devise", value: accountSummary.currency)
                    LabeledContent("Valeur totale", value: (accountSummary.totalValue ?? 0).currency(accountSummary.currency))
                }
            }

            Section("Destination") {
                if portfolios.isEmpty {
                    Text("Crée un portefeuille avant de synchroniser.")
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
                    Label("Créer un portefeuille Trading 212", systemImage: "plus.rectangle.on.folder")
                }

                if selectedPortfolioContainsManualTransactions {
                    Label(
                        "Ce portefeuille contient déjà des opérations manuelles. Elles seront conservées et peuvent doubler des opérations déjà saisies.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }

            Section("Synchronisation") {
                Toggle("Synchroniser automatiquement", isOn: $autoSync)

                Button {
                    beginSynchronization()
                } label: {
                    actionLabel("Synchroniser maintenant", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isWorking || !hasStoredCredentials || selectedPortfolio == nil)

                if let lastSyncDate {
                    LabeledContent(
                        "Dernière synchronisation",
                        value: lastSyncDate.formatted(date: .abbreviated, time: .shortened)
                    )
                }

                if let statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.positive)
                }

                Text("Lorsque l’option automatique est active, l’application vérifie le compte au lancement puis au retour dans l’application, au maximum une fois toutes les 15 minutes. Les éléments déjà importés sont reconnus par leur identifiant Trading 212 et ne sont pas ajoutés deux fois.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            if hasStoredCredentials {
                Section {
                    Button("Déconnecter ce compte", systemImage: "link.badge.minus", role: .destructive) {
                        showingDisconnectConfirmation = true
                    }
                } footer: {
                    Text("La déconnexion efface uniquement les clés du trousseau. Les opérations déjà importées restent dans le portefeuille.")
                }
            }
        }
        .navigationTitle("Trading 212")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .overlay {
            if isWorking {
                ProgressView("Synchronisation Trading 212…\nDurée maximale : 90 secondes")
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task { refreshStoredState() }
        .onChange(of: environmentRawValue) { _, _ in
            accountSummary = nil
            statusMessage = nil
            apiKey = ""
            apiSecret = ""
            refreshStoredState()
        }
        .onChange(of: selectedPortfolioID) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: portfolioPreferenceKey)
        }
        .alert("Connexion impossible", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Déconnecter Trading 212 ?", isPresented: $showingDisconnectConfirmation) {
            Button("Annuler", role: .cancel) {}
            Button("Déconnecter", role: .destructive) { disconnect() }
        } message: {
            Text("Les clés du compte \(environment.title) seront supprimées du trousseau iOS.")
        }
        .confirmationDialog(
            "Ce portefeuille contient des opérations manuelles",
            isPresented: $showingManualDataWarning,
            titleVisibility: .visible
        ) {
            Button("Synchroniser et conserver les opérations") {
                Task { await synchronize() }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Si les mêmes achats ont été saisis manuellement, ils apparaîtront en double. Un portefeuille Trading 212 séparé est recommandé.")
        }
    }

    @ViewBuilder
    private func actionLabel(_ title: String, systemImage: String) -> some View {
        if isWorking {
            HStack {
                ProgressView()
                Text(title)
            }
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    private func refreshStoredState() {
        do {
            hasStoredCredentials = try Trading212Keychain.load(for: environment) != nil
            selectedPortfolioID = UserDefaults.standard.string(forKey: portfolioPreferenceKey) ?? ""
            lastSyncTimestamp = UserDefaults.standard.double(forKey: lastSyncPreferenceKey)
            if selectedPortfolio == nil {
                selectedPortfolioID = portfolios.first?.id.uuidString ?? ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveAndTestCredentials() async {
        let credentials = Trading212Credentials(
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            apiSecret: apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        isWorking = true
        defer { isWorking = false }
        do {
            try Trading212Keychain.save(credentials, for: environment)
            let summary = try await Trading212Client(
                environment: environment,
                credentials: credentials
            ).accountSummary()
            accountSummary = summary
            hasStoredCredentials = true
            apiKey = ""
            apiSecret = ""
            statusMessage = "Connexion réussie au compte \(summary.id)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func testStoredCredentials() async {
        isWorking = true
        defer { isWorking = false }
        do {
            guard let credentials = try Trading212Keychain.load(for: environment) else {
                throw Trading212Error.noCredentials
            }
            let summary = try await Trading212Client(
                environment: environment,
                credentials: credentials
            ).accountSummary()
            accountSummary = summary
            statusMessage = "Connexion réussie au compte \(summary.id)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createDedicatedPortfolio() {
        let portfolio = Portfolio(
            name: environment == .demo ? "Trading 212 Démo" : "Trading 212",
            currencyCode: accountSummary?.currency ?? "EUR"
        )
        modelContext.insert(portfolio)
        do {
            try modelContext.save()
            selectedPortfolioID = portfolio.id.uuidString
            statusMessage = "Portefeuille \(portfolio.name) créé."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginSynchronization() {
        if selectedPortfolioContainsManualTransactions {
            showingManualDataWarning = true
        } else {
            Task { await synchronize() }
        }
    }

    private func synchronize() async {
        guard let portfolio = selectedPortfolio else { return }
        guard await Trading212SyncGate.shared.acquire() else {
            errorMessage = Trading212Error.synchronizationAlreadyRunning.localizedDescription
            return
        }
        isWorking = true
        statusMessage = nil
        defer { isWorking = false }
        do {
            guard let credentials = try Trading212Keychain.load(for: environment) else {
                throw Trading212Error.noCredentials
            }
            let snapshot = try await Trading212Client(
                environment: environment,
                credentials: credentials
            ).snapshot(since: lastSyncDate)
            let result = try await Trading212Importer.synchronize(
                snapshot: snapshot,
                environment: environment,
                into: portfolio,
                context: modelContext
            )
            accountSummary = snapshot.account
            lastSyncTimestamp = Date.now.timeIntervalSince1970
            UserDefaults.standard.set(lastSyncTimestamp, forKey: lastSyncPreferenceKey)
            let historyWarning = snapshot.historyWasTruncated
                ? " · historique initial limité aux 300 éléments les plus récents"
                : ""
            statusMessage = "\(result.importedOrders) achats/ventes et \(result.importedDividends) dividendes ajoutés · \(result.skippedDuplicates) doublons ignorés · \(result.reconciledPositions) positions vérifiées\(historyWarning)."
            await marketData.refresh(
                holdings: portfolios.flatMap(\.holdings),
                watchlistItems: watchlistItems,
                context: modelContext
            )
            await Trading212SyncGate.shared.release()
        } catch {
            await Trading212SyncGate.shared.release()
            errorMessage = error.localizedDescription
        }
    }

    private func disconnect() {
        do {
            try Trading212Keychain.delete(for: environment)
            hasStoredCredentials = false
            accountSummary = nil
            statusMessage = "Compte déconnecté."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var portfolioPreferenceKey: String {
        "trading212.portfolioID.\(environment.rawValue)"
    }

    private var lastSyncPreferenceKey: String {
        "trading212.lastSyncTimestamp.\(environment.rawValue)"
    }
}
