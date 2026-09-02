import SwiftUI

struct SecurityDetailView: View {
    let symbol: String
    let displayName: String
    let currentPrice: Double
    let previousClose: Double
    let currencyCode: String
    let annualDividendPerShare: Double
    let dividendYieldPercent: Double
    let lastDividendPerShare: Double
    let lastDividendDate: Date?
    let nextDividendDate: Date?
    let nextDividendDateIsEstimated: Bool
    let dividendPaymentsLastTwelveMonths: Int
    var quantity: Double? = nil
    var fxRateToPortfolioCurrency: Double = 1
    var portfolioCurrencyCode: String? = nil
    var averagePurchasePrice: Double? = nil

    @State private var analystSnapshot: AnalystSnapshot?
    @State private var isLoadingAnalysis = false
    @State private var analystErrorMessage: String?
    @State private var hasAnalystAPIKey = false

    private var dailyChangePercent: Double {
        guard previousClose > 0 else { return 0 }
        return (currentPrice - previousClose) / previousClose * 100
    }

    private var estimatedAnnualIncome: Double? {
        guard let quantity else { return nil }
        return annualDividendPerShare * quantity * fxRateToPortfolioCurrency
    }

    private var estimatedNextDividendPerShare: Double {
        if lastDividendPerShare > 0 { return lastDividendPerShare }
        guard dividendPaymentsLastTwelveMonths > 0 else { return 0 }
        return annualDividendPerShare / Double(dividendPaymentsLastTwelveMonths)
    }

