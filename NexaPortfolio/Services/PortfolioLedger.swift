import Foundation
import SwiftData

enum LedgerError: LocalizedError {
    case invalidQuantity
    case invalidPrice
    case insufficientQuantity(available: Double)

    var errorDescription: String? {
        switch self {
        case .invalidQuantity:
            return "La quantité doit être supérieure à zéro."
        case .invalidPrice:
            return "Le prix ne peut pas être négatif."
        case let .insufficientQuantity(available):
            return "Quantité insuffisante. Disponible : \(available.formatted(.number.precision(.fractionLength(0...4))))."
        }
    }
}

enum PortfolioLedger {
    private struct PositionState {
        var displayName: String
        var quantity: Double
        var totalCost: Double
        var lastPrice: Double
        var currencyCode: String
    }

    private struct HoldingSnapshot {
        let currentPrice: Double
        let previousClose: Double
        let currencyCode: String
        let fxRate: Double
        let lastUpdated: Date?
        let annualDividend: Double
        let dividendYield: Double
        let lastDividend: Double
        let lastDividendDate: Date?
        let nextDividendDate: Date?
        let nextDividendDateIsEstimated: Bool
        let paymentCount: Int
        let manualAverageCost: Double?
    }

    @MainActor
    static func record(
        kind: TransactionKind,
        symbol: String,
        displayName: String,
        quantity: Double,
        price: Double,
        fees: Double,
        currencyCode: String,
        date: Date,
        notes: String,
        in portfolio: Portfolio,
        context: ModelContext
    ) throws {
        guard quantity > 0 || kind == .dividend else {
            throw LedgerError.invalidQuantity
        }
        guard price >= 0, fees >= 0 else {
            throw LedgerError.invalidPrice
        }

        let normalizedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let existing = portfolio.holdings.first { $0.symbol == normalizedSymbol }

        switch kind {
        case .buy:
            if let holding = existing {
                let oldCost = holding.purchasePrice * holding.quantity
                let addedCost = price * quantity + fees
                holding.quantity += quantity
                holding.averageCost = (oldCost + addedCost) / holding.quantity
                holding.manualAverageCost = nil
                if holding.currentPrice == 0 { holding.currentPrice = price }
                if holding.previousClose == 0 { holding.previousClose = price }
                holding.currencyCode = currencyCode
                if !displayName.isEmpty { holding.displayName = displayName }
            } else {
                let holding = Holding(
                    symbol: normalizedSymbol,
                    displayName: displayName.isEmpty ? normalizedSymbol : displayName,
                    quantity: quantity,
                    averageCost: (price * quantity + fees) / quantity,
                    currentPrice: price,
                    currencyCode: currencyCode,
                    portfolio: portfolio
                )
                context.insert(holding)
            }

        case .sell:
            let available = existing?.quantity ?? 0
            guard quantity <= available else {
                throw LedgerError.insufficientQuantity(available: available)
            }
            if let holding = existing {
                holding.quantity -= quantity
                if holding.quantity <= 0.000_000_1 {
                    context.delete(holding)
                }
            }

        case .dividend:
            break
        }

        let transaction = TradeTransaction(
            kind: kind,
            symbol: normalizedSymbol,
            displayName: displayName.isEmpty ? normalizedSymbol : displayName,
            quantity: quantity,
            price: price,
            fees: fees,
            currencyCode: currencyCode,
            date: date,
            notes: notes,
            portfolio: portfolio
        )
        context.insert(transaction)
        try context.save()
    }

    @MainActor
    static func deleteTransaction(_ transaction: TradeTransaction, context: ModelContext) throws {
        guard let portfolio = transaction.portfolio else {
            context.delete(transaction)
            try context.save()
            return
        }

        try rebuildHoldings(in: portfolio, excluding: transaction, context: context)
    }

