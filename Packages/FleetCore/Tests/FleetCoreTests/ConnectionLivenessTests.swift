import XCTest
import FleetCore

/// t_a07ca37e — tiered heartbeat-freshness liveness windows (Hermex #227
/// pattern). The STANDARD constants must behave exactly as specified:
/// fresh below 12s of transport silence, escalation (checkDue) from 12s to
/// the reconnect window, stale (reconnect) at 18s — extended to 25s while a
/// tool call is mid-flight.
final class ConnectionLivenessTests: XCTestCase {

    private let timing = ConnectionLivenessTiming.standard

    private func snapshot(silenceSeconds: TimeInterval) -> ConnectionLivenessSnapshot {
        ConnectionLivenessSnapshot(
            lastFrameReceivedAt: ContinuousClock.Instant.now - Duration(seconds: silenceSeconds))
    }

    // MARK: standard constants are the specified 5/12/18/25

    func testStandardTimingConstants() {
        XCTAssertEqual(timing.checkingInterval, 5)
        XCTAssertEqual(timing.transportFreshInterval, 12)
        XCTAssertEqual(timing.reconnectInterval, 18)
        XCTAssertEqual(timing.runningToolReconnectInterval, 25)
    }

    // MARK: fresh window (<12s: provably alive)

    func testSilenceUnderFreshWindowIsFresh() {
        XCTAssertEqual(snapshot(silenceSeconds: 0).tier(timing: timing), .fresh)
        XCTAssertEqual(snapshot(silenceSeconds: 4.9).tier(timing: timing), .fresh)
        XCTAssertEqual(snapshot(silenceSeconds: 11.9).tier(timing: timing), .fresh)
        // Fresh regardless of a tool call in flight.
        XCTAssertEqual(snapshot(silenceSeconds: 11.9).tier(toolInFlight: true, timing: timing), .fresh)
    }

    // MARK: escalation window (12s..<18s / 25s: checkDue)

    func testSilencePastFreshWindowIsCheckDue() {
        XCTAssertEqual(snapshot(silenceSeconds: 12).tier(timing: timing), .checkDue)
        XCTAssertEqual(snapshot(silenceSeconds: 15).tier(timing: timing), .checkDue)
        XCTAssertEqual(snapshot(silenceSeconds: 17.9).tier(timing: timing), .checkDue)
    }

    // MARK: reconnect window (18s, or 25s while a tool call is mid-flight)

    func testSilenceAtReconnectWindowIsStale() {
        XCTAssertEqual(snapshot(silenceSeconds: 18).tier(timing: timing), .stale)
        XCTAssertEqual(snapshot(silenceSeconds: 60).tier(timing: timing), .stale)
    }

    func testToolInFlightExtendsReconnectWindowTo25s() {
        XCTAssertEqual(snapshot(silenceSeconds: 18).tier(toolInFlight: true, timing: timing), .checkDue)
        XCTAssertEqual(snapshot(silenceSeconds: 24.9).tier(toolInFlight: true, timing: timing), .checkDue)
        XCTAssertEqual(snapshot(silenceSeconds: 25).tier(toolInFlight: true, timing: timing), .stale)
    }

    // MARK: secondsSinceLastFrame

    func testSecondsSinceLastFrameComputesElapsed() {
        let now = ContinuousClock.Instant.now
        let snap = ConnectionLivenessSnapshot(lastFrameReceivedAt: now - .seconds(3))
        XCTAssertEqual(snap.secondsSinceLastFrame(now: now), 3, accuracy: 0.05)
        // Never negative (clock skew / same instant).
        XCTAssertEqual(snap.secondsSinceLastFrame(now: snap.lastFrameReceivedAt), 0, accuracy: 0.0001)
    }
}

extension Duration {
    /// Convenience: `Duration(seconds:)` accepts fractional seconds.
    fileprivate init(seconds: TimeInterval) {
        self = .milliseconds(Int64(seconds * 1000))
    }
}
