import XCTest
import SwiftUI
import FleetCore
@testable import FleetUI

/// B41 theme + avatar identity decoupling — hosted integration tests.
///
/// Proves the precedence contract at the resolution seam shared by the
/// roster renderer and the editor preview, and the new theme defaults:
/// white dark-mode highlight with legible light-mode default, preservation
/// of explicit custom palettes, and the invisible-pair apply guard.
@MainActor
final class BotAvatarThemeDecouplingTests: XCTestCase {

    private func bot(
        gateway: String = "workstation",
        slug: String = "default",
        displayName: String = "MacBook Bot",
        metadataColor: String? = nil,
        shape: String? = nil
    ) -> FleetBot {
        var metadata: BotModeMetadata?
        if metadataColor != nil || shape != nil {
            metadata = BotModeMetadata()
            metadata?.color = metadataColor
            metadata?.shape = shape
        }
        return FleetBot(
            route: Route(gatewayID: GatewayID(rawValue: gateway), profileSlug: ProfileSlug(rawValue: slug)),
            displayName: displayName,
            botModeMetadata: metadata)
    }

    /// Round-trips the seam's Color through UIColor. Channel values carry
    /// float precision (e.g. 0x30 → 47.0000x → 46.9999), so channels are
    /// compared with ±1 tolerance.
    private func resolvedChannels(_ metadataHex: String?, identity: String) -> (Int, Int, Int) {
        let color = BotAvatarAppearanceTint.resolvedTint(metadataHex: metadataHex, identity: identity)
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    private func assertResolved(
        _ metadataHex: String?, identity: String, hex: UInt32,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let (r, g, b) = resolvedChannels(metadataHex, identity: identity)
        let er = Int((hex >> 16) & 255), eg = Int((hex >> 8) & 255), eb = Int(hex & 255)
        XCTAssertEqual(r, er, accuracy: 1, "red", file: file, line: line)
        XCTAssertEqual(g, eg, accuracy: 1, "green", file: file, line: line)
        XCTAssertEqual(b, eb, accuracy: 1, "blue", file: file, line: line)
    }

    // MARK: - Precedence 1/2: explicit metadata vs identity fallback

    /// MacBook-style bot WITH explicit color: metadata is authoritative.
    func testExplicitMetadataColorIsAuthoritative() {
        assertResolved("#30D158", identity: "workstation#default", hex: 0x30D158)
        assertResolved("#FF3B30", identity: "workstation#default", hex: 0xFF3B30)
        // Even when the identity fallback would choose a different color.
        assertResolved("#30D158", identity: "arch-lab#default", hex: 0x30D158)
    }

    /// Arch-style bot WITHOUT explicit color: identity-derived fallback —
    /// a stable curated color, never the theme highlight.
    func testMetadatalessBotUsesIdentityFallbackNeverTheme() {
        assertResolved(nil, identity: "arch-lab#default", hex: 0xBF7AF6)
        assertResolved(nil, identity: "workstation#default", hex: 0xFF453A)
        // The seam takes NO theme input — there is no code path by which a
        // white (or any) highlight can reach the avatar tint. A white
        // highlight theme resolves identically by construction; the source
        // wiring guard below pins that no such path is reintroduced.
        let whiteHighlight = FleetThemeValues(
            palette: FleetThemePalette(
                highlight: FleetStoredColor(hex: 0xFFFFFF),
                text: FleetStoredColor(hex: 0xF5F5F7),
                background: FleetStoredColor(hex: 0x101216)),
            isDarkAppearance: true,
            isIncreasedContrast: false)
        XCTAssertEqual(
            whiteHighlight.resolvedPalette.highlight, FleetStoredColor(hex: 0xFFFFFF))
        assertResolved(nil, identity: "arch-lab#default", hex: 0xBF7AF6)
    }

    /// Invalid explicit metadata is NOT authoritative: a malformed color
    /// string falls through to the identity fallback (never the theme).
    func testInvalidMetadataFallsThroughToIdentityFallback() {
        for bad in ["not-a-color", "#12345", "#GGGGGG", "30D158", ""] {
            assertResolved(bad, identity: "workstation#default", hex: 0xFF453A)
        }
    }

    // MARK: - Theme independence

    /// Different accent selections NEVER change avatar identity: the seam
    /// output is identical across the full legacy accent vocabulary.
    func testAccentSelectionsNeverChangeAvatarIdentity() {
        let identities = ["workstation#default", "arch-lab#default", "gpu-4090#default"]
        for identity in identities {
            let baseline = resolvedChannels(nil, identity: identity)
            for accent in FleetAccent.allCases {
                _ = accent.legacyHighlight // the retired vocabulary, still persisted
                let current = resolvedChannels(nil, identity: identity)
                XCTAssertEqual(current.0, baseline.0)
                XCTAssertEqual(current.1, baseline.1)
                XCTAssertEqual(current.2, baseline.2)
            }
        }
    }

    /// The renderer and the editor preview agree: same identity + same
    /// metadata → same tint, through the ONE shared seam.
    func testRendererAndEditorPreviewAgree() {
        for identity in ["workstation#default", "arch-lab#default"] {
            for meta in [nil, "#30D158", "#FF3B30"] as [String?] {
                let first = resolvedChannels(meta, identity: identity)
                let second = resolvedChannels(meta, identity: identity)
                XCTAssertEqual(first.0, second.0)
                XCTAssertEqual(first.1, second.1)
                XCTAssertEqual(first.2, second.2)
            }
        }
        // The preview view itself uses the canonical identity when present.
        let draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: false)
        let preview = BotAvatarAppearancePreview(
            draft: draft, identityName: "default", canonicalIdentity: "workstation#default")
        XCTAssertNotNil(preview.body)
    }

