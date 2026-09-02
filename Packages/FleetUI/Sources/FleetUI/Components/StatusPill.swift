import SwiftUI

/// V2 (Nous Direction A) — status pill: leading semantic dot + label, on a
/// subtle tint of the status color, with a hairline stroke of the same color
/// for definition on the near-black canvas. Fully rounded (Capsule).
///
/// The dot + semantic tint IS the status read (process-table voice); text
/// stays title-case (FleetStatus.label) — it is data, not a micro-label.
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
        .background(Capsule().fill(FleetTheme.statusPillTint(status.color)))
        .overlay(
            Capsule().strokeBorder(status.color.opacity(Self.strokeOpacity), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(status.label)")
    }

    /// Pill dot diameter (pt).
    static let dotDiameter: CGFloat = 8
    /// Hairline status-color stroke opacity (subtle definition on #0A0A0A).
    static let strokeOpacity: Double = 0.25
}

#Preview("StatusPill — all states") {
    VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
        ForEach(FleetStatus.allCases, id: \.self) { StatusPill(status: $0) }
    }
    .padding()
    .background(FleetTheme.background)
    .preferredColorScheme(.dark)
}