    @MainActor
    static func rebuildHoldings(
        in portfolio: Portfolio,
        excluding excludedTransaction: TradeTransaction? = nil,
        context: ModelContext
    ) throws {
        let quoteSnapshots = Dictionary(uniqueKeysWithValues: portfolio.holdings.map {
            ($0.symbol, HoldingSnapshot(
                currentPrice: $0.currentPrice,
                previousClose: $0.previousClose,
                currencyCode: $0.currencyCode,
                fxRate: $0.fxRateToPortfolioCurrency,
                lastUpdated: $0.lastUpdated,
                annualDividend: $0.annualDividendPerShare,
                dividendYield: $0.dividendYieldPercent,
                lastDividend: $0.lastDividendPerShare,
                lastDividendDate: $0.lastDividendDate,
                nextDividendDate: $0.nextDividendDate,
                nextDividendDateIsEstimated: $0.nextDividendDateIsEstimated,
                paymentCount: $0.dividendPaymentsLastTwelveMonths,
                manualAverageCost: $0.manualAverageCost
            ))
        })

        for holding in portfolio.holdings {
            context.delete(holding)
        }

        let ordered = portfolio.transactions
            .filter { $0.id != excludedTransaction?.id }
            .sorted { $0.date < $1.date }
        var states: [String: PositionState] = [:]

        for transaction in ordered {
            let symbol = transaction.symbol
            switch transaction.kind {
            case .buy:
                var state = states[symbol] ?? PositionState(
                    displayName: transaction.displayName,
                    quantity: 0,
                    totalCost: 0,
                    lastPrice: transaction.price,
                    currencyCode: transaction.currencyCode
                )
                state.quantity += transaction.quantity
                state.totalCost += transaction.grossAmount + transaction.fees
                state.lastPrice = transaction.price
                state.currencyCode = transaction.currencyCode
                states[symbol] = state
            case .sell:
                if var state = states[symbol], state.quantity > 0 {
                    let soldQuantity = min(transaction.quantity, state.quantity)
                    let averageCost = state.totalCost / state.quantity
                    state.quantity -= soldQuantity
                    let isShareAdjustment = transaction.price == 0
                        && transaction.fees == 0
                        && (
                            transaction.notes.localizedCaseInsensitiveContains("ajustement de titres")
                            || transaction.notes.localizedCaseInsensitiveContains("fractionnement de titres")
                            || transaction.notes.localizedCaseInsensitiveContains("regroupement de titres")
                        )
                    if !isShareAdjustment {
                        state.totalCost -= soldQuantity * averageCost
                    }
                    if state.quantity <= 0.000_000_1 {
                        states.removeValue(forKey: symbol)
                    } else {
                        states[symbol] = state
                    }
                }
            case .dividend:
                break
            }
        }

        for (symbol, state) in states where state.quantity > 0 {
            let snapshot = quoteSnapshots[symbol]
            let holding = Holding(
                symbol: symbol,
                displayName: state.displayName,
                quantity: state.quantity,
                averageCost: state.totalCost / state.quantity,
                currentPrice: snapshot?.currentPrice ?? state.lastPrice,
                previousClose: snapshot?.previousClose ?? state.lastPrice,
                currencyCode: snapshot?.currencyCode ?? state.currencyCode,
                annualDividendPerShare: snapshot?.annualDividend ?? 0,
                dividendYieldPercent: snapshot?.dividendYield ?? 0,
                lastDividendPerShare: snapshot?.lastDividend ?? 0,
                lastDividendDate: snapshot?.lastDividendDate,
                nextDividendDate: snapshot?.nextDividendDate,
                nextDividendDateIsEstimated: snapshot?.nextDividendDateIsEstimated ?? true,
                dividendPaymentsLastTwelveMonths: snapshot?.paymentCount ?? 0,
                portfolio: portfolio
            )
            holding.fxRateToPortfolioCurrency = snapshot?.fxRate ?? 1
            holding.lastUpdated = snapshot?.lastUpdated
            holding.manualAverageCost = snapshot?.manualAverageCost
            context.insert(holding)
        }

        if let excludedTransaction {
            context.delete(excludedTransaction)
        }
        try context.save()
    }
}
