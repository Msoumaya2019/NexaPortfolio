import SwiftUI

struct AggregatePortfolioContent: View {
    @EnvironmentObject private var marketData: MarketDataStore

    let portfolios: [Portfolio]
    @Binding var aggregateCurrencyCode: String

    private let currencies = ["EUR", "USD", "GBP", "CHF", "CAD", "JPY"]

    private var totalValue: Double {
        portfolios.reduce(0) { $0 + $1.totalValue * aggregateRate(for: $1) }
    }

    private var totalCost: Double {
        portfolios.reduce(0) { $0 + $1.costBasis * aggregateRate(for: $1) }
    }

    private var totalCash: Double {
        portfolios.reduce(0) { $0 + $1.cashBalance * aggregateRate(for: $1) }
    }

    private var totalGain: Double {
        portfolios.reduce(0) { $0 + $1.unrealizedGain * aggregateRate(for: $1) }
    }

    private var totalGainPercent: Double {
        guard totalCost > 0 else { return 0 }
        return totalGain / totalCost * 100
    }

    private var annualDividendIncome: Double {
        portfolios.reduce(0) { partial, portfolio in
            partial + portfolio.holdings.reduce(0) {
                $0 + $1.estimatedAnnualDividendIncome * aggregateRate(for: portfolio)
            }
        }
    }

    private var combinedHoldings: [AggregateHolding] {
        var values: [String: AggregateHolding] = [:]

        for portfolio in portfolios {
            let portfolioRate = aggregateRate(for: portfolio)
            for holding in portfolio.holdings {
                let directRate = holding.fxRateToPortfolioCurrency * portfolioRate
                let aggregateMarketValue = holding.marketValue * directRate
                let aggregateCost = holding.costBasis * directRate
                let aggregatePreviousValue = holding.previousClose * holding.quantity * directRate
                let aggregateDailyChange = (holding.currentPrice - holding.previousClose)
                    * holding.quantity
                    * directRate
                let aggregateDividendIncome = holding.annualDividendPerShare
                    * holding.quantity
                    * directRate

                if var existing = values[holding.symbol] {
                    existing.quantity += holding.quantity
                    existing.marketValue += aggregateMarketValue
                    existing.costBasis += aggregateCost
                    existing.previousValue += aggregatePreviousValue
                    existing.dailyChangeValue += aggregateDailyChange
                    existing.annualDividendIncome += aggregateDividendIncome
                    existing.fxRateToAggregateCurrency = directRate
                    existing.dividendPaymentsLastTwelveMonths = max(
                        existing.dividendPaymentsLastTwelveMonths,
                        holding.dividendPaymentsLastTwelveMonths
                    )
                    if let date = holding.lastDividendDate {
                        let isMoreRecent = existing.lastDividendDate.map { date > $0 } ?? true
                        if isMoreRecent {
                            existing.lastDividendDate = date
                            existing.lastDividendPerShare = holding.lastDividendPerShare
                        }
                    }
                    values[holding.symbol] = existing
                } else {
                    values[holding.symbol] = AggregateHolding(
                        symbol: holding.symbol,
                        displayName: holding.displayName,
                        quantity: holding.quantity,
                        currentPrice: holding.currentPrice,
                        previousClose: holding.previousClose,
                        currencyCode: holding.currencyCode,
                        annualDividendPerShare: holding.annualDividendPerShare,
                        lastDividendPerShare: holding.lastDividendPerShare,
                        lastDividendDate: holding.lastDividendDate,
                        dividendPaymentsLastTwelveMonths: holding.dividendPaymentsLastTwelveMonths,
                        fxRateToAggregateCurrency: directRate,
                        marketValue: aggregateMarketValue,
                        costBasis: aggregateCost,
                        previousValue: aggregatePreviousValue,
                        dailyChangeValue: aggregateDailyChange,
                        annualDividendIncome: aggregateDividendIncome
                    )
                }
            }
        }

        return values.values.sorted { $0.marketValue > $1.marketValue }
    }

    private var allTransactions: [TradeTransaction] {
        portfolios.flatMap(\.transactions).sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(spacing: 18) {
            aggregateSummaryCard
            portfolioBreakdownCard
            combinedHoldingsCard
            combinedTransactionsCard
        }
    }

