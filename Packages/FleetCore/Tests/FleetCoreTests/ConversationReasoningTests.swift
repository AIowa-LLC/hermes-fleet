import XCTest
@testable import FleetCore

/// Dogfood r8 (reasoning slider) — the level model must match the gateway
/// wire EXACTLY: `hermes_constants.parse_reasoning_effort` accepts
/// none | minimal | low | medium | high (verified live 2026-09-20); anything
/// else is rejected server-side with 4002. The enum is the single source of
/// the five words Fleet ever puts on the wire.
final class ConversationReasoningTests: XCTestCase {

    // MARK: wire words

    func testRawValuesAreExactlyTheFiveAcceptedWireWords() {
        XCTAssertEqual(
            FleetReasoningLevel.allCases.map(\.rawValue),
            ["none", "minimal", "low", "medium", "high"],
            "rawValues must equal the gateway's accepted effort words in stop order"
        )
    }

    func testStopOrderIsLeastToMostThinking() {
        XCTAssertEqual(
            FleetReasoningLevel.allCases.map(\.stopIndex),
            Array(0..<5),
            "cases must be declared in stop order so stopIndex is monotonic"
        )
        XCTAssertTrue(FleetReasoningLevel.off.stopIndex < FleetReasoningLevel.minimal.stopIndex)
        XCTAssertTrue(FleetReasoningLevel.minimal.stopIndex < FleetReasoningLevel.low.stopIndex)
        XCTAssertTrue(FleetReasoningLevel.low.stopIndex < FleetReasoningLevel.medium.stopIndex)
        XCTAssertTrue(FleetReasoningLevel.medium.stopIndex < FleetReasoningLevel.high.stopIndex)
    }

    func testLabelsArePlainEnglishTitleCase() {
        XCTAssertEqual(FleetReasoningLevel.off.label, "None")
        XCTAssertEqual(FleetReasoningLevel.minimal.label, "Minimal")
        XCTAssertEqual(FleetReasoningLevel.low.label, "Low")
        XCTAssertEqual(FleetReasoningLevel.medium.label, "Medium")
        XCTAssertEqual(FleetReasoningLevel.high.label, "High")
    }

    // MARK: Codable round-trip (the wire word "none" is not the case name)

    func testCodableRoundTripsTheWireWords() throws {
        for level in FleetReasoningLevel.allCases {
            let data = try JSONEncoder().encode(level)
            XCTAssertEqual(
                String(data: data, encoding: .utf8),
                "\"\(level.rawValue)\"",
                "the persisted/wire form is the gateway word, never the case name"
            )
            let decoded = try JSONDecoder().decode(FleetReasoningLevel.self, from: data)
            XCTAssertEqual(decoded, level)
        }
        // The off case specifically: its case name is `off` but the coded
        // word is `none` — a Codable payload must carry the WIRE word.
        XCTAssertEqual(
            String(data: try JSONEncoder().encode(FleetReasoningLevel.off), encoding: .utf8),
            "\"none\""
        )
    }

    // MARK: ReasoningState (readback mapping)

    func testReasoningStateCarriesLevelRawValueAndDisplay() {
        let known = ReasoningState(level: .high, rawValue: "high", display: "show")
        XCTAssertEqual(known.level, .high)
        XCTAssertEqual(known.rawValue, "high")
        XCTAssertEqual(known.display, "show")

        // An unknown/custom readback (level nil) is a legal state: the chip
        // shows the raw string, the slider marks no stop.
        let unknown = ReasoningState(level: nil, rawValue: "ultra", display: nil)
        XCTAssertNil(unknown.level)
        XCTAssertEqual(unknown.rawValue, "ultra")
        XCTAssertNil(unknown.display)
    }

    func testReasoningStateEquality() {
        XCTAssertEqual(
            ReasoningState(level: .medium, rawValue: "medium", display: "hide"),
            ReasoningState(level: .medium, rawValue: "medium", display: "hide")
        )
        XCTAssertNotEqual(
            ReasoningState(level: .medium, rawValue: "medium", display: nil),
            ReasoningState(level: .medium, rawValue: "medium", display: "hide")
        )
    }

    // MARK: default

    func testDefaultLevelIsMedium() {
        XCTAssertEqual(FleetReasoningLevel.defaultLevel, .medium)
    }

    // MARK: fail-closed unsupported seam

    func testUnsupportedReasoningThrowsFailClosed() async {
        let seam = UnsupportedReasoning()
        do {
            _ = try await seam.reasoning(sessionID: "abc12345")
            XCTFail("read must throw, never pretend")
        } catch {}
        do {
            _ = try await seam.setReasoning(.high, sessionID: "abc12345")
            XCTFail("write must throw, never pretend")
        } catch {}
    }
}
