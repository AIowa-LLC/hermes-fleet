import XCTest
import os
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
@testable import FleetUI
@testable import HermesFleetApp

/// The v2 (owner approval) half of Add to Fleet: the coordinator's state machine from a pinned
/// link through request, polling, approval, denial, expiry, cancel, lifecycle and lost
/// responses. Synthetic data only; the wire protocol is covered against real TLS servers in
/// FleetNetworking's tests.
@MainActor
final class PairingApprovalFlowTests: XCTestCase {
    private let instance = String(repeating: "ab12cd34", count: 4)
    private let secret = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"
    private let id = "AbCdEfGhIjKlMnOpQrStUv"
    private let origin = URL(string: "https://fleet.example.test")!
    private var pin: String { PairingInvitationLink.base64URLEncode(Data(repeating: 7, count: 32)) }
    private var linkText: String { "https://fleet.example.test/pair#v=2&i=\(id)&s=\(secret)&k=\(pin)" }

    // MARK: Doubles

    private final class Service: GatewayPairing, @unchecked Sendable {
        struct State {
            var previews = 0
            var redeems = 0
            var requestSecrets: [String] = []
            var pollSecrets: [String] = []
            var revokes: [String] = []
            var previewResult: Result<PairingPreview, PairingFailure>
            var requestResults: [Result<PairingApprovalRequest, PairingFailure>]
            var pollResults: [Result<PairingApprovalStatus, PairingFailure>] = [.success(.pending)]
            var sleeps: [TimeInterval] = []
        }
        let state: OSAllocatedUnfairLock<State>

        init(preview: PairingPreview, request: PairingApprovalRequest) {
            state = OSAllocatedUnfairLock(initialState: State(
                previewResult: .success(preview), requestResults: [.success(request)]))
        }
        var snapshot: State { state.withLock { $0 } }
        func set(_ change: @Sendable (inout State) -> Void) { state.withLock { change(&$0) } }

        func preview(_ link: PairingInvitationLink) async throws(PairingFailure) -> PairingPreview {
            try state.withLock { s -> Result<PairingPreview, PairingFailure> in
                s.previews += 1
                return s.previewResult
            }.get()
        }
        func redeem(_ link: PairingInvitationLink, deviceName: String, expecting: PairingPreview) async throws(PairingFailure) -> PairingGrant {
            state.withLock { $0.redeems += 1 }
            throw .approvalRequired
        }
        func revoke(origin: URL, credential: PairingDeviceCredential, expecting: SPKIFingerprint?) async -> PairingRevocationOutcome {
            state.withLock { $0.revokes.append(credential.rawValue) }
            return .revoked
        }
        func requestApproval(
            _ link: PairingInvitationLink, deviceName: String, deviceModel: String,
            clientSecret: PairingClientSecret, expecting: PairingPreview
        ) async throws(PairingFailure) -> PairingApprovalRequest {
            try state.withLock { s -> Result<PairingApprovalRequest, PairingFailure> in
                s.requestSecrets.append(clientSecret.rawValue)
                return s.requestResults.count > 1 ? s.requestResults.removeFirst() : s.requestResults[0]
            }.get()
        }
        func pollApproval(_ request: PairingApprovalRequest, clientSecret: PairingClientSecret) async throws(PairingFailure) -> PairingApprovalStatus {
            try state.withLock { s -> Result<PairingApprovalStatus, PairingFailure> in
                s.pollSecrets.append(clientSecret.rawValue)
                return s.pollResults.count > 1 ? s.pollResults.removeFirst() : s.pollResults[0]
            }.get()
        }
    }

