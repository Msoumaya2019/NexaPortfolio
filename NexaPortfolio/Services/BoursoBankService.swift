import CryptoKit
import Foundation
import Security
import SwiftData

enum BoursoBankError: LocalizedError {
    case invalidURL
    case invalidCredentials
    case invalidPassword
    case invalidResponse
    case unsupportedMFA
    case mfaRequired
    case mfaQRCodeRequired
    case notAuthenticated
    case noTradingAccount
    case sessionExpired
    case synchronizationAlreadyRunning
    case server(Int)
    case incompatiblePage(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Adresse BoursoBank invalide."
        case .invalidCredentials:
            return "Identifiant ou mot de passe BoursoBank invalide."
        case .invalidPassword:
            return "Le mot de passe BoursoBank doit contenir uniquement des chiffres."
        case .invalidResponse:
            return "La réponse de BoursoBank est illisible ou incomplète."
        case .unsupportedMFA:
            return "Cette méthode de validation forte n’est pas prise en charge. Active la validation depuis l’application BoursoBank."
        case .mfaRequired:
            return "Une validation dans l’application BoursoBank est nécessaire."
        case .mfaQRCodeRequired:
            return "BoursoBank demande une validation par QR code, non compatible avec la connexion depuis le même iPhone."
        case .notAuthenticated:
            return "La session BoursoBank n’est pas authentifiée. Reconnecte le compte."
        case .noTradingAccount:
            return "Aucun PEA ou compte-titres BoursoBank n’a été détecté."
        case .sessionExpired:
            return "La session BoursoBank a expiré. Reconnecte le compte puis relance la synchronisation."
        case .synchronizationAlreadyRunning:
            return "Une synchronisation BoursoBank est déjà en cours."
        case let .server(code):
            return "BoursoBank a renvoyé une erreur HTTP \(code)."
        case let .incompatiblePage(detail):
            return "BoursoBank a modifié sa page de connexion (\(detail)). Une mise à jour de Nexa Portfolio sera nécessaire."
        case let .keychain(status):
            return "Le trousseau iOS n’a pas pu enregistrer l’identifiant BoursoBank (code \(status))."
        }
    }
}

enum BoursoBankCustomerIDKeychain {
    private static let service = "com.msoumaya2019.nexaportfolio.boursobank"
    private static let account = "customer-id"

    static func save(_ customerID: String) throws {
        let data = Data(customerID.utf8)
        let query = baseQuery
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw BoursoBankError.keychain(status) }
    }

    static func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { throw BoursoBankError.keychain(status) }
        return value
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BoursoBankError.keychain(status)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum BoursoBankSessionKeychain {
    private static let service = "com.msoumaya2019.nexaportfolio.boursobank"
    private static let account = "authenticated-session"

    static func save(_ session: BoursoBankStoredSession) throws {
        let data = try JSONEncoder().encode(session)
        let query = baseQuery
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw BoursoBankError.keychain(status) }
    }

    static func load() throws -> BoursoBankStoredSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw BoursoBankError.keychain(status)
        }
        return try JSONDecoder().decode(BoursoBankStoredSession.self, from: data)
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BoursoBankError.keychain(status)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum BoursoBankLoginResult: Sendable {
    case authenticated
    case mfaRequired
}

struct BoursoBankMFAChallenge: Sendable {
    let otpID: String
    let formState: String
    let token: String
}

struct BoursoBankTradingAccount: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let displayedBalance: Double
    let bankName: String
}

struct BoursoBankSummaryValue: Decodable, Sendable {
    let value: Double
    let decimals: Int
    let currency: String?

    private enum CodingKeys: String, CodingKey {
        case value, decimals, currency
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = Self.decodeDouble(container, forKey: .value) ?? 0
        decimals = Self.decodeInt(container, forKey: .decimals) ?? 2
        currency = try? container.decodeIfPresent(String.self, forKey: .currency)
    }

    private static func decodeDouble(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return Double(value) }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(value.replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }

    private static func decodeInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return Int(value) }
        return nil
    }
}

struct BoursoBankPosition: Decodable, Sendable {
    let symbol: String
    let label: String
    let permalink: String?
    let quantity: BoursoBankSummaryValue
    let buyingPrice: BoursoBankSummaryValue
    let amount: BoursoBankSummaryValue
    let last: BoursoBankSummaryValue
    let variation: BoursoBankSummaryValue?
    let gainLoss: BoursoBankSummaryValue?
    let gainLossPercent: BoursoBankSummaryValue?
    let lastMovementDate: String?

