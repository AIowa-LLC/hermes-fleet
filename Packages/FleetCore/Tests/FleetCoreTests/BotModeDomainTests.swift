import XCTest
@testable import FleetCore

/// Bot Mode foundation domain tests: metadata decode/round-trip, canonical
/// chat fail-closed resolution, typed failures, room provenance identity,
/// and the legacy ui_meta projection decoder.
final class BotModeDomainTests: XCTestCase {

    // MARK: - BotModeMetadata

    func testMetadataDecodesKnownFields() {
        let meta = BotModeMetadata(metadataValue: .object([
            "title": .string("Researcher"),
            "hidden": .bool(true),
            "sectionId": .string("sec-1"),
            "groups": .array([.string("crew")]),
            "created": .number(1_700_000_000),
        ]))
        XCTAssertEqual(meta?.title, "Researcher")
        XCTAssertEqual(meta?.hidden, true)
        XCTAssertEqual(meta?.sectionID, "sec-1")
        XCTAssertEqual(meta?.groups, ["crew"])
        XCTAssertEqual(meta?.created, 1_700_000_000)
    }

    func testMetadataRoundTripsUnknownKeys() {
        let meta = BotModeMetadata(object: [
            "title": .string("R"),
            "futureField": .object(["nested": .bool(true)]),
        ])
        let wire = meta.toWire()
        XCTAssertEqual(wire["futureField"], .object(["nested": .bool(true)]))
        // And back:
        let redecoded = BotModeMetadata(object: wire)
        XCTAssertEqual(redecoded.unknownKeys["futureField"], .object(["nested": .bool(true)]))
        XCTAssertEqual(redecoded.title, "R")
    }

    func testAbsentMetadataKeyDecodesNil() {
        XCTAssertNil(BotModeMetadata(metadataValue: .object([:])))
        XCTAssertNil(BotModeMetadata(metadataValue: nil))
        XCTAssertNil(BotModeMetadata(metadataValue: .string("junk")))
    }

    // MARK: - CanonicalSessionRef.openID hardening

    func testOpenIDRejectsMalformedResolvedID() {
        let ref = CanonicalSessionRef(id: "reg-1", resolvedID: "   ")
        XCTAssertEqual(ref.openID, "reg-1")
        let emptyBoth = CanonicalSessionRef(id: "  ", resolvedID: "")
        XCTAssertNil(emptyBoth.openID, "malformed pair must fail closed, not route an empty id")
    }

    func testOpenIDPrefersCompressionTip() {
        let ref = CanonicalSessionRef(id: "reg-1", resolvedID: "tip-9")
        XCTAssertEqual(ref.openID, "tip-9")
    }

    // MARK: - CanonicalChatResolution (fail-closed contract)

    private func canonicalRow(id: String, title: String = BotModeContract.canonicalChatTitle) -> SessionSummary {
        SessionSummary(id: id, title: title, preview: "p", startedAt: 1, messageCount: 2)
    }

    func testLookupErrorFailsClosed() {
        let resolution = CanonicalChatResolver.resolve(
            lookupRows: [], rosterCanonicalID: nil, lookupError: "rpc failed")
        guard case .unconfirmedLookup = resolution else {
            return XCTFail("RPC error must be unconfirmed, never absence")
        }
        if case .unconfirmedLookup(let m) = resolution {
            XCTAssertTrue(m.contains("not starting a new chat"))
        }
        // And the planner must turn it into unavailable — never create.
        guard case .unavailable = BotChatPlanner.plan(from: resolution) else {
            return XCTFail("unconfirmed lookup must plan unavailable, not createThenOpen")
        }
    }

    func testEmptyLookupWithKnownCanonicalFailsClosed() {
        // canonical-chat.ts:222-232 (#98383): zero-row SUCCESS + prior
        // canonical id = unconfirmed, never mint.
        let resolution = CanonicalChatResolver.resolve(
            lookupRows: [], rosterCanonicalID: "reg-7", lookupError: nil)
        guard case .unconfirmedLookup = resolution else {
            return XCTFail("empty lookup with known canonical must be unconfirmed")
        }
        guard case .unavailable = BotChatPlanner.plan(from: resolution) else {
            return XCTFail("must not fork/create on unconfirmed registry")
        }
    }

    func testConfirmedMissPlansCreation() {
        let resolution = CanonicalChatResolver.resolve(
            lookupRows: [], rosterCanonicalID: nil, lookupError: nil)
        XCTAssertEqual(
            CanonicalChatResolution.self == CanonicalChatResolution.self, true)
        guard case .confirmedAbsent = resolution else {
            return XCTFail("empty lookup with no prior canonical is a confirmed miss")
        }
        guard case .createThenOpen = BotChatPlanner.plan(from: resolution) else {
            return XCTFail("confirmed miss plans safe creation")
        }
    }