    private var estimatedNextDividendIncome: Double? {
        guard let quantity, quantity > 0, estimatedNextDividendPerShare > 0 else { return nil }
        return estimatedNextDividendPerShare * quantity * fxRateToPortfolioCurrency
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    priceCard
                    if quantity != nil {
                        positionCard
                    }
                    dividendCard
                    nextDividendCard
                    analystSection
                    calculationNote
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle(symbol)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: symbol) {
            await loadAnalystSnapshot(forceRefresh: false)
        }
    }

    @ViewBuilder
    private var analystSection: some View {
        if let snapshot = analystSnapshot {
            analystSourceCard(snapshot)
            localAIAdviceCard(snapshot)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Label("Analyses de l’action", systemImage: "sparkles")
                    .font(.headline)

                if isLoadingAnalysis {
                    ProgressView("Chargement des données Alpha Vantage…")
                } else if !hasAnalystAPIKey {
                    Text("Ajoute ta clé Alpha Vantage gratuite pour afficher séparément l’avis des analystes et l’avis IA.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)

                    NavigationLink {
                        AnalystSettingsView()
                    } label: {
                        Label("Configurer l’analyse", systemImage: "key.fill")
                    }
                    .buttonStyle(.borderedProminent)
                } else if let analystErrorMessage {
                    Text(analystErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.negative)

                    Button {
                        Task { await loadAnalystSnapshot(forceRefresh: true) }
                    } label: {
                        Label("Réessayer", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .appCard()
        }
    }

    private func analystSourceCard(_ snapshot: AnalystSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Label("Avis des analystes", systemImage: "person.3.fill")
                    .font(.headline)
                Spacer()
                Text("ALPHA VANTAGE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(AppTheme.accent.opacity(0.12), in: Capsule())
            }

            if let targetPrice = snapshot.targetPrice {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Objectif moyen publié")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    HStack(alignment: .firstTextBaseline) {
                        Text(targetPrice.currency(snapshot.currencyCode))
                            .font(.title2.weight(.bold))
                        if let change = snapshot.targetChangePercent(from: currentPrice) {
                            Text(change / 100, format: .percent.precision(.fractionLength(1)))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(change >= 0 ? AppTheme.positive : AppTheme.negative)
                        }
                    }
                }
            }

            if snapshot.analystCount > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Consensus")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                            Text(snapshot.consensusLabel)
                                .font(.subheadline.weight(.bold))
                        }
                        Spacer()
                        Text("\(snapshot.analystCount) avis")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryText)
                    }

                    HStack(spacing: 12) {
                        analystMetric("Positifs", snapshot.positiveCount, color: AppTheme.positive)
                        analystMetric("Neutres", snapshot.hold, color: AppTheme.accent)
                        analystMetric("Négatifs", snapshot.negativeCount, color: AppTheme.negative)
                    }
                }
            }

            if let revenue = snapshot.quarterlyRevenueGrowth {
                HStack {
                    Text("Croissance trimestrielle du CA")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Spacer()
                    Text(revenue, format: .percent.precision(.fractionLength(1)))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(revenue >= 0 ? AppTheme.positive : AppTheme.negative)
                }
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack {
                Link("Source : Alpha Vantage", destination: URL(string: "https://www.alphavantage.co/")!)
                    .font(.caption)
                Spacer()
                Button {
                    Task { await loadAnalystSnapshot(forceRefresh: true) }
                } label: {
                    if isLoadingAnalysis {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isLoadingAnalysis || !hasAnalystAPIKey)
                .accessibilityLabel("Actualiser l’avis des analystes")
            }

            Text("Données récupérées le \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened)). L’objectif et le consensus proviennent du fournisseur : ce ne sont pas des prédictions de Nexa.")
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText)

            if let analystErrorMessage {
                Text("Dernière actualisation impossible : \(analystErrorMessage)")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.negative)
            }
        }
        .appCard()
    }

    private func localAIAdviceCard(_ snapshot: AnalystSnapshot) -> some View {
        let advice = snapshot.localAIAssessment(currentPrice: currentPrice)
        let adviceColor = advice.score >= 58
            ? AppTheme.positive
            : (advice.score < 43 ? AppTheme.negative : AppTheme.accent)

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Label("Avis IA", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Text("MODÈLE LOCAL")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(adviceColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(adviceColor.opacity(0.12), in: Capsule())
            }

            HStack(alignment: .firstTextBaseline) {
                Text(advice.verdict)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(adviceColor)
                Spacer()
                Text("\(advice.score)/100")
                    .font(.title3.weight(.bold))
            }

            ProgressView(value: Double(advice.score), total: 100)
                .tint(adviceColor)

            Text(advice.summary)
                .font(.subheadline)

            if !advice.strengths.isEmpty {
                assessmentFactors(title: "Points favorables", items: advice.strengths, color: AppTheme.positive)
            }
            if !advice.risks.isEmpty {
                assessmentFactors(title: "Points de vigilance", items: advice.risks, color: AppTheme.negative)
            }

            HStack {
                Text("Confiance : \(advice.confidence)")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("Calculé sur l’iPhone")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Text("Avis généré séparément par le modèle multifactoriel de Nexa à partir des indicateurs affichés. Il peut être incomplet ou erroné, ne prédit pas le marché et ne constitue pas un conseil financier.")
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .appCard()
    }

    private func analystMetric(_ title: String, _ value: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.headline)
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func assessmentFactors(title: String, items: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
            ForEach(items, id: \.self) { item in
                Label(item.capitalized, systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .symbolRenderingMode(.monochrome)
            }
        }
    }

    @MainActor
    private func loadAnalystSnapshot(forceRefresh: Bool) async {
        do {
            let apiKey = try AnalystAPIKeychain.load()
            hasAnalystAPIKey = apiKey != nil

            if !forceRefresh, let cached = AnalystSnapshotCache.load(symbol: symbol) {
                analystSnapshot = cached
                analystErrorMessage = nil
                return
            }

            guard let apiKey else {
                analystSnapshot = AnalystSnapshotCache.load(symbol: symbol, allowExpired: true)
                analystErrorMessage = nil
                return
            }

            isLoadingAnalysis = true
            analystErrorMessage = nil
            defer { isLoadingAnalysis = false }

            let snapshot = try await AnalystDataClient.shared.snapshot(for: symbol, apiKey: apiKey)
            AnalystSnapshotCache.save(snapshot, requestedSymbol: symbol)
            analystSnapshot = snapshot
        } catch {
            analystErrorMessage = error.localizedDescription
            if analystSnapshot == nil {
                analystSnapshot = AnalystSnapshotCache.load(symbol: symbol, allowExpired: true)
            }
        }
    }

    private var nextDividendCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Prochain dividende", systemImage: "calendar.badge.clock")
                    .font(.headline)
                Spacer()
                if nextDividendDate != nil {
                    Text(nextDividendDateIsEstimated ? "ESTIMATION" : "ANNONCÉE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(nextDividendDateIsEstimated ? AppTheme.accent : AppTheme.positive)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            (nextDividendDateIsEstimated ? AppTheme.accent : AppTheme.positive).opacity(0.12),
                            in: Capsule()
                        )
                }
            }

            if let nextDividendDate {
                VStack(alignment: .leading, spacing: 5) {
                    Text(nextDividendDateIsEstimated ? "Date de détachement estimée" : "Date de détachement annoncée")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(nextDividendDate.formatted(.dateTime.day().month(.wide).year()))
                        .font(.title3.weight(.bold))
                }

                if let estimatedNextDividendIncome, let quantity {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Montant estimé pour ta position")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                        Text(estimatedNextDividendIncome.currency(portfolioCurrencyCode ?? currencyCode))
                            .font(.title2.weight(.bold))
                            .foregroundStyle(AppTheme.positive)
                        Text("≈ \(quantity.formatted(.number.precision(.fractionLength(0...4)))) actions × \(estimatedNextDividendPerShare.currency(currencyCode))")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(AppTheme.positive.opacity(0.09), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }

                Text(nextDividendDateIsEstimated
                     ? "La date et le montant sont estimés d’après les versements récents et peuvent changer après l’annonce de l’entreprise."
                     : "Cette date provient des données publiées pour le titre. Le montant reste estimé à partir du dernier versement et peut changer.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
            } else {
                Text("Aucune prochaine date disponible pour ce titre.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .appCard()
    }

    private var positionCard: some View {
        let positionQuantity = quantity ?? 0
        let purchasePrice = averagePurchasePrice ?? 0
        let targetCurrency = portfolioCurrencyCode ?? currencyCode
        let investedValue = purchasePrice * positionQuantity * fxRateToPortfolioCurrency
        let currentValue = currentPrice * positionQuantity * fxRateToPortfolioCurrency
        let gain = currentValue - investedValue

        return VStack(alignment: .leading, spacing: 16) {
            Label("Ma position", systemImage: "briefcase.fill")
                .font(.headline)

            HStack(alignment: .top, spacing: 16) {
                dividendMetric(
                    title: "Quantité",
                    value: positionQuantity.formatted(.number.precision(.fractionLength(0...4)))
                )
                dividendMetric(
                    title: "Prix d’achat moyen",
                    value: purchasePrice.currency(currencyCode)
                )
                dividendMetric(
                    title: "Valeur investie",
                    value: investedValue.currency(targetCurrency)
                )
            }

            HStack {
                Text("Gain/perte non réalisé")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
                Text(gain.currency(targetCurrency))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(gain >= 0 ? AppTheme.positive : AppTheme.negative)
            }
        }
        .appCard()
    }

    private var priceCard: some View {
        HStack(spacing: 14) {
            SymbolBadge(symbol: symbol, size: 58)
            VStack(alignment: .leading, spacing: 5) {
                Text(displayName)
                    .font(.headline)
                    .lineLimit(2)
                Text(currentPrice > 0 ? currentPrice.currency(currencyCode) : "Cours indisponible")
                    .font(.title2.weight(.bold))
            }
            Spacer()
            if previousClose > 0 {
                ChangeBadge(value: dailyChangePercent)
            }
        }
        .appCard()
    }

    @ViewBuilder
    private var dividendCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Dividendes", systemImage: "banknote.fill")
                    .font(.headline)
                Spacer()
                DividendBadge(yieldPercent: dividendYieldPercent)
            }

            if dividendYieldPercent > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rendement sur 12 mois")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(dividendYieldPercent / 100, format: .percent.precision(.fractionLength(2)))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.accent)
                }

                Divider().overlay(Color.white.opacity(0.08))

                HStack(alignment: .top, spacing: 16) {
                    dividendMetric(
                        title: "Total par action",
                        value: annualDividendPerShare.currency(currencyCode)
                    )
                    dividendMetric(
                        title: "Dernier versement",
                        value: lastDividendPerShare.currency(currencyCode)
                    )
                    dividendMetric(
                        title: "Versements",
                        value: "\(dividendPaymentsLastTwelveMonths)"
                    )
                }

                if let lastDividendDate {
                    Label {
                        Text("Dernier détachement : \(lastDividendDate.formatted(date: .abbreviated, time: .omitted))")
                    } icon: {
                        Image(systemName: "calendar")
                    }
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                }

                if let estimatedAnnualIncome {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Revenu annuel estimé pour ta position")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                        Text(estimatedAnnualIncome.currency(portfolioCurrencyCode ?? currencyCode))
                            .font(.title3.weight(.bold))
                            .foregroundStyle(AppTheme.positive)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(AppTheme.positive.opacity(0.09), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
            } else {
                EmptyStateView(
                    icon: "banknote",
                    title: "Aucun dividende détecté",
                    message: "Aucun versement en espèces n’a été trouvé pour ce titre sur les douze derniers mois."
                )
                .padding(.vertical, -12)
            }
        }
        .appCard()
    }

    private func dividendMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var calculationNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Méthode de calcul", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
            Text("Le rendement correspond à la somme des dividendes en espèces des douze derniers mois, divisée par le cours actuel. La prochaine date est estimée à partir de la cadence récente lorsqu’aucune date annoncée n’est disponible. Ces informations sont indicatives et ne garantissent pas les versements futurs.")
                .font(.footnote)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }
}
