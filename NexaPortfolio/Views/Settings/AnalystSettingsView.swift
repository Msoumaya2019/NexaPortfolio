import SwiftUI

struct AnalystSettingsView: View {
    @State private var enteredKeys: [AnalystProvider: String] = [:]
    @State private var storedProviders = Set<AnalystProvider>()
    @State private var testingProvider: AnalystProvider?
    @State private var statusMessages: [AnalystProvider: String] = [:]
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Sources indépendantes") {
                Label("Plusieurs fournisseurs peuvent fonctionner ensemble", systemImage: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(AppTheme.positive)
                Text("Chaque avis conserve son fournisseur et sa date. Nexa ne présente jamais une donnée issue d’une API comme une prédiction de son modèle IA.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            ForEach(AnalystProvider.allCases) { provider in
                providerSection(provider)
            }

            Section("Avis IA — Nexa") {
                Label("Synthèse multifactorielle séparée", systemImage: "sparkles")
                    .foregroundStyle(AppTheme.accent)
                Text("Le modèle local combine uniquement les indicateurs effectivement reçus, signale son niveau de confiance et sépare les points favorables des risques.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
                Label("Aucune donnée de portefeuille transmise", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    .font(.footnote)
            }

            Section("Fonctionnement") {
                Label("Fiches des positions et listes de suivi", systemImage: "rectangle.split.2x1")
                Label("Rubrique Opportunités à étudier", systemImage: "scope")
                Text("Les résultats sont conservés pendant 24 heures. Une source indisponible n’empêche pas les autres de s’afficher. Les quotas et la couverture dépendent de chaque formule API.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Section {
                Text("Les objectifs reflètent des opinions d’analystes tiers à une date donnée. L’avis IA est une estimation automatisée, potentiellement incomplète ou erronée. Aucun résultat ne garantit une évolution future ni ne constitue un conseil d’achat ou de vente.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .navigationTitle("Sources et avis IA")
        .navigationBarTitleDisplayMode(.inline)
        .task { refreshStoredProviders() }
        .alert("Configuration impossible", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func providerSection(_ provider: AnalystProvider) -> some View {
        Section(provider.title) {
            SecureField("Clé API personnelle", text: keyBinding(for: provider))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Link("Créer ou gérer une clé \(provider.title)", destination: provider.signupURL)

            Button {
                saveKey(for: provider)
            } label: {
                Label("Enregistrer dans le Trousseau iOS", systemImage: "key.fill")
            }
            .disabled((enteredKeys[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if storedProviders.contains(provider) {
                Label("Clé enregistrée sur cet appareil", systemImage: "checkmark.shield.fill")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.positive)

                HStack {
                    Button {
                        Task { await testKey(for: provider) }
                    } label: {
                        Label("Tester", systemImage: "network")
                    }
                    .disabled(testingProvider != nil)

                    Spacer()

                    Button("Supprimer", role: .destructive) {
                        deleteKey(for: provider)
                    }
                }
            }

            if testingProvider == provider { ProgressView("Vérification…") }
            if let status = statusMessages[provider] {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.positive)
            }
        }
    }

    private func keyBinding(for provider: AnalystProvider) -> Binding<String> {
        Binding(
            get: { enteredKeys[provider] ?? "" },
            set: { enteredKeys[provider] = $0 }
        )
    }

    private func refreshStoredProviders() {
        do {
            storedProviders = Set(try AnalystAPIKeychain.configuredKeys().keys)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveKey(for provider: AnalystProvider) {
        do {
            try AnalystAPIKeychain.save(enteredKeys[provider] ?? "", for: provider)
            enteredKeys[provider] = ""
            storedProviders.insert(provider)
            statusMessages[provider] = "Clé enregistrée."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func testKey(for provider: AnalystProvider) async {
        testingProvider = provider
        statusMessages[provider] = nil
        defer { testingProvider = nil }
        do {
            guard let key = try AnalystAPIKeychain.load(for: provider) else {
                throw AnalystDataError.apiMessage("Aucune clé n’est enregistrée.")
            }
            _ = try await AnalystDataClient.shared.snapshot(for: "AAPL", apiKey: key, provider: provider)
            statusMessages[provider] = "Connexion réussie."
        } catch {
            errorMessage = "\(provider.title) : \(error.localizedDescription)"
        }
    }

    private func deleteKey(for provider: AnalystProvider) {
        do {
            try AnalystAPIKeychain.delete(for: provider)
            storedProviders.remove(provider)
            enteredKeys[provider] = ""
            statusMessages[provider] = "Clé supprimée."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
