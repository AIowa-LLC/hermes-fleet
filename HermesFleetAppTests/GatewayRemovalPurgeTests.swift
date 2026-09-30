import XCTest
import SwiftData
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
@testable import FleetUI

/// P0.3b: removing a gateway deletes the device-local data it leaves behind
/// (cached transcripts and per-gateway SwiftData rows, room drafts, bridged
/// rooms) without touching other gateways, and a failed purge is recorded but
/// never blocks the removal. Synthetic fixtures only.
@MainActor
final class GatewayRemovalPurgeTests: XCTestCase {
    private let removed = GatewayID(rawValue: "gw-removed")
    private let kept = GatewayID(rawValue: "gw-kept")

    // MARK: Doubles

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

    /// Delegates to a real in-memory SwiftData store but fails the purge.
    private struct PurgeFailingCache: CacheStoring {
        let base: SwiftDataCacheStore
        func saveHistory(_ history: SessionHistory, for gatewayID: GatewayID) async throws {
            try await base.saveHistory(history, for: gatewayID)
        }
        func loadHistory(sessionID: String, for gatewayID: GatewayID) async throws -> SessionHistory? {
            try await base.loadHistory(sessionID: sessionID, for: gatewayID)
        }
        func deleteHistory(sessionID: String, for gatewayID: GatewayID) async throws {
            try await base.deleteHistory(sessionID: sessionID, for: gatewayID)
        }
        func saveWatermark(_ watermark: SessionEventWatermark, for gatewayID: GatewayID) async throws {
            try await base.saveWatermark(watermark, for: gatewayID)
        }
        func loadWatermarks() async throws -> [SessionEventWatermark] { try await base.loadWatermarks() }
        func clearWatermarks() async throws { try await base.clearWatermarks() }
        func saveReplayEpoch(_ epoch: String?, for gatewayID: GatewayID) async throws {
            try await base.saveReplayEpoch(epoch, for: gatewayID)
        }
        func loadReplayEpoch(for gatewayID: GatewayID) async throws -> String? {
            try await base.loadReplayEpoch(for: gatewayID)
        }
        func resetForReplayEpochChange(gatewayID: GatewayID) async throws {
            try await base.resetForReplayEpochChange(gatewayID: gatewayID)
        }
        func clearCachedData() async throws { try await base.clearCachedData() }
        func purgeGateway(_ id: GatewayID) async throws {
            throw CacheStoreError.storeUnavailable("synthetic-sensitive-error-payload")
        }
    }

    /// A store that predates `purgeGateway`: relies on the protocol default.
    private struct LegacyCache: CacheStoring {
        func saveHistory(_ history: SessionHistory, for gatewayID: GatewayID) async throws {}
        func loadHistory(sessionID: String, for gatewayID: GatewayID) async throws -> SessionHistory? { nil }
        func deleteHistory(sessionID: String, for gatewayID: GatewayID) async throws {}
        func saveWatermark(_ watermark: SessionEventWatermark, for gatewayID: GatewayID) async throws {}
        func loadWatermarks() async throws -> [SessionEventWatermark] { [] }
        func clearWatermarks() async throws {}
        func saveReplayEpoch(_ epoch: String?, for gatewayID: GatewayID) async throws {}
        func loadReplayEpoch(for gatewayID: GatewayID) async throws -> String? { nil }
        func resetForReplayEpochChange(gatewayID: GatewayID) async throws {}
    }

    // MARK: Fixtures

