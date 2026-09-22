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
    /// `gatewayLabel` (Build 76) is the human connection label (Desktop
    /// `connectionLabel`) used to qualify same-named bots across gateways;
    /// absent on Build 75 records — code falls back to `gatewayID`.
    public struct MemberRef: Hashable, Sendable, Codable {
        public let gatewayID: String
        public let profile: String
        public let displayName: String
        public let routeID: String
        public let gatewayLabel: String?

        public init(
            gatewayID: String, profile: String, displayName: String, routeID: String,
            gatewayLabel: String? = nil
        ) {
            self.gatewayID = gatewayID
            self.profile = profile
            self.displayName = displayName
            self.routeID = routeID
            self.gatewayLabel = gatewayLabel
        }

        /// Desktop `connectionLabel || connectionId`: the stable
        /// source-qualified token for cross-gateway identity.
        public var sourceLabel: String { gatewayLabel ?? gatewayID }

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
        public var bridgeSessionIDs: [String: String] = [:]
        /// Per-member delivery watermarks (Build 76, FR-04): routeID -> the
        /// highest room event `seq` included in that member's submitted group
        /// context. Absent on Build 75 records; decode falls back to `[:]`
        /// (every event is new). Advanced ONLY after an accepted submission.
        public var deliveryWatermarks: [String: Int] = [:]

        private enum CodingKeys: String, CodingKey {
            case roomKey, name, members, createdAt, disbandedAt, renamedAt,
                 events, bridgeSessionIDs, deliveryWatermarks
        }

        public init(
            roomKey: String, name: String, members: [MemberRef], createdAt: Double,
            disbandedAt: Double? = nil, renamedAt: Double? = nil, events: [EventRecord] = [],
            bridgeSessionIDs: [String: String] = [:],
            deliveryWatermarks: [String: Int] = [:]
        ) {
            self.roomKey = roomKey
            self.name = name
            self.members = members
            self.createdAt = createdAt
            self.disbandedAt = disbandedAt
            self.renamedAt = renamedAt
            self.events = events
            self.bridgeSessionIDs = bridgeSessionIDs
            self.deliveryWatermarks = deliveryWatermarks
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            roomKey = try values.decode(String.self, forKey: .roomKey)
            name = try values.decode(String.self, forKey: .name)
            members = try values.decode([MemberRef].self, forKey: .members)
            createdAt = try values.decode(Double.self, forKey: .createdAt)
            disbandedAt = try values.decodeIfPresent(Double.self, forKey: .disbandedAt)
            renamedAt = try values.decodeIfPresent(Double.self, forKey: .renamedAt)
            events = try values.decodeIfPresent([EventRecord].self, forKey: .events) ?? []
            bridgeSessionIDs = try values.decodeIfPresent([String: String].self, forKey: .bridgeSessionIDs) ?? [:]
            deliveryWatermarks = try values.decodeIfPresent([String: Int].self, forKey: .deliveryWatermarks) ?? [:]
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(roomKey, forKey: .roomKey)
            try values.encode(name, forKey: .name)
            try values.encode(members, forKey: .members)
            try values.encode(createdAt, forKey: .createdAt)
            try values.encodeIfPresent(disbandedAt, forKey: .disbandedAt)
            try values.encodeIfPresent(renamedAt, forKey: .renamedAt)
            try values.encode(events, forKey: .events)
            try values.encode(bridgeSessionIDs, forKey: .bridgeSessionIDs)
            try values.encode(deliveryWatermarks, forKey: .deliveryWatermarks)
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
        /// Set when a present store file could not be read/decoded and was
        /// moved aside (`<name>.unreadable-<stamp>.json`) instead of being
        /// overwritten by the next mutation. Nil = nothing was quarantined.
        public private(set) var quarantinedURL: URL?
        /// Lock-guarded subscriber hub. Lives OUTSIDE actor isolation so
        /// `changes()` registers subscribers SYNCHRONOUSLY — an observer
        /// that subscribes then reads state can never miss the next
        /// mutation (the async-registration race the live tail hit).
        private let changeHub = ChangeHub()

        private final class ChangeHub: @unchecked Sendable {
            private let lock = NSLock()
            private var subscribers: [UUID: AsyncStream<String>.Continuation] = [:]

            func subscribe() -> AsyncStream<String> {
                let (stream, continuation) = AsyncStream<String>.makeStream()
                let id = UUID()
                lock.lock(); defer { lock.unlock() }
                subscribers[id] = continuation
                continuation.onTermination = { [weak self] _ in
                    self?.remove(id)
                }
                return stream
            }

            private func remove(_ id: UUID) {
                lock.lock(); defer { lock.unlock() }
                subscribers.removeValue(forKey: id)
            }

            func emit(_ key: String) {
                lock.lock(); defer { lock.unlock() }
                for continuation in subscribers.values {
                    continuation.yield(key)
                }
            }
        }

        public init(url: URL) {
            self.url = url
        }

        /// Live change feed (room storage keys). Every mutation yields the
        /// mutated room's key so observers (the relay's transcriptChanges →
        /// RoomChatViewModel live tail) can re-read just that room. Yields
        /// happen AFTER the snapshot is persisted and published in memory.
        /// Nonisolated + synchronous registration: subscribe, then read
        /// current state, then iterate — an overlapping mutation is deduped
        /// by the observer's seq-keyed cache.
        public nonisolated func changes() -> AsyncStream<String> {
            changeHub.subscribe()
        }

        public static func defaultURL() -> URL {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            return base.appendingPathComponent(BridgedRooms.storeFileName)
        }

        private func loadIfNeeded() {
            guard !loaded else { return }
            loaded = true
            // "No file yet" (fresh install) and "a file we cannot read" are
            // DIFFERENT states, and only the first may leave `rooms` empty:
            // every later mutation persists the in-memory snapshot with
            // `.atomic`, so reading an unreadable file as "no rooms" would
            // overwrite the user's only copy with an empty one. A path that is
            // not a regular file at all is not our store: leave it in place so
            // writes keep failing loudly.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return }
            do {
                let data = try Data(contentsOf: url)
                rooms = try JSONDecoder().decode([String: RoomRecord].self, from: data)
            } catch {
                quarantineUnreadableStore()
            }
        }

        /// Move a present-but-unreadable store aside so its bytes survive for
        /// recovery, and surface the quarantine. A decode failure can then
        /// never be silently converted into authoritative empty state that the
        /// next mutation persists over.
        private func quarantineUnreadableStore() {
            let backup = url.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            do {
                try FileManager.default.moveItem(at: url, to: backup)
            } catch {
                return
            }
            quarantinedURL = backup
        }

        private func persist(_ snapshot: [String: RoomRecord]) throws {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
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

        public func upsert(_ record: RoomRecord) throws {
            loadIfNeeded()
            var snapshot = rooms
            snapshot[record.roomKey] = record
            try persist(snapshot)
            rooms = snapshot
            changeHub.emit(record.roomKey)
        }

        public func disband(roomKey: String, at timestamp: Double) throws {
            loadIfNeeded()
            guard var record = rooms[roomKey] else { return }
            record.disbandedAt = timestamp
            var snapshot = rooms
            snapshot[roomKey] = record
            try persist(snapshot)
            rooms = snapshot
            changeHub.emit(roomKey)
        }

        public func rename(roomKey: String, to name: String, at timestamp: Double) throws {
            loadIfNeeded()
            guard var record = rooms[roomKey] else { return }
            record.name = name
            record.renamedAt = timestamp
            var snapshot = rooms
            snapshot[roomKey] = record
            try persist(snapshot)
            rooms = snapshot
            changeHub.emit(roomKey)
        }

        /// Append events and return the updated record.
        @discardableResult
        public func append(events newEvents: [EventRecord], to roomKey: String) throws -> RoomRecord? {
            try append(events: newEvents, to: roomKey, advancingWatermarkFor: nil)
        }

        /// Append events; when `advancingWatermarkFor` names a member whose
        /// watermark already sits at the log's tail, the append extends that
        /// member's watermark past its own reply (Desktop's contiguous
        /// own-reply advance — the member never re-receives its own words).
        @discardableResult
        public func append(
            events newEvents: [EventRecord], to roomKey: String,
            advancingWatermarkFor routeID: String?
        ) throws -> RoomRecord? {
            loadIfNeeded()
            guard var record = rooms[roomKey] else { return nil }
            record.events.append(contentsOf: newEvents)
            if let routeID,
               let last = record.events.last?.seq,
               record.deliveryWatermarks[routeID] == last - newEvents.count {
                record.deliveryWatermarks[routeID] = last
            }
            var snapshot = rooms
            snapshot[roomKey] = record
            try persist(snapshot)
            rooms = snapshot
            changeHub.emit(roomKey)
            return record
        }

        /// Advance one member's delivery watermark to `seq` (Build 76,
        /// FR-04). Monotonic: a stale turn can never move a watermark
        /// backwards past events another turn already delivered.
        public func advanceDeliveryWatermark(roomKey: String, routeID: String, to seq: Int) throws {
            loadIfNeeded()
            guard var record = rooms[roomKey] else { return }
            let current = record.deliveryWatermarks[routeID] ?? 0
            guard seq > current else { return }
            record.deliveryWatermarks[routeID] = seq
            var snapshot = rooms
            snapshot[roomKey] = record
            try persist(snapshot)
            rooms = snapshot
        }

        public func setBridgeSessionID(roomKey: String, routeID: String, sessionID: String) throws {
            loadIfNeeded()
            guard var record = rooms[roomKey] else { return }
            record.bridgeSessionIDs[routeID] = sessionID
            var snapshot = rooms
            snapshot[roomKey] = record
            try persist(snapshot)
            rooms = snapshot
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
                "groups.log", "groups.send", "groups.rename", "groups.disband",
                "groups.stop", "groups.retry"
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
