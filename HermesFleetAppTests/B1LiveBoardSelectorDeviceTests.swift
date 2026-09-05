import XCTest
@testable import HermesFleetApp
import FleetCore
import FleetUI

/// B1 QA (t_a0ca4856) — INDEPENDENT live verification of the board selector
/// on Tony's physical iPhone (build-22 code, Debug) against the REAL gateway
/// the phone's app already has registered (mac-fleet tunnel over HTTPS),
/// hosted in the unit-test bundle so it signs with the app profile
/// (headless xctrunner provisioning wall — same pattern as
/// F1LiveATSProbeTests).
///
/// Rides the REAL production stack end-to-end: the app's actual gateway
/// registry + Keychain credentials + FleetServiceGraph kanban watcher
/// factory (GatewayAuthenticator → PasswordLoginClient → WS ticket →
/// KanbanEventStreamClient) → KanbanBoardViewModel.
///
/// LOGIN-RATE PACING: the gateway rate-limits password logins (10 per 60s
/// per surface) and the client resolves credentials FRESH per request by
/// design ("snapshot fetches are infrequent"). This test therefore runs in
/// paced phases: at most one live VM at a time, VMs stopped during pauses,
/// ~70s pauses between phases so each phase's login burst fits the budget.
/// (First run failed mid-test on HTTP 429 — test amplification, not a
/// product defect.)
///
/// Asserts the B1 acceptance surface:
///   1. fetchBoards returns the gateway's REAL boards incl. active slug.
///   2. Unpinned snapshot targets the ACTIVE board (its real cards).
///   3. selectBoard re-targets the snapshot; the re-opened stream goes Live.
///   4. selectBoard(nil) restores the active board's content.
///   5. Selection persists; relaunch (fresh VM, same defaults) restores it.
///   6. Unknown persisted slug → falls back to active board, persist cleared.
#if !targetEnvironment(simulator)
@MainActor
final class B1LiveBoardSelectorDeviceTests: XCTestCase {

    // Real boards on the live gateway (verified via GET /boards from QA).
    private static let activeSlug = "hermes-fleet-r10"
    private static let activeName = "Hermes Fleet R10"     // is_current=true
    private static let otherSlug = "hermes-fleet-ios"
    private static let otherName = "Hermes Fleet for iOS"
    private static let activeCardFragment = "B1 board selector"
    /// Pause between phases so the gateway's 10/60s login limiter resets.
    private static let phasePause: TimeInterval = 70

    private var environment: AppEnvironment!

    override func setUpWithError() throws {
        environment = FleetServiceGraph.makeDefaultEnvironment()
    }

    /// A FRESH watcher per VM — `stop()` is terminal on the watcher (the
    /// board view rebinds a new model per appear), so each phase builds a
    /// new watcher exactly as the app does.
    private func makeWatcher() throws -> any KanbanBoardWatching {
        try XCTUnwrap(environment.makeKanbanWatcher(for: try makeGateway()))
    }

    private func makeGateway() throws -> FleetGateway {
        // Mirror the board view's rule but require a REAL endpoint — an
        // endpoint-less gateway yields the UnconfiguredKanbanWatcher stub.
        try XCTUnwrap(
            environment.gateways.first {
                $0.endpoint != nil && environment.makeKanbanWatcher(for: $0) != nil
            },
            "no registered gateway with an endpoint yields a kanban watcher")
    }

