import XCTest
import SwiftData
import FleetCore
import FleetPersistence
@testable import FleetUI

/// P0.3c: privacy-bearing local files carry backup exclusion and the
/// `NSFileProtectionComplete` class. Asserted on iOS (hosted), where the
/// attributes are real; the macOS host cannot report a protection class.
///
/// The iOS Simulator does not faithfully honor per-file protection classes
/// (it can report its own default instead of the applied `.complete`), so the
/// class assertion is exact on a device and "a class is reported" on the
/// simulator, while backup exclusion — which the simulator does honor — is
/// asserted exactly everywhere.
@MainActor
final class FileProtectionTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileProtection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The shared assertion: backup-excluded exactly, protected class present
    /// (exactly `.complete` on a device).
    private func assertProtected(
        _ url: URL, _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let attributes = LocalFileProtection.read(from: url)
        XCTAssertEqual(attributes.backupExcluded, true, "\(label) must be backup-excluded", file: file, line: line)
        XCTAssertNotEqual(
            attributes.fileProtection, FileProtectionType.none.rawValue,
            "\(label) must not report an unprotected class", file: file, line: line)
        #if targetEnvironment(simulator)
        // The simulator reports a class for files (its default, not the applied
        // one) and none at all for directories, so only files can be checked.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            XCTAssertNotNil(
                attributes.fileProtection, "\(label) must report a protection class", file: file, line: line)
        }
        #else
        XCTAssertEqual(
            attributes.fileProtection, FileProtectionType.complete.rawValue,
            "\(label) must be NSFileProtectionComplete", file: file, line: line)
        #endif
    }

    // MARK: SwiftData cache family

    func testCacheStoreDirectoryStoreAndSidecarsAreProtectedAfterAWrite() async throws {
        let directory = root.appendingPathComponent("HermesFleetCache", isDirectory: true)
        let storeURL = directory.appendingPathComponent("cache.store")
        let store = try SwiftDataCacheStore.makeFileBacked(storeURL: storeURL)
        try await store.saveWatermark(
            SessionEventWatermark(sessionID: "s1", lastSeenSeq: 3),
            for: GatewayID(rawValue: "gw-a.example.invalid"))
        try await store.saveHistory(
            SessionHistory(sessionID: "s1", count: 1, messages: [
                SessionMessage(role: .user, text: "synthetic transcript text", timestamp: 1, rowID: "r1"),
            ]),
            for: GatewayID(rawValue: "gw-a.example.invalid"))

        assertProtected(directory, "store directory")
        assertProtected(storeURL, "store")
        let sidecars = CacheStoreProtection.sidecarURLs(for: storeURL)
        var presentSidecars = 0
        for (label, sidecar) in [("-wal", sidecars.wal), ("-shm", sidecars.shm)]
        where FileManager.default.fileExists(atPath: sidecar.path) {
            presentSidecars += 1
            assertProtected(sidecar, label)
        }
        XCTAssertGreaterThan(presentSidecars, 0, "WAL mode leaves at least one sidecar while the store is open")

        let verified = await store.verifyProtection()
        let report = try XCTUnwrap(verified)
        XCTAssertTrue(report.isFullyProtected, report.diagnosticsDetail)
        XCTAssertTrue(store.protectionFailures.isEmpty)
    }

    // MARK: Bridged rooms

    func testBridgedRoomsStoreIsProtectedAfterPersist() async throws {
        let url = root.appendingPathComponent(BridgedRooms.storeFileName)
        let store = BridgedRooms.Store(url: url)
        try await store.upsert(.init(roomKey: "room", name: "Room", members: [], createdAt: 1))
        assertProtected(url, "bridged rooms store")
        try await store.rename(roomKey: "room", to: "Renamed", at: 2)
        assertProtected(url, "bridged rooms store after an atomic rewrite")
    }

    func testLegacyBridgedRoomsSurviveAndGainProtection() async throws {
        let url = root.appendingPathComponent(BridgedRooms.storeFileName)
        let legacy = BridgedRooms.RoomRecord(roomKey: "legacy", name: "Legacy", members: [], createdAt: 5)
        try JSONEncoder().encode(["legacy": legacy]).write(to: url, options: .atomic)

        let store = BridgedRooms.Store(url: url)
        let keys = await store.roomsSnapshot().map(\.roomKey)

        XCTAssertEqual(keys, ["legacy"])
        assertProtected(url, "legacy bridged rooms store after load")
    }

    // MARK: Artifact staging

    private struct StubRetriever: ArtifactRetrieving {
        let gatewayID: GatewayID
        func retrieve(_ reference: ArtifactReference) async throws -> RetrievedArtifact {
            RetrievedArtifact(reference: reference, data: Data("synthetic-bytes".utf8), mimeType: "image/png")
        }
    }

    private func artifact(_ gateway: GatewayID, _ name: String) -> ArtifactReference {
        ArtifactReference(
            gatewayID: gateway, sessionID: "s-1", profile: "default",
            path: "/synthetic/cache/images/\(name)")
    }

    func testStagedShareFilesAreProtectedAndRemovedByClearAndRemoveAll() async throws {
        let store = ArtifactImageStore()
        let gateway = GatewayID(rawValue: "gw-protect.example.invalid")
        let retriever = StubRetriever(gatewayID: gateway)
        let first = artifact(gateway, "first.png")
        let second = artifact(gateway, "second.png")
        _ = await store.load(first, using: retriever)
        _ = await store.load(second, using: retriever)

        let firstURL = try XCTUnwrap(store.shareFileURL(for: first))
        let secondURL = try XCTUnwrap(store.shareFileURL(for: second))
        assertProtected(ArtifactImageStore.shareDirectory, "artifact staging directory")
        assertProtected(firstURL, "staged artifact")
        assertProtected(secondURL, "staged artifact")

        store.clear(gatewayID: gateway)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))

        _ = await store.load(first, using: retriever)
        let restaged = try XCTUnwrap(store.shareFileURL(for: first))
        assertProtected(restaged, "re-staged artifact")
        store.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: restaged.path))
    }

    // MARK: Room drafts

    private func draftStore(
        defaults: UserDefaults,
        reporter: (@Sendable (LocalFileProtection.Failure) -> Void)? = nil
    ) -> (RoomDraftFileStore, URL) {
        let url = root.appendingPathComponent("room-drafts-\(UUID().uuidString).json")
        return (RoomDraftFileStore(url: url, defaults: defaults, reporter: reporter), url)
    }

    private func suite() throws -> UserDefaults {
        let name = "room-drafts-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func room(_ gateway: String, _ key: String) -> FleetRoomID {
        FleetRoomID(provenance: .hosted, gatewayID: GatewayID(rawValue: gateway), key: key)
    }

    func testRoomDraftsLiveInAProtectedFileNotUserDefaults() throws {
        let defaults = try suite()
        let (store, url) = draftStore(defaults: defaults)
        let id = room("gw-a", "r1")

        store.save("unsent synthetic draft", for: id)

        XCTAssertEqual(store.load(for: id), "unsent synthetic draft")
        assertProtected(url, "room drafts file")
        XCTAssertTrue(
            defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix(RoomDraftFileStore.legacyKeyPrefix) },
            "a draft never reaches UserDefaults")
        // A fresh instance (relaunch) reads the same draft back.
        let relaunched = RoomDraftFileStore(url: url, defaults: defaults)
        XCTAssertEqual(relaunched.load(for: id), "unsent synthetic draft")
    }

    func testLegacyUserDefaultsDraftsMigrateOnceAndTheKeysAreDeleted() throws {
        let defaults = try suite()
        let id = room("gw-a", "r1")
        let other = room("gw-b", "r2")
        defaults.set("legacy draft", forKey: RoomDraftFileStore.legacyKeyPrefix + id.storageKey)
        defaults.set("other legacy", forKey: RoomDraftFileStore.legacyKeyPrefix + other.storageKey)
        defaults.set("keep", forKey: "unrelated")
        let (store, url) = draftStore(defaults: defaults)

        XCTAssertTrue(store.migrateLegacyDraftsIfNeeded())

        XCTAssertEqual(store.load(for: id), "legacy draft")
        XCTAssertEqual(store.load(for: other), "other legacy")
        XCTAssertNil(defaults.string(forKey: RoomDraftFileStore.legacyKeyPrefix + id.storageKey))
        XCTAssertNil(defaults.string(forKey: RoomDraftFileStore.legacyKeyPrefix + other.storageKey))
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep", "only draft keys are touched")
        assertProtected(url, "migrated room drafts file")

        // Once is once: a key written by an older build after migration is not
        // resurrected over a newer draft, and a second call is a no-op.
        store.save("newer draft", for: id)
        XCTAssertTrue(store.migrateLegacyDraftsIfNeeded())
        XCTAssertEqual(store.load(for: id), "newer draft")
    }

    func testMigrationKeepsTheLegacyKeysWhenTheFileCannotBeWritten() throws {
        let defaults = try suite()
        let id = room("gw-a", "r1")
        defaults.set("legacy draft", forKey: RoomDraftFileStore.legacyKeyPrefix + id.storageKey)
        // The destination's parent is a regular file, so the write must fail.
        let blocker = root.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let store = RoomDraftFileStore(
            url: blocker.appendingPathComponent("drafts.json"), defaults: defaults)

        XCTAssertFalse(store.migrateLegacyDraftsIfNeeded(), "an unwritable destination does not finish the move")
        XCTAssertEqual(
            defaults.string(forKey: RoomDraftFileStore.legacyKeyPrefix + id.storageKey), "legacy draft",
            "nothing is deleted until the drafts are durably written")
    }

    func testRoomDraftFacadeKeepsGatewayScopedClearing() throws {
        let defaults = try suite()
        let (store, _) = draftStore(defaults: defaults)
        let removed = GatewayID(rawValue: "gw-removed")
        let kept = GatewayID(rawValue: "gw-kept")
        let lookalike = GatewayID(rawValue: "gw-removed:8080")
        store.save("a", for: room(removed.rawValue, "r1"))
        store.save("b", for: room(kept.rawValue, "r1"))
        store.save("c", for: room(lookalike.rawValue, "r1"))

        store.clearAll(forGateway: removed, otherGatewayIDs: [kept, lookalike])

        XCTAssertEqual(store.load(for: room(removed.rawValue, "r1")), "")
        XCTAssertEqual(store.load(for: room(kept.rawValue, "r1")), "b")
        XCTAssertEqual(store.load(for: room(lookalike.rawValue, "r1")), "c")
    }

    func testRemoveAllClearsFileAndLegacyKeys() throws {
        let defaults = try suite()
        let id = room("gw-a", "r1")
        let (store, url) = draftStore(defaults: defaults)
        store.save("draft", for: id)
        defaults.set("late legacy", forKey: RoomDraftFileStore.legacyKeyPrefix + "x")

        store.removeAll()

        XCTAssertEqual(store.load(for: id), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(defaults.string(forKey: RoomDraftFileStore.legacyKeyPrefix + "x"))
    }
}
