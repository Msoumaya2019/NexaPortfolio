import Foundation
import PDFKit
import SwiftData

enum TradeRepublicImportError: LocalizedError {
    case unreadableFile(String)
    case notTradeRepublicDocument(String)
    case noImportableDocument

    var errorDescription: String? {
        switch self {
        case let .unreadableFile(name):
            return "Le PDF \(name) ne peut pas être lu. Télécharge-le à nouveau depuis Trade Republic."
        case let .notTradeRepublicDocument(name):
            return "Le fichier \(name) n’est pas une confirmation d’exécution ou un relevé de dividende Trade Republic reconnu."
        case .noImportableDocument:
            return "Aucun achat, vente ou dividende exploitable n’a été trouvé. Choisis les confirmations d’exécution ou relevés de dividendes, pas les informations de coûts préalables."
        }
    }
}

struct TradeRepublicImportSummary: Sendable {
    let importedTrades: Int
    let importedDividends: Int
    let skippedDuplicates: Int
    let ignoredDocuments: Int
}

@MainActor
enum TradeRepublicPDFImporter {
    private static let source = "traderepublic:pdf"

    static func importDocuments(
        at urls: [URL],
        into portfolio: Portfolio,
        context: ModelContext
    ) async throws -> TradeRepublicImportSummary {
        var parsedItems: [TradeRepublicParsedItem] = []
        var ignoredDocuments = 0

        for url in urls {
            let hasSecurityAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityAccess { url.stopAccessingSecurityScopedResource() }
            }

            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw TradeRepublicImportError.unreadableFile(url.lastPathComponent)
            }
            guard let document = PDFDocument(data: data) else {
                throw TradeRepublicImportError.unreadableFile(url.lastPathComponent)
            }

            let text = (0..<document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n")
            guard text.foldedForImport.contains("trade republic") else {
                throw TradeRepublicImportError.notTradeRepublicDocument(url.lastPathComponent)
            }

            if let item = TradeRepublicTextParser.parse(text) {
                parsedItems.append(item)
            } else {
                ignoredDocuments += 1
            }
        }

        guard !parsedItems.isEmpty else {
            throw TradeRepublicImportError.noImportableDocument
        }

        let symbols = await TradeRepublicSymbolResolver.resolve(parsedItems)
        let allTransactions = try context.fetch(FetchDescriptor<TradeTransaction>())
        var knownIdentifiers = Set(allTransactions.compactMap(\.externalIdentifier))
        var importedTrades = 0
        var importedDividends = 0
        var duplicates = 0

