import SwiftUI
import FleetCore

/// Card E — the branded, indeterminate image-generation animation.
///
/// Rendered beneath a tool row's chip while (and only while) the gateway has
/// VERIFIED an in-flight `image_generate` call — a wire frame naming the tool
/// (`ImageGenerationActivity`). Indeterminate by construction: the gateway
/// reports no completion fraction for a generation, so this view carries no
/// percentage, countdown, or ETA — only the FleetWingMark and honest copy
/// (`ImageGenerationCopy`, pinned by `ImageGenerationActivityTests`).
///
/// - Reduce Motion: the same branding holds still (`ImageGenerationRules.motion`).
/// - Light/dark: the mark is the opaque white-wing plate asset (readable on
///   both appearances by construction); the card chrome uses theme tokens.
/// - Lifecycle: `.delivered` / `.stopped` remove this view entirely — the
///   row's artifact slot or chip tells the outcome, so the animation can
///   never overlap a delivered image.
struct FleetWingGenerationView: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Accessibility/identifier stem — the citing row id, so two generations
    /// on one screen never collide.
    let identifier: String

    @State private var pulsing = false

    /// Movement is allowed only when Reduce Motion permits it AND the
    /// platform gate allows it. Under XCUITest continuous motion defaults OFF
    /// (a repeat-forever animation fights XCUITest's idle wait and
    /// destabilizes every query after it — the splash precedent); a test can
    /// opt in with `HERMES_FLEET_WING_MOTION=1`. Production always animates;
    /// the still variant is exactly what Reduce Motion users see, so the
    /// default test rendering is the accessible one.
    private var animates: Bool {
        guard ImageGenerationRules.motion(reduceMotion: reduceMotion) == .animated else { return false }
        return Self.motionGate
    }

    static var motionGate: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let forced = env["HERMES_FLEET_WING_MOTION"] {
            return forced == "1" || forced == "on"
        }
        return env["XCTestConfigurationFilePath"] == nil
        #else
        return true
        #endif
    }

    var body: some View {
        HStack(spacing: 12) {
            medallion
            VStack(alignment: .leading, spacing: 2) {
                Text(ImageGenerationCopy.caption)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(ImageGenerationCopy.detail)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 320, alignment: .leading)
        .background(theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(theme.border, lineWidth: 1))
        // One focusable element for the whole stage: the branding is
        // decorative, the fact is "Generating image, In progress".
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ImageGenerationCopy.accessibilityLabel)
        .accessibilityValue(ImageGenerationCopy.accessibilityValue)
        .accessibilityIdentifier("fleet.conversation.imagegen.activity.\(identifier)")
        .task(id: animates) { startMotionIfNeeded() }
    }

    /// The wing medallion: the FleetWingMark asset, with a halo that pings
    /// and a gentle breathe/rock while motion is allowed. The still variant
    /// keeps the identical composition (same medallion, same ring) so there
    /// is no layout change between motion modes.
    private var medallion: some View {
        ZStack {
            Circle()
                .strokeBorder(theme.highlight.opacity(pulsing ? 0 : 0.55), lineWidth: 1.5)
                .frame(width: 40, height: 40)
                .scaleEffect(pulsing ? 1.35 : 0.95)
            Image("FleetWingMark", bundle: .module)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .scaleEffect(pulsing ? 1.05 : 0.97)
                .rotationEffect(.degrees(pulsing ? 4 : -4))
                .accessibilityHidden(true)
        }
        .frame(width: 56, height: 56)
    }

    private func startMotionIfNeeded() {
        guard animates else {
            pulsing = false
            return
        }
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }
}
