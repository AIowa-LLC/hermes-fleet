import XCTest
import os
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
@testable import FleetUI
@testable import HermesFleetApp

/// Add to Fleet at the app level: the coordinator's state machine (what is and is not allowed to
/// happen before the person confirms), and `AppEnvironment` as the host that registers what was
/// paired, detects duplicates, undoes a failed save, and revokes the device when a gateway is
/// removed. Synthetic fixtures only: the real wire protocol is covered against genuine TLS
/// servers in FleetNetworking's tests.
@MainActor
final class PairingFlowTests: XCTestCase {
    private let instance = String(repeating: "ab12cd34", count: 4)
    private let secret = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"
    private let id = "AbCdEfGhIjKlMnOpQrStUv"
    private var linkText: String { "https://gateway.example.test/pair#v=1&i=\(id)&s=\(secret)" }
    private var origin: URL { URL(string: "https://gateway.example.test")! }

    // MARK: Doubles

    /// Scripted pairing service. Records what was asked; each step can be failed or held.
    private final class ScriptedPairing: GatewayPairing, @unchecked Sendable {
        struct State {
            var previews = 0
            var redeems = 0
            var revokes: [String] = []
            var previewResult: Result<PairingPreview, PairingFailure>
            var redeemResult: Result<PairingGrant, PairingFailure>
            var revokeOutcome: PairingRevocationOutcome = .revoked
            var previewGate: Gate?
        }
        let state: OSAllocatedUnfairLock<State>

        init(preview: PairingPreview, grant: PairingGrant) {
            state = OSAllocatedUnfairLock(initialState: State(
                previewResult: .success(preview), redeemResult: .success(grant)))
        }
        var snapshot: State { state.withLock { $0 } }
        func set(_ change: @Sendable (inout State) -> Void) { state.withLock { change(&$0) } }

