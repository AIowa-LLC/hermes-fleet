import XCTest
import SwiftData
import FleetCore
@testable import FleetPersistence

/// P0.4b: quarantine-and-rebuild when the cache store cannot be opened.
final class CacheStoreRecoveryTests: XCTestCase {
    private var directory: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheStoreRecovery-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("HermesFleetCache", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("cache.store")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func gateway(_ id: String, name: String) -> StoredGatewayRecord {
        StoredGatewayRecord(
            id: id, displayName: name, endpoint: "https://\(id)",
            authConfiguration: GatewayAuthConfiguration(strategy: .sessionToken, credentialStored: true),
            authConfigured: true)
    }

    /// Writes a healthy store with two saved gateways and one transcript.
    private func seedHealthyStore() async throws {
        let store = try SwiftDataCacheStore.makeFileBacked(storeURL: storeURL)
        try await store.saveGatewayRecord(gateway("gw-a.example.invalid", name: "Alpha"))
        try await store.saveGatewayRecord(gateway("gw-b.example.invalid", name: "Beta"))
        try await store.saveHistory(
            SessionHistory(sessionID: "s1", count: 1, messages: [
                SessionMessage(role: .user, text: "private transcript", timestamp: 1, rowID: "r1"),
            ]),
            for: GatewayID(rawValue: "gw-a.example.invalid"))
    }

    private func quarantineGenerations() throws -> [URL] {
        let root = SwiftDataCacheStore.quarantineDirectory(for: storeURL)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    }

    // MARK: Healthy path

    func testHealthyStoreOpensWithoutRecovery() async throws {
        try await seedHealthyStore()
        let result = try SwiftDataCacheStore.openWithRecovery(storeURL: storeURL)
        XCTAssertNil(result.recovery)
        let gateways = try await result.store.loadGatewayRecords()
        XCTAssertEqual(gateways.count, 2)
        XCTAssertTrue(try quarantineGenerations().isEmpty)
    }

    // MARK: Quarantine + salvage

    func testUnreadableStoreIsQuarantinedRebuiltAndGatewaysSalvaged() async throws {
        try await seedHealthyStore()

        let result = try SwiftDataCacheStore.openWithRecovery(
            storeURL: storeURL, faults: [.unreadablePrimaryStore])

        let report = try XCTUnwrap(result.recovery)
        XCTAssertEqual(report.outcome, .quarantinedAndRebuilt)
        XCTAssertEqual(report.registry, .salvaged(count: 2))
        XCTAssertTrue(report.notices.isEmpty, "a fully salvaged registry needs no notice")

        // Gateways survive; the transcript went with the quarantined file.
        let gateways = try await result.store.loadGatewayRecords()
        XCTAssertEqual(gateways.map(\.displayName), ["Alpha", "Beta"])
        XCTAssertEqual(gateways.first?.authConfiguration.strategy, .sessionToken)
        XCTAssertEqual(gateways.first?.authConfiguration.credentialStored, true)
        let history = try await result.store.loadHistory(
            sessionID: "s1", for: GatewayID(rawValue: "gw-a.example.invalid"))
        XCTAssertNil(history, "transcripts are not carried into the rebuilt store")

        // The rebuilt store is file-backed, protected, and usable.
        XCTAssertEqual(result.store.storeURL, storeURL)
        XCTAssertEqual(CacheStoreProtection.read(from: storeURL).backupExcluded, true)
        try await result.store.saveGatewayRecord(gateway("gw-c.example.invalid", name: "Gamma"))

        // The store directory itself is untouched (fresh-install detection).
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testQuarantinedFilesAreBackupExcludedAndScratchIsRemoved() async throws {
        try await seedHealthyStore()
        let result = try SwiftDataCacheStore.openWithRecovery(
            storeURL: storeURL, faults: [.unreadablePrimaryStore])
        XCTAssertNotNil(result.recovery)

        let root = SwiftDataCacheStore.quarantineDirectory(for: storeURL)
        XCTAssertEqual(CacheStoreProtection.read(from: root).backupExcluded, true)
        let generations = try quarantineGenerations()
        XCTAssertEqual(generations.count, 1, "only the timestamped generation remains (no scratch dir)")
        let generation = try XCTUnwrap(generations.first)
        XCTAssertEqual(CacheStoreProtection.read(from: generation).backupExcluded, true)

        let files = try FileManager.default.contentsOfDirectory(at: generation, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.lastPathComponent == "cache.store" })
        for file in files {
            XCTAssertEqual(
                CacheStoreProtection.read(from: file).backupExcluded, true,
                "\(file.lastPathComponent) must be backup-excluded")
        }
    }

    func testOnlyOneQuarantineGenerationIsKept() async throws {
        try await seedHealthyStore()
        _ = try SwiftDataCacheStore.openWithRecovery(
            storeURL: storeURL, faults: [.unreadablePrimaryStore],
            now: Date(timeIntervalSince1970: 1_700_000_000))
        let first = try quarantineGenerations()
        XCTAssertEqual(first.count, 1)

        _ = try SwiftDataCacheStore.openWithRecovery(
            storeURL: storeURL, faults: [.unreadablePrimaryStore],
            now: Date(timeIntervalSince1970: 1_700_000_900))
        let second = try quarantineGenerations()
        XCTAssertEqual(second.count, 1)
        XCTAssertNotEqual(first.first?.lastPathComponent, second.first?.lastPathComponent)
    }

    // MARK: Genuinely corrupt file

    func testCorruptStoreFileIsQuarantinedAndFreshStoreWorks() async throws {
        try Data("this is not a sqlite database".utf8).write(to: storeURL)

        let result = try SwiftDataCacheStore.openWithRecovery(storeURL: storeURL)

        let report = try XCTUnwrap(result.recovery)
        XCTAssertEqual(report.outcome, .quarantinedAndRebuilt)
        XCTAssertEqual(report.registry, .lost, "the registry could not be read from a corrupt file")
        XCTAssertTrue(report.notices.contains(.savedGatewaysNeedReadding))
        XCTAssertFalse(report.notices.contains(.runningWithoutLocalCache))

        try await result.store.saveGatewayRecord(gateway("gw-d.example.invalid", name: "Delta"))
        let loaded = try await result.store.loadGatewayRecords()
        XCTAssertEqual(loaded.map(\.displayName), ["Delta"])
        XCTAssertEqual(try quarantineGenerations().count, 1)
    }

    // MARK: Fallbacks

    func testFreshStoreFailureFallsBackToInMemoryWithoutTrapping() async throws {
        try await seedHealthyStore()
        let result = try SwiftDataCacheStore.openWithRecovery(
            storeURL: storeURL, faults: [.unreadablePrimaryStore, .freshFileBackedStore])

        let report = try XCTUnwrap(result.recovery)
        XCTAssertEqual(report.outcome, .inMemoryFallback)
        XCTAssertTrue(report.notices.contains(.runningWithoutLocalCache))
        XCTAssertNil(result.store.storeURL, "in-memory store has no file")
        let gateways = try await result.store.loadGatewayRecords()
        XCTAssertEqual(gateways.count, 2, "salvaged gateways still serve this session")
    }

    func testUnrecoverableFailureThrowsInsteadOfTrapping() throws {
        XCTAssertThrowsError(try SwiftDataCacheStore.openWithRecovery(
            storeURL: storeURL,
            faults: [.unreadablePrimaryStore, .freshFileBackedStore, .inMemoryStore])
        ) { error in
            let report = (error as? CacheOpenError)?.report
            XCTAssertEqual(report?.outcome, .inMemoryFallback)
        }
    }

    func testLockedStoreIsLeftUntouchedAndRunsInMemory() async throws {
        try await seedHealthyStore()
        // The seeding store closes asynchronously and SQLite checkpoints the
        // WAL into the store file on close. Wait for the bytes to settle so the
        // baseline is the final seeded state, not a mid-checkpoint snapshot.
        var before = try Data(contentsOf: storeURL)
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(25))
            let again = try Data(contentsOf: storeURL)
            if again == before { break }
            before = again
        }

