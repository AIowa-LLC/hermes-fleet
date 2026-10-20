import Foundation
import XCTest
@testable import FleetCore

final class LocalFileProtectionTests: XCTestCase {
    func testApplyAndReadBackPreserveBackupExclusion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-protection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.json")
        try Data("fixture".utf8).write(to: file)

        try LocalFileProtection.apply(to: file)

        XCTAssertEqual(LocalFileProtection.read(from: file).backupExcluded, true)
        #if os(iOS) && !targetEnvironment(simulator)
        XCTAssertEqual(LocalFileProtection.read(from: file).protectionClass,
                       FileProtectionType.complete.rawValue)
        #endif
    }

    func testReadBackRefreshesCachedResourceValues() throws {
        var file = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-protection-readback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("fixture".utf8).write(to: file)
        try LocalFileProtection.apply(to: file)
        XCTAssertEqual(LocalFileProtection.read(from: file).backupExcluded, true)

        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try file.setResourceValues(values)

        XCTAssertEqual(LocalFileProtection.read(from: file).backupExcluded, false)
    }

    func testFailedBestEffortReportsRoleAndErrorTypeWithoutPath() {
        let privatePathMarker = "private-path-\(UUID().uuidString)"
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(privatePathMarker, isDirectory: true)
            .appendingPathComponent("missing.json")
        let failure = LocalFileProtection.applyBestEffortReportingFailure(
            to: missing, role: "bridged-rooms")

        XCTAssertEqual(failure?.role, "bridged-rooms")
        XCTAssertFalse(failure?.errorType.isEmpty ?? true)
        XCTAssertFalse(failure?.diagnosticsDetail.contains(privatePathMarker) ?? true)
        XCTAssertFalse(failure?.diagnosticsDetail.contains(missing.path) ?? true)
    }
}
