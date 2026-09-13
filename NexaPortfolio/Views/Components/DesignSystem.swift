import SwiftUI
import UIKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "Jour"
        case .dark: "Nuit"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }
}

enum PortfolioPerformancePeriod: String, CaseIterable, Identifiable {
    case sinceInception
    case sixMonths
    case threeMonths
    case oneMonth
    case oneWeek
    case oneDay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sinceInception: "Depuis le début"
        case .sixMonths: "6 mois"
        case .threeMonths: "3 mois"
        case .oneMonth: "1 mois"
        case .oneWeek: "1 semaine"
        case .oneDay: "24 h"
        }
    }

    var metricTitle: String {
        switch self {
        case .sinceInception: "Depuis le début"
        default: title
        }
    }

    var startDate: Date? {
        let calendar = Calendar.current
        switch self {
        case .sinceInception:
            return nil
        case .oneDay:
            return calendar.date(byAdding: .day, value: -1, to: .now)
        case .sixMonths:
            return calendar.date(byAdding: .month, value: -6, to: .now)
        case .threeMonths:
            return calendar.date(byAdding: .month, value: -3, to: .now)
        case .oneMonth:
            return calendar.date(byAdding: .month, value: -1, to: .now)
        case .oneWeek:
            return calendar.date(byAdding: .day, value: -7, to: .now)
        }
    }
}

struct PerformancePeriodMenu: View {
    @Binding var selection: String

    private var selectedPeriod: PortfolioPerformancePeriod {
        PortfolioPerformancePeriod(rawValue: selection) ?? .oneDay
    }

    var body: some View {
        Menu {
            Picker("Période", selection: $selection) {
                ForEach(PortfolioPerformancePeriod.allCases) { period in
                    Text(period.title).tag(period.rawValue)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedPeriod.title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppTheme.accentBlue)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(AppTheme.accentBlue.opacity(0.10), in: Capsule())
        }
        .accessibilityLabel("Choisir la période de performance")
    }
}

enum AppTheme {
    static let background = adaptive(
        light: UIColor(red: 0.955, green: 0.970, blue: 0.985, alpha: 1),
        dark: UIColor(red: 0.035, green: 0.055, blue: 0.095, alpha: 1)
    )
    static let card = adaptive(
        light: .white,
        dark: UIColor(red: 0.07, green: 0.095, blue: 0.15, alpha: 1)
    )
    static let raisedCard = adaptive(
        light: UIColor(red: 0.925, green: 0.945, blue: 0.970, alpha: 1),
        dark: UIColor(red: 0.095, green: 0.125, blue: 0.19, alpha: 1)
    )
    static let heroStart = adaptive(
        light: UIColor(red: 0.82, green: 0.96, blue: 0.92, alpha: 1),
        dark: UIColor(red: 0.10, green: 0.25, blue: 0.31, alpha: 1)
    )
    static let accent = adaptive(
        light: UIColor(red: 0.02, green: 0.53, blue: 0.40, alpha: 1),
        dark: UIColor(red: 0.31, green: 0.85, blue: 0.72, alpha: 1)
    )
    static let accentBlue = adaptive(
        light: UIColor(red: 0.12, green: 0.40, blue: 0.86, alpha: 1),
        dark: UIColor(red: 0.32, green: 0.60, blue: 1.0, alpha: 1)
    )
    static let positive = adaptive(
        light: UIColor(red: 0.03, green: 0.50, blue: 0.28, alpha: 1),
        dark: UIColor(red: 0.28, green: 0.86, blue: 0.57, alpha: 1)
    )
    static let negative = adaptive(
        light: UIColor(red: 0.82, green: 0.12, blue: 0.18, alpha: 1),
        dark: UIColor(red: 1.0, green: 0.38, blue: 0.42, alpha: 1)
    )
    static let primaryText = adaptive(light: .black, dark: .white)
    static let secondaryText = adaptive(
        light: UIColor.black.withAlphaComponent(0.58),
        dark: UIColor.white.withAlphaComponent(0.62)
    )
    static let border = adaptive(
        light: UIColor.black.withAlphaComponent(0.08),
        dark: UIColor.white.withAlphaComponent(0.06)
    )

    static let allocationColors: [Color] = [
        accent,
        accentBlue,
        Color(red: 0.73, green: 0.48, blue: 1.0),
        Color(red: 1.0, green: 0.67, blue: 0.28),
        Color(red: 0.95, green: 0.36, blue: 0.72),
        Color(red: 0.34, green: 0.78, blue: 0.98)
    ]

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
    }
}

extension View {
    func appCard() -> some View { modifier(CardModifier()) }
}

struct ChangeBadge: View {
    let value: Double

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: value >= 0 ? "arrow.up.right" : "arrow.down.right")
            Text(value, format: .number.precision(.fractionLength(2)))
            Text("%")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(value >= 0 ? AppTheme.positive : AppTheme.negative)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background((value >= 0 ? AppTheme.positive : AppTheme.negative).opacity(0.12), in: Capsule())
    }
}

struct DividendBadge: View {
    let yieldPercent: Double

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "banknote.fill")
            if yieldPercent > 0 {
                Text("Div. \(yieldPercent / 100, format: .percent.precision(.fractionLength(2)))")
            } else {
                Text("Aucun dividende")
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(yieldPercent > 0 ? AppTheme.accent : AppTheme.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            (yieldPercent > 0 ? AppTheme.accent : AppTheme.secondaryText).opacity(0.09),
            in: Capsule()
        )
    }
}

struct SymbolBadge: View {
    let symbol: String
    var size: CGFloat = 42

    private var initials: String {
        String(symbol.prefix(3)).uppercased()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AppTheme.accentBlue.opacity(0.85), AppTheme.accent.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(initials)
                .font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 70, height: 70)
                .background(AppTheme.accent.opacity(0.1), in: Circle())
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}

extension Double {
    func currency(_ code: String = "EUR") -> String {
        formatted(.currency(code: code).precision(.fractionLength(2)))
    }
}
