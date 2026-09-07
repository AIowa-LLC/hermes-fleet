import XCTest
@testable import FleetCore

/// TRUE BOTS MODE slice 4 — room chat domain tests: capability gates
/// (disabled mutations never issue writes), transcript projection from
/// durable events (typed failures / indeterminate), replay cache merge
/// (navigation/reconnect survival), create-draft 2-6 rule + frozen-roster
/// wire shape, and source-qualified member display (D18).
final class RoomChatDomainTests: XCTestCase {

    private func event(
        _ seq: Int, kind: String, actorKind: String = "member", actorID: String = "researcher",
        actorProfile: String? = "researcher", text: String? = nil, reason: String? = nil,
        at: Double = 1_757_200_000
    ) -> HostedRoomEventValue {
        HostedRoomEventValue(
            roomID: "room-alpha", seq: seq, eventID: "e\(seq)", kind: kind,
            actorKind: actorKind, actorID: actorID, actorProfile: actorProfile,
            payloadText: text, reasonCode: reason, createdAt: at)
    }

    private func page(_ events: [HostedRoomEventValue], cursor: Int, latest: Int,
                      hasMore: Bool = false) -> RoomLogPageSlice {
        RoomLogPageSlice(
            events: events, cursor: cursor, latestSeq: latest, hasMore: hasMore,
            authorityGatewayID: "install:abc", authorityEpoch: 3)
    }

    // MARK: - Capability gate: disabled never writes

    func testLegacyRoomCapabilitiesForbidEveryMutation() {
        let room = FleetRoom(
            id: FleetRoomID(provenance: .desktopLegacy, gatewayID: GatewayID(rawValue: "workstation"), key: "name:Research Crew"),
            name: "Research Crew")
        let caps = room.capabilities
        XCTAssertFalse(caps.canSend)
        XCTAssertFalse(caps.canRename)
        XCTAssertFalse(caps.canDisband)
        XCTAssertFalse(caps.canStop)
        XCTAssertFalse(caps.canRetry)
        XCTAssertFalse(caps.canApprove)
        XCTAssertFalse(caps.canReplay)
        XCTAssertFalse(caps.canManageMembers)
    }

    func testHostedCapabilitiesFollowAdvertisedMethods() {
        func hostedRoom(methods: [String]) -> FleetRoom {
            FleetRoom(
                id: FleetRoomID(provenance: .hosted, gatewayID: GatewayID(rawValue: "workstation"), key: "r1"),
                name: "R1",
                hosted: HostedRoomState(
                    authorityGatewayID: "install:abc", authorityEpoch: 1,
                    advertisedMethods: methods, driverAvailable: true))
        }
        let full = hostedRoom(methods: [
            "groups.send", "groups.rename", "groups.disband", "groups.stop",
            "groups.retry", "groups.approve", "groups.log", "groups.create"]).capabilities
        XCTAssertTrue(full.canSend && full.canRename && full.canDisband && full.canStop)
        XCTAssertTrue(full.canRetry && full.canApprove && full.canReplay && full.canManageMembers)

        let old = hostedRoom(methods: ["groups.list", "groups.state"]).capabilities
        XCTAssertFalse(old.canSend)
        XCTAssertFalse(old.canDisband)

        // Driver down: no execution mutation, replay can survive.
        let down = FleetRoom(
            id: FleetRoomID(provenance: .hosted, gatewayID: GatewayID(rawValue: "workstation"), key: "r2"),
            name: "R2",
            hosted: HostedRoomState(
                authorityGatewayID: "install:abc", authorityEpoch: 1,
                advertisedMethods: ["groups.send"], driverAvailable: false)).capabilities
        XCTAssertFalse(down.canSend)
        XCTAssertTrue(down.canReplay == false)
    }

    // MARK: - Transcript projection

    func testProjectionRendersMessagesAndTypedFailure() {
        let projection = RoomTranscriptProjection.project([
            event(1, kind: "room.created", actorKind: "system", actorID: "system"),
            event(2, kind: "message.user", actorKind: "user", actorID: "desktop", text: "hello team"),
            event(3, kind: "message.member", actorProfile: "researcher", text: "draft ready"),
            event(4, kind: "turn.failed", actorProfile: "researcher", text: "provider auth rejected",
                  reason: "provider_auth_or_access"),
            event(5, kind: "room.renamed", actorKind: "system", actorID: "system"),
        ])
        XCTAssertEqual(projection.entries.count, 3, "only messages + failures render")
        XCTAssertEqual(projection.entries[0].flavor, .message(isUser: true))
        XCTAssertEqual(projection.entries[1].speaker, "researcher")
        XCTAssertEqual(projection.entries[2].flavor, .failure)
        XCTAssertEqual(projection.latestFailure?.reason, .providerAuthOrAccess)
        XCTAssertFalse(projection.latestFailure!.reason.isAutoRetryable)
        XCTAssertNil(projection.indeterminateTaskID)
    }

