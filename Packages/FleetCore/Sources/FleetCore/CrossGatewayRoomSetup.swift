import Foundation

/// Safe catalog metadata from groups.capabilities. The complete catalog must
/// round-trip: the target's live probe compares it structurally, not just by digest.
public struct RoomLinkTargetSnapshot: Sendable {
    public let negotiation: RoomLinkNegotiation
    public let catalog: MetadataValue
    public let driver: Bool
    public init(negotiation: RoomLinkNegotiation, catalog: MetadataValue, driver: Bool) {
        self.negotiation = negotiation; self.catalog = catalog; self.driver = driver
    }
    public var supportsDirect: Bool {
        let n = negotiation
        return n.enabled && n.supportsProtocol(2) && n.persistentProcess && n.linkModes.contains("direct")
            && !n.installationID.isEmpty && !n.catalogDigest.isEmpty
            && n.executionPolicy?.targetProfile == n.profile
            && !(n.executionPolicy?.policyDigest.isEmpty ?? true)
            && n.endpoint?.available == true && n.endpoint?.url != nil
    }
    public var supportsHome: Bool {
        driver && supportsDirect && ["groups.create", "groups.state", "groups.peer.register"].allSatisfy(negotiation.methods.contains)
    }
    public var supportsTarget: Bool {
        supportsDirect && ["groups.peer.invite", "groups.peer.revoke"].allSatisfy(negotiation.methods.contains)
    }
}

/// The opaque grant is transient controller state. Never persist or display it.
public struct ScopedRoomGrant: Sendable, CustomStringConvertible {
    public let token: String
    public let profile: String
    public let catalog: MetadataValue
    public init(token: String, profile: String, catalog: MetadataValue) {
        self.token = token; self.profile = profile; self.catalog = catalog
    }
    public var description: String { "ScopedRoomGrant(<redacted>)" }
}

public protocol CrossGatewayRoomCommanding: Sendable {
    func roomLinkTarget(profile: String) async throws -> RoomLinkTargetSnapshot
    func createScopedRoom(roomID: String, name: String, members: [MetadataValue]) async throws -> FleetRoom
    func inviteScopedRoom(room: FleetRoom, profile: String, memberID: String) async throws -> ScopedRoomGrant
    func registerScopedPeer(roomID: String, memberID: String, target: RoomLinkTargetSnapshot, grant: ScopedRoomGrant) async throws
    func revokeScopedPeer(_ grant: ScopedRoomGrant) async throws
}

public enum CrossGatewayRoomSetup {
    public static func memberID(_ route: Route) -> String {
        "fleet-" + route.id.utf8.map { String(format: "%02x", $0) }.joined()
    }
    public static func member(_ candidate: RoomMemberCandidate, target: RoomLinkTargetSnapshot?) -> MetadataValue {
        let profile = candidate.route.profileSlug.rawValue
        let id = memberID(candidate.route)
        var value: [String: MetadataValue] = ["member_id": .string(id), "profile": .string(profile),
            "handle": .string(id), "display_name": .string(candidate.displayName)]
        if let target {
            value["target"] = .object(["kind": .string("peer"), "profile": .string(profile),
                "peer_id": .string(target.negotiation.installationID),
                "installation_id": .string(target.negotiation.installationID),
                "capability_digest": .string(target.negotiation.catalogDigest)])
        }
        return .object(value)
    }
}
