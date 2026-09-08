import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Pixel-hairline height (1pt on non-Retina, 0.5pt on Retina+).
#if canImport(UIKit)
private var fleetListRowHairline: CGFloat { 1 / UIScreen.main.scale }
#else
private let fleetListRowHairline: CGFloat = 0.5
#endif

/// FOS-6 (SPEC §18) — the OPERATIONAL ROW container: content with vertical
/// padding, a 44-point minimum actionable height, and a hairline separator.
/// Nothing else. No border, no rounded background, no card chrome — row
/// density comes from shared alignment and typography, not boxes.
///
/// Use for: Bots, Gateways, ordinary conversations, routines, skills,
/// simple activity, navigation, settings. Semantic groups (confirmed
/// attention, focused recovery, actual Kanban cards, onboarding) stay on
/// `FleetCard`.
///
/// Accessibility contract (repo lesson): the row NEVER sets its own
/// accessibilityIdentifier and never combines children — a container id
/// overrides every descendant id. Row identity rides the inner text;
/// inner controls keep their own ids. System press feedback comes from the
/// caller's `.buttonStyle(.fleetPressable)` / native List row.
public struct FleetListRow<Content: View>: View {
    private let showsSeparator: Bool
    private let content: Content

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    /// - Parameters:
    ///   - showsSeparator: draw the bottom hairline. Pass `false` inside a
    ///     `List` (the List already provides native separators) or between
    ///     entries that are not list peers (e.g. transcript messages).
    ///   - content: the row's content. Callers own horizontal insets.
    public init(showsSeparator: Bool = true, @ViewBuilder content: () -> Content) {
        self.showsSeparator = showsSeparator
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.vertical, FleetTheme.spacingSm)
                .frame(minHeight: 44, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            if showsSeparator {
                Rectangle()
                    .fill(FleetTheme.borderColor(colorSchemeContrast: colorSchemeContrast))
                    .frame(height: fleetListRowHairline)
            }
        }
    }
}

#Preview("FleetListRow") {
    VStack {
        FleetListRow {
            HStack(spacing: FleetTheme.spacingMd) {
                Image(systemName: "cpu")
                    .foregroundStyle(FleetTheme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Researcher")
                        .font(.body.weight(.semibold))
                    Text("gateway-1#researcher · 5m")
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                }
                Spacer()
            }
        }
        FleetListRow {
            Text("Writer")
                .font(.body.weight(.semibold))
        }
    }
    .padding()
    .background(FleetTheme.background)
}
