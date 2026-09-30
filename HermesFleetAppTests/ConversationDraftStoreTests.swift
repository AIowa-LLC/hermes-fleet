import XCTest
@testable import FleetUI
import FleetCore
import FleetPersistence

/// P0.4a: device-local persistence of unsent 1:1 conversation composer text.
final class ConversationDraftStoreTests: XCTestCase {
    private let ws = GatewayID(rawValue: "workstation")
    private let lab = GatewayID(rawValue: "lab")

    private func route(_ gateway: GatewayID, _ profile: String) -> Route {
        Route(gatewayID: gateway, profileSlug: ProfileSlug(rawValue: profile))
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("p04a-drafts-\(UUID().uuidString).json")
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            value = value.addingTimeInterval(seconds)
        }
    }

    private func store(
        _ url: URL, clock: Clock = Clock(Date(timeIntervalSince1970: 10_000)),
        debounce: TimeInterval = 60
    ) -> ConversationDraftStore {
        ConversationDraftStore(url: url, now: { clock.now }, debounce: debounce)
    }

    // MARK: restore

    func testDraftRestoresAcrossStoreReload() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = store(url)
        first.scheduleSave("half-written thought", route: route(ws, "default"), sessionID: "s1")
        first.flush()

        // A NEW store over the same file (app relaunch) restores it.
        let second = store(url)
        XCTAssertEqual(second.draft(route: route(ws, "default"), sessionID: "s1"), "half-written thought")
    }

    func testUnflushedDraftIsVisibleWithinTheSameProcess() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url)
        s.scheduleSave("typing", route: route(ws, "default"), sessionID: "s1")
        XCTAssertEqual(s.draft(route: route(ws, "default"), sessionID: "s1"), "typing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "debounced: nothing written yet")
    }

    func testDraftsAreSourceQualified() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url)
        s.scheduleSave("A", route: route(ws, "default"), sessionID: "s1")
        s.scheduleSave("B", route: route(lab, "default"), sessionID: "s1")
        s.scheduleSave("C", route: route(ws, "researcher"), sessionID: "s1")
        s.scheduleSave("D", route: route(ws, "default"), sessionID: "s2")
        s.flush()
        XCTAssertEqual(s.draft(route: route(ws, "default"), sessionID: "s1"), "A")
        XCTAssertEqual(s.draft(route: route(lab, "default"), sessionID: "s1"), "B")
        XCTAssertEqual(s.draft(route: route(ws, "researcher"), sessionID: "s1"), "C")
        XCTAssertEqual(s.draft(route: route(ws, "default"), sessionID: "s2"), "D")
        XCTAssertEqual(s.draft(route: route(ws, "default"), sessionID: "other"), "")
    }

    // MARK: clear

    func testClearRemovesDraftAndPersists() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url)
        s.scheduleSave("sent soon", route: route(ws, "default"), sessionID: "s1")
        s.flush()
        s.clear(route: route(ws, "default"), sessionID: "s1")
        XCTAssertEqual(s.draft(route: route(ws, "default"), sessionID: "s1"), "")
        XCTAssertEqual(store(url).draft(route: route(ws, "default"), sessionID: "s1"), "")
    }

    func testClearCancelsPendingDebouncedWrite() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url, debounce: 0.05)
        s.scheduleSave("about to send", route: route(ws, "default"), sessionID: "s1")
        s.clear(route: route(ws, "default"), sessionID: "s1")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(s.draft(route: route(ws, "default"), sessionID: "s1"), "",
                       "a stale debounce must not resurrect a sent draft")
        XCTAssertEqual(store(url).draft(route: route(ws, "default"), sessionID: "s1"), "")
    }

    func testFailedSendKeepsDraft() {
        // The view clears the store only when `send` returns true; on failure
        // it makes no store call, so the persisted draft must survive.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url)
        s.scheduleSave("retry me", route: route(ws, "default"), sessionID: "s1")
        s.flush()
        XCTAssertEqual(store(url).draft(route: route(ws, "default"), sessionID: "s1"), "retry me")
    }

    func testEmptyOrWhitespaceSaveRemovesEntry() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url)
        s.scheduleSave("text", route: route(ws, "default"), sessionID: "s1")
        s.flush()
        s.scheduleSave("  \n", route: route(ws, "default"), sessionID: "s1")
        s.flush()
        XCTAssertEqual(s.count, 0)
        XCTAssertEqual(store(url).draft(route: route(ws, "default"), sessionID: "s1"), "")
    }

    // MARK: debounce

    func testDebounceCoalescesAndEventuallyWrites() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url, debounce: 0.05)
        for prefix in ["h", "he", "hel", "hell", "hello"] {
            s.scheduleSave(prefix, route: route(ws, "default"), sessionID: "s1")
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store(url).draft(route: route(ws, "default"), sessionID: "s1"), "hello")
    }

    // MARK: pruning + bounds

    func testPruneRemovesOnlyTheRemovedGatewaysDrafts() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url)
        s.scheduleSave("keep", route: route(ws, "default"), sessionID: "s1")
        s.scheduleSave("drop", route: route(lab, "default"), sessionID: "s2")
        s.flush()
        s.scheduleSave("drop pending", route: route(lab, "default"), sessionID: "s3")
        s.prune(gatewayID: lab)
        XCTAssertEqual(s.draft(route: route(ws, "default"), sessionID: "s1"), "keep")
        XCTAssertEqual(s.draft(route: route(lab, "default"), sessionID: "s2"), "")
        XCTAssertEqual(s.draft(route: route(lab, "default"), sessionID: "s3"), "")
        XCTAssertEqual(store(url).count, 1)
    }

    func testPruneToRegisteredGateways() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url)
        s.scheduleSave("a", route: route(ws, "default"), sessionID: "s1")
        s.scheduleSave("b", route: route(lab, "default"), sessionID: "s1")
        s.flush()
        s.pruneToRegisteredGateways([ws.rawValue])
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.draft(route: route(ws, "default"), sessionID: "s1"), "a")
    }

    func testDraftsOlderThanThirtyDaysExpire() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = Clock(Date(timeIntervalSince1970: 50_000))
        let s = store(url, clock: clock)
        s.scheduleSave("old", route: route(ws, "default"), sessionID: "s1")
        s.flush()
        clock.advance(ConversationDraftStore.retentionInterval - 60)
        XCTAssertEqual(s.draft(route: route(ws, "default"), sessionID: "s1"), "old")
        clock.advance(120)
        XCTAssertEqual(s.draft(route: route(ws, "default"), sessionID: "s1"), "")
        // A later write also drops the expired entry from disk.
        s.scheduleSave("fresh", route: route(ws, "default"), sessionID: "s2")
        s.flush()
        XCTAssertEqual(store(url, clock: clock).count, 1)
    }

    func testEntryCountAndLengthAreBounded() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = Clock(Date(timeIntervalSince1970: 90_000))
        let s = store(url, clock: clock)
        for i in 0..<(ConversationDraftStore.maxEntries + 10) {
            clock.advance(1)
            s.scheduleSave("draft \(i)", route: route(ws, "default"), sessionID: "s\(i)")
            s.flush()
        }
        XCTAssertEqual(s.count, ConversationDraftStore.maxEntries)
        // Oldest evicted, newest kept.
        XCTAssertEqual(s.draft(route: route(ws, "default"), sessionID: "s0"), "")
        XCTAssertEqual(
            s.draft(route: route(ws, "default"), sessionID: "s\(ConversationDraftStore.maxEntries + 9)"),
            "draft \(ConversationDraftStore.maxEntries + 9)")

        s.scheduleSave(String(repeating: "x", count: ConversationDraftStore.maxCharacters + 500),
                       route: route(ws, "default"), sessionID: "long")
        s.flush()
        XCTAssertEqual(store(url, clock: clock).draft(route: route(ws, "default"), sessionID: "long").count,
                       ConversationDraftStore.maxCharacters)
    }

    func testRemoveAllDeletesFile() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url)
        s.scheduleSave("a", route: route(ws, "default"), sessionID: "s1")
        s.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        s.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(s.count, 0)
    }

    // MARK: protection + safety

    func testFileIsBackupExcludedAndProtected() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url)
        s.scheduleSave("sensitive", route: route(ws, "default"), sessionID: "s1")
        s.flush()
        // Re-assert after a second (atomic-replace) write.
        s.scheduleSave("sensitive 2", route: route(ws, "default"), sessionID: "s1")
        s.flush()
        let protection = CacheStoreProtection.read(from: url)
        XCTAssertEqual(protection.backupExcluded, true)
        // The simulator does not faithfully report per-file classes (see
        // ModuleBoundaryTests); assert data protection is on, not the class.
        XCTAssertNotNil(protection.fileProtection)
    }

    func testCorruptFileLoadsAsEmptyAndIsReplaced() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        let s = store(url)
        XCTAssertEqual(s.draft(route: route(ws, "default"), sessionID: "s1"), "")
        s.scheduleSave("new", route: route(ws, "default"), sessionID: "s1")
        s.flush()
        XCTAssertEqual(store(url).draft(route: route(ws, "default"), sessionID: "s1"), "new")
    }

    func testKeyMatchesContinueIndexConversationIdentity() {
        let r = route(ws, "default")
        XCTAssertEqual(ConversationDraftStore.key(route: r, sessionID: "s1"),
                       FleetContinueIndexStore.conversationID(route: r, sessionID: "s1"))
    }
}
