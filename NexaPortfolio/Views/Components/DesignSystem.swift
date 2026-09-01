import SwiftUI

enum AppTheme {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.095)
    static let card = Color(red: 0.07, green: 0.095, blue: 0.15)
    static let raisedCard = Color(red: 0.095, green: 0.125, blue: 0.19)
    static let accent = Color(red: 0.31, green: 0.85, blue: 0.72)
    static let accentBlue = Color(red: 0.32, green: 0.60, blue: 1.0)
    static let positive = Color(red: 0.28, green: 0.86, blue: 0.57)
    static let negative = Color(red: 1.0, green: 0.38, blue: 0.42)
    static let secondaryText = Color.white.opacity(0.62)

    static let allocationColors: [Color] = [
        accent,
        accentBlue,
        Color(red: 0.73, green: 0.48, blue: 1.0),
        Color(red: 1.0, green: 0.67, blue: 0.28),
        Color(red: 0.95, green: 0.36, blue: 0.72),
        Color(red: 0.34, green: 0.78, blue: 0.98)
    ]
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
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
            (yieldPercent > 0 ? AppTheme.accent : Color.white).opacity(0.09),
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
