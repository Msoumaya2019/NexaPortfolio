import SwiftUI

private struct OpportunityCandidate: Identifiable, Sendable {
    let symbol: String
    let name: String
    let universe: String
    var id: String { symbol }
}

private enum OpportunityUniverse: String, CaseIterable, Identifiable {
    case nasdaq100
    case sp500
    case cac40

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nasdaq100: return "Nasdaq-100"
        case .sp500: return "S&P 500"
        case .cac40: return "CAC 40"
        }
    }

    var candidates: [OpportunityCandidate] {
        let values: [(String, String)]
        switch self {
        case .nasdaq100:
            values = [
                ("AAPL", "Apple"), ("MSFT", "Microsoft"), ("AMZN", "Amazon"),
                ("GOOGL", "Alphabet"), ("META", "Meta Platforms"), ("NVDA", "NVIDIA"),
                ("AVGO", "Broadcom"), ("COST", "Costco"), ("AMD", "AMD"), ("NFLX", "Netflix")
            ]
        case .sp500:
            values = [
                ("JPM", "JPMorgan Chase"), ("XOM", "Exxon Mobil"), ("JNJ", "Johnson & Johnson"),
                ("WMT", "Walmart"), ("PG", "Procter & Gamble"), ("KO", "Coca-Cola"),
                ("CVX", "Chevron"), ("ABBV", "AbbVie"), ("BAC", "Bank of America"), ("HD", "Home Depot")
            ]
        case .cac40:
            values = [
                ("MC.PA", "LVMH"), ("OR.PA", "L’Oréal"), ("AIR.PA", "Airbus"),
                ("SAN.PA", "Sanofi"), ("TTE.PA", "TotalEnergies"), ("BNP.PA", "BNP Paribas"),
                ("SU.PA", "Schneider Electric"), ("DG.PA", "Vinci"), ("AI.PA", "Air Liquide"), ("CS.PA", "AXA")
            ]
        }
        return values.map { OpportunityCandidate(symbol: $0.0, name: $0.1, universe: title) }
    }
}

private struct OpportunityResult: Identifiable {
    let candidate: OpportunityCandidate
    let quote: MarketQuote
    let snapshots: [AnalystSnapshot]
    let score: Int

    var id: String { candidate.id }
    var primarySnapshot: AnalystSnapshot { snapshots[0] }
    var assessment: LocalAIAssessment {
        LocalAIAssessment.make(from: snapshots, currentPrice: quote.price)
    }

    var label: String {
        switch score {
        case 72...: return "Décote à étudier"
        case 58..<72: return "À surveiller"
        case 43..<58: return "Valorisation neutre"
        default: return "Prudence"
        }
    }
}

struct OpportunitiesView: View {
    @EnvironmentObject private var marketData: MarketDataStore

    @State private var universe: OpportunityUniverse = .nasdaq100
    @State private var results: [OpportunityResult] = []
    @State private var isLoading = false
    @State private var progressText = ""
    @State private var errorMessage: String?
    @State private var hasConfiguredProvider = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                introductionCard