    @MainActor
    private final class Host: PairingHosting {
        var existing: FleetGateway?
        var addError: Error?
        var added: [PairingGrant] = []
        var revokedUnsaved: [PairingGrant] = []
        var pairingDeviceName: String { "Test iPhone" }
        var pairingDeviceModel: String { "iPhone17,1" }
        func existingGateway(forPairedInstance instanceID: String, origin: URL) -> FleetGateway? { existing }
        func addPairedGateway(_ grant: PairingGrant) async throws -> FleetGateway {
            if let addError { throw addError }
            added.append(grant)
            return FleetGateway(id: GatewayID(pairedInstanceID: grant.gateway.instanceID)!,
                                displayName: grant.gateway.displayName, endpoint: grant.gateway.origin)
        }
        func revokeUnsavedDevice(_ grant: PairingGrant) async -> PairingRevocationOutcome {
            revokedUnsaved.append(grant)
            return .revoked
        }
    }

    private func fingerprint(_ byte: UInt8 = 7) -> SPKIFingerprint {
        SPKIFingerprint(sha256Digest: Data(repeating: byte, count: 32))!
    }

    private func gatewayIdentity() -> PairingGatewayIdentity {
        PairingGatewayIdentity(instanceID: instance, displayName: "Fleet Host", origin: origin)
    }

    private func makePreview() -> PairingPreview {
        PairingPreview(
            gateway: gatewayIdentity(), label: "phone",
            access: [PairingAccess(scope: "fleet:operator", summary: PairingScope.fleetOperator.summary)],
            expiresAt: Date().addingTimeInterval(600), tlsFingerprint: fingerprint(),
            approvalRequired: true, protocols: [1, 2])
    }

    private func makeRequest(expiresIn: TimeInterval = 600, pollInterval: TimeInterval = 2) -> PairingApprovalRequest {
        PairingApprovalRequest(
            id: "req_0123456789abcdef", matchCode: "482913",
            expiresAt: Date().addingTimeInterval(expiresIn), pollInterval: pollInterval,
            gateway: gatewayIdentity(), scopes: ["fleet:operator"], tlsFingerprint: fingerprint())
    }

    private func makeGrant() -> PairingGrant {
        PairingGrant(
            gateway: gatewayIdentity(), deviceID: String(repeating: "0123abcd", count: 4),
            credential: PairingDeviceCredential("hfd1." + String(repeating: "0123abcd", count: 4) + "." + String(repeating: "S", count: 43)),
            tlsFingerprint: fingerprint())
    }

    private func make(
        service: Service? = nil, now: @escaping @Sendable () -> Date = { Date() }
    ) -> (PairingCoordinator, Service, Host) {
        let service = service ?? Service(preview: makePreview(), request: makeRequest())
        let coordinator = PairingCoordinator(service: service, now: now, sleep: { seconds in
            service.set { $0.sleeps.append(seconds) }
            try? await Task.sleep(for: .milliseconds(3))
        })
        coordinator.appURLScheme = "hermes-fleet-dev"
        let host = Host()
        coordinator.attach(host: host)
        return (coordinator, service, host)
    }

