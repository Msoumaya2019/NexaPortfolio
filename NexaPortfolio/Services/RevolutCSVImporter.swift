import Foundation
import SwiftData

enum RevolutCSVImportError: LocalizedError {
    case unreadableFile(String)
    case unsupportedFile(String)
    case noImportableData

    var errorDescription: String? {
        switch self {
        case let .unreadableFile(name):
            return "Le fichier \(name) ne peut pas être lu. Exporte-le à nouveau depuis Revolut."
        case let .unsupportedFile(name):
            return "Le fichier \(name) n’est pas un export CSV d’investissements Revolut reconnu."
        case .noImportableData:
            return "Aucun achat, vente, dividende ou ajustement de titres exploitable n’a été trouvé."
        }
    }
}

struct RevolutImportSummary: Sendable {
    let importedTrades: Int
    let importedDividends: Int
    let importedCorporateActions: Int
    let skippedDuplicates: Int
    let ignoredRows: Int
}

@MainActor
enum RevolutCSVImporter {
    private static let source = "revolut:csv"

    static func importDocuments(
        at urls: [URL],
        into portfolio: Portfolio,
        context: ModelContext
    ) async throws -> RevolutImportSummary {
        var parsedRows: [RevolutCSVRow] = []
        var ignoredRows = 0

        for url in urls {
            let hasSecurityAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityAccess { url.stopAccessingSecurityScopedResource() }
            }

            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw RevolutCSVImportError.unreadableFile(url.lastPathComponent)
            }

            guard let text = RevolutCSVParser.decode(data) else {
                throw RevolutCSVImportError.unreadableFile(url.lastPathComponent)
            }
            let result = try RevolutCSVParser.parse(text, fileName: url.lastPathComponent)
            parsedRows.append(contentsOf: result.rows)
            ignoredRows += result.ignoredRows
        }

        guard !parsedRows.isEmpty else {
            throw RevolutCSVImportError.noImportableData
        }

        let instruments = await RevolutSymbolResolver.resolve(parsedRows)
        let allTransactions = try context.fetch(FetchDescriptor<TradeTransaction>())
        var knownIdentifiers = Set(allTransactions.compactMap(\.externalIdentifier))
        var importedTrades = 0
        var importedDividends = 0
        var importedCorporateActions = 0
        var duplicates = 0

        for row in parsedRows.sorted(by: { $0.date < $1.date }) {
            let identifier = "\(source):\(stableHash(row.identityMaterial))"
            guard knownIdentifiers.insert(identifier).inserted else {
                duplicates += 1
                continue
            }

            let instrument = instruments[row.ticker]
            let symbol = instrument?.symbol ?? row.ticker
            let displayName = instrument?.displayName ?? row.ticker
            let note: String
            if row.isCorporateAction {
                note = "Import CSV Revolut · ajustement de titres (split ou fusion)"
                importedCorporateActions += 1
            } else if row.kind == .dividend {
                note = row.rawType.contains("TAX")
                    ? "Import CSV Revolut · correction fiscale de dividende"
                    : "Import CSV Revolut · dividende versé"
                importedDividends += 1
            } else {
                note = "Import CSV Revolut · \(row.rawType.lowercased())"
                importedTrades += 1
            }

            context.insert(TradeTransaction(
                kind: row.kind,
                symbol: symbol,
                displayName: displayName,
                quantity: row.quantity,
                price: row.price,
                fees: 0,
                currencyCode: row.currency,
                date: row.date,
                notes: note,
                externalSource: source,
                externalIdentifier: identifier,
                brokerTicker: row.ticker,
                portfolio: portfolio
            ))
        }

        try context.save()
        try PortfolioLedger.rebuildHoldings(in: portfolio, context: context)

        return RevolutImportSummary(
            importedTrades: importedTrades,
            importedDividends: importedDividends,
            importedCorporateActions: importedCorporateActions,
            skippedDuplicates: duplicates,
            ignoredRows: ignoredRows
        )
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private struct RevolutCSVRow: Sendable {
    let kind: TransactionKind
    let ticker: String
    let quantity: Double
    let price: Double
    let currency: String
    let date: Date
    let rawType: String
    let rawTotalAmount: Double
    let fxRate: Double?
    let isCorporateAction: Bool

    var identityMaterial: String {
        [
            date.ISO8601Format(),
            rawType,
            ticker,
            String(quantity),
            String(price),
            String(rawTotalAmount),
            currency,
            fxRate.map { String($0) } ?? "",
            String(isCorporateAction)
        ].joined(separator: "|")
    }
}

private struct RevolutCSVParseResult {
    let rows: [RevolutCSVRow]
    let ignoredRows: Int
}

