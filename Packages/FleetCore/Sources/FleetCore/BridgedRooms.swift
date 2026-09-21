import Foundation

/// Phone-bridged groups (GC2 follow-up): a mixed-gateway selection that no
/// single gateway can host (cross-gateway RoomLink endpoints not configured)
/// still gets a working group by relaying through each member's existing
/// authenticated conversation connection on this device.
///
/// Scope is deliberately minimal ("safest, easiest" per owner):
/// - The room record and transcript are DEVICE-LOCAL (JSON file, non-secret).
/// - `send` fans the user text out to every member's conversation session and
///   collects each member's next `message.complete` as its reply.
/// - Failures are honest per-member system notes (`turn.failed`), never
///   fabricated replies. No turn engine, no cross-room sync, no attachments.
public enum BridgedRooms {
    /// Storage scope for bridged rooms inside `roomsByGateway`.
    public static let gatewayScope = GatewayID(rawValue: "bridged-device")
    /// File name under Application Support.
    public static let storeFileName = "fleet-bridged-rooms.json"

    // MARK: - Identity + persistence record

    /// One bridged member: enough to route sends and render identity.
    public struct MemberRef: Hashable, Sendable, Codable {
        public let gatewayID: String
        public let profile: String
        public let displayName: String
        public let routeID: String

        public init(gatewayID: String, profile: String, displayName: String, routeID: String) {
            self.gatewayID = gatewayID
            self.profile = profile
            self.displayName = displayName
            self.routeID = routeID
        }

        public var route: Route? { Route(validating: GatewayID(rawValue: gatewayID), profileSlug: ProfileSlug(rawValue: profile)) }
    }

    /// Persisted shape of one bridged room (non-secret).
    public struct RoomRecord: Hashable, Sendable, Codable {
        public let roomKey: String
        public var name: String
        public let members: [MemberRef]
        public let createdAt: Double
        public var disbandedAt: Double?
        public var renamedAt: Double?
        public var events: [EventRecord] = []

        public init(
            roomKey: String, name: String, members: [MemberRef], createdAt: Double,
            disbandedAt: Double? = nil, renamedAt: Double? = nil, events: [EventRecord] = []
        ) {
            self.roomKey = roomKey
            self.name = name
            self.members = members
            self.createdAt = createdAt
            self.disbandedAt = disbandedAt
            self.renamedAt = renamedAt
            self.events = events
        }
    }

    /// Persisted transcript event (hosted-room event vocabulary so the
    /// existing transcript projection renders it unchanged).
    public struct EventRecord: Hashable, Sendable, Codable {
        public let seq: Int
        public let eventID: String
        public let kind: String
        public let actorKind: String
        public let actorID: String
        public let actorDisplayName: String?
        public let actorProfile: String?
        public let payloadText: String?
        public let reasonCode: String?
        public let createdAt: Double

        public init(
            seq: Int, eventID: String, kind: String, actorKind: String, actorID: String,
            actorDisplayName: String? = nil, actorProfile: String? = nil,
            payloadText: String? = nil, reasonCode: String? = nil, createdAt: Double
        ) {
            self.seq = seq
            self.eventID = eventID
            self.kind = kind
            self.actorKind = actorKind
            self.actorID = actorID
            self.actorDisplayName = actorDisplayName
            self.actorProfile = actorProfile
            self.payloadText = payloadText
            self.reasonCode = reasonCode
            self.createdAt = createdAt
        }

        /// Hosted-event view for the existing projection.
        public func hostedEvent(roomKey: String) -> HostedRoomEventValue {
            HostedRoomEventValue(
                roomID: roomKey, seq: seq, eventID: eventID, kind: kind,
                actorKind: actorKind, actorID: actorID,
                actorDisplayName: actorDisplayName, actorProfile: actorProfile,
                payloadText: payloadText, reasonCode: reasonCode, createdAt: createdAt)
        }
    }

    // MARK: - JSON store

