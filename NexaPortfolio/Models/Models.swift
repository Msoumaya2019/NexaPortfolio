import Foundation
import SwiftData

@Model
final class Portfolio {
    @Attribute(.unique) var id: UUID
    var name: String
    var currencyCode: String
    var cashBalance: Double
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Holding.portfolio)
    var holdings: [Holding]

    @Relationship(deleteRule: .cascade, inverse: \TradeTransaction.portfolio)
    var transactions: [TradeTransaction]

    init(
        name: String,
        currencyCode: String = "EUR",
        cashBalance: Double = 0,
        createdAt: Date = .now
    ) {
        self.id = UUID()
        self.name = name
        self.currencyCode = currencyCode
        self.cashBalance = cashBalance
        self.createdAt = createdAt
        self.holdings = []
        self.transactions = []
    }

    var holdingsValue: Double {
        holdings.reduce(0) { $0 + $1.marketValueInPortfolioCurrency }
    }

    var totalValue: Double {
        holdingsValue + cashBalance
    }

    var costBasis: Double {
        holdings.reduce(0) { $0 + $1.costBasisInPortfolioCurrency }
    }

    var unrealizedGain: Double {
        holdingsValue - costBasis
    }

    var unrealizedGainPercent: Double {
        guard costBasis > 0 else { return 0 }
        return unrealizedGain / costBasis * 100
    }
}

@Model
final class Holding {
    @Attribute(.unique) var id: UUID
    var symbol: String
    var displayName: String
    var quantity: Double
    var averageCost: Double
    var manualAverageCost: Double? = nil
    var currentPrice: Double
    var previousClose: Double
    var currencyCode: String
    var fxRateToPortfolioCurrency: Double
    var annualDividendPerShare: Double = 0
    var dividendYieldPercent: Double = 0
    var lastDividendPerShare: Double = 0
    var lastDividendDate: Date?
    var nextDividendDate: Date?
    var nextDividendDateIsEstimated: Bool = true
    var dividendPaymentsLastTwelveMonths: Int = 0
    var lastUpdated: Date?
    var portfolio: Portfolio?

    init(
        symbol: String,
        displayName: String,
        quantity: Double,
        averageCost: Double,
        currentPrice: Double,
        previousClose: Double? = nil,
        currencyCode: String = "EUR",
        annualDividendPerShare: Double = 0,
        dividendYieldPercent: Double = 0,
        lastDividendPerShare: Double = 0,
        lastDividendDate: Date? = nil,
        nextDividendDate: Date? = nil,
        nextDividendDateIsEstimated: Bool = true,
        dividendPaymentsLastTwelveMonths: Int = 0,
        portfolio: Portfolio? = nil
    ) {
        self.id = UUID()
        self.symbol = symbol.uppercased()
        self.displayName = displayName
        self.quantity = quantity
        self.averageCost = averageCost
        self.manualAverageCost = nil
        self.currentPrice = currentPrice
        self.previousClose = previousClose ?? currentPrice
        self.currencyCode = currencyCode
        self.fxRateToPortfolioCurrency = 1
        self.annualDividendPerShare = annualDividendPerShare
        self.dividendYieldPercent = dividendYieldPercent
        self.lastDividendPerShare = lastDividendPerShare
        self.lastDividendDate = lastDividendDate
        self.nextDividendDate = nextDividendDate
        self.nextDividendDateIsEstimated = nextDividendDateIsEstimated
        self.dividendPaymentsLastTwelveMonths = dividendPaymentsLastTwelveMonths
        self.lastUpdated = nil
        self.portfolio = portfolio
    }

    var marketValue: Double { quantity * currentPrice }
    var purchasePrice: Double { manualAverageCost ?? averageCost }
    var costBasis: Double { quantity * purchasePrice }
    var marketValueInPortfolioCurrency: Double { marketValue * fxRateToPortfolioCurrency }
    var costBasisInPortfolioCurrency: Double { costBasis * fxRateToPortfolioCurrency }
    var unrealizedGain: Double { marketValueInPortfolioCurrency - costBasisInPortfolioCurrency }
    var estimatedAnnualDividendIncome: Double {
        annualDividendPerShare * quantity * fxRateToPortfolioCurrency
    }

    var unrealizedGainPercent: Double {
        guard costBasisInPortfolioCurrency > 0 else { return 0 }
        return unrealizedGain / costBasisInPortfolioCurrency * 100
    }

    var dailyChangePercent: Double {
        guard previousClose > 0 else { return 0 }
        return (currentPrice - previousClose) / previousClose * 100
    }
}

enum TransactionKind: String, Codable, CaseIterable, Identifiable {
    case buy
    case sell
    case dividend

