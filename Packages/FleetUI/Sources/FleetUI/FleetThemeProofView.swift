#if DEBUG
import SwiftUI

/// Deterministic, debug-only acceptance surface for Issue #6. It deliberately
/// consumes the same environment seam as production views and is enabled only
/// by the UI-test launch argument `-issue6-theme-proof`.
public struct FleetThemeProofView: View {
    @Environment(\.fleetTheme) private var theme

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
            Text("Theme proof")
                .font(FleetTheme.sectionHeaderFont)
                .foregroundStyle(theme.textPrimary)
            Text("Highlight \(theme.resolvedPalette.highlight.hexString)")
                .accessibilityIdentifier("fleet.theme.proof.applied-highlight")
            Text("Text \(theme.resolvedPalette.text.hexString)")
                .accessibilityIdentifier("fleet.theme.proof.applied-text")
            Text("Background \(theme.resolvedPalette.background.hexString)")
                .accessibilityIdentifier("fleet.theme.proof.applied-background")
            Text(theme.isIncreasedContrast ? "Increase Contrast on" : "Increase Contrast off")
                .accessibilityIdentifier("fleet.theme.proof.increased-contrast")

            AssistantRichTextView(
                markdown: "**Rich Markdown** [link](https://example.com) and `code`",
                isStreaming: false,
                identity: "issue6-theme-proof")
                .frame(maxHeight: 70)
                .accessibilityIdentifier("fleet.theme.proof.rich-markdown")

            VStack(alignment: .leading, spacing: 2) {
                Text("Semantic statuses")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                ForEach(FleetStatus.allCases, id: \.self) { status in
                    StatusPill(status: status)
                }
            }
            .accessibilityIdentifier("fleet.theme.proof.semantic-statuses")
        }
        .padding(FleetTheme.spacingMd)
        .frame(maxWidth: 360, alignment: .leading)
        .background(theme.surface)
        .overlay {
            RoundedRectangle(cornerRadius: FleetTheme.radiusCard)
                .stroke(theme.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: FleetTheme.radiusCard))
    }
}
#endif
