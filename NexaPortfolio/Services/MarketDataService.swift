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
        guard let price = result.meta.regularMarketPrice ?? closes.last else {
            throw MarketDataError.quoteUnavailable(symbol)
        }
        let previousClose = result.meta.chartPreviousClose
            ?? result.meta.previousClose
            ?? closes.dropLast().last
            ?? price
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
        let annualDividend = dividendEvents.reduce(0) { $0 + $1.amount }
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
            currencyCode: result.meta.currency ?? "USD",
            timestamp: timestamp,
            annualDividendPerShare: annualDividend,
            dividendYieldPercent: dividendYieldPercent,
            lastDividendPerShare: lastDividend?.amount ?? 0,
            lastDividendDate: lastDividend.map { Date(timeIntervalSince1970: TimeInterval($0.date)) },
            nextDividendDate: nextDividendDate,
            nextDividendDateIsEstimated: announcedNextDividend == nil,
            dividendPaymentsLastTwelveMonths: dividendEvents.count
        )
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
        let candidates = zip(timestamps, closes).compactMap { pair -> (distance: Double, price: Double)? in
            guard let close = pair.1, close > 0 else { return nil }
            return (abs(TimeInterval(pair.0) - targetTimestamp), close)
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
            if holding.displayName == holding.symbol { holding.displayName = quote.displayName }

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
        holdings: [Holding],
        cashBalance: Double,
        since date: Date
    ) async -> PortfolioPerformanceSnapshot? {
        let positions = holdings.filter { $0.quantity > 0 }
        guard !positions.isEmpty else {
            return PortfolioPerformanceSnapshot(amount: 0, percent: 0)
        }

        let symbols = Array(Set(positions.map { $0.symbol.uppercased() }))
        let historicalPrices = await withTaskGroup(
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

        var currentValue = cashBalance
        var startingValue = cashBalance
        var matchedPositionCount = 0
        for holding in positions {
            guard let historicalPrice = historicalPrices[holding.symbol.uppercased()] else { continue }
            currentValue += holding.marketValueInPortfolioCurrency
            startingValue += historicalPrice * holding.quantity * holding.fxRateToPortfolioCurrency
            matchedPositionCount += 1
        }

        guard matchedPositionCount > 0, startingValue > 0 else { return nil }
        let amount = currentValue - startingValue
        return PortfolioPerformanceSnapshot(
            amount: amount,
            percent: amount / startingValue * 100
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
