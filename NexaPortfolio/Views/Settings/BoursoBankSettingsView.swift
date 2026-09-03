import SwiftData
import SwiftUI

struct BoursoBankSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var marketData: MarketDataStore

    @Query(sort: \Portfolio.createdAt) private var portfolios: [Portfolio]
    @Query(sort: \WatchlistItem.symbol) private var watchlistItems: [WatchlistItem]

    @AppStorage("boursobank.autoSync") private var autoSync = true
    @State private var customerID = ""
    @State private var password = ""
    @State private var rememberCustomerID = true
    @State private var client: BoursoBankClient?
    @State private var challenge: BoursoBankMFAChallenge?
    @State private var tradingAccounts: [BoursoBankTradingAccount] = []
    @State private var selectedAccountID = ""
    @State private var selectedPortfolioID = ""
    @State private var isConnected = false
    @State private var isWorking = false
    @State private var workingMessage = "Connexion à BoursoBank…"
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showingDisconnectConfirmation = false

    private var selectedAccount: BoursoBankTradingAccount? {
        tradingAccounts.first { $0.id == selectedAccountID }
    }

    private var selectedPortfolio: Portfolio? {
        portfolios.first { $0.id.uuidString == selectedPortfolioID }
    }

    private var lastSyncDate: Date? {
        let timestamp = UserDefaults.standard.double(forKey: lastSyncPreferenceKey)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    var body: some View {
        Form {
            Section("Connexion non officielle") {
                Label("Lecture seule dans Nexa Portfolio", systemImage: "lock.shield.fill")
                    .foregroundStyle(AppTheme.positive)

                Text("Cette connexion utilise les interfaces privées du site BoursoBank. Elle peut cesser de fonctionner si la banque les modifie. Nexa n’intègre aucune fonction d’achat, de vente ou de virement.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)

                Link(
                    "Voir le projet open source utilisé comme référence",
                    destination: URL(string: "https://github.com/azerpas/bourso-api")!
                )
            }

            Section("Authentification") {
                if isConnected {
                    Label("Session BoursoBank active", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.positive)
                } else {
                    TextField("Identifiant client", text: $customerID)
                        .keyboardType(.numberPad)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Mot de passe", text: $password)
                        .keyboardType(.numberPad)
                        .textContentType(.password)

                    Toggle("Mémoriser uniquement l’identifiant", isOn: $rememberCustomerID)

                    Button {
                        Task { await connect() }
                    } label: {
                        Label("Se connecter", systemImage: "person.badge.key.fill")
                    }
                    .disabled(
                        customerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || password.isEmpty
                    )
                }

                Text("Le mot de passe n’est jamais enregistré. Après la connexion, seuls les cookies de session sont conservés dans le Trousseau iOS, uniquement sur cet appareil et uniquement lorsque l’iPhone est déverrouillé.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            if challenge != nil {
                Section("Validation forte") {
                    Label("Ouvre l’application BoursoBank et valide la connexion.", systemImage: "iphone.gen3.radiowaves.left.and.right")

                    Button {
                        Task { await verifyMFA() }
                    } label: {
                        Label("J’ai validé dans BoursoBank", systemImage: "checkmark.shield.fill")
                    }

                    Text("Si la demande n’apparaît pas immédiatement, attends quelques secondes puis appuie de nouveau sur ce bouton.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }

            if !tradingAccounts.isEmpty {
                Section("Compte à synchroniser") {
                    Picker("PEA ou compte-titres", selection: $selectedAccountID) {
                        ForEach(tradingAccounts) { account in
                            Text(account.name).tag(account.id)
                        }
                    }

                    if let selectedAccount {
                        LabeledContent("Solde affiché", value: selectedAccount.displayedBalance.currency("EUR"))
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
                        Label("Créer un portefeuille BoursoBank", systemImage: "plus.rectangle.on.folder")
                    }

                    Text("Un portefeuille séparé est recommandé. La synchronisation remplace uniquement les positions précédemment créées par ce même compte BoursoBank ; tes positions manuelles restent intactes.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Section("Synchronisation") {
                    Toggle("Synchronisation silencieuse", isOn: $autoSync)

                    Button {
                        Task { await synchronize() }
                    } label: {
                        Label("Synchroniser maintenant", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!isConnected || selectedAccount == nil || selectedPortfolio == nil)

                    if let lastSyncDate {
                        LabeledContent(
                            "Dernière synchronisation",
                            value: lastSyncDate.formatted(date: .abbreviated, time: .shortened)
                        )
                    }

                    Text("La synchronisation silencieuse s’exécute au lancement et à chaque retour dans l’application, au maximum une fois toutes les 15 minutes. iOS et BoursoBank peuvent interrompre ce fonctionnement : une nouvelle validation sera demandée si la session bancaire expire.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }

            if let statusMessage {
                Section {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.positive)
                }
            }

            if client != nil || isConnected {
                Section {
                    Button("Déconnecter BoursoBank", systemImage: "link.badge.minus", role: .destructive) {
                        showingDisconnectConfirmation = true
                    }
                } footer: {
                    Text("La déconnexion détruit la session conservée dans le Trousseau. Les positions déjà synchronisées restent dans le portefeuille.")
                }
            }
        }
        .navigationTitle("BoursoBank")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .overlay {
            if isWorking {
                ProgressView(workingMessage)
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task { await restoreStoredSession() }
        .onChange(of: selectedAccountID) { _, _ in
            loadPortfolioPreference()
            statusMessage = nil
        }
        .onChange(of: selectedPortfolioID) { _, newValue in
            guard !selectedAccountID.isEmpty else { return }
            UserDefaults.standard.set(newValue, forKey: portfolioPreferenceKey)
            UserDefaults.standard.set(newValue, forKey: "boursobank.lastPortfolioID")
        }
        .alert("Connexion BoursoBank", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Déconnecter BoursoBank ?", isPresented: $showingDisconnectConfirmation) {
            Button("Annuler", role: .cancel) {}
            Button("Déconnecter", role: .destructive) {
                Task { await disconnect() }
            }
        } message: {
            Text("La session et l’identifiant client mémorisé seront supprimés du Trousseau iOS.")
        }
    }

    @MainActor
    private func restoreStoredSession() async {
        do {
            customerID = try BoursoBankCustomerIDKeychain.load() ?? ""
            guard let storedSession = try BoursoBankSessionKeychain.load() else { return }
            workingMessage = "Restauration de la session BoursoBank…"
            isWorking = true
            defer { isWorking = false }
            let restoredClient = BoursoBankClient(storedSession: storedSession)
            let accounts = try await restoredClient.tradingAccounts()
            client = restoredClient
            tradingAccounts = accounts
            isConnected = true
            challenge = nil
            selectInitialAccount()
            statusMessage = "Session restaurée. La synchronisation silencieuse est disponible."
        } catch let error as BoursoBankError {
            if case .sessionExpired = error {
                isConnected = false
                client = nil
                tradingAccounts = []
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func connect() async {
        isWorking = true
        workingMessage = "Connexion sécurisée à BoursoBank…"
        statusMessage = nil
        defer {
            password = ""
            isWorking = false
        }

        do {
            let normalizedCustomerID = customerID.trimmingCharacters(in: .whitespacesAndNewlines)
            if rememberCustomerID {
                try BoursoBankCustomerIDKeychain.save(normalizedCustomerID)
            } else {
                try BoursoBankCustomerIDKeychain.delete()
            }

            let newClient = BoursoBankClient()
            let result = try await newClient.initializeAndLogin(
                customerID: normalizedCustomerID,
                password: password
            )
            client = newClient
            switch result {
            case .authenticated:
                try await finishConnection(using: newClient)
            case .mfaRequired:
                workingMessage = "Préparation de la validation BoursoBank…"
                challenge = try await newClient.requestMFA()
                statusMessage = "Demande envoyée. Valide-la dans l’application BoursoBank."
            }
        } catch {
            client = nil
            challenge = nil
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func verifyMFA() async {
        guard let client, let challenge else { return }
        isWorking = true
        workingMessage = "Vérification de la validation BoursoBank…"
        defer { isWorking = false }
        do {
            if try await client.checkMFA(challenge) {
                self.challenge = nil
                try await finishConnection(using: client)
            } else {
                statusMessage = "La validation n’est pas encore confirmée par BoursoBank."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func finishConnection(using client: BoursoBankClient) async throws {
        workingMessage = "Recherche des PEA et comptes-titres…"
        tradingAccounts = try await client.tradingAccounts()
        isConnected = true
        selectInitialAccount()
        statusMessage = "Connexion réussie. \(tradingAccounts.count) compte(s) bourse détecté(s)."
    }

    @MainActor
    private func selectInitialAccount() {
        let savedID = UserDefaults.standard.string(forKey: "boursobank.accountID")
        selectedAccountID = tradingAccounts.contains(where: { $0.id == savedID })
            ? (savedID ?? "")
            : (tradingAccounts.first?.id ?? "")
        UserDefaults.standard.set(selectedAccountID, forKey: "boursobank.accountID")
        loadPortfolioPreference()
    }

    @MainActor
    private func loadPortfolioPreference() {
        selectedPortfolioID = UserDefaults.standard.string(forKey: portfolioPreferenceKey)
            ?? UserDefaults.standard.string(forKey: "boursobank.lastPortfolioID")
            ?? ""
        if selectedPortfolio == nil {
            selectedPortfolioID = portfolios.first?.id.uuidString ?? ""
        }
        UserDefaults.standard.set(selectedAccountID, forKey: "boursobank.accountID")
        UserDefaults.standard.set(selectedPortfolioID, forKey: portfolioPreferenceKey)
    }

    @MainActor
    private func createDedicatedPortfolio() {
        let baseName = selectedAccount?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = baseName?.isEmpty == false ? baseName! : "BoursoBank PEA"
        let portfolio = Portfolio(name: name, currencyCode: "EUR")
        modelContext.insert(portfolio)
        do {
            try modelContext.save()
            selectedPortfolioID = portfolio.id.uuidString
            statusMessage = "Portefeuille \(portfolio.name) créé."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func synchronize() async {
        guard let client, let account = selectedAccount, let portfolio = selectedPortfolio else { return }
        guard await BoursoBankSyncGate.shared.acquire() else {
            errorMessage = BoursoBankError.synchronizationAlreadyRunning.localizedDescription
            return
        }

        isWorking = true
        workingMessage = "Synchronisation du portefeuille BoursoBank…"
        statusMessage = nil
        defer { isWorking = false }
        do {
            let snapshot = try await client.snapshot(for: account)
            let result = try await BoursoBankImporter.synchronize(
                snapshot: snapshot,
                client: client,
                into: portfolio,
                context: modelContext
            )
            UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: lastSyncPreferenceKey)
            let symbolWarning = result.unresolvedSymbols > 0
                ? " · \(result.unresolvedSymbols) symbole(s) conservé(s) sous forme d’ISIN"
                : ""
            statusMessage = "\(result.positions) positions synchronisées · \(result.created) ajoutées · \(result.updated) mises à jour · \(result.removed) clôturées\(symbolWarning)."
            await marketData.refresh(
                holdings: portfolios.flatMap(\.holdings),
                watchlistItems: watchlistItems,
                context: modelContext
            )
            await BoursoBankSyncGate.shared.release()
        } catch {
            await BoursoBankSyncGate.shared.release()
            if let boursoError = error as? BoursoBankError, case .sessionExpired = boursoError {
                isConnected = false
                self.client = nil
                tradingAccounts = []
            }
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func disconnect() async {
        isWorking = true
        workingMessage = "Déconnexion de BoursoBank…"
        if let client { await client.disconnect() }
        try? BoursoBankSessionKeychain.delete()
        try? BoursoBankCustomerIDKeychain.delete()
        self.client = nil
        challenge = nil
        tradingAccounts = []
        selectedAccountID = ""
        isConnected = false
        customerID = ""
        password = ""
        statusMessage = "Compte BoursoBank déconnecté."
        isWorking = false
    }

    private var portfolioPreferenceKey: String {
        "boursobank.portfolioID.\(selectedAccountID)"
    }

    private var lastSyncPreferenceKey: String {
        "boursobank.lastSyncTimestamp.\(selectedAccountID)"
    }
}
