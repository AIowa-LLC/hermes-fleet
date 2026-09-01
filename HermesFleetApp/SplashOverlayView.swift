import SwiftUI

/// Named timing constants for the launch splash (Tony's artwork).
///
/// iOS dismisses the native `LaunchScreen` as soon as the app's first frame
/// is ready, which made the artwork "tear away" almost instantly (P0-1
/// dogfood defect). The in-app splash continues the same artwork past that
/// point and holds it for `minimumDisplayDuration` before cross-fading into
/// the app UI — a guaranteed minimum window, never an artificial delay after
/// the app is interactive.
enum SplashConfiguration {
    /// Minimum wall-clock time the splash artwork stays on screen before the
    /// cross-fade into the app UI begins. Kept as a named constant so the
    /// product window is tunable in one place (and covered by a unit test).
    static let minimumDisplayDuration: TimeInterval = 1.8

    /// Duration of the cross-fade from the splash into the app UI.
    static let fadeOutDuration: TimeInterval = 0.35

    /// DEBUG-only test seam: a UI test can extend the hold via
    /// `HERMES_FLEET_SPLASH_HOLD` (seconds) so a slow CI simulator has time to
    /// attach its first accessibility query before the splash fades. Defaults
    /// to `minimumDisplayDuration` in every configuration; the unit test keeps
    /// the product default locked at 1.5-2.0s.
    static var effectiveMinimumDisplayDuration: TimeInterval {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["HERMES_FLEET_SPLASH_HOLD"],
           let seconds = Double(raw), seconds > 0 {
            return seconds
        }
        #endif
        return minimumDisplayDuration
    }
}

/// In-app splash that seamlessly continues the native launch screen (same
/// `LaunchArtwork` image, same dark background) so the artwork registers,
/// holds for the minimum display duration, then cross-fades into the app.
struct SplashOverlayView: View {
    @State private var isVisible = true
    @State private var isRemoved = false

    var body: some View {
        ZStack {
            if !isRemoved {
                // P0-6: the splash must be geometrically IDENTICAL to the
                // native LaunchScreen at the handoff frame, or the artwork
                // visibly jumps when the system launch screen is dismissed
                // (the dogfooded "jitter"). Both layers now use the same
                // recipe: full-bleed dark background + aspect-FIT artwork
                // centered on the FULL screen. aspectFit (not fill) because
                // the artwork is ~9:16 (941x1672) — on a ~19.5:9 phone a
                // fill crops ~18% of its width. The artwork's edges are
                // near-black, so the letterbox bars are imperceptible against
                // the matching background.
                Color(red: 10 / 255, green: 10 / 255, blue: 11 / 255)
                    .ignoresSafeArea()
                Image("LaunchArtwork")
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
                    // Opacity only — never animate layout, so the frame is
                    // identical from the very first rendered pass.
                    .opacity(isVisible ? 1 : 0)
                    .task {
                        // Hold for the minimum display window, then cross-fade
                        // out and drop the splash from the hierarchy so it no
                        // longer blocks interaction.
                        try? await Task.sleep(for: .seconds(SplashConfiguration.effectiveMinimumDisplayDuration))
                        withAnimation(.easeOut(duration: SplashConfiguration.fadeOutDuration)) {
                            isVisible = false
                        }
                        try? await Task.sleep(for: .seconds(SplashConfiguration.fadeOutDuration))
                        isRemoved = true
                    }
                    .accessibilityIdentifier("fleet.splash.artwork")
                    .accessibilityLabel("Splash")
            }
        }
        // Full-screen container from the first frame: both the background and
        // the aspect-fit image center on the FULL screen — exactly the native
        // LaunchScreen's geometry (imageView pinned to all four superview
        // edges, scaleAspectFit) — with no safe-area-dependent re-layout.
        .ignoresSafeArea()
    }

    /// Whether the in-app splash should be presented in this run.
    ///
    /// Release/TestFlight: always (this is the fix Tony dogfooded against).
    /// DEBUG: presented normally, but SKIPPED automatically when running under
    /// XCUITest (unless a test opts in with `HERMES_FLEET_SPLASH=on`) so the
    /// existing deterministic UI suites aren't slowed by the minimum window.
    /// `SplashUITests` opts in to exercise the real splash + fade.
    static var isEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let forced = env["HERMES_FLEET_SPLASH"] {
            return forced == "on" || forced == "1"
        }
        // Under XCUITest, `XCTestConfigurationFilePath` is injected into the
        // app process; skip the splash so existing suites stay deterministic.
        return env["XCTestConfigurationFilePath"] == nil
        #else
        return true
        #endif
    }
}
