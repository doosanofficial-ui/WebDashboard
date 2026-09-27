import SwiftUI

enum TelemetryTheme {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.082)
    static let backgroundRaised = Color(red: 0.055, green: 0.082, blue: 0.118)
    static let surface = Color(red: 0.075, green: 0.105, blue: 0.145)
    static let surfaceRaised = Color(red: 0.105, green: 0.145, blue: 0.19)
    static let plot = Color(red: 0.025, green: 0.045, blue: 0.07)
    static let grid = Color.white.opacity(0.08)
    static let accent = Color(red: 0.21, green: 0.86, blue: 0.95)
    static let accentMuted = Color(red: 0.10, green: 0.46, blue: 0.57)
    static let valid = Color(red: 0.30, green: 0.92, blue: 0.62)
    static let warning = Color(red: 1.0, green: 0.67, blue: 0.24)
    static let critical = Color(red: 1.0, green: 0.33, blue: 0.35)
    static let mutedText = Color.white.opacity(0.58)
    static let quietText = Color.white.opacity(0.38)

    enum Spacing {
        static let xSmall: CGFloat = 8
        static let small: CGFloat = 12
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let xLarge: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 12
        static let medium: CGFloat = 18
        static let large: CGFloat = 24
    }
}
enum TelemetrySurfaceLevel {
    case standard
    case raised
    case plot
}

private struct TelemetrySurfaceModifier: ViewModifier {
    let level: TelemetrySurfaceLevel
    let padding: CGFloat

    func body(content: Content) -> some View {
        let fill: Color = switch level {
        case .standard: TelemetryTheme.surface
        case .raised: TelemetryTheme.surfaceRaised
        case .plot: TelemetryTheme.plot
        }
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: TelemetryTheme.Radius.medium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: TelemetryTheme.Radius.medium, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }
    }
}

extension View {
    func telemetrySurface(_ level: TelemetrySurfaceLevel = .standard,
                          padding: CGFloat = TelemetryTheme.Spacing.medium) -> some View {
        modifier(TelemetrySurfaceModifier(level: level, padding: padding))
    }
}

struct TelemetryStatusBadge: View {
    let title: String
    let color: Color
    let symbol: String

    var body: some View {
        Label(title.uppercased(), systemImage: symbol)
            .font(.caption2.weight(.bold))
            .tracking(0.7)
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(color.opacity(0.13), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.24), lineWidth: 1))
    }
}
