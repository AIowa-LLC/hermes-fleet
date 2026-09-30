import XCTest
import LocalAuthentication
import FleetCore
@testable import HermesFleetApp

@MainActor
final class PresencePlatformTests: XCTestCase {
    func testUnknownAndInvalidContextErrorsDoNotStartPasscodeFallback() {
        for error in [NSError(domain: LAError.errorDomain, code: LAError.invalidContext.rawValue),
                      NSError(domain: LAError.errorDomain, code: LAError.notInteractive.rawValue),
                      NSError(domain: "SyntheticError", code: 1)] {
            XCTAssertEqual(LocalAuthenticationBiometricAuth.outcome(for: error, policy: .biometricsOnly), .failed)
        }
        XCTAssertEqual(LocalAuthenticationBiometricAuth.outcome(for: nil, policy: .biometricsOnly), .failed)
    }

    func testKnownLocalAuthenticationErrorsMapToExplicitOutcomes() {
        let errors: [(LAError.Code, PresenceOutcome)] = [
            (.userCancel, .cancelled), (.appCancel, .cancelled), (.systemCancel, .cancelled),
            (.authenticationFailed, .failed), (.passcodeNotSet, .passcodeNotSet),
            (.userFallback, .biometricsUnavailable), (.biometryLockout, .biometricsUnavailable),
            (.biometryNotAvailable, .biometricsUnavailable), (.biometryNotEnrolled, .biometricsUnavailable),
        ]
        for (code, expected) in errors {
            XCTAssertEqual(LocalAuthenticationBiometricAuth.outcome(
                for: NSError(domain: LAError.errorDomain, code: code.rawValue), policy: .biometricsOnly), expected)
        }
    }

    func testProductionProviderOnSimulatorWithoutAvailableBiometrics() async throws {
        #if targetEnvironment(simulator)
        let auth = LocalAuthenticationBiometricAuth()
        try XCTSkipIf(auth.canEvaluateBiometrics(), "This environmental check requires unavailable biometrics")
        let outcome = await auth.evaluate(policy: .biometricsOnly, reason: "Verify test presence")
        XCTAssertTrue([PresenceOutcome.biometricsUnavailable, .passcodeNotSet].contains(outcome))
        #else
        throw XCTSkip("Environmental unavailable-biometrics check runs on its dedicated simulator")
        #endif
    }
}