    private func makeEnvironment(
        cache: any CacheStoring,
        recorder: DiagnosticsRecorder = DiagnosticsRecorder(),
        bridgedStoreURL: URL? = nil
    ) async -> AppEnvironment {
        let credentials = InMemoryCredentialStore()
        let registry = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in Connection(gatewayID: gateway.id) })
        RoomDraftStore.allowWrites(forGateway: removed)
        RoomDraftStore.allowWrites(forGateway: kept)
        let seeds = [removed, kept].map {
            GatewayRegistration(
                id: $0, displayName: "Gateway \($0.rawValue)",
                endpoint: URL(string: "http://127.0.0.1:8642")!)
        }
        let environment = AppEnvironment(
            registry: registry,
            roster: FleetRosterService(
                registry: registry, credentials: credentials,
                sessionFactory: { gateway, _ in RosterSession(gatewayID: gateway.id) }),
            cache: cache,
            sessionList: SessionList(),
            connectionFactory: { gateway, _ in Connection(gatewayID: gateway.id) },
            health: Health(),
            seedRegistrations: seeds,
            bridgedStoreURL: bridgedStoreURL ?? tempURL(),
            diagnosticsRecorder: recorder)
        // Hermetic per-test persistence for the file-backed device-local stores.
        environment.attachContinueIndex(FleetContinueIndexStore(url: tempURL()))
        environment.attachArtifactLibrary(FleetArtifactLibrary(url: tempURL()))
        await environment.load()
        return environment
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-purge-\(UUID().uuidString).json")
    }

    private func history(_ sessionID: String, text: String) -> SessionHistory {
        SessionHistory(sessionID: sessionID, count: 1, messages: [
            SessionMessage(role: .user, text: text, timestamp: 1, rowID: "row-\(sessionID)")
        ])
    }

    private func seed(_ store: SwiftDataCacheStore, gateway: GatewayID, session: String) async throws {
        try await store.saveHistory(history(session, text: "synthetic transcript"), for: gateway)
        try await store.saveWatermark(SessionEventWatermark(sessionID: session, lastSeenSeq: 5), for: gateway)
        try await store.saveReplayEpoch("epoch-\(gateway.rawValue)", for: gateway)
    }

    private func room(_ gateway: GatewayID, _ key: String) -> FleetRoomID {
        FleetRoomID(provenance: .hosted, gatewayID: gateway, key: key)
    }

    // MARK: Tests

    func testRemoveGatewayPurgesItsCachedTranscriptsButNotOthers() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        try await seed(store, gateway: removed, session: "removed-session")
        try await seed(store, gateway: kept, session: "kept-session")
        let environment = await makeEnvironment(cache: store)

        try await environment.removeGateway(removed)

        let removedHistory = try await store.loadHistory(sessionID: "removed-session", for: removed)
        let keptHistory = try await store.loadHistory(sessionID: "kept-session", for: kept)
        XCTAssertNil(removedHistory, "the removed gateway's transcript must not survive removal")
        XCTAssertNotNil(keptHistory, "another gateway's transcript is untouched")
        let sessions = try await store.loadWatermarks().map(\.sessionID)
        XCTAssertFalse(sessions.contains("removed-session"))
        XCTAssertTrue(sessions.contains("kept-session"))
        let epoch = try await store.loadReplayEpoch(for: removed)
        XCTAssertNil(epoch)
        let keptEpoch = try await store.loadReplayEpoch(for: kept)
        XCTAssertNotNil(keptEpoch)
        XCTAssertEqual(environment.cachedWatermarkCount, 1)

        let ctx = ModelContext(store.container)
        let leftover = try ctx.fetch(FetchDescriptor<CachedMessageRow>())
            .filter { $0.gatewayID == removed.rawValue }
        XCTAssertTrue(leftover.isEmpty, "no CachedMessageRow remains for the removed gateway")
        XCTAssertEqual(environment.gateways.map(\.id), [kept])
    }

    func testRemoveGatewayClearsItsRoomDraftsOnly() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        let environment = await makeEnvironment(cache: store)
        let removedRoom = room(removed, "r1")
        let removedLegacy = FleetRoomID(provenance: .desktopLegacy, gatewayID: removed, key: "id:abc")
        let keptRoom = room(kept, "r1")
        // Shares the removed id as a `:`-delimited prefix; must survive.
        let lookalike = GatewayID(rawValue: "\(removed.rawValue):8080")
        let lookalikeRoom = room(lookalike, "r1")
        let all = [removedRoom, removedLegacy, keptRoom, lookalikeRoom]
        addTeardownBlock { all.forEach { RoomDraftStore.clear(for: $0) } }
        all.forEach { RoomDraftStore.save("draft \($0.storageKey)", for: $0) }

        RoomDraftStore.clearAll(forGateway: removed, otherGatewayIDs: [kept, lookalike])

        XCTAssertEqual(RoomDraftStore.load(for: removedRoom), "")
        XCTAssertEqual(RoomDraftStore.load(for: removedLegacy), "")
        XCTAssertFalse(RoomDraftStore.load(for: keptRoom).isEmpty)
        XCTAssertFalse(RoomDraftStore.load(for: lookalikeRoom).isEmpty,
                       "a gateway whose id extends the removed id is not the removed gateway")

        // And through the real removal path.
        RoomDraftStore.save("delayed write", for: removedRoom)
        XCTAssertEqual(RoomDraftStore.load(for: removedRoom), "")
        RoomDraftStore.allowWrites(forGateway: removed)
        RoomDraftStore.save("again", for: removedRoom)
        try await environment.removeGateway(removed)
        XCTAssertEqual(RoomDraftStore.load(for: removedRoom), "")
        XCTAssertFalse(RoomDraftStore.load(for: keptRoom).isEmpty)
    }

    func testRemoveGatewayDeletesBridgedRoomsWithAMemberOnIt() async throws {
        let url = tempURL()
        let bridged = BridgedRooms.Store(url: url)
        func member(_ gateway: GatewayID) -> BridgedRooms.MemberRef {
            BridgedRooms.MemberRef(
                gatewayID: gateway.rawValue, profile: "default", displayName: "Bot",
                routeID: "\(gateway.rawValue)#default")
        }
        let mixed = BridgedRooms.RoomRecord(
            roomKey: "mixed", name: "Mixed", members: [member(removed), member(kept)], createdAt: 1,
            events: [BridgedRooms.EventRecord(
                seq: 1, eventID: "e1", kind: "message", actorKind: "member", actorID: "x",
                payloadText: "synthetic reply", createdAt: 1)])
        let keptOnly = BridgedRooms.RoomRecord(
            roomKey: "kept-only", name: "Kept", members: [member(kept)], createdAt: 1)
        try await bridged.upsert(mixed)
        try await bridged.upsert(keptOnly)
        let environment = await makeEnvironment(
            cache: try SwiftDataCacheStore.makeInMemory(), bridgedStoreURL: url)
        let mixedID = room(BridgedRooms.gatewayScope, "mixed")
        addTeardownBlock { RoomDraftStore.clear(for: mixedID) }
        RoomDraftStore.save("bridged draft", for: mixedID)

        try await environment.removeGateway(removed)

        let remaining = await BridgedRooms.Store(url: url).roomsSnapshot().map(\.roomKey)
        XCTAssertEqual(remaining, ["kept-only"])
        XCTAssertEqual(RoomDraftStore.load(for: mixedID), "")
        RoomDraftStore.save("late bridged draft", for: mixedID)
        XCTAssertEqual(RoomDraftStore.load(for: mixedID), "")
    }

    func testFailedPurgeIsRecordedAndDoesNotBlockRemoval() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        let recorder = DiagnosticsRecorder()
        let environment = await makeEnvironment(
            cache: PurgeFailingCache(base: store), recorder: recorder)

        try await environment.removeGateway(removed)

        XCTAssertEqual(environment.gateways.map(\.id), [kept],
                       "a purge failure must not leave the gateway half-removed")
        let entries = recorder.snapshot()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.category, "Gateway removal")
        XCTAssertTrue(entries.first?.detail.contains("purge failed") == true)
        XCTAssertFalse(entries.first?.detail.contains("127.0.0.1") == true)
        XCTAssertFalse(entries.first?.detail.contains("synthetic-sensitive-error-payload") == true)
    }

    func testStoreWithoutPurgeSupportStillRemovesAndRecords() async throws {
        let recorder = DiagnosticsRecorder()
        let environment = await makeEnvironment(cache: LegacyCache(), recorder: recorder)

        try await environment.removeGateway(removed)

        XCTAssertEqual(environment.gateways.map(\.id), [kept])
        XCTAssertEqual(recorder.snapshot().count, 1,
                       "the default `.unsupported` purge is surfaced, not swallowed")
    }
}