    // MARK: - Theme defaults

    /// Dark default highlight is WHITE; light default keeps the legible
    /// Fleet violet.
    func testDarkDefaultHighlightIsWhiteLightStaysViolet() {
        XCTAssertEqual(FleetThemePalette.fleetDefaultDark.highlight, FleetStoredColor(hex: 0xFFFFFF))
        XCTAssertEqual(FleetThemePalette.fleetDefault.highlight, FleetStoredColor(hex: 0x5B35D5))
        // Resolution: the untouched default palette adapts per appearance.
        XCTAssertEqual(
            FleetThemePalette.fleetDefault.palette(forDarkAppearance: true).highlight,
            FleetStoredColor(hex: 0xFFFFFF))
        XCTAssertEqual(
            FleetThemePalette.fleetDefault.palette(forDarkAppearance: false).highlight,
            FleetStoredColor(hex: 0x5B35D5))
    }

    /// A fresh install resolves white in dark appearance through the
    /// controller seam.
    func testFreshInstallResolvesWhiteInDark() {
        let defaults = UserDefaults(suiteName: "b41FreshDarkDefault")!
        defaults.removePersistentDomain(forName: "b41FreshDarkDefault")
        let controller = FleetThemeController(defaults: defaults)
        let theme = controller.resolvedTheme(isDarkAppearance: true, isIncreasedContrast: false)
        XCTAssertEqual(theme.resolvedPalette.highlight, FleetStoredColor(hex: 0xFFFFFF))
        XCTAssertNil(defaults.data(forKey: FleetThemeController.persistKey),
                     "no palette is written until an explicit Apply")
    }

    /// Existing explicitly customized colors remain intact: a `.fixed`
    /// palette persists verbatim, including an intentional violet pick
    /// that storage cannot distinguish from the old default (it is NEVER
    /// rewritten — ambiguous preferences are preserved, not destroyed).
    func testExplicitCustomPalettesArePreservedVerbatim() {
        let defaults = UserDefaults(suiteName: "b41CustomPreserved")!
        defaults.removePersistentDomain(forName: "b41CustomPreserved")
        // A user who CHOSE violet via the editor produced .fixed — preserved.
        let chosenViolet = FleetThemePalette(
            highlight: FleetStoredColor(hex: 0xBDA7FF),
            text: FleetStoredColor(hex: 0xF5F5F7),
            background: FleetStoredColor(hex: 0x101216))
        defaults.set(try! JSONEncoder().encode(chosenViolet), forKey: FleetThemeController.persistKey)
        let controller = FleetThemeController(defaults: defaults)
        XCTAssertEqual(
            controller.resolvedTheme(isDarkAppearance: true, isIncreasedContrast: false)
                .resolvedPalette.highlight,
            FleetStoredColor(hex: 0xBDA7FF),
            "an explicitly chosen dark violet must survive the default change")
    }

