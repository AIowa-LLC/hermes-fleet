import XCTest
import os
import FleetCore
@testable import FleetNetworking

/// Explicit gateway removal at the registry/durable-store boundary (Dev build
/// 6): a removal is either fully applied or fully rolled back with an honest
/// error, a force-quit mid-removal rolls FORWARD instead of reviving the
/// gateway, a stale restore snapshot can never re-register a removed gateway,
/// and neighbouring gateways are never disturbed. Synthetic fixtures only.
final class GatewayRemovalDurabilityTests: XCTestCase {
    private let a = GatewayID(rawValue: "gw-a.example.invalid:9120")
    private let b = GatewayID(rawValue: "gw-b.example.invalid:9120")

    // MARK: fixtures

    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var entered = 0
        func wait() async {
            entered += 1
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
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

    private final class RecordStore: GatewayRecordStoring, @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(
            initialState: (records: [String: StoredGatewayRecord](), failDeletes: false, hangDeletes: false))
        var failDeletes: Bool {
            get { state.withLock { $0.failDeletes } }
            set { state.withLock { $0.failDeletes = newValue } }
        }
        /// Simulates a process kill in the middle of the delete: the call
        /// never returns and never mutates the store.
        var hangDeletes: Bool {
            get { state.withLock { $0.hangDeletes } }
            set { state.withLock { $0.hangDeletes = newValue } }
        }
        func saveGatewayRecord(_ record: StoredGatewayRecord) async throws {
            state.withLock { $0.records[record.id] = record }
        }
        func deleteGatewayRecord(id: GatewayID) async throws {
            if hangDeletes { await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } }
            if failDeletes { throw NSError(domain: "scripted.records", code: 1) }
            state.withLock { _ = $0.records.removeValue(forKey: id.rawValue) }
        }
        func loadGatewayRecords() async throws -> [StoredGatewayRecord] {
            state.withLock { $0.records.values.sorted { $0.id < $1.id } }
        }
    }

    private final class CredentialStore: CredentialStoring, @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(
            initialState: (secrets: [String: String](), failDeletes: false))
        var failDeletes: Bool {
            get { state.withLock { $0.failDeletes } }
            set { state.withLock { $0.failDeletes = newValue } }
        }
        /// Optional gate that parks `loadCredential` for one gateway.
        var loadGate: (id: GatewayID, gate: Gate)?
        func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {
            state.withLock { $0.secrets[gatewayID.rawValue] = credential.rawValue }
        }
        func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? {
            if let loadGate, loadGate.id == gatewayID { await loadGate.gate.wait() }
            return state.withLock { $0.secrets[gatewayID.rawValue].map { GatewayCredential(rawValue: $0) } }
        }
        func deleteCredential(for gatewayID: GatewayID) async throws {
            if failDeletes { throw NSError(domain: "scripted.keychain", code: -25308) }
            state.withLock { _ = $0.secrets.removeValue(forKey: gatewayID.rawValue) }
        }
    }

    private struct Offline: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        var status: GatewayStatus { .offline }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws { throw GatewayConnectivityError.connectionFailed("offline") }
        func disconnect() async {}
        func currentGateway() async -> FleetGateway {
            FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil)
        }
    }

    /// Everything that survives a force-quit.
    private struct Durable {
        let records = RecordStore()
        let credentials = CredentialStore()
        let ledger = InMemoryGatewayRemovalLedger()
        func service() -> GatewayRegistryService {
            GatewayRegistryService(
                credentials: credentials,
                connectionFactory: { gateway, _ in Offline(gatewayID: gateway.id) },
                recordStore: records,
                removalLedger: ledger)
        }
    }

    private func registration(_ id: GatewayID, name: String) -> GatewayRegistration {
        let host = id.rawValue.split(separator: ":").first.map(String.init) ?? id.rawValue
        return GatewayRegistration(
            id: id, displayName: name,
            endpoint: URL(string: "https://\(host):9120")!)
    }

    private func seedBoth(_ durable: Durable) async throws -> GatewayRegistryService {
        let service = durable.service()
        _ = try await service.addGateway(registration(a, name: "A"))
        _ = try await service.addGateway(registration(b, name: "B"))
        try await service.saveCredential(GatewayCredential(rawValue: "secret-a"), for: a)
        try await service.saveCredential(GatewayCredential(rawValue: "secret-b"), for: b)
        return service
    }

    // MARK: stale restore

    /// A restore that took its record snapshot before the user removed a
    /// gateway must not re-register that gateway when it resumes.
    func testRestoreInFlightDuringRemovalDoesNotReregisterRemovedGateway() async throws {
        let durable = Durable()
        _ = try await seedBoth(durable)

        // A fresh process: gateway B was re-added (registered), gateway A is
        // only a saved record, and A's credential read is slow.
        let gate = Gate()
        durable.credentials.loadGate = (a, gate)
        let service = durable.service()
        _ = try await service.addGateway(registration(b, name: "B"))

        let restore = Task { try await service.restorePersistedGateways() }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered, "restore must be parked mid-flight")

        try await service.removeGateway(b)
        await gate.open()
        _ = try await restore.value

        let ids = await service.allGateways().map(\.id)
        XCTAssertEqual(ids, [a], "a stale restore snapshot must not revive a removed gateway")
        let stored = try await durable.records.loadGatewayRecords().map(\.id)
        XCTAssertEqual(stored, [a.rawValue])
    }

    // MARK: honest failure

    /// If the saved record cannot be deleted the removal reports it and the
    /// gateway is left fully intact, credential included.
    func testRecordDeleteFailureRollsBackWithoutLosingTheCredential() async throws {
        let durable = Durable()
        let service = try await seedBoth(durable)
        durable.records.failDeletes = true

        do {
            try await service.removeGateway(a)
            XCTFail("removal that cannot be persisted must throw")
        } catch let error as GatewayRegistryError {
            guard case .recordStoreFailed = error else { return XCTFail("got \(error)") }
        }

        let listed = await service.gateway(for: a)
        XCTAssertNotNil(listed, "a failed removal must not claim success")
        let credential = try await durable.credentials.loadCredential(for: a)
        XCTAssertEqual(credential?.rawValue, "secret-a", "a failed removal must not destroy the credential")
        let pending = try await durable.ledger.pendingRemovals()
        XCTAssertTrue(pending.isEmpty, "a rolled-back removal leaves no marker")

        // After the store recovers the same removal succeeds.
        durable.records.failDeletes = false
        try await service.removeGateway(a)
        let after = await service.gateway(for: a)
        XCTAssertNil(after)
    }

    func testCredentialDeleteFailureRollsBackAndKeepsTheRecord() async throws {
        let durable = Durable()
        let service = try await seedBoth(durable)
        durable.credentials.failDeletes = true

        do {
            try await service.removeGateway(a)
            XCTFail("expected credentialStoreFailed")
        } catch let error as GatewayRegistryError {
            guard case .credentialStoreFailed = error else { return XCTFail("got \(error)") }
        }

        let listed = await service.gateway(for: a)
        XCTAssertNotNil(listed)
        let stored = try await durable.records.loadGatewayRecords().map(\.id)
        XCTAssertTrue(stored.contains(a.rawValue), "the saved record must be restored on rollback")
        let pending = try await durable.ledger.pendingRemovals()
        XCTAssertTrue(pending.isEmpty)
    }

    /// If the removal marker cannot be written nothing at all is touched.
    func testRemovalMarkerFailureAbortsBeforeAnySideEffect() async throws {
        let durable = Durable()
        let service = try await seedBoth(durable)
        await durable.ledger.setFailMarking(true)

        do {
            try await service.removeGateway(a)
            XCTFail("expected the removal to be refused")
        } catch let error as GatewayRegistryError {
            guard case .removalStateStoreFailed = error else { return XCTFail("got \(error)") }
        }

        let listed = await service.gateway(for: a)
        XCTAssertNotNil(listed)
        let credential = try await durable.credentials.loadCredential(for: a)
        XCTAssertNotNil(credential)
        let stored = try await durable.records.loadGatewayRecords().map(\.id)
        XCTAssertEqual(stored, [a.rawValue, b.rawValue].sorted())
    }

    // MARK: force-quit

    /// A process kill after the removal started but before it finished must
    /// not revive the gateway on the next launch, and the next launch
    /// finishes the cleanup.
    func testForceQuitMidRemovalRollsForwardOnRelaunch() async throws {
        let durable = Durable()
        let service = try await seedBoth(durable)

        durable.records.hangDeletes = true
        let doomedID = a
        let doomed = Task { try await service.removeGateway(doomedID) }
        // Let the removal run until it parks in the (never-returning) delete.
        try await Task.sleep(for: .milliseconds(200))
        doomed.cancel()   // the process is gone; nothing else of that run executes

        // Relaunch: fresh service over the same stores; the delete works now.
        durable.records.hangDeletes = false
        let relaunched = durable.service()
        let restored = try await relaunched.restorePersistedGateways()

        XCTAssertEqual(restored.map(\.id), [b], "the half-removed gateway must not reappear")
        let ids = await relaunched.allGateways().map(\.id)
        XCTAssertEqual(ids, [b])
        let stored = try await durable.records.loadGatewayRecords().map(\.id)
        XCTAssertEqual(stored, [b.rawValue], "the relaunch finishes deleting the record")
        let leftover = try await durable.credentials.loadCredential(for: a)
        XCTAssertNil(leftover, "the relaunch finishes deleting the credential")
        let neighbour = try await durable.credentials.loadCredential(for: b)
        XCTAssertEqual(neighbour?.rawValue, "secret-b", "the neighbour's credential is untouched")
        let pending = try await durable.ledger.pendingRemovals()
        XCTAssertTrue(pending.isEmpty, "the completed cleanup clears the marker")
    }

    // MARK: explicit re-add

    /// A removed gateway comes back only through a deliberate Add, which also
    /// clears its removal marker so the new record survives relaunch.
    func testRemovedGatewayReturnsOnlyThroughExplicitAdd() async throws {
        let durable = Durable()
        let service = try await seedBoth(durable)
        try await service.removeGateway(a)

        let relaunched = durable.service()
        let restoredAfterRemoval = try await relaunched.restorePersistedGateways()
        XCTAssertEqual(restoredAfterRemoval.map(\.id), [b])

        _ = try await relaunched.addGateway(registration(a, name: "A again"))
        let third = durable.service()
        let restored = try await third.restorePersistedGateways()
        XCTAssertEqual(restored.map(\.id).sorted { $0.rawValue < $1.rawValue }, [a, b],
                       "an explicit Add survives relaunch")
        let renamed = await third.gateway(for: a)
        XCTAssertEqual(renamed?.displayName, "A again")
    }

    // MARK: neighbours / concurrency

    func testRemovingOneGatewayLeavesTheOtherUntouched() async throws {
        let durable = Durable()
        let service = try await seedBoth(durable)

        try await service.removeGateway(a)

        let ids = await service.allGateways().map(\.id)
        XCTAssertEqual(ids, [b])
        let hasB = await service.hasCredential(for: b)
        XCTAssertTrue(hasB)
        let stored = try await durable.records.loadGatewayRecords().map(\.id)
        XCTAssertEqual(stored, [b.rawValue])
    }

    func testConcurrentRemovalOfTheSameGatewayAppliesOnce() async throws {
        let durable = Durable()
        let service = try await seedBoth(durable)

        let id = a
        async let first: Void = service.removeGateway(id)
        async let second: Void = service.removeGateway(id)
        var failures = 0
        do { try await first } catch { failures += 1 }
        do { try await second } catch { failures += 1 }

        XCTAssertEqual(failures, 1, "exactly one concurrent removal wins; the other reports not found")
        let ids = await service.allGateways().map(\.id)
        XCTAssertEqual(ids, [b])
    }

    // MARK: redaction

    func testRemovalErrorsDoNotLeakSecrets() async throws {
        let durable = Durable()
        let service = try await seedBoth(durable)
        durable.records.failDeletes = true
        do {
            try await service.removeGateway(a)
            XCTFail("expected failure")
        } catch {
            let text = String(describing: error) + (error.localizedDescription)
            XCTAssertFalse(text.contains("secret-a"))
        }
    }
}
