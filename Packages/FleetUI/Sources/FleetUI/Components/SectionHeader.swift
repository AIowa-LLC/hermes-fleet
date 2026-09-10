import SwiftUI

/// FOS-7 (SPEC §14) — section header: headline semibold, sentence/title
/// case, muted secondary color ("Gateways", "Active Now"). The tracked
/// uppercase micro-label treatment is retired. Trailing action keeps the
/// Fleet violet accent (optional closure- or value-based).
///
/// Generic over the pushed destination's type `D` (defaults to `Never` for
/// the closure flavor): the value-based `NavigationLink` MUST carry the
/// concrete route type — erasing to `AnyHashable` breaks the tab shell's
/// `navigationDestination(for:)` type matching (U4 lesson).
public struct SectionHeader<D: Hashable>: View {
    @Environment(\.fleetTheme) private var theme
    private let title: String
    private let actionTitle: String
    private let action: (() -> Void)?
    private let linkDestination: D?

    /// - Parameters:
    ///   - title: section title, rendered as a headline semibold label
    ///     (muted secondary, sentence/title case, no letter tracking).
    ///   - viewAllAction: when non-nil, an accent action button is shown
    ///     trailing; pass nil for sections without an action.
    ///   - actionTitle: action label; defaults to "View All".
    public init(
        title: String,
        viewAllAction: (() -> Void)? = nil,
        actionTitle: String = "View All"
    ) where D == Never {
        self.title = title
        self.action = viewAllAction
        self.actionTitle = actionTitle
        self.linkDestination = nil
    }

    /// Value-based variant (U4): the action renders as a `NavigationLink`
    /// pushing `destination` on the enclosing NavigationStack — preferred
    /// inside stacks (no programmatic path wiring at the call site).
    /// FOS-4: the action label is injectable ("See all" / "Connection
    /// summary" per SPEC §7).
    public init(
        title: String,
        destination: D,
        actionTitle: String = "View All"
    ) {
        self.title = title
        self.action = nil
        self.actionTitle = actionTitle
        self.linkDestination = destination
    }

    public var body: some View {
        HStack {
            Text(title)
                .font(FleetTheme.sectionHeaderFont)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            if let linkDestination {
                NavigationLink(value: linkDestination) {
                    Text(actionTitle)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.highlight)
                }
                .accessibilityLabel("\(actionTitle) \(title)")
            } else if let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.highlight)
                }
                .accessibilityLabel("\(actionTitle) \(title)")
            }
        }
    }

    #Preview("SectionHeader") {
        SectionHeader<Never>(title: "Gateways", viewAllAction: {})
            .padding()
            .background(FleetTheme.background)
            .preferredColorScheme(.dark)
    }
}
