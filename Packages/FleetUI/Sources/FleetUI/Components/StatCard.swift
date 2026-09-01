import SwiftUI

/// U2 (Gold Fleet) — dashboard stat card: SF Symbol icon in a colored
/// rounded square, big bold value (28pt stat font, white), secondary label —
/// all on the shared FleetCard surface.
public struct StatCard: View {
    private let icon: String
    private let tint: Color
    private let value: String
    private let label: String

    /// - Parameters:
    ///   - icon: SF Symbol name (e.g. `"cpu"`).
    ///   - tint: accent for the icon square (icon + ~20% tinted background).
    ///   - value: the stat value (e.g. `"12"`); rendered in the 28pt bold
    ///     stat font.
    ///   - label: secondary caption under the value (e.g. `"Active Bots"`).
    public init(icon: String, tint: Color, value: String, label: String) {
        self.icon = icon
        self.tint = tint
        self.value = value
        self.label = label
    }

    public var body: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                Image(systemName: icon)
                    .font(.system(size: Self.iconSize, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: Self.iconSquare, height: Self.iconSquare)
                    .background(tint.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: Self.iconCorner))
                Text(value)
                    .font(FleetTheme.statFont)
                    .foregroundStyle(FleetTheme.textPrimary)
                Text(label)
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }

    /// Icon square side (pt) and the icon's point size.
    static let iconSquare: CGFloat = 36
    static let iconSize: CGFloat = 16
    /// Icon square corner radius (softer than the 16pt card radius).
    static let iconCorner: CGFloat = 10
}

#Preview("StatCard") {
    HStack(spacing: FleetTheme.spacingMd) {
        StatCard(icon: "cpu", tint: FleetTheme.accentMagenta, value: "3", label: "Active Bots")
        StatCard(icon: "antenna.radiowaves.left.and.right", tint: FleetTheme.accentCyan, value: "2", label: "Gateways")
        StatCard(icon: "heart", tint: FleetTheme.statusOnline, value: "100%", label: "Fleet Health")
    }
    .padding()
    .background(FleetTheme.background)
    .preferredColorScheme(.dark)
}
