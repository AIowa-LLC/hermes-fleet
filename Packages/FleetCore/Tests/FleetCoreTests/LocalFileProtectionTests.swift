import XCTest
@testable import FleetCore

/// P0.3c shared file-protection policy. Protection *classes* are an iOS
/// data-protection feature and are not enforced (or reported) on the macOS
/// host, so these tests assert backup exclusion exactly and leave the class
/// assertions to the hosted iOS test target.
final class LocalFileProtectionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-file-protection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testApplyExcludesFilesAndDirectoriesFromBackup() throws {
        let file = directory.appendingPathComponent("file.json")
        try Data("{}".utf8).write(to: file)
        XCTAssertNotEqual(LocalFileProtection.read(from: file).backupExcluded, true)

        try LocalFileProtection.apply(to: file)
        try LocalFileProtection.apply(to: directory)

        XCTAssertEqual(LocalFileProtection.read(from: file).backupExcluded, true)
        XCTAssertEqual(LocalFileProtection.read(from: directory).backupExcluded, true)
    }

    func testPrepareDirectoryCreatesAndProtects() throws {
        let nested = directory.appendingPathComponent("a/b", isDirectory: true)
        try LocalFileProtection.prepareDirectory(nested)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(LocalFileProtection.read(from: nested).backupExcluded, true)
    }

    func testAtomicRewriteReassertsBackupExclusion() throws {
        // An atomic write replaces the inode and drops the exclusion xattr;
        // `write` must put it back every time, not only on first creation.
        let file = directory.appendingPathComponent("rewrite.json")
        try LocalFileProtection.write(Data("one".utf8), to: file)
        XCTAssertEqual(LocalFileProtection.read(from: file).backupExcluded, true)
        try LocalFileProtection.write(Data("two".utf8), to: file)
        XCTAssertEqual(LocalFileProtection.read(from: file).backupExcluded, true)
        XCTAssertEqual(try Data(contentsOf: file), Data("two".utf8))
    }

    func testWriteFailureThrowsAndAttributeFailureIsTypedSeparately() throws {
        // A write into a directory that does not exist is a real failure (not a
        // protection `Failure`): callers must not mistake it for fail-soft.
        let missing = directory.appendingPathComponent("missing/file.json")
        XCTAssertThrowsError(try LocalFileProtection.write(Data("x".utf8), to: missing)) { error in
            XCTAssertFalse(error is LocalFileProtection.Failure)
        }
    }

    func testApplyBestEffortSkipsMissingFilesAndReportsNoFailure() throws {
        let present = directory.appendingPathComponent("present")
        try Data("x".utf8).write(to: present)
        let failures = LocalFileProtection.applyBestEffort(to: [
            ("present", present),
            ("absent", directory.appendingPathComponent("absent")),
        ])
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(LocalFileProtection.read(from: present).backupExcluded, true)
    }

    func testFailureDiagnosticsDetailIsTypeOnly() {
        struct SecretPathError: Error { let path = "/private/var/example/secret.json" }
        let failure = LocalFileProtection.Failure(role: "store", error: SecretPathError())
        XCTAssertEqual(failure.role, "store")
        XCTAssertEqual(failure.errorType, "SecretPathError")
        XCTAssertFalse(failure.diagnosticsDetail.contains("/"))
        XCTAssertFalse(failure.diagnosticsDetail.contains("secret.json"))
    }

    func testAttributesIsProtectedRequiresBackupExclusion() {
        XCTAssertFalse(LocalFileProtection.Attributes(backupExcluded: nil, fileProtection: nil).isProtected)
        XCTAssertFalse(LocalFileProtection.Attributes(backupExcluded: false, fileProtection: "x").isProtected)
        // An unreadable class (directories, simulator) is not evidence of
        // missing protection; an explicit "none" class is.
        XCTAssertTrue(LocalFileProtection.Attributes(backupExcluded: true, fileProtection: nil).isProtected)
        XCTAssertFalse(LocalFileProtection.Attributes(
            backupExcluded: true, fileProtection: FileProtectionType.none.rawValue).isProtected)
    }

    func testReadOfMissingFileIsNil() {
        let attributes = LocalFileProtection.read(from: directory.appendingPathComponent("nope"))
        XCTAssertNil(attributes.backupExcluded)
        XCTAssertNil(attributes.fileProtection)
    }
}
