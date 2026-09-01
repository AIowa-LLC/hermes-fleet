import SwiftUI

/// U2 (Gold Fleet) — status pill: colored dot + label on the status color's
/// ~20% tinted background, fully rounded (Capsule), per the hero mock.
public struct StatusPill: View {
    private let status: FleetStatus

    public init(status: FleetStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: FleetTheme.spacingXs) {
            Circle()
                .fill(status.color)
                .frame(width: Self.dotDiameter, height: Self.dotDiameter)
            Text(status.label)
                .font(.system(size: FleetTheme.secondaryFontSize, weight: .semibold))
                .foregroundStyle(status.color)
        }
        .padding(.horizontal, FleetTheme.spacingSm)
        .padding(.vertical, FleetTheme.spacingXs)
        .background(FleetTheme.statusPillTint(status.color))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(status.label)")
    }

    /// Pill dot diameter (pt).
    static let dotDiameter: CGFloat = 8
}

#Preview("StatusPill — all states") {
    VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
        ForEach(FleetStatus.allCases, id: \.self) { StatusPill(status: $0) }
    }
    .padding()
    .background(FleetTheme.background)
    .preferredColorScheme(.dark)
}
