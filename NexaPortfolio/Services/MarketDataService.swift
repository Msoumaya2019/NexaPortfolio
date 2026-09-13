import Foundation
import Combine
import SwiftData

enum MarketDataError: LocalizedError {
    case invalidURL
    case invalidResponse
    case quoteUnavailable(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Adresse du service de marché invalide."
        case .invalidResponse:
            return "Réponse du service de marché illisible."
        case let .quoteUnavailable(symbol):
            return "Aucun cours disponible pour \(symbol)."
        case let .server(message):
            return message
        }
    }
}

struct PortfolioPerformanceSnapshot: Sendable, Equatable {
    let amount: Double
    let percent: Double
    let basis: Double

    init(amount: Double, percent: Double, basis: Double = 0) {
        self.amount = amount
        self.percent = percent
        self.basis = basis
    }
}

actor MarketDataClient {
    static let shared = MarketDataClient()

    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func quote(for rawSymbol: String) async throws -> MarketQuote {
        let symbol = rawSymbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)")
        else { throw MarketDataError.invalidURL }

        components.queryItems = [
            URLQueryItem(name: "range", value: "1y"),
            URLQueryItem(name: "interval", value: "1d"),
            URLQueryItem(name: "includePrePost", value: "false"),
            URLQueryItem(name: "events", value: "dividends")
        ]
        guard let url = components.url else { throw MarketDataError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 NexaPortfolio/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MarketDataError.invalidResponse
        }

        let payload = try decoder.decode(YahooChartResponse.self, from: data)
        if let message = payload.chart.error?.description {
            throw MarketDataError.server(message)
        }
        guard let result = payload.chart.result?.first else {
            throw MarketDataError.quoteUnavailable(symbol)
        }

        let closes = result.indicators.quote.first?.close.compactMap { $0 } ?? []
        guard let rawPrice = result.meta.regularMarketPrice ?? closes.last else {
            throw MarketDataError.quoteUnavailable(symbol)
        }
        let rawCurrency = result.meta.currency ?? "USD"
        let quoteScale = Self.currencyScale(rawCurrency)
        let normalizedCurrency = Self.normalizedCurrency(rawCurrency)
        let price = rawPrice * quoteScale
        let previousClose = (result.meta.chartPreviousClose
            ?? result.meta.previousClose
            ?? closes.dropLast().last
            ?? rawPrice) * quoteScale
        let timestamp = result.meta.regularMarketTime
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ?? .now
        let cutoffDate = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -366,
            to: timestamp
        ) ?? timestamp.addingTimeInterval(-31_622_400)
        let allDividendEvents = (result.events?.dividends.map { Array($0.values) } ?? [])
            .sorted { $0.date < $1.date }
        let dividendEvents = allDividendEvents
            .filter {
                let eventDate = Date(timeIntervalSince1970: TimeInterval($0.date))
                return eventDate >= cutoffDate && eventDate <= timestamp
            }
        let annualDividend = dividendEvents.reduce(0) { $0 + $1.amount } * quoteScale
        let lastDividend = dividendEvents.last
        let dividendYieldPercent = price > 0 ? annualDividend / price * 100 : 0
        let announcedNextDividend = allDividendEvents.first {
            Date(timeIntervalSince1970: TimeInterval($0.date)) > timestamp
        }
        let nextDividendDate = announcedNextDividend
            .map { Date(timeIntervalSince1970: TimeInterval($0.date)) }
            ?? Self.estimatedNextDividendDate(from: dividendEvents, after: timestamp)

        return MarketQuote(
            symbol: result.meta.symbol ?? symbol,
            displayName: result.meta.longName ?? result.meta.shortName ?? symbol,
            price: price,
            previousClose: previousClose,
            currencyCode: normalizedCurrency,
            timestamp: timestamp,
            annualDividendPerShare: annualDividend,
            dividendYieldPercent: dividendYieldPercent,
            lastDividendPerShare: (lastDividend?.amount ?? 0) * quoteScale,
            lastDividendDate: lastDividend.map { Date(timeIntervalSince1970: TimeInterval($0.date)) },
            nextDividendDate: nextDividendDate,
            nextDividendDateIsEstimated: announcedNextDividend == nil,
            dividendPaymentsLastTwelveMonths: dividendEvents.count
        )
    }

    private static func currencyScale(_ code: String) -> Double {
        code == "GBp" || code.uppercased() == "GBX" ? 0.01 : 1
    }

    private static func normalizedCurrency(_ code: String) -> String {
        currencyScale(code) == 0.01 ? "GBP" : code.uppercased()
    }

    private static func estimatedNextDividendDate(
        from events: [YahooChartResponse.DividendEvent],
        after referenceDate: Date
    ) -> Date? {
        guard let lastEvent = events.last else { return nil }

        let calendar = Calendar(identifier: .gregorian)
        let dates = events.map { Date(timeIntervalSince1970: TimeInterval($0.date)) }
        let recentDates = Array(dates.suffix(7))
        let intervals = zip(recentDates, recentDates.dropFirst()).compactMap { pair -> Int? in
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: pair.0),
                to: calendar.startOfDay(for: pair.1)
            ).day ?? 0
            return (20...400).contains(days) ? days : nil
        }.sorted()

        // Un seul versement sur douze mois correspond le plus souvent à une cadence annuelle.
        let cadenceDays = intervals.isEmpty ? 365 : intervals[intervals.count / 2]
        var candidate = calendar.date(
            byAdding: .day,
            value: cadenceDays,
            to: Date(timeIntervalSince1970: TimeInterval(lastEvent.date))
        )

        for _ in 0..<24 {
            guard let date = candidate, date <= referenceDate else { break }
            candidate = calendar.date(byAdding: .day, value: cadenceDays, to: date)
        }
        return candidate
    }

    func quotes(for symbols: [String]) async -> [String: MarketQuote] {
        let uniqueSymbols = Array(Set(symbols.map { $0.uppercased() }))
        var values: [String: MarketQuote] = [:]

        await withTaskGroup(of: MarketQuote?.self) { group in
            for symbol in uniqueSymbols {
                group.addTask {
                    try? await self.quote(for: symbol)
                }
            }
            for await quote in group {
                if let quote { values[quote.symbol.uppercased()] = quote }
            }
        }
        return values
    }

    func historicalClose(for rawSymbol: String, around targetDate: Date) async throws -> Double {
        let symbol = rawSymbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let calendar = Calendar(identifier: .gregorian)
        let periodStart = calendar.date(byAdding: .day, value: -10, to: targetDate) ?? targetDate
        let requestedEnd = calendar.date(byAdding: .day, value: 10, to: targetDate) ?? .now
        let latestEnd = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
        let periodEnd = min(requestedEnd, latestEnd)

        guard let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)")
        else { throw MarketDataError.invalidURL }

        components.queryItems = [
            URLQueryItem(name: "period1", value: String(Int(periodStart.timeIntervalSince1970))),
            URLQueryItem(name: "period2", value: String(Int(periodEnd.timeIntervalSince1970))),
            URLQueryItem(name: "interval", value: "1d"),
            URLQueryItem(name: "includePrePost", value: "false")
        ]
        guard let url = components.url else { throw MarketDataError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 NexaPortfolio/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MarketDataError.invalidResponse
        }

        let payload = try decoder.decode(YahooChartResponse.self, from: data)
        if let message = payload.chart.error?.description {
            throw MarketDataError.server(message)
        }
        guard let result = payload.chart.result?.first,
              let timestamps = result.timestamp,
              let closes = result.indicators.quote.first?.close
        else { throw MarketDataError.quoteUnavailable(symbol) }

        let targetTimestamp = targetDate.timeIntervalSince1970
        let scale = Self.currencyScale(result.meta.currency ?? "USD")
        let candidates = zip(timestamps, closes).compactMap { pair -> (distance: Double, price: Double)? in
            guard let close = pair.1, close > 0 else { return nil }
            return (abs(TimeInterval(pair.0) - targetTimestamp), close * scale)
        }
        guard let closest = candidates.min(by: { $0.distance < $1.distance }) else {
            throw MarketDataError.quoteUnavailable(symbol)
        }
        return closest.price
    }

    func search(_ query: String) async throws -> [SymbolSearchResult] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 1,
              var components = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/search")
        else { return [] }

        components.queryItems = [
            URLQueryItem(name: "q", value: normalized),
            URLQueryItem(name: "quotesCount", value: "12"),
            URLQueryItem(name: "newsCount", value: "0")
        ]
        guard let url = components.url else { throw MarketDataError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 NexaPortfolio/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MarketDataError.invalidResponse
        }

        let payload = try decoder.decode(YahooSearchResponse.self, from: data)
        return payload.quotes
            .filter { ["EQUITY", "ETF", "MUTUALFUND", "CRYPTOCURRENCY", "INDEX"].contains($0.quoteType ?? "") }
            .map {
                SymbolSearchResult(
                    symbol: $0.symbol,
                    displayName: $0.longname ?? $0.shortname ?? $0.symbol,
                    exchange: $0.exchDisp ?? $0.exchange ?? "Marché",
                    assetType: $0.quoteType ?? "ACTIF"
                )
            }
    }
}

