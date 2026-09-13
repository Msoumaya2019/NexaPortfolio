import SwiftUI
import SwiftData

struct PortfolioView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var marketData: MarketDataStore
    @Query(sort: \Portfolio.createdAt) private var portfolios: [Portfolio]

    @AppStorage("portfolio.performancePeriod") private var performancePeriodRawValue = PortfolioPerformancePeriod.oneDay.rawValue
    @State private var selectedPortfolioID: UUID?
    @State private var showingAddTrade = false
    @State private var showingNewPortfolio = false
    @State private var showingDeleteConfirmation = false
    @State private var errorMessage: String?
    @State private var editingHolding: Holding?
    @State private var historicalPerformance: PortfolioPerformanceSnapshot?
    @State private var isLoadingPerformance = false

    private var selectedPortfolio: Portfolio? {
        portfolios.first { $0.id == selectedPortfolioID } ?? portfolios.first
    }

    private var selectedPerformancePeriod: PortfolioPerformancePeriod {
        PortfolioPerformancePeriod(rawValue: performancePeriodRawValue) ?? .oneDay
    }

    private var performanceTaskID: String {
        guard let portfolio = selectedPortfolio else { return "aucun-\(performancePeriodRawValue)" }
        let positionSignature = portfolio.holdings.reduce(0) {
            $0 + $1.currentPrice + $1.quantity + $1.purchasePrice
        }
        return "\(portfolio.id.uuidString)-\(performancePeriodRawValue)-\(portfolio.transactions.count)-\(positionSignature)"
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            if let portfolio = selectedPortfolio {
                ScrollView {
                    LazyVStack(spacing: 18) {
                        portfolioSelector(portfolio)
                        summaryCard(portfolio)
                        portfolioDividendCard(portfolio)
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
        .task(id: performanceTaskID) {
            await loadSelectedPortfolioPerformance()
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
        .sheet(item: $editingHolding) { holding in
            PurchasePriceEditor(holding: holding)
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
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Valeur actuelle")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(portfolio.totalValue.currency(portfolio.currencyCode))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                }
                Spacer()
                performanceSelection(for: portfolio)
            }

            Divider().overlay(AppTheme.border)

            HStack {
                summaryMetric("Investi", portfolio.costBasis.currency(portfolio.currencyCode))
                Spacer()
                summaryMetric("Liquidités", portfolio.cashBalance.currency(portfolio.currencyCode))
                Spacer()
                summaryMetric(
                    "Non réalisé",
                    portfolio.unrealizedGain.currency(portfolio.currencyCode),
                    color: portfolio.unrealizedGain >= 0 ? AppTheme.positive : AppTheme.negative
                )
            }
        }
        .appCard()
    }

    private func summaryMetric(_ title: String, _ value: String, color: Color = AppTheme.primaryText) -> some View {
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

    private func displayedPerformance(for portfolio: Portfolio) -> PortfolioPerformanceSnapshot? {
        historicalPerformance
    }

    private func performanceSelection(for portfolio: Portfolio) -> some View {
        HStack(spacing: 6) {
            if isLoadingPerformance {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 62)
            } else if let performance = displayedPerformance(for: portfolio) {
                ChangeBadge(value: performance.percent)
            } else {
                Text("—")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(AppTheme.secondaryText.opacity(0.09), in: Capsule())
            }
            PerformancePeriodMenu(selection: $performancePeriodRawValue)
        }
    }

    @MainActor
    private func loadSelectedPortfolioPerformance() async {
        guard let portfolio = selectedPortfolio else {
            historicalPerformance = nil
            isLoadingPerformance = false
            return
        }

        isLoadingPerformance = true
        defer { isLoadingPerformance = false }
        historicalPerformance = await marketData.performance(
            holdings: portfolio.holdings,
            transactions: portfolio.transactions,
            portfolioCurrencyCode: portfolio.currencyCode,
            since: selectedPerformancePeriod.startDate
        )
    }

    private func portfolioDividendCard(_ portfolio: Portfolio) -> some View {
        let annualIncome = portfolio.holdings.reduce(0) { $0 + $1.estimatedAnnualDividendIncome }
        let monthlyAverage = annualIncome / 12
        let yieldPercent = portfolio.holdingsValue > 0
            ? annualIncome / portfolio.holdingsValue * 100
            : 0
        let dividendHoldings = portfolio.holdings
            .filter { $0.dividendYieldPercent > 0 }
            .sorted { $0.estimatedAnnualDividendIncome > $1.estimatedAnnualDividendIncome }

        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Dividendes du portefeuille", systemImage: "banknote.fill")
                    .font(.headline)
                Spacer()
                DividendBadge(yieldPercent: yieldPercent)
            }

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Estimation annuelle")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(annualIncome.currency(portfolio.currencyCode))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(AppTheme.positive)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Moyenne mensuelle")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(monthlyAverage.currency(portfolio.currencyCode))
                        .font(.subheadline.weight(.bold))
                }
            }

            if dividendHoldings.isEmpty {
                Text("Aucun dividende détecté dans ce portefeuille sur les douze derniers mois.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
            } else {
                Divider().overlay(AppTheme.border)

                ForEach(dividendHoldings.prefix(4)) { holding in
                    HStack {
                        Text(holding.symbol)
                            .font(.subheadline.weight(.bold))
                        Text(holding.dividendYieldPercent / 100, format: .percent.precision(.fractionLength(2)))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.accent)
                        Spacer()
                        Text(holding.estimatedAnnualDividendIncome.currency(portfolio.currencyCode))
                            .font(.subheadline.monospacedDigit())
                    }
                }
            }
        }
        .appCard()
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
                        Divider().overlay(AppTheme.border)
                    }
                }
            }
        }
        .appCard()
    }

    private func holdingRow(_ holding: Holding) -> some View {
        HStack(spacing: 8) {
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
                    nextDividendDate: holding.nextDividendDate,
                    nextDividendDateIsEstimated: holding.nextDividendDateIsEstimated,
                    dividendPaymentsLastTwelveMonths: holding.dividendPaymentsLastTwelveMonths,
                    quantity: holding.quantity,
                    fxRateToPortfolioCurrency: holding.fxRateToPortfolioCurrency,
                    portfolioCurrencyCode: holding.portfolio?.currencyCode,
                    averagePurchasePrice: holding.purchasePrice
                )
            } label: {
                HStack(spacing: 12) {
                    SymbolBadge(symbol: holding.symbol)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(holding.displayName)
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                        Text("\(holding.symbol) · \(holding.quantity.formatted(.number.precision(.fractionLength(0...4)))) titres · PRU \(holding.purchasePrice.currency(holding.currencyCode))")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                        DividendBadge(yieldPercent: holding.dividendYieldPercent)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(holding.marketValue.currency(holding.currencyCode))
                            .font(.subheadline.weight(.semibold))
                        Text(holding.unrealizedGainPercent / 100, format: .percent.precision(.fractionLength(2)))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(holding.unrealizedGainPercent >= 0 ? AppTheme.positive : AppTheme.negative)
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                editingHolding = holding
            } label: {
                Image(systemName: "pencil.circle")
                    .font(.title3)
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 34, height: 42)
            }
            .accessibilityLabel("Modifier la position \(holding.symbol)")
        }
    }

    private func transactionsCard(_ portfolio: Portfolio) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Historique")
                    .font(.headline)
                Spacer()
                if portfolio.transactions.count > 20 {
                    Text("20 dernières")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }

            if portfolio.transactions.isEmpty {
                Text("Les achats, ventes et dividendes apparaîtront ici.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.vertical, 12)
            } else {
                ForEach(portfolio.transactions.sorted { $0.date > $1.date }.prefix(20)) { transaction in
                    HStack(spacing: 12) {
                        Image(systemName: transaction.kind.systemImage)
                            .foregroundStyle(AppTheme.accent)
                            .frame(width: 34, height: 34)
                            .background(AppTheme.accent.opacity(0.1), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(transaction.kind.title) · \(transaction.symbol)")
                                .font(.subheadline.weight(.semibold))
                            HStack(spacing: 5) {
                                Text(transaction.date, format: .dateTime.day().month(.abbreviated).year())
                                if transaction.externalSource?.hasPrefix("trading212:") == true {
                                    Label("Trading 212", systemImage: "link")
                                } else if transaction.externalSource == "degiro:csv" {
                                    Label("DEGIRO", systemImage: "doc.text")
                                } else if transaction.externalSource?.hasPrefix("traderepublic:") == true {
                                    Label("Trade Republic", systemImage: "doc.richtext")
                                }
                            }
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

private enum PurchaseValueInputMode: String, CaseIterable, Identifiable {
    case pricePerShare
    case totalValue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pricePerShare: return "Prix par action"
        case .totalValue: return "Valeur totale"
        }
    }
}

private struct PurchasePriceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let holding: Holding

    @State private var inputMode: PurchaseValueInputMode = .pricePerShare
    @State private var amountText: String
    @State private var priceWasEdited = false
    @State private var displayNameText: String
    @State private var nameWasEdited = false
    @State private var errorMessage: String?

    init(holding: Holding) {
        self.holding = holding
        _amountText = State(
            initialValue: holding.purchasePrice.formatted(
                .number.precision(.fractionLength(2...6))
            )
        )
        _displayNameText = State(initialValue: holding.displayName)
    }

    private var parsedAmount: Double? {
        Double(
            amountText
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\u{00A0}", with: "")
                .replacingOccurrences(of: "\u{202F}", with: "")
                .replacingOccurrences(of: ",", with: ".")
        )
    }

    private var editedPurchasePrice: Double? {
        guard let amount = parsedAmount, amount >= 0 else { return nil }
        switch inputMode {
        case .pricePerShare:
            return amount
        case .totalValue:
            guard holding.quantity > 0 else { return nil }
            return amount / holding.quantity
        }
    }

    private var editedTotalValue: Double {
        (editedPurchasePrice ?? 0) * holding.quantity
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Position") {
                    LabeledContent("Titre", value: holding.symbol)
                    LabeledContent(
                        "Quantité",
                        value: holding.quantity.formatted(.number.precision(.fractionLength(0...4)))
                    )
                    LabeledContent("Devise", value: holding.currencyCode)
                }

                Section("Nom affiché") {
                    TextField("Nom compréhensible", text: $displayNameText)
                        .onChange(of: displayNameText) {
                            nameWasEdited = true
                        }

                    Text("Ce nom est uniquement utilisé dans Nexa. Le symbole boursier et la synchronisation restent inchangés.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)

                    if holding.manualDisplayName != nil || holding.displayName != holding.symbol {
                        Button {
                            displayNameText = ""
                            nameWasEdited = true
                        } label: {
                            Label("Utiliser le nom automatique", systemImage: "arrow.counterclockwise")
                        }
                    }
                }

                Section("Valeur d’achat") {
                    Picker("Mode de saisie", selection: $inputMode) {
                        ForEach(PurchaseValueInputMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: inputMode) { _, newMode in
                        switch newMode {
                        case .pricePerShare:
                            amountText = holding.purchasePrice.formatted(
                                .number.precision(.fractionLength(2...6))
                            )
                        case .totalValue:
                            amountText = holding.costBasis.formatted(
                                .number.precision(.fractionLength(2...6))
                            )
                        }
                    }

                    TextField(
                        inputMode == .pricePerShare ? "Prix moyen par action" : "Valeur totale investie",
                        text: $amountText
                    )
                    .keyboardType(.decimalPad)
                    .onChange(of: amountText) {
                        priceWasEdited = true
                    }

                    LabeledContent(
                        "Prix moyen obtenu",
                        value: (editedPurchasePrice ?? 0).currency(holding.currencyCode)
                    )
                    LabeledContent(
                        "Valeur totale obtenue",
                        value: editedTotalValue.currency(holding.currencyCode)
                    )
                }

                Section {
                    Text("Cette correction modifie le prix moyen utilisé pour les gains et pertes, sans changer l’historique des transactions.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)

                    if holding.manualAverageCost != nil {
                        Button {
                            restoreTransactionValue()
                        } label: {
                            Label("Rétablir la valeur calculée", systemImage: "arrow.counterclockwise")
                        }
                    }
                }
            }
            .navigationTitle("Modifier la position")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { save() }
                        .disabled(priceWasEdited && editedPurchasePrice == nil)
                }
            }
            .alert("Modification impossible", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        if priceWasEdited {
            guard let editedPurchasePrice else { return }
            holding.manualAverageCost = editedPurchasePrice
        }
        if nameWasEdited {
            let name = displayNameText.trimmingCharacters(in: .whitespacesAndNewlines)
            holding.manualDisplayName = name.isEmpty ? nil : name
            holding.displayName = name.isEmpty ? holding.symbol : name
        }
        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreTransactionValue() {
        holding.manualAverageCost = nil
        do {
            try modelContext.save()
            dismiss()
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
