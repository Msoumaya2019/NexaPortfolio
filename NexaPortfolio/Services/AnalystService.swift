import Foundation
import Security

enum AnalystDataError: LocalizedError {
    case invalidURL
    case invalidResponse
    case apiMessage(String)
    case noData(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "L’adresse du service d’analyse est invalide."
        case .invalidResponse: return "La réponse du service d’analyse est illisible."
        case let .apiMessage(message): return message
        case let .noData(symbol): return "Aucune donnée d’analyse n’est disponible pour \(symbol)."
        case let .keychain(status): return "Le Trousseau iOS a renvoyé l’erreur \(status)."
        }
    }
}

enum AnalystProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case twelveData
    case finnhub
    case alphaVantage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .twelveData: return "Twelve Data"
        case .finnhub: return "Finnhub"
        case .alphaVantage: return "Alpha Vantage"
        }
    }

    var badgeTitle: String { title.uppercased() }

    var websiteURL: URL {
        switch self {
        case .twelveData: return URL(string: "https://twelvedata.com/")!
        case .finnhub: return URL(string: "https://finnhub.io/")!
        case .alphaVantage: return URL(string: "https://www.alphavantage.co/")!
        }
    }

    var signupURL: URL {
        switch self {
        case .twelveData: return URL(string: "https://twelvedata.com/pricing")!
        case .finnhub: return URL(string: "https://finnhub.io/register")!
        case .alphaVantage: return URL(string: "https://www.alphavantage.co/support/#api-key")!
        }
    }

    fileprivate var keychainService: String {
        switch self {
        case .twelveData: return "com.msoumaya2019.nexaportfolio.twelvedata"
        case .finnhub: return "com.msoumaya2019.nexaportfolio.finnhub"
        case .alphaVantage: return "com.msoumaya2019.nexaportfolio.alphavantage"
        }
    }
}

struct AnalystSnapshot: Codable, Identifiable, Sendable {
    let provider: AnalystProvider
    let symbol: String
    let companyName: String
    let currencyCode: String
    let targetPrice: Double?
    let strongBuy: Int
    let buy: Int
    let hold: Int
    let sell: Int
    let strongSell: Int
    let quarterlyRevenueGrowth: Double?
    let quarterlyEarningsGrowth: Double?
    let forwardPE: Double?
    let trailingPE: Double?
    let priceToBook: Double?
    let pegRatio: Double?
    let debtToEquity: Double?
    let profitMargin: Double?
    let beta: Double?
    let week52High: Double?
    let week52Low: Double?
    let latestQuarter: String?
    let fetchedAt: Date

    var id: String { provider.rawValue + ":" + symbol.uppercased() }
    var analystCount: Int { strongBuy + buy + hold + sell + strongSell }
    var positiveCount: Int { strongBuy + buy }
    var negativeCount: Int { sell + strongSell }
    var usablePE: Double? { forwardPE ?? trailingPE }
    var hasUsefulData: Bool {
        targetPrice != nil || analystCount > 0 || usablePE != nil || priceToBook != nil
    }

    func targetChangePercent(from currentPrice: Double) -> Double? {
        guard let targetPrice, targetPrice > 0, currentPrice > 0 else { return nil }
        return (targetPrice / currentPrice - 1) * 100
    }

    var consensusLabel: String {
        guard analystCount > 0 else { return "Consensus indisponible" }
        let positiveShare = Double(positiveCount) / Double(analystCount)
        let negativeShare = Double(negativeCount) / Double(analystCount)
        if positiveShare >= 0.7 { return "Très majoritairement positif" }
        if positiveShare >= 0.5 { return "Majoritairement positif" }
        if negativeShare >= 0.5 { return "Majoritairement négatif" }
        return "Partagé ou neutre"
    }
}

struct LocalAIAssessment: Sendable {
    let verdict: String
    let score: Int
    let confidence: String
    let summary: String
    let strengths: [String]
    let risks: [String]
}

