import XCTest
import FleetCore
@testable import FleetNetworking

/// The 2^63 `Int(Double)` trap class, closed for the gateway-JSON integer
/// reads that were still unguarded: `ui_meta_revisions` (profiles.configure
/// receipt + edit outcome), the JSON-RPC `id`, and the modern
/// `profiles.list` counters/revisions.
///
/// `Double(Int.max)` rounds UP to exactly 2^63, so an inclusive
/// `n <= Double(Int.max)` upper bound is NOT safe: `Int(2^63)` traps with
/// "Double value cannot be converted to Int because the result would be
/// greater than Int.max" (Trace/BPT, exit 133 — reproduced on this
/// toolchain). Every conversion now goes through `JSONValue.boundedInt` /
/// `JSONValue.intValue`, whose upper bound is 2^63-EXCLUSIVE, and every
/// out-of-range degradation is pinned below (drop-the-entry, `?? 0`, or a
/// typed error — never an invented value a caller would act on).
final class JSONIntegerBoundaryTests: XCTestCase {

    /// 2^63 — the first Double that is NOT representable in `Int`.
    private static let twoPow63 = 9_223_372_036_854_775_808.0
    /// The largest Double below 2^63 (the ulp at this magnitude is 1024).
    private static let largestSafe = 9_223_372_036_854_775_808.0 - 1_024.0

    /// Decode through the SAME Foundation decoder the wire path uses, so the
    /// hostile literal really arrives as a `Double` (asserted per test).
    private static func json(_ raw: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }

    // MARK: - the shared conversion helper

    func testBoundedIntRejectsTheTwoToTheSixtyThreeBoundaryInsteadOfTrapping() {
        XCTAssertEqual(Double(Int.max), Self.twoPow63,
                       "Double(Int.max) IS 2^63 — that is the trap door")
        XCTAssertNil(JSONValue.boundedInt(Self.twoPow63),
                     "a value at 2^63 must decode to nil, never reach Int(_:)")
        XCTAssertNil(JSONValue.boundedInt(Self.twoPow63 * 2))
        XCTAssertNil(JSONValue.boundedInt(1e300))
        XCTAssertNil(JSONValue.boundedInt(.nan))
        XCTAssertNil(JSONValue.boundedInt(.infinity))
        XCTAssertNil(JSONValue.boundedInt(-.infinity))
        XCTAssertNil(JSONValue.boundedInt(-Self.twoPow63 - 2_048.0),
                     "the next representable Double below -2^63 is not representable either")
        XCTAssertEqual(JSONValue.boundedInt(-Self.twoPow63), Int.min)
        XCTAssertEqual(JSONValue.boundedInt(Self.largestSafe), Int(Self.largestSafe),
                       "the largest safe Double below 2^63 still converts exactly")
    }

    func testIntValueKeepsIntSemanticsForRepresentableNumbers() {
        XCTAssertEqual(JSONValue.number(0).intValue, 0)
        XCTAssertEqual(JSONValue.number(42).intValue, 42)
        XCTAssertEqual(JSONValue.number(2.9).intValue, 2, "truncates, exactly as Int(_:) did")
        XCTAssertEqual(JSONValue.number(-2.9).intValue, -2)
        XCTAssertNil(JSONValue.string("2").intValue)
        XCTAssertNil(JSONValue.null.intValue)
        XCTAssertNil(JSONValue.bool(true).intValue)
        XCTAssertNil(JSONValue.array([]).intValue)
        XCTAssertNil(JSONValue.object([:]).intValue)
    }

    // MARK: - profiles.configure receipt (GatewayBotModeClient.swift sites)

