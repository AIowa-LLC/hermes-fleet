import XCTest
import FleetCore
@testable import FleetPersistence

final class FileConversationPinStoreTests: XCTestCase {
    private var directory: URL!
    private var url: URL!
    private var defaults: UserDefaults!
    private let suite = "pin-store-tests-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pin-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(FileConversationPinStore.fileName)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func pin(_ title: String, preview: String = "secret preview") -> FleetConversationPin {
        FleetConversationPin(
            identity: .group(canonicalID: "g-\(title)"), title: title, preview: preview,
            pinnedAt: Date(timeIntervalSince1970: 1))
    }

    func testRoundTripsAndExcludesFileFromBackup() async throws {
        let store = FileConversationPinStore(url: url, legacy: .suite(suite))
        try await store.savePins([pin("a")])
        XCTAssertTrue(BackupExclusion.isExcluded(url))
        let reloaded = try await FileConversationPinStore(url: url, legacy: .suite(suite)).loadPins()
        XCTAssertEqual(reloaded, [pin("a")])
    }

    func testMigratesLegacyDefaultsAndRemovesPlaintextCopy() async throws {
        let legacy = try JSONEncoder().encode([pin("old")])
        defaults.set(legacy, forKey: UserDefaultsConversationPinStore.storageKey)

        let pins = try await FileConversationPinStore(url: url, legacy: .suite(suite)).loadPins()

        XCTAssertEqual(pins, [pin("old")])
        XCTAssertNil(defaults.data(forKey: UserDefaultsConversationPinStore.storageKey),
                     "previews must not remain in the unprotected UserDefaults plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(BackupExclusion.isExcluded(url))
    }

    func testLegacyNeverOverwritesExistingProtectedPins() async throws {
        let store = FileConversationPinStore(url: url, legacy: .none)
        try await store.savePins([pin("new")])
        defaults.set(try JSONEncoder().encode([pin("old")]), forKey: UserDefaultsConversationPinStore.storageKey)

        let pins = try await FileConversationPinStore(url: url, legacy: .suite(suite)).loadPins()

        XCTAssertEqual(pins, [pin("new")])
        XCTAssertNil(defaults.data(forKey: UserDefaultsConversationPinStore.storageKey))
    }

    func testMissingFileLoadsEmpty() async throws {
        let pins = try await FileConversationPinStore(url: url, legacy: .suite(suite)).loadPins()
        XCTAssertTrue(pins.isEmpty)
    }
}
