import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var marketData: MarketDataStore

    @Query(sort: \Portfolio.createdAt) private var portfolios: [Portfolio]
    @Query(sort: \Holding.symbol) private var holdings: [Holding]
    @Query(sort: \WatchlistItem.addedAt) private var watchlistItems: [WatchlistItem]
    @Query(sort: \TradeTransaction.date, order: .reverse) private var transactions: [TradeTransaction]

    @AppStorage("hideBalances") private var hideBalances = false
    @AppStorage("refreshOnLaunch") private var refreshOnLaunch = true
    @AppStorage("trading212.environment") private var trading212EnvironmentRawValue = Trading212Environment.demo.rawValue
    @AppStorage("trading212.autoSync") private var trading212AutoSync = true
    @State private var trading212SyncInProgress = false

    private var primaryCurrency: String { portfolios.first?.currencyCode ?? "EUR" }
    private var totalValue: Double { portfolios.reduce(0) { $0 + $1.totalValue } }
    private var totalCost: Double { portfolios.reduce(0) { $0 + $1.costBasis } }
    private var totalGain: Double { totalValue - portfolios.reduce(0) { $0 + $1.cashBalance } - totalCost }
    private var dailyGain: Double {
        holdings.reduce(0) {
            $0 + ($1.currentPrice - $1.previousClose) * $1.quantity * $1.fxRateToPortfolioCurrency
        }
    }

    private var dailyGainPercent: Double {
        let previousValue = holdings.reduce(0) {
            $0 + $1.previousClose * $1.quantity * $1.fxRateToPortfolioCurrency
        }
        guard previousValue > 0 else { return 0 }
        return dailyGain / previousValue * 100
    }

    private var estimatedAnnualDividendIncome: Double {
        holdings.reduce(0) { $0 + $1.estimatedAnnualDividendIncome }
    }

    private var portfolioDividendYieldPercent: Double {
        let holdingsValue = holdings.reduce(0) { $0 + $1.marketValueInPortfolioCurrency }
        guard holdingsValue > 0 else { return 0 }
        return estimatedAnnualDividendIncome / holdingsValue * 100
    }

    private var marketDataIsStale: Bool {
        let cutoff = Date.now.addingTimeInterval(-15 * 60)
        let dates = holdings.map(\.lastUpdated) + watchlistItems.map(\.lastUpdated)
        guard !dates.isEmpty else { return false }
        return dates.contains { date in
            guard let date else { return true }
            return date < cutoff
        }
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 18) {
                    heroCard

                    if holdings.isEmpty {
                        EmptyStateView(
                            icon: "chart.pie.fill",
                            title: "Ton portefeuille est prêt",
                            message: "Ajoute une première transaction pour voir la répartition et les performances."
                        )
                        .appCard()
                    } else {
                        allocationCard
                        dividendIncomeCard
                        topMoversCard
                    }

                    recentActivityCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .refreshable { await refreshQuotes() }
        }
        .navigationTitle("Nexa Portfolio")
        .task {
            await synchronizeTrading212IfNeeded()
            if refreshOnLaunch, marketDataIsStale {
                await refreshQuotes()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await synchronizeTrading212IfNeeded()
                if refreshOnLaunch, marketDataIsStale {
                    await refreshQuotes()
                }
            }
        }
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
                .accessibilityLabel("Actualiser les cours")
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

    @MainActor
    private func synchronizeTrading212IfNeeded() async {
        guard trading212AutoSync, !trading212SyncInProgress,
              let environment = Trading212Environment(rawValue: trading212EnvironmentRawValue),
              let credentials = try? Trading212Keychain.load(for: environment)
        else { return }

        let defaults = UserDefaults.standard
        let portfolioKey = "trading212.portfolioID.\(environment.rawValue)"
        let lastSyncKey = "trading212.lastSyncTimestamp.\(environment.rawValue)"
        let lastSyncTimestamp = defaults.double(forKey: lastSyncKey)
        guard Date.now.timeIntervalSince1970 - lastSyncTimestamp >= 15 * 60,
              let portfolioID = defaults.string(forKey: portfolioKey),
              let portfolio = portfolios.first(where: { $0.id.uuidString == portfolioID })
        else { return }
        guard await Trading212SyncGate.shared.acquire() else { return }

        trading212SyncInProgress = true
        defer { trading212SyncInProgress = false }
        do {
            let lastSyncDate = lastSyncTimestamp > 0
                ? Date(timeIntervalSince1970: lastSyncTimestamp)
                : nil
            let snapshot = try await Trading212Client(
                environment: environment,
                credentials: credentials
            ).snapshot(since: lastSyncDate)
            _ = try await Trading212Importer.synchronize(
                snapshot: snapshot,
                environment: environment,
                into: portfolio,
                context: modelContext
            )
            defaults.set(Date.now.timeIntervalSince1970, forKey: lastSyncKey)
            await Trading212SyncGate.shared.release()
        } catch {
            await Trading212SyncGate.shared.release()
            // Une synchronisation manuelle dans Réglages affichera le détail de l’erreur.
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Valeur totale", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
                ChangeBadge(value: dailyGainPercent)
            }

            Text(hideBalances ? "••••••" : totalValue.currency(primaryCurrency))
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .contentTransition(.numericText())

            HStack(spacing: 24) {
                metric(title: "Aujourd’hui", value: dailyGain, color: dailyGain >= 0 ? AppTheme.positive : AppTheme.negative)
                metric(title: "Non réalisé", value: totalGain, color: totalGain >= 0 ? AppTheme.positive : AppTheme.negative)
            }
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.10, green: 0.25, blue: 0.31), AppTheme.card],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(AppTheme.accent.opacity(0.14))
                        .frame(width: 170, height: 170)
                        .blur(radius: 10)
                        .offset(x: 55, y: -65)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(AppTheme.accent.opacity(0.18), lineWidth: 1)
        }
    }

    private func metric(title: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
            Text(hideBalances ? "••••" : value.currency(primaryCurrency))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(color)
        }
    }

    private var allocationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Répartition")
                .font(.headline)

            HStack(spacing: 20) {
                Chart(holdings.prefix(8)) { holding in
                    SectorMark(
                        angle: .value("Valeur", holding.marketValueInPortfolioCurrency),
                        innerRadius: .ratio(0.68),
                        angularInset: 2
                    )
                    .cornerRadius(4)
                    .foregroundStyle(by: .value("Symbole", holding.symbol))
                }
                .chartLegend(.hidden)
                .frame(width: 126, height: 126)

                VStack(spacing: 10) {
                    ForEach(Array(holdings.sorted { $0.marketValue > $1.marketValue }.prefix(4).enumerated()), id: \.element.id) { index, holding in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(AppTheme.allocationColors[index % AppTheme.allocationColors.count])
                                .frame(width: 8, height: 8)
                            Text(holding.symbol)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(totalValue > 0 ? holding.marketValueInPortfolioCurrency / totalValue : 0, format: .percent.precision(.fractionLength(1)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                }
            }
        }
        .appCard()
    }

    private var topMoversCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Positions")
                .font(.headline)

            ForEach(holdings.sorted { abs($0.dailyChangePercent) > abs($1.dailyChangePercent) }.prefix(4)) { holding in
                HStack(spacing: 12) {
                    SymbolBadge(symbol: holding.symbol)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(holding.symbol)
                            .font(.subheadline.weight(.bold))
                        Text(holding.displayName)
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                        if holding.dividendYieldPercent > 0 {
                            Text("Div. \(holding.dividendYieldPercent / 100, format: .percent.precision(.fractionLength(2)))")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(holding.currentPrice.currency(holding.currencyCode))
                            .font(.subheadline.weight(.semibold))
                        Text(holding.dailyChangePercent / 100, format: .percent.precision(.fractionLength(2)))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(holding.dailyChangePercent >= 0 ? AppTheme.positive : AppTheme.negative)
                    }
                }
            }
        }
        .appCard()
    }

    private var dividendIncomeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Revenus de dividendes", systemImage: "banknote.fill")
                    .font(.headline)
                Spacer()
                DividendBadge(yieldPercent: portfolioDividendYieldPercent)
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Estimation annuelle")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(estimatedAnnualDividendIncome.currency(primaryCurrency))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.positive)
                }
                Spacer()
                Text("12 derniers mois")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            let dividendHoldings = holdings
                .filter { $0.dividendYieldPercent > 0 }
                .sorted { $0.estimatedAnnualDividendIncome > $1.estimatedAnnualDividendIncome }

            if dividendHoldings.isEmpty {
                Text("Aucun dividende détecté dans tes positions.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
            } else {
                ForEach(dividendHoldings.prefix(3)) { holding in
                    HStack {
                        Text(holding.symbol)
                            .font(.subheadline.weight(.bold))
                        Text(holding.dividendYieldPercent / 100, format: .percent.precision(.fractionLength(2)))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.accent)
                        Spacer()
                        Text(holding.estimatedAnnualDividendIncome.currency(holding.portfolio?.currencyCode ?? primaryCurrency))
                            .font(.subheadline.monospacedDigit())
                    }
                }
            }
        }
        .appCard()
    }

    private var recentActivityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Activité récente")
                .font(.headline)

            if transactions.isEmpty {
                Text("Aucune transaction enregistrée.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.vertical, 10)
            } else {
                ForEach(transactions.prefix(5)) { transaction in
                    HStack(spacing: 12) {
                        Image(systemName: transaction.kind.systemImage)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AppTheme.accent)
                            .frame(width: 36, height: 36)
                            .background(AppTheme.accent.opacity(0.1), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(transaction.kind.title) · \(transaction.symbol)")
                                .font(.subheadline.weight(.semibold))
                            Text(transaction.date, format: .dateTime.day().month(.abbreviated).year())
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

    private func refreshQuotes() async {
        await marketData.refresh(holdings: holdings, watchlistItems: watchlistItems, context: modelContext)
    }
}
