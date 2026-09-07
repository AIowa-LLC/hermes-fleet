import XCTest
import os
import FleetCore

/// H2 Connection health dashboard — accumulator unit tests.
///
/// Deterministic: a manual clock is injected into the accumulator so uptime /
/// reconnect / persistence semantics are asserted against exact timestamps,
/// never real sleeps.

/// In-memory `HealthStatsStoring` double (FleetCoreTests cannot import
/// FleetPersistence — this package depends only on FleetCore). Uses the
/// async-safe scoped `OSAllocatedUnfairLock` pattern (same as the transport's
/// `TransportStateBox`).
private final class InMemoryHealthStatsStore: HealthStatsStoring, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[String: GatewayHealthStats]>(initialState: [:])

    func saveHealthStats(_ stats: GatewayHealthStats, for gatewayID: GatewayID) async throws {
        lock.withLock { $0[gatewayID.rawValue] = stats }
    }
    func loadHealthStats(for gatewayID: GatewayID) async throws -> GatewayHealthStats? {
        lock.withLock { $0[gatewayID.rawValue] }
    }
    func deleteHealthStats(for gatewayID: GatewayID) async throws {
        lock.withLock { $0[gatewayID.rawValue] = nil }
    }
    var count: Int {
        lock.withLock { $0.count }
    }
}

