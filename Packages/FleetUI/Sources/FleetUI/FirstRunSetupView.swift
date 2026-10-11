import SwiftUI
import FleetCore

/// Root wrapper for the unconfigured first-run state (see
/// `AppEnvironment.hydrationPhase`).
///
/// Deliberately thin: the owner-enrollment experience is
/// `GatewayOnboardingView`; this wrapper gives the root a stable accessibility
/// identifier for UI tests and keeps hydration-gate logic in `FleetTabView`.
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
