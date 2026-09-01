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
            URLQueryItem(name: "range", value: "5d"),
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

        return MarketQuote(
            symbol: result.meta.symbol ?? symbol,
            displayName: result.meta.longName ?? result.meta.shortName ?? symbol,
            price: price,
            previousClose: previousClose,
            currencyCode: result.meta.currency ?? "USD",
            timestamp: result.meta.regularMarketTime.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? .now
        )
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
        let indicators: Indicators
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