private enum RevolutCSVParser {
    static func decode(_ data: Data) -> String? {
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .windowsCP1252,
            .isoLatin1
        ]
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding), !text.isEmpty {
                return text.replacingOccurrences(of: "\u{FEFF}", with: "")
            }
        }
        return nil
    }

    static func parse(_ text: String, fileName: String) throws -> RevolutCSVParseResult {
        let delimiter = detectDelimiter(in: text)
        let records = parseRows(text, delimiter: delimiter).filter { record in
            record.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        guard let header = records.first else {
            throw RevolutCSVImportError.unsupportedFile(fileName)
        }

        let headers = header.map(\.normalizedRevolutHeader)
        let dateIndex = index(in: headers, aliases: ["date", "datetime", "timestamp"])
        let tickerIndex = index(in: headers, aliases: ["ticker", "symbol", "symbole"])
        let typeIndex = index(in: headers, aliases: ["type", "transactiontype", "typedetransaction"])
        let quantityIndex = index(in: headers, aliases: ["quantity", "quantite", "shares"])
        let priceIndex = index(in: headers, aliases: ["pricepershare", "prixparaction", "price", "prix"])
        let amountIndex = index(in: headers, aliases: ["totalamount", "montanttotal", "amount", "montant"])
        let currencyIndex = index(in: headers, aliases: ["currency", "devise"])
        let fxRateIndex = index(in: headers, aliases: ["fxrate", "tauxdechange", "exchangerate"])

        guard let dateIndex,
              let tickerIndex,
              let typeIndex,
              let quantityIndex,
              let priceIndex,
              let amountIndex,
              let currencyIndex
        else {
            throw RevolutCSVImportError.unsupportedFile(fileName)
        }

        var rows: [RevolutCSVRow] = []
        var ignoredRows = 0

        for record in records.dropFirst() {
            let rawType = value(at: typeIndex, in: record)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            let exportedTicker = value(at: tickerIndex, in: record)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            let ticker = normalizedTicker(exportedTicker)
            guard let date = parsedDate(value(at: dateIndex, in: record)) else {
                ignoredRows += 1
                continue
            }

            let rawQuantity = number(value(at: quantityIndex, in: record))
            let explicitPrice = number(value(at: priceIndex, in: record))
            let totalAmount = number(value(at: amountIndex, in: record)) ?? 0
            let currency = normalizedCurrency(
                value(at: currencyIndex, in: record),
                monetaryValues: [
                    value(at: amountIndex, in: record),
                    value(at: priceIndex, in: record)
                ]
            )
            let fxRate = number(value(at: fxRateIndex, in: record))

            if rawType == "DIVIDEND" || rawType.hasPrefix("DIVIDEND TAX") {
                guard !ticker.isEmpty, totalAmount != 0 else {
                    ignoredRows += 1
                    continue
                }
                rows.append(RevolutCSVRow(
                    kind: .dividend,
                    ticker: ticker,
                    quantity: 0,
                    price: totalAmount,
                    currency: currency,
                    date: date,
                    rawType: rawType,
                    rawTotalAmount: totalAmount,
                    fxRate: fxRate,
                    isCorporateAction: false
                ))
                continue
            }

            let isCorporateAction = rawType == "STOCK SPLIT" || rawType == "MERGER - STOCK"
            if isCorporateAction {
                guard !ticker.isEmpty, let rawQuantity, rawQuantity != 0 else {
                    ignoredRows += 1
                    continue
                }
                rows.append(RevolutCSVRow(
                    kind: rawQuantity > 0 ? .buy : .sell,
                    ticker: ticker,
                    quantity: abs(rawQuantity),
                    price: 0,
                    currency: currency,
                    date: date,
                    rawType: rawType,
                    rawTotalAmount: totalAmount,
                    fxRate: fxRate,
                    isCorporateAction: true
                ))
                continue
            }

            let kind: TransactionKind?
            if rawType.hasPrefix("BUY") {
                kind = .buy
            } else if rawType.hasPrefix("SELL") {
                kind = .sell
            } else {
                kind = nil
            }

            guard let kind,
                  !ticker.isEmpty,
                  let rawQuantity,
                  abs(rawQuantity) > 0
            else {
                ignoredRows += 1
                continue
            }

            let quantity = abs(rawQuantity)
            let price: Double
            if kind == .buy, totalAmount != 0 {
                // Le prix unitaire de l’export est arrondi. Le coût total par quantité
                // conserve exactement la valeur d’achat réellement débitée.
                price = abs(totalAmount) / quantity
            } else if let explicitPrice, explicitPrice != 0 {
                price = abs(explicitPrice)
            } else {
                price = abs(totalAmount) / quantity
            }
            guard price.isFinite, price >= 0 else {
                ignoredRows += 1
                continue
            }

            rows.append(RevolutCSVRow(
                kind: kind,
                ticker: ticker,
                quantity: quantity,
                price: price,
                currency: currency,
                date: date,
                rawType: rawType,
                rawTotalAmount: totalAmount,
                fxRate: fxRate,
                isCorporateAction: false
            ))
        }

        return RevolutCSVParseResult(rows: rows, ignoredRows: ignoredRows)
    }

    private static func index(in headers: [String], aliases: Set<String>) -> Int? {
        headers.firstIndex { aliases.contains($0) }
    }

    private static func value(at index: Int?, in record: [String]) -> String {
        guard let index, record.indices.contains(index) else { return "" }
        return record[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedCurrency(_ value: String, monetaryValues: [String]) -> String {
        let explicit = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if explicit.count == 3 { return explicit }
        for monetaryValue in monetaryValues {
            let prefix = monetaryValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(3)
                .uppercased()
            if prefix.count == 3, prefix.allSatisfy(\.isLetter) {
                return String(prefix)
            }
        }
        return "EUR"
    }

    private static func normalizedTicker(_ ticker: String) -> String {
        // Certains exports utilisent le symbole OTC temporaire après une radiation.
        // Le rattachement au symbole d’origine permet à la vente de clôturer la
        // position historique au lieu de laisser une position fantôme.
        switch ticker {
        case "HTZGQ": return "HTZ"
        case "CHKAQ": return "CHK"
        default: return ticker
        }
    }

    private static func parsedDate(_ value: String) -> Date? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: cleaned) { return date }
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: cleaned) { return date }

        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "dd/MM/yyyy HH:mm:ss", "dd/MM/yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .autoupdatingCurrent
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }

    private static func number(_ rawValue: String) -> Double? {
        var value = rawValue
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "'", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let isParenthesized = value.hasPrefix("(") && value.hasSuffix(")")
        value = String(value.filter { "0123456789.,-+".contains($0) })
        if value.contains(","), value.contains(".") {
            if value.lastIndex(of: ",")! > value.lastIndex(of: ".")! {
                value = value.replacingOccurrences(of: ".", with: "")
                    .replacingOccurrences(of: ",", with: ".")
            } else {
                value = value.replacingOccurrences(of: ",", with: "")
            }
        } else if value.contains(",") {
            value = value.replacingOccurrences(of: ",", with: ".")
        }
        guard let number = Double(value) else { return nil }
        return isParenthesized ? -abs(number) : number
    }

    private static func detectDelimiter(in text: String) -> Character {
        let candidates: [Character] = [",", ";", "\t"]
        let sample = text.split(whereSeparator: \.isNewline).prefix(8).joined(separator: "\n")
        return candidates.max {
            count($0, outsideQuotesIn: String(sample)) < count($1, outsideQuotesIn: String(sample))
        } ?? ","
    }

    private static func count(_ candidate: Character, outsideQuotesIn text: String) -> Int {
        var insideQuotes = false
        var result = 0
        for character in text {
            if character == "\"" { insideQuotes.toggle() }
            if character == candidate && !insideQuotes { result += 1 }
        }
        return result
    }

    private static func parseRows(_ text: String, delimiter: Character) -> [[String]] {
        let characters = Array(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var insideQuotes = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if insideQuotes, index + 1 < characters.count, characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else {
                    insideQuotes.toggle()
                }
            } else if character == delimiter && !insideQuotes {
                row.append(field)
                field = ""
            } else if (character == "\n" || character == "\r") && !insideQuotes {
                row.append(field)
                field = ""
                rows.append(row)
                row = []
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" {
                    index += 1
                }
            } else {
                field.append(character)
            }
            index += 1
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

private enum RevolutSymbolResolver {
    static func resolve(_ rows: [RevolutCSVRow]) async -> [String: SymbolSearchResult] {
        let tickers = Set(rows.map(\.ticker).filter { !$0.isEmpty })
        return await withTaskGroup(of: (String, SymbolSearchResult?).self) { group in
            for ticker in tickers {
                group.addTask {
                    let results = try? await MarketDataClient.shared.search(ticker)
                    let exact = results?.first(where: {
                        $0.symbol.uppercased() == ticker.uppercased()
                    })
                    return (ticker, exact ?? results?.first)
                }
            }

            var resolved: [String: SymbolSearchResult] = [:]
            for await (ticker, result) in group {
                if let result { resolved[ticker] = result }
            }
            return resolved
        }
    }
}

private extension String {
    var normalizedRevolutHeader: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .filter(\.isLetterOrNumber)
    }
}