    func testExistingRowOpensCanonicalNeverForks() {
        let resolution = CanonicalChatResolver.resolve(
            lookupRows: [canonicalRow(id: "reg-1")],
            rosterCanonicalID: "reg-1",
            lookupError: nil)
        guard case .existing(let ref) = resolution else {
            return XCTFail("matching row resolves existing")
        }
        XCTAssertEqual(ref.openID, "reg-1")
        guard case .openCanonical(let outRef) = BotChatPlanner.plan(from: resolution) else {
            return XCTFail("existing plans openCanonical")
        }
        XCTAssertEqual(outRef.openID, "reg-1")
    }

    func testNonCanonicalTitleRowIsNotAdopted() {
        // A row with a different title must never count as the canonical
        // chat even if the gateway returned it.
        let resolution = CanonicalChatResolver.resolve(
            lookupRows: [canonicalRow(id: "x", title: "Other Chat")],
            rosterCanonicalID: nil,
            lookupError: nil)
        guard case .confirmedAbsent = resolution else {
            return XCTFail("non-matching title row is a miss for canonical identity")
        }
    }

    // MARK: - Typed failures

    func testFailureReasonWireSpelling() {
        XCTAssertEqual(BotFailureReason.runtimeOffline.rawValue, "runtime_offline")
        XCTAssertEqual(BotFailureReason.providerAuthOrAccess.rawValue, "provider_auth_or_access")
        XCTAssertEqual(BotFailureReason.providerQuotaLimit.rawValue, "provider_quota_limit")
        XCTAssertEqual(BotFailureReason(wireValue: "provider_rate_limit"), .providerRateLimit)
        XCTAssertEqual(BotFailureReason(wireValue: "something_new"), .unknown)
    }

    func testFailureRecoveryClassification() {
        XCTAssertTrue(BotFailureReason.providerRateLimit.isAutoRetryable)
        XCTAssertTrue(BotFailureReason.runtimeOffline.isAutoRetryable)
        XCTAssertFalse(BotFailureReason.providerAuthOrAccess.isAutoRetryable)
        XCTAssertEqual(BotFailureReason.contextOverflow.recoveryAction, .compressThenResume)
        XCTAssertEqual(BotFailureReason.missingConfig.recoveryAction, .none)
    }

    func testFailureAttentionClasses() {
        XCTAssertTrue(BotFailureReason.agentBlocked.requiresAttention)
        XCTAssertTrue(BotFailureReason.providerQuotaLimit.requiresAttention)
        XCTAssertFalse(BotFailureReason.cancelled.requiresAttention)
    }

    // MARK: - Room identity & provenance

    func testSameNameDifferentProvenanceAreDistinct() {
        let hosted = FleetRoomID(provenance: .hosted, gatewayID: GatewayID(rawValue: "gw"), key: "room-1")
        let legacy = FleetRoomID(provenance: .desktopLegacy, gatewayID: GatewayID(rawValue: "gw"), key: "id:r-1")
        XCTAssertNotEqual(hosted, legacy)

        var union = FleetRoomUnion()
        union.ingest([
            FleetRoom(id: hosted, name: "Research Crew"),
            FleetRoom(id: legacy, name: "Research Crew"),
        ])
        XCTAssertEqual(union.allRooms.count, 2, "same-name rooms must coexist, never merge")
        XCTAssertTrue(union.containsSameNameDistinctPair())
    }

    func testSameNameDifferentGatewaysAreDistinct() {
        let a = FleetRoomID(provenance: .hosted, gatewayID: GatewayID(rawValue: "gw-a"), key: "room-1")
        let b = FleetRoomID(provenance: .hosted, gatewayID: GatewayID(rawValue: "gw-b"), key: "room-1")
        XCTAssertNotEqual(a, b)
    }

    func testLegacyRoomsAreObservational() {
        let room = FleetRoom(
            id: FleetRoomID(provenance: .desktopLegacy, gatewayID: GatewayID(rawValue: "gw"), key: "id:r-1"),
            name: "Crew")
        XCTAssertFalse(room.capabilities.canSend)
        XCTAssertFalse(room.capabilities.canRename)
        XCTAssertFalse(room.capabilities.canDisband)
        XCTAssertFalse(room.capabilities.canStop)
        XCTAssertTrue(room.isManagedByDesktop)
    }

    func testHostedRoomsFailClosedWithoutCapabilityTruth() {
        // No advertised methods fetched yet → observational (fail closed).
        let room = FleetRoom(
            id: FleetRoomID(provenance: .hosted, gatewayID: GatewayID(rawValue: "gw"), key: "room-1"),
            name: "Crew",
            hosted: HostedRoomState(
                authorityGatewayID: "install:x", authorityEpoch: 1,
                advertisedMethods: nil, driverAvailable: false))
        XCTAssertFalse(room.capabilities.canSend)
    }

