import XCTest
import os
import FleetCore
@testable import FleetNetworking

final class GatewayPairingRegistrationTests: XCTestCase {
    private let instanceID = "0123456789abcdef0123456789abcdef"
    private let deviceID = "abcdef0123456789abcdef0123456789"
    private let endpoint = URL(string: "https://fleet.example.invalid:9443")!

    private func grant() -> PairingGrant {
        PairingGrant(
            gateway: PairingGatewayIdentity(
                instanceID: instanceID, displayName: "Paired Gateway", origin: endpoint),
            deviceID: deviceID,
            credential: PairingDeviceCredential("hfd1.\(deviceID).\(String(repeating: "s", count: 43))"),
            tlsFingerprint: SPKIFingerprint(rawBytes: Array(repeating: 7, count: 32)))
    }

    private final class Credentials: CredentialStoring, @unchecked Sendable {
        private struct State {
            var values: [String: GatewayCredential] = [:]
            var failSave = false
            var blockNext = false
            var waiting = false
            var continuation: CheckedContinuation<Void, Never>?
        }
        private let lock = OSAllocatedUnfairLock(initialState: State())

        var failSave: Bool {
            get { lock.withLock { $0.failSave } }
            set { lock.withLock { $0.failSave = newValue } }
        }
        var isWaiting: Bool { lock.withLock { $0.waiting } }

        func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {
            let shouldWait = lock.withLock { state -> Bool in
                guard state.blockNext else { return false }
                state.blockNext = false
                state.waiting = true
                return true
            }
            if shouldWait {
                await withCheckedContinuation { continuation in
                    let resumeNow = lock.withLock { state -> Bool in
                        if state.continuation == nil {
                            state.continuation = continuation
                            return false
                        }
                        return true
                    }
                    if resumeNow { continuation.resume() }
                }
            }
            try lock.withLock { state in
                if state.failSave { throw CredentialStoreError.storeUnavailable("injected") }
                state.values[gatewayID.rawValue] = credential
            }
        }
        func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? {
            lock.withLock { $0.values[gatewayID.rawValue] }
        }
        func deleteCredential(for gatewayID: GatewayID) async throws {
            _ = lock.withLock { $0.values.removeValue(forKey: gatewayID.rawValue) }
        }
        func seed(_ credential: GatewayCredential, for id: GatewayID) {
            lock.withLock { $0.values[id.rawValue] = credential }
        }
        func release() {
            let continuation = lock.withLock { state -> CheckedContinuation<Void, Never>? in
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume()
        }
        func prepareToBlockNextSave() {
            lock.withLock { $0.blockNext = true }
        }
    }

    private final class Pins: TLSPinStoring, @unchecked Sendable {
        private struct State { var values: [String: SPKIFingerprint] = [:]; var failSave = false }
        private let lock = OSAllocatedUnfairLock(initialState: State())
        var failSave: Bool {
            get { lock.withLock { $0.failSave } }
            set { lock.withLock { $0.failSave = newValue } }
        }
        func savePin(_ pin: SPKIFingerprint, for gatewayID: GatewayID) async throws {
            try lock.withLock { state in
                if state.failSave { throw PinStoreError.unexpectedStatus(-1) }
                state.values[gatewayID.rawValue] = pin
            }
        }
        func loadPin(for gatewayID: GatewayID) async throws -> SPKIFingerprint? {
            lock.withLock { $0.values[gatewayID.rawValue] }
        }
        func deletePin(for gatewayID: GatewayID) async throws {
            _ = lock.withLock { $0.values.removeValue(forKey: gatewayID.rawValue) }
        }
    }

    private final class Records: GatewayRecordStoring, @unchecked Sendable {
        private struct State {
            var values: [String: StoredGatewayRecord] = [:]
            var failAfterSave = false
            var failDelete = false
        }
        private let lock = OSAllocatedUnfairLock(initialState: State())
        var failAfterSave: Bool {
            get { lock.withLock { $0.failAfterSave } }
            set { lock.withLock { $0.failAfterSave = newValue } }
        }
        var failDelete: Bool {
            get { lock.withLock { $0.failDelete } }
            set { lock.withLock { $0.failDelete = newValue } }
        }
        func saveGatewayRecord(_ record: StoredGatewayRecord) async throws {
            try lock.withLock { state in
                state.values[record.id] = record
                if state.failAfterSave { throw GatewayRegistryError.recordStoreFailed("injected") }
            }
        }
        func deleteGatewayRecord(id: GatewayID) async throws {
            try lock.withLock { state in
                if state.failDelete { throw GatewayRegistryError.recordStoreFailed("injected delete") }
                state.values.removeValue(forKey: id.rawValue)
            }
        }
        func loadGatewayRecords() async throws -> [StoredGatewayRecord] {
            lock.withLock { Array($0.values.values) }
        }
    }

