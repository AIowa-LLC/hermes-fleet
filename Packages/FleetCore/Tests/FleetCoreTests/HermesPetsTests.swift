import XCTest
@testable import FleetCore

/// #9 — typed Pet catalog values: decoding semantics, two-stage merge,
/// dual-field search, and the route-aware bounded thumbnail cache
/// (same-slug isolation across gateways AND profiles, LRU bounds).
final class HermesPetsTests: XCTestCase {

    // MARK: - models

    func testSearchMatchesDisplayNameAndSlug() {
        let pet = HermesPet(
            slug: "spark-fox", displayName: "Spark Fox", installed: true,
            curated: false, generated: false, spritesheetURL: nil)
        XCTAssertTrue(pet.matches(query: "spark"))   // display name
        XCTAssertTrue(pet.matches(query: "fox"))
        XCTAssertTrue(pet.matches(query: "SPARK"))   // case-insensitive
        XCTAssertTrue(pet.matches(query: "spark-fox")) // slug
        XCTAssertTrue(pet.matches(query: "  "))        // blank query = all
        XCTAssertFalse(pet.matches(query: "owl"))
        XCTAssertFalse(pet.matches(query: "SparkFox")) // no cross-field glue
    }

    func testThumbnailSourceURLNilForLocalPets() {
        // Local/generated pets without a remote sheet: nil (pet.thumb
        // resolves from the installed sheet; no `url` param sent).
        let local = HermesPet(
            slug: "null-cat", displayName: "Null Cat", installed: true,
            curated: false, generated: true, spritesheetURL: nil)
        XCTAssertNil(local.thumbnailSourceURL)
        let empty = HermesPet(
            slug: "x", displayName: "X", installed: false,
            curated: false, generated: false, spritesheetURL: "")
        XCTAssertNil(empty.thumbnailSourceURL)
        // Remote catalog entry carries its Petdex sheet URL.
        let remote = HermesPet(
            slug: "pixel-owl", displayName: "Pixel Owl", installed: false,
            curated: true, generated: false,
            spritesheetURL: "https://petdex.dev/sheets/pixel-owl.png")
        XCTAssertEqual(
            remote.thumbnailSourceURL, "https://petdex.dev/sheets/pixel-owl.png")
    }

    func testTwoStageMergePrefersHydratedRowsAndRetainsLocalOnly() {
        let local = HermesPetGallery(pets: [
            HermesPet(slug: "a", displayName: "A-local", installed: true,
                      curated: false, generated: false, spritesheetURL: nil),
            HermesPet(slug: "b", displayName: "B", installed: true,
                      curated: false, generated: false, spritesheetURL: nil),
        ])
        let full = HermesPetGallery(pets: [
            // Hydrated truth for the same slug wins (installed flips).
            HermesPet(slug: "a", displayName: "A-local", installed: false,
                      curated: true, generated: false,
                      spritesheetURL: "https://petdex.dev/a.png"),
            HermesPet(slug: "c", displayName: "C", installed: false,
                      curated: false, generated: false,
                      spritesheetURL: "https://petdex.dev/c.png"),
        ])
        let merged = local.merged(with: full)
        XCTAssertEqual(merged.pets.map(\.slug), ["a", "b", "c"])
        XCTAssertEqual(merged.pets[0].installed, false)
        XCTAssertEqual(merged.pets[0].curated, true)
        // Local-only slug retained even though the manifest lacks it.
        XCTAssertEqual(merged.pets[1].slug, "b")
    }

    // MARK: - route-aware bounded cache

    func testCacheIsolatesSameSlugAcrossGatewaysAndProfiles() {
        let cache = PetThumbnailCache()
        let gw1 = GatewayID(rawValue: "workstation")
        let gw2 = GatewayID(rawValue: "render-box")
        let p1 = ProfileSlug(rawValue: "default")
        let p2 = ProfileSlug(rawValue: "researcher")

        let foxGw1 = PetThumbnailCache.Key(gatewayID: gw1, profileSlug: p1, petSlug: "spark-fox")
        let foxGw2 = PetThumbnailCache.Key(gatewayID: gw2, profileSlug: p1, petSlug: "spark-fox")
        let foxGw1P2 = PetThumbnailCache.Key(gatewayID: gw1, profileSlug: p2, petSlug: "spark-fox")

        cache.set(Data([1, 2, 3]), for: foxGw1)
        cache.set(Data([4, 5, 6]), for: foxGw2)
        cache.set(Data([7, 8, 9]), for: foxGw1P2)

        // Same pet slug, three routes → three distinct entries, never
        // cross-contaminated.
        XCTAssertEqual(cache.pngData(for: foxGw1), Data([1, 2, 3]))
        XCTAssertEqual(cache.pngData(for: foxGw2), Data([4, 5, 6]))
        XCTAssertEqual(cache.pngData(for: foxGw1P2), Data([7, 8, 9]))
        // A slug-only key does not exist — the key type makes
        // slug-only caching unrepresentable.
        XCTAssertNil(cache.pngData(for: PetThumbnailCache.Key(
            gatewayID: gw1, profileSlug: p1, petSlug: "other")))
    }

    func testCacheEvictsBeyondEntryAndCostBounds() {
        let cache = PetThumbnailCache(capacity: 3, totalCostBudget: 10)
        let gw = GatewayID(rawValue: "g")
        let p = ProfileSlug(rawValue: "default")
        func key(_ i: Int) -> PetThumbnailCache.Key {
            PetThumbnailCache.Key(gatewayID: gw, profileSlug: p, petSlug: "pet-\(i)")
        }
        cache.set(Data(repeating: 0, count: 2), for: key(0)) // cost 2
        cache.set(Data(repeating: 0, count: 2), for: key(1)) // cost 4
        cache.set(Data(repeating: 0, count: 2), for: key(2)) // cost 6
        XCTAssertEqual(cache.count, 3)
        // Entry-bound eviction: oldest (0) drops.
        cache.set(Data(repeating: 0, count: 2), for: key(3))
        XCTAssertNil(cache.pngData(for: key(0)))
        XCTAssertEqual(cache.count, 3)
        // Cost-bound eviction: a 6-byte value pushes total over 10.
        cache.set(Data(repeating: 0, count: 6), for: key(4))
        XCTAssertLessThanOrEqual(cache.totalCost, 10)
        XCTAssertLessThanOrEqual(cache.count, 3)
    }

    func testCacheRecencyProtectsTouchedEntries() {
        let cache = PetThumbnailCache(capacity: 2)
        let gw = GatewayID(rawValue: "g")
        let p = ProfileSlug(rawValue: "default")
        let k1 = PetThumbnailCache.Key(gatewayID: gw, profileSlug: p, petSlug: "one")
        let k2 = PetThumbnailCache.Key(gatewayID: gw, profileSlug: p, petSlug: "two")
        let k3 = PetThumbnailCache.Key(gatewayID: gw, profileSlug: p, petSlug: "three")
        cache.set(Data([1]), for: k1)
        cache.set(Data([2]), for: k2)
        // Touch k1 → k2 is now the LRU.
        _ = cache.pngData(for: k1)
        cache.set(Data([3]), for: k3)
        XCTAssertNotNil(cache.pngData(for: k1), "touched entry survives")
        XCTAssertNil(cache.pngData(for: k2), "LRU entry evicted")
    }
}
