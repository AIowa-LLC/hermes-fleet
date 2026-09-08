import SwiftUI

/// V2 (Nous Direction A) — section header: the UPPERCASE micro-label role —
/// 11pt semibold caps with wide tracking, muted secondary color ("GATEWAYS",
/// "ACTIVE BOTS"). Trailing action stays the pale-cyan accent (optional
/// closure- or value-based).
///
/// Generic over the pushed destination's type `D` (defaults to `Never` for
/// the closure flavor): the value-based `NavigationLink` MUST carry the
/// concrete route type — erasing to `AnyHashable` breaks the tab shell's
/// `navigationDestination(for:)` type matching (U4 lesson).
public struct SectionHeader<D: Hashable>: View {
    private let title: String
    private let actionTitle: String
    private let action: (() -> Void)?
    private let linkDestination: D?

    /// - Parameters:
    ///   - title: section title, rendered as an UPPERCASE micro-label
    ///     (muted secondary, 11pt semibold, wide tracking).
    ///   - viewAllAction: when non-nil, a pale-cyan action button is shown
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
                .textCase(.uppercase)
                .tracking(FleetTheme.microLabelTracking)
                .foregroundStyle(FleetTheme.textSecondary)
            Spacer()
            if let linkDestination {
                NavigationLink(value: linkDestination) {
                    Text(actionTitle)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(FleetTheme.accent)
                }
                .accessibilityLabel("\(actionTitle) \(title)")
            } else if let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(FleetTheme.accent)
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
