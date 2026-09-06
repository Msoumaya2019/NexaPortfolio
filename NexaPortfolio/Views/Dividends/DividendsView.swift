import SwiftUI
import SwiftData
import Charts

private enum DividendHistoryPeriod: String, CaseIterable, Identifiable {
    case oneMonth
    case sixMonths
    case twelveMonths

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneMonth: "1 mois"
        case .sixMonths: "6 mois"
        case .twelveMonths: "12 mois"
        }
    }

    var startDate: Date {
        let months: Int
        switch self {
        case .oneMonth: months = -1
        case .sixMonths: months = -6
        case .twelveMonths: months = -12
        }
        return Calendar.current.date(byAdding: .month, value: months, to: .now) ?? .distantPast
    }
}

private struct UpcomingDividend: Identifiable {
    let holding: Holding
    let date: Date

    var id: UUID { holding.id }

    var estimatedPerShare: Double {
        if holding.lastDividendPerShare > 0 {
            return holding.lastDividendPerShare
        }
        guard holding.dividendPaymentsLastTwelveMonths > 0 else { return 0 }
        return holding.annualDividendPerShare / Double(holding.dividendPaymentsLastTwelveMonths)
    }

    var estimatedAmount: Double {
        estimatedPerShare * holding.quantity * holding.fxRateToPortfolioCurrency
    }

    var portfolioCurrencyCode: String {
        holding.portfolio?.currencyCode ?? holding.currencyCode
    }
}

private struct DividendCurrencyTotal: Identifiable {
    let currencyCode: String
    let amount: Double

    var id: String { currencyCode }
}

private struct DividendChartPoint: Identifiable {
    let month: Date
    let amount: Double
    let series: String

    var id: String {
        "\(Int(month.timeIntervalSince1970))-\(series)"
    }
}

private struct DividendChartSection: Identifiable {
    let currencyCode: String
    let points: [DividendChartPoint]
    let currentTotal: Double
    let previousTotal: Double

    var id: String { currencyCode }

    var changePercent: Double? {
        guard previousTotal != 0 else { return nil }
        return (currentTotal - previousTotal) / abs(previousTotal) * 100
    }
}

private struct DividendMonthSection: Identifiable {
    let monthStart: Date
    let dividends: [UpcomingDividend]

    var id: Date { monthStart }

    var totals: [DividendCurrencyTotal] {
        Dictionary(grouping: dividends, by: \.portfolioCurrencyCode)
            .map { currencyCode, dividends in
                DividendCurrencyTotal(
                    currencyCode: currencyCode,
                    amount: dividends.reduce(0) { $0 + $1.estimatedAmount }
                )
            }
            .sorted { $0.currencyCode < $1.currencyCode }
    }
}