@MainActor
final class MarketDataStore: ObservableObject {
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?

    private let client = MarketDataClient.shared

    func refresh(holdings: [Holding], watchlistItems: [WatchlistItem], context: ModelContext) async {
        let symbols = holdings.map(\.symbol) + watchlistItems.map(\.symbol)
        guard !symbols.isEmpty else { return }

        isRefreshing = true
        errorMessage = nil
        let quotes = await client.quotes(for: symbols)

        let fxSymbols = Set(holdings.compactMap { holding -> String? in
            guard let quote = quotes[holding.symbol.uppercased()],
                  let targetCurrency = holding.portfolio?.currencyCode,
                  quote.currencyCode != targetCurrency
            else { return nil }
            return "\(quote.currencyCode)\(targetCurrency)=X"
        })
        let fxQuotes = await client.quotes(for: Array(fxSymbols))

        for holding in holdings {
            guard let quote = quotes[holding.symbol.uppercased()] else { continue }
            if (holding.currencyCode == "GBp" || holding.currencyCode.uppercased() == "GBX"),
               quote.currencyCode == "GBP" {
                holding.averageCost *= 0.01
                if let manualAverageCost = holding.manualAverageCost {
                    holding.manualAverageCost = manualAverageCost * 0.01
                }
            }
            holding.currentPrice = quote.price
            holding.previousClose = quote.previousClose
            holding.currencyCode = quote.currencyCode
            holding.annualDividendPerShare = quote.annualDividendPerShare
            holding.dividendYieldPercent = quote.dividendYieldPercent
            holding.lastDividendPerShare = quote.lastDividendPerShare
            holding.lastDividendDate = quote.lastDividendDate
            holding.nextDividendDate = quote.nextDividendDate
            holding.nextDividendDateIsEstimated = quote.nextDividendDateIsEstimated
            holding.dividendPaymentsLastTwelveMonths = quote.dividendPaymentsLastTwelveMonths
            holding.lastUpdated = quote.timestamp
            if holding.manualDisplayName == nil { holding.displayName = quote.displayName }

            if let targetCurrency = holding.portfolio?.currencyCode {
                if quote.currencyCode == targetCurrency {
                    holding.fxRateToPortfolioCurrency = 1
                } else {
                    let fxSymbol = "\(quote.currencyCode)\(targetCurrency)=X"
                    if let fxQuote = fxQuotes[fxSymbol] {
                        holding.fxRateToPortfolioCurrency = fxQuote.price
                    }
                }
            }
        }

        for item in watchlistItems {
            guard let quote = quotes[item.symbol.uppercased()] else { continue }
            item.currentPrice = quote.price
            item.previousClose = quote.previousClose
            item.currencyCode = quote.currencyCode
            item.annualDividendPerShare = quote.annualDividendPerShare
            item.dividendYieldPercent = quote.dividendYieldPercent
            item.lastDividendPerShare = quote.lastDividendPerShare
            item.lastDividendDate = quote.lastDividendDate
            item.nextDividendDate = quote.nextDividendDate
            item.nextDividendDateIsEstimated = quote.nextDividendDateIsEstimated
            item.dividendPaymentsLastTwelveMonths = quote.dividendPaymentsLastTwelveMonths
            item.lastUpdated = quote.timestamp
            if item.displayName == item.symbol { item.displayName = quote.displayName }
        }

        do {
            try context.save()
        } catch {
            errorMessage = "Les cours ont été reçus mais n’ont pas pu être enregistrés."
        }
        if quotes.isEmpty {
            errorMessage = "Aucun cours n’a pu être actualisé. Vérifie la connexion et les symboles."
        }
        isRefreshing = false
    }