        func preview(_ link: PairingInvitationLink) async throws(PairingFailure) -> PairingPreview {
            let gate = state.withLock { s -> Gate? in s.previews += 1; return s.previewGate }
            if let gate { await gate.wait() }
            return try state.withLock { $0.previewResult }.get()
        }
        func redeem(
            _ link: PairingInvitationLink, deviceName: String, expecting: PairingPreview
        ) async throws(PairingFailure) -> PairingGrant {
            state.withLock { $0.redeems += 1 }
            return try state.withLock { $0.redeemResult }.get()
        }
        func revoke(origin: URL, credential: PairingDeviceCredential) async -> PairingRevocationOutcome {
            state.withLock {
                $0.revokes.append(credential.rawValue)
                return $0.revokeOutcome
            }
        }
    }

    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var entered = 0
        func wait() async {
            entered += 1
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
        func waitUntilEntered() async -> Bool {
            for _ in 0..<400 {
                if entered > 0 { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
    }

    /// Records host calls; behaviours are switchable.
    @MainActor
    private final class RecordingHost: PairingHosting {
        var existing: FleetGateway?
        var addError: Error?
        var added: [PairingGrant] = []
        var revokedUnsaved: [PairingGrant] = []
        var pairingDeviceName: String { "Test iPhone" }
        func existingGateway(forPairedInstance instanceID: String, origin: URL) -> FleetGateway? { existing }
        func addPairedGateway(_ grant: PairingGrant) async throws -> FleetGateway {
            if let addError { throw addError }
            added.append(grant)
            return FleetGateway(id: GatewayID(pairedInstanceID: grant.gateway.instanceID)!,
                                displayName: grant.gateway.displayName, endpoint: grant.gateway.origin)
        }
        func revokeUnsavedDevice(_ grant: PairingGrant) async { revokedUnsaved.append(grant) }
    }

    private func fingerprint(_ byte: UInt8 = 7) -> SPKIFingerprint {
        SPKIFingerprint(sha256Digest: Data(repeating: byte, count: 32))!
    }

    private func gatewayIdentity(name: String = "Home Gateway") -> PairingGatewayIdentity {
        PairingGatewayIdentity(instanceID: instance, displayName: name, origin: origin)
    }

    private func makePreview(expiresIn: TimeInterval = 600) -> PairingPreview {
        PairingPreview(
            gateway: gatewayIdentity(), label: "Tony's phone",
            access: [PairingAccess(scope: "fleet:operator", summary: PairingScope.fleetOperator.summary)],
            expiresAt: Date().addingTimeInterval(expiresIn), tlsFingerprint: fingerprint())
    }

    private func makeGrant() -> PairingGrant {
        PairingGrant(
            gateway: gatewayIdentity(), deviceID: String(repeating: "0123abcd", count: 4),
            credential: PairingDeviceCredential("hfd1." + String(repeating: "0123abcd", count: 4) + "." + String(repeating: "S", count: 43)),
            tlsFingerprint: fingerprint())
    }

    private func makeCoordinator(
        service: ScriptedPairing? = nil
    ) -> (PairingCoordinator, ScriptedPairing, RecordingHost) {
        let scripted = service ?? ScriptedPairing(preview: makePreview(), grant: makeGrant())
        let coordinator = PairingCoordinator(service: scripted)
        let host = RecordingHost()
        coordinator.attach(host: host)
        return (coordinator, scripted, host)
    }

    /// Wait for the flow to leave a transient phase.
    private func settle(_ coordinator: PairingCoordinator) async {
        for _ in 0..<500 {
            switch coordinator.phase {
            case .previewing, .redeeming: try? await Task.sleep(for: .milliseconds(10))
            default: return
            }
        }
    }

    // MARK: Intake / validation

    func testNonPairingURLsAreNotTaken() {
        let (coordinator, service, _) = makeCoordinator()
        XCTAssertFalse(coordinator.receive(url: URL(string: "hermes-fleet://conversation/abc")!))
        XCTAssertFalse(coordinator.receive(url: URL(string: "https://gateway.example.test/other")!))
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(service.snapshot.previews, 0)
    }

    func testMalformedAndInsecureLinksFailClearlyWithoutAnyNetworkCall() async {
        let cases: [(String, PairingFailure)] = [
            ("https://gateway.example.test/pair#v=1&i=short&s=short", .malformedLink),
            ("not a link", .malformedLink),
            ("http://gateway.example.test/pair#v=1&i=\(id)&s=\(secret)", .insecureDestination),
            ("https://127.0.0.1/pair#v=1&i=\(id)&s=\(secret)", .insecureDestination),
            ("https://gateway.example.test/pair#v=2&i=\(id)&s=\(secret)", .unsupportedLinkVersion),
        ]
        for (text, expected) in cases {
            let (coordinator, service, _) = makeCoordinator()
            coordinator.receive(text: text)
            XCTAssertEqual(coordinator.phase, .failed(expected, host: nil), text)
            XCTAssertEqual(service.snapshot.previews, 0, "no network call for \(text)")
            XCTAssertEqual(service.snapshot.redeems, 0)
        }
    }

    func testABuildWithoutPairingReportsItHonestly() {
        let coordinator = PairingCoordinator(service: nil)
        XCTAssertFalse(coordinator.isAvailable)
        coordinator.receive(text: linkText)
        XCTAssertEqual(coordinator.phase, .failed(.pairingUnavailable, host: nil))
    }

    // MARK: Opening a link consumes nothing

    func testOpeningALinkPreviewsOnceAndNeverRedeemsUntilThePersonConfirms() async throws {
        let (coordinator, service, host) = makeCoordinator()
        XCTAssertTrue(coordinator.receive(url: try XCTUnwrap(URL(string: linkText))))
        XCTAssertEqual(coordinator.entry, .link)
        XCTAssertEqual(coordinator.phase, .previewing(host: "gateway.example.test"))
        await settle(coordinator)

        guard case .confirming(let preview) = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertEqual(preview.gateway.displayName, "Home Gateway")
        XCTAssertEqual(service.snapshot.previews, 1)
        XCTAssertEqual(service.snapshot.redeems, 0, "previewing must not consume the invitation")
        XCTAssertTrue(host.added.isEmpty, "nothing is added before confirmation")

        // Time passing on the confirmation screen changes nothing either.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(service.snapshot.redeems, 0)
    }

    func testCancelBeforeConfirmLeavesTheInvitationUntouchedAndDropsTheLink() async {
        let (coordinator, service, host) = makeCoordinator()
        coordinator.receive(text: linkText)
        await settle(coordinator)
        coordinator.cancel()

        XCTAssertEqual(coordinator.phase, .idle)
        coordinator.confirm()                       // nothing to confirm any more
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(service.snapshot.redeems, 0)
        XCTAssertTrue(host.added.isEmpty)
    }

    func testConfirmOnlyActsFromTheConfirmingState() async {
        let (coordinator, service, _) = makeCoordinator()
        coordinator.confirm()                                   // idle
        coordinator.receive(text: linkText)
        coordinator.confirm()                                   // still previewing
        await settle(coordinator)
        XCTAssertEqual(service.snapshot.redeems, 0)
    }

    func testTheSameLinkDeliveredTwiceStartsOneFlow() async {
        let (coordinator, service, _) = makeCoordinator()
        coordinator.receive(url: URL(string: linkText)!)
        coordinator.receive(url: URL(string: linkText)!)        // e.g. open-URL AND user-activity callbacks
        await settle(coordinator)
        XCTAssertEqual(service.snapshot.previews, 1)
    }

    // MARK: Confirm → add

    func testConfirmRedeemsOnceAndAddsTheGateway() async {
        let (coordinator, service, host) = makeCoordinator()
        coordinator.receive(text: linkText)
        await settle(coordinator)
        coordinator.confirm()
        XCTAssertTrue({ if case .redeeming = coordinator.phase { return true } else { return false } }())
        XCTAssertFalse(coordinator.canCancel, "a redemption in flight cannot be backed out of")
        await settle(coordinator)

        XCTAssertEqual(coordinator.phase, .completed(name: "Home Gateway"))
        XCTAssertEqual(service.snapshot.redeems, 1)
        XCTAssertEqual(host.added.count, 1)
        XCTAssertTrue(host.revokedUnsaved.isEmpty)
    }

    func testCancelAndDismissAreIgnoredWhileRedeeming() async {
        let service = ScriptedPairing(preview: makePreview(), grant: makeGrant())
        let (coordinator, _, host) = makeCoordinator(service: service)
        coordinator.receive(text: linkText)
        await settle(coordinator)
        coordinator.confirm()
        coordinator.cancel()
        coordinator.dismiss()
        await settle(coordinator)
        XCTAssertEqual(coordinator.phase, .completed(name: "Home Gateway"))
        XCTAssertEqual(host.added.count, 1)
    }

    func testAGatewayAlreadyInFleetIsDetectedBeforeAnythingIsConsumed() async {
        let (coordinator, service, host) = makeCoordinator()
        host.existing = FleetGateway(
            id: GatewayID(pairedInstanceID: instance)!, displayName: "Already Here", endpoint: origin)
        coordinator.receive(text: linkText)
        await settle(coordinator)

        XCTAssertEqual(coordinator.phase, .alreadyAdded(name: "Already Here"))
        XCTAssertEqual(service.snapshot.redeems, 0, "a duplicate must not consume the invitation")
        XCTAssertTrue(host.added.isEmpty)
    }

    func testAnExpiredPreviewIsRefusedWithoutRedeeming() async {
        let service = ScriptedPairing(preview: makePreview(expiresIn: -5), grant: makeGrant())
        let (coordinator, _, _) = makeCoordinator(service: service)
        coordinator.receive(text: linkText)
        await settle(coordinator)
        XCTAssertEqual(coordinator.phase, .failed(.expired, host: "gateway.example.test"))
        XCTAssertEqual(service.snapshot.redeems, 0)
    }

    func testAnInvitationThatExpiresWhileTheConfirmScreenIsOpenIsNotRedeemed() async {
        let service = ScriptedPairing(preview: makePreview(expiresIn: 600), grant: makeGrant())
        let clock = OSAllocatedUnfairLock(initialState: Date())
        let coordinator = PairingCoordinator(service: service, now: { clock.withLock { $0 } })
        coordinator.attach(host: RecordingHost())
        coordinator.receive(text: linkText)
        await settle(coordinator)
        clock.withLock { $0 = $0.addingTimeInterval(601) }
        coordinator.confirm()
        XCTAssertEqual(coordinator.phase, .failed(.expired, host: "gateway.example.test"))
        XCTAssertEqual(service.snapshot.redeems, 0)
    }

    // MARK: Failures

    func testEachGatewayRefusalSurfacesAsItsOwnSpecificFailure() async {
        for failure: PairingFailure in [.expired, .alreadyUsed, .cancelled, .invalidInvitation, .rateLimited,
                                         .pairingUnavailable, .untrustedCertificate, .identityMismatch] {
            let service = ScriptedPairing(preview: makePreview(), grant: makeGrant())
            service.set { $0.previewResult = .failure(failure) }
            let (coordinator, _, _) = makeCoordinator(service: service)
            coordinator.receive(text: linkText)
            await settle(coordinator)
            XCTAssertEqual(coordinator.phase, .failed(failure, host: "gateway.example.test"), "\(failure)")
            XCTAssertFalse(PairingCopy.title(for: failure).isEmpty)
            XCTAssertFalse(PairingCopy.message(for: failure, host: "gateway.example.test").isEmpty)
        }
    }

    func testAnOfflinePhoneCanRetryTheSameLinkAndExplainsAboutReachability() async {
        let service = ScriptedPairing(preview: makePreview(), grant: makeGrant())
        service.set { $0.previewResult = .failure(.unreachable) }
        let (coordinator, _, _) = makeCoordinator(service: service)
        coordinator.receive(text: linkText)
        await settle(coordinator)
        XCTAssertEqual(coordinator.phase, .failed(.unreachable, host: "gateway.example.test"))
        XCTAssertTrue(PairingCopy.message(for: .unreachable, host: "gateway.example.test")
            .contains("doesn't create a network path"))

        let backOnline = makePreview()
        service.set { $0.previewResult = .success(backOnline) }      // back online
        coordinator.retry()
        await settle(coordinator)
        guard case .confirming = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertEqual(service.snapshot.previews, 2)
        XCTAssertEqual(service.snapshot.redeems, 0)
    }

    func testANonRetryableFailureDropsTheLinkSoRetryDoesNothing() async {
        let service = ScriptedPairing(preview: makePreview(), grant: makeGrant())
        service.set { $0.previewResult = .failure(.expired) }
        let (coordinator, _, _) = makeCoordinator(service: service)
        coordinator.receive(text: linkText)
        await settle(coordinator)
        coordinator.retry()
        XCTAssertEqual(coordinator.phase, .failed(.expired, host: "gateway.example.test"))
        XCTAssertEqual(service.snapshot.previews, 1)
    }

    func testARedemptionRefusalIsReportedAndNothingIsAdded() async {
        let service = ScriptedPairing(preview: makePreview(), grant: makeGrant())
        service.set { $0.redeemResult = .failure(.alreadyUsed) }
        let (coordinator, _, host) = makeCoordinator(service: service)
        coordinator.receive(text: linkText)
        await settle(coordinator)
        coordinator.confirm()
        await settle(coordinator)
        XCTAssertEqual(coordinator.phase, .failed(.alreadyUsed, host: "gateway.example.test"))
        XCTAssertTrue(host.added.isEmpty)
    }

    func testACredentialThatCannotBeSavedIsRevokedAndNothingIsAdded() async {
        let (coordinator, _, host) = makeCoordinator()
        host.addError = GatewayRegistryError.credentialStoreFailed("scripted")
        coordinator.receive(text: linkText)
        await settle(coordinator)
        coordinator.confirm()
        await settle(coordinator)

        XCTAssertEqual(coordinator.phase, .failed(.couldNotSave, host: "gateway.example.test"))
        XCTAssertEqual(host.revokedUnsaved.count, 1, "the just-issued device must be revoked on the gateway")
        XCTAssertTrue(host.added.isEmpty)
    }

    func testANewLinkWhileConfirmingReplacesTheOldFlowAndStaleResultsAreIgnored() async throws {
        let service = ScriptedPairing(preview: makePreview(), grant: makeGrant())
        let gate = Gate()
        service.set { $0.previewGate = gate }
        let (coordinator, _, _) = makeCoordinator(service: service)
        coordinator.receive(text: linkText)                              // first flow parks in preview
        let parked = await gate.waitUntilEntered()
        XCTAssertTrue(parked)

        let other = "https://other.example.test/pair#v=1&i=ZzYyXxWwVvUuTtSsRrQqPp&s=\(secret)"
        coordinator.receive(text: other)                                 // replaces it
        XCTAssertEqual(coordinator.phase, .previewing(host: "other.example.test"))
        service.set { $0.previewGate = nil }
        await gate.release()                                             // the first preview now answers
        await settle(coordinator)
        guard case .confirming = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertEqual(service.snapshot.redeems, 0)
    }

    // MARK: Presentation policy

    func testLinkFlowPresentationWaitsForUnlockAndHydration() {
        let (coordinator, _, _) = makeCoordinator()
        coordinator.receive(url: URL(string: linkText)!)       // as the system delivers a Universal Link
        XCTAssertTrue(coordinator.isActive)
        XCTAssertEqual(coordinator.entry, .link)
        // The root presenter requires readiness AND a link-entry flow; manual entry is the
        // Add Gateway form's own sheet.
        XCTAssertTrue(PairingPresentationPolicy.shouldPresentAtRoot(isReady: true, entry: .link, isActive: true))
        XCTAssertFalse(PairingPresentationPolicy.shouldPresentAtRoot(isReady: false, entry: .link, isActive: true),
                       "a link opened while locked or hydrating waits")
        XCTAssertFalse(PairingPresentationPolicy.shouldPresentAtRoot(isReady: true, entry: .manual, isActive: true))
        XCTAssertFalse(PairingPresentationPolicy.shouldPresentAtRoot(isReady: true, entry: .link, isActive: false))
    }

    func testALinkThatArrivesBeforeTheAppIsReadyIsHeldNotLost() async {
        // Cold launch: the URL is delivered while the registry is still loading / the app is locked.
        let (coordinator, service, _) = makeCoordinator()
        coordinator.receive(url: URL(string: linkText)!)
        await settle(coordinator)
        guard case .confirming = coordinator.phase else { return XCTFail("\(coordinator.phase)") }
        XCTAssertTrue(coordinator.isActive, "the flow is waiting for the root to present it")
        XCTAssertEqual(service.snapshot.redeems, 0)
    }

    // MARK: Redaction

    func testNothingTheCoordinatorExposesContainsTheSecret() async {
        let (coordinator, _, _) = makeCoordinator()
        coordinator.receive(text: linkText)
        await settle(coordinator)
        for text in ["\(coordinator.phase)", String(reflecting: coordinator.phase),
                     PairingCopy.message(for: .invalidInvitation, host: "gateway.example.test")] {
            XCTAssertFalse(text.contains(secret), text)
            XCTAssertFalse(text.contains(id), text)
        }
    }
}

// MARK: - AppEnvironment as pairing host

@MainActor
final class PairingHostTests: XCTestCase {
    private let instance = String(repeating: "ab12cd34", count: 4)
    private var origin: URL { URL(string: "https://gateway.example.test")! }

    private struct Connection: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        var status: GatewayStatus { .offline }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway { FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil) }
    }
    private struct Roster: GatewayRosterSession {
        let gatewayID: GatewayID
        var status: GatewayStatus { .offline }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway { FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil) }
        func fetchProfiles() async throws -> [ProfileDescriptor] { [] }
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }
    private struct Sessions: SessionListProviding {
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }
    private struct Health: ConnectionHealthAccumulating {
        func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
        func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
        func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
        func rehydrate(gatewayIDs: [GatewayID]) async {}
        func forget(gatewayID: GatewayID) async {}
    }
    /// Credential store that can refuse writes.
    private final class Credentials: CredentialStoring, @unchecked Sendable {
        let inner = InMemoryCredentialStore()
        let failSaves = OSAllocatedUnfairLock(initialState: false)
        func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {
            if failSaves.withLock({ $0 }) { throw NSError(domain: "scripted.keychain", code: -34018) }
            try await inner.saveCredential(credential, for: gatewayID)
        }
        func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? {
            try await inner.loadCredential(for: gatewayID)
        }
        func deleteCredential(for gatewayID: GatewayID) async throws { try await inner.deleteCredential(for: gatewayID) }
    }
    private final class Revoker: GatewayPairing, @unchecked Sendable {
        let calls = OSAllocatedUnfairLock(initialState: [(URL, String)]())
        let outcome = OSAllocatedUnfairLock(initialState: PairingRevocationOutcome.revoked)
        /// When set, preview/redeem succeed for this gateway identity (the real exchange is not under test here).
        let identity = OSAllocatedUnfairLock<PairingGatewayIdentity?>(initialState: nil)
        private let fp = SPKIFingerprint(sha256Digest: Data(repeating: 9, count: 32))!
        func preview(_ link: PairingInvitationLink) async throws(PairingFailure) -> PairingPreview {
            guard let identity = identity.withLock({ $0 }) else { throw .pairingUnavailable }
            return PairingPreview(gateway: identity, label: "x",
                access: [PairingAccess(scope: "fleet:operator", summary: PairingScope.fleetOperator.summary)],
                expiresAt: Date().addingTimeInterval(600), tlsFingerprint: fp)
        }
        func redeem(_ link: PairingInvitationLink, deviceName: String, expecting: PairingPreview) async throws(PairingFailure) -> PairingGrant {
            guard identity.withLock({ $0 }) != nil else { throw .pairingUnavailable }
            return PairingGrant(gateway: expecting.gateway, deviceID: String(repeating: "0123abcd", count: 4),
                credential: PairingDeviceCredential("hfd1." + String(repeating: "0123abcd", count: 4) + "." + String(repeating: "S", count: 43)),
                tlsFingerprint: fp)
        }
        func revoke(origin: URL, credential: PairingDeviceCredential) async -> PairingRevocationOutcome {
            calls.withLock { $0.append((origin, credential.rawValue)) }
            return outcome.withLock { $0 }
        }
    }

