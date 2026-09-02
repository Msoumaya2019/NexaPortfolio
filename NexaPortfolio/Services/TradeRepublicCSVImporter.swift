import Foundation
import SwiftData

enum TradeRepublicCSVImportError: LocalizedError {
    case unreadableFile(String)
    case unsupportedFile(String)
    case noImportableData

    var errorDescription: String? {
        switch self {
        case let .unreadableFile(name):
            return "Le fichier \(name) ne peut pas être lu. Exporte-le à nouveau depuis Trade Republic."
        case let .unsupportedFile(name):
            return "Le fichier \(name) n’est pas l’export CSV Trade Republic destiné aux outils de suivi."
        case .noImportableData:
            return "Aucun achat, vente ou dividende exploitable n’a été trouvé dans l’export Trade Republic."
        }
    }
}

@MainActor
enum TradeRepublicDocumentImporter {
    static func importDocuments(
        at urls: [URL],
        into portfolio: Portfolio,
        context: ModelContext
    ) async throws -> TradeRepublicImportSummary {
        let pdfURLs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        let csvURLs = urls.filter { $0.pathExtension.lowercased() != "pdf" }

        var trades = 0
        var dividends = 0
        var duplicates = 0
        var ignoredDocuments = 0

        if !csvURLs.isEmpty {
            let summary = try await TradeRepublicCSVImporter.importDocuments(
                at: csvURLs,
                into: portfolio,
                context: context
            )
            trades += summary.importedTrades
            dividends += summary.importedDividends
            duplicates += summary.skippedDuplicates
            ignoredDocuments += summary.ignoredDocuments
        }

        if !pdfURLs.isEmpty {
            let summary = try await TradeRepublicPDFImporter.importDocuments(
                at: pdfURLs,
                into: portfolio,
                context: context
            )
            trades += summary.importedTrades
            dividends += summary.importedDividends
            duplicates += summary.skippedDuplicates
            ignoredDocuments += summary.ignoredDocuments
        }

        return TradeRepublicImportSummary(
            importedTrades: trades,
            importedDividends: dividends,
            skippedDuplicates: duplicates,
            ignoredDocuments: ignoredDocuments
        )
    }
}

@MainActor
enum TradeRepublicCSVImporter {
    private static let source = "traderepublic:csv"

    static func importDocuments(
        at urls: [URL],
        into portfolio: Portfolio,
        context: ModelContext
    ) async throws -> TradeRepublicImportSummary {
        var rows: [TradeRepublicCSVRow] = []

        for url in urls {
            let hasSecurityAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityAccess { url.stopAccessingSecurityScopedResource() }
            }

            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw TradeRepublicCSVImportError.unreadableFile(url.lastPathComponent)
            }

