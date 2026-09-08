import Foundation

// MARK: - Replay source seam (Bot Mode stabilization)

/// Authority-side room data needed to replicate: the room's identity/profile
/// (name + members verbatim from the authority) and its monotonic log pages.
/// Declared in FleetCore so FleetUI never imports FleetNetworking; implemented
/// app-side over `groups.state` + `groups.log`.
public protocol RoomReplaySourceProviding: Sendable {
    /// `groups.state` room row: name + members as the authority stores them.
    func roomProfile(roomID: String) async throws -> RoomReplayProfile
    /// One `groups.log` page after `sinceSeq` (verbatim upstream page shape:
    /// events/cursor/latest_seq/has_more/authority).
    func logPage(roomID: String, sinceSeq: Int) async throws -> RoomReplayLogPage
}

/// Authority room identity needed by `groups.replicate` (room_name + members
/// must be the authority's own values — verbatim from `groups.state`).
public struct RoomReplayProfile: Sendable, Equatable {
    public let roomID: String
    public let name: String
    /// Members exactly as the authority stores them (a JSON array value).
    public let members: MetadataValue
    /// The authority lineage the room row reported at read time.
    public let authorityGatewayID: String
    public let authorityEpoch: Int

    public init(
        roomID: String, name: String, members: MetadataValue,
        authorityGatewayID: String, authorityEpoch: Int
    ) {
        self.roomID = roomID
        self.name = name
        self.members = members
        self.authorityGatewayID = authorityGatewayID
        self.authorityEpoch = authorityEpoch
    }
}

/// One verbatim `groups.log` result (upstream `read_events` page:
/// {events, cursor, latest_seq, has_more, authority}). The page value is
/// carried as-parsed and submitted to `groups.replicate` VERBATIM — authority
/// lineage and sequence data are never rebuilt, resorted, or truncated
/// client-side. The decoded cursor/latestSeq/authority fields exist ONLY for
/// choreography decisions (paging, gap and regression guards).
public struct RoomReplayLogPage: Sendable, Equatable {
    public let roomID: String
    /// The verbatim page object exactly as the authority returned it.
    public let page: MetadataValue
    public let cursor: Int
    public let latestSeq: Int
    public let hasMore: Bool
    public let authorityGatewayID: String
    public let authorityEpoch: Int

    public init(
        roomID: String, page: MetadataValue, cursor: Int, latestSeq: Int,
        hasMore: Bool, authorityGatewayID: String, authorityEpoch: Int
    ) {
        self.roomID = roomID
        self.page = page
        self.cursor = cursor
        self.latestSeq = latestSeq
        self.hasMore = hasMore
        self.authorityGatewayID = authorityGatewayID
        self.authorityEpoch = authorityEpoch
    }
}

/// `groups.replicate` sink (the wire call on the target replica gateway).
public protocol RoomReplicateSink: Sendable {
    func replicate(
        roomID: String, roomName: String, members: MetadataValue, page: MetadataValue
    ) async throws -> RoomReplicateReceipt
}

// MARK: - Manual replication choreography (defect-2 fix)

/// Typed failures for manual replication.
public enum RoomReplicationFailure: Error, Hashable, Sendable, Equatable {
    /// A log page carried an older authority epoch than previously seen
    /// (upstream ingest refuses epoch regressions).
    case epochRegression(observed: Int, stored: Int)
    /// The log page authority does not match the room-profile authority —
    /// takeover or fencing happened mid-replay; restart the choreography.
    case authorityChangedMidReplay
    /// Pages keep arriving without cursor progress (defensive bound against
    /// a misbehaving authority; also covers the max-page budget).
    case noProgress(cursor: Int)
    /// Room profile missing name/members — a valid replicate cannot be
    /// assembled (never send placeholder metadata).
    case incompleteRoomProfile
}

