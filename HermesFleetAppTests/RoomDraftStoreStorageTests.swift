import XCTest
import FleetCore
import FleetPersistence
@testable import FleetUI

/// Room drafts are private text: they live in a protected, backup-excluded
/// file, never in the unprotected UserDefaults plist.
@MainActor
final class RoomDraftStoreStorageTests: XCTestCase {
    private var fileURL: URL!
    private var defaults: UserDefaults!
    private let suite = "room-draft-tests-\(UUID().uuidString)"
    private let room = FleetRoomID(provenance: .hosted, gatewayID: GatewayID(rawValue: "gw-draft-test"), key: "r1")

    override func setUp() async throws {
        try await super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("room-drafts-\(UUID().uuidString).json")
        RoomDraftStore.useStoreURLForTesting(fileURL)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        RoomDraftStore.useStoreURLForTesting(
            FileManager.default.temporaryDirectory.appendingPathComponent("room-drafts-discard.json"))
        try? FileManager.default.removeItem(at: fileURL)
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    func testDraftIsPersistedToBackupExcludedFileNotUserDefaults() throws {
        RoomDraftStore.save("private words", for: room)
        RoomDraftStore.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(BackupExclusion.isExcluded(fileURL))
        XCTAssertNil(UserDefaults.standard.string(forKey: "fleet.room.draft.v1." + room.storageKey))

        // A fresh in-memory state re-reads the durable copy.
        RoomDraftStore.useStoreURLForTesting(fileURL)
        XCTAssertEqual(RoomDraftStore.load(for: room), "private words")
    }

    func testLegacyUserDefaultsDraftIsMigratedAndRemoved() throws {
        let legacyKey = "fleet.room.draft.v1." + room.storageKey
        UserDefaults.standard.set("old plaintext draft", forKey: legacyKey)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: legacyKey) }

        XCTAssertEqual(RoomDraftStore.load(for: room), "old plaintext draft")
        XCTAssertNil(UserDefaults.standard.string(forKey: legacyKey),
                     "the plaintext copy must be removed after migration")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testDraftLengthIsBounded() {
        RoomDraftStore.save(String(repeating: "x", count: RoomDraftStore.maxCharacters + 500), for: room)
        XCTAssertEqual(RoomDraftStore.load(for: room).count, RoomDraftStore.maxCharacters)
    }
}
