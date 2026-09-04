import SwiftUI
import SwiftData

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

struct DividendsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var marketData: MarketDataStore

    @Query(sort: \Holding.symbol) private var holdings: [Holding]
    @Query(sort: \WatchlistItem.addedAt) private var watchlistItems: [WatchlistItem]

    @AppStorage("hideBalances") private var hideBalances = false

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

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 14) {
                    introductionCard

                    if upcomingDividends.isEmpty {
                        EmptyStateView(
                            icon: "calendar.badge.clock",
                            title: "Aucun dividende à venir",
                            message: "Actualise les cours pour rechercher les prochaines dates de tes positions."
                        )
                        .appCard()
                    } else {
                        ForEach(upcomingDividends) { dividend in
                            dividendCard(dividend)
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