    func testLivePickerSwitchPersistenceAndFallback() async throws {
        await environment.load()
        try XCTAssertFalse(environment.gateways.isEmpty,
            "the app must have at least one registered gateway on this device")
        _ = try makeGateway()  // fails fast with a clear message if none

        let defaults = UserDefaults(suiteName: "b1-qa-live")!
        defaults.removePersistentDomain(forName: "b1-qa-live")
        defer { defaults.removePersistentDomain(forName: "b1-qa-live") }

        func freshVM() throws -> KanbanBoardViewModel {
            KanbanBoardViewModel(
                watcher: try makeWatcher(),
                selectionStore: KanbanBoardSelectionStore(defaults: defaults))
        }

        // ================= PHASE 1: boards list + active snapshot ==========
        let vm = try freshVM()
        try await vm.start()
        let boards = vm.boards
        try XCTAssertFalse(boards.isEmpty, "live gateway must list its boards")
        XCTAssertTrue(
            boards.contains { $0.slug == Self.activeSlug && $0.isCurrent },
            "the operator's active board must be flagged is_current (got: \(boards.map(\.slug)))")
        XCTAssertTrue(
            boards.contains { $0.slug == Self.otherSlug },
            "the second real board must be listed")
        XCTAssertTrue(
            vm.displayBoardName.contains(Self.activeName),
            "unpinned display name must be the active board (got: \(vm.displayBoardName))")

        try await waitUntil(timeout: 25) {
            vm.snapshot != nil && vm.snapshot?.totalCards ?? 0 > 0
        }
        let activeSnapshot = try XCTUnwrap(vm.snapshot)
        XCTAssertTrue(
            Self.allCards(activeSnapshot).contains { $0.title.contains(Self.activeCardFragment) },
            "active board snapshot must contain its real B1 card")
        XCTAssertNil(vm.selectedBoard, "fresh device must start unpinned")
        await vm.stop()

        // ================= PHASE 2: switch re-targets + stream Live ========
        try await pause()
        let vm2 = try freshVM()
        try await vm2.start()
        try await waitUntil(timeout: 25) { vm2.boards.isEmpty == false }
        await vm2.selectBoard(Self.otherSlug)
        XCTAssertEqual(vm2.selectedBoard, Self.otherSlug)
        try await waitUntil(timeout: 25) {
            vm2.snapshot != nil && vm2.snapshot?.columns.isEmpty == false
        }
        let switchedSnapshot = try XCTUnwrap(vm2.snapshot)
        XCTAssertFalse(
            Self.allCards(switchedSnapshot).contains { $0.title.contains(Self.activeCardFragment) },
            "switched snapshot must NOT contain the active board's card — client-side pinning must re-target the fetch")
        XCTAssertGreaterThan(
            switchedSnapshot.totalCards, 0,
            "switched board must return its own (non-empty) snapshot")
        try await waitUntil(timeout: 30) { vm2.streamPhase == .streaming }
        // Persistence write is part of selectBoard — verify the store itself.
        XCTAssertEqual(
            defaults.string(forKey: KanbanBoardSelectionStore.key),
            Self.otherSlug,
            "selectBoard must persist the pin per-device")
        await vm2.stop()

        // ================= PHASE 3: un-pin restores the active board =======
        try await pause()
        let vm3 = try freshVM()
        try await vm3.start()
        try await waitUntil(timeout: 25) { vm3.boards.isEmpty == false }
        // Relaunch restoration FIRST (the pin persisted from phase 2):
        XCTAssertEqual(
            vm3.selectedBoard, Self.otherSlug,
            "a fresh VM over the same per-device defaults must restore the pinned board")
        XCTAssertTrue(
            vm3.displayBoardName.contains(Self.otherName),
            "restored display name must be the pinned board (got: \(vm3.displayBoardName))")
        try await waitUntil(timeout: 25) {
            vm3.snapshot.map { snap in
                !Self.allCards(snap).contains { $0.title.contains(Self.activeCardFragment) }
            } ?? false
        }
        // Now un-pin: back to the operator's active board.
        await vm3.selectBoard(nil)
        XCTAssertNil(vm3.selectedBoard)
        try await waitUntil(timeout: 25) {
            vm3.snapshot.map { Self.allCards($0).contains {
                $0.title.contains(Self.activeCardFragment) } ?? false } == true
        }
        try await waitUntil(timeout: 30) { vm3.streamPhase == .streaming }
        await vm3.stop()

        // ================= PHASE 4: unknown persisted slug fallback =========
        try await pause()
        defaults.set("no-such-board-slug", forKey: KanbanBoardSelectionStore.key)
        let vm4 = try freshVM()
        try await vm4.start()
        XCTAssertNil(
            vm4.selectedBoard,
            "unknown persisted slug must fall back to the active board (no crash, no pin)")
        XCTAssertNil(
            defaults.string(forKey: KanbanBoardSelectionStore.key),
            "the stale persist must be cleared")
        try await waitUntil(timeout: 25) { vm4.boards.isEmpty == false }
        try await waitUntil(timeout: 25) {
            vm4.snapshot.map { Self.allCards($0).contains {
                $0.title.contains(Self.activeCardFragment) } ?? false } == true
        }
        await vm4.stop()
    }

    // MARK: Helpers

    /// All cards in a snapshot across columns (snapshot.cards(in:) is per-column).
    private static func allCards(_ snapshot: KanbanBoardSnapshot) -> [KanbanCard] {
        snapshot.columns.flatMap { snapshot.cards(in: $0) }
    }

    /// Login-limiter reset pause (no VM alive during it).
    private func pause(_ seconds: TimeInterval = B1LiveBoardSelectorDeviceTests.phasePause) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    private func waitUntil(
        timeout: TimeInterval, _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        if await condition() { return }
        XCTFail("condition not met within \(timeout)s")
    }
}
#endif
