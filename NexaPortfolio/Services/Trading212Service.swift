import Foundation
import Security
import SwiftData

enum Trading212Environment: String, CaseIterable, Codable, Identifiable, Sendable {
    case demo
    case live

    var id: String { rawValue }

    var title: String {
        switch self {
        case .demo: return "Démo"
        case .live: return "Compte réel"
        }
    }

    var hostURL: URL {
        switch self {
        case .demo: return URL(string: "https://demo.trading212.com")!
        case .live: return URL(string: "https://live.trading212.com")!
        }
    }
}

struct Trading212Credentials: Codable, Sendable {
    let apiKey: String
    let apiSecret: String
}

enum Trading212Keychain {
    private static let service = "com.msoumaya2019.nexaportfolio.trading212"

    static func save(_ credentials: Trading212Credentials, for environment: Trading212Environment) throws {
        let data = try JSONEncoder().encode(credentials)
        let lookup = baseQuery(for: environment)
        SecItemDelete(lookup as CFDictionary)

        var attributes = lookup
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Trading212Error.keychain(status) }
    }

    static func load(for environment: Trading212Environment) throws -> Trading212Credentials? {
        var query = baseQuery(for: environment)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw Trading212Error.keychain(status)
        }
        return try JSONDecoder().decode(Trading212Credentials.self, from: data)
    }

    static func delete(for environment: Trading212Environment) throws {
        let status = SecItemDelete(baseQuery(for: environment) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Trading212Error.keychain(status)
        }
    }

    private static func baseQuery(for environment: Trading212Environment) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "credentials.\(environment.rawValue)"
        ]
    }
}

enum Trading212Error: LocalizedError {
    case invalidURL
    case invalidCredentials
    case permissionDenied
    case rateLimited
    case server(Int, String)
    case invalidResponse
    case keychain(OSStatus)
    case noCredentials

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Adresse Trading 212 invalide."
        case .invalidCredentials:
            return "Clé API ou secret Trading 212 invalide."
        case .permissionDenied:
            return "La clé ne possède pas les autorisations de lecture nécessaires, ou ce type de compte n’est pas pris en charge."
        case .rateLimited:
            return "Trading 212 limite temporairement les requêtes. Réessaie dans une minute."
        case let .server(code, message):
            return message.isEmpty ? "Erreur Trading 212 (HTTP \(code))." : "Trading 212 : \(message)"
        case .invalidResponse:
            return "La réponse Trading 212 est incompatible ou incomplète."
        case let .keychain(status):
            return "Le trousseau iOS n’a pas pu enregistrer les identifiants (code \(status))."
        case .noCredentials:
            return "Enregistre d’abord une clé API et son secret."
        }
    }
}