    func testProjectionTracksIndeterminateAndStopRequested() {
        let projection = RoomTranscriptProjection.project([
            event(2, kind: "message.user", actorKind: "user", actorID: "desktop", text: "go"),
            event(3, kind: "turn.started", actorProfile: "researcher"),
            event(4, kind: "turn.deferred", actorProfile: "researcher", text: "task-77"),
            event(5, kind: "room.stop_requested", actorKind: "gateway", actorID: "gateway"),
        ])
        XCTAssertEqual(projection.indeterminateTaskID, "task-77")
        XCTAssertTrue(projection.stopRequested)
        XCTAssertEqual(projection.entries.count, 1)
    }

    func testProjectionSkipsUnknownKindsWithoutInventingRows() {
        let projection = RoomTranscriptProjection.project([
            event(2, kind: "future.kind", actorProfile: "x", text: "??"),
        ])
        XCTAssertTrue(projection.entries.isEmpty)
        XCTAssertNil(projection.latestFailure)
    }

    func testTypedFailureWireDecodingTolerant() {
        XCTAssertEqual(TypedBotFailure(wireReason: "target_busy").reason.rawValue, "unknown")
        XCTAssertEqual(TypedBotFailure(wireReason: "delivery_timeout").reason, .deliveryTimeout)
        XCTAssertTrue(BotFailureReason.targetBusyRawValue == "target_busy")
    }

    // MARK: - Replay cache (D17 support)

    func testReplayCacheMergesAndDeduplicates() {
        var cache = RoomTranscriptCache()
        XCTAssertTrue(cache.merge(page([
            event(1, kind: "message.user", actorKind: "user", actorID: "desktop", text: "a"),
            event(2, kind: "message.member", text: "b"),
        ], cursor: 2, latest: 2)))
        // Reconnect: same page replayed (idempotent) — no phantom entries.
        XCTAssertFalse(cache.merge(page([
            event(1, kind: "message.user", actorKind: "user", actorID: "desktop", text: "a"),
            event(2, kind: "message.member", text: "b"),
        ], cursor: 2, latest: 2)))
        XCTAssertTrue(cache.merge(page([
            event(3, kind: "message.member", text: "c"),
        ], cursor: 3, latest: 3)))
        XCTAssertEqual(cache.orderedEvents.map(\.seq), [1, 2, 3])
        XCTAssertEqual(cache.nextSinceSeq, 3)
        XCTAssertEqual(cache.latestSeq, 3)
    }

    func testReplayCacheSurvivesNavigationBySeqOrder() {
        var cache = RoomTranscriptCache()
        cache.merge(page([event(2, kind: "message.member", text: "b")], cursor: 2, latest: 2))
        cache.merge(page([event(1, kind: "message.user", actorKind: "user", actorID: "desktop", text: "a"),
                          event(3, kind: "message.member", text: "c")], cursor: 3, latest: 3))
        // Out-of-order pages still project in durable order.
        let projection = RoomTranscriptProjection.project(cache.orderedEvents)
        XCTAssertEqual(projection.entries.map { $0.text ?? "" }, ["a", "b", "c"])
    }

    // MARK: - Create draft (D15)

    private func candidate(_ slug: String, gateway: String = "workstation") -> RoomMemberCandidate {
        RoomMemberCandidate(
            route: Route(gatewayID: GatewayID(rawValue: gateway), profileSlug: ProfileSlug(rawValue: slug)),
            displayName: slug.capitalized)
    }

    func testCreateDraftValidationEnforcesTwoToSix() {
        var draft = RoomCreateDraft(name: "Launch Crew")
        XCTAssertEqual(draft.validationMessage, "Pick at least 2 members.")
        draft.toggle(candidate("researcher"))
        XCTAssertEqual(draft.validationMessage, "Pick at least 2 members.")
        draft.toggle(candidate("scribe"))
        XCTAssertNil(draft.validationMessage)
        XCTAssertTrue(draft.canSubmit)

        for slug in ["a", "b", "c", "d"] {
            draft.toggle(candidate(slug))
        }
        XCTAssertEqual(draft.members.count, 6)
        // The picker enforces the cap at input time — a full roster stays valid.
        XCTAssertNil(draft.validationMessage)

        draft = RoomCreateDraft(name: "   ", members: [candidate("a"), candidate("b")])
        XCTAssertEqual(draft.validationMessage, "Name the room.")
    }

