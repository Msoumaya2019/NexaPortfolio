import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Portfolio.createdAt) private var portfolios: [Portfolio]
    @Query(sort: \Watchlist.createdAt) private var watchlists: [Watchlist]
    var body: some View {
        TabView {
            NavigationStack {
                DashboardView()
            }
            .tabItem { Label("Aperçu", systemImage: "chart.xyaxis.line") }

            NavigationStack {
                PortfolioView()
            }
            .tabItem { Label("Portefeuille", systemImage: "briefcase.fill") }

            NavigationStack {
                WatchlistsView()
            }
            .tabItem { Label("Suivi", systemImage: "star.fill") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Réglages", systemImage: "gearshape.fill") }
        }
        .tint(AppTheme.accent)
        .task { createInitialDataIfNeeded() }
    }

    private func createInitialDataIfNeeded() {
        if portfolios.isEmpty {
            modelContext.insert(Portfolio(name: "Principal", currencyCode: "EUR"))
        }
        if watchlists.isEmpty {
            modelContext.insert(Watchlist(name: "À surveiller"))
        }
        try? modelContext.save()
    }
}
