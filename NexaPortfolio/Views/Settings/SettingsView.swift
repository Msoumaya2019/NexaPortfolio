import SwiftUI
import SwiftData

struct SettingsView: View {
    @Query(sort: \Portfolio.createdAt) private var portfolios: [Portfolio]
    @Query(sort: \Holding.symbol) private var holdings: [Holding]
    @Query(sort: \TradeTransaction.date) private var transactions: [TradeTransaction]
    @Query(sort: \Watchlist.createdAt) private var watchlists: [Watchlist]

    @AppStorage("hideBalances") private var hideBalances = false
    @AppStorage("refreshOnLaunch") private var refreshOnLaunch = true

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            List {
                Section("Affichage") {
                    Toggle(isOn: $hideBalances) {
                        Label("Masquer les montants", systemImage: "eye.slash")
                    }
                    Toggle(isOn: $refreshOnLaunch) {
                        Label("Actualiser au démarrage", systemImage: "arrow.clockwise")
                    }
                }

                Section("Données") {
                    LabeledContent("Portefeuilles", value: "\(portfolios.count)")
                    LabeledContent("Positions", value: "\(holdings.count)")
                    LabeledContent("Transactions", value: "\(transactions.count)")
                    LabeledContent("Listes de suivi", value: "\(watchlists.count)")

                    ShareLink(item: exportText) {
                        Label("Exporter un relevé", systemImage: "square.and.arrow.up")
                    }
                }

                Section("Connexions") {
                    NavigationLink {
                        Trading212SettingsView()
                    } label: {
                        Label("Trading 212", systemImage: "link.circle.fill")
                    }

                    Text("Importe automatiquement les achats, ventes, dividendes, positions et liquidités avec une clé API en lecture seule.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)

                    NavigationLink {
                        DegiroSettingsView()
                    } label: {
                        Label("DEGIRO", systemImage: "doc.text.magnifyingglass")
                    }

                    Text("Importe les achats, ventes et dividendes depuis les relevés CSV officiels, sans identifiant ni mot de passe.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)

                    NavigationLink {
                        TradeRepublicSettingsView()
                    } label: {
                        Label("Trade Republic", systemImage: "doc.richtext")
                    }

                    Text("Importe localement l’export de transactions CSV ou les relevés PDF, sans PIN ni code 2FA.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)

                    NavigationLink {
                        RevolutSettingsView()
                    } label: {
                        Label("Revolut", systemImage: "building.columns.fill")
                    }

                    Text("Importe localement l’historique CSV d’investissements Revolut, sans identifiant ni code de connexion.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)

                    NavigationLink {
                        BoursoBankSettingsView()
                    } label: {
                        Label("BoursoBank", systemImage: "building.columns.circle.fill")
                    }

                    Text("Synchronise le PEA et les comptes-titres en lecture seule via une connexion non officielle avec validation dans l’application BoursoBank.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Section("Analyse") {
                    NavigationLink {
                        AnalystSettingsView()
                    } label: {
                        Label("Analystes et avis IA", systemImage: "sparkles")
                    }

                    Text("Affiche séparément les objectifs et consensus Alpha Vantage, puis l’avis du modèle local de Nexa pour chaque action.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Section("À propos des cours") {
                    Label("Actualisation manuelle et sans clé API", systemImage: "network")
                    Text("Les cours sont obtenus depuis un service public et peuvent être retardés ou indisponibles. Les valeurs sont indicatives.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Section("Application") {
                    LabeledContent("Version", value: "2.3.0")
                    Label("Stockage privé sur cet appareil", systemImage: "lock.shield")
                    Label("Aucune limite de listes ou d’opérations", systemImage: "infinity")
                }

                Section {
                    Text("Nexa Portfolio est un outil de suivi personnel, pas un service de conseil financier. Vérifie toujours les données avant toute décision d’investissement.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Réglages")
    }

    private var exportText: String {
        var lines = [
            "Nexa Portfolio — export du \(Date.now.formatted(date: .abbreviated, time: .shortened))",
            "",
            "POSITIONS",
            "Portefeuille;Symbole;Nom;Quantité;Prix moyen;Cours;Devise;Dividende annuel/action;Rendement dividende (%)"
        ]

        for portfolio in portfolios {
            for holding in portfolio.holdings {
                lines.append([
                    portfolio.name,
                    holding.symbol,
                    holding.displayName,
                    String(holding.quantity),
                    String(holding.purchasePrice),
                    String(holding.currentPrice),
                    holding.currencyCode,
                    String(holding.annualDividendPerShare),
                    String(holding.dividendYieldPercent)
                ].map(csvEscape).joined(separator: ";"))
            }
        }

        lines.append(contentsOf: ["", "TRANSACTIONS", "Portefeuille;Type;Symbole;Quantité;Prix;Frais;Devise;Date;Source;Identifiant externe;Notes"])
        for transaction in transactions {
            lines.append([
                transaction.portfolio?.name ?? "",
                transaction.kind.title,
                transaction.symbol,
                String(transaction.quantity),
                String(transaction.price),
                String(transaction.fees),
                transaction.currencyCode,
                transaction.date.ISO8601Format(),
                transaction.externalSource ?? "Manuel",
                transaction.externalIdentifier ?? "",
                transaction.notes
            ].map(csvEscape).joined(separator: ";"))
        }
        return lines.joined(separator: "\n")
    }

    private func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