                Picker("Indice", selection: $universe) {
                    ForEach(OpportunityUniverse.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)

                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(progressText)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .appCard()
                } else if !hasConfiguredProvider {
                    configurationCard
                } else if results.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "scope")
                            .font(.largeTitle)
                            .foregroundStyle(AppTheme.accent)
                        Text("Lance l’analyse de la sélection")
                            .font(.headline)
                        Text("Nexa comparera les valorisations disponibles et classera les titres sans les présenter comme des ordres d’achat.")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.secondaryText)
                            .multilineTextAlignment(.center)
                        Button {
                            Task { await analyze(forceRefresh: false) }
                        } label: {
                            Label("Analyser \(universe.title)", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .appCard()
                } else {
                    resultSummary
                    ForEach(results) { result in
                        opportunityCard(result)
                    }
                }

                disclaimerCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .task { refreshConfiguration() }
        .onChange(of: universe) {
            results = []
            errorMessage = nil
        }
        .alert("Analyse incomplète", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var introductionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Opportunités à étudier", systemImage: "scope")
                .font(.headline)
            Text("Présélection de grandes entreprises selon leur PER, leur valorisation, leur croissance et les objectifs disponibles.")
                .font(.subheadline)
            Text("Sélection représentative et non exhaustive des indices. Les compositions et les données peuvent évoluer.")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Une source d’analyse est nécessaire", systemImage: "key.fill")
                .font(.headline)
            Text("Configure Twelve Data, Finnhub ou Alpha Vantage. Twelve Data est utilisé en priorité pour cette présélection internationale.")
                .font(.footnote)
                .foregroundStyle(AppTheme.secondaryText)
            NavigationLink {
                AnalystSettingsView()
            } label: {
                Label("Configurer les sources", systemImage: "gearshape")
            }
            .buttonStyle(.borderedProminent)
        }
        .appCard()
    }

    private var resultSummary: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Classement actuel")
                    .font(.headline)
                Text("\(results.count) titre\(results.count > 1 ? "s" : "") avec données exploitables")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            Spacer()
            Button {
                Task { await analyze(forceRefresh: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading)
            .accessibilityLabel("Actualiser le classement")
        }
        .appCard()
    }

    private func opportunityCard(_ result: OpportunityResult) -> some View {
        let color = result.score >= 58 ? AppTheme.positive : (result.score < 43 ? AppTheme.negative : AppTheme.accent)
        return NavigationLink {
            SecurityDetailView(
                symbol: result.quote.symbol,
                displayName: result.quote.displayName,
                currentPrice: result.quote.price,
                previousClose: result.quote.previousClose,
                currencyCode: result.quote.currencyCode,
                annualDividendPerShare: result.quote.annualDividendPerShare,
                dividendYieldPercent: result.quote.dividendYieldPercent,
                lastDividendPerShare: result.quote.lastDividendPerShare,
                lastDividendDate: result.quote.lastDividendDate,
                nextDividendDate: result.quote.nextDividendDate,
                nextDividendDateIsEstimated: result.quote.nextDividendDateIsEstimated,
                dividendPaymentsLastTwelveMonths: result.quote.dividendPaymentsLastTwelveMonths
            )
        } label: {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 12) {
                    SymbolBadge(symbol: result.candidate.symbol)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.candidate.name)
                            .font(.subheadline.weight(.bold))
                        Text("\(result.candidate.symbol) · \(result.candidate.universe)")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    Spacer()
                    Text("\(result.score)/100")
                        .font(.headline)
                        .foregroundStyle(color)
                }

                ProgressView(value: Double(result.score), total: 100)
                    .tint(color)

                HStack {
                    Text(result.label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(color)
                    Spacer()
                    Text(result.quote.price.currency(result.quote.currencyCode))
                        .font(.subheadline.weight(.semibold))
                }

                HStack(spacing: 14) {
                    if let pe = result.primarySnapshot.usablePE, pe > 0 {
                        compactMetric("PER", pe.formatted(.number.precision(.fractionLength(1))))
                    }
                    if let upside = result.primarySnapshot.targetChangePercent(from: result.quote.price) {
                        compactMetric(
                            "Objectif",
                            (upside / 100).formatted(.percent.precision(.fractionLength(1)))
                        )
                    }
                    compactMetric("Source", result.primarySnapshot.provider.title)
                }

                if let reason = result.assessment.strengths.first {
                    Label(reason.capitalized, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .appCard()
        }
        .buttonStyle(.plain)
    }

    private func compactMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText)
            Text(value)
                .font(.caption.weight(.bold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var disclaimerCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Présélection, pas recommandation", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
            Text("Un PER faible peut signaler une décote ou une baisse future des bénéfices. Vérifie les comptes, le secteur, les risques et ta diversification avant toute décision.")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    @MainActor
    private func refreshConfiguration() {
        hasConfiguredProvider = ((try? AnalystAPIKeychain.configuredKeys())?.isEmpty == false)
    }

    @MainActor
    private func analyze(forceRefresh: Bool) async {
        guard let keys = try? AnalystAPIKeychain.configuredKeys(), !keys.isEmpty else {
            hasConfiguredProvider = false
            return
        }
        hasConfiguredProvider = true
        isLoading = true
        errorMessage = nil
        results = []
        defer { isLoading = false }

        let primaryProvider = AnalystProvider.allCases.first { keys[$0] != nil } ?? .alphaVantage
        guard let primaryKey = keys[primaryProvider] else { return }
        var loaded: [OpportunityResult] = []
        var failureCount = 0

        for (index, candidate) in universe.candidates.enumerated() {
            progressText = "\(candidate.name) · \(index + 1)/\(universe.candidates.count)"
            do {
                let quote = try await marketData.quote(for: candidate.symbol)
                let snapshot: AnalystSnapshot
                if !forceRefresh,
                   let cached = AnalystSnapshotCache.load(symbol: candidate.symbol, provider: primaryProvider) {
                    snapshot = cached
                } else {
                    snapshot = try await AnalystDataClient.shared.snapshot(
                        for: candidate.symbol,
                        apiKey: primaryKey,
                        provider: primaryProvider
                    )
                    AnalystSnapshotCache.save(snapshot, requestedSymbol: candidate.symbol)
                }
                let assessment = LocalAIAssessment.make(from: [snapshot], currentPrice: quote.price)
                loaded.append(OpportunityResult(
                    candidate: candidate,
                    quote: quote,
                    snapshots: [snapshot],
                    score: opportunityScore(assessment: assessment, snapshot: snapshot)
                ))
                results = loaded.sorted { $0.score > $1.score }
            } catch {
                failureCount += 1
            }
        }

        if loaded.isEmpty {
            errorMessage = "Aucun titre n’a pu être analysé. Vérifie la clé, son quota et la couverture de ton abonnement."
        } else if failureCount > 0 {
            errorMessage = "\(failureCount) titre\(failureCount > 1 ? "s n’ont" : " n’a") pas pu être analysé. Les autres résultats restent disponibles."
        }
    }

    private func opportunityScore(assessment: LocalAIAssessment, snapshot: AnalystSnapshot) -> Int {
        var value = assessment.score
        if let pe = snapshot.usablePE, pe > 0 {
            switch pe {
            case ..<10: value += 10
            case 10..<15: value += 7
            case 15..<22: value += 3
            case 35...: value -= 8
            default: break
            }
        }
        if let peg = snapshot.pegRatio, peg > 0, peg < 1.5 { value += 4 }
        if let priceToBook = snapshot.priceToBook, priceToBook > 0, priceToBook < 2 { value += 3 }
        return min(max(value, 0), 100)
    }
}
