import XCTest
@testable import FleetCore

/// Boundary coverage for the 2^63 `Int(Double)` trap class on the
/// `hermes-bots-groups` v3 projection (`LegacyGroupProjectionDecoder`).
///
/// These run the REAL decode path — the two guarded reads live in
/// `FleetRoomProviding.swift` (room `revision`, name-keyed tombstone
/// `revision`), and a regression there would make this file trap exactly the
/// way the pre-fix tree did.
final class MetadataIntegerDecodeBoundaryTests: XCTestCase {
    private let gatewayID = GatewayID(rawValue: "gw")

    /// 2^63: one past `Int.max`, exactly representable as a `Double`, and the
    /// value that traps `Int(_:)` ("result would be greater than Int.max").
    private let twoToTheSixtyThree = 9_223_372_036_854_775_808.0
    /// The largest `Double` strictly below 2^63: 2^63 - 1024 =
    /// 9223372036854774784 (exact; hex 0x1.fffffffffffffp+62; the spacing of
    /// `Double` in the 2^62..2^63 binade is 1024).
    private let largestSafeBelowTwoToTheSixtyThree = 9_223_372_036_854_774_784.0

    /// Envelope with one name-keyed room ("Crew") and an optional name-keyed
    /// tombstone for it.
    private func envelope(
        roomRevision: Double?,
        tombstoneRevision: Double?
    ) -> MetadataValue {
        var room: [String: MetadataValue] = ["name": .string("Crew")]
        if let roomRevision { room["revision"] = .number(roomRevision) }
        var deleted: [String: MetadataValue] = [:]
        if let tombstoneRevision { deleted["name:Crew"] = .number(tombstoneRevision) }
        return .object([
            "version": .number(3),
            "rooms": .object(["name:Crew": .object(room)]),
            "deleted": .object(deleted),
        ])
    }

    func testRevisionAtTwoToTheSixtyThreeDegradesToZeroWithoutTrap() {
        let result = LegacyGroupProjectionDecoder.decode(
            gatewayID: gatewayID,
            metaValue: envelope(roomRevision: twoToTheSixtyThree, tombstoneRevision: nil))
        XCTAssertEqual(result.rooms.count, 1, "the room still decodes; only the revision degrades")
        XCTAssertEqual(result.rooms.first?.id.key, "name:Crew")
        XCTAssertEqual(result.rooms.first?.revision, 0,
                       "unrepresentable revision keeps the missing-value shape (?? 0)")
    }

    func testRevisionAtLargestSafeDoubleBelowTwoToTheSixtyThreeIsExact() {
        // Guard the fixture itself: the literal is 2^63 - 1024 exactly, and
        // still inside Int (Int.max is 2^63 - 1).
        XCTAssertEqual(largestSafeBelowTwoToTheSixtyThree, Double(Int.max - 1023))
        let result = LegacyGroupProjectionDecoder.decode(
            gatewayID: gatewayID,
            metaValue: envelope(roomRevision: largestSafeBelowTwoToTheSixtyThree, tombstoneRevision: nil))
        XCTAssertEqual(result.rooms.first?.revision, 9_223_372_036_854_774_784,
                       "the largest in-range Double keeps Int(_:) semantics exactly")
    }

    func testUnrepresentableTombstoneRevisionDoesNotSuppressRoom() {
        // Tombstone 2^63 against room revision 5: the tombstone read stays
        // absent, so the "tombstone suppresses room" comparison is skipped.
        // Clamping the tombstone to Int.max instead would have suppressed it.
        let result = LegacyGroupProjectionDecoder.decode(
            gatewayID: gatewayID,
            metaValue: envelope(roomRevision: 5, tombstoneRevision: twoToTheSixtyThree))
        XCTAssertEqual(result.rooms.count, 1)
        XCTAssertEqual(result.rooms.first?.revision, 5)
    }

    func testTombstoneAtLargestSafeRevisionStillSuppresses() {
        // The revision gate itself is unchanged: tombstone >= room revision
        // still suppresses, for the largest representable revision.
        let result = LegacyGroupProjectionDecoder.decode(
            gatewayID: gatewayID,
            metaValue: envelope(
                roomRevision: largestSafeBelowTwoToTheSixtyThree,
                tombstoneRevision: largestSafeBelowTwoToTheSixtyThree))
        XCTAssertEqual(result.rooms.count, 0)
    }

    func testNonFiniteRevisionsAndTombstonesDegradeWithoutTrap() {
        let nonFinite: [Double] = [.infinity, -.infinity, .nan]
        for value in nonFinite {
            let asRoomRevision = LegacyGroupProjectionDecoder.decode(
                gatewayID: gatewayID,
                metaValue: envelope(roomRevision: value, tombstoneRevision: nil))
            XCTAssertEqual(asRoomRevision.rooms.first?.revision, 0,
                           "non-finite revision (\(value)) degrades to 0, never traps")

            let asTombstone = LegacyGroupProjectionDecoder.decode(
                gatewayID: gatewayID,
                metaValue: envelope(roomRevision: 5, tombstoneRevision: value))
            XCTAssertEqual(asTombstone.rooms.count, 1,
                           "non-finite tombstone (\(value)) is skipped, never traps")
        }
    }

    func testRevisionAtIntMinStillDecodes() {
        // The lower bound is -2^63 INCLUSIVE; in-range values are untouched.
        let result = LegacyGroupProjectionDecoder.decode(
            gatewayID: gatewayID,
            metaValue: envelope(roomRevision: -twoToTheSixtyThree, tombstoneRevision: nil))
        XCTAssertEqual(result.rooms.first?.revision, Int.min)
    }

    func testMissingRevisionStillDefaultsToZero() {
        // The pre-existing missing-value shape is unchanged.
        let result = LegacyGroupProjectionDecoder.decode(
            gatewayID: gatewayID,
            metaValue: envelope(roomRevision: nil, tombstoneRevision: nil))
        XCTAssertEqual(result.rooms.first?.revision, 0)
    }
}