    private var aggregateSummaryCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Patrimoine consolidé", systemImage: "square.stack.3d.up.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
                if marketData.isRefreshing {
                    ProgressView()
                }
                Picker("Devise globale", selection: $aggregateCurrencyCode) {
                    ForEach(currencies, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(AppTheme.accent)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(totalValue.currency(aggregateCurrencyCode))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Spacer()
                ChangeBadge(value: totalGainPercent)
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack {
                aggregateMetric("Investi", totalCost.currency(aggregateCurrencyCode))
                Spacer()
                aggregateMetric("Liquidités", totalCash.currency(aggregateCurrencyCode))
                Spacer()
                aggregateMetric(
                    "Gain/perte",
                    totalGain.currency(aggregateCurrencyCode),
                    color: totalGain >= 0 ? AppTheme.positive : AppTheme.negative
                )
            }

            HStack {
                Label("Dividendes annuels estimés", systemImage: "banknote.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
                Text(annualDividendIncome.currency(aggregateCurrencyCode))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.positive)
            }
            .padding(12)
            .background(AppTheme.positive.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .appCard()
    }

    private func aggregateMetric(_ title: String, _ value: String, color: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var portfolioBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Par portefeuille")
                    .font(.headline)
                Spacer()
                Text("\(portfolios.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(AppTheme.accent.opacity(0.1), in: Capsule())
            }

            ForEach(portfolios) { portfolio in
                HStack(spacing: 12) {
                    Image(systemName: "briefcase.fill")
                        .foregroundStyle(AppTheme.accentBlue)
                        .frame(width: 38, height: 38)
                        .background(AppTheme.accentBlue.opacity(0.1), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(portfolio.name)
                            .font(.subheadline.weight(.semibold))
                        Text("\(portfolio.holdings.count) positions · \(portfolio.currencyCode)")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text((portfolio.totalValue * aggregateRate(for: portfolio)).currency(aggregateCurrencyCode))
                            .font(.subheadline.weight(.bold))
                        if portfolio.currencyCode != aggregateCurrencyCode {
                            Text(portfolio.totalValue.currency(portfolio.currencyCode))
                                .font(.caption2)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                }
            }
        }
        .appCard()
    }

    private var combinedHoldingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Positions regroupées")
                    .font(.headline)
                Spacer()
                Text("\(combinedHoldings.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.accent)
            }

            if combinedHoldings.isEmpty {
                EmptyStateView(
                    icon: "plus.forwardslash.minus",
                    title: "Aucune position",
                    message: "Les positions de tous tes portefeuilles apparaîtront ici."
                )
            } else {
                ForEach(combinedHoldings) { holding in
                    NavigationLink {
                        SecurityDetailView(
                            symbol: holding.symbol,
                            displayName: holding.displayName,
                            currentPrice: holding.currentPrice,
                            previousClose: holding.previousClose,
                            currencyCode: holding.currencyCode,
                            annualDividendPerShare: holding.annualDividendPerShare,
                            dividendYieldPercent: holding.dividendYieldPercent,
                            lastDividendPerShare: holding.lastDividendPerShare,
                            lastDividendDate: holding.lastDividendDate,
                            dividendPaymentsLastTwelveMonths: holding.dividendPaymentsLastTwelveMonths,
                            quantity: holding.quantity,
                            fxRateToPortfolioCurrency: holding.fxRateToAggregateCurrency,
                            portfolioCurrencyCode: aggregateCurrencyCode
                        )
                    } label: {
                        HStack(spacing: 12) {
                            SymbolBadge(symbol: holding.symbol)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(holding.symbol)
                                    .font(.subheadline.weight(.bold))
                                Text("\(holding.quantity.formatted(.number.precision(.fractionLength(0...4)))) titres au total")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText)
                                DividendBadge(yieldPercent: holding.dividendYieldPercent)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(holding.marketValue.currency(aggregateCurrencyCode))
                                    .font(.subheadline.weight(.semibold))
                                Text(holding.unrealizedGainPercent / 100, format: .percent.precision(.fractionLength(2)))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(holding.unrealizedGain >= 0 ? AppTheme.positive : AppTheme.negative)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    if holding.id != combinedHoldings.last?.id {
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                }
            }
        }
        .appCard()
    }

    private var combinedTransactionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Activité de tous les portefeuilles")
                .font(.headline)

            if allTransactions.isEmpty {
                Text("Aucune transaction enregistrée.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
            } else {
                ForEach(allTransactions.prefix(12)) { transaction in
                    HStack(spacing: 12) {
                        Image(systemName: transaction.kind.systemImage)
                            .foregroundStyle(AppTheme.accent)
                            .frame(width: 34, height: 34)
                            .background(AppTheme.accent.opacity(0.1), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(transaction.kind.title) · \(transaction.symbol)")
                                .font(.subheadline.weight(.semibold))
                            Text("\(transaction.portfolio?.name ?? "Portefeuille") · \(transaction.date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        Spacer()
                        Text(transaction.grossAmount.currency(transaction.currencyCode))
                            .font(.subheadline.monospacedDigit())
                    }
                }
            }
        }
        .appCard()
    }

    private func aggregateRate(for portfolio: Portfolio) -> Double {
        if portfolio.currencyCode == aggregateCurrencyCode { return 1 }
        guard portfolio.aggregateFXTargetCurrency == aggregateCurrencyCode,
              portfolio.aggregateFXRate > 0
        else { return 1 }
        return portfolio.aggregateFXRate
    }
}

private struct AggregateHolding: Identifiable {
    var id: String { symbol }
    let symbol: String
    let displayName: String
    var quantity: Double
    let currentPrice: Double
    let previousClose: Double
    let currencyCode: String
    let annualDividendPerShare: Double
    var lastDividendPerShare: Double
    var lastDividendDate: Date?
    var dividendPaymentsLastTwelveMonths: Int
    var fxRateToAggregateCurrency: Double
    var marketValue: Double
    var costBasis: Double
    var previousValue: Double
    var dailyChangeValue: Double
    var annualDividendIncome: Double

    var unrealizedGain: Double { marketValue - costBasis }

    var unrealizedGainPercent: Double {
        guard costBasis > 0 else { return 0 }
        return unrealizedGain / costBasis * 100
    }

    var dividendYieldPercent: Double {
        guard marketValue > 0 else { return 0 }
        return annualDividendIncome / marketValue * 100
    }
}
