import Foundation
import SwiftData

enum DegiroImportError: LocalizedError {
    case unreadableFile(String)
    case unsupportedFile(String)
    case noImportableData

    var errorDescription: String? {
        switch self {
        case let .unreadableFile(name):
            return "Le fichier \(name) ne peut pas être lu. Exporte-le à nouveau au format CSV depuis DEGIRO."
        case let .unsupportedFile(name):
            return "Le fichier \(name) n’est pas un relevé Transactions ou Compte DEGIRO reconnu."
        case .noImportableData:
            return "Aucun achat, vente ou dividende DEGIRO exploitable n’a été trouvé dans les fichiers sélectionnés."
        }
    }
}

struct DegiroImportSummary: Sendable {
    let processedFiles: Int
    let importedTrades: Int
    let importedDividends: Int
    let skippedDuplicates: Int
    let ignoredRows: Int
}

@MainActor
enum DegiroCSVImporter {
    private static let source = "degiro:csv"

    static func importDocuments(
        at urls: [URL],
        into portfolio: Portfolio,
        context: ModelContext
    ) async throws -> DegiroImportSummary {
        var trades: [DegiroTradeRow] = []
        var dividends: [DegiroDividendRow] = []
        var ignoredRows = 0
        var processedFiles = 0

        for url in urls {
            let hasSecurityAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityAccess { url.stopAccessingSecurityScopedResource() }
            }

            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw DegiroImportError.unreadableFile(url.lastPathComponent)
            }

            guard let text = DegiroCSVParser.decode(data) else {
                throw DegiroImportError.unreadableFile(url.lastPathComponent)
            }

