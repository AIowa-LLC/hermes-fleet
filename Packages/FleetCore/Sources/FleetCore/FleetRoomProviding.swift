import Foundation

/// Slice 4: room-chat command seam factory (app-side adapter over the
/// per-gateway groups client; returns nil for gateways with no endpoint).
public typealias FleetRoomCommandFactory = @Sendable (FleetGateway) -> (any RoomChatCommanding)?

/// Slice 4: driver-status seam factory (groups.state driver_status decode).
public typealias FleetRoomDriverStatusFactory = @Sendable (FleetGateway) -> (any RoomDriverStatusProviding)?

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

    public init() {}

    /// Ingest provider output. Same-name rooms with different identities
    /// coexist; an exact duplicate identity is replaced by the incoming row
    /// (providers are authoritative for their own keys).
    public mutating func ingest(_ rooms: [FleetRoom]) {
        for room in rooms where !room.isDeleted {
            roomsByID[room.id] = room
        }
    }

    /// All live rooms, deterministic order (name then identity).
    public var allRooms: [FleetRoom] {
        roomsByID.values.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id.description < $1.id.description
        }
    }

    /// Rooms grouped by provenance — UI never branches on generation inside
    /// a row; it reads `capabilities` / `isManagedByDesktop`.
    public func rooms(provenance: RoomProvenance) -> [FleetRoom] {
        allRooms.filter { $0.id.provenance == provenance }
    }

    /// Acceptance test hook (addendum §8.3): two same-name rooms of
    /// different generations must both be present and distinct.
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
            let revision = roomObject["revision"]?.numberValue.map(Int.init) ?? 0

            // Name-keyed tombstones are revision-gated: a deleted marker
            // with revision >= the room's revision suppresses the room.
            if !isIDKey, let tombRevision = deleted[key]?.numberValue.map(Int.init),
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