    /// Wait (bounded) for `condition`.
    private func wait(_ coordinator: PairingCoordinator, _ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func reachAwaiting(_ coordinator: PairingCoordinator) async {
        coordinator.receive(text: linkText)
        await wait(coordinator) { if case .confirming = coordinator.phase { return true }; return false }
        coordinator.confirm()
        await wait(coordinator) { if case .awaitingApproval = coordinator.phase { return true }; return false }
    }

    // MARK: Happy path

    func testApprovalFlowSavesTheGrantExactlyLikeV1() async throws {
        let (coordinator, service, host) = make()
        let grant = makeGrant()
        service.set { $0.pollResults = [.success(.pending), .success(.pending), .success(.approved(grant))] }

        coordinator.receive(text: linkText)
        await wait(coordinator) { if case .confirming = coordinator.phase { return true }; return false }
        guard case .confirming(let preview) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertTrue(preview.approvalRequired)
        XCTAssertEqual(service.snapshot.requestSecrets.count, 0, "previewing sends nothing that creates a request")

        coordinator.confirm()
        XCTAssertEqual(coordinator.phase, .requesting(preview))
        await wait(coordinator) { if case .awaitingApproval = coordinator.phase { return true }; return false }
        guard case .awaitingApproval(let code, let expiresAt) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertEqual(code, "482913")
        XCTAssertGreaterThan(expiresAt, Date())
        XCTAssertTrue(coordinator.canCancel)
        XCTAssertEqual(coordinator.pendingRequest?.gateway.displayName, "Fleet Host")

        await wait(coordinator) { if case .completed = coordinator.phase { return true }; return false }
        XCTAssertEqual(coordinator.phase, .completed(name: "Fleet Host"))
        XCTAssertEqual(host.added, [makeGrant()], "the approved credential goes through the same save path")
        XCTAssertEqual(service.snapshot.redeems, 0, "a v2 link never redeems directly")
        XCTAssertTrue(host.revokedUnsaved.isEmpty)
        XCTAssertNil(coordinator.pendingRequest)

        let snapshot = service.snapshot
        let clientSecret = try XCTUnwrap(snapshot.requestSecrets.first)
        XCTAssertEqual(clientSecret.count, 43)
        XCTAssertEqual(snapshot.pollSecrets.count, 3)
        XCTAssertTrue(snapshot.pollSecrets.allSatisfy { $0 == clientSecret }, "every poll presents the same client secret")
    }

    func testEachPairingSessionUsesAFreshClientSecret() async {
        var secrets: [String] = []
        for _ in 0..<2 {
            let (coordinator, service, _) = make()
            await reachAwaiting(coordinator)
            secrets.append(service.snapshot.requestSecrets[0])
            coordinator.cancel()
        }
        XCTAssertNotEqual(secrets[0], secrets[1])
    }

    func testPollsNoFasterThanOncePerSecondAndHonourTheGatewaysPace() async {
        let service = Service(preview: makePreview(), request: makeRequest(pollInterval: 0.2))
        let (coordinator, _, _) = make(service: service)
        await reachAwaiting(coordinator)
        await wait(coordinator) { service.snapshot.sleeps.count >= 2 }
        coordinator.cancel()
        XCTAssertTrue(service.snapshot.sleeps.allSatisfy { $0 >= 1 }, "\(service.snapshot.sleeps)")

        let slow = Service(preview: makePreview(), request: makeRequest(pollInterval: 3))
        let (second, _, _) = make(service: slow)
        await reachAwaiting(second)
        await wait(second) { slow.snapshot.sleeps.count >= 2 }
        second.cancel()
        XCTAssertEqual(slow.snapshot.sleeps.first, 3)
    }

    // MARK: Terminal outcomes

    func testDenialEndsTheFlowAndStopsPolling() async {
        let (coordinator, service, host) = make()
        service.set { $0.pollResults = [.success(.pending), .success(.denied)] }
        await reachAwaiting(coordinator)
        await wait(coordinator) { coordinator.phase == .denied }
        XCTAssertEqual(coordinator.phase, .denied)
        XCTAssertFalse(coordinator.isPolling)
        let polls = service.snapshot.pollSecrets.count
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(service.snapshot.pollSecrets.count, polls, "no polling after the owner denied")
        XCTAssertTrue(host.added.isEmpty)
        XCTAssertNil(coordinator.pendingRequest)
    }

    func testServerReportedExpiryEndsTheFlow() async {
        let (coordinator, service, host) = make()
        service.set { $0.pollResults = [.success(.expired)] }
        await reachAwaiting(coordinator)
        await wait(coordinator) { coordinator.phase == .expired }
        XCTAssertEqual(coordinator.phase, .expired)
        XCTAssertTrue(host.added.isEmpty)
    }

    func testLocalClockExpiryEndsTheFlowWithoutAnotherPoll() async {
        let clock = OSAllocatedUnfairLock(initialState: Date())
        let service = Service(preview: makePreview(), request: makeRequest(expiresIn: 600))
        let (coordinator, _, _) = make(service: service, now: { clock.withLock { $0 } })
        await reachAwaiting(coordinator)
        let before = service.snapshot.pollSecrets.count
        clock.withLock { $0 = Date().addingTimeInterval(3600) }
        await wait(coordinator) { coordinator.phase == .expired }
        XCTAssertEqual(coordinator.phase, .expired)
        XCTAssertLessThanOrEqual(service.snapshot.pollSecrets.count, before + 1)
    }

    func testDeliveredWithoutACredentialIsAFailureNotASuccess() async {
        let (coordinator, service, host) = make()
        service.set { $0.pollResults = [.success(.delivered)] }
        await reachAwaiting(coordinator)
        await wait(coordinator) { if case .failed = coordinator.phase { return true }; return false }
        XCTAssertEqual(coordinator.phase, .failed(.alreadyUsed, host: "fleet.example.test"))
        XCTAssertTrue(host.added.isEmpty)
    }

    // MARK: Cancel

    func testCancelWhileWaitingStopsPollingAndForgetsEverything() async {
        let (coordinator, service, _) = make()
        await reachAwaiting(coordinator)
        await wait(coordinator) { service.snapshot.pollSecrets.count >= 1 }
        coordinator.cancel()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(coordinator.isPolling)
        XCTAssertNil(coordinator.pendingRequest)
        let polls = service.snapshot.pollSecrets.count
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(service.snapshot.pollSecrets.count, polls)
    }

    // MARK: Errors

    func testTransientPollErrorsBackOffToFiveSecondsThenRecover() async {
        let (coordinator, service, host) = make()
        let grant = makeGrant()
        service.set { $0.pollResults = [.failure(.unreachable), .failure(.rateLimited), .success(.approved(grant))] }
        await reachAwaiting(coordinator)
        await wait(coordinator) { if case .completed = coordinator.phase { return true }; return false }
        XCTAssertEqual(host.added.count, 1)
        let sleeps = service.snapshot.sleeps
        XCTAssertEqual(sleeps.first, 2)
        XCTAssertEqual(Array(sleeps.dropFirst().prefix(2)), [5, 5], "after a transient error the pace is five seconds")
    }

    func testAnInvalidRequestEndsTheFlowAsAFailure() async {
        let (coordinator, service, _) = make()
        service.set { $0.pollResults = [.failure(.invalidRequest)] }
        await reachAwaiting(coordinator)
        await wait(coordinator) { if case .failed = coordinator.phase { return true }; return false }
        XCTAssertEqual(coordinator.phase, .failed(.invalidRequest, host: "fleet.example.test"))
        XCTAssertFalse(coordinator.isPolling)
    }

    func testAChangedServerKeyDuringPollingEndsTheFlow() async {
        let (coordinator, service, host) = make()
        service.set { $0.pollResults = [.failure(.identityMismatch)] }
        await reachAwaiting(coordinator)
        await wait(coordinator) { if case .failed = coordinator.phase { return true }; return false }
        XCTAssertEqual(coordinator.phase, .failed(.identityMismatch, host: "fleet.example.test"))
        XCTAssertTrue(host.added.isEmpty)
        XCTAssertEqual(coordinator.diagnosis?.kind, .pinMismatch)
    }

    func testSavingAfterApprovalFailsSafelyAndRevokesTheDevice() async {
        let (coordinator, service, host) = make()
        let grant = makeGrant()
        service.set { $0.pollResults = [.success(.approved(grant))] }
        host.addError = PairingFailure.couldNotSave
        await reachAwaiting(coordinator)
        await wait(coordinator) { if case .failed = coordinator.phase { return true }; return false }
        XCTAssertEqual(coordinator.phase, .failed(.couldNotSave, host: "fleet.example.test"))
        XCTAssertEqual(host.revokedUnsaved, [makeGrant()], "a credential that cannot be saved is revoked")
        XCTAssertTrue(host.added.isEmpty)
    }

    func testLostRequestResponseRetriesWithTheSameClientSecretAndNoSecondPreview() async {
        let service = Service(preview: makePreview(), request: makeRequest())
        let request = makeRequest()
        service.set { $0.requestResults = [.failure(.interrupted), .success(request)] }
        let (coordinator, _, _) = make(service: service)
        coordinator.receive(text: linkText)
        await wait(coordinator) { if case .confirming = coordinator.phase { return true }; return false }
        coordinator.confirm()
        await wait(coordinator) { if case .failed = coordinator.phase { return true }; return false }
        XCTAssertEqual(coordinator.phase, .failed(.interrupted, host: "fleet.example.test"))
        XCTAssertTrue(coordinator.canRetry)

        coordinator.retry()
        await wait(coordinator) { if case .awaitingApproval = coordinator.phase { return true }; return false }
        let secrets = service.snapshot.requestSecrets
        XCTAssertEqual(secrets.count, 2)
        XCTAssertEqual(secrets[0], secrets[1], "the lost response is recovered with the same client secret")
        XCTAssertEqual(service.snapshot.previews, 1, "the consumed invitation is not previewed again")
        coordinator.cancel()
    }

    // MARK: Lifecycle

    func testBackgroundingPausesAWaitingApprovalAndForegroundResumesItWithTheSameSecret() async {
        let (coordinator, service, _) = make()
        await reachAwaiting(coordinator)
        await wait(coordinator) { service.snapshot.pollSecrets.count >= 1 }

        coordinator.appMovedToBackground()
        guard case .awaitingApproval = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertFalse(coordinator.isPolling)
        let paused = service.snapshot.pollSecrets.count
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertLessThanOrEqual(service.snapshot.pollSecrets.count, paused + 1, "no polling while backgrounded")

        coordinator.appBecameActive()
        XCTAssertTrue(coordinator.isPolling)
        await wait(coordinator) { service.snapshot.pollSecrets.count > paused + 1 }
        XCTAssertEqual(Set(service.snapshot.pollSecrets).count, 1)
        coordinator.cancel()
    }

    func testResumingAfterTheRequestExpiredReportsExpiry() async {
        let clock = OSAllocatedUnfairLock(initialState: Date())
        let (coordinator, _, _) = make(now: { clock.withLock { $0 } })
        await reachAwaiting(coordinator)
        coordinator.appMovedToBackground()
        clock.withLock { $0 = Date().addingTimeInterval(3600) }
        coordinator.appBecameActive()
        XCTAssertEqual(coordinator.phase, .expired)
    }

    func testBackgroundingStillDropsAnUnconfirmedInvitation() async {
        let (coordinator, _, _) = make()
        coordinator.receive(text: linkText)
        await wait(coordinator) { if case .confirming = coordinator.phase { return true }; return false }
        coordinator.appMovedToBackground()
        XCTAssertEqual(coordinator.phase, .idle)
    }

    // MARK: Intake and already-added servers

    func testAnAlreadyAddedServerIsDetectedBeforeAnyRequestIsCreated() async {
        let (coordinator, service, host) = make()
        host.existing = FleetGateway(id: GatewayID(pairedInstanceID: instance)!, displayName: "Fleet Host", endpoint: origin)
        coordinator.receive(text: linkText)
        await wait(coordinator) { coordinator.phase == .alreadyAdded(name: "Fleet Host") }
        XCTAssertEqual(coordinator.phase, .alreadyAdded(name: "Fleet Host"))
        XCTAssertTrue(service.snapshot.requestSecrets.isEmpty)
        XCTAssertEqual(service.snapshot.redeems, 0)
    }

    func testTheAppSchemeFormStartsTheSameFlow() async throws {
        let (coordinator, service, _) = make()
        let origin64 = PairingInvitationLink.base64URLEncode(Data("https://fleet.example.test".utf8))
        let url = try XCTUnwrap(URL(string: "hermes-fleet-dev://pair#v=2&i=\(id)&s=\(secret)&k=\(pin)&o=\(origin64)"))
        XCTAssertTrue(coordinator.receive(url: url))
        XCTAssertEqual(coordinator.entry, .link)
        await wait(coordinator) { if case .confirming = coordinator.phase { return true }; return false }
        XCTAssertEqual(service.snapshot.previews, 1)
        // Conversation links on the same scheme are not taken.
        coordinator.cancel()
        XCTAssertFalse(coordinator.receive(url: try XCTUnwrap(URL(string: "hermes-fleet-dev://conversation?gateway=a"))))
    }

    func testTheAppSchemeFormIsIgnoredWithoutAConfiguredScheme() throws {
        let coordinator = PairingCoordinator(service: Service(preview: makePreview(), request: makeRequest()))
        let url = try XCTUnwrap(URL(string: "hermes-fleet-dev://pair#v=2&i=\(id)&s=\(secret)&k=\(pin)&o=aHR0cHM6Ly9mbGVldC5leGFtcGxlLnRlc3Q"))
        XCTAssertFalse(coordinator.receive(url: url))
    }

    func testTheSameLinkDeliveredTwiceDoesNotRestartAWaitingRequest() async {
        let (coordinator, service, _) = make()
        await reachAwaiting(coordinator)
        coordinator.receive(text: linkText)
        XCTAssertEqual(service.snapshot.previews, 1)
        XCTAssertEqual(service.snapshot.requestSecrets.count, 1)
        coordinator.cancel()
    }

    // MARK: Diagnosis

    func testNetworkAndTrustFailuresOnAPinnedLinkOfferTryAgain() async {
        let cases: [(PairingFailure, PairingDiagnosis.Kind)] = [
            (.hostNotFound, .dns), (.timedOut, .noAnswer), (.connectionRefused, .noAnswer),
            (.offline, .offline), (.untrustedCertificate, .untrustedWithoutPin), (.identityMismatch, .pinMismatch),
        ]
        for (failure, kind) in cases {
            let service = Service(preview: makePreview(), request: makeRequest())
            service.set { $0.previewResult = .failure(failure) }
            let (coordinator, _, _) = make(service: service)
            coordinator.receive(text: linkText)
            await wait(coordinator) { if case .failed = coordinator.phase { return true }; return false }
            XCTAssertEqual(coordinator.diagnosis?.kind, kind, "\(failure)")
            XCTAssertTrue(coordinator.canRetry, "\(failure)")
            XCTAssertEqual(coordinator.diagnosis?.actionTitle, "Try again")
        }
    }

    func testRetryAfterADNSFailureUsesTheTailnetSentenceForTsNetHosts() async {
        let service = Service(preview: makePreview(), request: makeRequest())
        service.set { $0.previewResult = .failure(.hostNotFound) }
        let (coordinator, _, _) = make(service: service)
        coordinator.receive(text: "https://studio.tail1234.ts.net/pair#v=2&i=\(id)&s=\(secret)&k=\(pin)")
        await wait(coordinator) { if case .failed = coordinator.phase { return true }; return false }
        XCTAssertEqual(coordinator.diagnosis?.kind, .tailscaleDNS)
        let preview = makePreview()
        service.set { $0.previewResult = .success(preview) }
        coordinator.retry()
        await wait(coordinator) { if case .confirming = coordinator.phase { return true }; return false }
        guard case .confirming = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
    }

    func testV1LinksKeepTheirOrdinaryCertificateHandling() async {
        let service = Service(preview: makePreview(), request: makeRequest())
        service.set { $0.previewResult = .failure(.untrustedCertificate) }
        let (coordinator, _, _) = make(service: service)
        coordinator.receive(text: "https://fleet.example.test/pair#v=1&i=\(id)&s=\(secret)")
        await wait(coordinator) { if case .failed = coordinator.phase { return true }; return false }
        XCTAssertNil(coordinator.diagnosis)
        XCTAssertFalse(coordinator.canRetry, "a v1 link without a pin gains no retry for certificate failures")
    }

    func testCopyForNewFailureCasesIsNeverEmptyOrLeaksAnything() {
        let all: [PairingFailure] = [.hostNotFound, .timedOut, .connectionRefused, .offline,
                                     .approvalNotSupported, .approvalRequired, .invalidRequest]
        for failure in all {
            XCTAssertFalse(PairingCopy.title(for: failure).isEmpty, "\(failure)")
            let message = PairingCopy.message(for: failure, host: "fleet.example.test", linkIsPinned: true)
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains(secret))
        }
    }
}