    func testConfigureReceiptDropsAnUnrepresentableRevisionWithoutTrapping() throws {
        let result = try Self.json(#"""
        {"ok":true,"applied":{"ui_meta":true,"ui_meta_revisions":{"hermes-bots":9223372036854775808,"hermes-bots-chat":7}}}
        """#)
        // Precondition: the hostile literal really is the trapping Double.
        XCTAssertEqual(result["applied"]?["ui_meta_revisions"]?["hermes-bots"]?.numberValue,
                       Self.twoPow63)

        let receipt = try GatewayBotModeClient.decodeConfigureReceipt(result)
        XCTAssertTrue(receipt.applied)
        XCTAssertEqual(receipt.newRevisions, ["hermes-bots-chat": 7],
                       "the unrepresentable revision is dropped per key; the readable one survives")
    }

    func testConfigureReceiptConflictAtTheBoundaryFailsTypedNeverSilently() throws {
        let result = try Self.json(#"""
        {"ok":false,"applied":{"ui_meta":false,"ui_meta_conflicts":{"hermes-bots":{"expected":9223372036854775808,"actual":7}}}}
        """#)
        // The conflict pair is unreadable, so the entry is dropped (the same
        // shape as a missing pair) and the receipt still fails TYPED — no
        // trap, no silent success.
        do {
            _ = try GatewayBotModeClient.decodeConfigureReceipt(result)
            XCTFail("expected a typed failure")
        } catch let error as BotModeProfileError {
            guard case .rpcFailed = error else {
                return XCTFail("expected rpcFailed for an unreadable conflict pair, got \(error)")
            }
        }
    }

    // MARK: - profiles.configure edit outcome (GatewayBotModeClient.swift sites)

    func testEditOutcomeDropsAnUnrepresentableRevisionWithoutTrapping() throws {
        let result = try Self.json(#"""
        {"applied":{"ui_meta":true,"ui_meta_revisions":{"hermes-bots":9223372036854775808,"hermes-bots-chat":4}}}
        """#)
        let outcome = try GatewayBotModeClient.decodeEditOutcome(
            result, edit: BotProfileEdit(metadata: BotModeMetadata()))
        XCTAssertEqual(outcome.newMetadataRevisions, ["hermes-bots-chat": 4],
                       "the unrepresentable revision is dropped per key")
        XCTAssertEqual(outcome.appliedSections, [.metadata])
        XCTAssertNil(outcome.metadataConflict)
    }

    func testEditOutcomeConflictAtTheBoundaryDegradesToZeroNotATrap() throws {
        let result = try Self.json(#"""
        {"applied":{"ui_meta":false,"ui_meta_conflicts":{"hermes-bots":{"expected":9223372036854775808,"actual":7}},"ui_meta_revisions":{"hermes-bots":7}}}
        """#)
        do {
            _ = try GatewayBotModeClient.decodeEditOutcome(
                result, edit: BotProfileEdit(metadata: BotModeMetadata()))
            XCTFail("expected metadataConflict")
        } catch let error as BotModeProfileError {
            guard case .metadataConflict(let revisions, let conflicts) = error else {
                return XCTFail("expected metadataConflict, got \(error)")
            }
            XCTAssertEqual(revisions["hermes-bots"], 7)
            XCTAssertEqual(conflicts["hermes-bots"]?.expected, 0,
                           "an unrepresentable expected degrades to this site's missing-value default")
            XCTAssertEqual(conflicts["hermes-bots"]?.actual, 7)
        }
    }

    // MARK: - JSON-RPC id (JSONRPCCodec.swift sites)

    func testJSONRPCCodecRejectsAnIDAtTheBoundaryInsteadOfTrapping() throws {
        // End-to-end through the real frame codec: a response whose id sits at
        // exactly 2^63 used to reach `Int(_:)` in decodeID and kill the
        // process. It must now be rejected like any other junk id.
        let response = #"{"jsonrpc":"2.0","id":9223372036854775808,"result":{"ok":true}}"#
        XCTAssertThrowsError(try JSONRPCCodec.decode(response)) { error in
            XCTAssertEqual(error as? JSONRPCError, .invalidRequest)
        }
        let request = #"{"jsonrpc":"2.0","id":9223372036854775808,"method":"session.list","params":{}}"#
        XCTAssertThrowsError(try JSONRPCCodec.decode(request)) { error in
            XCTAssertEqual(error as? JSONRPCError, .invalidRequest)
        }
        // The boundary is exclusive: the largest safe id still round-trips.
        let ok = #"{"jsonrpc":"2.0","id":9223372036854774784,"result":{}}"#
        guard case .response(let decoded) = try JSONRPCCodec.decode(ok) else {
            return XCTFail("expected a response frame")
        }
        XCTAssertEqual(decoded.id, .number(Int(Self.largestSafe)))
    }

    func testJSONRPCIDCodableDecodeRejectsAnIDAtTheBoundary() throws {
        // `JSONRPCID`'s own Codable init is a public decode path for the same
        // wire value; an unrepresentable id must fail the decode, never trap.
        let data = Data(#"{"jsonrpc":"2.0","id":9223372036854775808,"result":{}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(JSONRPCResponse.self, from: data)) { error in
            XCTAssertTrue(error is DecodingError,
                          "an unrepresentable id fails like any junk id, got \(error)")
        }
    }

    // MARK: - modern profiles.list decoding (ModernProfilesDecoder.swift sites)

    func testProfilesListBoundaryValuesDegradeWithoutTrapping() throws {
        let raw = #"""
        {"profiles":[{"name":"researcher","path":"/synthetic/home","is_default":false,"skill_count":9223372036854775808,"last_session":{"id":"ls-1","title":"t","preview":"p","started_at":1,"last_active":2,"message_count":9223372036854775808},"canonical_session":{"id":"reg-1","resolved_id":"tip-9","title":"Bot Chat","started_at":1,"last_active":2,"message_count":9223372036854775808},"ui_meta_revisions":{"hermes-bots":9223372036854775808,"hermes-bots-chat":5}}]}
        """#
        let json = try Self.json(raw)
        let decoded = try ModernProfilesDecoder.decode(json)
        let profile = try XCTUnwrap(decoded.profiles.first)

        XCTAssertEqual(profile.skillCount, 0,
                       "an unrepresentable count degrades to the missing-value default")
        XCTAssertEqual(profile.lastSession?.messageCount, 0)
        XCTAssertNil(profile.canonicalSession?.messageCount,
                     "an optional count reads as absent")
        XCTAssertEqual(profile.uiMetaRevisions?.revisions, ["hermes-bots-chat": 5],
                       "the hostile revision is dropped per key; the readable one survives")
        XCTAssertFalse(profile.uiMetaRevisions?.supportsCAS(key: "hermes-bots") ?? true,
                       "an unreadable revision must not read as CAS-supported")
        XCTAssertTrue(profile.uiMetaRevisions?.supportsCAS(key: "hermes-bots-chat") ?? false)
    }

    func testProfilesListNegativeAndFractionalRevisionsKeepTheirOldSemantics() throws {
        // The pre-existing non-negative filter (applied to the Double, so -0.5
        // is still rejected) and truncation are unchanged by the bound.
        let raw = #"""
        {"profiles":[{"name":"researcher","ui_meta_revisions":{"a":2.9,"b":-0.5,"c":-1,"d":0}}]}
        """#
        let decoded = try ModernProfilesDecoder.decode(try Self.json(raw))
        let profile = try XCTUnwrap(decoded.profiles.first)
        XCTAssertEqual(profile.uiMetaRevisions?.revisions, ["a": 2, "d": 0])
    }
}
