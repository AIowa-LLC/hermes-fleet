import Foundation

/// Slice 4: room-chat command seam factory (app-side adapter over the
/// per-gateway groups client; returns nil for gateways with no endpoint).
public typealias FleetRoomCommandFactory = @Sendable (FleetGateway) -> (any RoomChatCommanding)?

/// Slice 4: driver-status seam factory (groups.state driver_status decode).
public typealias FleetRoomDriverStatusFactory = @Sendable (FleetGateway) -> (any RoomDriverStatusProviding)?

/// Slice 5 (D19): RoomLink command seam factory (app-side adapter over the
/// per-gateway RoomLink client; returns nil for gateways with no endpoint).
public typealias FleetRoomLinkFactory = @Sendable (FleetGateway) -> (any RoomLinkCommanding)?

/// Normalized room discovery seam — one abstraction over both room
/// generations (addendum: "Core/service abstraction must normalize rooms
/// while explicitly preserving source/provenance").
///
/// FleetUI depends on this protocol only; concrete hosted/legacy providers
/// live app-side over FleetNetworking clients. Merging by name is
/// structurally impossible: every room carries a `FleetRoomID` whose
/// provenance + gateway + key are part of identity.
public protocol FleetRoomProviding: Sendable {
    /// Discover all rooms visible through this provider.
    /// Returns rooms EXCLUDING deleted ones (tombstones are consumed by the
    /// provider; a stale mirror must not resurrect a room).
    func rooms() async throws -> [FleetRoom]
}

/// Aggregates room providers across gateways/generations, preserving
/// distinct identities. Pure value type — the union is computed from
/// provider outputs, never from names.
public struct FleetRoomUnion: Sendable {
    public private(set) var roomsByID: [FleetRoomID: FleetRoom] = [:]
    private var deletedCanonicalIdentities: Set<String> = []
    private var deletedHostedRoomIDs: Set<String> = []

    public init() {}

    /// Ingest provider output. Source records remain individually addressable;
    /// hosted tombstones are retained as negative knowledge so stale Desktop
    /// mirrors cannot resurrect a disbanded room.
    public mutating func ingest(_ rooms: [FleetRoom]) {
        for room in rooms {
            if room.isDeleted {
                deletedCanonicalIdentities.insert(room.canonicalIdentity)
                if room.id.provenance == .hosted {
                    deletedHostedRoomIDs.insert(room.id.key)
                }
                roomsByID.removeValue(forKey: room.id)
                continue
            }
            guard !isTombstoned(room) else { continue }
            roomsByID[room.id] = room
        }
    }

    /// Source-union view retained for diagnostics and archive consumers. Hosted
    /// advertisements with one verified authority collapse deterministically;
    /// legacy records remain source-scoped here and are never transcript-merged.
    public var allRooms: [FleetRoom] {
        var canonical: [String: FleetRoom] = [:]
        for room in roomsByID.values where !isTombstoned(room) {
            let key = room.canonicalIdentity
            guard let current = canonical[key] else {
                canonical[key] = room
                continue
            }
            canonical[key] = preferred(current, over: room)
        }
        return canonical.values.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id.description < $1.id.description
        }
    }

    /// Reconciled normal-list rows. Hosted rooms are primary when a verified
    /// Desktop relationship exists; legacy-only records are archive-only.
    public var primaryRooms: [FleetRoom] {
        reconciliation.primaryRooms
    }

    /// Every live Desktop projection that remains recoverable through the
    /// historical archive, including projections related to a hosted room.
    public var legacyArchiveRooms: [FleetRoom] {
        reconciliation.legacyArchiveRooms
    }

    public var reconciliation: FleetRoomReconciliationSnapshot {
        FleetRoomReconciler.reconcile(
            rooms: Array(roomsByID.values),
            deletedCanonicalIdentities: deletedCanonicalIdentities,
            deletedHostedRoomIDs: deletedHostedRoomIDs)
    }

    private func isTombstoned(_ room: FleetRoom) -> Bool {
        if deletedCanonicalIdentities.contains(room.canonicalIdentity) { return true }
        guard room.id.provenance == .desktopLegacy,
              let durableID = LegacyRoomContinuation.durableHostedRoomID(for: room) else {
            return false
        }
        return deletedHostedRoomIDs.contains(durableID)
    }

    private func preferred(_ lhs: FleetRoom, over rhs: FleetRoom) -> FleetRoom {
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

    /// Rooms grouped by provenance for source-level diagnostics and tests.
    public func rooms(provenance: RoomProvenance) -> [FleetRoom] {
        allRooms.filter { $0.id.provenance == provenance }
    }

    /// Acceptance hook: unrelated same-name source records remain distinct.
    public func containsSameNameDistinctPair() -> Bool {
        let names = Dictionary(grouping: allRooms) { $0.name }
        return names.values.contains { group in
            Set(group.map { $0.id.provenance }).count > 1
        }
    }
}

