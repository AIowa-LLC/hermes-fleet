import XCTest
import FleetCore
import FleetNetworking
import FleetPersistence
import FleetSecurity
@testable import FleetUI

/// First-use TLS fingerprint review: a secure gateway is only registered with
/// a review bound to ITS endpoint, the approval stored from it is bound to that
/// exact key, and every stale / changed / cancelled / failed path fails closed
/// before anything is registered or approved. Synthetic fixtures only.
@MainActor
final class TLSFirstUseReviewTests: XCTestCase {
    private let secure = URL(string: "https://gateway.example.invalid:8642")!
    private let otherSecure = URL(string: "https://other.example.invalid:8642")!
    private let keyA = SPKIFingerprint(rawBytes: Array(repeating: 0x0A, count: 32))
    private let keyB = SPKIFingerprint(rawBytes: Array(repeating: 0x0B, count: 32))

    private struct Probe: TLSKeyProbing {
        let result: Result<SPKIFingerprint, TLSKeyReviewError>
        func presentedKey(for endpoint: URL) async throws -> SPKIFingerprint { try result.get() }
    }

    private struct Connection: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        var status: GatewayStatus { .offline }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil)
        }
    }
    private struct RosterSession: GatewayRosterSession {
        let gatewayID: GatewayID
        var status: GatewayStatus { .offline }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil)
        }
        func fetchProfiles() async throws -> [ProfileDescriptor] { [] }
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }
    private struct SessionList: SessionListProviding {
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }
    private final class Health: ConnectionHealthAccumulating, @unchecked Sendable {
        func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
        func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
        func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
        func rehydrate(gatewayIDs: [GatewayID]) async {}
        func forget(gatewayID: GatewayID) async {}
    }

    private func makeEnvironment(
        store: InMemoryPinStore,
        probe: TLSKeyProbing? = nil,
        seeds: [GatewayRegistration] = []
    ) async throws -> AppEnvironment {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in Connection(gatewayID: gateway.id) })
        let environment = AppEnvironment(
            registry: registry,
            roster: FleetRosterService(
                registry: registry, credentials: credentials,
                sessionFactory: { gateway, _ in RosterSession(gatewayID: gateway.id) }),
            cache: try SwiftDataCacheStore.makeInMemory(),
            tlsPinStore: store,
            tlsApprovalStore: store,
            tlsKeyProbe: probe ?? Probe(result: .success(keyA)),
            sessionList: SessionList(),
            connectionFactory: { gateway, _ in Connection(gatewayID: gateway.id) },
            health: Health(),
            seedRegistrations: seeds,
            bridgedStoreURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tls-review-\(UUID().uuidString).json"))
        environment.attachContinueIndex(FleetContinueIndexStore(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("tls-ci-\(UUID().uuidString).json")))
        environment.attachArtifactLibrary(FleetArtifactLibrary(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("tls-al-\(UUID().uuidString).json")))
        await environment.load()
        return environment
    }

    private func registration(_ endpoint: URL, id: GatewayID? = nil) -> GatewayRegistration {
        GatewayRegistration(id: id, displayName: "Gateway", endpoint: endpoint)
    }

    private func assertThrows(_ expected: TLSKeyReviewError, _ body: () async throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? TLSKeyReviewError, expected, file: file, line: line) }
    }

    // MARK: review

    func testReviewReturnsTheKeyThePeerPresentsBoundToTheNormalizedEndpoint() async throws {
        let env = try await makeEnvironment(store: InMemoryPinStore())
        let review = try await env.reviewTLSKey(for: URL(string: "https://gateway.example.invalid:8642/?token=x#frag")!)
        XCTAssertEqual(review.fingerprint, keyA)
        XCTAssertEqual(review.endpoint.query, nil, "query/fragment never ride along")
        XCTAssertEqual(review.displayFingerprint.split(separator: ":").count, 32,
                       "the FULL fingerprint is shown, never abbreviated")
    }

    func testReviewOfInsecureOrUnreachableEndpointFailsClosed() async throws {
        let env = try await makeEnvironment(store: InMemoryPinStore())
        await assertThrows(.probeFailed) { _ = try await env.reviewTLSKey(for: URL(string: "http://127.0.0.1:8642")!) }
        let failing = try await makeEnvironment(store: InMemoryPinStore(), probe: Probe(result: .failure(.probeFailed)))
        await assertThrows(.probeFailed) { _ = try await failing.reviewTLSKey(for: secure) }
    }

    // MARK: add

    func testSecureAddWithoutReviewRegistersNothing() async throws {
        let store = InMemoryPinStore()
        let env = try await makeEnvironment(store: store)
        await assertThrows(.required) {
            _ = try await env.addGateway(registration(secure), credential: GatewayCredential(rawValue: "secret"))
        }
        XCTAssertTrue(env.gateways.isEmpty, "no gateway (and so no stored credential) without a trust decision")
    }

    func testReviewForAnotherEndpointIsRejectedBeforeRegistering() async throws {
        let env = try await makeEnvironment(store: InMemoryPinStore())
        let review = TLSKeyReview(endpoint: otherSecure, fingerprint: keyA)
        await assertThrows(.endpointChanged) {
            _ = try await env.addGateway(registration(secure), credential: nil, tlsReview: review)
        }
        XCTAssertTrue(env.gateways.isEmpty)
    }

    func testStaleReviewIsRejected() async throws {
        let env = try await makeEnvironment(store: InMemoryPinStore())
        let old = TLSKeyReview(endpoint: secure, fingerprint: keyA,
                               reviewedAt: Date().addingTimeInterval(-(TLSKeyReview.maxAge + 5)))
        await assertThrows(.stale) {
            _ = try await env.addGateway(registration(secure), credential: nil, tlsReview: old)
        }
        let future = TLSKeyReview(endpoint: secure, fingerprint: keyA, reviewedAt: Date().addingTimeInterval(120))
        await assertThrows(.stale) {
            _ = try await env.addGateway(registration(secure), credential: nil, tlsReview: future)
        }
        XCTAssertTrue(env.gateways.isEmpty)
    }

    func testConfirmedReviewStoresAnApprovalBoundToExactlyThatKey() async throws {
        let store = InMemoryPinStore()
        let env = try await makeEnvironment(store: store)
        let review = try await env.reviewTLSKey(for: secure)
        let gateway = try await env.addGateway(registration(secure), credential: nil, tlsReview: review)

        XCTAssertFalse(try store.syncConsumeFirstUseApproval(matching: keyB, for: gateway.id),
                       "a different key must not consume the approval")
        XCTAssertTrue(try store.syncConsumeFirstUseApproval(matching: keyA, for: gateway.id))
        XCTAssertFalse(try store.syncConsumeFirstUseApproval(matching: keyA, for: gateway.id), "single-use")
    }

    func testInsecureEndpointNeedsNoReview() async throws {
        let env = try await makeEnvironment(store: InMemoryPinStore())
        let gateway = try await env.addGateway(
            registration(URL(string: "http://127.0.0.1:8642")!), credential: nil)
        XCTAssertEqual(env.gateways.count, 1)
        XCTAssertNotNil(gateway.endpoint)
    }

    // MARK: edit / re-pair

    func testEndpointEditClearsOldTrustAndRequiresANewReview() async throws {
        let store = InMemoryPinStore()
        let id = GatewayID(rawValue: "gw-edit")
        let env = try await makeEnvironment(
            store: store, seeds: [registration(secure, id: id)])
        try await store.savePin(keyA, for: id)
        try store.syncApproveFirstUse(boundTo: keyA, for: id)

        // Without a review for the NEW address the edit is refused, untouched.
        await assertThrows(.required) {
            _ = try await env.updateGateway(id, edits: GatewayEdit(endpoint: self.otherSecure))
        }
        XCTAssertEqual(env.gateways.first?.endpoint, secure)
        XCTAssertEqual(try store.syncLoadPin(for: id), keyA, "a refused edit keeps the established pin")

        // A review of the old address cannot authorize the new one.
        await assertThrows(.endpointChanged) {
            _ = try await env.updateGateway(
                id, edits: GatewayEdit(endpoint: self.otherSecure),
                tlsReview: TLSKeyReview(endpoint: self.secure, fingerprint: self.keyB))
        }

        // A review of the new address: the old pin/approval are cleared and the
        // new approval is bound to the new reviewed key.
        let review = TLSKeyReview(endpoint: otherSecure, fingerprint: keyB)
        _ = try await env.updateGateway(id, edits: GatewayEdit(endpoint: otherSecure), tlsReview: review)
        XCTAssertNil(try store.syncLoadPin(for: id), "the old endpoint's pin never carries over")
        XCTAssertFalse(try store.syncConsumeFirstUseApproval(matching: keyA, for: id))
        XCTAssertTrue(try store.syncConsumeFirstUseApproval(matching: keyB, for: id))
    }

    func testRenameKeepsEstablishedPinWithoutReview() async throws {
        let store = InMemoryPinStore()
        let id = GatewayID(rawValue: "gw-rename")
        let env = try await makeEnvironment(store: store, seeds: [registration(secure, id: id)])
        try await store.savePin(keyA, for: id)
        _ = try await env.updateGateway(id, edits: GatewayEdit(displayName: "Renamed"))
        XCTAssertEqual(try store.syncLoadPin(for: id), keyA)
    }

    func testRepairApprovalValidatesAgainstTheCurrentEndpoint() async throws {
        let store = InMemoryPinStore()
        let id = GatewayID(rawValue: "gw-repair")
        let env = try await makeEnvironment(store: store, seeds: [registration(secure, id: id)])
        try await env.resetTLSTrust(for: id)

        await assertThrows(.endpointChanged) {
            try await env.approveTLSFirstUse(
                for: id, review: TLSKeyReview(endpoint: self.otherSecure, fingerprint: self.keyA))
        }
        XCTAssertFalse(try store.syncIsFirstUseApproved(for: id))

        try await env.approveTLSFirstUse(for: id, review: TLSKeyReview(endpoint: secure, fingerprint: keyA))
        XCTAssertTrue(try store.syncConsumeFirstUseApproval(matching: keyA, for: id))
    }
}
