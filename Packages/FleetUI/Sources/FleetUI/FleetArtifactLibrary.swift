import Foundation
import FleetCore

/// Card D — the device-local artifact library: every generated-image artifact
/// this device has OBSERVED, with the gateway + source conversation that
/// cited it. This is the Artifacts destination's honest content source: the
/// gateway publishes no media-listing API (only `GET /api/media?path=`, card
/// C), so nothing here is invented fleet-wide state — each row says where the
/// artifact came from and retrieval is attempted live, with expiration
/// surfaced truthfully.
///
/// Truth contract:
/// - Identity is source-qualified: `gateway + host path`. The same basename
///   on another gateway is a DIFFERENT artifact and stays a separate row.
/// - The host path is transport material (how to ask THIS gateway for the
///   bytes); it is never rendered and never logged — UI uses `name` only.
/// - `record` is an upsert keyed by identity, so a replayed/re-observed
///   citation never duplicates a row (it refreshes metadata + recency).
/// - Pruned when its gateway is removed — a saved row must not resolve to
///   another gateway.
/// - Device-local by construction: a fleet-wide sync of artifact lists does
///   not exist and is not simulated.
public final class FleetArtifactLibrary: @unchecked Sendable {

    /// One recorded observation.
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        /// Source-qualified identity: `artifact|<gatewayID>|<path>`.
        public let id: String
        public let gatewayIDRaw: String
        /// The originating conversation on that gateway, when the citation
        /// came from one (nil for a non-conversation source).
        public let sessionID: String?
        public let profile: String?
        /// Gateway-local path — transport material; NEVER displayed.
        public let path: String
        /// Basename for display.
        public let name: String
        public let mimeType: String?
        public let byteCount: Int?
        /// Source conversation title at capture time (display only).
        public let sourceTitle: String?
        /// Source conversation subtitle (bot + gateway label) at capture time.
        public let sourceSubtitle: String?
        public let observedAt: Date

        public init(
            id: String,
            gatewayIDRaw: String,
            sessionID: String? = nil,
            profile: String? = nil,
            path: String,
            name: String,
            mimeType: String? = nil,
            byteCount: Int? = nil,
            sourceTitle: String? = nil,
            sourceSubtitle: String? = nil,
            observedAt: Date
        ) {
            self.id = id
            self.gatewayIDRaw = gatewayIDRaw
            self.sessionID = sessionID
            self.profile = profile
            self.path = path
            self.name = name
            self.mimeType = mimeType
            self.byteCount = byteCount
            self.sourceTitle = sourceTitle
            self.sourceSubtitle = sourceSubtitle
            self.observedAt = observedAt
        }

        /// Rebuild the provenance-bound reference for a recorded row.
        public var gatewayID: GatewayID { GatewayID(rawValue: gatewayIDRaw) }

        public var reference: ArtifactReference {
            ArtifactReference(
                gatewayID: gatewayID,
                sessionID: sessionID,
                profile: profile,
                path: path,
                name: name,
                mimeType: mimeType,
                byteCount: byteCount)
        }
    }

    /// Bounded device-local catalogue (newest observations win).
    public static let maxEntries = 100

    private let url: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cache: [Entry]

    public init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            cache = decoded
        } else {
            cache = []
        }
    }

    /// Default production location (Application Support, app container).
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("fleet-artifact-library.json")
    }

    // MARK: reads

    /// Newest-first observations, capped.
    public func entries() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return Array(cache.sorted { $0.observedAt > $1.observedAt }.prefix(Self.maxEntries))
    }

    /// Newest-first observations for one gateway.
    public func entries(for gatewayID: GatewayID) -> [Entry] {
        entries().filter { $0.gatewayIDRaw == gatewayID.rawValue }
    }

    // MARK: writes

    /// Record one observed artifact. Identity is `gateway + path`: a repeated
    /// observation updates the existing row (metadata + recency) instead of
    /// duplicating it — the dedupe contract for replayed turns.
    public func record(
        reference: ArtifactReference,
        sourceTitle: String?,
        sourceSubtitle: String?
    ) {
        record(Entry(
            id: Self.identity(for: reference),
            gatewayIDRaw: reference.gatewayID.rawValue,
            sessionID: reference.sessionID,
            profile: reference.profile,
            path: reference.path,
            name: reference.name,
            mimeType: reference.mimeType,
            byteCount: reference.byteCount,
            sourceTitle: Self.bounded(sourceTitle),
            sourceSubtitle: Self.bounded(sourceSubtitle),
            observedAt: now()))
    }

    private func record(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll { $0.id == entry.id }
        cache.insert(entry, at: 0)
        persistLocked(Array(cache.prefix(Self.maxEntries)))
    }

    /// Remove every observation belonging to a removed gateway.
    public func prune(gatewayID: GatewayID) {
        lock.lock(); defer { lock.unlock() }
        persistLocked(cache.filter { $0.gatewayIDRaw != gatewayID.rawValue })
    }

    /// Drop observations whose gateway is no longer registered.
    public func pruneToRegisteredGateways(_ rawIDs: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        persistLocked(cache.filter { rawIDs.contains($0.gatewayIDRaw) })
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        persistLocked([])
    }

    // MARK: identity

    public static func identity(for reference: ArtifactReference) -> String {
        "artifact|\(reference.gatewayID.rawValue)|\(reference.path)"
    }

    private static func bounded(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(160))
    }

    // MARK: persistence

    private func persistLocked(_ entries: [Entry]) {
        cache = entries
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }
}
