import SwiftUI

/// V4 (Nous Direction A) — the ONE press feedback: scale to 0.97 with a
/// subtle opacity dip, ease-out 0.12s. Deliberately restrained: no spring,
/// no shadow soften (the design is flat — hairlines are the structure, not
/// elevation), no glow. Applied to tappable cards/rows and circular action
/// buttons so every press reads identically fleet-wide.
///
/// Reduce Motion: the scale is dropped (opacity dip alone survives) — the
/// press still acknowledges without movement.
public struct FleetPressableStyle: ButtonStyle {
    public init() {}

    /// Pressed scale factor (pt) — 0.97 per the V4 motion budget.
    public static let pressedScale: CGFloat = 0.97
    /// Pressed opacity dip — a dim, not a disappear.
    public static let pressedOpacity: Double = 0.85
    /// Press feedback duration (seconds), ease-out.
    public static let duration: TimeInterval = 0.12

    public func makeBody(configuration: Configuration) -> some View {
        Pressable(configuration: configuration)
    }

    private struct Pressable: View {
        let configuration: Configuration

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(
                    configuration.isPressed && !reduceMotion
                        ? FleetPressableStyle.pressedScale : 1
                )
                .opacity(
                    configuration.isPressed ? FleetPressableStyle.pressedOpacity : 1
                )
                .animation(
                    .easeOut(duration: FleetPressableStyle.duration),
                    value: configuration.isPressed
                )
        }
    }
}

extension ButtonStyle where Self == FleetPressableStyle {
    /// The Fleet press feedback (V4 motion budget: scale 0.97 + opacity dip).
    public static var fleetPressable: FleetPressableStyle { FleetPressableStyle() }
}

#Preview("FleetPressableStyle") {
    VStack(spacing: FleetTheme.spacingLg) {
        Button("Press me") {}
            .buttonStyle(.fleetPressable)
            .padding(FleetTheme.spacingLg)
            .background(FleetTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: FleetTheme.radiusCard)
                    .strokeBorder(FleetTheme.border, lineWidth: 1)
            )
    }
    .padding()
    .background(FleetTheme.background)
    .preferredColorScheme(.dark)
}