            let document = try DegiroCSVParser.parse(text, fileName: url.lastPathComponent)
            trades.append(contentsOf: document.trades)
            dividends.append(contentsOf: document.dividends)
            ignoredRows += document.ignoredRows
            processedFiles += 1
        }

        guard !trades.isEmpty || !dividends.isEmpty else {
            throw DegiroImportError.noImportableData
        }

        let instruments = (trades.map { (key: $0.instrumentKey, isin: $0.isin, name: $0.displayName) }
            + dividends.map { (key: $0.instrumentKey, isin: $0.isin, name: $0.displayName) })
        let symbols = await DegiroSymbolResolver.resolve(instruments)

        let allTransactions = try context.fetch(FetchDescriptor<TradeTransaction>())
        var knownIdentifiers = Set(allTransactions.compactMap(\.externalIdentifier))
        var importedTrades = 0
        var importedDividends = 0
        var duplicates = 0

        for row in trades.sorted(by: { $0.date < $1.date }) {
            let identifier = "\(source):trade:\(stableHash(row.identityMaterial))"
            guard knownIdentifiers.insert(identifier).inserted else {
                duplicates += 1
                continue
            }

            let symbol = symbols[row.instrumentKey]?.symbol ?? fallbackSymbol(for: row)
            let displayName = symbols[row.instrumentKey]?.displayName ?? row.displayName
            context.insert(TradeTransaction(
                kind: row.kind,
                symbol: symbol,
                displayName: displayName,
                quantity: row.quantity,
                price: row.price,
                fees: row.fees,
                currencyCode: row.currency,
                date: row.date,
                notes: "Import CSV DEGIRO",
                externalSource: source,
                externalIdentifier: identifier,
                brokerTicker: row.isin,
                portfolio: portfolio
            ))
            importedTrades += 1
        }

        for row in dividends.sorted(by: { $0.date < $1.date }) {
            let identifier = "\(source):dividend:\(stableHash(row.identityMaterial))"
            guard knownIdentifiers.insert(identifier).inserted else {
                duplicates += 1
                continue
            }

            let symbol = symbols[row.instrumentKey]?.symbol ?? fallbackSymbol(for: row)
            let displayName = symbols[row.instrumentKey]?.displayName ?? row.displayName
            context.insert(TradeTransaction(
                kind: .dividend,
                symbol: symbol,
                displayName: displayName,
                quantity: 0,
                price: row.amount,
                currencyCode: row.currency,
                date: row.date,
                notes: "Import CSV DEGIRO · dividende versé",
                externalSource: source,
                externalIdentifier: identifier,
                brokerTicker: row.isin,
                portfolio: portfolio
            ))
            importedDividends += 1
        }

        try context.save()
        try PortfolioLedger.rebuildHoldings(in: portfolio, context: context)

        return DegiroImportSummary(
            processedFiles: processedFiles,
            importedTrades: importedTrades,
            importedDividends: importedDividends,
            skippedDuplicates: duplicates,
            ignoredRows: ignoredRows
        )
    }

    private static func fallbackSymbol(for row: DegiroTradeRow) -> String {
        row.isin.isEmpty ? "DEGIRO-\(stableHash(row.displayName).prefix(8).uppercased())" : row.isin
    }

    private static func fallbackSymbol(for row: DegiroDividendRow) -> String {
        row.isin.isEmpty ? "DEGIRO-\(stableHash(row.displayName).prefix(8).uppercased())" : row.isin
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

private struct DegiroTradeRow: Sendable {
    let kind: TransactionKind
    let isin: String
    let displayName: String
    let quantity: Double
    let price: Double
    let fees: Double
    let currency: String
    let date: Date
    let orderID: String

    var instrumentKey: String { isin.isEmpty ? displayName.normalizedCSVHeader : isin }
    var identityMaterial: String {
        [
            orderID,
            date.ISO8601Format(),
            kind.rawValue,
            isin,
            displayName,
            String(quantity),
            String(price),
            String(fees),
            currency
        ].joined(separator: "|")
    }
}

private struct DegiroDividendRow: Sendable {
    let isin: String
    let displayName: String
    let amount: Double
    let currency: String
    let date: Date

    var instrumentKey: String { isin.isEmpty ? displayName.normalizedCSVHeader : isin }
    var identityMaterial: String {
        [date.ISO8601Format(), isin, displayName, String(amount), currency].joined(separator: "|")
    }
}

private struct DegiroParsedDocument {
    let trades: [DegiroTradeRow]
    let dividends: [DegiroDividendRow]
    let ignoredRows: Int
}

private enum DegiroCSVParser {
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

    static func parse(_ text: String, fileName: String) throws -> DegiroParsedDocument {
        let delimiter = detectDelimiter(in: text)
        let rows = parseRows(text, delimiter: delimiter).filter { row in
            row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        guard !rows.isEmpty else { throw DegiroImportError.unsupportedFile(fileName) }

        let headerCandidate = rows.prefix(10).enumerated().max { lhs, rhs in
            headerScore(lhs.element) < headerScore(rhs.element)
        }
        guard let headerIndex = headerCandidate?.offset,
              let header = headerCandidate?.element,
              headerScore(header) >= 3
        else { throw DegiroImportError.unsupportedFile(fileName) }

        let normalizedHeaders = header.map(\.normalizedCSVHeader)
        let dateIndex = index(in: normalizedHeaders, aliases: ["date", "datum"])
        let timeIndex = index(in: normalizedHeaders, aliases: ["heure", "time", "tijd"])
        let productIndex = index(in: normalizedHeaders, aliases: ["produit", "product"])
        let isinIndex = index(in: normalizedHeaders, aliases: ["isin"])
        let quantityIndex = index(in: normalizedHeaders, aliases: ["nombre", "quantite", "quantity", "aantal"])
        let priceIndex = index(in: normalizedHeaders, aliases: ["cours", "price", "koers"])
        let descriptionIndex = index(in: normalizedHeaders, aliases: ["description", "omschrijving"])
        let changeIndex = index(in: normalizedHeaders, aliases: ["variation", "change", "mutation", "mutatie"])
        let feeIndex = normalizedHeaders.firstIndex {
            $0.contains("frais") || $0.contains("fee") || $0.contains("transactiekosten")
        }
        let orderIndex = normalizedHeaders.firstIndex {
            $0 == "idordre" || $0 == "orderid" || ($0.contains("order") && $0.contains("id"))
        }

        guard let dateIndex else { throw DegiroImportError.unsupportedFile(fileName) }
        let isTransactionsDocument = quantityIndex != nil && priceIndex != nil
        let isAccountDocument = descriptionIndex != nil && changeIndex != nil
        guard isTransactionsDocument || isAccountDocument else {
            throw DegiroImportError.unsupportedFile(fileName)
        }

        var trades: [DegiroTradeRow] = []
        var dividends: [DegiroDividendRow] = []
        var ignored = 0

        for row in rows.dropFirst(headerIndex + 1) {
            guard let date = parsedDate(
                date: value(at: dateIndex, in: row),
                time: value(at: timeIndex, in: row)
            ) else {
                ignored += 1
                continue
            }

            if isTransactionsDocument,
               let quantityIndex,
               let priceIndex,
               let signedQuantity = number(value(at: quantityIndex, in: row)),
               signedQuantity != 0,
               let price = number(value(at: priceIndex, in: row)),
               price >= 0 {
                let name = nonEmpty(value(at: productIndex, in: row), fallback: "Titre DEGIRO")
                let isin = value(at: isinIndex, in: row).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                let currencyIndex = nextCurrencyIndex(after: priceIndex, headers: normalizedHeaders)
                let currency = normalizedCurrency(value(at: currencyIndex, in: row), fallback: "EUR")
                let fees = abs(number(value(at: feeIndex, in: row)) ?? 0)
                trades.append(DegiroTradeRow(
                    kind: signedQuantity > 0 ? .buy : .sell,
                    isin: isin,
                    displayName: name,
                    quantity: abs(signedQuantity),
                    price: price,
                    fees: fees,
                    currency: currency,
                    date: date,
                    orderID: value(at: orderIndex, in: row)
                ))
                continue
            }

            if isAccountDocument,
               let descriptionIndex,
               let changeIndex {
                let description = value(at: descriptionIndex, in: row).normalizedCSVHeader
                let isDividend = description.contains("dividend") || description.contains("dividende")
                let isTax = description.contains("tax")
                    || description.contains("withholding")
                    || description.contains("retenue")
                    || description.contains("precompte")
                    || description.contains("belasting")
                if isDividend,
                   !isTax,
                   let amount = number(value(at: changeIndex, in: row)),
                   amount > 0 {
                    let name = nonEmpty(value(at: productIndex, in: row), fallback: "Dividende DEGIRO")
                    let isin = value(at: isinIndex, in: row).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    let currencyIndex = nextCurrencyIndex(after: changeIndex, headers: normalizedHeaders)
                    let currency = normalizedCurrency(value(at: currencyIndex, in: row), fallback: "EUR")
                    dividends.append(DegiroDividendRow(
                        isin: isin,
                        displayName: name,
                        amount: amount,
                        currency: currency,
                        date: date
                    ))
                    continue
                }
            }

            ignored += 1
        }

        return DegiroParsedDocument(trades: trades, dividends: dividends, ignoredRows: ignored)
    }

    private static func detectDelimiter(in text: String) -> Character {
        let candidates: [Character] = [";", ",", "\t"]
        let sample = text.split(whereSeparator: \.isNewline).prefix(8).joined(separator: "\n")
        return candidates.max { count($0, outsideQuotesIn: String(sample)) < count($1, outsideQuotesIn: String(sample)) } ?? ","
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

    private static func headerScore(_ row: [String]) -> Int {
        let recognized = Set([
            "date", "datum", "heure", "time", "tijd", "produit", "product", "isin",
            "nombre", "quantite", "quantity", "aantal", "cours", "price", "koers",
            "description", "omschrijving", "variation", "change", "mutation", "mutatie"
        ])
        return row.map(\.normalizedCSVHeader).reduce(0) { score, value in
            score + (recognized.contains(value) ? 1 : 0)
        }
    }

    private static func index(in headers: [String], aliases: Set<String>) -> Int? {
        headers.firstIndex { aliases.contains($0) }
    }

    private static func nextCurrencyIndex(after index: Int, headers: [String]) -> Int? {
        guard index + 1 < headers.count else { return nil }
        return ((index + 1)..<headers.count).first {
            ["devise", "currency", "valuta"].contains(headers[$0])
        }
    }

    private static func value(at index: Int?, in row: [String]) -> String {
        guard let index, row.indices.contains(index) else { return "" }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func number(_ rawValue: String) -> Double? {
        var value = rawValue
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: " ", with: "")
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
        guard let result = Double(value) else { return nil }
        return isParenthesized ? -abs(result) : result
    }

    private static func parsedDate(date: String, time: String) -> Date? {
        let combined = time.isEmpty ? date : "\(date) \(time)"
        let formats = time.isEmpty
            ? ["dd-MM-yyyy", "dd/MM/yyyy", "dd.MM.yyyy", "yyyy-MM-dd"]
            : [
                "dd-MM-yyyy HH:mm:ss", "dd-MM-yyyy HH:mm",
                "dd/MM/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm",
                "dd.MM.yyyy HH:mm:ss", "dd.MM.yyyy HH:mm",
                "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"
            ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .autoupdatingCurrent
            formatter.dateFormat = format
            if let result = formatter.date(from: combined) { return result }
        }
        return ISO8601DateFormatter().date(from: combined)
    }

    private static func normalizedCurrency(_ value: String, fallback: String) -> String {
        let currency = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return currency.count == 3 ? currency : fallback
    }

    private static func nonEmpty(_ value: String, fallback: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
    }
}

private enum DegiroSymbolResolver {
    static func resolve(_ instruments: [(key: String, isin: String, name: String)]) async -> [String: SymbolSearchResult] {
        var unique: [String: (isin: String, name: String)] = [:]
        for instrument in instruments where unique[instrument.key] == nil {
            unique[instrument.key] = (instrument.isin, instrument.name)
        }

        return await withTaskGroup(of: (String, SymbolSearchResult?).self) { group in
            for (key, instrument) in unique {
                group.addTask {
                    let query = instrument.isin.isEmpty ? instrument.name : instrument.isin
                    let results = try? await MarketDataClient.shared.search(query)
                    return (key, results?.first)
                }
            }

            var resolved: [String: SymbolSearchResult] = [:]
            for await (key, result) in group {
                if let result { resolved[key] = result }
            }
            return resolved
        }
    }
}

private extension String {
    var normalizedCSVHeader: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}