    private enum CodingKeys: String, CodingKey {
        case symbol, label, permalink, quantity, buyingPrice, amount, last
        case variation = "var"
        case gainLoss, gainLossPercent, lastMovementDate
    }
}

struct BoursoBankAccountSummary: Decodable, Sendable {
    let name: String?
    let currency: String?
    let cash: BoursoBankSummaryValue?
    let valuation: BoursoBankSummaryValue?
    let total: BoursoBankSummaryValue?
    let gainLoss: BoursoBankSummaryValue?
    let gainLossPercent: BoursoBankSummaryValue?
}

struct BoursoBankTradingSummaryItem: Decodable, Sendable {
    let id: String
    let account: BoursoBankAccountSummary?
    let positions: [BoursoBankPosition]?
}

struct BoursoBankInstrumentQuote: Decodable, Sendable {
    let symbol: String?
    let label: String?
    let isin: String?
    let last: Double?
    let currency: String?
    let previousClose: Double?
    let exchangeCode: String?

    private enum CodingKeys: String, CodingKey {
        case symbol, label, isin, last, currency, previousClose, exchangeCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try? container.decodeIfPresent(String.self, forKey: .symbol)
        label = try? container.decodeIfPresent(String.self, forKey: .label)
        isin = try? container.decodeIfPresent(String.self, forKey: .isin)
        currency = try? container.decodeIfPresent(String.self, forKey: .currency)
        exchangeCode = try? container.decodeIfPresent(String.self, forKey: .exchangeCode)
        last = Self.number(in: container, key: .last)
        previousClose = Self.number(in: container, key: .previousClose)
    }

    private static func number(
        in container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Double? {
        if let number = try? container.decodeIfPresent(Double.self, forKey: key) { return number }
        if let number = try? container.decodeIfPresent(Int.self, forKey: key) { return Double(number) }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(text.replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }
}

struct BoursoBankSnapshot: Sendable {
    let account: BoursoBankTradingAccount
    let summary: BoursoBankAccountSummary
    let positions: [BoursoBankPosition]
}

private struct BoursoBankWebConfiguration: Codable, Sendable {
    let apiURL: String
    let userHash: String?

    private enum CodingKeys: String, CodingKey {
        case apiURL = "API_URL"
        case userHash = "USER_HASH"
    }
}

private final class BoursoBankNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct BoursoBankSessionCookie: Codable, Sendable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let secure: Bool
    let expiresAt: Date?

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        path = cookie.path.isEmpty ? "/" : cookie.path
        secure = cookie.isSecure
        expiresAt = cookie.expiresDate
    }

    init(name: String, value: String, domain: String, path: String = "/") {
        self.name = name
        self.value = value
        self.domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        self.path = path
        self.secure = true
        self.expiresAt = nil
    }

    func matches(_ url: URL, now: Date = .now) -> Bool {
        guard let host = url.host?.lowercased(),
              host == domain || host.hasSuffix(".\(domain)"),
              url.path.hasPrefix(path),
              !secure || url.scheme == "https",
              expiresAt.map({ $0 > now }) ?? true
        else { return false }
        return true
    }

    var key: String { "\(name)|\(domain)|\(path)" }
}

struct BoursoBankStoredSession: Codable, Sendable {
    fileprivate let cookies: [BoursoBankSessionCookie]
    fileprivate let webConfiguration: BoursoBankWebConfiguration
    let savedAt: Date
}