    private struct Harness {
        let environment: AppEnvironment
        let credentials: Credentials
        let pins: InMemoryPinStore
        let revoker: Revoker
    }

    private func makeHarness(existing: [GatewayRegistration] = []) async -> Harness {
        let credentials = Credentials()
        let pins = InMemoryPinStore()
        let revoker = Revoker()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in Connection(gatewayID: gateway.id) },
            pinStore: pins)
        let environment = AppEnvironment(
            registry: registry,
            roster: FleetRosterService(registry: registry, credentials: credentials,
                                       sessionFactory: { gateway, _ in Roster(gatewayID: gateway.id) }),
            cache: try! SwiftDataCacheStore.makeInMemory(),
            tlsPinStore: pins, tlsApprovalStore: pins,
            sessionList: Sessions(),
            connectionFactory: { gateway, _ in Connection(gatewayID: gateway.id) },
            health: Health(),
            pairingService: revoker)
        environment.attachContinueIndex(FleetContinueIndexStore(url: tempURL()))
        environment.attachArtifactLibrary(FleetArtifactLibrary(url: tempURL()))
        environment.attachConversationDrafts(ConversationDraftStore(url: tempURL()))
        for registration in existing { _ = try? await environment.addGateway(registration) }
        await environment.load()
        return Harness(environment: environment, credentials: credentials, pins: pins, revoker: revoker)
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fleet-pairing-\(UUID().uuidString).json")
    }

    private func grant(instance: String? = nil, credential: String? = nil) -> PairingGrant {
        let instanceID = instance ?? self.instance
        return PairingGrant(
            gateway: PairingGatewayIdentity(instanceID: instanceID, displayName: "Home Gateway", origin: origin),
            deviceID: String(repeating: "0123abcd", count: 4),
            credential: PairingDeviceCredential(credential ?? "hfd1." + String(repeating: "0123abcd", count: 4) + "." + String(repeating: "S", count: 43)),
            tlsFingerprint: SPKIFingerprint(sha256Digest: Data(repeating: 9, count: 32))!)
    }

    // MARK: adding

    func testPairedGatewayIsRegisteredWithItsStableIdentityAndKeychainCredential() async throws {
        let harness = await makeHarness()
        let added = try await harness.environment.addPairedGateway(grant())

        XCTAssertEqual(added.id, GatewayID(pairedInstanceID: instance))
        XCTAssertEqual(added.endpoint, origin)
        XCTAssertEqual(added.authConfiguration.strategy, .deviceCredential)
        XCTAssertEqual(harness.environment.gateways.map(\.id), [added.id])
        let stored = try await harness.credentials.loadCredential(for: added.id)
        XCTAssertEqual(stored?.rawValue, grant().credential.rawValue)
        XCTAssertNil(stored?.username)
        let hasCredential = await harness.environment.hasCredential(for: added.id)
        XCTAssertTrue(hasCredential)
        // The key validated during pairing is the key approved for pinning.
        let approved = try harness.pins.syncConsumeFirstUseApproval(matching: grant().tlsFingerprint, for: added.id)
        XCTAssertTrue(approved, "first-use approval must be bound to the validated key")
    }

    func testSameInstanceOrSameAddressIsADuplicate() async throws {
        let manual = GatewayRegistration(displayName: "By Hand", endpoint: origin)
        let harness = await makeHarness(existing: [manual])
        // Same address, added by hand.
        XCTAssertEqual(harness.environment.existingGateway(forPairedInstance: instance, origin: origin)?.displayName,
                       "By Hand")
        // Different address, but the stable identity is already paired.
        let other = await makeHarness()
        _ = try await other.environment.addPairedGateway(grant())
        XCTAssertNotNil(other.environment.existingGateway(
            forPairedInstance: instance, origin: URL(string: "https://elsewhere.example.test")!))
        // A different gateway is not.
        XCTAssertNil(other.environment.existingGateway(
            forPairedInstance: String(repeating: "ef56ab78", count: 4), origin: URL(string: "https://third.example.test")!))
    }

    func testAddingAnAlreadyPairedInstanceNeverTouchesTheExistingGateway() async throws {
        let harness = await makeHarness()
        let first = try await harness.environment.addPairedGateway(grant())
        do {
            _ = try await harness.environment.addPairedGateway(grant(credential: "hfd1.other." + String(repeating: "T", count: 43)))
            XCTFail("a duplicate must be refused")
        } catch let error as GatewayRegistryError {
            XCTAssertEqual(error, .duplicate(first.id))
        }
        XCTAssertEqual(harness.environment.gateways.map(\.id), [first.id], "the existing gateway stays")
        let kept = try await harness.credentials.loadCredential(for: first.id)
        XCTAssertEqual(kept?.rawValue, grant().credential.rawValue, "and keeps its own credential")
    }

    func testACredentialSaveFailureLeavesNothingHalfAdded() async throws {
        let harness = await makeHarness()
        harness.credentials.failSaves.withLock { $0 = true }
        do {
            _ = try await harness.environment.addPairedGateway(grant())
            XCTFail("expected the save failure to surface")
        } catch {}
        XCTAssertTrue(harness.environment.gateways.isEmpty, "no gateway may stay registered without a credential")
        let pin = try await harness.pins.loadPin(for: GatewayID(pairedInstanceID: instance)!)
        XCTAssertNil(pin)
    }

    // MARK: re-adding after removal is explicit

    func testARemovedPairedGatewayDoesNotReturnUntilThePersonPairsAgain() async throws {
        let harness = await makeHarness()
        let added = try await harness.environment.addPairedGateway(grant())
        try await harness.environment.removeGateway(added.id)
        await harness.environment.refreshRoster()
        await harness.environment.restoreIntendedConnections()
        XCTAssertTrue(harness.environment.gateways.isEmpty, "nothing brings a removed gateway back")
        XCTAssertNil(harness.environment.existingGateway(forPairedInstance: instance, origin: origin))

        let again = try await harness.environment.addPairedGateway(grant())     // the deliberate Add
        XCTAssertEqual(harness.environment.gateways.map(\.id), [again.id])
    }

    // MARK: revocation on removal

    func testRemovingAPairedGatewayRevokesTheDeviceOnTheGateway() async throws {
        let harness = await makeHarness()
        let added = try await harness.environment.addPairedGateway(grant())
        let report = try await harness.environment.removeGateway(added.id)

        XCTAssertEqual(report.deviceRevocation, .revoked)
        let calls = harness.revoker.calls.withLock { $0 }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, origin)
        XCTAssertEqual(calls.first?.1, grant().credential.rawValue)
        XCTAssertTrue(harness.environment.gateways.isEmpty)
        let leftover = try await harness.credentials.loadCredential(for: added.id)
        XCTAssertNil(leftover, "the local credential is gone")
    }

    func testRemovalStillSucceedsWhenTheGatewayCannotBeReachedToRevoke() async throws {
        let harness = await makeHarness()
        harness.revoker.outcome.withLock { $0 = .unreachable }
        let added = try await harness.environment.addPairedGateway(grant())
        let report = try await harness.environment.removeGateway(added.id)

        XCTAssertEqual(report.deviceRevocation, .notConfirmed, "the person is told revocation was not confirmed")
        XCTAssertTrue(harness.environment.gateways.isEmpty, "removal from this phone still happens")
    }

    func testRemovingAnOrdinaryGatewayDoesNotTouchTheRevocationService() async throws {
        let harness = await makeHarness(existing: [GatewayRegistration(displayName: "By Hand", endpoint: origin)])
        let id = try XCTUnwrap(harness.environment.gateways.first?.id)
        let report = try await harness.environment.removeGateway(id)
        XCTAssertEqual(report.deviceRevocation, .notApplicable)
        XCTAssertTrue(harness.revoker.calls.withLock { $0 }.isEmpty)
    }

    func testAFailedRemovalDoesNotRevokeTheDevice() async throws {
        let harness = await makeHarness()
        let added = try await harness.environment.addPairedGateway(grant())
        // Removing something that is not registered fails before any revocation.
        do {
            try await harness.environment.removeGateway(GatewayID(rawValue: "gw-unknown"))
            XCTFail()
        } catch {}
        XCTAssertTrue(harness.revoker.calls.withLock { $0 }.isEmpty)
        XCTAssertEqual(harness.environment.gateways.map(\.id), [added.id])
    }

    // MARK: coordinator + real environment

    /// The whole flow through the REAL environment: a second link for a gateway that the first
    /// link added is reported as already in Fleet and is never offered for confirmation.
    func testASecondLinkForAnAlreadyPairedGatewayIsReportedThroughTheRealEnvironment() async throws {
        let harness = await makeHarness()
        let identity = PairingGatewayIdentity(instanceID: instance, displayName: "Home Gateway", origin: origin)
        harness.revoker.identity.withLock { $0 = identity }
        let coordinator = harness.environment.pairing
        func link(_ id: String) -> String {
            "https://gateway.example.test/pair#v=1&i=\(id)&s=0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"
        }
        func settle() async {
            for _ in 0..<300 {
                switch coordinator.phase { case .previewing, .redeeming: try? await Task.sleep(for: .milliseconds(10)); default: return }
            }
        }

        coordinator.receive(url: URL(string: link("okAbCdEfGhIjKlMnOpQr"))!)
        await settle()
        coordinator.confirm()
        await settle()
        XCTAssertEqual(coordinator.phase, .completed(name: "Home Gateway"))
        coordinator.dismiss()
        XCTAssertEqual(coordinator.phase, .idle)

        coordinator.receive(url: URL(string: link("ok2AbCdEfGhIjKlMnOpQr"))!)
        await settle()
        XCTAssertEqual(coordinator.phase, .alreadyAdded(name: "Home Gateway"))
    }
}

