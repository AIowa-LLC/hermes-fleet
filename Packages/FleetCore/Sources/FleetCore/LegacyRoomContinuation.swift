import Foundation

/// Legacy → hosted room continuation policy (diagnostic 2026-09-15, fix B).
///
/// A Desktop legacy projection room (`hermes-bots-groups` v3) can be
/// continued as an authoritative hosted room via an idempotent
/// `groups.create` that reuses the projection's durable room id —
/// equality-by-construction becomes the Desktop ↔ hosted identity link.
///
/// Identity rules (fail closed everywhere):
/// - Only the id-keyed projection generation (`id:<roomId>`) carries a
///   durable id. `name:<name>` keys yield nothing — Fleet never derives a
///   hosted identity from a display name.
/// - A legacy member verifies against the gateway roster ONLY by profile
///   slug equality (the roster's durable per-gateway identity). Roster
///   display names are never consulted as identity. Cross-machine members
///   (non-local connections) cannot verify against a local roster.
public enum LegacyRoomContinuation {

    /// The projection's id-keyed room-key prefix (group-chat.ts roomKey()).
    public static let legacyIDKeyPrefix = "id:"
    /// The connectionId the projection assigns to this-device members.
    public static let localConnectionID = "local"

    // MARK: - durable identity

    /// The hosted `room_id` a legacy room can legitimately reuse, or `nil`
    /// when no durable id is provable.
    ///
    /// The bare id must also satisfy the hosted identifier charset
    /// (gateway/hosted_rooms_common.py IDENTIFIER_RE) — a projection key
    /// that cannot be a hosted room_id is not a bridge.
    public static func durableHostedRoomID(for room: FleetRoom) -> String? {
        guard room.id.provenance == .desktopLegacy,
              room.id.key.hasPrefix(legacyIDKeyPrefix) else { return nil }
        let bare = String(room.id.key.dropFirst(legacyIDKeyPrefix.count))
        guard !bare.isEmpty, HostedRoomMemberCodec.isValidIdentifier(bare) else { return nil }
        return bare
    }

    // MARK: - member verification

    /// Member verification outcome: roster-verified candidates plus the
    /// projected member names that could not be verified locally.
    public struct VerifiedMembers: Sendable, Equatable {
        public let candidates: [RoomMemberCandidate]
        public let unresolved: [String]

        public init(candidates: [RoomMemberCandidate], unresolved: [String]) {
            self.candidates = candidates
            self.unresolved = unresolved
        }
    }

    /// Verify projected members against a gateway roster.
    ///
    /// - Local members match by profile-name equality against roster
    ///   profile slugs (same namespace: profile names on this gateway);
    ///   first occurrence wins and duplicates by route collapse.
    /// - Cross-machine members never match a local roster; they surface as
    ///   unresolved only when no local member of the same profile name
    ///   resolved (a covered duplicate adds no information).
    public static func verifiedCandidates(
        members: [FleetRoomMember], roster: [RoomMemberCandidate]
    ) -> VerifiedMembers {
        var rosterBySlug: [String: RoomMemberCandidate] = [:]
        for candidate in roster {
            let slug = candidate.route.profileSlug.rawValue
            if rosterBySlug[slug] == nil { rosterBySlug[slug] = candidate }
        }
        var candidates: [RoomMemberCandidate] = []
        var unresolvedLocal: [String] = []
        var remoteNames: [String] = []
        var resolvedSlugs = Set<String>()
        for member in members {
            if member.connectionID == localConnectionID {
                let slug = member.name
                if resolvedSlugs.contains(slug) { continue }
                if let candidate = rosterBySlug[slug] {
                    resolvedSlugs.insert(slug)
                    candidates.append(candidate)
                } else {
                    unresolvedLocal.append(member.name)
                }
            } else {
                remoteNames.append(member.name)
            }
        }
        let uncoveredRemote = remoteNames.filter { !resolvedSlugs.contains($0) }
        return VerifiedMembers(
            candidates: candidates,
            unresolved: unresolvedLocal + uncoveredRemote)
    }

    // MARK: - continuation plan

    /// Why a legacy room can or cannot be continued right now.
    public enum Status: Hashable, Sendable {
        /// Durable id present and enough members verified — `groups.create`
        /// with the reused room id is offered.
        case ready
        /// No durable id (name-keyed projection generation) — continuation
        /// is never offered for this room.
        case missingDurableID
        /// Fewer than the hosted minimum verified — the action explains
        /// which members did not resolve.
        case insufficientMembers(resolved: Int, minimum: Int)
    }

    /// Fully-computed continuation decision for one legacy room.
    public struct Plan: Sendable {
        public let status: Status
        /// The durable hosted room id (nil unless an id-keyed room).
        public let roomID: String?
        /// Verified roster candidates (empty unless ready).
        public let candidates: [RoomMemberCandidate]
        /// Projected member names that did not verify locally.
        public let unresolvedMembers: [String]

        public init(
            status: Status,
            roomID: String?,
            candidates: [RoomMemberCandidate],
            unresolvedMembers: [String]
        ) {
            self.status = status
            self.roomID = roomID
            self.candidates = candidates
            self.unresolvedMembers = unresolvedMembers
        }
    }

    /// Compute the continuation plan for a legacy room against a roster.
    public static func plan(for room: FleetRoom, roster: [RoomMemberCandidate]) -> Plan {
        guard let roomID = durableHostedRoomID(for: room) else {
            return Plan(
                status: .missingDurableID, roomID: nil,
                candidates: [], unresolvedMembers: [])
        }
        let verified = verifiedCandidates(members: room.members, roster: roster)
        let status: Status = verified.candidates.count >= RoomCreateDraft.minMembers
            ? .ready
            : .insufficientMembers(
                resolved: verified.candidates.count,
                minimum: RoomCreateDraft.minMembers)
        return Plan(
            status: status,
            roomID: roomID,
            candidates: verified.candidates,
            unresolvedMembers: verified.unresolved)
    }
}
