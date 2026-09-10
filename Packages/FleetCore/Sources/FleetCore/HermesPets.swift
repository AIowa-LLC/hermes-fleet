import Foundation

/// Typed Petdex catalog values for the Bot-avatar Pet picker (#9).
///
/// Gateway/catalog data ONLY — these are never persisted as Bot metadata.
/// A Pet selection is an ordinary avatar image source: `pet.thumb`'s PNG
/// bytes stage into the unified appearance draft (`stageReplacement`) and
/// persist through the normal `profiles.set_asset asset:"avatar"` path.
/// There is NO `petSlug` field, NO `imageKind:"pet"`, and no Fleet-only
/// pet persistence contract.
///
/// Wire shapes (tui_gateway/methods_session.py, pet.gallery handler):
/// response `{enabled, active, pets:[{slug, displayName, installed,
/// spritesheetUrl, curated, generated}]}` — `spritesheetUrl` is "" for
/// local/installed pets, `generated` marks locally-generated pets.
public struct HermesPet: Hashable, Sendable, Identifiable, Codable {
    /// Petdex slug (unique within one gateway's catalog view).
    public var slug: String
    /// Human display name from the catalog.
    public var displayName: String
    /// Installed on the target gateway.
    public var installed: Bool
    /// Petdex hand-picked (curated) set membership.
    public var curated: Bool
    /// Locally generated pet (installed & generated on the gateway).
    public var generated: Bool
    /// Remote Petdex spritesheet URL ("" / nil for local-generated pets).
    public var spritesheetURL: String?

    public var id: String { slug }

    public init(
        slug: String,
        displayName: String,
        installed: Bool,
        curated: Bool,
        generated: Bool = false,
        spritesheetURL: String?
    ) {
        self.slug = slug
        self.displayName = displayName
        self.installed = installed
        self.curated = curated
        self.generated = generated
        self.spritesheetURL = spritesheetURL
    }

    /// The `url` param for `pet.thumb` — nil when the catalog entry has no
    /// remote sheet (installed/local/generated pets render from the
    /// gateway's own installed sheet).
    public var thumbnailSourceURL: String? {
        guard let url = spritesheetURL, !url.isEmpty else { return nil }
        return url
    }

    /// Case/diacritic-insensitive search over display name AND slug (#9:
    /// the picker matches both — display names localize, slugs are the
    /// stable Petdex identity).
    public func matches(query rawQuery: String) -> Bool {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return displayName.localizedCaseInsensitiveContains(query)
            || slug.localizedCaseInsensitiveContains(query)
    }
}

/// One `pet.gallery` response (already route-scoped by the caller).
public struct HermesPetGallery: Hashable, Sendable, Codable {
    public var pets: [HermesPet]
    /// Whether the pet DISPLAY is enabled on the gateway (informational;
    /// avatar selection never touches the animated mascot).
    public var displayEnabled: Bool
    /// Active animated pet slug, when the display is on (informational).
    public var activeSlug: String?

    public init(pets: [HermesPet], displayEnabled: Bool = false, activeSlug: String? = nil) {
        self.pets = pets
        self.displayEnabled = displayEnabled
        self.activeSlug = activeSlug
    }

    /// Two-stage merge (#9 §localOnly): local-phase entries first, then
    /// full-catalog entries not already present (by slug). A differing
    /// installed/curated/generated state for the same slug prefers the
    /// FULL-catalog row (the hydrated truth), while local-only rows that
    /// vanish from the manifest are retained (they are installed facts).
    public func merged(with hydrated: HermesPetGallery) -> HermesPetGallery {
        var bySlug: [String: HermesPet] = [:]
        var order: [String] = []
        for pet in pets + hydrated.pets {
            if bySlug[pet.slug] == nil { order.append(pet.slug) }
            bySlug[pet.slug] = pet
        }
        return HermesPetGallery(
            pets: order.compactMap { bySlug[$0] },
            displayEnabled: hydrated.displayEnabled || displayEnabled,
            activeSlug: hydrated.activeSlug ?? activeSlug)
    }
}

/// Route-aware bounded thumbnail cache (#9 §4).
///
/// Pet stores are profile-scoped and Fleet is multi-gateway: the same slug
/// can be a different local/generated pet on another machine or profile,
/// so the key MUST be the full route provenance (GatewayID + ProfileSlug +
/// PetSlug) — never the pet slug alone. Bounded LRU: entries beyond
/// `capacity` are evicted oldest-first; `totalCostBudget` bounds the sum
/// of stored byte counts.
public final class PetThumbnailCache: @unchecked Sendable {
    /// Cache key: full route provenance + pet slug.
    public struct Key: Hashable, Sendable, CustomStringConvertible {
        public let gatewayID: GatewayID
        public let profileSlug: ProfileSlug
        public let petSlug: String

        public init(gatewayID: GatewayID, profileSlug: ProfileSlug, petSlug: String) {
            self.gatewayID = gatewayID
            self.profileSlug = profileSlug
            self.petSlug = petSlug
        }

        public var description: String {
            "\(gatewayID.rawValue)#\(profileSlug.rawValue)#\(petSlug)"
        }
    }

    private let lock = NSLock()
    private var storage: [Key: Data] = [:]
    private var costs: [Key: Int] = [:]
    private var order: [Key] = []
    private let capacity: Int
    private let totalCostBudget: Int

    public init(capacity: Int = 128, totalCostBudget: Int = 4_000_000) {
        self.capacity = max(1, capacity)
        self.totalCostBudget = max(1, totalCostBudget)
    }

    /// Cached PNG bytes for a key, refreshing its recency.
    public func pngData(for key: Key) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let data = storage[key] else { return nil }
        touch(key)
        return data
    }

    /// Store PNG bytes under a key. Values whose cost alone exceeds the
    /// budget are not stored (the budget is a hard bound).
    public func set(_ data: Data, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = data
        costs[key] = data.count
        touch(key)
        evictIfNeeded()
    }

    /// Entries currently cached (diagnostics/tests).
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }

    public var totalCost: Int {
        lock.lock(); defer { lock.unlock() }
        return costs.values.reduce(0, +)
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
        costs.removeAll()
        order.removeAll()
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while storage.count > capacity || totalCostLocked > totalCostBudget {
            guard let oldest = order.first else { return }
            storage[oldest] = nil
            costs[oldest] = nil
            order.removeFirst()
        }
    }

    private var totalCostLocked: Int {
        costs.values.reduce(0, +)
    }
}