actor Trading212Client {
    private let environment: Trading212Environment
    private let credentials: Trading212Credentials
    private let session: URLSession
    private let decoder: JSONDecoder

    init(
        environment: Trading212Environment,
        credentials: Trading212Credentials,
        session: URLSession = .shared
    ) {
        self.environment = environment
        self.credentials = credentials
        self.session = session
        self.decoder = Self.makeDecoder()
    }

    func accountSummary() async throws -> Trading212AccountSummary {
        try await request("/api/v0/equity/account/summary", as: Trading212AccountSummary.self)
    }

    func snapshot(since: Date? = nil) async throws -> Trading212Snapshot {
        async let account = accountSummary()
        async let positions = request(
            "/api/v0/equity/positions",
            as: [Trading212Position].self
        )
        async let orders = collectPages(
            startingAt: "/api/v0/equity/history/orders?limit=50",
            itemType: Trading212HistoricalOrder.self,
            since: since
        )
        async let dividends = collectPages(
            startingAt: "/api/v0/equity/history/dividends?limit=50",
            itemType: Trading212Dividend.self,
            since: since
        )

        let values = try await (account, positions, orders, dividends)
        return Trading212Snapshot(
            account: values.0,
            positions: values.1,
            orders: values.2,
            dividends: values.3
        )
    }

    private func collectPages<Item: Decodable & Sendable & Trading212DatedItem>(
        startingAt firstPath: String,
        itemType: Item.Type,
        since: Date?
    ) async throws -> [Item] {
        var path: String? = firstPath
        var visitedPaths = Set<String>()
        var items: [Item] = []

        while let currentPath = path, visitedPaths.insert(currentPath).inserted {
            let page = try await request(currentPath, as: Trading212Page<Item>.self)
            items.append(contentsOf: page.items)
            if let since, page.items.contains(where: { ($0.trading212EventDate ?? .distantFuture) <= since }) {
                break
            }
            path = page.nextPagePath?.isEmpty == false ? page.nextPagePath : nil
        }
        return items
    }

    private func request<Value: Decodable>(_ path: String, as type: Value.Type) async throws -> Value {
        let url = try validatedURL(for: path)
        var request = URLRequest(url: url)
        let rawCredentials = "\(credentials.apiKey):\(credentials.apiSecret)"
        guard let credentialData = rawCredentials.data(using: .utf8) else {
            throw Trading212Error.invalidCredentials
        }
        request.setValue("Basic \(credentialData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NexaPortfolio/1.4", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        for attempt in 0..<2 {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw Trading212Error.invalidResponse
            }

            if http.statusCode == 429, attempt == 0 {
                let wait = rateLimitWait(from: http)
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            }

            switch http.statusCode {
            case 200...299:
                do {
                    return try decoder.decode(Value.self, from: data)
                } catch {
                    throw Trading212Error.invalidResponse
                }
            case 401:
                throw Trading212Error.invalidCredentials
            case 403:
                throw Trading212Error.permissionDenied
            case 429:
                throw Trading212Error.rateLimited
            default:
                throw Trading212Error.server(http.statusCode, serverMessage(from: data))
            }
        }
        throw Trading212Error.rateLimited
    }

    private func validatedURL(for path: String) throws -> URL {
        if let absoluteURL = URL(string: path), absoluteURL.scheme != nil {
            guard absoluteURL.scheme == "https", absoluteURL.host == environment.hostURL.host else {
                throw Trading212Error.invalidURL
            }
            return absoluteURL
        }
        guard path.hasPrefix("/api/v0/"),
              let url = URL(string: path, relativeTo: environment.hostURL)?.absoluteURL
        else { throw Trading212Error.invalidURL }
        return url
    }

    private func rateLimitWait(from response: HTTPURLResponse) -> TimeInterval {
        if let value = response.value(forHTTPHeaderField: "x-ratelimit-reset"),
           let timestamp = TimeInterval(value) {
            return min(max(timestamp - Date.now.timeIntervalSince1970 + 0.5, 1), 65)
        }
        return 10
    }

    private func serverMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return object["message"] as? String
            ?? object["error"] as? String
            ?? object["detail"] as? String
            ?? ""
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Date ISO 8601 invalide")
        }
        return decoder
    }
}

struct Trading212Snapshot: Sendable {
    let account: Trading212AccountSummary
    let positions: [Trading212Position]
    let orders: [Trading212HistoricalOrder]
    let dividends: [Trading212Dividend]
}

struct Trading212SyncSummary: Sendable {
    let importedOrders: Int
    let importedDividends: Int
    let skippedDuplicates: Int
    let reconciledPositions: Int
    let accountCurrency: String
}

