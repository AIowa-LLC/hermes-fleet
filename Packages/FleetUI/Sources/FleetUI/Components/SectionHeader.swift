import SwiftUI

/// U2 (Gold Fleet) — section header: white 17pt semibold title with an
/// optional cyan action ("View All") trailing.
public struct SectionHeader: View {
    private let title: String
    private let actionTitle: String
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - title: section title (white, 17pt semibold).
    ///   - viewAllAction: when non-nil, a cyan action is shown trailing;
    ///     pass nil for sections without an action.
    ///   - actionTitle: action label; defaults to "View All".
    public init(
        title: String,
        viewAllAction: (() -> Void)? = nil,
        actionTitle: String = "View All"
    ) {
        self.title = title
        self.action = viewAllAction
        self.actionTitle = actionTitle
    }

    public var body: some View {
        HStack {
            Text(title)
                .font(FleetTheme.sectionHeaderFont)
                .foregroundStyle(FleetTheme.textPrimary)
            Spacer()
            if let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: FleetTheme.secondaryFontSize, weight: .semibold))
                        .foregroundStyle(FleetTheme.accentCyan)
                }
                .accessibilityLabel("\(actionTitle) \(title)")
            }
        }
    }

    #Preview("SectionHeader") {
        SectionHeader(title: "Gateways", viewAllAction: {})
            .padding()
            .background(FleetTheme.background)
            .preferredColorScheme(.dark)
    }
}