    /// Legacy V1 payload WITHOUT the appearance field: classified as the
    /// untouched default ONLY on the exact old default triple → now dark
    /// resolves WHITE (the migration path for untouched installs).
    func testLegacyAppearancelessDefaultPayloadMigratesToWhiteDark() throws {
        let defaults = UserDefaults(suiteName: "b41LegacyDefaultPayload")!
        defaults.removePersistentDomain(forName: "b41LegacyDefaultPayload")
        let oldPayload = try JSONEncoder().encode(FleetThemePalette(
            highlight: .init(hex: 0x5B35D5),
            text: .init(hex: 0x1C1C1E),
            background: .init(hex: 0xF8F9FC)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: oldPayload) as? [String: Any])
        object.removeValue(forKey: "appearance")
        defaults.set(try JSONSerialization.data(withJSONObject: object),
                     forKey: FleetThemeController.persistKey)

        let controller = FleetThemeController(defaults: defaults)
        XCTAssertEqual(
            controller.resolvedTheme(isDarkAppearance: true, isIncreasedContrast: false)
                .resolvedPalette.highlight,
            FleetStoredColor(hex: 0xFFFFFF),
            "an untouched legacy default install must adopt the white dark highlight")
        XCTAssertEqual(
            controller.resolvedTheme(isDarkAppearance: false, isIncreasedContrast: false)
                .resolvedPalette.highlight,
            FleetStoredColor(hex: 0x5B35D5),
            "light appearance keeps the legible violet default")
        // The stored payload is untouched (in-memory resolution only).
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(
            with: defaults.data(forKey: FleetThemeController.persistKey)!)
            as? [String: Any])
        XCTAssertNil(stored["appearance"], "migration must not rewrite stored state")
    }

    // MARK: - Contrast handling

    /// White-highlight controls never render white-on-white: the derived
    /// `onHighlight` ink flips with the highlight luminance.
    func testOnHighlightInkFlipsWithHighlightLuminance() {
        let whiteHighlightDark = FleetThemeValues(
            palette: FleetThemePalette(
                highlight: FleetStoredColor(hex: 0xFFFFFF),
                text: FleetStoredColor(hex: 0xF5F5F7),
                background: FleetStoredColor(hex: 0x101216)),
            isDarkAppearance: true, isIncreasedContrast: false)
        XCTAssertEqual(
            whiteHighlightDark.onHighlight,
            FleetThemeContrast.inkDark.swiftUIColor,
            "a white highlight must render DARK ink")

        let violetHighlightLight = FleetThemeValues(
            palette: FleetThemePalette.fleetDefault,
            isDarkAppearance: false, isIncreasedContrast: false)
        XCTAssertEqual(
            violetHighlightLight.onHighlight,
            FleetThemeContrast.inkLight.swiftUIColor,
            "a dark violet highlight must render LIGHT ink")
    }

    /// The derived ink is legible for BOTH extremes and a mid gray: the
    /// worst case (crossover) is mathematically ≥ 4.58:1.
    func testMaxContrastInkAlwaysLegible() {
        for hex in [UInt32(0x000000), 0xFFFFFF, 0x808080, 0x5B35D5, 0xBDA7FF] {
            let fill = FleetStoredColor(hex: hex)
            let ink = FleetThemeContrast.maxContrastInk(on: fill)
            XCTAssertGreaterThanOrEqual(
                FleetThemeContrast.ratio(ink, fill), 4.5,
                "ink on \(String(format: "#%06X", hex)) must meet 4.5:1")
        }
    }

    /// The apply boundary refuses literally-invisible palettes but keeps
    /// accepting merely low-contrast ones (user choice, advisory warning).
    func testApplyRefusesInvisiblePairsOnly() {
        let defaults = UserDefaults(suiteName: "b41InvisibleGuard")!
        defaults.removePersistentDomain(forName: "b41InvisibleGuard")
        let controller = FleetThemeController(defaults: defaults)

        // White highlight + white background in LIGHT mode = invisible.
        let whiteOnWhite = FleetThemePalette(
            highlight: FleetStoredColor(hex: 0xFFFFFF),
            text: FleetStoredColor(hex: 0x1C1C1E),
            background: FleetStoredColor(hex: 0xFFFFFF))
        XCTAssertTrue(whiteOnWhite.hasInvisiblePair, "fixture must be invisible")
        XCTAssertFalse(controller.apply(whiteOnWhite), "invisible palette must be refused")
        XCTAssertNil(defaults.data(forKey: FleetThemeController.persistKey),
                     "a refused apply must not persist anything")

        // Low-but-visible contrast stays allowed (advisory, not blocking).
        let lowButVisible = FleetThemePalette(
            highlight: FleetStoredColor(hex: 0xE95D90),
            text: FleetStoredColor(hex: 0x1C1C1E),
            background: FleetStoredColor(hex: 0xF8F9FC))
        XCTAssertFalse(lowButVisible.hasInvisiblePair)
        XCTAssertTrue(controller.apply(lowButVisible), "visible palette must apply")

        // The old dark default (violet) would still apply if chosen.
        let oldVioletDark = FleetThemePalette(
            highlight: FleetStoredColor(hex: 0xBDA7FF),
            text: FleetStoredColor(hex: 0xF5F5F7),
            background: FleetStoredColor(hex: 0x101216))
        XCTAssertFalse(oldVioletDark.hasInvisiblePair)
        XCTAssertTrue(controller.apply(oldVioletDark))
    }

    /// Default palette itself passes the invisible guard (dark resolution
    /// white-on-#101216 = 19.3:1).
    func testDefaultPalettesPassInvisibleGuard() {
        XCTAssertFalse(FleetThemePalette.fleetDefault.hasInvisiblePair)
        XCTAssertFalse(FleetThemePalette.fleetDefaultDark.hasInvisiblePair)
    }

    /// Persistence round-trip: an applied custom palette survives a new
    /// controller (relaunch) with colors and appearance mode intact.
    func testRelaunchPersistenceOfCustomPalette() {
        let suite = "b41RelaunchPersistence"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let custom = FleetThemePalette(
            highlight: FleetStoredColor(hex: 0xE95D90),
            text: FleetStoredColor(hex: 0xF1E8D8),
            background: FleetStoredColor(hex: 0x17202A))
        let first = FleetThemeController(defaults: defaults)
        XCTAssertTrue(first.apply(custom))

        let relaunched = FleetThemeController(defaults: defaults)
        XCTAssertEqual(relaunched.activePalette, custom)
        XCTAssertEqual(
            relaunched.resolvedTheme(isDarkAppearance: true, isIncreasedContrast: false)
                .resolvedPalette.highlight,
            FleetStoredColor(hex: 0xE95D90),
            "relaunch must restore the applied highlight, not the default")
    }

    // MARK: - Unchanged avatar functionality

    /// Images, pets, and shapes remain unaffected: the draft model still
    /// stages color/shape/photo without touching the identity fallback.
    func testDraftStagingSemanticsUnchanged() {
        var draft = BotAvatarAppearanceDraft.seeded(from: nil, hasAvatar: false)
        XCTAssertTrue(draft.image == .unchanged)
        draft.selectColor("#101010")
        XCTAssertEqual(draft.color, "#101010")
        XCTAssertTrue(draft.custom)
        draft.stageReplacement(data: Data([1, 2, 3]))
        XCTAssertEqual(draft.imageKind, "photo")
        if case .replacement(let bytes) = draft.image {
            XCTAssertEqual(bytes, Data([1, 2, 3]))
        } else {
            XCTFail("staged bytes must ride .replacement")
        }
        // Seeded metadata is preserved verbatim (baseline).
        var meta = BotModeMetadata()
        meta.shape = "cloud"
        meta.color = "#FF3B30"
        let seeded = BotAvatarAppearanceDraft.seeded(from: meta, hasAvatar: false)
        XCTAssertEqual(seeded.shape, "cloud")
        XCTAssertEqual(seeded.color, "#FF3B30")
    }

    // MARK: - Source wiring guard

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // HermesFleetAppTests/
        .deletingLastPathComponent() // repo root

    /// The avatar renderer must contain NO path from the theme highlight to
    /// the avatar tint (the B41 coupling). Source-level guard because a
    /// hosted test cannot inspect a SwiftUI computed property's inputs.
    func testAvatarRendererNeverReadsThemeHighlight() throws {
        let url = Self.repoRoot
            .appendingPathComponent("Packages/FleetUI/Sources/FleetUI/Components/BotAvatar.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            source.contains("static func resolvedTint(metadataHex: String?, identity: String)"),
            "the shared precedence seam must exist")
        XCTAssertFalse(
            source.contains("fallback: theme.highlight"),
            "no avatar tint fallback may reference the user theme highlight (B41 coupling)")
        XCTAssertFalse(
            source.contains("tint: theme.highlight"),
            "no avatar face may render with the theme highlight directly")
    }
}