    func performance(
        portfolios: [Portfolio],
        since date: Date?
    ) async -> PortfolioPerformanceSnapshot? {
        guard let targetCurrency = portfolios.first?.currencyCode.uppercased() else {
            return PortfolioPerformanceSnapshot(amount: 0, percent: 0)
        }

        let portfolioCurrencies = Set(portfolios.map { $0.currencyCode.uppercased() })
        guard let conversionRates = await fxRates(
            for: portfolioCurrencies,
            to: targetCurrency,
            holdings: []
        ) else { return nil }

        var totalAmount = 0.0
        var totalBasis = 0.0
        var hasSnapshot = false
        for portfolio in portfolios {
            guard let snapshot = await performance(
                holdings: portfolio.holdings,
                transactions: portfolio.transactions,
                portfolioCurrencyCode: portfolio.currencyCode,
                since: date
            ), let rate = conversionRates[portfolio.currencyCode.uppercased()]
            else { continue }

            totalAmount += snapshot.amount * rate
            totalBasis += snapshot.basis * rate
            hasSnapshot = true
        }

        guard hasSnapshot else { return nil }
        return PortfolioPerformanceSnapshot(
            amount: totalAmount,
            percent: totalBasis > 0 ? totalAmount / totalBasis * 100 : 0,
            basis: totalBasis
        )
    }