actor BoursoBankClient {
    private let baseURL = URL(string: "https://clients.boursobank.com")!
    private let redirectDelegate: BoursoBankNoRedirectDelegate
    private let session: URLSession
    private var cookies: [String: BoursoBankSessionCookie] = [:]
    private var webConfiguration: BoursoBankWebConfiguration?
    private var formToken = ""
    private var virtualPadKeys: [String] = []
    private var challengeID = ""
    private var authenticated = false

    init(storedSession: BoursoBankStoredSession? = nil) {
        let delegate = BoursoBankNoRedirectDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        redirectDelegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        if let storedSession {
            cookies = Dictionary(uniqueKeysWithValues: storedSession.cookies.map { ($0.key, $0) })
            webConfiguration = storedSession.webConfiguration
            authenticated = true
        }
    }

    func initializeAndLogin(customerID: String, password: String) async throws -> BoursoBankLoginResult {
        let normalizedCustomerID = customerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCustomerID.isEmpty else { throw BoursoBankError.invalidCredentials }
        guard !password.isEmpty, password.allSatisfy(\.isNumber) else {
            throw BoursoBankError.invalidPassword
        }

        cookies.removeAll()
        authenticated = false
        let initialPage = try await getText(path: "/connexion/")
        guard let mitigationCookie = initialPage.firstCapture(for: #"__brs_mit=([^;]+);"#) else {
            throw BoursoBankError.incompatiblePage("cookie de connexion introuvable")
        }
        setCookie(name: "brsDomainMigration", value: "migrated", domain: "clients.boursobank.com")
        setCookie(name: "__brs_mit", value: mitigationCookie, domain: "clients.boursobank.com")

        let loginPage = try await getText(path: "/connexion/")
        formToken = try Self.extractFormToken(from: loginPage)
        webConfiguration = try Self.extractConfiguration(from: loginPage)

        let padPage = try await getText(path: "/connexion/clavier-virtuel?_hinclude=1")
        challengeID = try Self.extractVirtualPadChallenge(from: padPage)
        virtualPadKeys = try Self.extractVirtualPadKeys(from: padPage)

        let translatedPassword = try password.map { character -> String in
            guard let digit = character.wholeNumberValue,
                  virtualPadKeys.indices.contains(digit)
            else { throw BoursoBankError.invalidPassword }
            return virtualPadKeys[digit]
        }.joined(separator: "|")

        let fields = [
            ("form[fakePassword]", "••••••••"),
            ("form[ajx]", "1"),
            ("form[password]", translatedPassword),
            ("form[passwordAck]", #"{"ry":[],"pt":[],"js":true}"#),
            ("form[platformAuthenticatorAvailable]", "1"),
            ("form[matrixRandomChallenge]", challengeID),
            ("form[_token]", formToken),
            ("form[clientNumber]", normalizedCustomerID)
        ]
        let (loginData, response) = try await postMultipart(path: "/connexion/saisie-mot-de-passe", fields: fields)
        guard (300...399).contains(response.statusCode) else {
            let body = Self.text(from: loginData)
            if body.localizedCaseInsensitiveContains("mot de passe invalide")
                || body.localizedCaseInsensitiveContains("erreur d'authentification") {
                throw BoursoBankError.invalidCredentials
            }
            throw BoursoBankError.server(response.statusCode)
        }

        let homePage = try await getText(path: "/")
        if homePage.contains(#"href="/se-deconnecter""#) {
            webConfiguration = try Self.extractConfiguration(from: homePage)
            authenticated = true
            try persistSession()
            return .authenticated
        }
        if homePage.contains("/securisation") {
            webConfiguration = try? Self.extractConfiguration(from: homePage)
            return .mfaRequired
        }
        throw BoursoBankError.invalidCredentials
    }

    func requestMFA() async throws -> BoursoBankMFAChallenge {
        _ = try await getText(path: "/securisation", acceptedStatusCodes: 200...399)
        let validationPage = try await getText(path: "/securisation/validation")

        guard validationPage.contains("brs-otp-webtoapp") else {
            throw BoursoBankError.unsupportedMFA
        }
        webConfiguration = try Self.extractConfiguration(from: validationPage)
        guard let configuration = webConfiguration,
              let userHash = configuration.userHash,
              Self.isSafeIdentifier(userHash)
        else { throw BoursoBankError.invalidResponse }

        let token = try Self.extractFormToken(from: validationPage)
        let (otpID, formState) = try Self.extractMFAParameters(from: validationPage)
        guard Self.isSafeIdentifier(otpID) else { throw BoursoBankError.invalidResponse }

        let url = try validatedAPIURL(
            "\(configuration.apiURL)/fr-FR/_user_/_\(userHash)/session/challenge/startwebtoapp/\(otpID)"
        )
        let response = try await postJSON(url: url, object: ["formState": formState])
        guard response.success else { throw BoursoBankError.invalidResponse }
        return BoursoBankMFAChallenge(otpID: otpID, formState: formState, token: token)
    }

    func checkMFA(_ challenge: BoursoBankMFAChallenge) async throws -> Bool {
        guard let configuration = webConfiguration,
              let userHash = configuration.userHash,
              Self.isSafeIdentifier(userHash),
              Self.isSafeIdentifier(challenge.otpID)
        else { throw BoursoBankError.invalidResponse }

        let url = try validatedAPIURL(
            "\(configuration.apiURL)/_user_/_\(userHash)/session/challenge/checkwebtoapp/\(challenge.otpID)"
        )
        let result = try await postJSON(url: url, object: ["formState": challenge.formState])
        guard result.success else {
            if result.hasQRCode { throw BoursoBankError.mfaQRCodeRequired }
            return false
        }

        let body = Self.formURLEncoded([("form[_token]", challenge.token)])
        var request = URLRequest(url: baseURL.appendingPathComponent("securisation/validation"))
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://clients.boursobank.com", forHTTPHeaderField: "Origin")
        request.setValue("https://clients.boursobank.com/securisation/validation", forHTTPHeaderField: "Referer")
        let (_, validationResponse) = try await perform(request)
        guard (200...399).contains(validationResponse.statusCode) else {
            throw BoursoBankError.server(validationResponse.statusCode)
        }

        var homeRequest = URLRequest(url: baseURL)
        homeRequest.setValue("https://clients.boursobank.com/securisation/validation", forHTTPHeaderField: "Referer")
        let (homeData, homeResponse) = try await perform(homeRequest)
        guard (200...299).contains(homeResponse.statusCode) else {
            throw BoursoBankError.server(homeResponse.statusCode)
        }
        let homePage = Self.text(from: homeData)
        guard homePage.contains(#"href="/se-deconnecter""#) else {
            if homePage.contains("/securisation") { return false }
            throw BoursoBankError.invalidCredentials
        }
        webConfiguration = try Self.extractConfiguration(from: homePage)
        authenticated = true
        try persistSession()
        return true
    }

    func tradingAccounts() async throws -> [BoursoBankTradingAccount] {
        guard authenticated else { throw BoursoBankError.notAuthenticated }
        guard let url = URL(
            string: "/dashboard/liste-comptes?rumroute=dashboard.new_accounts&_hinclude=1",
            relativeTo: baseURL
        )?.absoluteURL else { throw BoursoBankError.invalidURL }
        let (data, response) = try await perform(URLRequest(url: url))
        if response.statusCode == 401 || response.statusCode == 403 || (300...399).contains(response.statusCode) {
            authenticated = false
            try? BoursoBankSessionKeychain.delete()
            throw BoursoBankError.sessionExpired
        }
        guard (200...299).contains(response.statusCode) else {
            throw BoursoBankError.server(response.statusCode)
        }
        let page = Self.text(from: data)
        if page.contains("/connexion/") && !page.contains("data-summary-trading") {
            authenticated = false
            try? BoursoBankSessionKeychain.delete()
            throw BoursoBankError.sessionExpired
        }
        let accounts = try Self.extractTradingAccounts(from: page)
        guard !accounts.isEmpty else { throw BoursoBankError.noTradingAccount }
        try persistSession()
        return accounts
    }

    func snapshot(for account: BoursoBankTradingAccount) async throws -> BoursoBankSnapshot {
        guard authenticated else { throw BoursoBankError.notAuthenticated }
        guard Self.isHexAccountID(account.id),
              let configuration = webConfiguration,
              let userHash = configuration.userHash,
              Self.isSafeIdentifier(userHash)
        else { throw BoursoBankError.invalidResponse }

        let url = try validatedAPIURL(
            "\(configuration.apiURL)/_user_/_\(userHash)/trading/accounts/summary/\(account.id)?_host=tradingboard.boursobank.com&position=ACCOUNTING&responseFormat=true"
        )
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request)
        if response.statusCode == 401 || response.statusCode == 403 {
            authenticated = false
            try? BoursoBankSessionKeychain.delete()
            throw BoursoBankError.sessionExpired
        }
        guard (200...299).contains(response.statusCode) else {
            throw BoursoBankError.server(response.statusCode)
        }

        let items: [BoursoBankTradingSummaryItem]
        do {
            items = try JSONDecoder().decode([BoursoBankTradingSummaryItem].self, from: data)
        } catch {
            throw BoursoBankError.invalidResponse
        }
        guard let summary = items.compactMap(\.account).first else {
            throw BoursoBankError.invalidResponse
        }
        let snapshot = BoursoBankSnapshot(
            account: account,
            summary: summary,
            positions: items.flatMap { $0.positions ?? [] }
        )
        try persistSession()
        return snapshot
    }

    func instrumentQuote(for symbol: String) async throws -> BoursoBankInstrumentQuote {
        guard let configuration = webConfiguration,
              Self.isSafeMarketSymbol(symbol)
        else { throw BoursoBankError.invalidResponse }
        let url = try validatedAPIURL(
            "\(configuration.apiURL)/_public_/feed/instrument/quote/\(symbol)?_host=tradingboard.boursobank.com"
        )
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request)
        guard (200...299).contains(response.statusCode) else {
            throw BoursoBankError.server(response.statusCode)
        }
        do {
            return try JSONDecoder().decode(BoursoBankInstrumentQuote.self, from: data)
        } catch {
            throw BoursoBankError.invalidResponse
        }
    }

    func disconnect() async {
        if authenticated {
            _ = try? await getText(path: "/se-deconnecter", acceptedStatusCodes: 200...399)
        }
        authenticated = false
        cookies.removeAll()
        formToken = ""
        virtualPadKeys.removeAll()
        challengeID = ""
        webConfiguration = nil
        try? BoursoBankSessionKeychain.delete()
        session.invalidateAndCancel()
    }

    private func getText(path: String, acceptedStatusCodes: ClosedRange<Int> = 200...299) async throws -> String {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw BoursoBankError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await perform(request)
        guard acceptedStatusCodes.contains(response.statusCode) else {
            throw BoursoBankError.server(response.statusCode)
        }
        return Self.text(from: data)
    }

    private func postMultipart(path: String, fields: [(String, String)]) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw BoursoBankError.invalidURL
        }
        let boundary = "NexaBoursoBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(baseURL.appendingPathComponent("connexion/").absoluteString, forHTTPHeaderField: "Referer")
        return try await perform(request)
    }

    private func postJSON(url: URL, object: [String: String]) async throws -> (success: Bool, hasQRCode: Bool) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request)
        guard (200...299).contains(response.statusCode) else {
            throw BoursoBankError.server(response.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let success = object["success"] as? Bool
        else { throw BoursoBankError.invalidResponse }
        return (success, object["qrcode"] is String)
    }

    private func perform(_ originalRequest: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = originalRequest.url,
              url.scheme == "https",
              ["clients.boursobank.com", "api.boursobank.com"].contains(url.host?.lowercased() ?? "")
        else { throw BoursoBankError.invalidURL }

        var request = originalRequest
        request.timeoutInterval = 30
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("fr-FR,fr;q=0.9", forHTTPHeaderField: "Accept-Language")
        let applicableCookies = cookies.values
            .filter { $0.matches(url) }
            .sorted { $0.name < $1.name }
        if !applicableCookies.isEmpty {
            request.setValue(
                applicableCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),
                forHTTPHeaderField: "Cookie"
            )
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BoursoBankError.invalidResponse
        }
        captureCookies(from: http, url: url)
        return (data, http)
    }

    private func captureCookies(from response: HTTPURLResponse, url: URL) {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            guard let key = item.key as? String else { return }
            result[key] = String(describing: item.value)
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            let stored = BoursoBankSessionCookie(cookie)
            if let expiry = stored.expiresAt, expiry <= .now {
                cookies.removeValue(forKey: stored.key)
            } else {
                cookies[stored.key] = stored
            }
        }
    }

    private func setCookie(name: String, value: String, domain: String) {
        let cookie = BoursoBankSessionCookie(name: name, value: value, domain: domain)
        cookies[cookie.key] = cookie
    }

    private func persistSession() throws {
        guard authenticated, let webConfiguration else { return }
        let activeCookies = cookies.values.filter { $0.expiresAt.map({ $0 > .now }) ?? true }
        try BoursoBankSessionKeychain.save(
            BoursoBankStoredSession(
                cookies: Array(activeCookies),
                webConfiguration: webConfiguration,
                savedAt: .now
            )
        )
    }

    private func validatedAPIURL(_ value: String) throws -> URL {
        guard let url = URL(string: value),
              url.scheme == "https",
              url.host?.lowercased() == "api.boursobank.com"
        else { throw BoursoBankError.invalidURL }
        return url
    }

    private static func extractConfiguration(from page: String) throws -> BoursoBankWebConfiguration {
        guard let json = page.firstCapture(
            for: #"window\.BRS_CONFIG\s*=\s*(\{.*?\});"#,
            options: [.dotMatchesLineSeparators]
        ), let data = json.data(using: .utf8) else {
            throw BoursoBankError.incompatiblePage("configuration absente")
        }
        do {
            let configuration = try JSONDecoder().decode(BoursoBankWebConfiguration.self, from: data)
            guard let apiURL = URL(string: configuration.apiURL),
                  apiURL.scheme == "https",
                  apiURL.host?.lowercased() == "api.boursobank.com"
            else { throw BoursoBankError.invalidURL }
            return configuration
        } catch let error as BoursoBankError {
            throw error
        } catch {
            throw BoursoBankError.incompatiblePage("configuration illisible")
        }
    }

    private static func extractFormToken(from page: String) throws -> String {
        guard let token = page.firstCapture(
            for: #"form\[_token\][^>]*?value="([^"]+)""#,
            options: [.dotMatchesLineSeparators]
        ) else { throw BoursoBankError.incompatiblePage("jeton de formulaire absent") }
        return token.decodingHTMLEntities
    }

    private static func extractVirtualPadChallenge(from page: String) throws -> String {
        guard let challenge = page.firstCapture(
            for: #"data-matrix-random-challenge\]"\)\.val\("([^"]+)"\)"#
        ), !challenge.isEmpty else {
            throw BoursoBankError.incompatiblePage("défi du clavier virtuel absent")
        }
        return challenge
    }

    private static func extractVirtualPadKeys(from page: String) throws -> [String] {
        let pattern = #"<button.*?data-matrix-key="([A-Z]{3})".*?src="(data:image.*?)">.*?</button>"#
        let matches = page.captures(for: pattern, options: [.dotMatchesLineSeparators])
        var keys = Array(repeating: "", count: 10)
        for match in matches where match.count >= 2 {
            let matrixKey = match[0]
            let svg = match[1].decodingHTMLEntities
            let hash = SHA256.hash(data: Data(svg.utf8)).map { String(format: "%02x", $0) }.joined()
            guard let digit = virtualPadHashes[hash] else { continue }
            keys[digit] = matrixKey
        }
        guard keys.allSatisfy({ !$0.isEmpty }) else {
            throw BoursoBankError.incompatiblePage("clavier virtuel inconnu")
        }
        return keys
    }

    private static func extractMFAParameters(from page: String) throws -> (String, String) {
        guard let encodedPayload = page.firstCapture(
            for: #"data-strong-authentication-payload="(\{.*?\})">"#,
            options: [.dotMatchesLineSeparators]
        ), let data = encodedPayload.decodingHTMLEntities.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let challenges = payload["challenges"] as? [[String: Any]],
              let parameters = challenges.first?["parameters"] as? [String: Any],
              let formScreen = parameters["formScreen"] as? [String: Any],
              let actions = formScreen["actions"] as? [String: Any],
              let check = actions["check"] as? [String: Any],
              let api = check["api"] as? [String: Any],
              let params = api["params"] as? [String: Any],
              let resourceID = params["resourceId"] as? String,
              let formState = params["formState"] as? String
        else { throw BoursoBankError.incompatiblePage("paramètres MFA absents") }
        return (resourceID, formState)
    }

    private static func extractTradingAccounts(from page: String) throws -> [BoursoBankTradingAccount] {
        guard let sectionStart = page.range(of: "data-summary-trading"),
              let sectionEnd = page.range(of: "</ul>", range: sectionStart.upperBound..<page.endIndex)
        else {
            if page.contains("Mes placements financiers") { return [] }
            throw BoursoBankError.incompatiblePage("liste des comptes-titres absente")
        }
        let section = String(page[sectionStart.lowerBound..<sectionEnd.upperBound])
        let pattern = #"data-account-label="([a-fA-F0-9]{32})"[^>]*>\s*(.*?)\s*</span>.*?c-info-box__account-balance[^>]*>\s*(.*?)\s*</span>.*?c-info-box__account-sub-label[^>]*>\s*(.*?)\s*</span>"#
        return section.captures(for: pattern, options: [.dotMatchesLineSeparators]).compactMap { groups in
            guard groups.count >= 4 else { return nil }
            return BoursoBankTradingAccount(
                id: groups[0].lowercased(),
                name: groups[1].strippingHTML,
                displayedBalance: parseFrenchAmount(groups[2].strippingHTML),
                bankName: groups[3].strippingHTML
            )
        }
    }

    private static func parseFrenchAmount(_ value: String) -> Double {
        var normalized = value
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "−", with: "-")
        if normalized.contains(",") {
            normalized = normalized.replacingOccurrences(of: ".", with: "")
            normalized = normalized.replacingOccurrences(of: ",", with: ".")
        }
        return Double(normalized) ?? 0
    }

    private static func isHexAccountID(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { $0.isHexDigit }
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count < 256 && value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }

    private static func isSafeMarketSymbol(_ value: String) -> Bool {
        !value.isEmpty && value.count < 80 && value.allSatisfy {
            $0.isLetter || $0.isNumber || "-_.".contains($0)
        }
    }

    private static func formURLEncoded(_ values: [(String, String)]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return values.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
    }

    private static func text(from data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    // Empreintes SHA-256 des dix pictogrammes du clavier virtuel BoursoBank.
    // Elles permettent de traduire le code localement sans reconnaissance d’image distante.
    private static let virtualPadHashes: [String: Int] = [
        "5522f0a64150e932b7274d466643d9b852b319ed27d0ff83e6950f02480e982b": 0,
        "72e8bca7c1929ec8110dfa563369307515162de33720c6400b942a0db03074ca": 1,
        "01cf2817791fbcbe5667fc063a0e584e07861edcc70b611f1aaf48b5168ef822": 2,
        "d7ff82170f2f8587ed429cdc2160eee0c2e17f87ab5d113eb62d63ee8f41b252": 3,
        "c56a5fbb3e0dec1ed84757bc52bcc4a551dfaf9c8357aa4bcc10dd1d348c120d": 4,
        "eaf76d27732f5c79028f7bb45c9625a0f0c4ff6cf821b1f775142657b9653077": 5,
        "66a8c08b7e4e7e39a106e0dc3e6fbbe2c6a0df7c7b77da0945dce5f62e386271": 6,
        "ff22cc04bf79a203bc9f0ac1eb0631345f7382db40ace63be5e52bdb1de596c7": 7,
        "d45ed60f516d0ca52f4d0d7fe20f5c14055e80f5868d066dbb6225870548339d": 8,
        "cca7828ce1225fbb2af7e6afa451631b555f80ac7487e4233bcea1b774667b37": 9
    ]
}