// MARK: - Simulator graph (what the UI tests drive)

@MainActor
final class PairingSimulatorGraphTests: XCTestCase {
    private func link(_ id: String) -> URL {
        URL(string: "https://pairing.example.test/pair#v=1&i=\(id)&s=0123456789abcdefghijklmnopqrstuvwxyzABCDEFG")!
    }

    private func settle(_ coordinator: PairingCoordinator) async {
        for _ in 0..<300 {
            switch coordinator.phase {
            case .previewing, .redeeming: try? await Task.sleep(for: .milliseconds(10))
            default: return
            }
        }
    }

    func testASecondLinkForTheSameGatewayIsAlreadyAddedInTheSimulatorGraph() async throws {
        let environment = FleetServiceGraph.makeSimulatorEnvironment()
        await environment.load()
        let coordinator = environment.pairing

        coordinator.receive(url: link("okAbCdEfGhAbCdEfGhAbCdEfGh"))
        await settle(coordinator)
        coordinator.confirm()
        await settle(coordinator)
        XCTAssertEqual(coordinator.phase, .completed(name: "Scripted Pairing Gateway"))
        XCTAssertTrue(environment.gateways.contains { $0.displayName == "Scripted Pairing Gateway" })
        coordinator.dismiss()

        coordinator.receive(url: link("ok2AbCdEfGhAbCdEfGhAbCdEfGh"))
        await settle(coordinator)
        XCTAssertEqual(coordinator.phase, .alreadyAdded(name: "Scripted Pairing Gateway"))
    }
}