/// Manual `Replicate Now` choreography, pure and testable:
/// 1. read the authority room profile (`groups.state`) for the real room
///    name, members, and authority lineage;
/// 2. page `groups.log` starting at the replica's last stored sequence
///    (0 for a fresh replica);
/// 3. submit each page VERBATIM to `groups.replicate` on the target replica
///    gateway (upstream `ingest_page` is idempotent, refuses sequence gaps
///    and epoch regressions — the same rules enforced client-side here so
///    the failure is honest BEFORE the wire);
/// 4. repeat until the receipt reports caught_up, with cursor-progress and
///    page-budget bounds so a misbehaving authority cannot loop forever.
public enum RoomReplicator {
    /// Bound on pages pulled in one manual replication run.
    public static let maxPages = 256

    public struct Outcome: Sendable, Equatable {
        public let storedSeq: Int
        public let ingested: Int
        public let caughtUp: Bool
        public let pages: Int
        public let lastAuthorityGatewayID: String
        public let lastAuthorityEpoch: Int
    }

    /// Drive replication for one room.
    /// - Parameters:
    ///   - roomID: the room to replicate.
    ///   - replica: the current replica state on the TARGET gateway
    ///     (nil = no replica yet; replay starts at sequence 0).
    ///   - source: the authority replay surface (`groups.state`+`groups.log`).
    ///   - sink: `groups.replicate` on the target replica gateway.
    public static func replicate(
        roomID: String,
        replica: RoomReplicaState?,
        source: any RoomReplaySourceProviding,
        sink: any RoomReplicateSink
    ) async throws -> Outcome {
        // 1. Room identity from the authority — name + members verbatim.
        let profile = try await source.roomProfile(roomID: roomID)
        guard !profile.name.isEmpty, case .array = profile.members else {
            throw RoomReplicationFailure.incompleteRoomProfile
        }

        var sinceSeq = replica?.lastSeq ?? 0
        var lineage: (gatewayID: String, epoch: Int)?
        var totalIngested = 0
        var storedSeq = sinceSeq
        var pageCount = 0

        while true {
            pageCount += 1
            guard pageCount <= maxPages else {
                throw RoomReplicationFailure.noProgress(cursor: sinceSeq)
            }
            // 2. One verbatim log page.
            let logPage = try await source.logPage(roomID: roomID, sinceSeq: sinceSeq)
            // 3a. Lineage continuity: epoch must never regress across pages,
            //     and the page authority must be the profile's authority.
            if let lineage {
                guard logPage.authorityEpoch >= lineage.epoch else {
                    throw RoomReplicationFailure.epochRegression(
                        observed: logPage.authorityEpoch, stored: lineage.epoch)
                }
            }
            guard logPage.authorityGatewayID == profile.authorityGatewayID,
                  logPage.authorityEpoch >= profile.authorityEpoch else {
                throw RoomReplicationFailure.authorityChangedMidReplay
            }
            lineage = (logPage.authorityGatewayID, logPage.authorityEpoch)
            // 3b. Submit the page VERBATIM — room identity from the profile,
            //     the page exactly as the authority produced it.
            let receipt = try await sink.replicate(
                roomID: roomID, roomName: profile.name, members: profile.members,
                page: logPage.page)
            totalIngested += receipt.ingested
            storedSeq = max(storedSeq, receipt.storedSeq)
            // 4. Caught up per the replica's own receipt — done.
            if receipt.caughtUp { break }
            // Not caught up: the next page must advance past this cursor.
            guard logPage.cursor > sinceSeq else {
                throw RoomReplicationFailure.noProgress(cursor: logPage.cursor)
            }
            sinceSeq = logPage.cursor
        }

        return Outcome(
            storedSeq: storedSeq,
            ingested: totalIngested,
            caughtUp: true,
            pages: pageCount,
            lastAuthorityGatewayID: lineage?.gatewayID ?? profile.authorityGatewayID,
            lastAuthorityEpoch: lineage?.epoch ?? profile.authorityEpoch)
    }
}
