import SwiftUI

/// Named timing constants for the launch splash.
///
/// iOS dismisses the native `LaunchScreen` as soon as the app's first frame
/// is ready. The in-app splash continues the same mark past that point and
/// holds it for `minimumDisplayDuration` before cross-fading into the app UI.
enum SplashConfiguration {
    /// Minimum wall-clock time the splash mark stays on screen before the
    /// cross-fade into the app UI begins.
    static let minimumDisplayDuration: TimeInterval = 1.8

    /// Duration of the cross-fade from the splash into the app UI.
    static let fadeOutDuration: TimeInterval = 0.35

    /// DEBUG-only test seam. A UI test can extend the hold with
    /// `HERMES_FLEET_SPLASH_HOLD` so a slow simulator has time to attach its
    /// first accessibility query before the splash fades.
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

/// In-app continuation of the launch screen. The mark is centered on the
/// system background, held for the minimum display duration, then faded out
/// without animating layout.
struct SplashOverlayView: View {
    @State private var isVisible = true
    @State private var isRemoved = false

    var body: some View {
        ZStack {
            if !isRemoved {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()
                Image("FleetWingMark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    // The mark PNG already carries its transparent corner mask.
                    // Opacity is the only animated property, so layout remains
                    // stable from the first rendered frame.
                    .opacity(isVisible ? 1 : 0)
                    .task {
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
        .ignoresSafeArea()
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
