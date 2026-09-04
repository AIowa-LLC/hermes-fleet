import XCTest
import FleetCore
import FleetUI
@testable import HermesFleetApp

/// R9-T1/R9-T2/R9-T3 — approval flow: banner state machine, FaceID-gated
/// approve / friction-free deny, `approval.respond` param shapes, and the
/// per-session YOLO toggle (config.set yolo scope=session, confirmed on
/// enable, honest per-session copy).
@MainActor
final class ApprovalFlowTests: XCTestCase {

    // MARK: - Scripted approvals seam

    private final class ScriptedApprovals: ApprovalsProviding, @unchecked Sendable {
        struct RespondCall: Equatable {
            let sessionID: String
            let requestID: String
            let choice: ApprovalChoice
            let all: Bool
        }
        private let lock = NSLock()
        private var _respondCalls: [RespondCall] = []
        var respondCalls: [RespondCall] {
            lock.lock(); defer { lock.unlock() }
            return _respondCalls
        }
        var respondResult: Result<Int, Error> = .success(1)

        private var _yoloCalls: [(enabled: Bool, sessionID: String)] = []
        var yoloCalls: [(enabled: Bool, sessionID: String)] {
            lock.lock(); defer { lock.unlock() }
            return _yoloCalls
        }
        var yoloResult: Result<Bool, Error> = .success(true)

        // Sync recorders (NSLock is unavailable from async contexts).
        private func recordRespond(
            _ sessionID: String, _ requestID: String, _ choice: ApprovalChoice, _ all: Bool
        ) {
            lock.lock(); defer { lock.unlock() }
            _respondCalls.append(.init(sessionID: sessionID, requestID: requestID, choice: choice, all: all))
        }
        private func recordYolo(_ enabled: Bool, _ sessionID: String) {
            lock.lock(); defer { lock.unlock() }
            _yoloCalls.append((enabled, sessionID))
        }

        func respond(sessionID: String, requestID: String, choice: ApprovalChoice, all: Bool) async throws -> Int {
            recordRespond(sessionID, requestID, choice, all)
            return try respondResult.get()
        }

        func setSessionYolo(_ enabled: Bool, sessionID: String) async throws -> Bool {
            recordYolo(enabled, sessionID)
            // Echo the requested state on success (the failure case is what
            // the scripted error exercises).
            return try yoloResult.map { _ in enabled }.get()
        }
    }

    /// Scripted biometric seam: denies by default (the banner must NOT send
    /// approval without explicit biometric success).
    private struct ScriptedBiometrics: AppLockBiometricAuth {
        let result: AppLockAuthResult
        func canEvaluateBiometrics() -> Bool { result != .unavailable }
        func evaluateBiometrics(reason: String) async -> AppLockAuthResult { result }
        func evaluateDevicePasscode(reason: String) async -> Bool { false }
    }

    private let request = ApprovalRequest(
        requestID: "req-1",
        sessionID: "s-1",
        command: "curl -H 'Authorization: Bearer sk-live-abc123' https://api",
        detail: "HTTP request",
        choices: ["once", "session", "always", "deny"]
    )

    private func makeViewModel(
        biometrics: AppLockAuthResult = .failure,
        yolo: Bool? = nil
    ) -> (ScriptedApprovals, ApprovalViewModel) {
        let approvals = ScriptedApprovals()
        let vm = ApprovalViewModel(
            approvals: approvals,
            biometrics: ScriptedBiometrics(result: biometrics),
            initialYolo: yolo
        )
        // YOLO rides the open session (config.set yolo scope=session).
        vm.bind(sessionID: "s-1")
        return (approvals, vm)
    }

    // MARK: - Banner state

    func testPushedApprovalSurfacesPendingBannerState() {
        let (_, vm) = makeViewModel()
        XCTAssertNil(vm.pending, "no approval pending initially")
        vm.handleApprovalRequest(request)
        XCTAssertEqual(vm.pending?.requestID, "req-1")
        XCTAssertEqual(vm.state, .pending)
        // The banner preview is the CLIENT-redacted command (second pass) —
        // the bearer token never renders.
        XCTAssertEqual(
            vm.pending?.command,
            "curl -H 'Authorization: Bearer [REDACTED]' https://api"
        )
        XCTAssertFalse(vm.pending!.command.contains("sk-live-abc123"))
    }

    func testApprovalClearedByResolution() {
        let (_, vm) = makeViewModel()
        vm.handleApprovalRequest(request)
        vm.clearApproval(requestID: "req-1")
        XCTAssertNil(vm.pending)
        XCTAssertEqual(vm.state, .idle)
    }

    // MARK: - Deny: friction-free (no biometrics)

