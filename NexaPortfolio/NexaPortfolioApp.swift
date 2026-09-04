import SwiftUI
import SwiftData

@main
struct NexaPortfolioApp: App {
    private let modelContainer: ModelContainer = {
        let schema = Schema([
            Portfolio.self,
            Holding.self,
            TradeTransaction.self,
            Watchlist.self,
            WatchlistItem.self
        ])

        do {
            return try ModelContainer(for: schema)
        } catch {
            fatalError("Impossible de créer la base locale: \(error)")
        }
    }()

    @StateObject private var marketData = MarketDataStore()
    @AppStorage("appearance.mode") private var appearanceRawValue = AppAppearance.dark.rawValue

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRawValue) ?? .dark
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(marketData)
                .preferredColorScheme(appearance.colorScheme)
        }
        .modelContainer(modelContainer)
    }
}
