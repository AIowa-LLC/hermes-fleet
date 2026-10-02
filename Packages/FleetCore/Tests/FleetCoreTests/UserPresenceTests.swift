import XCTest
@testable import FleetCore

/// P0.2b — gate decision logic with a scripted evaluator.
final class UserPresenceTests: XCTestCase {

    private final class StubEvaluator: PresenceEvaluating, @unchecked Sendable {
        private let lock = NSLock()
        private let biometrics: PresenceOutcome
        private let passcode: PresenceOutcome
        private var recorded: [(PresencePolicy, String)] = []

        init(biometrics: PresenceOutcome, passcode: PresenceOutcome = .failed) {
            self.biometrics = biometrics
            self.passcode = passcode
        }

        func evaluate(policy: PresencePolicy, reason: String) async -> PresenceOutcome {
            record(policy, reason)
            return policy == .biometricsOnly ? biometrics : passcode
        }

        private func record(_ policy: PresencePolicy, _ reason: String) {
            lock.withLock { recorded.append((policy, reason)) }
        }

        var calls: [(PresencePolicy, String)] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }
        var policies: [PresencePolicy] { calls.map(\.0) }
    }

    private func verify(
        biometrics: PresenceOutcome,
        passcode: PresenceOutcome = .failed,
        action: PresenceAction = .approveOnce
    ) async -> (PresenceResult, StubEvaluator) {
        let stub = StubEvaluator(biometrics: biometrics, passcode: passcode)
        let result = await UserPresenceGate(evaluator: stub).verify(action)
        return (result, stub)
    }

    func testBiometricSuccessVerifiesWithoutPasscode() async {
        let (result, stub) = await verify(biometrics: .success)
        XCTAssertEqual(result, .verified)
        XCTAssertEqual(stub.policies, [.biometricsOnly])
    }

    func testBiometricFailureStaysBlockedWithoutPasscode() async {
        let (result, stub) = await verify(biometrics: .failed, passcode: .success)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(stub.policies, [.biometricsOnly])
    }

    func testBiometricCancelDoesNotFallBack() async {
        let (result, stub) = await verify(biometrics: .cancelled, passcode: .success)
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(stub.policies, [.biometricsOnly])
    }

    func testUnavailableThenPasscodeSuccess() async {
        let (result, stub) = await verify(biometrics: .biometricsUnavailable, passcode: .success)
        XCTAssertEqual(result, .verified)
        XCTAssertEqual(stub.policies, [.biometricsOnly, .deviceOwner])
    }

    func testLockoutThenPasscodeSuccess() async {
        // Lockout is reported by the platform seam as `.biometricsUnavailable`.
        let (result, stub) = await verify(biometrics: .biometricsUnavailable, passcode: .success,
                                          action: .enableYolo)
        XCTAssertEqual(result, .verified)
        XCTAssertEqual(stub.calls.count, 2)
    }

    func testPasscodeCancelIsCancelled() async {
        let (result, stub) = await verify(biometrics: .biometricsUnavailable, passcode: .cancelled)
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(stub.policies, [.biometricsOnly, .deviceOwner])
    }

    func testPasscodeFailureFails() async {
        let (result, _) = await verify(biometrics: .biometricsUnavailable, passcode: .failed)
        XCTAssertEqual(result, .failed)
    }

    func testNoPasscodeAtAllFailsClosedWithGuidanceResult() async {
        let (fromBiometrics, first) = await verify(biometrics: .passcodeNotSet)
        XCTAssertEqual(fromBiometrics, .passcodeNotSet)
        XCTAssertEqual(first.policies, [.biometricsOnly])

        let (fromPasscode, second) = await verify(biometrics: .biometricsUnavailable, passcode: .passcodeNotSet)
        XCTAssertEqual(fromPasscode, .passcodeNotSet)
        XCTAssertEqual(second.policies, [.biometricsOnly, .deviceOwner])
    }

    func testEachActionUsesItsOwnSpecificReason() async {
        let expectations: [(PresenceAction, String)] = [
            (.enableYolo, "Enable YOLO for this session"),
            (.approveAlways, "Save an always-allow rule"),
            (.turnOffAppLock, "Turn off App Lock"),
        ]
        for (action, reason) in expectations {
            let (_, stub) = await verify(biometrics: .success, action: action)
            XCTAssertEqual(stub.calls.first?.1, reason)
        }
        let all: [PresenceAction] = [.approveOnce, .approveForSession, .approveAlways,
                                     .enableYolo, .turnOffAppLock, .enterSudoPassword, .enterSecret]
        XCTAssertEqual(Set(all.map(\.localizedReason)).count, all.count)
    }

    func testDenyHasNoPresenceAction() {
        XCTAssertNil(PresenceAction(approvalChoice: .deny))
        XCTAssertEqual(PresenceAction(approvalChoice: .once), .approveOnce)
        XCTAssertEqual(PresenceAction(approvalChoice: .session), .approveForSession)
        XCTAssertEqual(PresenceAction(approvalChoice: .always), .approveAlways)
    }
}