    func testHostedRoomsWithCapabilityTruth() {
        let room = FleetRoom(
            id: FleetRoomID(provenance: .hosted, gatewayID: GatewayID(rawValue: "gw"), key: "room-1"),
            name: "Crew",
            hosted: HostedRoomState(
                authorityGatewayID: "install:x", authorityEpoch: 1,
                advertisedMethods: ["groups.send", "groups.rename", "groups.log"],
                driverAvailable: true))
        XCTAssertTrue(room.capabilities.canSend)
        XCTAssertTrue(room.capabilities.canReplay)
        XCTAssertFalse(room.capabilities.canStop, "stop not advertised")
    }

    // MARK: - Legacy projection decoder

    private let legacyEnvelope: MetadataValue = .object([
        "version": .number(3),
        "updatedAt": .number(1_700_000_500_000),
        "rooms": .object([
            "id:r-abc": .object([
                "name": .string("Design Crew"),
                "roomId": .string("r-abc"),
                "revision": .number(4),
                "members": .array([
                    .object(["name": .string("researcher"), "connectionId": .string("workstation")]),
                ]),
                "log": .array([
                    .object([
                        "id": .string("m1"),
                        "from": .object(["kind": .string("member"), "name": .string("researcher")]),
                        "text": .string("shipping now"),
                        "at": .number(1_700_000_400_000),
                    ]),
                ]),
            ]),
            "name:Old Room": .object([
                "name": .string("Old Room"),
                "revision": .number(2),
            ]),
        ]),
        "deleted": .object([
            "id:r-gone": .number(9),
            "name:Old Room": .number(5),
        ]),
    ])

    func testLegacyProjectionDecodesRoomsAndMembers() {
        let result = LegacyGroupProjectionDecoder.decode(
            gatewayID: GatewayID(rawValue: "gw"), metaValue: legacyEnvelope)
        XCTAssertEqual(result.rooms.count, 1, "name:Old Room is tombstoned at revision 5 >= 2")
        let room = result.rooms[0]
        XCTAssertEqual(room.name, "Design Crew")
        XCTAssertEqual(room.id.key, "id:r-abc")
        XCTAssertEqual(room.members.first?.name, "researcher")
        XCTAssertEqual(room.members.first?.connectionID, "workstation")
        XCTAssertEqual(room.recentLog.first?.text, "shipping now")
        XCTAssertEqual(room.recentLog.first?.from.name, "researcher")
        XCTAssertEqual(room.revision, 4)
    }

    func testIDKeyedTombstoneIsFinal() {
        var envelope = legacyEnvelope
        // A room whose id-key IS in deleted never renders, regardless of
        // the room's own revision.
        if case .object(var rooms) = envelope {
            rooms["id:r-gone"] = .object(["name": .string("Ghost"), "revision": .number(99)])
            envelope = .object(rooms)
        }
        let result = LegacyGroupProjectionDecoder.decode(
            gatewayID: GatewayID(rawValue: "gw"), metaValue: envelope)
        XCTAssertFalse(result.rooms.contains { $0.id.key == "id:r-gone" },
                      "id-keyed tombstones must never resurrect")
    }

    func testNameKeyedTombstoneRevisionGate() {
        // Room revision 7 > tombstone revision 5 → room survives.
        var envelope = legacyEnvelope
        if case .object(var topLevel) = envelope,
           case .object(var rooms)? = topLevel["rooms"] {
            rooms["name:Old Room"] = .object(["name": .string("Old Room"), "revision": .number(7)])
            topLevel["rooms"] = .object(rooms)
            envelope = .object(topLevel)
        }
        let result = LegacyGroupProjectionDecoder.decode(
            gatewayID: GatewayID(rawValue: "gw"), metaValue: envelope)
        XCTAssertTrue(result.rooms.contains { $0.id.key == "name:Old Room" },
                      "higher room revision survives an older tombstone")
    }

    func testMissingOrMalformedEnvelopeDecodesEmpty() {
        let gw = GatewayID(rawValue: "gw")
        XCTAssertEqual(LegacyGroupProjectionDecoder.decode(gatewayID: gw, metaValue: nil).rooms.count, 0)
        XCTAssertEqual(LegacyGroupProjectionDecoder.decode(gatewayID: gw, metaValue: .number(3)).rooms.count, 0)
        // Empty envelope object: no rooms, no crash.
        XCTAssertEqual(LegacyGroupProjectionDecoder.decode(gatewayID: gw, metaValue: .object([:])).rooms.count, 0)
    }

    // MARK: - Modern roster decode integration (domain level)

    func testProfileDescriptorBotModeMetadataBridge() {
        let descriptor = ProfileDescriptor(
            name: "researcher",
            path: "/synthetic/home",
            uiMeta: ["hermes-bots": .object(["title": .string("Researcher")])])
        XCTAssertEqual(descriptor.botModeMetadata?.title, "Researcher")
    }
}