/// A manual wall clock the accumulator reads through its injected `now`.
private final class ManualClock: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Date>(initialState: Date(timeIntervalSince1970: 1_700_000_000))

    func now() -> Date {
        lock.withLock { $0 }
    }
    func advance(seconds: TimeInterval) {
        lock.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

final class ConnectionHealthTests: XCTestCase {

    private let id = GatewayID(rawValue: "workstation")

    private func makeAccumulator(
        store: HealthStatsStoring,
        clock: ManualClock
    ) -> GatewayHealthStatsAccumulator {
        GatewayHealthStatsAccumulator(store: store, now: { clock.now() })
    }

    private func unwrapStats(_ stats: GatewayHealthStats?) throws -> GatewayHealthStats {
        try XCTUnwrap(stats)
    }

    // MARK: uptime + reconnect + last disconnect

    func testUptimeAccumulatesAndComputesPercentage() async throws {
        let store = InMemoryHealthStatsStore()
        let clock = ManualClock()
        let accumulator = makeAccumulator(store: store, clock: clock)

        // t0: connect; 30s of connected; disconnect; 10s down; reconnect.
        await accumulator.record(.connectStarted, for: id)
        await accumulator.record(.connected, for: id)
        clock.advance(seconds: 30)
        await accumulator.record(.disconnected(reason: "normal closure"), for: id)
        clock.advance(seconds: 10)
        await accumulator.record(.connectStarted, for: id)
        await accumulator.record(.connected, for: id)

        let stats = try unwrapStats(await accumulator.stats(for: id))
        XCTAssertEqual(stats.connectedMilliseconds, 30_000, "30s connected accumulated")
        XCTAssertEqual(stats.disconnectedMilliseconds, 10_000, "10s disconnected accumulated")
        XCTAssertEqual(stats.uptimePercentage, 75.0, accuracy: 0.01)
        XCTAssertEqual(stats.reconnectCount, 1, "re-establishment after the first connect")
        XCTAssertEqual(stats.lastDisconnectReason, "normal closure")
        XCTAssertEqual(stats.currentState, .online, "last event was connected")
        XCTAssertTrue(stats.hasObservations)
    }

    func testFirstConnectIsNotAReconnect() async throws {
        let accumulator = makeAccumulator(
            store: InMemoryHealthStatsStore(), clock: ManualClock())

        await accumulator.record(.connectStarted, for: id)
        await accumulator.record(.connected, for: id)

        let stats = try unwrapStats(await accumulator.stats(for: id))
        XCTAssertEqual(stats.reconnectCount, 0, "initial connect is not a reconnect")
    }

    func testFailedFirstHandshakeThenSuccessIsNotAReconnect() async throws {
        let clock = ManualClock()
        let accumulator = makeAccumulator(store: InMemoryHealthStatsStore(), clock: clock)

        // The production-reachable defect: the FIRST-ever connect attempt
        // fails before any `.connected` (gateway unreachable → transport
        // yields .connectStarted then .disconnected from a failed
        // handshake), then the retry succeeds. The failed window is real
        // downtime, but the eventual success is still the FIRST connect —
        // it must not be counted as a reconnect.
        await accumulator.record(.connectStarted, for: id)
        clock.advance(seconds: 5)
        await accumulator.record(.disconnected(reason: "unreachable"), for: id)
        clock.advance(seconds: 2)
        await accumulator.record(.connectStarted, for: id)
        await accumulator.record(.connected, for: id)

        let stats = try unwrapStats(await accumulator.stats(for: id))
        XCTAssertEqual(stats.reconnectCount, 0,
            "failed initial handshake is not an establishment; first success is not a reconnect")
        XCTAssertEqual(stats.connectedMilliseconds, 0, "no connected interval ever settled")
        XCTAssertEqual(stats.disconnectedMilliseconds, 2_000,
            "failed-handshake window is honest downtime")
        XCTAssertEqual(stats.lastDisconnectReason, "unreachable")
        XCTAssertEqual(stats.currentState, .online)
    }

    func testDisconnectWhileConnectingRecordsReasonWithoutUptime() async throws {
        let clock = ManualClock()
        let accumulator = makeAccumulator(store: InMemoryHealthStatsStore(), clock: clock)

        // A failed connect: start → never connected → disconnect.
        await accumulator.record(.connectStarted, for: id)
        clock.advance(seconds: 5)
        await accumulator.record(.disconnected(reason: "abnormal closure"), for: id)

        let stats = try unwrapStats(await accumulator.stats(for: id))
        XCTAssertEqual(stats.connectedMilliseconds, 0, "never connected → no uptime")
        XCTAssertEqual(stats.lastDisconnectReason, "abnormal closure")
        XCTAssertEqual(stats.currentState, .offline)
    }

    func testUptimeZeroWhenNoObservations() async throws {
        let accumulator = makeAccumulator(
            store: InMemoryHealthStatsStore(), clock: ManualClock())

        // No settled time observed (a ping alone creates the entry without
        // any connected/disconnected bucket time).
        await accumulator.record(.pingRTT(milliseconds: 5.0), for: id)
        let stats = try unwrapStats(await accumulator.stats(for: id))
        XCTAssertEqual(stats.uptimePercentage, 0)
        XCTAssertFalse(stats.hasObservations)

        // The default (never-observed) snapshot is also 0.
        XCTAssertEqual(GatewayHealthStats().uptimePercentage, 0)
        XCTAssertFalse(GatewayHealthStats().hasObservations)
    }

    // MARK: ping RTT

    func testPingRTTLastAndAverage() async throws {
        let accumulator = makeAccumulator(
            store: InMemoryHealthStatsStore(), clock: ManualClock())

        await accumulator.record(.connectStarted, for: id)
        await accumulator.record(.connected, for: id)
        await accumulator.record(.pingRTT(milliseconds: 12.5), for: id)
        await accumulator.record(.pingRTT(milliseconds: 7.5), for: id)

        let stats = try unwrapStats(await accumulator.stats(for: id))
        XCTAssertEqual(stats.lastPingRTTMilliseconds, 7.5)
        XCTAssertEqual(stats.averagePingRTTMilliseconds ?? 0, 10.0, accuracy: 0.001)
        XCTAssertEqual(stats.pingSampleCount, 2)
    }

    // MARK: persistence across accumulator instances (restart survival)

    func testPersistenceRoundTripAcrossInstances() async throws {
        let store = InMemoryHealthStatsStore()
        let clock = ManualClock()
        let first = makeAccumulator(store: store, clock: clock)

        // Session 1: connect, 30s up, disconnect, 10s down, reconnect.
        await first.record(.connectStarted, for: id)
        await first.record(.connected, for: id)
        clock.advance(seconds: 30)
        await first.record(.disconnected(reason: "going away"), for: id)
        clock.advance(seconds: 10)
        await first.record(.connectStarted, for: id)
        await first.record(.connected, for: id)
        await first.record(.pingRTT(milliseconds: 21.0), for: id)
        // Persisted after every record (assert the store holds the row).
        let loaded = try await store.loadHealthStats(for: id)
        let stored = try XCTUnwrap(loaded)
        XCTAssertEqual(stored.reconnectCount, 1)

        // Session 2: a FRESH accumulator over the same store (app restart).
        let second = makeAccumulator(store: store, clock: clock)
        await second.rehydrate(gatewayIDs: [id])

        let restored = try unwrapStats(await second.stats(for: id))
        XCTAssertEqual(restored.connectedMilliseconds, 30_000, "uptime survives restart")
        XCTAssertEqual(restored.disconnectedMilliseconds, 10_000)
        XCTAssertEqual(restored.reconnectCount, 1, "reconnect count survives restart")
        XCTAssertEqual(restored.lastDisconnectReason, "going away")
        XCTAssertEqual(restored.lastPingRTTMilliseconds, 21.0, "last RTT survives restart")
        XCTAssertEqual(restored.pingSampleCount, 1)
        // The timeline is frozen at rehydrate: no dead-interval back-fill.
        XCTAssertEqual(restored.uptimePercentage, 75.0, accuracy: 0.01)

        // The restored accumulator CONTINUES accumulating: reconnect (a
        // re-establishment after restart → reconnect count grows), stay up
        // 30s, then drop.
        clock.advance(seconds: 30)
        await second.record(.connectStarted, for: id)
        await second.record(.connected, for: id)
        clock.advance(seconds: 30)
        await second.record(.disconnected(reason: "abnormal closure"), for: id)
        let after = try unwrapStats(await second.stats(for: id))
        XCTAssertEqual(after.connectedMilliseconds, 60_000, "30s more connected after restart")
        XCTAssertEqual(after.reconnectCount, 2, "restart re-establishment counts as a reconnect")
        XCTAssertEqual(after.lastDisconnectReason, "abnormal closure")
    }

    func testRehydrateDoesNotBackfillDeadInterval() async throws {
        let store = InMemoryHealthStatsStore()
        let clock = ManualClock()
        let first = makeAccumulator(store: store, clock: clock)

        // Killed while connected: connect at t0, app dies, no disconnect event.
        await first.record(.connectStarted, for: id)
        await first.record(.connected, for: id)
        clock.advance(seconds: 100)

        // Restart: a fresh accumulator restores the persisted snapshot.
        let second = makeAccumulator(store: store, clock: clock)
        await second.rehydrate(gatewayIDs: [id])
        let restored = try unwrapStats(await second.stats(for: id))
        XCTAssertEqual(restored.connectedMilliseconds, 0, "dead interval is NOT claimed as uptime")
        XCTAssertEqual(restored.uptimePercentage, 0)

        // A disconnect arriving after restart must not charge the dead window.
        await second.record(.disconnected(reason: "abnormal closure"), for: id)
        let after = try unwrapStats(await second.stats(for: id))
        XCTAssertEqual(after.connectedMilliseconds, 0)
        XCTAssertEqual(after.disconnectedMilliseconds, 0, "restart window starts at rehydrate")
        XCTAssertEqual(after.lastDisconnectReason, "abnormal closure")
    }

    func testRehydrateOnlineSnapshotCountsNextReestablishmentAsReconnect() async throws {
        let store = InMemoryHealthStatsStore()
        let clock = ManualClock()
        let first = makeAccumulator(store: store, clock: clock)

        // Gateway reached .connected (hasConnectedOnce true), then the app
        // was killed mid-connection: the persisted snapshot has
        // currentState == .online but connectedMilliseconds == 0 (the
        // interval was never closed). Rehydrate must derive the flag from
        // `.online`, so the post-restart re-establishment counts as a
        // reconnect — matching the "survives restart" contract.
        await first.record(.connectStarted, for: id)
        await first.record(.connected, for: id)
        clock.advance(seconds: 100)

        let second = makeAccumulator(store: store, clock: clock)
        await second.rehydrate(gatewayIDs: [id])

        await second.record(.connectStarted, for: id)
        await second.record(.connected, for: id)

        let stats = try unwrapStats(await second.stats(for: id))
        XCTAssertEqual(stats.reconnectCount, 1,
            ".online persisted snapshot must carry hasConnectedOnce across restart")
        XCTAssertEqual(stats.connectedMilliseconds, 0,
            "dead interval not claimed; new interval starts after rehydrate")
    }

    func testRehydrateNeverClobbersLiveEntry() async throws {
        let store = InMemoryHealthStatsStore()
        let clock = ManualClock()
        let accumulator = makeAccumulator(store: store, clock: clock)

        // Live session: connected and accumulating.
        await accumulator.record(.connectStarted, for: id)
        await accumulator.record(.connected, for: id)
        clock.advance(seconds: 10)

        // A rehydrate for the same gateway (e.g. a registry reload while the
        // connection is live) must NOT replace the live entry with the
        // persisted (older) snapshot.
        await accumulator.rehydrate(gatewayIDs: [id])
        let stats = try unwrapStats(await accumulator.stats(for: id))
        XCTAssertEqual(stats.connectedMilliseconds, 0, "live entry has not been rehydrate-clobbered")
        XCTAssertEqual(stats.currentState, .online)
    }

    // MARK: forget / removal

    func testForgetRemovesAccumulatedAndPersistedStats() async throws {
        let store = InMemoryHealthStatsStore()
        let accumulator = makeAccumulator(store: store, clock: ManualClock())

        await accumulator.record(.connectStarted, for: id)
        await accumulator.record(.connected, for: id)
        let observed = await accumulator.stats(for: id)
        XCTAssertNotNil(observed)
        XCTAssertEqual(store.count, 1)

        await accumulator.forget(gatewayID: id)
        let afterForget = await accumulator.stats(for: id)
        XCTAssertNil(afterForget)
        XCTAssertEqual(store.count, 0, "persisted row deleted on removal")
    }

    func testMultipleGatewaysStayIndependent() async throws {
        let accumulator = makeAccumulator(
            store: InMemoryHealthStatsStore(), clock: ManualClock())
        let other = GatewayID(rawValue: "arch")

        await accumulator.record(.connectStarted, for: id)
        await accumulator.record(.connected, for: id)
        await accumulator.record(.disconnected(reason: "normal closure"), for: id)

        let m5 = try unwrapStats(await accumulator.stats(for: id))
        XCTAssertEqual(m5.reconnectCount, 0)
        let otherStats = await accumulator.stats(for: other)
        XCTAssertNil(otherStats, "unobserved gateway has no stats")

        let snapshot = await accumulator.snapshot()
        XCTAssertEqual(snapshot.count, 1)
    }
}