    /// Device-local JSON persistence for bridged rooms (non-secret; same
    /// container protection as every other Fleet store).
    public actor Store {
        private let url: URL
        private var rooms: [String: RoomRecord] = [:]
        private var loaded = false

        public init(url: URL) {
            self.url = url
        }

        public static func defaultURL() -> URL {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            return base.appendingPathComponent(BridgedRooms.storeFileName)
        }

        private func loadIfNeeded() {
            guard !loaded else { return }
            loaded = true
            guard let data = try? Data(contentsOf: url) else { return }
            let decoder = JSONDecoder()
            if let decoded = try? decoder.decode([String: RoomRecord].self, from: data) {
                rooms = decoded
            }
        }

        private func persist() {
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(rooms) else { return }
            try? data.write(to: url, options: .atomic)
        }

        /// Test launches reset before hydration, so previous rooms cannot
        /// leak into a later UI journey. Normal launches never call this.
        public func resetForUITests() {
            rooms.removeAll()
            loaded = true
            try? FileManager.default.removeItem(at: url)
        }

        public func roomsSnapshot() -> [RoomRecord] {
            loadIfNeeded()
            return Array(rooms.values)
        }

        public func record(roomKey: String) -> RoomRecord? {
            loadIfNeeded()
            return rooms[roomKey]
        }

        public func upsert(_ record: RoomRecord) {
            loadIfNeeded()
            rooms[record.roomKey] = record
            persist()
        }

        public func disband(roomKey: String, at timestamp: Double) {
            loadIfNeeded()
            guard var record = rooms[roomKey] else { return }
            record.disbandedAt = timestamp
            rooms[roomKey] = record
            persist()
        }

        public func rename(roomKey: String, to name: String, at timestamp: Double) {
            loadIfNeeded()
            guard var record = rooms[roomKey] else { return }
            record.name = name
            record.renamedAt = timestamp
            rooms[roomKey] = record
            persist()
        }

        /// Append events and return the updated record.
        @discardableResult
        public func append(events newEvents: [EventRecord], to roomKey: String) -> RoomRecord? {
            loadIfNeeded()
            guard var record = rooms[roomKey] else { return nil }
            record.events.append(contentsOf: newEvents)
            rooms[roomKey] = record
            persist()
            return record
        }
    }

    // MARK: - Projection to FleetRoom

    /// Render a persisted record as the FleetRoom row the Groups list shows.
    public static func fleetRoom(for record: RoomRecord) -> FleetRoom {
        let members: [FleetRoomMember] = record.members.map { ref in
            FleetRoomMember(name: ref.displayName, handle: ref.routeID, connectionLabel: ref.gatewayID)
        }
        let hostedState = HostedRoomState(
            authorityGatewayID: BridgedRooms.gatewayScope.rawValue,
            authorityEpoch: 1,
            latestSeq: record.events.last?.seq,
            createdAt: record.createdAt,
            updatedAt: record.events.last?.createdAt ?? record.createdAt,
            disbandedAt: record.disbandedAt,
            advertisedMethods: [
                "groups.log", "groups.send", "groups.rename", "groups.disband"
            ],
            driverAvailable: true)
        let recent = record.events.compactMap { event -> FleetRoomMessage? in
            guard event.kind == "message.user" || event.kind == "message.member" else { return nil }
            return FleetRoomMessage(
                id: event.eventID,
                from: FleetRoomMessage.Actor(
                    kind: event.actorKind == "user" ? .user : .member,
                    name: event.actorDisplayName ?? event.actorID,
                    source: event.actorProfile),
                text: event.payloadText ?? "",
                at: event.createdAt * 1000)
        }
        return FleetRoom(
            id: FleetRoomID(
                provenance: .hosted, gatewayID: BridgedRooms.gatewayScope, key: record.roomKey),
            name: record.name,
            members: members,
            recentLog: recent,
            revision: record.events.count,
            isDeleted: false,
            hosted: hostedState)
    }
}