    func performance(
        holdings: [Holding],
        transactions: [TradeTransaction],
        portfolioCurrencyCode: String,
        since date: Date?
    ) async -> PortfolioPerformanceSnapshot? {
        let targetCurrency = portfolioCurrencyCode.uppercased()
        let currencies = Set(
            transactions.map { normalizedCurrency($0.currencyCode) }
                + holdings.map { normalizedCurrency($0.currencyCode) }
        )
        guard let rates = await fxRates(for: currencies, to: targetCurrency, holdings: holdings) else {
            return nil
        }

        if date == nil {
            return lifetimePerformance(
                holdings: holdings,
                transactions: transactions,
                rates: rates
            )
        }
        guard let date else { return nil }

        let recentTransactions = transactions.filter { $0.date >= date }
        if recentTransactions.contains(where: isShareAdjustment) {
            // Sans historique précis du ratio de split/fusion, mieux vaut ne pas publier
            // une performance trompeuse pour cette période.
            return nil
        }

        var startingQuantities: [String: Double] = [:]
        for holding in holdings where holding.quantity > 0 {
            startingQuantities[holding.symbol.uppercased(), default: 0] += holding.quantity
        }
        for transaction in recentTransactions {
            let symbol = transaction.symbol.uppercased()
            switch transaction.kind {
            case .buy:
                startingQuantities[symbol, default: 0] -= transaction.quantity
            case .sell:
                startingQuantities[symbol, default: 0] += transaction.quantity
            case .dividend:
                break
            }
        }
        startingQuantities = startingQuantities.filter { $0.value > 0.000_000_1 }

        var startingPrices: [String: Double] = [:]
        let isOneDay = Date.now.timeIntervalSince(date) <= 2 * 86_400
        if isOneDay {
            for holding in holdings where holding.previousClose > 0 {
                startingPrices[holding.symbol.uppercased()] = holding.previousClose
            }
        }

        let missingSymbols = startingQuantities.keys.filter { startingPrices[$0] == nil }
        let fetchedPrices = await historicalPrices(for: Array(missingSymbols), around: date)
        startingPrices.merge(fetchedPrices) { existing, _ in existing }

        var startingValue = 0.0
        for (symbol, quantity) in startingQuantities {
            guard let price = startingPrices[symbol] else { return nil }
            let holding = holdings.first { $0.symbol.uppercased() == symbol }
            let currency = normalizedCurrency(holding?.currencyCode ?? transactionCurrency(
                for: symbol,
                in: transactions
            ))
            guard let rate = rates[currency] else { return nil }
            startingValue += price * quantity * rate
        }

        let endingValue = holdings.reduce(0) { $0 + $1.marketValueInPortfolioCurrency }
        var purchases = 0.0
        var saleProceeds = 0.0
        var dividends = 0.0
        for transaction in recentTransactions {
            guard let rate = rates[normalizedCurrency(transaction.currencyCode)] else { return nil }
            let scale = currencyScale(transaction.currencyCode)
            switch transaction.kind {
            case .buy:
                purchases += (transaction.quantity * transaction.price + transaction.fees) * scale * rate
            case .sell:
                saleProceeds += (transaction.quantity * transaction.price - transaction.fees) * scale * rate
            case .dividend:
                dividends += (transaction.price - transaction.fees) * scale * rate
            }
        }

        let basis = startingValue + purchases
        let amount = endingValue + saleProceeds + dividends - startingValue - purchases
        return PortfolioPerformanceSnapshot(
            amount: amount,
            percent: basis > 0 ? amount / basis * 100 : 0,
            basis: basis
        )
    }