    var id: String { rawValue }

    var title: String {
        switch self {
        case .buy: return "Achat"
        case .sell: return "Vente"
        case .dividend: return "Dividende"
        }
    }

    var systemImage: String {
        switch self {
        case .buy: return "arrow.down.left"
        case .sell: return "arrow.up.right"
        case .dividend: return "banknote"
        }
    }
}

@Model
final class TradeTransaction {
    @Attribute(.unique) var id: UUID
    var kindRawValue: String
    var symbol: String
    var displayName: String
    var quantity: Double
    var price: Double
    var fees: Double
    var currencyCode: String
    var date: Date
    var notes: String
    var portfolio: Portfolio?

    var kind: TransactionKind {
        get { TransactionKind(rawValue: kindRawValue) ?? .buy }
        set { kindRawValue = newValue.rawValue }
    }

    init(
        kind: TransactionKind,
        symbol: String,
        displayName: String,
        quantity: Double,
        price: Double,
        fees: Double = 0,
        currencyCode: String = "EUR",
        date: Date = .now,
        notes: String = "",
        portfolio: Portfolio? = nil
    ) {
        self.id = UUID()
        self.kindRawValue = kind.rawValue
        self.symbol = symbol.uppercased()
        self.displayName = displayName
        self.quantity = quantity
        self.price = price
        self.fees = fees
        self.currencyCode = currencyCode
        self.date = date
        self.notes = notes
        self.portfolio = portfolio
    }

    var grossAmount: Double {
        kind == .dividend ? price : quantity * price
    }
}

@Model
final class Watchlist {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \WatchlistItem.watchlist)
    var items: [WatchlistItem]

    init(name: String, createdAt: Date = .now) {
        self.id = UUID()
        self.name = name
        self.createdAt = createdAt
        self.items = []
    }
}

@Model
final class WatchlistItem {
    @Attribute(.unique) var id: UUID
    var symbol: String
    var displayName: String
    var currentPrice: Double
    var previousClose: Double
    var currencyCode: String
    var annualDividendPerShare: Double = 0
    var dividendYieldPercent: Double = 0
    var lastDividendPerShare: Double = 0
    var lastDividendDate: Date?
    var nextDividendDate: Date?
    var nextDividendDateIsEstimated: Bool = true
    var dividendPaymentsLastTwelveMonths: Int = 0
    var addedAt: Date
    var lastUpdated: Date?
    var watchlist: Watchlist?

    init(
        symbol: String,
        displayName: String,
        currentPrice: Double = 0,
        previousClose: Double = 0,
        currencyCode: String = "USD",
        annualDividendPerShare: Double = 0,
        dividendYieldPercent: Double = 0,
        lastDividendPerShare: Double = 0,
        lastDividendDate: Date? = nil,
        nextDividendDate: Date? = nil,
        nextDividendDateIsEstimated: Bool = true,
        dividendPaymentsLastTwelveMonths: Int = 0,
        watchlist: Watchlist? = nil
    ) {
        self.id = UUID()
        self.symbol = symbol.uppercased()
        self.displayName = displayName
        self.currentPrice = currentPrice
        self.previousClose = previousClose
        self.currencyCode = currencyCode
        self.annualDividendPerShare = annualDividendPerShare
        self.dividendYieldPercent = dividendYieldPercent
        self.lastDividendPerShare = lastDividendPerShare
        self.lastDividendDate = lastDividendDate
        self.nextDividendDate = nextDividendDate
        self.nextDividendDateIsEstimated = nextDividendDateIsEstimated
        self.dividendPaymentsLastTwelveMonths = dividendPaymentsLastTwelveMonths
        self.addedAt = .now
        self.lastUpdated = nil
        self.watchlist = watchlist
    }

    var dailyChange: Double { currentPrice - previousClose }

    var dailyChangePercent: Double {
        guard previousClose > 0 else { return 0 }
        return dailyChange / previousClose * 100
    }
}

struct MarketQuote: Sendable {
    let symbol: String
    let displayName: String
    let price: Double
    let previousClose: Double
    let currencyCode: String
    let timestamp: Date
    let annualDividendPerShare: Double
    let dividendYieldPercent: Double
    let lastDividendPerShare: Double
    let lastDividendDate: Date?
    let nextDividendDate: Date?
    let nextDividendDateIsEstimated: Bool
    let dividendPaymentsLastTwelveMonths: Int

    var changePercent: Double {
        guard previousClose > 0 else { return 0 }
        return (price - previousClose) / previousClose * 100
    }
}

struct SymbolSearchResult: Identifiable, Sendable, Hashable {
    var id: String { symbol }
    let symbol: String
    let displayName: String
    let exchange: String
    let assetType: String
}
