import SwiftUI

/// Rounded loading placeholder that matches the `FleetSkeletonRow` idiom: a
/// `theme.border` fill that gently breathes in opacity. The breathe is
/// disabled under Reduce Motion, where the block stays static. Decorative
/// only, so it is hidden from accessibility.
public struct FleetSkeletonBlock: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    private let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = 8) {
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(theme.border)
            .opacity(reduceMotion ? 1 : (dimmed ? 0.5 : 1))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                value: dimmed
            )
            .onAppear { if !reduceMotion { dimmed = true } }
            .accessibilityHidden(true)
    }
}
