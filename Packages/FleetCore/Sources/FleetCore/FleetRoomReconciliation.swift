import Foundation

/// Confidence for a relationship between a gateway-hosted room and a
/// Desktop projection. A relationship never changes either source identity.
public enum FleetRoomRelationshipConfidence: String, Hashable, Sendable {
    /// The projection and hosted room share a durable id on the same gateway;
    /// this is the anchor established by the continuation contract.
    case hostedGatewayAnchor
    /// A second gateway published a compatible mirror of the anchored
    /// projection. Its bounded transcript remains a separate archive record.
    case mirroredProjection
}

/// A verified association between source records that represent one logical
/// group. The hosted record is always the primary interactive identity.
public struct FleetRoomRelationship: Hashable, Sendable {
    public let primaryID: FleetRoomID
    public let representationIDs: [FleetRoomID]
    public let confidence: FleetRoomRelationshipConfidence

    public init(
        primaryID: FleetRoomID,
        representationIDs: [FleetRoomID],
        confidence: FleetRoomRelationshipConfidence
    ) {
        self.primaryID = primaryID
        self.representationIDs = representationIDs
        self.confidence = confidence
    }
}

/// Result of deterministic room reconciliation. `primaryRooms` is suitable
/// for normal interactive navigation; `legacyArchiveRooms` is intentionally
/// separate so bounded Desktop history remains recoverable without appearing
/// as another interactive group.
public struct FleetRoomReconciliationSnapshot: Sendable {
    public let primaryRooms: [FleetRoom]
    public let legacyArchiveRooms: [FleetRoom]
    public let relationships: [FleetRoomRelationship]

    public init(
        primaryRooms: [FleetRoom],
        legacyArchiveRooms: [FleetRoom],
        relationships: [FleetRoomRelationship]
    ) {
        self.primaryRooms = primaryRooms
        self.legacyArchiveRooms = legacyArchiveRooms
        self.relationships = relationships
    }
}

/// Pure, refresh-order-independent reconciliation for hosted and Desktop
/// projection records. No transcript is merged and no source record is
/// rewritten.
public enum FleetRoomReconciler {
    public static func reconcile(
        rooms: [FleetRoom],
        deletedCanonicalIdentities: Set<String> = [],
        deletedHostedRoomIDs: Set<String> = []
    ) -> FleetRoomReconciliationSnapshot {
        let live = rooms.filter {
            !$0.isDeleted
                && !deletedCanonicalIdentities.contains($0.canonicalIdentity)
                && !isDeletedLegacy($0, deletedHostedRoomIDs: deletedHostedRoomIDs)
        }

        var hostedByCanonical: [String: FleetRoom] = [:]
        for room in live where room.id.provenance == .hosted {
            let key = room.canonicalIdentity
            if let current = hostedByCanonical[key] {
                hostedByCanonical[key] = preferred(current, over: room)
            } else {
                hostedByCanonical[key] = room
            }
        }
        let hosted = hostedByCanonical.values.sorted(by: stableRoomOrder)
        let legacy = live
            .filter { $0.id.provenance == .desktopLegacy }
            .sorted(by: stableRoomOrder)

        var primary = hosted
        var archived: [FleetRoom] = []
        var relationships: [FleetRoomRelationship] = []

        for hostedRoom in hosted {
            let candidates = legacy.filter {
                LegacyRoomContinuation.durableHostedRoomID(for: $0) == hostedRoom.id.key
            }
            let anchors = candidates.filter { $0.id.gatewayID == hostedRoom.id.gatewayID }
            guard anchors.count == 1 else { continue }

            let anchor = anchors[0]
            let hostedForSource = hosted.filter {
                $0.id.key == hostedRoom.id.key && $0.id.gatewayID == anchor.id.gatewayID
            }
            guard hostedForSource.count == 1 else { continue }

            let linked = candidates.filter {
                $0.id == anchor.id || isCompatibleMirror($0, anchor: anchor, hosted: hostedRoom)
            }
            guard !linked.isEmpty else { continue }
            let ids = [hostedRoom.id] + linked.map(\.id).sorted { $0.description < $1.description }
            let hasForeignMirror = linked.contains { $0.id.gatewayID != anchor.id.gatewayID }
            relationships.append(FleetRoomRelationship(
                primaryID: hostedRoom.id,
                representationIDs: ids,
                confidence: hasForeignMirror ? .mirroredProjection : .hostedGatewayAnchor))
        }

        archived.append(contentsOf: legacy)
        archived.sort(by: stableRoomOrder)
        primary.sort(by: stableRoomOrder)

        // Keep the relationship list deterministic even if provider completion
        // order changes.
        relationships.sort {
            if $0.primaryID.description != $1.primaryID.description {
                return $0.primaryID.description < $1.primaryID.description
            }
            return $0.representationIDs.map(\.description).joined() < $1.representationIDs.map(\.description).joined()
        }

        return FleetRoomReconciliationSnapshot(
            primaryRooms: primary,
            legacyArchiveRooms: archived,
            relationships: relationships)
    }

