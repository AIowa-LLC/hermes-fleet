import SwiftUI
import FleetCore

/// Root wrapper for the unconfigured first-run state (see
/// `AppEnvironment.hydrationPhase`).
///
/// Deliberately thin: the experience is `GatewayOnboardingView`; this wrapper
/// gives the root a single stable accessibility identifier
/// (`fleet.root.onboarding`) for UI tests and keeps the hydration-gate
/// presentation logic in `FleetTabView` free of product copy.
public struct FirstRunSetupView: View {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        GatewayOnboardingView(environment: environment)
            .accessibilityIdentifier("fleet.root.onboarding")
    }
}