@MainActor
enum Trading212Importer {
    static func synchronize(
        snapshot: Trading212Snapshot,
        environment: Trading212Environment,
        into portfolio: Portfolio,
        context: ModelContext
    ) async throws -> Trading212SyncSummary {
        let symbolMap = await resolveSymbols(in: snapshot)
        let allTransactions = try context.fetch(FetchDescriptor<TradeTransaction>())
        var knownIdentifiers = Set(allTransactions.compactMap(\.externalIdentifier))
        let source = "trading212:\(environment.rawValue):\(snapshot.account.id)"
        var importedOrders = 0
        var importedDividends = 0
        var duplicates = 0

        for historyItem in snapshot.orders {
            guard let fill = historyItem.fill,
                  let side = historyItem.order.side?.uppercased(),
                  side == "BUY" || side == "SELL",
                  let price = fill.price,
                  price >= 0
            else { continue }

            let quantity = abs(fill.quantity ?? historyItem.order.filledQuantity ?? 0)
            guard quantity > 0 else { continue }
            let ticker = historyItem.order.instrument?.ticker
                ?? historyItem.order.ticker
                ?? "INCONNU"
            let identifierComponent = fill.id.map { String($0) }
                ?? "\(historyItem.order.id.map { String($0) } ?? "order")-\(Int((fill.filledAt ?? historyItem.order.createdAt ?? .distantPast).timeIntervalSince1970 * 1_000))"
            let identifier = "\(source):fill:\(identifierComponent)"
            guard knownIdentifiers.insert(identifier).inserted else {
                duplicates += 1
                continue
            }

            let instrument = historyItem.order.instrument
            let currency = instrument?.effectiveCurrency
                ?? historyItem.order.currency
                ?? portfolio.currencyCode
            let fees = (fill.walletImpact?.taxes ?? [])
                .filter { $0.currency == currency }
                .reduce(0) { $0 + abs($1.quantity ?? 0) }
            let transaction = TradeTransaction(
                kind: side == "BUY" ? .buy : .sell,
                symbol: symbolMap[ticker] ?? Trading212SymbolMapper.fallback(ticker: ticker, currency: currency),
                displayName: instrument?.name ?? ticker,
                quantity: quantity,
                price: price,
                fees: fees,
                currencyCode: currency,
                date: fill.filledAt ?? historyItem.order.createdAt ?? .now,
                notes: "Import automatique Trading 212",
                externalSource: source,
                externalIdentifier: identifier,
                brokerTicker: ticker,
                portfolio: portfolio
            )
            context.insert(transaction)
            importedOrders += 1
        }

        for dividend in snapshot.dividends {
            let ticker = dividend.instrument?.ticker ?? dividend.ticker ?? "INCONNU"
            let date = dividend.paidOn ?? .now
            let reference = dividend.reference?.isEmpty == false
                ? dividend.reference!
                : "\(ticker)-\(Int(date.timeIntervalSince1970))-\(dividend.amount ?? 0)"
            let identifier = "\(source):dividend:\(reference)"
            guard knownIdentifiers.insert(identifier).inserted else {
                duplicates += 1
                continue
            }

            let currency = dividend.currency ?? snapshot.account.currency
            let perShare = dividend.grossAmountPerShare ?? 0
            let transaction = TradeTransaction(
                kind: .dividend,
                symbol: symbolMap[ticker] ?? Trading212SymbolMapper.fallback(ticker: ticker, currency: dividend.tickerCurrency),
                displayName: dividend.instrument?.name ?? ticker,
                quantity: dividend.quantity ?? 0,
                price: dividend.amount ?? 0,
                currencyCode: currency,
                date: date,
                notes: "Import Trading 212 · \(perShare.currency(dividend.tickerCurrency ?? currency)) par action",
                externalSource: source,
                externalIdentifier: identifier,
                brokerTicker: ticker,
                portfolio: portfolio
            )
            context.insert(transaction)
            importedDividends += 1
        }

        try context.save()
        try PortfolioLedger.rebuildHoldings(in: portfolio, context: context)

        for position in snapshot.positions where position.quantity > 0 {
            let ticker = position.instrument.ticker ?? "INCONNU"
            let currency = position.instrument.effectiveCurrency
            let symbol = symbolMap[ticker] ?? Trading212SymbolMapper.fallback(ticker: ticker, currency: currency)
            let holding: Holding
            if let existing = portfolio.holdings.first(where: { $0.symbol == symbol }) {
                holding = existing
            } else {
                holding = Holding(
                    symbol: symbol,
                    displayName: position.instrument.name ?? ticker,
                    quantity: position.quantity,
                    averageCost: position.averagePricePaid,
                    currentPrice: position.currentPrice,
                    currencyCode: currency,
                    portfolio: portfolio
                )
                context.insert(holding)
            }
            holding.displayName = position.instrument.name ?? holding.displayName
            holding.quantity = position.quantity
            holding.averageCost = position.averagePricePaid
            holding.currentPrice = position.currentPrice
            if holding.previousClose == 0 { holding.previousClose = position.currentPrice }
            holding.currencyCode = currency
        }

        portfolio.currencyCode = snapshot.account.currency
        portfolio.cashBalance = snapshot.account.cash.total
        try context.save()

        return Trading212SyncSummary(
            importedOrders: importedOrders,
            importedDividends: importedDividends,
            skippedDuplicates: duplicates,
            reconciledPositions: snapshot.positions.count,
            accountCurrency: snapshot.account.currency
        )
    }

