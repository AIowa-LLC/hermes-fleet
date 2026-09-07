import XCTest
import FleetCore
@testable import FleetUI

/// U6 (Gold Fleet conversation re-skin): presentation-layer guards.
///
/// The visual re-skin itself is verified by apple-design review + the
/// deterministic scripted-fleet UI suites; these unit tests pin the ONE
/// behavioral addition U6 makes — `ConversationRow.timestamp` (display-only
/// authoring time carried from the gateway-stamped `SessionMessage`, never
/// fabricated) and its persistence round-trip through the cached transcript.
@MainActor
final class U6ConversationSkinTests: XCTestCase {

    // MARK: - row(from:) carries the gateway timestamp through

    func testRowFromMessageCarriesTimestampForUserAndAssistant() {
        let user = SessionMessage(role: .user, text: "hi", timestamp: 1_756_000_000, rowID: "r1")
        let assistant = SessionMessage(role: .assistant, text: "hello", timestamp: 1_756_000_001, rowID: "r2")

        let userRow = ConversationViewModel.row(from: user, id: "row-1")
        let assistantRow = ConversationViewModel.row(from: assistant, id: "row-2")

        XCTAssertEqual(userRow.kind, .user)
        XCTAssertEqual(userRow.timestamp, 1_756_000_000)
        XCTAssertEqual(assistantRow.kind, .assistant)
        XCTAssertEqual(assistantRow.timestamp, 1_756_000_001)
    }

    func testRowFromMessageTimestampIsNilWhenGatewayDidNotStamp() {
        // Live-streamed events build rows without a persisted timestamp — the
        // UI must omit the timestamp line, never invent one.
        let message = SessionMessage(role: .user, text: "live", rowID: "r3")
        let row = ConversationViewModel.row(from: message, id: "row-3")
        XCTAssertNil(row.timestamp)
    }

    // MARK: - SessionMessage default still stamps nothing (no fabricated time)

    func testSessionMessageWithoutExplicitTimestampStaysNil() {
        let message = SessionMessage(role: .assistant, text: "x")
        XCTAssertNil(message.timestamp)
    }

    // MARK: - Persisted-cache round trip keeps the timestamp

    func testCachedTranscriptRoundTripsTimestamp() throws {
        let stamp = 1_756_000_042.0
        let message = SessionMessage(role: .user, text: "cached", timestamp: stamp, rowID: "r-cached")

        // row(from:) — what hydrateFromCache/applyOpenedSession do.
        let row = ConversationViewModel.row(from: message, id: "row-c")
        XCTAssertEqual(row.timestamp, stamp)

        // sessionMessage(from:) — what persistTranscript does.
        let persisted = try XCTUnwrap(ConversationViewModel.sessionMessage(from: row))
        XCTAssertEqual(persisted.timestamp, stamp)
    }
}
