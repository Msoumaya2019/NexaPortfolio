import SwiftUI

struct AnalystSettingsView: View {
    @State private var apiKey = ""
    @State private var hasStoredKey = false
    @State private var isTesting = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Avis des analystes — Alpha Vantage") {
                Label("Objectifs et consensus sourcés", systemImage: "person.3.fill")
                    .foregroundStyle(AppTheme.positive)

                Text("Cette catégorie affiche uniquement l’objectif moyen et la répartition des recommandations fournis par Alpha Vantage.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)

                Link(
                    "Créer une clé API Alpha Vantage",
                    destination: URL(string: "https://www.alphavantage.co/support/#api-key")!
                )
            }

            Section("Avis IA — Nexa") {
                Label("Analyse multifactorielle séparée", systemImage: "sparkles")
                    .foregroundStyle(AppTheme.accent)

                Text("Le modèle local de Nexa calcule un score, un niveau de confiance, des points favorables et des risques à partir des indicateurs disponibles. Son avis est affiché dans un bloc différent et n’est jamais attribué à Alpha Vantage.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)

                Label("Aucune donnée de portefeuille transmise", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    .font(.footnote)
            }

            Section("Clé personnelle") {
                SecureField("Clé API", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    saveKey()
                } label: {
                    Label("Enregistrer dans le Trousseau iOS", systemImage: "key.fill")
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if hasStoredKey {
                    Label("Clé enregistrée sur cet appareil", systemImage: "checkmark.shield.fill")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.positive)

                    Button {
                        Task { await testKey() }
                    } label: {
                        Label("Tester la connexion", systemImage: "network")
                    }
                    .disabled(isTesting)

                    Button("Supprimer la clé", role: .destructive) {
                        deleteKey()
                    }
                }

                if isTesting {
                    ProgressView("Vérification…")
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.positive)
                }
            }

            Section("Fonctionnement") {
                Label("Ouvre une action pour voir les deux avis", systemImage: "rectangle.split.2x1")
                Text("Les résultats sont conservés pendant 24 heures pour limiter les appels. La formule gratuite du fournisseur impose un quota quotidien et certains titres, notamment des ETF ou marchés secondaires, peuvent ne disposer d’aucun consensus.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Section {
                Text("Les objectifs reflètent l’opinion d’analystes tiers à une date donnée. L’avis IA est une estimation automatisée distincte, qui peut être incomplète ou erronée. Aucun des deux ne garantit une évolution future ni ne constitue un conseil d’achat ou de vente.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .navigationTitle("Analystes et IA")
        .navigationBarTitleDisplayMode(.inline)
        .task { refreshStoredKeyStatus() }
        .alert("Configuration impossible", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func refreshStoredKeyStatus() {
        do {
            hasStoredKey = try AnalystAPIKeychain.load() != nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveKey() {
        do {
            try AnalystAPIKeychain.save(apiKey)
            apiKey = ""
            hasStoredKey = true
            statusMessage = "Clé enregistrée. Tu peux maintenant analyser tes actions."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func testKey() async {
        isTesting = true
        statusMessage = nil
        defer { isTesting = false }
        do {
            guard let storedKey = try AnalystAPIKeychain.load() else {
                throw AnalystDataError.apiMessage("Aucune clé n’est enregistrée.")
            }
            _ = try await AnalystDataClient.shared.snapshot(for: "IBM", apiKey: storedKey)
            statusMessage = "Connexion réussie."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteKey() {
        do {
            try AnalystAPIKeychain.delete()
            hasStoredKey = false
            apiKey = ""
            statusMessage = "Clé supprimée."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
