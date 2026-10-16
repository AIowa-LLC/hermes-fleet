import SwiftUI
import FleetCore

/// Root wrapper for the unconfigured first-run state (see
/// `AppEnvironment.hydrationPhase`). First-run enrollment starts from a link the owner asks
/// Hermes for (`/fleet pair`), approved by its code; owner sign-in and manual setup remain
/// available under "Other ways to connect".
public struct FirstRunSetupView: View {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        QRFirstServerView(environment: environment)
            .accessibilityIdentifier("fleet.root.onboarding")
    }
}
