import XCTest
import SwiftData
import FleetCore
@testable import FleetPersistence

/// P0.3c: the whole SQLite family (directory, store, `-wal`, `-shm`) carries
/// backup exclusion, and protection is re-applied after the first write. The
/// iOS protection class is asserted in the hosted app test target; the macOS
/// host reports no class, so here backup exclusion is asserted exactly.
final class CacheStoreProtectionTests: XCTestCase {
    private var directory: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheStoreProtection-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("HermesFleetCache", isDirectory: true)
        storeURL = directory.appendingPathComponent("cache.store")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func gateway(_ id: String) -> StoredGatewayRecord {
        StoredGatewayRecord(
            id: id, displayName: id, endpoint: "https://\(id)",
            authConfiguration: GatewayAuthConfiguration(strategy: .sessionToken, credentialStored: true),
            authConfigured: true)
    }

    private func history() -> SessionHistory {
        SessionHistory(sessionID: "s1", count: 1, messages: [
            SessionMessage(role: .user, text: "synthetic transcript text", timestamp: 1, rowID: "r1"),
        ])
    }

    func testStoreDirectoryIsProtectedBeforeAnyFileExists() throws {
        _ = try SwiftDataCacheStore.openFileBackedContainer(storeURL: storeURL)
        XCTAssertEqual(CacheStoreProtection.read(from: directory).backupExcluded, true)
    }

    func testFileBackedStoreProtectsDirectoryStoreAndPresentSidecarsAfterWrite() async throws {
        let store = try SwiftDataCacheStore.makeFileBacked(storeURL: storeURL)
        try await store.saveHistory(history(), for: GatewayID(rawValue: "gw-a.example.invalid"))

        let verified = await store.verifyProtection()
        let report = try XCTUnwrap(verified)
        let roles = Set(report.entries.map(\.role))
        XCTAssertTrue(roles.isSuperset(of: ["directory", "store"]), "roles: \(roles)")
        for entry in report.entries {
            XCTAssertEqual(entry.attributes.backupExcluded, true, "\(entry.role) must be backup-excluded")
        }
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(report.isFullyProtected, report.diagnosticsDetail)
        let late = await store.lateProtectionFailureList()
        XCTAssertTrue(late.isEmpty)
        XCTAssertTrue(store.protectionFailures.isEmpty)
    }

    #if os(macOS)
    /// `isExcludedFromBackup` reads back true for any file under an excluded
    /// directory, so it cannot prove a SIDECAR was itself protected. On the
    /// macOS host the exclusion is an xattr on the file; check that directly.
    private func hasBackupExclusionXattr(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:com_apple_backup_excludeItem", nil, 0, 0, 0) >= 0
    }

    func testSidecarsCarryTheirOwnExclusionAfterTheFirstWrite() async throws {
        let store = try SwiftDataCacheStore.makeFileBacked(storeURL: storeURL)
        let sidecars = CacheStoreProtection.sidecarURLs(for: storeURL)
        // Whatever sidecar exists right after open is stripped, so the only
        // way it can carry the attribute again is the first-write re-apply.
        for sidecar in [sidecars.wal, sidecars.shm] where FileManager.default.fileExists(atPath: sidecar.path) {
            removexattr(sidecar.path, "com.apple.metadata:com_apple_backup_excludeItem", 0)
        }
        try await store.saveGatewayRecord(gateway("gw-a.example.invalid"))

        let wal = sidecars.wal
        try XCTSkipUnless(FileManager.default.fileExists(atPath: wal.path), "SQLite produced no -wal file")
        XCTAssertTrue(hasBackupExclusionXattr(wal), "the -wal sidecar is protected after the first write")
        XCTAssertTrue(hasBackupExclusionXattr(storeURL))
        XCTAssertTrue(hasBackupExclusionXattr(directory))
    }
    #endif

    func testOpenWithRecoveryProtectsTheWholeFamily() async throws {
        let result = try SwiftDataCacheStore.openWithRecovery(storeURL: storeURL)
        XCTAssertNil(result.recovery)
        XCTAssertTrue(result.store.protectionFailures.isEmpty)
        try await result.store.saveGatewayRecord(gateway("gw-a.example.invalid"))
        let verified = await result.store.verifyProtection()
        let report = try XCTUnwrap(verified)
        XCTAssertTrue(report.isFullyProtected, report.diagnosticsDetail)
    }

    func testRebuiltStoreAfterCorruptionIsProtected() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: storeURL)
        let result = try SwiftDataCacheStore.openWithRecovery(storeURL: storeURL)
        XCTAssertEqual(result.recovery?.outcome, .quarantinedAndRebuilt)
        try await result.store.saveGatewayRecord(gateway("gw-a.example.invalid"))
        let verified = await result.store.verifyProtection()
        let report = try XCTUnwrap(verified)
        XCTAssertTrue(report.isFullyProtected, report.diagnosticsDetail)
    }

    func testInMemoryStoreHasNothingToVerify() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        let report = await store.verifyProtection()
        XCTAssertNil(report)
        XCTAssertTrue(store.protectionFailures.isEmpty)
    }

    func testReportDiagnosticsDetailIsTypeOnly() {
        let failure = LocalFileProtection.Failure(role: "wal", error: CocoaError(.fileWriteNoPermission))
        let report = CacheStoreProtectionReport(
            entries: [.init(role: "store", attributes: .init(backupExcluded: false, fileProtection: nil))],
            failures: [failure])
        XCTAssertFalse(report.isFullyProtected)
        XCTAssertTrue(report.diagnosticsDetail.contains("store"))
        XCTAssertTrue(report.diagnosticsDetail.contains("wal"))
        XCTAssertFalse(report.diagnosticsDetail.contains("/"))
    }
}
