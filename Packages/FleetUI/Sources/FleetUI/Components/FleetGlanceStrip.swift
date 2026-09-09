import SwiftUI

/// One fact inside a `FleetGlanceStrip` — value + caption. Deliberately
/// NOT a bordered tile (SPEC §18: "no four bordered tiles"). VoiceOver
/// reads it as one element, "label: value".
public struct FleetGlanceFact: View {
    let value: String
    let label: String
    let id: String

    public init(value: String, label: String, id: String) {
        self.value = value
        self.label = label
        self.id = id
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(FleetTheme.statFont)
                .foregroundStyle(FleetTheme.textPrimary)
                .lineLimit(1)
            Text(label)
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(FleetTheme.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
        .accessibilityIdentifier(id)
        // Surface as a static text in the AX tree: the fact is read-only
        // content, and text queries (tests + VoiceOver) match by kind.
        .accessibilityAddTraits(.isStaticText)
    }
}

/// FOS-6 (SPEC §18) — the shared GLANCE STRIP: four small facts about
/// coverage and counts, 2×2 at standard type sizes, one per line at
/// accessibility sizes. No tile borders, no background boxes — the grid is
/// alignment, not decoration.
///
/// Honesty contract inherited from FOS-4 Home: the CALLER builds each
/// fact's value under data-coverage truth (unknown must not render as
/// zero; incomplete coverage is stated in the caller's coverage line).
///
/// Accessibility contract (repo lesson): NO container identifier — on
/// non-AX containers SwiftUI forwards it to descendants where it
/// overrides the per-fact identifiers. The per-fact
/// `accessibilityElement(children: .ignore)` keeps each fact a single
/// VoiceOver stop with a stable id.
public struct FleetGlanceStrip: View {
    /// leading-top, trailing-top, leading-bottom, trailing-bottom.
    let a: FleetGlanceFact
    let b: FleetGlanceFact
    let c: FleetGlanceFact
    let d: FleetGlanceFact

    @Environment(\.dynamicTypeSize) private var typeSize

    public init(
        a: FleetGlanceFact, b: FleetGlanceFact,
        c: FleetGlanceFact, d: FleetGlanceFact
    ) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
    }

    public var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // Large type: order and readability over viewport packing
                // (SPEC §21 gate 3) — stacked, one fact per line.
                VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                    a; b; c; d
                }
            } else {
                VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                    HStack(alignment: .top, spacing: FleetTheme.spacingLg) { a; b }
                    HStack(alignment: .top, spacing: FleetTheme.spacingLg) { c; d }
                }
            }
        }
    }
}

#Preview("FleetGlanceStrip") {
    FleetGlanceStrip(
        a: FleetGlanceFact(value: "2/3", label: "Connected", id: "preview.connected"),
        b: FleetGlanceFact(value: "12", label: "Known Bots", id: "preview.bots"),
        c: FleetGlanceFact(value: "—", label: "Active", id: "preview.active"),
        d: FleetGlanceFact(value: "1", label: "Known attention items", id: "preview.needsYou")
    )
    .padding()
    .background(FleetTheme.background)
}