/// Decode of the Desktop legacy `hermes-bots-groups` v3 projection envelope
/// (group-chat.ts:67-74, 180-302). Bounded and lossy BY DESIGN — this is a
/// display window, not the durable log.
///
/// Envelope: `{version: 3, updatedAt, rooms: {key: room}, deleted:
/// {key: revision}}`. Keys are `id:<roomId>` (modern) or `name:<name>`
/// (legacy). Tombstones: id-keyed are FINAL (never resurrect); name-keyed
/// are revision-gated (a mirror with a lower revision cannot resurrect).
public enum LegacyGroupProjectionDecoder {
    public struct DecodeResult: Sendable {
        public let rooms: [FleetRoom]
        /// Tombstone keys consumed (for caller bookkeeping).
        public let tombstones: [String]
    }

    /// Decode the envelope for one gateway. `metaValue` is the decoded
    /// `ui_meta["hermes-bots-groups"]` value.
    public static func decode(
        gatewayID: GatewayID,
        metaValue: MetadataValue?
    ) -> DecodeResult {
        guard let envelope = metaValue?.objectValue else {
            return DecodeResult(rooms: [], tombstones: [])
        }
        // Version gate: v1/v2 normalize upstream; Fleet understands v3 only.
        // Older/unknown versions decode their rooms best-effort (fields are
        // a superset-stable subset) but the envelope is treated as v3 shape.
        let roomObject = envelope["rooms"]?.objectValue ?? [:]
        let deleted = envelope["deleted"]?.objectValue ?? [:]

        var rooms: [FleetRoom] = []
        for (key, value) in roomObject {
            guard let roomObject = value.objectValue else { continue }
            let isIDKey = key.hasPrefix("id:")

            // Tombstone check: id-keyed tombstones are final.
            if isIDKey, deleted[key] != nil { continue }

            guard let name = roomObject["name"]?.stringValue, !name.isEmpty else { continue }
            // An unrepresentable revision (e.g. a hostile 2^63) degrades to the
            // missing-value shape — `?? 0` — instead of trapping `Int(_:)`.
            let revision = roomObject["revision"]?.intValue ?? 0

            // Name-keyed tombstones are revision-gated: a deleted marker
            // with revision >= the room's revision suppresses the room.
            // An unrepresentable tombstone revision stays absent, so the
            // comparison is skipped (never clamped to an invented revision).
            if !isIDKey, let tombRevision = deleted[key]?.intValue,
               tombRevision >= revision {
                continue
            }

            rooms.append(FleetRoom(
                id: FleetRoomID(provenance: .desktopLegacy, gatewayID: gatewayID, key: key),
                name: name,
                members: decodeMembers(roomObject["members"]),
                recentLog: decodeLog(roomObject["log"]),
                image: roomObject["image"]?.stringValue,
                revision: revision,
                isDeleted: false,
                hosted: nil
            ))
        }
        return DecodeResult(rooms: rooms, tombstones: Array(deleted.keys))
    }

    static func decodeMembers(_ value: MetadataValue?) -> [FleetRoomMember] {
        guard let array = value?.arrayValue else { return [] }
        return array.compactMap { entry in
            guard let o = entry.objectValue,
                  let name = o["name"]?.stringValue, !name.isEmpty else { return nil }
            return FleetRoomMember(
                name: name,
                handle: o["handle"]?.stringValue,
                connectionID: o["connectionId"]?.stringValue,
                connectionLabel: o["connectionLabel"]?.stringValue,
                sourceScoped: o["sourceScoped"]?.boolValue ?? false
            )
        }
    }

    static func decodeLog(_ value: MetadataValue?) -> [FleetRoomMessage] {
        guard let array = value?.arrayValue else { return [] }
        return array.compactMap { entry in
            guard let o = entry.objectValue,
                  let id = o["id"]?.stringValue, !id.isEmpty else { return nil }
            let fromObject = o["from"]?.objectValue
            let kind: FleetRoomMessage.ActorKind =
                fromObject?["kind"]?.stringValue == "user" ? .user : .member
            let fromName = fromObject?["name"]?.stringValue ?? ""
            return FleetRoomMessage(
                id: id,
                from: FleetRoomMessage.Actor(
                    kind: kind, name: fromName, source: fromObject?["source"]?.stringValue),
                text: o["text"]?.stringValue ?? "",
                // Legacy projection timestamps are epoch MILLISECONDS.
                at: o["at"]?.numberValue ?? 0,
                thread: o["thread"]?.stringValue
            )
        }
    }
}