private extension String {
    func firstCapture(
        for pattern: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options),
              let match = expression.firstMatch(
                in: self,
                range: NSRange(startIndex..<endIndex, in: self)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: self)
        else { return nil }
        return String(self[range])
    }

    func captures(
        for pattern: String,
        options: NSRegularExpression.Options = []
    ) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }
        return expression.matches(in: self, range: NSRange(startIndex..<endIndex, in: self)).map { match in
            (1..<match.numberOfRanges).compactMap { index -> String? in
                guard let range = Range(match.range(at: index), in: self) else { return nil }
                return String(self[range])
            }
        }
    }

    var decodingHTMLEntities: String {
        replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    var strippingHTML: String {
        let withoutTags = replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        return withoutTags.decodingHTMLEntities
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

actor BoursoBankSyncGate {
    static let shared = BoursoBankSyncGate()
    private var running = false

    func acquire() -> Bool {
        guard !running else { return false }
        running = true
        return true
    }

    func release() {
        running = false
    }
}

struct BoursoBankSyncSummary: Sendable {
    let positions: Int
    let created: Int
    let updated: Int
    let removed: Int
    let unresolvedSymbols: Int
    let cash: Double
    let currency: String
}

private struct ResolvedBoursoBankPosition: Sendable {
    let brokerSymbol: String
    let marketSymbol: String
    let displayName: String
    let quantity: Double
    let averageCost: Double
    let currentPrice: Double
    let previousClose: Double
    let currency: String
    let resolvedSymbol: Bool
}

@MainActor
enum BoursoBankImporter {
    static func synchronize(
        snapshot: BoursoBankSnapshot,
        client: BoursoBankClient,
        into portfolio: Portfolio,
        context: ModelContext
    ) async throws -> BoursoBankSyncSummary {
        let source = "boursobank:\(snapshot.account.id)"
        let resolved = await resolve(snapshot.positions, client: client, fallbackCurrency: snapshot.summary.currency ?? "EUR")
        var created = 0
        var updated = 0
        var activeBrokerSymbols = Set<String>()

        for position in resolved where position.quantity > 0 {
            activeBrokerSymbols.insert(position.brokerSymbol)
            let holding: Holding
            if let existing = portfolio.holdings.first(where: {
                $0.externalSource == source && $0.brokerSymbol == position.brokerSymbol
            }) {
                holding = existing
                updated += 1
            } else {
                holding = Holding(
                    symbol: position.marketSymbol,
                    displayName: position.displayName,
                    quantity: position.quantity,
                    averageCost: position.averageCost,
                    currentPrice: position.currentPrice,
                    previousClose: position.previousClose,
                    currencyCode: position.currency,
                    portfolio: portfolio
                )
                holding.externalSource = source
                holding.brokerSymbol = position.brokerSymbol
                context.insert(holding)
                created += 1
            }
            holding.symbol = position.marketSymbol.uppercased()
            holding.displayName = position.displayName
            holding.quantity = position.quantity
            holding.averageCost = position.averageCost
            holding.currentPrice = position.currentPrice
            holding.previousClose = position.previousClose
            holding.currencyCode = position.currency
            holding.externalSource = source
            holding.brokerSymbol = position.brokerSymbol
            holding.lastUpdated = .now
        }

        let stale = portfolio.holdings.filter {
            $0.externalSource == source
                && !activeBrokerSymbols.contains($0.brokerSymbol ?? "")
        }
        for holding in stale { context.delete(holding) }

        let currency = snapshot.summary.currency ?? "EUR"
        portfolio.currencyCode = currency
        portfolio.cashBalance = snapshot.summary.cash?.value ?? 0
        try context.save()

        return BoursoBankSyncSummary(
            positions: resolved.count,
            created: created,
            updated: updated,
            removed: stale.count,
            unresolvedSymbols: resolved.filter { !$0.resolvedSymbol }.count,
            cash: portfolio.cashBalance,
            currency: currency
        )
    }

    private static func resolve(
        _ positions: [BoursoBankPosition],
        client: BoursoBankClient,
        fallbackCurrency: String
    ) async -> [ResolvedBoursoBankPosition] {
        await withTaskGroup(of: ResolvedBoursoBankPosition?.self) { group in
            for position in positions where position.quantity.value > 0 {
                group.addTask {
                    let quote = try? await client.instrumentQuote(for: position.symbol)
                    let isin = quote?.isin?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let searchResults: [SymbolSearchResult]
                    if let isin, !isin.isEmpty {
                        searchResults = (try? await MarketDataClient.shared.search(isin)) ?? []
                    } else {
                        searchResults = []
                    }
                    let matched = searchResults.first
                    let marketSymbol = matched?.symbol
                        ?? (isin?.isEmpty == false ? isin! : position.symbol)
                    let quantity = position.quantity.value
                    let currentPrice = position.last.value > 0
                        ? position.last.value
                        : (quote?.last ?? (quantity > 0 ? position.amount.value / quantity : 0))
                    let previousClose = quote?.previousClose ?? currentPrice
                    let currency = position.last.currency
                        ?? quote?.currency
                        ?? position.buyingPrice.currency
                        ?? fallbackCurrency
                    return ResolvedBoursoBankPosition(
                        brokerSymbol: position.symbol,
                        marketSymbol: marketSymbol,
                        displayName: matched?.displayName ?? quote?.label ?? position.label,
                        quantity: quantity,
                        averageCost: position.buyingPrice.value,
                        currentPrice: currentPrice,
                        previousClose: previousClose,
                        currency: currency,
                        resolvedSymbol: matched != nil
                    )
                }
            }

            var values: [ResolvedBoursoBankPosition] = []
            for await value in group {
                if let value { values.append(value) }
            }
            return values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }
}
