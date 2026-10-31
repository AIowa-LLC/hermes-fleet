import SwiftUI

/// Named timing constants for the launch splash.
///
/// iOS dismisses the native `LaunchScreen` as soon as the app's first frame
/// is ready. The in-app splash continues the same mark — identical size,
/// position, and backdrop, so there is no layout jump at the handoff — plays
/// a short branded moment, then cross-fades into the app UI.
///
/// Refinement Phase 1: the 1.8s static hold is retired. Total time from the
/// first in-app frame to usable UI is `minimumDisplayDuration +
/// fadeOutDuration` (~0.75s; ~0.6s under Reduce Motion).
enum SplashConfiguration {
    /// Time the mark's motion plays before the cross-fade begins.
    static let minimumDisplayDuration: TimeInterval = 0.45

    /// Reduce Motion: no scale, just a short hold before the fade.
    static let reduceMotionDisplayDuration: TimeInterval = 0.3

    /// Duration of the cross-fade from the splash into the app UI.
    static let fadeOutDuration: TimeInterval = 0.3

    /// Side of the mark in points. Must equal the native `LaunchScreen`
    /// storyboard's image constraints (100×100) so the handoff never jumps.
    static let markSide: CGFloat = 100

    /// Peak scale of the mark's settle (subtle; never a bounce).
    static let settleScale: CGFloat = 1.08

    /// Scale the mark lifts to while the splash fades away.
    static let liftScale: CGFloat = 1.16

    /// Total time from the first in-app frame to usable UI.
    static func totalDuration(reduceMotion: Bool) -> TimeInterval {
        (reduceMotion ? reduceMotionDisplayDuration : minimumDisplayDuration) + fadeOutDuration
    }

    /// DEBUG-only test seam. A UI test can extend the hold with
    /// `HERMES_FLEET_SPLASH_HOLD` so a slow simulator has time to attach its
    /// first accessibility query before the splash fades.
    static func effectiveDisplayDuration(reduceMotion: Bool) -> TimeInterval {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["HERMES_FLEET_SPLASH_HOLD"],
           let seconds = Double(raw), seconds > 0 {
            return seconds
        }
        #endif
        return reduceMotion ? reduceMotionDisplayDuration : minimumDisplayDuration
    }
}

/// In-app continuation of the launch screen. The first frame is pixel-matched
/// to the native `LaunchScreen` (100pt mark centered on the theme canvas); the mark then settles with a subtle scale and the whole
/// overlay lifts and fades into the app. Only scale and opacity animate, so
/// layout is stable from the first frame. Reduce Motion: no scale — a short
/// hold and a plain fade.
struct SplashOverlayView: View {
    @State private var settled = false
    @State private var isVisible = true
    @State private var isRemoved = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fleetTheme) private var theme

    var body: some View {
        ZStack {
            if !isRemoved {
                // The theme canvas — the same values as the storyboard's
                // `LaunchCanvas` color — so native → splash → app is one
                // continuous surface in both appearances.
                theme.background.ignoresSafeArea()
                Image("FleetWingMark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: SplashConfiguration.markSide, height: SplashConfiguration.markSide)
                    // The mark PNG already carries its transparent corner mask.
                    .scaleEffect(markScale)
                    .accessibilityIdentifier("fleet.splash.artwork")
                    .accessibilityLabel("Splash")
            }
        }
        .opacity(isVisible ? 1 : 0)
        .ignoresSafeArea()
        .allowsHitTesting(isVisible)
        .task {
            if !reduceMotion {
                withAnimation(.spring(duration: SplashConfiguration.minimumDisplayDuration, bounce: 0)) {
                    settled = true
                }
            }
            try? await Task.sleep(for: .seconds(
                SplashConfiguration.effectiveDisplayDuration(reduceMotion: reduceMotion)))
            withAnimation(.easeOut(duration: SplashConfiguration.fadeOutDuration)) {
                isVisible = false
            }
            try? await Task.sleep(for: .seconds(SplashConfiguration.fadeOutDuration))
            isRemoved = true
        }
    }

    private var markScale: CGFloat {
        guard !reduceMotion else { return 1 }
        if !isVisible { return SplashConfiguration.liftScale }
        return settled ? SplashConfiguration.settleScale : 1
    }

    /// Whether the in-app splash should be presented in this run.
    ///
    /// Production builds always present it. DEBUG builds present it normally
    /// but skip it under XCUITest unless the test opts in with
    /// `HERMES_FLEET_SPLASH=on`.
    static var isEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let forced = env["HERMES_FLEET_SPLASH"] {
            return forced == "on" || forced == "1"
        }
        return env["XCTestConfigurationFilePath"] == nil
        #else
        return true
        #endif
    }
}
