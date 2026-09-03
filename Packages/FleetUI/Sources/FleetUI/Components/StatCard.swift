import SwiftUI

/// V2 (Nous Direction A) — dashboard stat tile: MONO number on a flat
/// hairline card with an UPPERCASE micro-label underneath. The V1 icon
/// square / tinted-accent treatment is gone — a stat is read, not decorated
/// (terminal-minimal restraint; numbers are the identity).
///
/// The value renders in the 28pt bold mono stat font (tabular figures), the
/// label in the 11pt uppercase micro-label role with wide tracking.
public struct StatCard: View {
    private let value: String
    private let label: String

    /// - Parameters:
    ///   - value: the stat value (e.g. `"12"`); rendered in the 28pt bold
    ///     mono stat font with tabular figures.
    ///   - label: the caption under the value (e.g. `"Active Bots"`),
    ///     rendered as an UPPERCASE micro-label.
    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }

    public var body: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                Text(value)
                    .font(FleetTheme.statFont)
                    .foregroundStyle(FleetTheme.textPrimary)
                    // V4 motion: numeric values slide/settle instead of
                    // hard-swapping when counts refresh.
                    .contentTransition(.numericText())
                Text(label)
                    .font(FleetTheme.microLabelFont)
                    .textCase(.uppercase)
                    .tracking(FleetTheme.microLabelTracking)
                    .foregroundStyle(FleetTheme.textSecondary)
            }
        }
        .animation(.easeOut(duration: 0.18), value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

#Preview("StatCard") {
    HStack(spacing: FleetTheme.spacingMd) {
        StatCard(value: "3", label: "Active Bots")
        StatCard(value: "2", label: "Gateways")
        StatCard(value: "100%", label: "Fleet Health")
    }
    .padding()
    .background(FleetTheme.background)
    .preferredColorScheme(.dark)
}