        let result = try SwiftDataCacheStore.openWithRecovery(
            storeURL: storeURL, faults: [.unreadablePrimaryStore, .protectedDataUnavailable])

        let report = try XCTUnwrap(result.recovery)
        XCTAssertEqual(report.outcome, .storeLockedInMemory)
        XCTAssertEqual(report.registry, .nothingToRestore)
        XCTAssertTrue(report.notices.contains(.runningWithoutLocalCache))
        XCTAssertEqual(try Data(contentsOf: storeURL), before, "store file must not be touched")
        XCTAssertTrue(try quarantineGenerations().isEmpty)
    }

    // MARK: Redaction

    func testDiagnosticsDetailCarriesNoPathsOrNames() async throws {
        try await seedHealthyStore()
        let result = try SwiftDataCacheStore.openWithRecovery(
            storeURL: storeURL, faults: [.unreadablePrimaryStore])
        let detail = try XCTUnwrap(result.recovery).diagnosticsDetail

        XCTAssertFalse(detail.contains("/"), "no filesystem path")
        XCTAssertFalse(detail.contains(directory.lastPathComponent))
        XCTAssertFalse(detail.contains("gw-a"), "no hostnames")
        XCTAssertFalse(detail.contains("Alpha"), "no gateway names")
        XCTAssertTrue(detail.contains("InjectedCacheOpenFault"), "type-only cause")
    }
}