    private func lifetimePerformance(
        holdings: [Holding],
        transactions: [TradeTransaction],
        rates: [String: Double]
    ) -> PortfolioPerformanceSnapshot {
        struct PositionCost {
            var quantity = 0.0
            var totalCost = 0.0
        }

        var states: [String: PositionCost] = [:]
        var realizedAndDividends = 0.0
        var cumulativePurchases = 0.0

        for transaction in transactions.sorted(by: { $0.date < $1.date }) {
            let currency = normalizedCurrency(transaction.currencyCode)
            guard let rate = rates[currency] else { continue }
            let scale = currencyScale(transaction.currencyCode)
            let symbol = transaction.symbol.uppercased()

            switch transaction.kind {
            case .buy:
                let cost = (transaction.quantity * transaction.price + transaction.fees) * scale * rate
                var state = states[symbol] ?? PositionCost()
                state.quantity += transaction.quantity
                state.totalCost += cost
                states[symbol] = state
                cumulativePurchases += cost
            case .sell:
                guard var state = states[symbol], state.quantity > 0 else { continue }
                let soldQuantity = min(transaction.quantity, state.quantity)
                if isShareAdjustment(transaction) {
                    state.quantity -= soldQuantity
                } else {
                    let averageCost = state.totalCost / state.quantity
                    let removedCost = soldQuantity * averageCost
                    let proceeds = (soldQuantity * transaction.price - transaction.fees) * scale * rate
                    realizedAndDividends += proceeds - removedCost
                    state.quantity -= soldQuantity
                    state.totalCost -= removedCost
                }
                if state.quantity <= 0.000_000_1 {
                    states.removeValue(forKey: symbol)
                } else {
                    states[symbol] = state
                }
            case .dividend:
                realizedAndDividends += (transaction.price - transaction.fees) * scale * rate
            }
        }

        let currentCost = holdings.reduce(0) { $0 + $1.costBasisInPortfolioCurrency }
        let untrackedCurrentCost = holdings.reduce(0.0) { partial, holding in
            let trackedQuantity = states[holding.symbol.uppercased()]?.quantity ?? 0
            guard holding.quantity > 0, trackedQuantity < holding.quantity else { return partial }
            let untrackedRatio = max(0, holding.quantity - trackedQuantity) / holding.quantity
            return partial + holding.costBasisInPortfolioCurrency * untrackedRatio
        }
        let amount = realizedAndDividends + holdings.reduce(0) { $0 + $1.unrealizedGain }
        let basis = cumulativePurchases > 0
            ? cumulativePurchases + untrackedCurrentCost
            : currentCost
        return PortfolioPerformanceSnapshot(
            amount: amount,
            percent: basis > 0 ? amount / basis * 100 : 0,
            basis: basis
        )
    }

