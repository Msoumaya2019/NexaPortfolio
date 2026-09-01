import SwiftUI
import SwiftData

struct AddTradeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var marketData: MarketDataStore

    let portfolio: Portfolio

    @State private var kind: TransactionKind = .buy
    @State private var symbol = ""
    @State private var displayName = ""
    @State private var quantity = "1"
    @State private var price = ""
    @State private var fees = "0"
    @State private var currencyCode: String
    @State private var date = Date.now
    @State private var notes = ""
    @State private var showingSearch = false
    @State private var isLoadingQuote = false
    @State private var errorMessage: String?
    @State private var latestQuote: MarketQuote?

    init(portfolio: Portfolio) {
        self.portfolio = portfolio
        _currencyCode = State(initialValue: portfolio.currencyCode)
    }

    private var parsedQuantity: Double {
        Double(quantity.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var parsedPrice: Double {
        Double(price.replacingOccurrences(of: ",", with: ".")) ?? -1
    }

    private var parsedFees: Double {
        Double(fees.replacingOccurrences(of: ",", with: ".")) ?? -1
    }

    private var canSave: Bool {
        !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parsedPrice >= 0
            && parsedFees >= 0
            && (kind == .dividend || parsedQuantity > 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Opération", selection: $kind) {
                        ForEach(TransactionKind.allCases) { item in
                            Label(item.title, systemImage: item.systemImage).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Titre") {
                    Button {
                        showingSearch = true
                    } label: {
                        HStack {
                            Label(symbol.isEmpty ? "Rechercher un titre" : symbol, systemImage: "magnifyingglass")
                            Spacer()
                            if isLoadingQuote { ProgressView() }
                        }
                    }

                    TextField("Symbole (ex. AAPL)", text: $symbol)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Nom", text: $displayName)
                }

                Section(kind == .dividend ? "Dividende" : "Exécution") {
                    if kind != .dividend {
                        TextField("Quantité", text: $quantity)
                            .keyboardType(.decimalPad)
                    }
                    TextField(kind == .dividend ? "Montant reçu" : "Prix unitaire", text: $price)
                        .keyboardType(.decimalPad)
                    TextField("Frais", text: $fees)
                        .keyboardType(.decimalPad)
                    Picker("Devise", selection: $currencyCode) {
                        ForEach(["EUR", "USD", "GBP", "CHF", "CAD", "JPY"], id: \.self) { Text($0).tag($0) }
                    }
                    DatePicker("Date", selection: $date, displayedComponents: [.date])
                }

                Section("Notes") {
                    TextField("Facultatif", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle("Nouvelle transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { save() }
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showingSearch) {
                SecuritySearchView { result in
                    symbol = result.symbol
                    displayName = result.displayName
                    loadQuote(for: result.symbol)
                }
            }
            .alert("Transaction impossible", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func loadQuote(for symbol: String) {
        isLoadingQuote = true
        Task {
            do {
                let quote = try await marketData.quote(for: symbol)
                latestQuote = quote
                price = quote.price.formatted(.number.precision(.fractionLength(2...6)))
                currencyCode = quote.currencyCode
                if displayName.isEmpty { displayName = quote.displayName }
            } catch {
                errorMessage = "Le titre a été sélectionné, mais le cours n’a pas pu être chargé. Tu peux saisir le prix manuellement."
            }
            isLoadingQuote = false
        }
    }

    private func save() {
        do {
            try PortfolioLedger.record(
                kind: kind,
                symbol: symbol,
                displayName: displayName,
                quantity: kind == .dividend ? 0 : parsedQuantity,
                price: parsedPrice,
                fees: parsedFees,
                currencyCode: currencyCode,
                date: date,
                notes: notes,
                in: portfolio,
                context: modelContext
            )

            let normalizedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if let quote = latestQuote,
               quote.symbol.uppercased() == normalizedSymbol,
               let holding = portfolio.holdings.first(where: { $0.symbol == normalizedSymbol }) {
                holding.currentPrice = quote.price
                holding.previousClose = quote.previousClose
                holding.currencyCode = quote.currencyCode
                holding.annualDividendPerShare = quote.annualDividendPerShare
                holding.dividendYieldPercent = quote.dividendYieldPercent
                holding.lastDividendPerShare = quote.lastDividendPerShare
                holding.lastDividendDate = quote.lastDividendDate
                holding.dividendPaymentsLastTwelveMonths = quote.dividendPaymentsLastTwelveMonths
                holding.lastUpdated = quote.timestamp
                try modelContext.save()
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
