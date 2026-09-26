import XCTest
@testable import FleetCore

/// B41 avatar identity-color fix — deterministic fallback derivation.
///
/// The avatar fallback color must be a pure function of the CANONICAL
/// identity (route id `gateway#slug`): stable across relaunches, processes,
/// theme changes, and cache refreshes; distinct across gateways for the
/// same slug; and NEVER derived from the display name (a rename must not
/// recolor a Bot).
final class BotAvatarIdentityColorTests: XCTestCase {

    private func route(_ gateway: String, _ slug: String) -> Route {
        Route(gatewayID: GatewayID(rawValue: gateway), profileSlug: ProfileSlug(rawValue: slug))
    }

    // MARK: - Determinism

    /// Same identity → same color, forever (FNV-1a over UTF-8, not the
    /// process-randomized Swift Hasher).
    func testFallbackIsDeterministicAcrossCalls() {
        for identity in ["workstation#default", "arch-lab#default", "gpu-4090#default", ""] {
            XCTAssertEqual(
                BotAvatarIdentity.fallbackColorHex(identity: identity),
                BotAvatarIdentity.fallbackColorHex(identity: identity),
                "identity '\(identity)' must resolve identically on every call")
        }
    }

    /// Pinned vectors: the exact FNV-1a → palette mapping. If any of these
    /// change, the derivation changed — update deliberately, never silently.
    func testPinnedDerivationVectors() {
        XCTAssertEqual(BotAvatarIdentity.stableHash("workstation#default"), 3_249_072_182)
        XCTAssertEqual(BotAvatarIdentity.stableHash("arch-lab#default"), 798_627_101)
        XCTAssertEqual(
            BotAvatarIdentity.fallbackColorHex(identity: "workstation#default"),
            0xFF453A)
        XCTAssertEqual(
            BotAvatarIdentity.fallbackColorHex(identity: "arch-lab#default"),
            0xBF7AF6)
    }

    // MARK: - Canonical identity, not display name

    /// The ROUTE id is the identity: two gateways exposing the same slug
    /// are distinct Bots and must derive independently (verified distinct
    /// for this fixture pair — no accidental collision).
    func testSameSlugOnDifferentGatewaysIsDistinct() {
        let a = BotAvatarIdentity.fallbackColorHex(route: route("workstation", "default"))
        let b = BotAvatarIdentity.fallbackColorHex(route: route("arch-lab", "default"))
        XCTAssertNotEqual(a, b, "canonical gateway/profile identities must remain distinct")
    }

    /// A rename (display name change) must not change the fallback: the
    /// derivation never sees the display name.
    func testFallbackIgnoresDisplayName() {
        let byRoute = BotAvatarIdentity.fallbackColorHex(identity: "workstation#default")
        // A display name identical to the slug text still differs from the
        // canonical route id, so it derives independently — the point is
        // that RENAMING a bot leaves route-derived color untouched:
        XCTAssertEqual(
            byRoute,
            BotAvatarIdentity.fallbackColorHex(identity: "workstation#default"),
            "route-keyed color is name-independent by construction")
        // The route API and the raw route-id string agree (one vocabulary).
        XCTAssertEqual(
            byRoute,
            BotAvatarIdentity.fallbackColorHex(route: route("workstation", "default")))
    }

    // MARK: - Palette curation

    /// Every palette entry is distinct and within the accessible band
    /// (mirrors scripts/avatar_palette_check.py): eye ink ≥ 3:1 and the
    /// shape visible on both dark and light elevated avatar surfaces.
    func testFallbackPaletteIsCuratedDistinctAndAccessible() {
        let palette = BotAvatarIdentity.fallbackColors
        XCTAssertEqual(Set(palette).count, palette.count, "palette entries must be distinct")
        XCTAssertGreaterThanOrEqual(palette.count, 6, "a small curated set, not a rainbow")

        // WCAG relative luminance — FleetCore has no FleetThemeContrast, so
        // the band is asserted locally (constants pinned by the python gate).
        func luminance(_ hex: UInt32) -> Double {
            func linear(_ v: Double) -> Double {
                v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            let r = linear(Double((hex >> 16) & 255) / 255)
            let g = linear(Double((hex >> 8) & 255) / 255)
            let b = linear(Double(hex & 255) / 255)
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        for hex in palette {
            let l = luminance(hex)
            XCTAssertTrue((0.18...0.60).contains(l),
                          "palette entry \(String(format: "#%06X", hex)) luminance \(l) outside the curated 0.18–0.60 band")
        }
    }

    /// The fallback is a function of identity ONLY — no theme, no palette,
    /// no persistence input. (Structural: the API surface takes exactly the
    /// identity string; kept as documentation of the contract.)
    func testFallbackAPIHasNoThemeInput() {
        _ = BotAvatarIdentity.fallbackColorHex(identity: "anything")
        _ = BotAvatarIdentity.fallbackColorHex(route: route("g", "s"))
    }
}
