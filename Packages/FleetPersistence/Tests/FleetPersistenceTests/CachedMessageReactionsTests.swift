import XCTest
import Foundation
import SwiftData
import FleetCore
@testable import FleetPersistence

/// R10-T2 — reactions survive the SwiftData transcript cache round trip
/// (nil stays nil; a reacted row reloads with its reaction list intact).
final class CachedMessageReactionsTests: XCTestCase {

    func testReactionsRoundTripThroughCache() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        let gateway = GatewayID(rawValue: "workstation")
        let history = SessionHistory(sessionID: "s-1", count: 2, messages: [
            SessionMessage(
                role: .user,
                text: "hello",
                rowID: "11",
                reactions: [MessageReaction(emoji: "👀", author: "user", at: 1.5)]),
            SessionMessage(
                role: .assistant,
                text: "hi",
                rowID: "12",
                reactions: nil),
        ])
        try await store.saveHistory(history, for: gateway)

        let loaded = try await store.loadHistory(sessionID: "s-1", for: gateway)
        XCTAssertEqual(loaded?.messages.count, 2)
        XCTAssertEqual(loaded?.messages[0].rowID, "11")
        XCTAssertEqual(loaded?.messages[0].reactions?.count, 1)
        XCTAssertEqual(loaded?.messages[0].reactions?.first?.emoji, "👀")
        XCTAssertEqual(loaded?.messages[0].reactions?.first?.author, "user")
        XCTAssertEqual(loaded?.messages[0].reactions?.first?.at, 1.5)
        XCTAssertNil(loaded?.messages[1].reactions, "no-reaction rows stay nil across the round trip")
    }

    func testEmptyReactionsListRoundTripsAsEmpty() async throws {
        let store = try SwiftDataCacheStore.makeInMemory()
        let gateway = GatewayID(rawValue: "workstation")
        let history = SessionHistory(sessionID: "s-2", count: 1, messages: [
            SessionMessage(role: .user, text: "cleared", rowID: "21", reactions: []),
        ])
        try await store.saveHistory(history, for: gateway)

        let loaded = try await store.loadHistory(sessionID: "s-2", for: gateway)
        // Empty (disclosed-none) is distinct from nil (not disclosed): a
        // row whose reaction was cleared keeps the honest empty state.
        XCTAssertEqual(loaded?.messages[0].reactions, [])
    }

    // (Legacy-row note: rows written before R10-T2 have no reactionsData
    // value; `reactionsData` is an additive optional column, and SwiftData's
    // lightweight migration + the nil-coalescing decode cover it — exercised
    // by the nil-reactions message in the round-trip test above, which
    // writes a row with nil reactionsData and reloads nil.)
}