    private func historicalPrices(for symbols: [String], around date: Date) async -> [String: Double] {
        await withTaskGroup(
            of: (String, Double)?.self,
            returning: [String: Double].self
        ) { group in
            for symbol in symbols {
                group.addTask {
                    guard let price = try? await MarketDataClient.shared.historicalClose(
                        for: symbol,
                        around: date
                    ) else { return nil }
                    return (symbol, price)
                }
            }

            var prices: [String: Double] = [:]
            for await result in group {
                if let result { prices[result.0] = result.1 }
            }
            return prices
        }
    }

    private func fxRates(
        for currencies: Set<String>,
        to targetCurrency: String,
        holdings: [Holding]
    ) async -> [String: Double]? {
        var rates = [targetCurrency: 1.0]
        for holding in holdings {
            let currency = normalizedCurrency(holding.currencyCode)
            if holding.fxRateToPortfolioCurrency > 0, rates[currency] == nil {
                rates[currency] = holding.fxRateToPortfolioCurrency
            }
        }

        let missing = currencies.filter { $0 != targetCurrency && rates[$0] == nil }
        let symbols = missing.map { "\($0)\(targetCurrency)=X" }
        let quotes = await client.quotes(for: symbols)
        for currency in missing {
            let symbol = "\(currency)\(targetCurrency)=X"
            if let quote = quotes[symbol], quote.price > 0 {
                rates[currency] = quote.price
            }
        }
        guard missing.allSatisfy({ rates[$0] != nil }) else { return nil }
        return rates
    }

    private func transactionCurrency(for symbol: String, in transactions: [TradeTransaction]) -> String {
        transactions.last { $0.symbol.uppercased() == symbol }?.currencyCode ?? "USD"
    }

    private func currencyScale(_ currencyCode: String) -> Double {
        currencyCode == "GBp" || currencyCode.uppercased() == "GBX" ? 0.01 : 1
    }

    private func normalizedCurrency(_ currencyCode: String) -> String {
        currencyScale(currencyCode) == 0.01 ? "GBP" : currencyCode.uppercased()
    }

    private func isShareAdjustment(_ transaction: TradeTransaction) -> Bool {
        transaction.price == 0
            && transaction.fees == 0
            && (
                transaction.notes.localizedCaseInsensitiveContains("ajustement de titres")
                || transaction.notes.localizedCaseInsensitiveContains("fractionnement de titres")
                || transaction.notes.localizedCaseInsensitiveContains("regroupement de titres")
            )
    }

    func search(_ query: String) async throws -> [SymbolSearchResult] {
        try await client.search(query)
    }

    func quote(for symbol: String) async throws -> MarketQuote {
        try await client.quote(for: symbol)
    }
}

private struct YahooChartResponse: Decodable {
    let chart: Chart

    struct Chart: Decodable {
        let result: [Result]?
        let error: YahooError?
    }

    struct Result: Decodable {
        let meta: Meta
        let timestamp: [Int]?
        let indicators: Indicators
        let events: Events?
    }

    struct Meta: Decodable {
        let currency: String?
        let symbol: String?
        let shortName: String?
        let longName: String?
        let regularMarketPrice: Double?
        let regularMarketTime: Int?
        let chartPreviousClose: Double?
        let previousClose: Double?
    }

    struct Indicators: Decodable {
        let quote: [Quote]
    }

    struct Quote: Decodable {
        let close: [Double?]
    }

    struct Events: Decodable {
        let dividends: [String: DividendEvent]?
    }

    struct DividendEvent: Decodable {
        let amount: Double
        let date: Int
    }

    struct YahooError: Decodable {
        let code: String?
        let description: String?
    }
}

private struct YahooSearchResponse: Decodable {
    let quotes: [Quote]

    struct Quote: Decodable {
        let symbol: String
        let shortname: String?
        let longname: String?
        let exchange: String?
        let exchDisp: String?
        let quoteType: String?
    }
}
