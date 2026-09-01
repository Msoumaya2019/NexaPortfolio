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

    private var dailyChangePercent: Double {
        guard previousClose > 0 else { return 0 }
        return (currentPrice - previousClose) / previousClose * 100
    }

    private var estimatedAnnualIncome: Double? {
        guard let quantity else { return nil }
        return annualDividendPerShare * quantity * fxRateToPortfolioCurrency
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
                    calculationNote
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle(symbol)
        .navigationBarTitleDisplayMode(.inline)
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

                Text(nextDividendDateIsEstimated
                     ? "Cette date est calculée d’après la cadence récente des dividendes et peut changer après l’annonce de l’entreprise."
                     : "Cette date provient des données publiées pour le titre et peut encore être modifiée par l’entreprise.")
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