    func testCreateDraftTogglePreservesPickOrder() {
        var draft = RoomCreateDraft(name: "R")
        draft.toggle(candidate("zeta"))
        draft.toggle(candidate("alpha"))
        XCTAssertEqual(draft.members.map(\.route.profileSlug.rawValue), ["zeta", "alpha"])
        draft.toggle(candidate("zeta"))
        XCTAssertEqual(draft.members.map(\.route.profileSlug.rawValue), ["alpha"])
        // Full roster: the 7th tap does not join.
        for slug in ["b", "c", "d", "e", "f", "g"] {
            draft.toggle(candidate(slug))
        }
        XCTAssertEqual(draft.members.count, 6)
        XCTAssertFalse(draft.members.contains { $0.route.profileSlug.rawValue == "g" })
    }

    // MARK: - Frozen-roster wire shape (groups.create)

    func testWireMembersMatchFrozenRosterShape() {
        let gateway = GatewayID(rawValue: "workstation")
        let members = HostedRoomMemberCodec.wireMembers(
            [candidate("researcher", gateway: "workstation"),
             candidate("scribe", gateway: "workstation")],
            gatewayID: gateway)
        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(members[0]["member_id"], "fleet-workstation-researcher")
        XCTAssertEqual(members[0]["profile"], "researcher")
        XCTAssertEqual(members[0]["handle"], "researcher")
        XCTAssertEqual(members[0]["display_name"], "Researcher")
        // member_id / profile / handle all match IDENTIFIER_RE.
        for member in members {
            for key in ["member_id", "profile", "handle"] {
                XCTAssertTrue(
                    HostedRoomMemberCodec.isValidIdentifier(member[key] ?? ""),
                    "\(key)=\(member[key] ?? "") must match IDENTIFIER_RE")
            }
        }
    }

    func testIdentifierValidationMirrorsUpstreamRegex() {
        XCTAssertTrue(HostedRoomMemberCodec.isValidIdentifier("fleet-workstation-researcher"))
        XCTAssertTrue(HostedRoomMemberCodec.isValidIdentifier("a1._:-x"))
        XCTAssertFalse(HostedRoomMemberCodec.isValidIdentifier("-leading-dash"))
        XCTAssertFalse(HostedRoomMemberCodec.isValidIdentifier("with space"))
        XCTAssertFalse(HostedRoomMemberCodec.isValidIdentifier(""))
    }

    // MARK: - D18: source-qualified member display

    func testSameNameMembersOnTwoGatewaysStayDistinct() {
        let a = FleetRoomMember(name: "Researcher", handle: "researcher")
        let b = FleetRoomMember(name: "Researcher", handle: "researcher")
        XCTAssertFalse(
            RoomMemberDisplay.areDistinct(a, gatewayA: "workstation", b, gatewayB: "workstation"),
            "same gateway + same name = same member")
        XCTAssertTrue(
            RoomMemberDisplay.areDistinct(a, gatewayA: "workstation", b, gatewayB: "laptop"),
            "same name on two gateways = two members (never collapses)")

        XCTAssertEqual(RoomMemberDisplay.label(for: a, gatewayLabel: "Workstation"), "Researcher")
        XCTAssertEqual(
            RoomMemberDisplay.sourceQualifier(for: a, gatewayLabel: "Workstation"),
            "Workstation")
        let linked = FleetRoomMember(
            name: "Researcher", handle: "researcher", connectionID: "peer-1", connectionLabel: "peer")
        XCTAssertEqual(
            RoomMemberDisplay.sourceQualifier(for: linked, gatewayLabel: "Workstation"),
            "Workstation · linked")
    }

    func testSameNameHostedAndLegacyRoomsRemainDistinctRooms() {
        let hosted = FleetRoom(
            id: FleetRoomID(provenance: .hosted, gatewayID: GatewayID(rawValue: "workstation"), key: "room-alpha"),
            name: "Research Crew")
        let legacy = FleetRoom(
            id: FleetRoomID(provenance: .desktopLegacy, gatewayID: GatewayID(rawValue: "workstation"), key: "name:Research Crew"),
            name: "Research Crew")
        XCTAssertNotEqual(hosted.id, legacy.id, "identity = provenance+gateway+key, never the name")
        var union = FleetRoomUnion()
        union.ingest([hosted, legacy])
        XCTAssertEqual(union.allRooms.count, 2)
        XCTAssertTrue(union.containsSameNameDistinctPair())
    }
}