extension LocalAIAssessment {
    static func make(from snapshots: [AnalystSnapshot], currentPrice: Double) -> LocalAIAssessment {
        var score = 50.0
        var evidence = 0
        var strengths: [String] = []
        var risks: [String] = []

        let targetChanges = snapshots.compactMap { $0.targetChangePercent(from: currentPrice) }
        if !targetChanges.isEmpty {
            let change = targetChanges.reduce(0, +) / Double(targetChanges.count)
            score += min(max(change, -50), 50) * 0.25
            evidence += 1
            let formatted = abs(change).formatted(.number.precision(.fractionLength(1)))
            if change >= 5 {
                strengths.append("objectifs publiés supérieurs en moyenne de \(formatted) % au cours")
            } else if change <= -5 {
                risks.append("objectifs publiés inférieurs en moyenne de \(formatted) % au cours")
            }
        }

        let analystCount = snapshots.reduce(0) { $0 + $1.analystCount }
        let positiveCount = snapshots.reduce(0) { $0 + $1.positiveCount }
        let negativeCount = snapshots.reduce(0) { $0 + $1.negativeCount }
        if analystCount > 0 {
            let netOpinion = Double(positiveCount - negativeCount) / Double(analystCount)
            score += netOpinion * 18
            evidence += 1
            if netOpinion >= 0.25 {
                strengths.append("consensus agrégé des analystes favorable")
            } else if netOpinion <= -0.25 {
                risks.append("consensus agrégé des analystes défavorable")
            }
        }

        if let revenue = average(snapshots.compactMap(\.quarterlyRevenueGrowth)) {
            score += min(max(revenue, -0.5), 0.5) * 24
            evidence += 1
            if revenue >= 0.05 {
                strengths.append("chiffre d’affaires trimestriel en croissance")
            } else if revenue <= -0.05 {
                risks.append("chiffre d’affaires trimestriel en recul")
            }
        }

        if let earnings = average(snapshots.compactMap(\.quarterlyEarningsGrowth)) {
            score += min(max(earnings, -0.5), 0.5) * 24
            evidence += 1
            if earnings >= 0.05 {
                strengths.append("résultat trimestriel en croissance")
            } else if earnings <= -0.05 {
                risks.append("résultat trimestriel en recul")
            }
        }

        if let pe = median(snapshots.compactMap(\.usablePE).filter { $0 > 0 }) {
            evidence += 1
            switch pe {
            case ..<12:
                score += 7
                strengths.append("multiple de bénéfices modéré")
            case 12...25: score += 3
            case 40...:
                score -= 7
                risks.append("multiple de bénéfices élevé")
            default: score -= 1
            }
        }

        if let priceToBook = median(snapshots.compactMap(\.priceToBook).filter { $0 > 0 }) {
            evidence += 1
            if priceToBook < 1.5 {
                score += 4
                strengths.append("valorisation comptable modérée")
            } else if priceToBook > 8 {
                score -= 3
                risks.append("valorisation comptable élevée")
            }
        }

        if snapshots.compactMap(\.beta).contains(where: { $0 >= 1.4 }) {
            risks.append("volatilité historique élevée")
        }

        let boundedScore = Int(min(max(score.rounded(), 0), 100))
        let verdict: String
        switch boundedScore {
        case 72...: verdict = "Favorable"
        case 58..<72: verdict = "Plutôt favorable"
        case 43..<58: verdict = "Neutre"
        case 28..<43: verdict = "Prudence"
        default: verdict = "Défavorable"
        }

        let confidence: String
        switch evidence {
        case 6...: confidence = "Élevée"
        case 3...5: confidence = "Moyenne"
        default: confidence = "Limitée"
        }

        var summary = "Le modèle local classe actuellement ce titre « \(verdict.lowercased()) » avec un score de \(boundedScore)/100."
        if snapshots.count > 1 { summary += " Il s’appuie sur \(snapshots.count) sources distinctes." }
        if let firstStrength = strengths.first { summary += " Point favorable principal : \(firstStrength)." }
        if let firstRisk = risks.first { summary += " Risque principal identifié : \(firstRisk)." }
        if evidence < 3 { summary += " Peu d’indicateurs sont disponibles : cet avis est donc fragile." }

        return LocalAIAssessment(
            verdict: verdict,
            score: boundedScore,
            confidence: confidence,
            summary: summary,
            strengths: Array(strengths.uniqued().prefix(4)),
            risks: Array(risks.uniqued().prefix(4))
        )
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        if sorted.count.isMultiple(of: 2) {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return sorted[sorted.count / 2]
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

enum AnalystAPIKeychain {
    private static let account = "personal-api-key"

    static func save(_ apiKey: String, for provider: AnalystProvider) throws {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let query = baseQuery(provider: provider)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw AnalystDataError.keychain(status) }
    }

    static func load(for provider: AnalystProvider) throws -> String? {
        var query = baseQuery(provider: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { throw AnalystDataError.keychain(status) }
        return value
    }

    static func delete(for provider: AnalystProvider) throws {
        let status = SecItemDelete(baseQuery(provider: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AnalystDataError.keychain(status)
        }
    }

    static func configuredKeys() throws -> [AnalystProvider: String] {
        var result: [AnalystProvider: String] = [:]
        for provider in AnalystProvider.allCases {
            if let key = try load(for: provider), !key.isEmpty { result[provider] = key }
        }
        return result
    }

    static func save(_ apiKey: String) throws { try save(apiKey, for: .alphaVantage) }
    static func load() throws -> String? { try load(for: .alphaVantage) }
    static func delete() throws { try delete(for: .alphaVantage) }

    private static func baseQuery(provider: AnalystProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.keychainService,
            kSecAttrAccount as String: account
        ]
    }
}

actor AnalystDataClient {
    static let shared = AnalystDataClient()
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func snapshot(
        for rawSymbol: String,
        apiKey: String,
        provider: AnalystProvider = .alphaVantage
    ) async throws -> AnalystSnapshot {
        switch provider {
        case .alphaVantage: return try await alphaVantageSnapshot(for: rawSymbol, apiKey: apiKey)
        case .twelveData: return try await twelveDataSnapshot(for: rawSymbol, apiKey: apiKey)
        case .finnhub: return try await finnhubSnapshot(for: rawSymbol, apiKey: apiKey)
        }
    }

    private func alphaVantageSnapshot(for rawSymbol: String, apiKey: String) async throws -> AnalystSnapshot {
        let symbol = normalized(rawSymbol)
        let payload = try await dictionary(baseURL: "https://www.alphavantage.co/query", queryItems: [
            URLQueryItem(name: "function", value: "OVERVIEW"),
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "apikey", value: apiKey)
        ])
        try validate(payload: payload)
        guard let returnedSymbol = string("Symbol", in: payload), !returnedSymbol.isEmpty else {
            throw AnalystDataError.noData(symbol)
        }

        let snapshot = AnalystSnapshot(
            provider: .alphaVantage,
            symbol: returnedSymbol,
            companyName: string("Name", in: payload) ?? symbol,
            currencyCode: string("Currency", in: payload) ?? currency(for: symbol),
            targetPrice: number("AnalystTargetPrice", in: payload),
            strongBuy: integer("AnalystRatingStrongBuy", in: payload),
            buy: integer("AnalystRatingBuy", in: payload),
            hold: integer("AnalystRatingHold", in: payload),
            sell: integer("AnalystRatingSell", in: payload),
            strongSell: integer("AnalystRatingStrongSell", in: payload),
            quarterlyRevenueGrowth: number("QuarterlyRevenueGrowthYOY", in: payload),
            quarterlyEarningsGrowth: number("QuarterlyEarningsGrowthYOY", in: payload),
            forwardPE: number("ForwardPE", in: payload),
            trailingPE: number("TrailingPE", in: payload),
            priceToBook: number("PriceToBookRatio", in: payload),
            pegRatio: number("PEGRatio", in: payload),
            debtToEquity: nil,
            profitMargin: number("ProfitMargin", in: payload),
            beta: number("Beta", in: payload),
            week52High: number("52WeekHigh", in: payload),
            week52Low: number("52WeekLow", in: payload),
            latestQuarter: string("LatestQuarter", in: payload),
            fetchedAt: .now
        )
        guard snapshot.hasUsefulData else { throw AnalystDataError.noData(symbol) }
        return snapshot
    }

    private func twelveDataSnapshot(for rawSymbol: String, apiKey: String) async throws -> AnalystSnapshot {
        let raw = normalized(rawSymbol)
        let requestSymbol = raw.hasSuffix(".PA") ? String(raw.dropLast(3)) : raw
        var common = [URLQueryItem(name: "symbol", value: requestSymbol), URLQueryItem(name: "apikey", value: apiKey)]
        if raw.hasSuffix(".PA") { common.append(URLQueryItem(name: "exchange", value: "XPAR")) }

        let statistics = try await json(baseURL: "https://api.twelvedata.com/statistics", queryItems: common)
        try validateGeneric(payload: statistics, symbol: raw)
        let recommendations = try? await json(baseURL: "https://api.twelvedata.com/recommendations", queryItems: common)
        let targets = try? await json(baseURL: "https://api.twelvedata.com/price_target", queryItems: common)
        let recommendationNode = firstDictionary(
            in: recommendations ?? [],
            containingAny: ["strong_buy", "strongbuy", "buy", "hold", "sell", "strong_sell", "strongsell"]
        ) ?? [:]

        let snapshot = AnalystSnapshot(
            provider: .twelveData,
            symbol: recursiveString(keys: ["symbol"], in: statistics) ?? raw,
            companyName: recursiveString(keys: ["name", "company_name"], in: statistics) ?? raw,
            currencyCode: recursiveString(keys: ["currency", "currency_code"], in: statistics) ?? currency(for: raw),
            targetPrice: recursiveNumber(keys: ["target_mean", "mean", "price_target", "target_price", "target_median"], in: targets ?? [:]),
            strongBuy: flexibleInteger(keys: ["strong_buy", "strongbuy"], in: recommendationNode),
            buy: flexibleInteger(keys: ["buy"], in: recommendationNode),
            hold: flexibleInteger(keys: ["hold"], in: recommendationNode),
            sell: flexibleInteger(keys: ["sell"], in: recommendationNode),
            strongSell: flexibleInteger(keys: ["strong_sell", "strongsell"], in: recommendationNode),
            quarterlyRevenueGrowth: recursiveNumber(keys: ["quarterly_revenue_growth", "revenue_growth_quarterly_yoy"], in: statistics),
            quarterlyEarningsGrowth: recursiveNumber(keys: ["quarterly_earnings_growth", "earnings_growth_quarterly_yoy"], in: statistics),
            forwardPE: recursiveNumber(keys: ["forward_pe", "forward_price_to_earnings"], in: statistics),
            trailingPE: recursiveNumber(keys: ["trailing_pe", "price_to_earnings_ttm", "pe_ratio"], in: statistics),
            priceToBook: recursiveNumber(keys: ["price_to_book_mrq", "price_to_book", "pb_ratio"], in: statistics),
            pegRatio: recursiveNumber(keys: ["peg_ratio", "peg"], in: statistics),
            debtToEquity: recursiveNumber(keys: ["debt_to_equity_mrq", "debt_to_equity"], in: statistics),
            profitMargin: recursiveNumber(keys: ["profit_margin", "net_profit_margin_ttm"], in: statistics),
            beta: recursiveNumber(keys: ["beta"], in: statistics),
            week52High: recursiveNumber(keys: ["fifty_two_week_high", "52_week_high", "week_52_high"], in: statistics),
            week52Low: recursiveNumber(keys: ["fifty_two_week_low", "52_week_low", "week_52_low"], in: statistics),
            latestQuarter: recursiveString(keys: ["fiscal_date", "latest_quarter", "last_updated"], in: statistics),
            fetchedAt: .now
        )
        guard snapshot.hasUsefulData else { throw AnalystDataError.noData(raw) }
        return snapshot
    }

    private func finnhubSnapshot(for rawSymbol: String, apiKey: String) async throws -> AnalystSnapshot {
        let symbol = normalized(rawSymbol)
        let auth = [URLQueryItem(name: "symbol", value: symbol), URLQueryItem(name: "token", value: apiKey)]
        let metrics = try await json(baseURL: "https://finnhub.io/api/v1/stock/metric", queryItems: auth + [URLQueryItem(name: "metric", value: "all")])
        try validateGeneric(payload: metrics, symbol: symbol)
        let recommendations = try? await json(baseURL: "https://finnhub.io/api/v1/stock/recommendation", queryItems: auth)
        let targets = try? await json(baseURL: "https://finnhub.io/api/v1/stock/price-target", queryItems: auth)
        let recommendationNode = firstDictionary(
            in: recommendations ?? [],
            containingAny: ["strongBuy", "buy", "hold", "sell", "strongSell"]
        ) ?? [:]

        let snapshot = AnalystSnapshot(
            provider: .finnhub,
            symbol: symbol,
            companyName: symbol,
            currencyCode: currency(for: symbol),
            targetPrice: recursiveNumber(keys: ["targetMean", "targetMedian"], in: targets ?? [:]),
            strongBuy: flexibleInteger(keys: ["strongBuy"], in: recommendationNode),
            buy: flexibleInteger(keys: ["buy"], in: recommendationNode),
            hold: flexibleInteger(keys: ["hold"], in: recommendationNode),
            sell: flexibleInteger(keys: ["sell"], in: recommendationNode),
            strongSell: flexibleInteger(keys: ["strongSell"], in: recommendationNode),
            quarterlyRevenueGrowth: recursiveNumber(keys: ["revenueGrowthQuarterlyYoy", "revenueGrowthTTMYoy"], in: metrics),
            quarterlyEarningsGrowth: recursiveNumber(keys: ["epsGrowthQuarterlyYoy", "epsGrowthTTMYoy"], in: metrics),
            forwardPE: recursiveNumber(keys: ["forwardPE"], in: metrics),
            trailingPE: recursiveNumber(keys: ["peTTM", "peBasicExclExtraTTM"], in: metrics),
            priceToBook: recursiveNumber(keys: ["pbQuarterly", "pbAnnual"], in: metrics),
            pegRatio: recursiveNumber(keys: ["pegTTM"], in: metrics),
            debtToEquity: recursiveNumber(keys: ["totalDebtToEquityQuarterly", "totalDebtToEquityAnnual"], in: metrics),
            profitMargin: recursiveNumber(keys: ["netProfitMarginTTM", "netProfitMarginAnnual"], in: metrics).map(percentToFractionIfNeeded),
            beta: recursiveNumber(keys: ["beta"], in: metrics),
            week52High: recursiveNumber(keys: ["52WeekHigh"], in: metrics),
            week52Low: recursiveNumber(keys: ["52WeekLow"], in: metrics),
            latestQuarter: recursiveString(keys: ["period", "lastUpdated"], in: targets ?? [:]),
            fetchedAt: .now
        )
        guard snapshot.hasUsefulData else { throw AnalystDataError.noData(symbol) }
        return snapshot
    }

    private func normalized(_ symbol: String) -> String {
        symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func currency(for symbol: String) -> String { symbol.hasSuffix(".PA") ? "EUR" : "USD" }
    private func percentToFractionIfNeeded(_ value: Double) -> Double { abs(value) > 1 ? value / 100 : value }

    private func dictionary(baseURL: String, queryItems: [URLQueryItem]) async throws -> [String: Any] {
        let payload = try await json(baseURL: baseURL, queryItems: queryItems)
        guard let dictionary = payload as? [String: Any] else { throw AnalystDataError.invalidResponse }
        return dictionary
    }

    private func json(baseURL: String, queryItems: [URLQueryItem]) async throws -> Any {
        guard var components = URLComponents(string: baseURL) else { throw AnalystDataError.invalidURL }
        components.queryItems = queryItems
        guard let url = components.url else { throw AnalystDataError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("NexaPortfolio/2.7", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AnalystDataError.invalidResponse
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func validate(payload: [String: Any]) throws {
        if let message = payload["Error Message"] as? String { throw AnalystDataError.apiMessage(message) }
        if let message = payload["Note"] as? String { throw AnalystDataError.apiMessage(message) }
        if let message = payload["Information"] as? String, payload["Symbol"] == nil { throw AnalystDataError.apiMessage(message) }
        if let message = payload["message"] as? String, payload["Symbol"] == nil { throw AnalystDataError.apiMessage(message) }
    }

    private func validateGeneric(payload: Any, symbol: String) throws {
        if let dictionary = payload as? [String: Any] {
            if (dictionary["status"] as? String)?.lowercased() == "error" {
                throw AnalystDataError.apiMessage(
                    (dictionary["message"] as? String) ?? (dictionary["code"] as? String) ?? "Erreur du fournisseur pour \(symbol)."
                )
            }
            if let error = dictionary["error"] as? String, !error.isEmpty { throw AnalystDataError.apiMessage(error) }
        }
    }

    private func string(_ key: String, in payload: [String: Any]) -> String? {
        guard let value = payload[key] as? String,
              !value.isEmpty,
              value.lowercased() != "none",
              value.lowercased() != "null",
              value != "-"
        else { return nil }
        return value
    }

    private func number(_ key: String, in payload: [String: Any]) -> Double? {
        guard let value = string(key, in: payload) else { return nil }
        return Double(value.replacingOccurrences(of: ",", with: ""))
    }

    private func integer(_ key: String, in payload: [String: Any]) -> Int {
        guard let value = string(key, in: payload) else { return 0 }
        return Int(value) ?? Int(Double(value) ?? 0)
    }

    private func normalizedKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func recursiveNumber(keys: Set<String>, in payload: Any) -> Double? {
        let expected = Set(keys.map(normalizedKey))
        if let dictionary = payload as? [String: Any] {
            for (key, value) in dictionary where expected.contains(normalizedKey(key)) {
                if let number = value as? NSNumber { return number.doubleValue }
                if let text = value as? String,
                   let number = Double(text.replacingOccurrences(of: ",", with: "")) { return number }
            }
            for value in dictionary.values {
                if let result = recursiveNumber(keys: expected, in: value) { return result }
            }
        } else if let array = payload as? [Any] {
            for value in array {
                if let result = recursiveNumber(keys: expected, in: value) { return result }
            }
        }
        return nil
    }

    private func recursiveString(keys: Set<String>, in payload: Any) -> String? {
        let expected = Set(keys.map(normalizedKey))
        if let dictionary = payload as? [String: Any] {
            for (key, value) in dictionary where expected.contains(normalizedKey(key)) {
                if let text = value as? String, !text.isEmpty { return text }
            }
            for value in dictionary.values {
                if let result = recursiveString(keys: expected, in: value) { return result }
            }
        } else if let array = payload as? [Any] {
            for value in array {
                if let result = recursiveString(keys: expected, in: value) { return result }
            }
        }
        return nil
    }

    private func firstDictionary(in payload: Any, containingAny keys: Set<String>) -> [String: Any]? {
        let expected = Set(keys.map(normalizedKey))
        if let dictionary = payload as? [String: Any] {
            if dictionary.keys.contains(where: { expected.contains(normalizedKey($0)) }) { return dictionary }
            for value in dictionary.values {
                if let result = firstDictionary(in: value, containingAny: expected) { return result }
            }
        } else if let array = payload as? [Any] {
            for value in array {
                if let result = firstDictionary(in: value, containingAny: expected) { return result }
            }
        }
        return nil
    }

    private func flexibleInteger(keys: Set<String>, in payload: [String: Any]) -> Int {
        let expected = Set(keys.map(normalizedKey))
        for (key, value) in payload where expected.contains(normalizedKey(key)) {
            if let number = value as? NSNumber { return number.intValue }
            if let text = value as? String { return Int(Double(text) ?? 0) }
        }
        return 0
    }
}

enum AnalystSnapshotCache {
    private static let prefix = "analyst.snapshot.v2."
    static let validity: TimeInterval = 24 * 60 * 60

    static func load(symbol: String, provider: AnalystProvider, allowExpired: Bool = false) -> AnalystSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(symbol: symbol, provider: provider)),
              let snapshot = try? JSONDecoder().decode(AnalystSnapshot.self, from: data),
              allowExpired || Date.now.timeIntervalSince(snapshot.fetchedAt) < validity
        else { return nil }
        return snapshot
    }

    static func loadAll(symbol: String, allowExpired: Bool = false) -> [AnalystSnapshot] {
        AnalystProvider.allCases.compactMap { load(symbol: symbol, provider: $0, allowExpired: allowExpired) }
    }

    static func save(_ snapshot: AnalystSnapshot, requestedSymbol: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey(symbol: requestedSymbol, provider: snapshot.provider))
    }

    static func deleteAll(for symbols: [String]) {
        for symbol in symbols {
            for provider in AnalystProvider.allCases {
                UserDefaults.standard.removeObject(forKey: cacheKey(symbol: symbol, provider: provider))
            }
        }
    }

    private static func cacheKey(symbol: String, provider: AnalystProvider) -> String {
        prefix + provider.rawValue + "." + symbol.uppercased()
    }
}