    private static func isDeletedLegacy(
        _ room: FleetRoom,
        deletedHostedRoomIDs: Set<String>
    ) -> Bool {
        guard room.id.provenance == .desktopLegacy,
              let durableID = LegacyRoomContinuation.durableHostedRoomID(for: room) else {
            return false
        }
        return deletedHostedRoomIDs.contains(durableID)
    }

    private static func isCompatibleMirror(
        _ candidate: FleetRoom,
        anchor: FleetRoom,
        hosted: FleetRoom
    ) -> Bool {
        guard candidate.id.key == anchor.id.key,
              candidate.name == anchor.name || candidate.name == hosted.name else {
            return false
        }

        let anchorMembers = Set(anchor.members.map(memberIdentity))
        let candidateMembers = Set(candidate.members.map(memberIdentity))
        if !anchorMembers.isEmpty && !candidateMembers.isEmpty && anchorMembers != candidateMembers {
            return false
        }

        // Same-gateway identity is the explicit anchor. A foreign projection
        // must additionally carry compatible projection evidence; a bare id or
        // matching display name alone is never enough.
        if candidate.id.gatewayID == anchor.id.gatewayID { return true }
        if candidate.revision == anchor.revision && candidate.revision > 0 { return true }
        let sharedEvents = Set(candidate.recentLog.map(\.id))
            .intersection(Set(anchor.recentLog.map(\.id)))
        return !sharedEvents.isEmpty
    }

    private static func memberIdentity(_ member: FleetRoomMember) -> String {
        let handle = member.handle ?? member.name
        let source = member.connectionID ?? ""
        return handle + "|" + source
    }

    private static func preferred(_ lhs: FleetRoom, over rhs: FleetRoom) -> FleetRoom {
        if rhs.revision != lhs.revision { return rhs.revision > lhs.revision ? rhs : lhs }
        if (rhs.hosted?.latestSeq ?? -1) != (lhs.hosted?.latestSeq ?? -1) {
            return (rhs.hosted?.latestSeq ?? -1) > (lhs.hosted?.latestSeq ?? -1) ? rhs : lhs
        }
        if rhs.hosted?.driverAvailable != lhs.hosted?.driverAvailable {
            return rhs.hosted?.driverAvailable == true ? rhs : lhs
        }
        let lhsRichness = lhs.members.count + lhs.recentLog.count
        let rhsRichness = rhs.members.count + rhs.recentLog.count
        if lhsRichness != rhsRichness { return rhsRichness > lhsRichness ? rhs : lhs }
        return rhs.id.description < lhs.id.description ? rhs : lhs
    }

    private static func stableRoomOrder(_ lhs: FleetRoom, _ rhs: FleetRoom) -> Bool {
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.id.description < rhs.id.description
    }
}
