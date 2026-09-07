import Foundation
import FleetCore
import FleetNetworking
import FleetUI

/// Hosted-room provider: `groups.list` over the gateway's Bot Mode client
/// transport, normalized into `FleetRoom`s with `.hosted` provenance.
///
/// Capability truth is fetched once per provider instance via
/// `groups.capabilities` and attached to every room (fail closed when
/// unavailable: rooms decode with no advertised methods → observational).
struct HostedRoomProvider: FleetRoomProviding {
    let gatewayID: GatewayID
    private let client: GatewayGroupsClient

    init(gatewayID: GatewayID, client: GatewayGroupsClient) {
        self.gatewayID = gatewayID
        self.client = client
    }

    func rooms() async throws -> [FleetRoom] {
        let caps: GroupsCapabilities?
        do {
            caps = try await client.capabilities()
        } catch {
            // Old gateway without groups.*: no hosted rooms, honest absence.
            if case GroupsError.unsupportedMethod = error { return [] }
            throw error
        }
        guard let caps else { return [] }
        let page = try await client.listRooms()
        return page.rooms.map { row in
            FleetRoom(
                id: FleetRoomID(provenance: .hosted, gatewayID: gatewayID, key: row.roomID),
                name: row.name,
                members: row.members,
                recentLog: [],
                image: nil,
                revision: row.revision,
                isDeleted: row.disbandedAt != nil,
                hosted: HostedRoomState(
                    authorityGatewayID: row.authorityGatewayID,
                    authorityEpoch: row.authorityEpoch,
                    latestSeq: row.latestSeq,
                    createdAt: row.createdAt,
                    updatedAt: row.updatedAt,
                    disbandedAt: row.disbandedAt,
                    advertisedMethods: caps.methods,
                    driverAvailable: caps.driver
                )
            )
        }
        .filter { !$0.isDeleted }
    }
}

/// Desktop-legacy-room provider: decodes the `hermes-bots-groups` v3
/// projection from the DEFAULT profile's ui_meta via `profiles.list`.
struct DesktopLegacyRoomProvider: FleetRoomProviding {
    let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    func rooms() async throws -> [FleetRoom] {
        guard case .connected = transport.state else { throw RosterError.notConnected }
        let result = try await transport.request(method: "profiles.list", params: .object([:]))
        // Find the default profile's row and decode its projection.
        guard let profiles = result["profiles"]?.arrayValue else {
            throw RosterError.malformedPayload("profiles.list missing 'profiles'")
        }
        let defaultRow = profiles.first { $0["is_default"]?.boolValue == true }
            ?? profiles.first
        guard let row = defaultRow else { return [] }
        guard let metaJSON = row["ui_meta"]?["hermes-bots-groups"] else { return [] }
        let metaValue = ModernProfilesDecoder.toMetadataValue(metaJSON)
        return LegacyGroupProjectionDecoder.decode(gatewayID: gatewayID, metaValue: metaValue).rooms
    }
}

/// Union room source for one gateway: hosted rooms + legacy projection,
/// identities never merged (distinct provenance keys by construction).
/// Conforms to the FleetCore `FleetRoomSourceProviding` seam (slice 2).
struct GatewayRoomSource {
    let hosted: HostedRoomProvider
    let legacy: DesktopLegacyRoomProvider

    /// Both providers, best-effort per source: a legacy-decode failure must
    /// not hide hosted rooms and vice versa (addendum: observational rooms
    /// degrade without invented state).
    func rooms() async -> [FleetRoom] {
        var out: [FleetRoom] = []
        if let hostedRooms = try? await hosted.rooms() {
            out.append(contentsOf: hostedRooms)
        }
        if let legacyRooms = try? await legacy.rooms() {
            out.append(contentsOf: legacyRooms)
        }
        return out
    }
}

/// Slice 2 seam adapter: `FleetRoomSourceProviding` over the union source.
struct GatewayRoomSourceAdapter: FleetRoomSourceProviding {
    let gatewayID: GatewayID
    let hosted: HostedRoomProvider
    let legacy: DesktopLegacyRoomProvider
    /// Sections-registry + legacy-projection reader (the Bot Mode client).
    let profileReader: GatewayBotModeClient

    func rooms() async -> [FleetRoom] {
        await GatewayRoomSource(hosted: hosted, legacy: legacy).rooms()
    }
}

/// Empty room source for gateways with no endpoint (honest absence).
struct EmptyRoomSource: FleetRoomSourceProviding {
    func rooms() async -> [FleetRoom] { [] }
}

/// Fail-closed bot-profile seam for gateways without an endpoint.
struct UnsupportedBotProfileManagement: BotProfileManaging {
    func describeProfile(_ profile: String) async throws -> BotProfileDescription {
        throw RosterError.notConnected
    }

    func configureProfile(_ profile: String, edit: BotProfileEdit) async throws -> BotProfileEditOutcome {
        throw RosterError.notConnected
    }

    func configureProfile(
        _ profile: String, edit: BotProfileEdit, confirmExpensiveModel: Bool
    ) async throws -> BotProfileEditOutcome {
        throw RosterError.notConnected
    }

    func createProfile(_ spec: BotCreateSpec) async throws -> String {
        throw RosterError.notConnected
    }

    func uploadAvatar(_ profile: String, dataURL: String) async throws {
        throw RosterError.notConnected
    }

    func clearAvatar(_ profile: String) async throws {
        throw RosterError.notConnected
    }

    func avatarData(_ profile: String) async throws -> Data? {
        throw RosterError.notConnected
    }
}

/// Section-registry sync on the Bot Mode client: the Fleet registry rides
/// the gateway DEFAULT profile's ui_meta key `bot-sections-v1` with per-key
/// CAS (load revision → write with expected revision; typed conflict on
/// mismatch — never silent overwrite).
extension GatewayBotModeClient: BotSectionRegistryLoading, BotSectionRegistryWriting {
    public func loadSectionRegistry() async throws -> (sections: [BotSection], revision: Int?) {
        let revision = try await uiMetaRevision(
            profile: "default", key: BotSectionRegistry.metaKey)
        let meta = try await profileUIMeta(profile: "default")
        let sections = BotSectionRegistry.normalize(meta?[BotSectionRegistry.metaKey])
        return (sections, revision)
    }

    public func writeSectionRegistry(
        value: MetadataValue, expectedRevision: Int?
    ) async throws -> MetadataWriteReceiptLike {
        let receipt = try await writeUIMetaKey(
            profile: "default",
            key: BotSectionRegistry.metaKey,
            value: value,
            expectedRevision: expectedRevision
        )
        return MetadataWriteReceiptLike(
            applied: receipt.applied, newRevisions: receipt.newRevisions)
    }
}
