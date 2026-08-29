import XCTest
import FleetCore

/// P4 (M6) — pure-domain tests for the reconnect/replay vocabulary:
/// `SessionEventWatermark`, `ReplayOutcome` and `ReplayError`. No network.
final class ReplayDomainTests: XCTestCase {

    // MARK: SessionEventWatermark

    func testWatermarkValue() {
        let w = SessionEventWatermark(sessionID: "s1", lastSeenSeq: 42)
        XCTAssertEqual(w.sessionID, "s1")
        XCTAssertEqual(w.lastSeenSeq, 42)
    }

    func testWatermarkEqualityAndHash() {
        let a = SessionEventWatermark(sessionID: "s1", lastSeenSeq: 42)
        let b = SessionEventWatermark(sessionID: "s1", lastSeenSeq: 42)
        let c = SessionEventWatermark(sessionID: "s2", lastSeenSeq: 42)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    // MARK: ReplayOutcome

    func testReplayOutcomeEquality() {
        XCTAssertEqual(ReplayOutcome.replayed(sessionID: "s1", count: 3),
                       ReplayOutcome.replayed(sessionID: "s1", count: 3))
        XCTAssertNotEqual(ReplayOutcome.replayed(sessionID: "s1", count: 3),
                          ReplayOutcome.replayed(sessionID: "s1", count: 4))
        XCTAssertEqual(ReplayOutcome.truncated(sessionID: "s1"),
                       ReplayOutcome.truncated(sessionID: "s1"))
        XCTAssertEqual(ReplayOutcome.epochChanged(from: "a", to: "b"),
                       ReplayOutcome.epochChanged(from: "a", to: "b"))
        XCTAssertNotEqual(ReplayOutcome.epochChanged(from: "a", to: "b"),
                          ReplayOutcome.epochChanged(from: "a", to: "c"))
        XCTAssertEqual(ReplayOutcome.nothingToReplay, ReplayOutcome.nothingToReplay)
        XCTAssertEqual(ReplayOutcome.failed(sessionID: "s", detail: "x"),
                       ReplayOutcome.failed(sessionID: "s", detail: "x"))
    }

    func testReplayOutcomeDebugSummary() {
        XCTAssertEqual(ReplayOutcome.replayed(sessionID: "s1", count: 3).debugSummary,
                       "replayed 3 event(s) for s1")
        XCTAssertTrue(ReplayOutcome.truncated(sessionID: "s1").debugSummary.contains("refetch history"))
        XCTAssertTrue(ReplayOutcome.epochChanged(from: "e1", to: "e2").debugSummary.contains("rehydrate"))
        XCTAssertEqual(ReplayOutcome.nothingToReplay.debugSummary, "nothing to replay")
    }

    // MARK: ReplayError

    func testReplayErrorDescriptions() {
        XCTAssertEqual(ReplayError.notConnected.errorDescription, "gateway not connected; cannot replay")
        XCTAssertTrue(ReplayError.malformedPayload("bad").errorDescription?.contains("bad") == true)
        XCTAssertTrue(ReplayError.rpcFailed("boom").errorDescription?.contains("boom") == true)
    }
}