    private func service(
        credentials: Credentials = Credentials(), pins: Pins = Pins(), records: Records = Records()
    ) -> GatewayRegistryService {
        GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in Offline(gatewayID: gateway.id) },
            recordStore: records,
            pinStore: pins)
    }

    private struct Offline: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        var status: GatewayStatus { .offline }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws { throw GatewayConnectivityError.connectionFailed("offline") }
        func disconnect() async {}
        func currentGateway() async -> FleetGateway { FleetGateway(id: gatewayID, displayName: "offline", endpoint: nil) }
    }

    func testCredentialWriteCutpointHasNoVisibleOrDurableGatewayAndReservesIdentity() async throws {
        let credentials = Credentials()
        // A continuation installed before register makes the first save pause.
        credentials.prepareToBlockNextSave()
        let records = Records()
        let service = service(credentials: credentials, records: records)
        let pairingGrant = grant()
        let registration = Task { try await service.registerPairedGateway(pairingGrant) }
        for _ in 0..<10_000 where !credentials.isWaiting { await Task.yield() }
        XCTAssertTrue(credentials.isWaiting)
        let visibleAtCutpoint = await service.allGateways()
        let durableAtCutpoint = try await records.loadGatewayRecords()
        XCTAssertTrue(visibleAtCutpoint.isEmpty)
        XCTAssertTrue(durableAtCutpoint.isEmpty)

        do {
            _ = try await service.registerPairedGateway(pairingGrant)
            XCTFail("an in-flight pairing must reserve its identity")
        } catch let error as GatewayRegistryError {
            guard case .duplicate = error else { return XCTFail("unexpected error: \(error)") }
        }
        do {
            try await service.discardUncommittedPairing(pairingGrant)
            XCTFail("cleanup cannot race a still-running registration")
        } catch { }

        do {
            _ = try await service.addGateway(GatewayRegistration(
                id: GatewayID(pairedInstanceID: instanceID), displayName: "Manual",
                endpoint: endpoint))
            XCTFail("an in-flight pairing must reserve its ID and origin")
        } catch let error as GatewayRegistryError {
            guard case .duplicate = error else { return XCTFail("unexpected error: \(error)") }
        }

        credentials.release()
        let registered = try await registration.value
        XCTAssertEqual(registered.authConfiguration.strategy, .deviceCredential)
        let committedRecords = try await records.loadGatewayRecords()
        XCTAssertEqual(committedRecords.count, 1)
    }

    func testCredentialWriteFailureCanBeDiscardedWithoutPublishingGateway() async throws {
        let credentials = Credentials(); credentials.failSave = true
        let pins = Pins(); let records = Records()
        let service = service(credentials: credentials, pins: pins, records: records)
        let pairingGrant = grant()
        do { _ = try await service.registerPairedGateway(pairingGrant); XCTFail("expected failure") }
        catch { }
        try await service.discardUncommittedPairing(pairingGrant)
        let visible = await service.allGateways()
        let durable = try await records.loadGatewayRecords()
        XCTAssertTrue(visible.isEmpty)
        XCTAssertTrue(durable.isEmpty)
        let id = try XCTUnwrap(GatewayID(pairedInstanceID: instanceID))
        let savedCredential = try await credentials.loadCredential(for: id)
        let savedPin = try await pins.loadPin(for: id)
        XCTAssertNil(savedCredential)
        XCTAssertNil(savedPin)
    }

    func testPinWriteFailureCleansCredentialAndNeverWritesRecord() async throws {
        let credentials = Credentials(); let pins = Pins(); pins.failSave = true
        let records = Records(); let service = service(credentials: credentials, pins: pins, records: records)
        let pairingGrant = grant()
        do { _ = try await service.registerPairedGateway(pairingGrant); XCTFail("expected failure") }
        catch { }
        try await service.discardUncommittedPairing(pairingGrant)
        let visible = await service.allGateways()
        let durable = try await records.loadGatewayRecords()
        XCTAssertTrue(visible.isEmpty)
        XCTAssertTrue(durable.isEmpty)
        let id = try XCTUnwrap(GatewayID(pairedInstanceID: instanceID))
        let savedCredential = try await credentials.loadCredential(for: id)
        let savedPin = try await pins.loadPin(for: id)
        XCTAssertNil(savedCredential)
        XCTAssertNil(savedPin)
    }

    func testRecordWriteFailureRemovesAmbiguousCommitMarkerBeforeSecrets() async throws {
        let credentials = Credentials(); let pins = Pins(); let records = Records(); records.failAfterSave = true
        let service = service(credentials: credentials, pins: pins, records: records)
        let pairingGrant = grant()
        do { _ = try await service.registerPairedGateway(pairingGrant); XCTFail("expected failure") }
        catch { }
        // The store simulates an ambiguous failure after its upsert. Cleanup
        // must remove the possible commit marker and all transaction material.
        try await service.discardUncommittedPairing(pairingGrant)
        let visible = await service.allGateways()
        let durable = try await records.loadGatewayRecords()
        XCTAssertTrue(visible.isEmpty)
        XCTAssertTrue(durable.isEmpty)
        let id = try XCTUnwrap(GatewayID(pairedInstanceID: instanceID))
        let savedCredential = try await credentials.loadCredential(for: id)
        let savedPin = try await pins.loadPin(for: id)
        XCTAssertNil(savedCredential)
        XCTAssertNil(savedPin)
    }

    func testFailedCommitMarkerCleanupKeepsSecretsAndReservationUntilRetry() async throws {
        let credentials = Credentials(); let pins = Pins(); let records = Records()
        records.failAfterSave = true
        let service = service(credentials: credentials, pins: pins, records: records)
        let pairingGrant = grant()
        do { _ = try await service.registerPairedGateway(pairingGrant); XCTFail("expected failure") }
        catch { }

        records.failDelete = true
        do {
            try await service.discardUncommittedPairing(pairingGrant)
            XCTFail("cleanup failure must surface")
        } catch let error as GatewayRegistryError {
            guard case .recordStoreFailed = error else { return XCTFail("unexpected error: \(error)") }
        }
        let id = try XCTUnwrap(GatewayID(pairedInstanceID: instanceID))
        let pendingCredential = try await credentials.loadCredential(for: id)
        let pendingPin = try await pins.loadPin(for: id)
        let pendingRecords = try await records.loadGatewayRecords()
        XCTAssertNotNil(pendingCredential)
        XCTAssertNotNil(pendingPin)
        XCTAssertEqual(pendingRecords.count, 1)

        records.failDelete = false
        try await service.discardUncommittedPairing(pairingGrant)
        let visible = await service.allGateways()
        let durable = try await records.loadGatewayRecords()
        let remainingCredential = try await credentials.loadCredential(for: id)
        let remainingPin = try await pins.loadPin(for: id)
        XCTAssertTrue(visible.isEmpty)
        XCTAssertTrue(durable.isEmpty)
        XCTAssertNil(remainingCredential)
        XCTAssertNil(remainingPin)
    }

    func testRelaunchRestoresOnlyFullyConfiguredCommittedPairing() async throws {
        let credentials = Credentials(); let pins = Pins(); let records = Records()
        let first = service(credentials: credentials, pins: pins, records: records)
        _ = try await first.registerPairedGateway(grant())

        let relaunched = service(credentials: credentials, pins: pins, records: records)
        let restored = try await relaunched.restorePersistedGateways()
        XCTAssertEqual(restored.count, 1)
        XCTAssertTrue(restored[0].authConfigured)
        XCTAssertTrue(restored[0].authConfiguration.credentialStored)
        XCTAssertEqual(restored[0].authConfiguration.strategy, .deviceCredential)
        let restoredPin = try await pins.loadPin(for: restored[0].id)
        let restoredCredential = try await credentials.loadCredential(for: restored[0].id)
        XCTAssertNotNil(restoredPin)
        XCTAssertNotNil(restoredCredential)
    }

    func testExistingCredentialIsNeverOverwrittenByPairing() async throws {
        let credentials = Credentials(); let pins = Pins(); let records = Records()
        let id = try XCTUnwrap(GatewayID(pairedInstanceID: instanceID))
        let existing = GatewayCredential(rawValue: "keep-existing")
        credentials.seed(existing, for: id)
        let service = service(credentials: credentials, pins: pins, records: records)
        do { _ = try await service.registerPairedGateway(grant()); XCTFail("expected duplicate") }
        catch let error as GatewayRegistryError {
            guard case .duplicate = error else { return XCTFail("unexpected error: \(error)") }
        }
        let savedCredential = try await credentials.loadCredential(for: id)
        let durable = try await records.loadGatewayRecords()
        let visible = await service.allGateways()
        XCTAssertEqual(savedCredential, existing)
        XCTAssertTrue(durable.isEmpty)
        XCTAssertTrue(visible.isEmpty)
    }
}
