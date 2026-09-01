import SwiftUI
import SwiftData

struct PortfolioView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Portfolio.createdAt) private var portfolios: [Portfolio]

    @State private var selectedPortfolioID: UUID?
    @State private var showingAddTrade = false
    @State private var showingNewPortfolio = false
    @State private var showingDeleteConfirmation = false
    @State private var errorMessage: String?

    private var selectedPortfolio: Portfolio? {
        portfolios.first { $0.id == selectedPortfolioID } ?? portfolios.first
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            if let portfolio = selectedPortfolio {
                ScrollView {
                    LazyVStack(spacing: 18) {
                        portfolioSelector(portfolio)
                        summaryCard(portfolio)
                        holdingsCard(portfolio)
                        transactionsCard(portfolio)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 30)
                }
            } else {
                EmptyStateView(
                    icon: "briefcase",
                    title: "Aucun portefeuille",
                    message: "Crée un portefeuille pour commencer."
                )
            }
        }
        .navigationTitle("Portefeuille")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingNewPortfolio = true
                    } label: {
                        Label("Nouveau portefeuille", systemImage: "folder.badge.plus")
                    }

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Supprimer ce portefeuille", systemImage: "trash")
                    }
                    .disabled(portfolios.count <= 1)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddTrade = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(selectedPortfolio == nil)
                .accessibilityLabel("Ajouter une transaction")
            }
        }
        .task {
            if selectedPortfolioID == nil { selectedPortfolioID = portfolios.first?.id }
        }
        .onChange(of: portfolios.count) {
            if selectedPortfolio == nil { selectedPortfolioID = portfolios.first?.id }
        }
        .sheet(isPresented: $showingAddTrade) {
            if let portfolio = selectedPortfolio {
                AddTradeSheet(portfolio: portfolio)
            }
        }
        .sheet(isPresented: $showingNewPortfolio) {
            NewPortfolioSheet { portfolio in
                selectedPortfolioID = portfolio.id
            }
        }
        .confirmationDialog(
            "Supprimer « \(selectedPortfolio?.name ?? "") » ?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Supprimer le portefeuille et ses données", role: .destructive) {
                deleteSelectedPortfolio()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Cette action supprime aussi ses positions et transactions.")
        }
        .alert("Erreur", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func portfolioSelector(_ portfolio: Portfolio) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Portefeuille actif")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                Text(portfolio.name)
                    .font(.title3.weight(.bold))
            }
            Spacer()
            Menu {
                ForEach(portfolios) { item in
                    Button {
                        selectedPortfolioID = item.id
                    } label: {
                        if item.id == portfolio.id {
                            Label(item.name, systemImage: "checkmark")
                        } else {
                            Text(item.name)
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(10)
                    .background(AppTheme.accent.opacity(0.1), in: Circle())
            }
        }
    }

    private func summaryCard(_ portfolio: Portfolio) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Valeur actuelle")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(portfolio.totalValue.currency(portfolio.currencyCode))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                }
                Spacer()
                ChangeBadge(value: portfolio.unrealizedGainPercent)
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack {
                summaryMetric("Investi", portfolio.costBasis.currency(portfolio.currencyCode))
                Spacer()
                summaryMetric("Liquidités", portfolio.cashBalance.currency(portfolio.currencyCode))
                Spacer()
                summaryMetric(
                    "Gain/perte",
                    portfolio.unrealizedGain.currency(portfolio.currencyCode),
                    color: portfolio.unrealizedGain >= 0 ? AppTheme.positive : AppTheme.negative
                )
            }
        }
        .appCard()
    }

    private func summaryMetric(_ title: String, _ value: String, color: Color = .white) -> some View {
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

    private func holdingsCard(_ portfolio: Portfolio) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Positions")
                    .font(.headline)
                Spacer()
                Text("\(portfolio.holdings.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(AppTheme.accent.opacity(0.1), in: Capsule())
            }

            if portfolio.holdings.isEmpty {
                EmptyStateView(
                    icon: "plus.forwardslash.minus",
                    title: "Aucune position",
                    message: "Touche + pour enregistrer ton premier achat."
                )
            } else {
                ForEach(portfolio.holdings.sorted { $0.marketValue > $1.marketValue }) { holding in
                    holdingRow(holding)
                    if holding.id != portfolio.holdings.sorted(by: { $0.marketValue > $1.marketValue }).last?.id {
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                }
            }
        }
        .appCard()
    }

    private func holdingRow(_ holding: Holding) -> some View {
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
                fxRateToPortfolioCurrency: holding.fxRateToPortfolioCurrency,
                portfolioCurrencyCode: holding.portfolio?.currencyCode
            )
        } label: {
            HStack(spacing: 12) {
                SymbolBadge(symbol: holding.symbol)
                VStack(alignment: .leading, spacing: 5) {
                    Text(holding.symbol)
                        .font(.subheadline.weight(.bold))
                    Text("\(holding.quantity.formatted(.number.precision(.fractionLength(0...4)))) titres")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    DividendBadge(yieldPercent: holding.dividendYieldPercent)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(holding.marketValue.currency(holding.currencyCode))
                        .font(.subheadline.weight(.semibold))
                    Text(holding.unrealizedGainPercent / 100, format: .percent.precision(.fractionLength(2)))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(holding.unrealizedGainPercent >= 0 ? AppTheme.positive : AppTheme.negative)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func transactionsCard(_ portfolio: Portfolio) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Historique")
                .font(.headline)

            if portfolio.transactions.isEmpty {
                Text("Les achats, ventes et dividendes apparaîtront ici.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.vertical, 12)
            } else {
                ForEach(portfolio.transactions.sorted { $0.date > $1.date }) { transaction in
                    HStack(spacing: 12) {
                        Image(systemName: transaction.kind.systemImage)
                            .foregroundStyle(AppTheme.accent)
                            .frame(width: 34, height: 34)
                            .background(AppTheme.accent.opacity(0.1), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(transaction.kind.title) · \(transaction.symbol)")
                                .font(.subheadline.weight(.semibold))
                            Text(transaction.date, format: .dateTime.day().month(.abbreviated).year())
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(transaction.grossAmount.currency(transaction.currencyCode))
                                .font(.subheadline.monospacedDigit())
                            Menu {
                                Button("Supprimer", systemImage: "trash", role: .destructive) {
                                    delete(transaction)
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .frame(width: 30, height: 22)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .appCard()
    }

    private func delete(_ transaction: TradeTransaction) {
        do {
            try PortfolioLedger.deleteTransaction(transaction, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSelectedPortfolio() {
        guard portfolios.count > 1, let portfolio = selectedPortfolio else { return }
        modelContext.delete(portfolio)
        do {
            try modelContext.save()
            selectedPortfolioID = portfolios.first { $0.id != portfolio.id }?.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct NewPortfolioSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let onCreate: (Portfolio) -> Void

    @State private var name = ""
    @State private var currencyCode = "EUR"
    @State private var cashBalance = "0"

    private let currencies = ["EUR", "USD", "GBP", "CHF", "CAD", "JPY"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Portefeuille") {
                    TextField("Nom", text: $name)
                    Picker("Devise", selection: $currencyCode) {
                        ForEach(currencies, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Liquidités initiales", text: $cashBalance)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle("Nouveau portefeuille")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") { createPortfolio() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func createPortfolio() {
        let cash = Double(cashBalance.replacingOccurrences(of: ",", with: ".")) ?? 0
        let portfolio = Portfolio(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            currencyCode: currencyCode,
            cashBalance: cash
        )
        modelContext.insert(portfolio)
        try? modelContext.save()
        onCreate(portfolio)
        dismiss()
    }
}