    private static func resolveSymbols(in snapshot: Trading212Snapshot) async -> [String: String] {
        var instruments: [String: Trading212Instrument] = [:]
        for position in snapshot.positions {
            if let ticker = position.instrument.ticker { instruments[ticker] = position.instrument }
        }
        for item in snapshot.orders {
            if let instrument = item.order.instrument, let ticker = instrument.ticker {
                instruments[ticker] = instrument
            }
        }
        for dividend in snapshot.dividends {
            if let instrument = dividend.instrument, let ticker = instrument.ticker {
                instruments[ticker] = instrument
            }
        }

        return await withTaskGroup(of: (String, String).self, returning: [String: String].self) { group in
            for (ticker, instrument) in instruments {
                group.addTask {
                    if let isin = instrument.isin, !isin.isEmpty,
                       let results = try? await MarketDataClient.shared.search(isin),
                       let match = results.first {
                        return (ticker, match.symbol.uppercased())
                    }
                    return (
                        ticker,
                        Trading212SymbolMapper.fallback(ticker: ticker, currency: instrument.effectiveCurrency)
                    )
                }
            }

            var resolved: [String: String] = [:]
            for await (ticker, symbol) in group { resolved[ticker] = symbol }
            return resolved
        }
    }
}

private enum Trading212SymbolMapper {
    static func fallback(ticker: String, currency: String?) -> String {
        let suffixes: [(String, String)] = [
            ("_US_EQ", ""),
            ("_FR_EQ", ".PA"),
            ("_DE_EQ", ".DE"),
            ("_NL_EQ", ".AS"),
            ("_IT_EQ", ".MI"),
            ("_ES_EQ", ".MC"),
            ("_CH_EQ", ".SW")
        ]
        for (suffix, marketSuffix) in suffixes where ticker.uppercased().hasSuffix(suffix) {
            let base = String(ticker.dropLast(suffix.count))
            if base.caseInsensitiveCompare("BRKa") == .orderedSame { return "BRK-A" }
            if base.caseInsensitiveCompare("BRKb") == .orderedSame { return "BRK-B" }
            return base.uppercased() + marketSuffix
        }

        if ticker.uppercased().hasSuffix("_EQ") {
            let base = String(ticker.dropLast(3)).uppercased()
            if currency == "GBX" || currency == "GBP" { return base + ".L" }
            return base
        }
        return ticker.uppercased()
    }
}

private struct Trading212Page<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
    let nextPagePath: String?
}

struct Trading212AccountSummary: Decodable, Sendable {
    let cash: Cash
    let currency: String
    let id: Int64
    let totalValue: Double?

    struct Cash: Decodable, Sendable {
        let availableToTrade: Double?
        let inPies: Double?
        let reservedForOrders: Double?

        var total: Double {
            (availableToTrade ?? 0) + (inPies ?? 0) + (reservedForOrders ?? 0)
        }
    }
}

struct Trading212Instrument: Decodable, Sendable {
    let ticker: String?
    let name: String?
    let isin: String?
    let currency: String?
    let currencyCode: String?

    var effectiveCurrency: String { currency ?? currencyCode ?? "EUR" }
}

struct Trading212Position: Decodable, Sendable {
    let averagePricePaid: Double
    let currentPrice: Double
    let instrument: Trading212Instrument
    let quantity: Double
}

struct Trading212HistoricalOrder: Decodable, Sendable {
    let order: Order
    let fill: Fill?

    struct Order: Decodable, Sendable {
        let id: Int64?
        let ticker: String?
        let instrument: Trading212Instrument?
        let currency: String?
        let filledQuantity: Double?
        let side: String?
        let status: String?
        let createdAt: Date?
    }

    struct Fill: Decodable, Sendable {
        let id: Int64?
        let quantity: Double?
        let price: Double?
        let filledAt: Date?
        let walletImpact: WalletImpact?
    }

    struct WalletImpact: Decodable, Sendable {
        let currency: String?
        let fxRate: Double?
        let netValue: Double?
        let taxes: [Tax]?
    }

    struct Tax: Decodable, Sendable {
        let name: String?
        let quantity: Double?
        let currency: String?
    }
}

extension Trading212HistoricalOrder: Trading212DatedItem {
    fileprivate var trading212EventDate: Date? { fill?.filledAt ?? order.createdAt }
}

struct Trading212Dividend: Decodable, Sendable {
    let amount: Double?
    let currency: String?
    let grossAmountPerShare: Double?
    let instrument: Trading212Instrument?
    let paidOn: Date?
    let quantity: Double?
    let reference: String?
    let ticker: String?
    let tickerCurrency: String?
    let type: String?
}

extension Trading212Dividend: Trading212DatedItem {
    fileprivate var trading212EventDate: Date? { paidOn }
}

private protocol Trading212DatedItem {
    var trading212EventDate: Date? { get }
}