struct DividendsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var marketData: MarketDataStore

    @Query(sort: \Holding.symbol) private var holdings: [Holding]
    @Query(sort: \WatchlistItem.addedAt) private var watchlistItems: [WatchlistItem]
    @Query(sort: \TradeTransaction.date, order: .reverse) private var transactions: [TradeTransaction]

    @AppStorage("hideBalances") private var hideBalances = false
    @AppStorage("dividends.historyPeriod") private var historyPeriodRawValue = DividendHistoryPeriod.sixMonths.rawValue

    private var historyPeriod: DividendHistoryPeriod {
        DividendHistoryPeriod(rawValue: historyPeriodRawValue) ?? .sixMonths
    }

    private var recordedDividendTransactions: [TradeTransaction] {
        transactions.filter { $0.kind == .dividend && $0.date <= .now && $0.grossAmount != 0 }
    }

    private var transactionsInSelectedPeriod: [TradeTransaction] {
        recordedDividendTransactions.filter { $0.date >= historyPeriod.startDate }
    }

    private var receivedPaymentCount: Int {
        transactionsInSelectedPeriod.filter { $0.grossAmount > 0 }.count
    }

    private var receivedTotals: [DividendCurrencyTotal] {
        Dictionary(grouping: transactionsInSelectedPeriod, by: \.currencyCode)
            .map { currencyCode, transactions in
                DividendCurrencyTotal(
                    currencyCode: currencyCode,
                    amount: transactions.reduce(0) { $0 + $1.grossAmount - $1.fees }
                )
            }
            .sorted { $0.currencyCode < $1.currencyCode }
    }

    private var recentReceivedDividends: [TradeTransaction] {
        Array(recordedDividendTransactions.filter { $0.grossAmount > 0 }.prefix(10))
    }

    private var dividendChartSections: [DividendChartSection] {
        let calendar = Calendar.current
        let now = Date.now
        guard let currentMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now)
        ) else { return [] }

        let months = (0..<12).compactMap { offset in
            calendar.date(byAdding: .month, value: offset - 11, to: currentMonth)
        }
        let currencies = Set(recordedDividendTransactions.map { $0.currencyCode.uppercased() })

        return currencies.sorted().map { currencyCode in
            var points: [DividendChartPoint] = []
            var currentTotal = 0.0
            var previousTotal = 0.0

            for month in months {
                let currentAmount = recordedAmount(
                    currencyCode: currencyCode,
                    month: month,
                    upperBound: month == currentMonth ? now : nil
                )
                let previousMonth = calendar.date(byAdding: .year, value: -1, to: month) ?? month
                let previousUpperBound = month == currentMonth
                    ? calendar.date(byAdding: .year, value: -1, to: now)
                    : nil
                let previousAmount = recordedAmount(
                    currencyCode: currencyCode,
                    month: previousMonth,
                    upperBound: previousUpperBound
                )

                currentTotal += currentAmount
                previousTotal += previousAmount
                points.append(DividendChartPoint(
                    month: month,
                    amount: currentAmount,
                    series: "12 mois récents"
                ))
                points.append(DividendChartPoint(
                    month: month,
                    amount: previousAmount,
                    series: "N-1"
                ))
            }

            return DividendChartSection(
                currencyCode: currencyCode,
                points: points,
                currentTotal: currentTotal,
                previousTotal: previousTotal
            )
        }
        .filter { section in
            section.points.contains { point in point.amount != 0 }
        }
    }

    private var upcomingDividends: [UpcomingDividend] {
        let startOfToday = Calendar.current.startOfDay(for: .now)
        return holdings.compactMap { holding in
            guard holding.quantity > 0,
                  let date = holding.nextDividendDate,
                  date >= startOfToday
            else { return nil }
            return UpcomingDividend(holding: holding, date: date)
        }
        .sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            let symbolComparison = lhs.holding.symbol.localizedCaseInsensitiveCompare(rhs.holding.symbol)
            if symbolComparison != .orderedSame { return symbolComparison == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private var monthSections: [DividendMonthSection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: upcomingDividends) { dividend in
            calendar.date(
                from: calendar.dateComponents([.year, .month], from: dividend.date)
            ) ?? calendar.startOfDay(for: dividend.date)
        }
        return grouped.keys.sorted().compactMap { monthStart in
            guard let dividends = grouped[monthStart] else { return nil }
            return DividendMonthSection(monthStart: monthStart, dividends: dividends)
        }
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 14) {
                    receivedSummaryCard
                    if dividendChartSections.isEmpty {
                        emptyDividendChartCard
                    } else {
                        ForEach(dividendChartSections) { section in
                            dividendChartCard(section)
                        }
                    }
                    recentReceivedCard
                    introductionCard

                    if upcomingDividends.isEmpty {
                        EmptyStateView(
                            icon: "calendar.badge.clock",
                            title: "Aucun dividende à venir",
                            message: "Actualise les cours pour rechercher les prochaines dates de tes positions."
                        )
                        .appCard()
                    } else {
                        ForEach(monthSections) { section in
                            monthHeader(section)
                            ForEach(section.dividends) { dividend in
                                dividendCard(dividend)
                            }
                        }
                    }

                    Text("Les dates peuvent être annoncées ou estimées à partir de la cadence des versements récents. Les montants utilisent le dernier dividende connu et restent indicatifs.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .refreshable { await refreshQuotes() }
        }
        .navigationTitle("Dividendes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    hideBalances.toggle()
                } label: {
                    Image(systemName: hideBalances ? "eye.slash" : "eye")
                }
                .accessibilityLabel(hideBalances ? "Afficher les montants" : "Masquer les montants")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refreshQuotes() }
                } label: {
                    if marketData.isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(marketData.isRefreshing)
                .accessibilityLabel("Actualiser les dividendes")
            }
        }
        .alert("Actualisation", isPresented: Binding(
            get: { marketData.errorMessage != nil },
            set: { if !$0 { marketData.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { marketData.errorMessage = nil }
        } message: {
            Text(marketData.errorMessage ?? "")
        }
    }

    private var introductionCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 54, height: 54)
                .background(AppTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Prochains dividendes")
                    .font(.headline)
                Text("\(upcomingDividends.count) versement\(upcomingDividends.count > 1 ? "s" : "") estimé\(upcomingDividends.count > 1 ? "s" : ""), classé\(upcomingDividends.count > 1 ? "s" : "") par date")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            Spacer()
        }
        .appCard()
    }

    private var receivedSummaryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Dividendes reçus", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                Spacer()
                Text("Période glissante")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Picker("Période des dividendes reçus", selection: $historyPeriodRawValue) {
                ForEach(DividendHistoryPeriod.allCases) { period in
                    Text(period.title).tag(period.rawValue)
                }
            }
            .pickerStyle(.segmented)

            if receivedTotals.isEmpty {
                Text("Aucun dividende enregistré sur cette période.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 9) {
                    ForEach(receivedTotals) { total in
                        HStack(alignment: .firstTextBaseline) {
                            Text("Montant reçu")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                            Spacer()
                            Text(hideBalances ? "••••" : total.amount.currency(total.currencyCode))
                                .font(.title2.weight(.bold))
                                .foregroundStyle(total.amount >= 0 ? AppTheme.positive : AppTheme.negative)
                        }
                    }
                }

                HStack {
                    Label(
                        "\(receivedPaymentCount) versement\(receivedPaymentCount > 1 ? "s" : "")",
                        systemImage: "banknote"
                    )
                    Spacer()
                    Text(historyPeriod.title)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
            }

            Text("Les annulations, retenues ou corrections fiscales enregistrées comme dividendes sont déduites du total.")
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .appCard()
    }

    private var recentReceivedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("10 derniers dividendes reçus")
                    .font(.headline)
                Spacer()
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(AppTheme.accent)
            }

            if recentReceivedDividends.isEmpty {
                Text("Aucun dividende reçu n’est encore enregistré.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(recentReceivedDividends.enumerated()), id: \.element.id) { index, transaction in
                    receivedDividendRow(transaction)
                    if index < recentReceivedDividends.count - 1 {
                        Divider().overlay(AppTheme.border)
                    }
                }
            }
        }
        .appCard()
    }

    private var emptyDividendChartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Évolution mensuelle", systemImage: "chart.bar.xaxis")
                .font(.headline)
            Text("Le graphique apparaîtra après l’enregistrement ou l’import de dividendes.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    private func dividendChartCard(_ section: DividendChartSection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Évolution mensuelle", systemImage: "chart.bar.xaxis")
                        .font(.headline)
                    Text("12 derniers mois comparés à N-1 · \(section.currencyCode)")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer()
                if let changePercent = section.changePercent {
                    ChangeBadge(value: changePercent)
                } else {
                    Text("N-1 indisponible")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }

            HStack(spacing: 22) {
                chartTotal(
                    title: "12 mois récents",
                    amount: section.currentTotal,
                    currencyCode: section.currencyCode,
                    color: AppTheme.accent
                )
                chartTotal(
                    title: "N-1",
                    amount: section.previousTotal,
                    currencyCode: section.currencyCode,
                    color: AppTheme.accentBlue
                )
            }

            if hideBalances {
                Label("Graphique masqué", systemImage: "eye.slash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 190)
                    .background(AppTheme.raisedCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Chart(section.points) { point in
                    BarMark(
                        x: .value("Mois", point.month, unit: .month),
                        y: .value("Dividendes", point.amount)
                    )
                    .position(by: .value("Période", point.series))
                    .foregroundStyle(by: .value("Période", point.series))
                    .cornerRadius(3)
                }
                .chartForegroundStyleScale([
                    "12 mois récents": AppTheme.accent,
                    "N-1": AppTheme.accentBlue
                ])
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month, count: 2)) { value in
                        AxisGridLine().foregroundStyle(AppTheme.border)
                        AxisTick().foregroundStyle(AppTheme.secondaryText)
                        AxisValueLabel(format: .dateTime.month(.narrow))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(AppTheme.border)
                        AxisValueLabel()
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
                .frame(height: 220)
                .accessibilityLabel("Dividendes mensuels des douze derniers mois comparés à l’année précédente en \(section.currencyCode)")
            }

            Text("Le mois en cours est comparé à la même période du mois correspondant de N-1.")
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .appCard()
    }

    private func chartTotal(title: String, amount: Double, currencyCode: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText)
            Text(hideBalances ? "••••" : amount.currency(currencyCode))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(color)
        }
    }

    private func recordedAmount(currencyCode: String, month: Date, upperBound: Date?) -> Double {
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .month, value: 1, to: month) else { return 0 }
        return recordedDividendTransactions.reduce(0) { total, transaction in
            guard transaction.currencyCode.uppercased() == currencyCode,
                  transaction.date >= month,
                  transaction.date < end,
                  upperBound.map({ transaction.date <= $0 }) ?? true
            else { return total }
            return total + transaction.grossAmount - transaction.fees
        }
    }

    private func receivedDividendRow(_ transaction: TradeTransaction) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "banknote.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.positive)
                .frame(width: 38, height: 38)
                .background(AppTheme.positive.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.symbol)
                    .font(.subheadline.weight(.bold))
                Text(transaction.displayName)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                Text("\(transaction.date.formatted(.dateTime.day().month(.abbreviated).year())) · \(transaction.portfolio?.name ?? "Portefeuille")")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Text(hideBalances ? "••••" : (transaction.grossAmount - transaction.fees).currency(transaction.currencyCode))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.positive)
        }
    }

    private func monthHeader(_ section: DividendMonthSection) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(section.monthStart.formatted(.dateTime.month(.wide).year()).capitalized)
                    .font(.title3.weight(.bold))
                Text("\(section.dividends.count) dividende\(section.dividends.count > 1 ? "s" : "") prévu\(section.dividends.count > 1 ? "s" : "")")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("Total prévu")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText)
                ForEach(section.totals) { total in
                    Text(hideBalances ? "••••" : total.amount.currency(total.currencyCode))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppTheme.positive)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
    }

    private func dividendCard(_ dividend: UpcomingDividend) -> some View {
        NavigationLink {
            SecurityDetailView(
                symbol: dividend.holding.symbol,
                displayName: dividend.holding.displayName,
                currentPrice: dividend.holding.currentPrice,
                previousClose: dividend.holding.previousClose,
                currencyCode: dividend.holding.currencyCode,
                annualDividendPerShare: dividend.holding.annualDividendPerShare,
                dividendYieldPercent: dividend.holding.dividendYieldPercent,
                lastDividendPerShare: dividend.holding.lastDividendPerShare,
                lastDividendDate: dividend.holding.lastDividendDate,
                nextDividendDate: dividend.holding.nextDividendDate,
                nextDividendDateIsEstimated: dividend.holding.nextDividendDateIsEstimated,
                dividendPaymentsLastTwelveMonths: dividend.holding.dividendPaymentsLastTwelveMonths,
                quantity: dividend.holding.quantity,
                fxRateToPortfolioCurrency: dividend.holding.fxRateToPortfolioCurrency,
                portfolioCurrencyCode: dividend.portfolioCurrencyCode,
                averagePurchasePrice: dividend.holding.purchasePrice
            )
        } label: {
            HStack(spacing: 14) {
                VStack(spacing: 1) {
                    Text(dividend.date.formatted(.dateTime.day()))
                        .font(.title2.weight(.bold))
                    Text(dividend.date.formatted(.dateTime.month(.abbreviated)))
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                }
                .foregroundStyle(AppTheme.accent)
                .frame(width: 52, height: 58)
                .background(AppTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(dividend.holding.symbol)
                            .font(.headline)
                        Text(dividend.holding.nextDividendDateIsEstimated ? "DATE ESTIMÉE" : "DATE ANNONCÉE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(dividend.holding.nextDividendDateIsEstimated ? AppTheme.accent : AppTheme.positive)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                (dividend.holding.nextDividendDateIsEstimated ? AppTheme.accent : AppTheme.positive).opacity(0.11),
                                in: Capsule()
                            )
                    }
                    Text(dividend.holding.displayName)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                    Text("\(dividend.holding.portfolio?.name ?? "Portefeuille") · \(dividend.holding.quantity.formatted(.number.precision(.fractionLength(0...4)))) actions")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(
                        hideBalances
                            ? "••••"
                            : dividend.estimatedPerShare > 0
                                ? dividend.estimatedAmount.currency(dividend.portfolioCurrencyCode)
                                : "—"
                    )
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppTheme.positive)
                    if dividend.estimatedPerShare > 0 {
                        Text("≈ \(dividend.estimatedPerShare.currency(dividend.holding.currencyCode))/action")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.secondaryText)
                    } else {
                        Text("Montant indisponible")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appCard()
    }

    @MainActor
    private func refreshQuotes() async {
        await marketData.refresh(
            holdings: holdings,
            watchlistItems: watchlistItems,
            context: modelContext
        )
    }
}
