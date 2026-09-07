import XCTest
@testable import FleetCore

/// R10-T2 — `MessageReaction` / `MessageReactionTarget` /
/// `MessageReactionsSnapshot` domain tests (RED-first: written and run RED
/// before any implementation existed; the JSON decode halves live in
/// FleetNetworking next to `JSONValue` and are covered by wire tests).
///
/// Wire truth (hermes-agent tui_gateway, verified 2026-09-04):
/// - `message.react` (methods_session.py:1563): params
///   `{session_id, row_id? | newest_role in {user,assistant}, emoji}`,
///   optional `author in {user,agent}` (default "user"). Errors: 4023
///   row_id-or-newest_role required, 4024 emoji empty, 4025 author invalid,
///   4040 message not found / no message to react to yet, 4001 session not
///   found, 5007 db. Result `{row_id: Int, reactions: [...]}`.
/// - Retract semantics (hermes_state.set_message_reaction :13008):
///   re-sending the SAME emoji retracts; different emoji replaces;
///   emoji null clears.
/// - Read-back: `session.history` rows carry `display_metadata.reactions`
///   (hermes_state._rows_to_conversation :14153 forwards display_metadata →
///   server._history_to_messages :9936 forwards it on each message).
final class MessageReactionDomainTests: XCTestCase {

    // MARK: - Target resolution

    func testDurableTargetCarriesRowID() {
        let target = MessageReactionTarget.durable(rowID: "42")
        XCTAssertEqual(target.rowID, "42")
        XCTAssertNil(target.newestRole)
    }

    func testLiveTargetCarriesNewestRole() throws {
        let target = try XCTUnwrap(MessageReactionTarget(liveRole: "user"))
        XCTAssertNil(target.rowID)
        XCTAssertEqual(target.newestRole, "user")
    }

    func testLiveTargetRejectsInvalidRole() {
        XCTAssertNil(MessageReactionTarget(liveRole: "system"))
        XCTAssertNil(MessageReactionTarget(liveRole: "tool"))
        XCTAssertNil(MessageReactionTarget(liveRole: ""))
        XCTAssertNil(MessageReactionTarget(liveRole: "USER"))
    }

    // MARK: - Snapshot-merge semantics (optimistic update + server truth)

    func testSnapshotWithUserReactionAppliesOwnReaction() {
        let snapshot = MessageReactionsSnapshot(reactions: [])
        let applied = snapshot.applyingOwnReaction("👍")
        XCTAssertEqual(applied.ownEmoji, "👍")
        XCTAssertEqual(applied.reactions.map(\.emoji), ["👍"])
    }

    func testSnapshotApplyingDifferentEmojiReplacesOwn() {
        let snapshot = MessageReactionsSnapshot(reactions: [
            MessageReaction(emoji: "👍", author: "user"),
            MessageReaction(emoji: "🎉", author: "agent"),
        ])
        let applied = snapshot.applyingOwnReaction("❤️")
        XCTAssertEqual(applied.ownEmoji, "❤️")
        // The agent's reaction survives.
        XCTAssertEqual(applied.reactions.map(\.emoji).sorted(), ["❤️", "🎉"])
    }

    func testSnapshotApplyIsValueSemanticsNotMutation() {
        let snapshot = MessageReactionsSnapshot(reactions: [MessageReaction(emoji: "👍", author: "user")])
        _ = snapshot.applyingOwnReaction("❤️")
        XCTAssertEqual(snapshot.reactions.map(\.emoji), ["👍"], "applying must not mutate the receiver")
    }

    func testSnapshotClearingRemovesOnlyOwnReaction() {
        let snapshot = MessageReactionsSnapshot(reactions: [
            MessageReaction(emoji: "👍", author: "user"),
            MessageReaction(emoji: "🎉", author: "agent"),
        ])
        let cleared = snapshot.clearingOwnReaction()
        XCTAssertNil(cleared.ownEmoji)
        XCTAssertEqual(cleared.reactions.map(\.emoji), ["🎉"])
    }

    func testSnapshotAdoptsServerTruth() {
        let result = MessageReactionResult(
            rowID: "42",
            reactions: [MessageReaction(emoji: "❤️", author: "user")])
        let snapshot = MessageReactionsSnapshot(result)
        XCTAssertEqual(snapshot.ownEmoji, "❤️")
        XCTAssertEqual(snapshot.reactions.count, 1)
    }

    // MARK: - Palette

    func testPaletteIsSmallOrderedAndUnique() {
        let palette = MessageReactionPalette.standard
        XCTAssertLessThanOrEqual(palette.emojis.count, 6, "small Tapback-style palette")
        XCTAssertEqual(palette.emojis.count, Set(palette.emojis).count, "no duplicates")
        XCTAssertEqual(palette.emojis.first, "👍", "thumbs-up leads the palette")
    }
}