    func testDenySendsRespondWithoutBiometrics() async {
        let (approvals, vm) = makeViewModel(biometrics: .failure)
        vm.handleApprovalRequest(request)

        await vm.deny()

        XCTAssertEqual(approvals.respondCalls.count, 1)
        XCTAssertEqual(approvals.respondCalls.first?.choice, .deny)
        XCTAssertEqual(approvals.respondCalls.first?.requestID, "req-1")
        XCTAssertEqual(approvals.respondCalls.first?.sessionID, "s-1")
        XCTAssertFalse(approvals.respondCalls.first?.all ?? true)
        XCTAssertNil(vm.pending, "deny clears the banner")
    }

    // MARK: - Approve: biometric-gated

    func testApproveRequiresBiometricSuccess() async {
        let (approvals, vm) = makeViewModel(biometrics: .success)
        vm.handleApprovalRequest(request)

        await vm.approve(scope: .once)

        XCTAssertEqual(approvals.respondCalls.count, 1)
        XCTAssertEqual(approvals.respondCalls.first?.choice, .once)
        XCTAssertNil(vm.pending)
    }

    func testApproveBlockedWhenBiometricsFail() async {
        let (approvals, vm) = makeViewModel(biometrics: .failure)
        vm.handleApprovalRequest(request)

        await vm.approve(scope: .once)

        XCTAssertTrue(approvals.respondCalls.isEmpty,
                      "approve must NEVER reach the wire without biometric success")
        XCTAssertNotNil(vm.pending, "the banner stays up — the command stays blocked")
        XCTAssertEqual(vm.state, .biometricFailed)
    }

    func testApproveBlockedWhenBiometricsUnavailable() async {
        let (approvals, vm) = makeViewModel(biometrics: .unavailable)
        vm.handleApprovalRequest(request)

        await vm.approve(scope: .once)

        XCTAssertTrue(approvals.respondCalls.isEmpty)
        XCTAssertEqual(vm.state, .biometricUnavailable)
    }

    // MARK: - Respond failure keeps the banner honest

    func testRespondFailureSurfacesErrorAndKeepsBanner() async {
        let approvals = ScriptedApprovals()
        approvals.respondResult = .failure(ConversationError.notConnected)
        let vm = ApprovalViewModel(
            approvals: approvals,
            biometrics: ScriptedBiometrics(result: .success),
            initialYolo: nil
        )
        vm.handleApprovalRequest(request)

        await vm.deny()

        XCTAssertNotNil(vm.pending, "a failed deny keeps the banner (never silently drop)")
        XCTAssertEqual(vm.state, .respondFailed("gateway not connected"))
    }

    // MARK: - YOLO toggle

    func testYoloEnableRequiresConfirmationBeforeWire() async {
        let (approvals, vm) = makeViewModel(yolo: false)
        XCTAssertFalse(vm.isYoloEnabled)

        // First tap only asks for confirmation — nothing on the wire yet.
        vm.requestYoloEnable()
        XCTAssertEqual(vm.state, .confirmYolo)
        XCTAssertTrue(approvals.yoloCalls.isEmpty)

        // Cancel keeps YOLO off, nothing sent.
        vm.cancelYoloConfirmation()
        XCTAssertFalse(vm.isYoloEnabled)
        XCTAssertTrue(approvals.yoloCalls.isEmpty)

        // Confirm sends the session-scoped enable.
        await vm.confirmYoloEnable()
        XCTAssertEqual(approvals.yoloCalls.count, 1)
        XCTAssertEqual(approvals.yoloCalls.first?.enabled, true)
        XCTAssertTrue(vm.isYoloEnabled)
    }

    func testYoloDisableIsImmediateNoConfirmation() async {
        let (approvals, vm) = makeViewModel(yolo: true)
        XCTAssertTrue(vm.isYoloEnabled)

        await vm.disableYolo()

        XCTAssertEqual(approvals.yoloCalls.count, 1)
        XCTAssertEqual(approvals.yoloCalls.first?.enabled, false)
        XCTAssertFalse(vm.isYoloEnabled)
    }

    func testYoloStateAdoptsSessionInfoReadback() {
        let (_, vm) = makeViewModel(yolo: false)
        vm.applySessionInfo(yolo: true, approvalMode: "manual")
        XCTAssertTrue(vm.isYoloEnabled, "session.info yolo=true is the effective readback")
        vm.applySessionInfo(yolo: false, approvalMode: "manual")
        XCTAssertFalse(vm.isYoloEnabled)
    }

    // MARK: - Session routing

    func testApprovalForOtherSessionIsIgnored() {
        let (_, vm) = makeViewModel()
        vm.bind(sessionID: "s-1")
        let other = ApprovalRequest(
            requestID: "req-2", sessionID: "s-OTHER",
            command: "rm -rf /x", detail: nil, choices: ["once", "deny"]
        )
        vm.handleApprovalRequest(other)
        XCTAssertNil(vm.pending, "another session's approval must not hijack this screen")
    }
}
