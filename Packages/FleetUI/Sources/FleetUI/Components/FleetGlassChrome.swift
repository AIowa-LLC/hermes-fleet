import SwiftUI

/// Liquid Glass chrome seam (refinement Phase 1, SPEC §14 materials).
///
/// Glass is for CHROME only — floating controls, the composer capsule, the
/// drawer footer. Body content (messages, cards, rows) stays on the opaque
/// canvas/surface tokens and never sits on translucent glass.
///
/// Accessibility postures fall back to opaque chrome: Reduce Transparency and
/// Increase Contrast render the theme's elevated surface with a visible
/// border instead of glass (the same seam the high-contrast tokens use).
/// Foreground ink is NEVER supplied by the glass: every caller sets an
/// explicit theme foreground so light and dark both resolve (the blank-pill
/// bug class).
public struct FleetGlassChrome<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.fleetTheme) private var theme

    let shape: S
    let interactive: Bool

    public init(shape: S, interactive: Bool = false) {
        self.shape = shape
        self.interactive = interactive
    }

    /// True when the chrome must render opaque (Reduce Transparency or
    /// Increase Contrast). Exposed for tests via `FleetGlassChromePolicy`.
    private var opaque: Bool {
        FleetGlassChromePolicy.rendersOpaque(
            reduceTransparency: reduceTransparency,
            increasedContrast: colorSchemeContrast == .increased)
    }

    public func body(content: Content) -> some View {
        if opaque {
            content
                .background(theme.surfaceElevated, in: shape)
                .overlay(shape.strokeBorder(
                    theme.borderColor(), lineWidth: colorSchemeContrast == .increased ? 1 : 0.5))
        } else {
            content
                .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        }
    }
}

/// Pure decision for the glass/opaque fallback so the posture contract is
/// testable without rendering.
public enum FleetGlassChromePolicy {
    public static func rendersOpaque(reduceTransparency: Bool, increasedContrast: Bool) -> Bool {
        reduceTransparency || increasedContrast
    }
}

public extension View {
    /// Liquid Glass chrome in `shape`, falling back to opaque chrome under
    /// Reduce Transparency / Increase Contrast. Chrome only — see
    /// `FleetGlassChrome`.
    func fleetGlass<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(FleetGlassChrome(shape: shape, interactive: interactive))
    }
}
