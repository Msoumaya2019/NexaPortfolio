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
        case .invalidURL:
            return "L’adresse du service d’analyse est invalide."
        case .invalidResponse:
            return "La réponse du service d’analyse est illisible."
        case let .apiMessage(message):
            return message
        case let .noData(symbol):
            return "Aucun consensus d’analystes n’est disponible pour \(symbol)."
        case let .keychain(status):
            return "Le Trousseau iOS a renvoyé l’erreur \(status)."
        }
    }
}

struct AnalystSnapshot: Codable, Sendable {
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
    let beta: Double?
    let week52High: Double?
    let week52Low: Double?
    let latestQuarter: String?
    let fetchedAt: Date

    var analystCount: Int {
        strongBuy + buy + hold + sell + strongSell
    }

    var positiveCount: Int { strongBuy + buy }
    var negativeCount: Int { sell + strongSell }

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

    func localAIAssessment(currentPrice: Double) -> LocalAIAssessment {
        var score = 50.0
        var evidence = 0
        var strengths: [String] = []
        var risks: [String] = []

        if let change = targetChangePercent(from: currentPrice) {
            score += min(max(change, -50), 50) * 0.25
            evidence += 1
            let formatted = abs(change).formatted(.number.precision(.fractionLength(1)))
            if change >= 5 {
                strengths.append("objectif moyen supérieur de \(formatted) % au cours")
            } else if change <= -5 {
                risks.append("objectif moyen inférieur de \(formatted) % au cours")
            }
        }

        if analystCount > 0 {
            let netOpinion = Double(positiveCount - negativeCount) / Double(analystCount)
            score += netOpinion * 18
            evidence += 1
            if netOpinion >= 0.25 {
                strengths.append("consensus d’analystes favorable")
            } else if netOpinion <= -0.25 {
                risks.append("consensus d’analystes défavorable")
            }
        }

        if let revenue = quarterlyRevenueGrowth {
            score += min(max(revenue, -0.5), 0.5) * 24
            evidence += 1
            if revenue >= 0.05 {
                strengths.append("chiffre d’affaires trimestriel en croissance")
            } else if revenue <= -0.05 {
                risks.append("chiffre d’affaires trimestriel en recul")
            }
        }

        if let earnings = quarterlyEarningsGrowth {
            score += min(max(earnings, -0.5), 0.5) * 24
            evidence += 1
            if earnings >= 0.05 {
                strengths.append("résultat trimestriel en croissance")
            } else if earnings <= -0.05 {
                risks.append("résultat trimestriel en recul")
            }
        }

        if let forwardPE, forwardPE > 0 {
            evidence += 1
            switch forwardPE {
            case ..<12:
                score += 5
                strengths.append("multiple de bénéfices anticipés modéré")
            case 12...28:
                score += 2
            case 40...:
                score -= 6
                risks.append("multiple de bénéfices anticipés élevé")
            default:
                score -= 2
            }
        }

        if let beta, beta >= 1.4 {
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
        case 5...: confidence = "Élevée"
        case 3...4: confidence = "Moyenne"
        default: confidence = "Limitée"
        }

        var summary = "Le modèle local classe actuellement ce titre « \(verdict.lowercased()) » avec un score de \(boundedScore)/100."
        if let firstStrength = strengths.first {
            summary += " Point favorable principal : \(firstStrength)."
        }
        if let firstRisk = risks.first {
            summary += " Risque principal identifié : \(firstRisk)."
        }
        if evidence < 3 {
            summary += " Peu d’indicateurs sont disponibles : cet avis est donc fragile."
        }

        return LocalAIAssessment(
            verdict: verdict,
            score: boundedScore,
            confidence: confidence,
            summary: summary,
            strengths: Array(strengths.prefix(3)),
            risks: Array(risks.prefix(3))
        )
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

enum AnalystAPIKeychain {
    private static let service = "com.msoumaya2019.nexaportfolio.alphavantage"
    private static let account = "personal-api-key"

    static func save(_ apiKey: String) throws {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let query = baseQuery()
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw AnalystDataError.keychain(status) }
    }

    static func load() throws -> String? {
        var query = baseQuery()
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

    static func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AnalystDataError.keychain(status)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

actor AnalystDataClient {
    static let shared = AnalystDataClient()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func snapshot(for rawSymbol: String, apiKey: String) async throws -> AnalystSnapshot {
        let symbol = rawSymbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard var components = URLComponents(string: "https://www.alphavantage.co/query") else {
            throw AnalystDataError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "function", value: "OVERVIEW"),
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "apikey", value: apiKey)
        ]
        guard let url = components.url else { throw AnalystDataError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("NexaPortfolio/1.8", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else { throw AnalystDataError.invalidResponse }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnalystDataError.invalidResponse
        }
        if let message = payload["Error Message"] as? String {
            throw AnalystDataError.apiMessage(message)
        }
        if let message = payload["Note"] as? String {
            throw AnalystDataError.apiMessage(message)
        }
        if let message = payload["Information"] as? String,
           payload["Symbol"] == nil {
            throw AnalystDataError.apiMessage(message)
        }
        guard let returnedSymbol = string("Symbol", in: payload), !returnedSymbol.isEmpty else {
            throw AnalystDataError.noData(symbol)
        }

        let snapshot = AnalystSnapshot(
            symbol: returnedSymbol,
            companyName: string("Name", in: payload) ?? symbol,
            currencyCode: string("Currency", in: payload) ?? "USD",
            targetPrice: number("AnalystTargetPrice", in: payload),
            strongBuy: integer("AnalystRatingStrongBuy", in: payload),
            buy: integer("AnalystRatingBuy", in: payload),
            hold: integer("AnalystRatingHold", in: payload),
            sell: integer("AnalystRatingSell", in: payload),
            strongSell: integer("AnalystRatingStrongSell", in: payload),
            quarterlyRevenueGrowth: number("QuarterlyRevenueGrowthYOY", in: payload),
            quarterlyEarningsGrowth: number("QuarterlyEarningsGrowthYOY", in: payload),
            forwardPE: number("ForwardPE", in: payload),
            beta: number("Beta", in: payload),
            week52High: number("52WeekHigh", in: payload),
            week52Low: number("52WeekLow", in: payload),
            latestQuarter: string("LatestQuarter", in: payload),
            fetchedAt: .now
        )

        guard snapshot.targetPrice != nil || snapshot.analystCount > 0 else {
            throw AnalystDataError.noData(symbol)
        }
        return snapshot
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
}

enum AnalystSnapshotCache {
    private static let prefix = "analyst.snapshot."
    static let validity: TimeInterval = 24 * 60 * 60

    static func load(symbol: String, allowExpired: Bool = false) -> AnalystSnapshot? {
        let key = prefix + symbol.uppercased()
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(AnalystSnapshot.self, from: data),
              allowExpired || Date.now.timeIntervalSince(snapshot.fetchedAt) < validity
        else { return nil }
        return snapshot
    }

    static func save(_ snapshot: AnalystSnapshot, requestedSymbol: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: prefix + requestedSymbol.uppercased())
    }

    static func deleteAll(for symbols: [String]) {
        for symbol in symbols {
            UserDefaults.standard.removeObject(forKey: prefix + symbol.uppercased())
        }
    }
}
