import SwiftUI

/// FOS-7 (SPEC §14/§16/§15) — status pill: leading symbol + exact state
/// word on a subtle tint of the status color. Symbol + word are ALWAYS
/// rendered (color is never the only differentiator). The word renders in
/// primary label with the colored glyph (SPEC §14 status row).
///
/// Motion (SPEC §15): one 150–200 ms crossfade when the status changes;
/// Reduce Motion replaces it with an instant label swap.
public struct StatusPill: View {
    private let status: FleetStatus

    public init(status: FleetStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: FleetTheme.spacingXs) {
            Image(systemName: status.symbolName)
                .font(.system(size: Self.symbolFontSize, weight: .semibold))
                .foregroundStyle(status.color)
                .accessibilityHidden(true)
            Text(status.label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(status.labelColor)
        }
        .padding(.horizontal, FleetTheme.spacingSm)
        .padding(.vertical, FleetTheme.spacingXs)
        .background(Capsule().fill(FleetTheme.statusPillTint(status.color)))
        .overlay(
            Capsule().strokeBorder(status.color.opacity(Self.strokeOpacity), lineWidth: 1)
        )
        // SPEC §15: one 150–200 ms status crossfade; instant under Reduce Motion.
        .animation(reduceMotion ? nil : .easeInOut(duration: Self.crossfadeDuration), value: status)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(status.label)")
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Hairline status-color stroke opacity (subtle definition on canvas).
    static let strokeOpacity: Double = 0.25
    /// Status crossfade duration (seconds) — SPEC §15 budget 150–200 ms.
    static let crossfadeDuration: TimeInterval = 0.18
    /// Pill glyph size (pt).
    static let symbolFontSize: CGFloat = 11
}

#Preview("StatusPill — all states") {
    VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
        ForEach(FleetStatus.allCases, id: \.self) { StatusPill(status: $0) }
    }
    .padding()
    .background(FleetTheme.background)
    .preferredColorScheme(.dark)
}