            guard let text = TradeRepublicCSVParser.decode(data) else {
                throw TradeRepublicCSVImportError.unreadableFile(url.lastPathComponent)
            }
            rows.append(contentsOf: try TradeRepublicCSVParser.parse(
                text,
                fileName: url.lastPathComponent
            ))
        }

        guard !rows.isEmpty else {
            throw TradeRepublicCSVImportError.noImportableData
        }

        let symbols = await TradeRepublicCSVSymbolResolver.resolve(rows)
        let allTransactions = try context.fetch(FetchDescriptor<TradeTransaction>())
        var knownIdentifiers = Set(allTransactions.compactMap(\.externalIdentifier))
        var importedTrades = 0
        var importedDividends = 0
        var duplicates = 0

        for row in rows.sorted(by: { $0.date < $1.date }) {
            let identifier = row.transactionID.isEmpty
                ? "\(source):\(stableHash(row.identityMaterial))"
                : "\(source):\(row.transactionID)"
            guard knownIdentifiers.insert(identifier).inserted else {
                duplicates += 1
                continue
            }

            let resolved = symbols[row.brokerSymbol]
            let symbol = resolved?.symbol ?? fallbackSymbol(for: row)
            let displayName = resolved?.displayName ?? row.displayName
            context.insert(TradeTransaction(
                kind: row.kind,
                symbol: symbol,
                displayName: displayName,
                quantity: row.quantity,
                price: row.price,
                fees: row.fees,
                currencyCode: row.currency,
                date: row.date,
                notes: row.isCorporateAction
                    ? "Import CSV Trade Republic · regroupement ou fractionnement de titres"
                    : (row.kind == .dividend
                        ? (row.price < 0
                            ? "Import CSV Trade Republic · annulation de dividende"
                            : "Import CSV Trade Republic · montant net après retenues")
                        : "Import CSV Trade Republic"),
                externalSource: source,
                externalIdentifier: identifier,
                brokerTicker: row.brokerSymbol,
                portfolio: portfolio
            ))

            if row.kind == .dividend {
                importedDividends += 1
            } else {
                importedTrades += 1
            }
        }

        try context.save()
        try PortfolioLedger.rebuildHoldings(in: portfolio, context: context)

        return TradeRepublicImportSummary(
            importedTrades: importedTrades,
            importedDividends: importedDividends,
            skippedDuplicates: duplicates,
            ignoredDocuments: 0
        )
    }

    private static func fallbackSymbol(for row: TradeRepublicCSVRow) -> String {
        if !row.brokerSymbol.isEmpty { return row.brokerSymbol }
        return "TR-\(stableHash(row.displayName).prefix(8).uppercased())"
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

private struct TradeRepublicCSVRow: Sendable {
    let kind: TransactionKind
    let brokerSymbol: String
    let displayName: String
    let quantity: Double
    let price: Double
    let fees: Double
    let currency: String
    let date: Date
    let transactionID: String
    let isCorporateAction: Bool

    var identityMaterial: String {
        [
            date.ISO8601Format(),
            kind.rawValue,
            brokerSymbol,
            displayName,
            String(quantity),
            String(price),
            String(fees),
            currency,
            String(isCorporateAction)
        ].joined(separator: "|")
    }
}

private enum TradeRepublicCSVParser {
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

    static func parse(_ text: String, fileName: String) throws -> [TradeRepublicCSVRow] {
        let delimiter = detectDelimiter(in: text)
        let records = parseRows(text, delimiter: delimiter).filter { record in
            record.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        guard !records.isEmpty else {
            throw TradeRepublicCSVImportError.unsupportedFile(fileName)
        }

        let headerCandidate = records.prefix(10).enumerated().max { lhs, rhs in
            headerScore(lhs.element) < headerScore(rhs.element)
        }
        guard let headerIndex = headerCandidate?.offset,
              let header = headerCandidate?.element,
              headerScore(header) >= 6
        else {
            throw TradeRepublicCSVImportError.unsupportedFile(fileName)
        }

        let headers = header.map(\.normalizedTRCSVHeader)
        let dateTimeIndex = index(in: headers, aliases: ["datetime", "timestamp", "horodatage"])
        let dateIndex = index(in: headers, aliases: ["date"])
        let typeIndex = index(in: headers, aliases: ["type", "transactiontype", "typedetransaction"])
        let nameIndex = index(in: headers, aliases: ["name", "nom", "instrumentname"])
        let symbolIndex = index(in: headers, aliases: ["symbol", "symbole", "isin"])
        let sharesIndex = index(in: headers, aliases: ["shares", "quantity", "quantite", "nombre"])
        let priceIndex = index(in: headers, aliases: ["price", "prix", "cours"])
        let amountIndex = index(in: headers, aliases: ["amount", "montant", "value", "valeur"])
        let feeIndex = index(in: headers, aliases: ["fee", "fees", "frais"])
        let taxIndex = index(in: headers, aliases: ["tax", "taxes", "impot", "retenue"])
        let currencyIndex = index(in: headers, aliases: ["currency", "devise"])
        let descriptionIndex = index(in: headers, aliases: ["description"])
        let transactionIDIndex = index(in: headers, aliases: ["transactionid", "idtransaction"])

        guard (dateTimeIndex != nil || dateIndex != nil),
              typeIndex != nil,
              symbolIndex != nil,
              amountIndex != nil
        else {
            throw TradeRepublicCSVImportError.unsupportedFile(fileName)
        }

        var parsedRows: [TradeRepublicCSVRow] = []
        for record in records.dropFirst(headerIndex + 1) {
            let rawType = value(at: typeIndex, in: record)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")
            let rawShares = number(value(at: sharesIndex, in: record))
            let isCorporateAction = ["STOCK_SPLIT", "REVERSE_SPLIT"].contains(rawType)
            let kind: TransactionKind?
            if isCorporateAction, let rawShares, rawShares != 0 {
                kind = rawShares > 0 ? .buy : .sell
            } else {
                kind = transactionKind(rawType)
            }
            guard let kind else { continue }

            let rawDateTime = value(at: dateTimeIndex, in: record)
            let rawDate = value(at: dateIndex, in: record)
            guard let date = parsedDate(rawDateTime.isEmpty ? rawDate : rawDateTime) else {
                continue
            }

            let brokerSymbol = value(at: symbolIndex, in: record).uppercased()
            let description = value(at: descriptionIndex, in: record)
            let rawName = value(at: nameIndex, in: record)
            let displayName = !rawName.isEmpty
                ? rawName
                : (!description.isEmpty ? description : brokerSymbol)
            guard !brokerSymbol.isEmpty || !displayName.isEmpty else { continue }

            let amount = number(value(at: amountIndex, in: record)) ?? 0
            let rawFee = number(value(at: feeIndex, in: record)) ?? 0
            let rawTax = number(value(at: taxIndex, in: record)) ?? 0
            let currency = normalizedCurrency(value(at: currencyIndex, in: record))
            let transactionID = value(at: transactionIDIndex, in: record)

            if kind == .dividend {
                // Les montants, frais et taxes sont signés dans l'export.
                // Une ligne négative correspond à l'annulation d'un versement.
                let netAmount = amount + rawFee + rawTax
                guard netAmount != 0 else { continue }
                parsedRows.append(TradeRepublicCSVRow(
                    kind: .dividend,
                    brokerSymbol: brokerSymbol,
                    displayName: displayName,
                    quantity: 0,
                    price: netAmount,
                    fees: 0,
                    currency: currency,
                    date: date,
                    transactionID: transactionID,
                    isCorporateAction: false
                ))
                continue
            }

            guard let rawShares, abs(rawShares) > 0
            else { continue }
            let quantity = abs(rawShares)
            let explicitPrice = number(value(at: priceIndex, in: record))
            let price = abs(explicitPrice ?? (amount / quantity))
            parsedRows.append(TradeRepublicCSVRow(
                kind: kind,
                brokerSymbol: brokerSymbol,
                displayName: displayName,
                quantity: quantity,
                price: price,
                fees: abs(rawFee) + abs(rawTax),
                currency: currency,
                date: date,
                transactionID: transactionID,
                isCorporateAction: isCorporateAction
            ))
        }
        return parsedRows
    }

    private static func transactionKind(_ value: String) -> TransactionKind? {
        switch value {
        case "BUY", "PURCHASE", "ACHAT", "SAVINGS_PLAN", "SAVINGS_PLAN_EXECUTION", "SAVEBACK":
            return .buy
        case "SELL", "SALE", "VENTE":
            return .sell
        case "DIVIDEND", "CASH_DIVIDEND", "DIVIDENDE", "DISTRIBUTION":
            return .dividend
        default:
            return nil
        }
    }

    private static func headerScore(_ record: [String]) -> Int {
        let recognized = Set([
            "datetime", "date", "accounttype", "category", "type", "assetclass",
            "name", "symbol", "shares", "price", "amount", "fee", "tax", "currency",
            "originalamount", "originalcurrency", "fxrate", "description", "transactionid"
        ])
        return record.map(\.normalizedTRCSVHeader).reduce(0) { score, value in
            score + (recognized.contains(value) ? 1 : 0)
        }
    }

    private static func index(in headers: [String], aliases: Set<String>) -> Int? {
        headers.firstIndex { aliases.contains($0) }
    }

    private static func value(at index: Int?, in record: [String]) -> String {
        guard let index, record.indices.contains(index) else { return "" }
        return record[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedCurrency(_ value: String) -> String {
        let currency = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return currency.count == 3 ? currency : "EUR"
    }

    private static func parsedDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: value) { return date }
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: value) { return date }

        for format in ["yyyy-MM-dd", "dd/MM/yyyy", "dd.MM.yyyy", "dd-MM-yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .autoupdatingCurrent
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
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

private enum TradeRepublicCSVSymbolResolver {
    static func resolve(_ rows: [TradeRepublicCSVRow]) async -> [String: SymbolSearchResult] {
        var instruments: [String: String] = [:]
        for row in rows where !row.brokerSymbol.isEmpty && instruments[row.brokerSymbol] == nil {
            instruments[row.brokerSymbol] = row.displayName
        }

        return await withTaskGroup(of: (String, SymbolSearchResult?).self) { group in
            for (brokerSymbol, displayName) in instruments {
                group.addTask {
                    let symbolResults = try? await MarketDataClient.shared.search(brokerSymbol)
                    if let result = symbolResults?.first {
                        return (brokerSymbol, result)
                    }
                    let nameResults = try? await MarketDataClient.shared.search(displayName)
                    return (brokerSymbol, nameResults?.first)
                }
            }

            var resolved: [String: SymbolSearchResult] = [:]
            for await (brokerSymbol, result) in group {
                if let result { resolved[brokerSymbol] = result }
            }
            return resolved
        }
    }
}

private extension String {
    var normalizedTRCSVHeader: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}
