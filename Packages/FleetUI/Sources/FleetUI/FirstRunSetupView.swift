import SwiftUI
import FleetCore

/// Root wrapper for the unconfigured first-run state (see
/// `AppEnvironment.hydrationPhase`). First-run enrollment starts from an
/// owner-issued, one-use QR invitation; address and credential setup remain
/// available only through Advanced Gateway setup.
public struct FirstRunSetupView: View {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        QRFirstServerView(pairing: environment.pairing)
            .accessibilityIdentifier("fleet.root.onboarding")
    }
}
