import XCTest
@testable import FleetCore

/// Legacy → hosted continuation policy (diagnostic 2026-09-15, fix B).
///
/// Provenance facts these tests pin:
/// - The Desktop v3 projection keys rooms `id:<roomId>`; older rooms are
///   `name:<name>` (group-chat.ts roomKey()). Only the id-keyed generation
///   carries a durable id that can become the hosted `room_id` (IDENTIFIER_RE
///   compatible; upstream `_room_id` accepts it).
/// - A legacy member verifies against the gateway roster ONLY by profile
///   slug equality (durable identity). Display-name equality is not
///   identity. Cross-machine (ssh) members never verify against the local
///   roster — they need RoomLink, not a local profile.
final class LegacyRoomContinuationTests: XCTestCase {

    private func legacyRoom(
        key: String, members: [(name: String, connectionID: String?)] = []
    ) -> FleetRoom {
        FleetRoom(
            id: FleetRoomID(
                provenance: .desktopLegacy,
                gatewayID: GatewayID(rawValue: "workstation"),
                key: key),
            name: "Research Crew",
            members: members.map {
                FleetRoomMember(
                    name: $0.name,
                    handle: $0.name,
                    connectionID: $0.connectionID,
                    connectionLabel: $0.connectionID == "local" ? "This device" : "Arch (archlinux-1)",
                    sourceScoped: true)
            })
    }

    private func candidate(_ slug: String, display: String) -> RoomMemberCandidate {
        RoomMemberCandidate(
            route: Route(
                gatewayID: GatewayID(rawValue: "workstation"),
                profileSlug: ProfileSlug(rawValue: slug)),
            displayName: display)
    }

    // MARK: - durable hosted room id

    func testIDKeyedLegacyRoomYieldsBareRoomID() {
        let room = legacyRoom(key: "id:rmtxtyapg-nsd4n")
        XCTAssertEqual(
            LegacyRoomContinuation.durableHostedRoomID(for: room),
            "rmtxtyapg-nsd4n")
    }

    func testNameKeyedLegacyRoomHasNoDurableID() {
        // Older projection generation: `name:<name>` keys carry no durable
        // identity — fail closed (nil), never derive one from the name.
        let room = legacyRoom(key: "name:Research Crew")
        XCTAssertNil(LegacyRoomContinuation.durableHostedRoomID(for: room))
    }

    func testHostedRoomHasNoContinuationID() {
        // Continuation is a legacy-room-only flow; hosted rooms already
        // ARE the authority.
        let room = FleetRoom(
            id: FleetRoomID(
                provenance: .hosted,
                gatewayID: GatewayID(rawValue: "workstation"),
                key: "room-1"),
            name: "Hosted")
        XCTAssertNil(LegacyRoomContinuation.durableHostedRoomID(for: room))
    }

    // MARK: - member verification

    func testLocalMembersVerifyByProfileSlugAndDedupe() {
        // Two `default` entries (local + macbox ssh) + `apple` local:
        // only members with a LOCAL connection resolve against this
        // gateway's roster; duplicates by route collapse; order preserved.
        let room = legacyRoom(key: "id:r1", members: [
            ("default", "local"),
            ("apple", "local"),
            ("default", "macbook-m5"),
            ("researcher", "archlinux-1"),
        ])
        let roster = [
            candidate("researcher", display: "Deep Research"),
            candidate("default", display: "Hermes"),
            candidate("apple", display: "Apple Dev"),
            candidate("release", display: "Apple Release"),
        ]
        let result = LegacyRoomContinuation.verifiedCandidates(
            members: room.members, roster: roster)
        XCTAssertEqual(
            result.candidates.map(\.route.profileSlug.rawValue),
            ["default", "apple"])
        XCTAssertEqual(result.unresolved, ["researcher"])
    }

    func testDisplayNameMatchIsNotIdentity() {
        // A member named "Deep Research" must NOT match a bot whose
        // profile slug is "researcher" but whose DISPLAY name is
        // "Deep Research" — display equality is banned as identity.
        let room = legacyRoom(key: "id:r1", members: [("Deep Research", "local")])
        let roster = [candidate("researcher", display: "Deep Research")]
        let result = LegacyRoomContinuation.verifiedCandidates(
            members: room.members, roster: roster)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.unresolved, ["Deep Research"])
    }

    func testEmptyRosterResolvesNothing() {
        let room = legacyRoom(key: "id:r1", members: [("default", "local"), ("apple", "local")])
        let result = LegacyRoomContinuation.verifiedCandidates(
            members: room.members, roster: [])
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.unresolved, ["default", "apple"])
    }

    // MARK: - continuation readiness

    func testContinuationPlanRequiresDurableIDAndQuorum() {
        let idKeyed = legacyRoom(key: "id:r1", members: [("default", "local"), ("apple", "local")])
        let roster = [candidate("default", display: "Hermes"), candidate("apple", display: "Apple")]
        let ready = LegacyRoomContinuation.plan(for: idKeyed, roster: roster)
        XCTAssertEqual(ready.status, .ready)
        XCTAssertEqual(ready.roomID, "r1")

        let nameKeyed = legacyRoom(key: "name:Research Crew", members: [("default", "local"), ("apple", "local")])
        XCTAssertEqual(
            LegacyRoomContinuation.plan(for: nameKeyed, roster: roster).status,
            .missingDurableID)

        let thin = legacyRoom(key: "id:r2", members: [("default", "local"), ("ghost", "local")])
        let thinRoster = [candidate("default", display: "Hermes")]
        let thinPlan = LegacyRoomContinuation.plan(for: thin, roster: thinRoster)
        guard case .insufficientMembers(let resolved, let min) = thinPlan.status else {
            return XCTFail("expected insufficientMembers")
        }
        XCTAssertEqual(resolved, 1)
        XCTAssertEqual(min, RoomCreateDraft.minMembers)
        XCTAssertEqual(thinPlan.unresolvedMembers, ["ghost"])
    }
}