        for item in parsedItems.sorted(by: { $0.date < $1.date }) {
            let identifier = "\(source):\(item.kind.rawValue):\(stableHash(item.identityMaterial))"
            guard knownIdentifiers.insert(identifier).inserted else {
                duplicates += 1
                continue
            }

            let resolved = symbols[item.isin]
            let symbol = resolved?.symbol ?? item.isin
            let displayName = resolved?.displayName ?? item.displayName
            context.insert(TradeTransaction(
                kind: item.kind,
                symbol: symbol,
                displayName: displayName,
                quantity: item.quantity,
                price: item.amountOrUnitPrice,
                fees: item.fees,
                currencyCode: item.currency,
                date: item.date,
                notes: item.kind == .dividend
                    ? "Import PDF Trade Republic · montant net versé"
                    : "Import PDF Trade Republic",
                externalSource: source,
                externalIdentifier: identifier,
                brokerTicker: item.isin,
                portfolio: portfolio
            ))

            if item.kind == .dividend {
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
            ignoredDocuments: ignoredDocuments
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

private struct TradeRepublicParsedItem: Sendable {
    let kind: TransactionKind
    let isin: String
    let displayName: String
    let quantity: Double
    let amountOrUnitPrice: Double
    let fees: Double
    let currency: String
    let date: Date
    let executionID: String

    var identityMaterial: String {
        [
            executionID,
            date.ISO8601Format(),
            kind.rawValue,
            isin,
            String(quantity),
            String(amountOrUnitPrice),
            String(fees),
            currency
        ].joined(separator: "|")
    }
}

private enum TradeRepublicTextParser {
    private struct PositionLine {
        let name: String
        let quantity: Double
        let unitValue: Double
        let unitCurrency: String
        let total: Double
        let totalCurrency: String
    }

    static func parse(_ text: String) -> TradeRepublicParsedItem? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let foldedLines = lines.map(\.foldedForImport)

        // Les documents ex-ante décrivent une intention d’ordre, pas une exécution.
        if foldedLines.contains(where: {
            $0.contains("ex-ante")
                || $0.contains("information sur les couts")
                || $0.contains("kosteninformation zum wertpapier")
        }) {
            return nil
        }

        guard let isin = extractISIN(from: lines),
              let position = extractPosition(from: lines)
        else { return nil }

        let kind = documentKind(from: foldedLines)
        guard let kind else { return nil }
        let executionID = extractExecutionID(from: lines) ?? ""

        if kind == .dividend {
            guard let payment = extractBookedAmount(from: lines)
                ?? extractLastTotal(from: lines),
                  payment.amount > 0,
                  let date = extractDate(from: lines, preferBookingLine: true)
            else { return nil }

            return TradeRepublicParsedItem(
                kind: .dividend,
                isin: isin,
                displayName: position.name,
                quantity: position.quantity,
                amountOrUnitPrice: payment.amount,
                fees: 0,
                currency: payment.currency,
                date: date,
                executionID: executionID
            )
        }

        guard position.quantity > 0,
              position.unitValue >= 0,
              let date = extractDate(from: lines, preferBookingLine: false)
        else { return nil }

        return TradeRepublicParsedItem(
            kind: kind,
            isin: isin,
            displayName: position.name,
            quantity: position.quantity,
            amountOrUnitPrice: position.unitValue,
            fees: extractFees(from: lines),
            currency: position.unitCurrency,
            date: date,
            executionID: executionID
        )
    }

    private static func documentKind(from lines: [String]) -> TransactionKind? {
        let exactDividendTitles = Set([
            "dividende", "dividende en especes", "cash dividend", "dividend",
            "ausschuttung", "ausschuettung", "distribution", "dividendo"
        ])
        if lines.contains(where: {
            exactDividendTitles.contains($0)
                || $0.hasPrefix("dividende a la date")
                || $0.hasPrefix("dividende en especes avec")
                || $0.hasPrefix("dividend with")
        }) {
            return .dividend
        }

        let tokens = Set(lines.flatMap { $0.split(whereSeparator: { !$0.isLetter }).map(String.init) })
        if !tokens.isDisjoint(with: ["vente", "verkauf", "sell", "venta"]) {
            return .sell
        }
        if !tokens.isDisjoint(with: ["achat", "kauf", "buy", "compra", "acquisto"])
            || lines.contains(where: {
                $0.contains("investissement programme")
                    || $0.contains("sparplanausfuhrung")
                    || $0.contains("savings plan execution")
                    || $0.contains("saveback execution")
            }) {
            return .buy
        }
        return nil
    }

    private static func extractISIN(from lines: [String]) -> String? {
        let pattern = "^(?:ISIN\\s*:?\\s*)?([A-Z]{2}[A-Z0-9]{9}[0-9])$"
        for line in lines {
            if let groups = captures(pattern, in: line.uppercased()) {
                return groups[0]
            }
        }
        return nil
    }

    private static func extractPosition(from lines: [String]) -> PositionLine? {
        let unit = "(?:titre\\(s\\)|titres?|stk\\.?|stücke|stuecke|pcs\\.?|pz\\.?|tít\\.?)"
        let number = "([0-9][0-9.,' ]*)"
        let pattern = "^(.+?)\\s+\(number)\\s+\(unit)\\s+\(number)\\s+([A-Z]{3})\\s+\(number)\\s+([A-Z]{3})$"

        for line in lines {
            guard let groups = captures(pattern, in: line, caseInsensitive: true),
                  groups.count == 6,
                  let quantity = parseNumber(groups[1]),
                  let unitValue = parseNumber(groups[2]),
                  let total = parseNumber(groups[4])
            else { continue }
            return PositionLine(
                name: groups[0].trimmingCharacters(in: .whitespacesAndNewlines),
                quantity: abs(quantity),
                unitValue: abs(unitValue),
                unitCurrency: groups[3].uppercased(),
                total: abs(total),
                totalCurrency: groups[5].uppercased()
            )
        }
        return nil
    }

    private static func extractExecutionID(from lines: [String]) -> String? {
        let pattern = "(?:EX.CUTION|AUSF.HRUNG|EXECUTION|EJECUCI.N|ESECUZIONE)\\s+([A-Z0-9-]+)"
        for line in lines {
            if let groups = captures(pattern, in: line.uppercased(), caseInsensitive: true) {
                return groups[0]
            }
        }
        return nil
    }

    private static func extractFees(from lines: [String]) -> Double {
        let amountPattern = "(-?[0-9][0-9.,' ]*)\\s+[A-Z]{3}$"
        return lines.reduce(0) { result, line in
            let folded = line.foldedForImport
            let isFee = folded.contains("frais")
                || folded.contains("fremdkosten")
                || folded.contains("commission")
                || folded.contains("external cost")
            guard isFee,
                  let groups = captures(amountPattern, in: line, caseInsensitive: true),
                  let value = parseNumber(groups[0])
            else { return result }
            return result + abs(value)
        }
    }

    private static func extractBookedAmount(from lines: [String]) -> (amount: Double, currency: String)? {
        let date = "(?:[0-3][0-9][./][01][0-9][./][0-9]{4}|[0-9]{4}-[01][0-9]-[0-3][0-9])"
        let pattern = "^[A-Z]{2}[A-Z0-9 ]{12,}\\s+\(date)\\s+(-?[0-9][0-9.,' ]*)\\s+([A-Z]{3})$"
        for line in lines.reversed() {
            guard let groups = captures(pattern, in: line.uppercased()),
                  let amount = parseNumber(groups[0])
            else { continue }
            return (abs(amount), groups[1].uppercased())
        }
        return nil
    }

    private static func extractLastTotal(from lines: [String]) -> (amount: Double, currency: String)? {
        let pattern = "^(?:TOTAL|GESAMT|TOTALE|SUMME)\\s+(-?[0-9][0-9.,' ]*)\\s+([A-Z]{3})$"
        for line in lines.reversed() {
            guard let groups = captures(pattern, in: line.uppercased()),
                  let amount = parseNumber(groups[0])
            else { continue }
            return (abs(amount), groups[1].uppercased())
        }
        return nil
    }

    private static func extractDate(from lines: [String], preferBookingLine: Bool) -> Date? {
        let actionWords = [
            "achat", "vente", "buy", "sell", "kauf", "verkauf", "compra", "venta",
            "investissement programme", "sparplanausfuhrung", "savings plan", "saveback"
        ]
        let orderedLines: [String]
        if preferBookingLine {
            orderedLines = lines.filter { $0.range(of: "^[A-Z]{2}[A-Z0-9 ]{12,}\\s+", options: .regularExpression) != nil }
                + lines
        } else {
            orderedLines = lines.filter { line in
                actionWords.contains { line.foldedForImport.contains($0) }
            } + lines
        }

        for line in orderedLines {
            if let date = parseDate(in: line) { return date }
        }
        return nil
    }

    private static func parseDate(in line: String) -> Date? {
        let patterns = ["[0-3][0-9]/[01][0-9]/[0-9]{4}", "[0-3][0-9]\\.[01][0-9]\\.[0-9]{4}", "[0-9]{4}-[01][0-9]-[0-3][0-9]"]
        guard let rawDate = patterns.compactMap({ firstMatch($0, in: line) }).first else { return nil }
        let rawTime = firstMatch("[0-2][0-9]:[0-5][0-9]", in: line)
        let input = rawTime.map { "\(rawDate) \($0)" } ?? rawDate
        let baseFormats: [String]
        if rawDate.contains("/") {
            baseFormats = ["dd/MM/yyyy"]
        } else if rawDate.contains(".") {
            baseFormats = ["dd.MM.yyyy"]
        } else {
            baseFormats = ["yyyy-MM-dd"]
        }

        for baseFormat in baseFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .autoupdatingCurrent
            formatter.dateFormat = rawTime == nil ? baseFormat : "\(baseFormat) HH:mm"
            if let result = formatter.date(from: input) { return result }
        }
        return nil
    }

    private static func parseNumber(_ rawValue: String) -> Double? {
        var value = rawValue
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "'", with: "")
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
        return Double(value)
    }

    private static func firstMatch(_ pattern: String, in string: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: string,
                range: NSRange(string.startIndex..<string.endIndex, in: string)
              ),
              let range = Range(match.range, in: string)
        else { return nil }
        return String(string[range])
    }

    private static func captures(
        _ pattern: String,
        in string: String,
        caseInsensitive: Bool = false
    ) -> [String]? {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(
                in: string,
                range: NSRange(string.startIndex..<string.endIndex, in: string)
              ),
              match.numberOfRanges > 1
        else { return nil }

        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: string) else { return nil }
            return String(string[range])
        }
    }
}

private enum TradeRepublicSymbolResolver {
    static func resolve(_ items: [TradeRepublicParsedItem]) async -> [String: SymbolSearchResult] {
        let identifiers = Set(items.map(\.isin))
        return await withTaskGroup(of: (String, SymbolSearchResult?).self) { group in
            for isin in identifiers {
                group.addTask {
                    let results = try? await MarketDataClient.shared.search(isin)
                    return (isin, results?.first)
                }
            }

            var values: [String: SymbolSearchResult] = [:]
            for await (isin, result) in group {
                if let result { values[isin] = result }
            }
            return values
        }
    }
}

private extension String {
    var foldedForImport: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
    }
}
