import XCTest
import FleetCore
@testable import FleetPersistence

final class FileInboxHistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var url: URL!
    private let gateway = GatewayID(rawValue: "gw-synthetic")
    private let now = Date(timeIntervalSince1970: 50_000_000)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(FileInboxHistoryStore.fileName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func item(_ n: Int, status: InboxStatus = .pending, updatedAt: Date? = nil) -> InboxItem {
        let agent = InboxAgentIdentity(gatewayID: gateway, gatewayLabel: "Synthetic", sessionID: "s1")
        return InboxItem(
            id: InboxItemID(gatewayID: gateway, sessionID: "s1", requestID: "r\(n)"),
            kind: .approval,
            requestID: "r\(n)",
            status: status,
            agent: agent,
            context: InboxContext(command: "echo synthetic", choices: ["once", "deny"]),
            serverRequestID: "srq-\(n)",
            createdAt: now,
            updatedAt: updatedAt ?? now)
    }

    private func record(_ n: Int, age: TimeInterval = 0) -> InboxDecisionRecord {
        InboxDecisionRecord(
            itemID: InboxItemID(rawValue: "i\(n)"), kind: .approval, action: .approveOnce,
            gatewayID: gateway, sessionID: "s1", agentLabel: "Synthetic",
            decider: .thisDevice(ownerName: nil), decidedAt: now.addingTimeInterval(-age),
            outcome: .succeeded)
    }

    private func store(clock: Date? = nil) -> FileInboxHistoryStore {
        let fixed = clock ?? now
        return FileInboxHistoryStore(url: url, now: { fixed })
    }

    func testMissingFileLoadsEmpty() async {
        let loaded = await store().load()
        XCTAssertEqual(loaded, .empty)
    }

    func testRoundTripsItemsAndAuditAndExcludesFromBackup() async throws {
        let state = InboxPersistedState(items: [item(1), item(2, status: .approved)], audit: [record(1)])
        try await store().save(state)
        XCTAssertTrue(BackupExclusion.isExcluded(url))
        let reloaded = await store().load()
        XCTAssertEqual(reloaded, state)
    }

    func testCorruptFileFailsSoftToEmpty() async throws {
        try Data("not json".utf8).write(to: url)
        let loaded = await store().load()
        XCTAssertEqual(loaded, .empty)
    }

    func testAuditIsCappedByCountOnSave() async throws {
        let audit = (0..<(InboxLedger.maxAuditRecords + 25)).map { record($0, age: TimeInterval($0)) }
        try await store().save(InboxPersistedState(audit: audit))
        let reloaded = await store().load()
        XCTAssertEqual(reloaded.audit.count, InboxLedger.maxAuditRecords)
        XCTAssertEqual(reloaded.audit.first?.decidedAt, now)
    }

    func testAuditOlderThanRetentionIsDroppedOnLoad() async throws {
        try await store().save(InboxPersistedState(audit: [record(1, age: 0), record(2, age: InboxLedger.auditRetention + 60)]))
        // Load a clock 30 days later: the record from `now` sits exactly at
        // the window edge (kept); the one 60 seconds older than the window is dropped.
        let later = now.addingTimeInterval(InboxLedger.auditRetention)
        let reloaded = await store(clock: later).load()
        XCTAssertEqual(reloaded.audit.map(\.itemID.rawValue), ["i1"])
    }

    func testHistoryItemsOlderThanRetentionAreDroppedPendingKept() async throws {
        let old = now.addingTimeInterval(-InboxLedger.auditRetention - 60)
        let state = InboxPersistedState(items: [
            item(1, status: .pending, updatedAt: old),
            item(2, status: .denied, updatedAt: old),
        ])
        try await store().save(state)
        let reloaded = await store().load()
        XCTAssertEqual(reloaded.items.map(\.requestID), ["r1"])
    }

    func testFileNeverContainsAnswerText() async throws {
        // The persisted types have no field for an answer value. A decision
        // record for an answer keeps only the action name.
        let answered = InboxDecisionRecord(
            itemID: InboxItemID(rawValue: "x"), kind: .secret, action: InboxDecisionAction(.answer("SYNTHETIC-VALUE-123")),
            gatewayID: gateway, sessionID: "s1", agentLabel: "Synthetic",
            decider: .thisDevice(ownerName: nil), decidedAt: now, outcome: .succeeded)
        try await store().save(InboxPersistedState(audit: [answered]))
        let bytes = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(bytes.contains("SYNTHETIC-VALUE-123"))
    }
}
