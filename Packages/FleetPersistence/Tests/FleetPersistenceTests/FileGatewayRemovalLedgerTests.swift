import XCTest
import FleetCore
@testable import FleetPersistence

/// The removal ledger is what makes an explicit Remove survive a force-quit
/// mid-removal, so it must persist across instances, hold identifiers only,
/// and fail CLOSED when unreadable (never report "no markers").
final class FileGatewayRemovalLedgerTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent(FileGatewayRemovalLedger.fileName) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-ledger-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testMarkerSurvivesANewInstance() async throws {
        let id = GatewayID(rawValue: "gw-one")
        try await FileGatewayRemovalLedger(url: url).markRemoving(id)

        let pending = try await FileGatewayRemovalLedger(url: url).pendingRemovals()
        XCTAssertEqual(pending, [id], "a marker must survive a relaunch")
    }

    func testClearRemovesOnlyThatMarkerAndDeletesTheEmptyFile() async throws {
        let one = GatewayID(rawValue: "gw-one"), two = GatewayID(rawValue: "gw-two")
        let ledger = FileGatewayRemovalLedger(url: url)
        try await ledger.markRemoving(one)
        try await ledger.markRemoving(two)

        try await ledger.clear(one)
        let afterOne = try await ledger.pendingRemovals()
        XCTAssertEqual(afterOne, [two])

        try await ledger.clear(two)
        let afterTwo = try await ledger.pendingRemovals()
        XCTAssertTrue(afterTwo.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try await ledger.clear(two)   // missing marker is a no-op
    }

    func testFileHoldsIdentifiersOnly() async throws {
        try await FileGatewayRemovalLedger(url: url).markRemoving(GatewayID(rawValue: "gw-one"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, "[\"gw-one\"]")
    }

    func testUnreadableLedgerFailsClosedInsteadOfReportingNoMarkers() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let ledger = FileGatewayRemovalLedger(url: url)

        do {
            _ = try await ledger.pendingRemovals()
            XCTFail("a corrupt ledger must not read as empty")
        } catch let error as GatewayRemovalLedgerError {
            XCTAssertEqual(error, .unavailable)
        }
        do {
            try await ledger.markRemoving(GatewayID(rawValue: "gw-one"))
            XCTFail("a corrupt ledger must not be silently overwritten")
        } catch let error as GatewayRemovalLedgerError {
            XCTAssertEqual(error, .unavailable)
            XCTAssertFalse("\(error)".contains(directory.lastPathComponent), "errors carry no paths")
        }
    }
}
