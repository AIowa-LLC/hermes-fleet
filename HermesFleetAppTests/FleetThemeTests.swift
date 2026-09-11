import XCTest
import SwiftUI
import UIKit
@testable import FleetUI

/// FOS-7 (SPEC §14) drift guard: the fixed Fleet violet interactive token,
/// the semantic status palette, opaque canvas/grouped surfaces, and system
/// label/separator resolution are all PINNED here in both light and dark
/// appearances. The accent picker is retired (V7.5 pins live in git
/// history): FleetTheme.accent must resolve to the fixed Fleet violet
/// regardless of any persisted FleetAccentController selection.
@MainActor
final class FleetThemeTests: XCTestCase {

    /// Hermetic accent state: a long-lived simulator may carry a persisted
    /// V7.5 pick ("gold" etc.). FOS-7 no longer APPLIES the pick, but keep
    /// the fixture discipline of pinning + restoring so assertions never
    /// depend on interactive-app leftovers.
    private var savedAccentRaw: String?

    override func setUp() {
        super.setUp()
        savedAccentRaw = UserDefaults.standard.string(forKey: FleetAccentController.persistKey)
        FleetAccentController.shared.selection = .gold
    }

    override func tearDown() {
        if let raw = savedAccentRaw {
            UserDefaults.standard.set(raw, forKey: FleetAccentController.persistKey)
        } else {
            UserDefaults.standard.removeObject(forKey: FleetAccentController.persistKey)
        }
        FleetAccentController.shared.selection = FleetAccent(rawValue: savedAccentRaw ?? "") ?? .default
        super.tearDown()
    }

    // MARK: - Helpers

    private func assertResolvedHex(
        _ color: Color, hex: UInt32, alpha: CGFloat = 1,
        traits: UITraitCollection, name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let resolved = UIColor(color).resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, CGFloat((hex >> 16) & 0xFF) / 255, accuracy: 0.001, "\(name) red", file: file, line: line)
        XCTAssertEqual(g, CGFloat((hex >> 8) & 0xFF) / 255, accuracy: 0.001, "\(name) green", file: file, line: line)
        XCTAssertEqual(b, CGFloat(hex & 0xFF) / 255, accuracy: 0.001, "\(name) blue", file: file, line: line)
        XCTAssertEqual(a, alpha, accuracy: 0.001, "\(name) alpha", file: file, line: line)
    }

    private func assertSystemResolved(
        _ theme: Color, system: UIColor,
        appearance: UIUserInterfaceStyle, name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let traits = UITraitCollection(userInterfaceStyle: appearance)
        let resolved = UIColor(theme).resolvedColor(with: traits)
        let expected = system.resolvedColor(with: traits)
        var rr: CGFloat = 0, rg: CGFloat = 0, rb: CGFloat = 0, ra: CGFloat = 0
        var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0, ea: CGFloat = 0
        resolved.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)
        expected.getRed(&er, green: &eg, blue: &eb, alpha: &ea)
        XCTAssertEqual(rr, er, accuracy: 0.001, "\(name) red (system-resolved)", file: file, line: line)
        XCTAssertEqual(rg, eg, accuracy: 0.001, "\(name) green (system-resolved)", file: file, line: line)
        XCTAssertEqual(rb, eb, accuracy: 0.001, "\(name) blue (system-resolved)", file: file, line: line)
        XCTAssertEqual(ra, ea, accuracy: 0.001, "\(name) alpha (system-resolved)", file: file, line: line)
    }

    private var light: UITraitCollection { UITraitCollection(userInterfaceStyle: .light) }
    private var dark: UITraitCollection { UITraitCollection(userInterfaceStyle: .dark) }

    // MARK: - Interactive: fixed Fleet violet (SPEC §14)

    /// The accent is FIXED and must IGNORE any persisted V7.5 pick (setUp
    /// deliberately persists "gold" for every test in this class).
    func testAccentIsFixedFleetVioletAndIgnoresRetiredPick() {
        assertResolvedHex(FleetTheme.accent, hex: 0x5B35D5, traits: light, name: "accent light")
        assertResolvedHex(FleetTheme.accent, hex: 0xBDA7FF, traits: dark, name: "accent dark")
        // Direct proof: mutating the retired controller changes nothing.
        FleetAccentController.shared.selection = .green
        assertResolvedHex(FleetTheme.accent, hex: 0x5B35D5, traits: light, name: "accent light (pick=green)")
        assertResolvedHex(FleetTheme.accent, hex: 0xBDA7FF, traits: dark, name: "accent dark (pick=green)")
    }

    /// Increase Contrast interactive variants (SPEC §14).
    func testAccentHighContrastVariants() {
        let hcLight = UITraitCollection(traitsFrom: [light, UITraitCollection(accessibilityContrast: .high)])
        let hcDark = UITraitCollection(traitsFrom: [dark, UITraitCollection(accessibilityContrast: .high)])
        assertResolvedHex(FleetTheme.accent, hex: 0x422093, traits: hcLight, name: "accent HC light")
        assertResolvedHex(FleetTheme.accent, hex: 0xD5C7FF, traits: hcDark, name: "accent HC dark")
    }

    // MARK: - Semantic status tokens (SPEC §14 table)

    func testStatusTokensPinSpecificationValues() {
        assertResolvedHex(FleetTheme.statusOnline, hex: 0x176B46, traits: light, name: "online light")
        assertResolvedHex(FleetTheme.statusOnline, hex: 0x73D6A0, traits: dark, name: "online dark")

        assertResolvedHex(FleetTheme.statusExecuting, hex: 0x006D87, traits: light, name: "executing light")
        assertResolvedHex(FleetTheme.statusExecuting, hex: 0x65D9F0, traits: dark, name: "executing dark")

        assertResolvedHex(FleetTheme.statusNeedsIntervention, hex: 0x865400, traits: light, name: "needsIntervention light")
        assertResolvedHex(FleetTheme.statusNeedsIntervention, hex: 0xFFD080, traits: dark, name: "needsIntervention dark")

        assertResolvedHex(FleetTheme.statusDegraded, hex: 0x9D4713, traits: light, name: "degraded light")
        assertResolvedHex(FleetTheme.statusDegraded, hex: 0xFFBA8A, traits: dark, name: "degraded dark")

        assertResolvedHex(FleetTheme.statusDestructive, hex: 0xB42335, traits: light, name: "destructive light")
        assertResolvedHex(FleetTheme.statusDestructive, hex: 0xFF97A3, traits: dark, name: "destructive dark")
    }

    /// Waiting / offline / unknown take NO alarm tint — they must resolve to
    /// the system secondary label in both modes (SPEC §14).
    func testWaitingOfflineUnknownUseSecondaryLabelNotAlarmTints() {
        for status in [FleetStatus.waiting, .offline, .unknown] {
            for appearance in [UIUserInterfaceStyle.light, .dark] {
                assertSystemResolved(
                    status.color, system: .secondaryLabel,
                    appearance: appearance,
                    name: "\(status.label) color")
            }
        }
    }

    // MARK: - Surfaces (opaque canvas / grouped surface)

    func testCanvasAndGroupedSurfacePinSpecificationValues() {
        assertResolvedHex(FleetTheme.background, hex: 0xF8F9FC, traits: light, name: "canvas light")
        assertResolvedHex(FleetTheme.background, hex: 0x101216, traits: dark, name: "canvas dark")
        assertResolvedHex(FleetTheme.surface, hex: 0xFFFFFF, traits: light, name: "grouped surface light")
        assertResolvedHex(FleetTheme.surface, hex: 0x1B1E24, traits: dark, name: "grouped surface dark")
    }

    /// Increase Contrast: custom surfaces fall back to the opaque system
    /// background (SPEC §14 "opaque system background").
    func testSurfacesFallBackToSystemBackgroundUnderIncreasedContrast() {
        let hcLight = UITraitCollection(traitsFrom: [light, UITraitCollection(accessibilityContrast: .high)])
        let hcDark = UITraitCollection(traitsFrom: [dark, UITraitCollection(accessibilityContrast: .high)])
        for (token, name) in [(FleetTheme.background, "canvas"), (FleetTheme.surface, "grouped surface")] {
            for (traits, mode) in [(hcLight, "light"), (hcDark, "dark")] {
                let resolved = UIColor(token).resolvedColor(with: traits)
                let expected = UIColor.systemBackground.resolvedColor(with: traits)
                XCTAssertEqual(resolved.description, expected.description,
                               "\(name) HC \(mode) must be the opaque system background")
            }
        }
        // And the fallback must actually differ from the custom canvas in
        // at least one channel (proof the HC branch is live).
        let customLight = UIColor(FleetTheme.background).resolvedColor(with: light)
        let hcResolved = UIColor(FleetTheme.background).resolvedColor(with: hcLight)
        XCTAssertNotEqual(customLight.description, hcResolved.description,
                          "HC canvas fallback must differ from the custom canvas")
    }

    // MARK: - Text + separators stay system

    func testTextTokensResolveToSemanticLabels() {
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            assertSystemResolved(FleetTheme.textPrimary, system: .label, appearance: appearance, name: "textPrimary")
            assertSystemResolved(FleetTheme.textSecondary, system: .secondaryLabel, appearance: appearance, name: "textSecondary")
            assertSystemResolved(FleetTheme.textMuted, system: .tertiaryLabel, appearance: appearance, name: "textMuted")
        }
    }

    func testBorderResolvesToSystemSeparator() {
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            assertSystemResolved(FleetTheme.border, system: .separator, appearance: appearance, name: "border")
        }
    }

    func testBorderColorHelperResolvesOpaqueSeparatorUnderIncreasedContrast() {
        let standard = UIColor(FleetTheme.borderColor(colorSchemeContrast: .standard)).resolvedColor(with: dark)
        let increased = UIColor(FleetTheme.borderColor(colorSchemeContrast: .increased)).resolvedColor(with: dark)
        let expectedStandard = UIColor.separator.resolvedColor(with: dark)
        let expectedIncreased = UIColor.opaqueSeparator.resolvedColor(with: dark)
        XCTAssertEqual(standard.description, expectedStandard.description)
        XCTAssertEqual(increased.description, expectedIncreased.description)
        XCTAssertNotEqual(standard.description, increased.description, "borderColor(.increased) must differ from standard")
    }

    // MARK: - Radii + spacing (unchanged scale)

    func testRadiusScale() {
        XCTAssertEqual(FleetTheme.radiusCard, 16)
        XCTAssertEqual(FleetTheme.radiusRow, 12)
        XCTAssertEqual(FleetTheme.radiusBubble, 18)
    }

    func testSpacingScale() {
        XCTAssertEqual(FleetTheme.spacingXs, 4)
        XCTAssertEqual(FleetTheme.spacingSm, 8)
        XCTAssertEqual(FleetTheme.spacingMd, 12)
        XCTAssertEqual(FleetTheme.spacingLg, 16)
        XCTAssertEqual(FleetTheme.spacingXl, 24)
        XCTAssertEqual(FleetTheme.spacingXxl, 32)
    }

    // MARK: - Typography (SPEC §14: SF default design, Dynamic Type styles)

    func testTypographyScale() {
        XCTAssertEqual(FleetTheme.titleFontSize, 34)
        XCTAssertEqual(FleetTheme.titleFontWeight, .bold)
        XCTAssertEqual(FleetTheme.sectionHeaderFontSize, 17)
        XCTAssertEqual(FleetTheme.sectionHeaderFontWeight, .semibold)
        XCTAssertEqual(FleetTheme.statFontSize, 20, "glance number = Title 3 (~20pt), not a 28pt stat tile")
        XCTAssertEqual(FleetTheme.statFontWeight, .semibold)
        XCTAssertEqual(FleetTheme.secondaryFontSize, 13, "provenance footnote = 13pt")
        XCTAssertEqual(FleetTheme.secondaryFontWeight, .regular)
        XCTAssertEqual(FleetTheme.microLabelFontSize, 11)
        XCTAssertEqual(FleetTheme.monoFontSize, 13)
        XCTAssertEqual(FleetTheme.monoCaptionFontSize, 11)
    }

    // MARK: - FleetStatus vocabulary (SPEC §7 via §14 tokens)

    func testFleetStatusVocabularyLabels() {
        XCTAssertEqual(FleetStatus.online.label, "Online")
        XCTAssertEqual(FleetStatus.executing(.working).label, "Working")
        XCTAssertEqual(FleetStatus.executing(.thinking).label, "Thinking")
        XCTAssertEqual(FleetStatus.executing(.usingTool).label, "Using tool")
        XCTAssertEqual(FleetStatus.waiting.label, "Waiting")
        XCTAssertEqual(FleetStatus.needsYou.label, "Needs you")
        XCTAssertEqual(FleetStatus.authRequired.label, "Sign in required")
        XCTAssertEqual(FleetStatus.degraded.label, "Degraded")
        XCTAssertEqual(FleetStatus.offline.label, "Offline")
        XCTAssertEqual(FleetStatus.unknown.label, "Unknown")
    }

    /// Symbol + word pairs ALWAYS: every state carries a distinct symbol.
    func testFleetStatusSymbolsAreDistinctAndNonEmpty() {
        var seen = Set<String>()
        for status in FleetStatus.allCases {
            XCTAssertFalse(status.symbolName.isEmpty, "\(status.label) needs a symbol")
            XCTAssertFalse(seen.contains(status.symbolName), "duplicate symbol \(status.symbolName)")
            seen.insert(status.symbolName)
        }
        XCTAssertEqual(seen.count, FleetStatus.allCases.count)
    }

    /// Status text renders primary label with a colored glyph (SPEC §14).
    func testStatusPillLabelColorPolicy() {
        for status in FleetStatus.allCases {
            XCTAssertEqual(status.labelColor, FleetTheme.textPrimary, "\(status.label)")
        }
    }

    /// The old four-state compression is DEAD: gateway mapping keeps
    /// authRequired distinct, unsupported is degraded (classified problem),
    /// and presence-unknown renders unknown — never idle/offline.
    func testGatewayAndPresenceMappingsPreserveVocabulary() {
        XCTAssertEqual(FleetStatus(gatewayStatus: .online), .online)
        XCTAssertEqual(FleetStatus(gatewayStatus: .connecting), .waiting)
        XCTAssertEqual(FleetStatus(gatewayStatus: .degraded), .degraded)
        XCTAssertEqual(FleetStatus(gatewayStatus: .authenticationRequired), .authRequired)
        XCTAssertEqual(FleetStatus(gatewayStatus: .unsupported), .degraded)
        XCTAssertEqual(FleetStatus(gatewayStatus: .offline), .offline)

        XCTAssertEqual(FleetStatus(activity: .working, presence: .reachable), .executing(.working))
        XCTAssertEqual(FleetStatus(activity: .thinking, presence: .reachable), .executing(.thinking))
        XCTAssertEqual(FleetStatus(activity: .usingTool, presence: .reachable), .executing(.usingTool))
        XCTAssertEqual(FleetStatus(activity: .waiting, presence: .reachable), .waiting)
        XCTAssertEqual(FleetStatus(activity: .needsAttention, presence: .reachable), .needsYou)
        XCTAssertEqual(FleetStatus(activity: .idle, presence: .reachable), .online)
        XCTAssertEqual(FleetStatus(activity: .unknown, presence: .reachable), .online)
        XCTAssertEqual(FleetStatus(activity: .working, presence: .unreachable), .offline)
        // UNKNOWN never maps to idle or offline (SPEC §7).
        XCTAssertEqual(FleetStatus(activity: .idle, presence: .unknown), .unknown)
        XCTAssertEqual(FleetStatus(activity: .unknown, presence: .unknown), .unknown)
    }

    func testStatusPillTintIsTwentyPercent() {
        assertResolvedHex(
            FleetTheme.statusPillTint(FleetTheme.statusOnline),
            hex: 0x176B46, alpha: 0.2, traits: light, name: "statusPillTint(online)"
        )
    }

    // MARK: - Retired accent picker: rollback-safe persistence only

    /// The stored pick round-trips untouched (rollback value preserved) but
    /// nothing applies it — see testAccentIsFixedFleetVioletAndIgnoresRetiredPick.
    func testRetiredAccentControllerStillRoundTripsStoredValue() {
        let suite = UserDefaults(suiteName: "testFOS7AccentRollback")!
        suite.removePersistentDomain(forName: "testFOS7AccentRollback")
        let controller = FleetAccentController(defaults: suite)
        XCTAssertEqual(controller.selection, .blue, "fresh install default")
        controller.selection = .gold
        XCTAssertEqual(suite.string(forKey: FleetAccentController.persistKey), "gold")
        XCTAssertEqual(FleetAccentController(defaults: suite).selection, .gold, "stored rollback value survives")
        suite.set("teal-not-a-real-accent", forKey: FleetAccentController.persistKey)
        XCTAssertEqual(FleetAccentController(defaults: suite).selection, .blue, "stale raw falls back")
    }

    // MARK: - V1 custom palette

    func testV1DefaultPaletteHasOpaqueFleetValues() {
        let palette = FleetThemePalette.fleetDefault
        XCTAssertEqual(palette.version, FleetThemePalette.currentVersion)
        XCTAssertEqual(palette.appearance, .adaptiveFleetDefault)
        XCTAssertEqual(palette.highlight, FleetStoredColor(hex: 0x5B35D5))
        XCTAssertEqual(palette.text, FleetStoredColor(hex: 0x1C1C1E))
        XCTAssertEqual(palette.background, FleetStoredColor(hex: 0xF8F9FC))
        XCTAssertTrue(palette.highlight.isValid && palette.text.isValid && palette.background.isValid)
    }

    func testExplicitCustomPaletteStaysExactlyTheSameInLightAndDark() {
        let custom = FleetThemePalette(
            highlight: FleetStoredColor(hex: 0xE95D90),
            text: FleetStoredColor(hex: 0xF1E8D8),
            background: FleetStoredColor(hex: 0x17202A))

        XCTAssertEqual(custom.appearance, .fixed)
        XCTAssertEqual(custom.palette(forDarkAppearance: false), custom)
        XCTAssertEqual(custom.palette(forDarkAppearance: true), custom)
    }

    func testV1PaletteCodableRoundTripPreservesArbitraryRGB() throws {
        let palette = FleetThemePalette(
            highlight: FleetStoredColor(red: 0.123, green: 0.456, blue: 0.789),
            text: FleetStoredColor(red: 0.901, green: 0.234, blue: 0.567),
            background: FleetStoredColor(red: 0.012, green: 0.345, blue: 0.678))
        let encoded = try JSONEncoder().encode(palette)
        let decoded = try JSONDecoder().decode(FleetThemePalette.self, from: encoded)
        XCTAssertEqual(decoded, palette)
    }

    func testThemeControllerKeepsDraftLocalUntilApplyAndPersistsOnlyAppliedPalette() throws {
        let defaults = UserDefaults(suiteName: "testFleetThemeApply")!
        defaults.removePersistentDomain(forName: "testFleetThemeApply")
        let controller = FleetThemeController(defaults: defaults)
        let draft = FleetThemePalette(
            highlight: FleetStoredColor(red: 0.2, green: 0.4, blue: 0.8),
            text: FleetStoredColor(red: 0.9, green: 0.8, blue: 0.1),
            background: FleetStoredColor(red: 0.04, green: 0.05, blue: 0.08))

        XCTAssertEqual(controller.activePalette, .fleetDefault)
        XCTAssertNil(defaults.data(forKey: FleetThemeController.persistKey))
        // A draft is an editor value, not controller state, until Apply.
        XCTAssertNotEqual(draft, controller.activePalette)

        controller.apply(draft)
        XCTAssertEqual(controller.activePalette, draft)
        let persisted = try XCTUnwrap(defaults.data(forKey: FleetThemeController.persistKey))
        XCTAssertEqual(try JSONDecoder().decode(FleetThemePalette.self, from: persisted), draft)
    }

    func testThemeControllerResetRestoresFleetDefault() {
        let defaults = UserDefaults(suiteName: "testFleetThemeReset")!
        defaults.removePersistentDomain(forName: "testFleetThemeReset")
        let controller = FleetThemeController(defaults: defaults)
        controller.apply(FleetThemePalette(
            highlight: FleetStoredColor(hex: 0x00FF00),
            text: FleetStoredColor(hex: 0xFFFFFF),
            background: FleetStoredColor(hex: 0x000000)))
        controller.reset()
        XCTAssertEqual(controller.activePalette, .fleetDefault)
    }

    func testMalformedPersistedPaletteFallsBackWithoutOverwritingPayload() {
        let defaults = UserDefaults(suiteName: "testFleetThemeCorrupt")!
        defaults.removePersistentDomain(forName: "testFleetThemeCorrupt")
        let corrupt = Data("{not-a-palette".utf8)
        defaults.set(corrupt, forKey: FleetThemeController.persistKey)

        let controller = FleetThemeController(defaults: defaults)

        XCTAssertEqual(controller.activePalette, .fleetDefault)
        XCTAssertEqual(defaults.data(forKey: FleetThemeController.persistKey), corrupt,
                       "fallback must not destroy recoverable corrupt state")
    }

    func testCorruptV1StateDoesNotResurrectLegacyAccent() {
        let defaults = UserDefaults(suiteName: "testFleetThemeCorruptPrecedence")!
        defaults.removePersistentDomain(forName: "testFleetThemeCorruptPrecedence")
        let corrupt = Data("{not-a-palette".utf8)
        defaults.set(corrupt, forKey: FleetThemeController.persistKey)
        defaults.set(FleetAccent.green.rawValue, forKey: FleetAccentController.persistKey)

        let controller = FleetThemeController(defaults: defaults)

        XCTAssertEqual(controller.activePalette, .fleetDefault,
                       "a present but corrupt V1 key must win over stale legacy state")
        XCTAssertEqual(defaults.data(forKey: FleetThemeController.persistKey), corrupt)
        XCTAssertEqual(defaults.string(forKey: FleetAccentController.persistKey), "green")
    }

    func testOutOfRangeChannelsClampAtConstructionButStrictDecodeRejectsThem() throws {
        let clamped = FleetStoredColor(red: -0.5, green: 1.5, blue: .infinity)
        XCTAssertEqual(clamped.red, 0)
        XCTAssertEqual(clamped.green, 1)
        XCTAssertEqual(clamped.blue, 0)

        let invalid = Data("""
        {"version":1,"highlight":{"red":2,"green":0,"blue":0},"text":{"red":0,"green":0,"blue":0},"background":{"red":1,"green":1,"blue":1}}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FleetThemePalette.self, from: invalid))
    }

    func testLegacyAccentMigratesInMemoryWithoutChangingLegacyOrNewStorage() {
        let defaults = UserDefaults(suiteName: "testFleetThemeMigration")!
        defaults.removePersistentDomain(forName: "testFleetThemeMigration")
        defaults.set(FleetAccent.green.rawValue, forKey: FleetAccentController.persistKey)

        let controller = FleetThemeController(defaults: defaults)

        XCTAssertEqual(controller.activePalette.highlight, FleetAccent.green.legacyHighlight)
        XCTAssertEqual(controller.activePalette.appearance, .adaptiveCustomHighlight)
        XCTAssertEqual(defaults.string(forKey: FleetAccentController.persistKey), "green")
        XCTAssertNil(defaults.data(forKey: FleetThemeController.persistKey),
                     "migration writes the V1 schema only through explicit Apply")
    }

    func testLegacyAccentMigrationKeepsDefaultTextAndBackgroundAdaptive() {
        let defaults = UserDefaults(suiteName: "testFleetThemeMigrationAppearance")!
        defaults.removePersistentDomain(forName: "testFleetThemeMigrationAppearance")
        defaults.set(FleetAccent.gold.rawValue, forKey: FleetAccentController.persistKey)

        let controller = FleetThemeController(defaults: defaults)
        let light = controller.resolvedTheme(isDarkAppearance: false, isIncreasedContrast: false)
        let dark = controller.resolvedTheme(isDarkAppearance: true, isIncreasedContrast: false)

        XCTAssertEqual(light.resolvedPalette.highlight, FleetAccent.gold.legacyHighlight)
        XCTAssertEqual(light.resolvedPalette.text, FleetThemePalette.fleetDefault.text)
        XCTAssertEqual(light.resolvedPalette.background, FleetThemePalette.fleetDefault.background)
        XCTAssertEqual(dark.resolvedPalette.highlight, FleetAccent.gold.legacyHighlight)
        XCTAssertEqual(dark.resolvedPalette.text, FleetThemePalette.fleetDefaultDark.text)
        XCTAssertEqual(dark.resolvedPalette.background, FleetThemePalette.fleetDefaultDark.background)
    }

    func testColorPickerColorsNormalizeToFiniteBoundedOpaqueSRGB() throws {
        let p3 = UIColor(displayP3Red: 1.0, green: 0.2, blue: 0.1, alpha: 1)
        let first = try XCTUnwrap(FleetStoredColor(uiColor: p3))
        let second = try XCTUnwrap(FleetStoredColor(uiColor: p3))

        XCTAssertEqual(first, second, "P3 conversion must be deterministic")
        for channel in [first.red, first.green, first.blue] {
            XCTAssertTrue(channel.isFinite)
            XCTAssertTrue((0...1).contains(channel))
        }
        XCTAssertTrue(first.isValid)

        let extended = UIColor(red: 1.25, green: -0.25, blue: 0.4, alpha: 1)
        let normalized = try XCTUnwrap(FleetStoredColor(uiColor: extended))
        XCTAssertEqual(normalized.red, 1, accuracy: 0.000_001)
        XCTAssertEqual(normalized.green, 0, accuracy: 0.000_001)
        XCTAssertEqual(normalized.blue, 0.4, accuracy: 0.000_001)
        XCTAssertNil(FleetStoredColor(uiColor: UIColor(red: 0, green: 0, blue: 0, alpha: 0.5)),
                     "opacity remains prohibited")
    }

    func testOldV1DefaultPayloadRetainsAdaptiveDarkResolution() throws {
        let defaults = UserDefaults(suiteName: "testFleetThemeOldDefaultPayload")!
        defaults.removePersistentDomain(forName: "testFleetThemeOldDefaultPayload")
        let oldPayload = try JSONEncoder().encode(FleetThemePalette(
            highlight: .init(hex: 0x5B35D5),
            text: .init(hex: 0x1C1C1E),
            background: .init(hex: 0xF8F9FC)))
        // Simulate the pre-remediation V1 encoding, which had no appearance
        // field but represented the Fleet default palette.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: oldPayload) as? [String: Any])
        object.removeValue(forKey: "appearance")
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: FleetThemeController.persistKey)

        let controller = FleetThemeController(defaults: defaults)
        XCTAssertEqual(
            controller.resolvedTheme(isDarkAppearance: true, isIncreasedContrast: false).resolvedPalette,
            FleetThemePalette.fleetDefaultDark)
    }

    func testContrastMathAndEditorWarningAreDeterministic() {
        let black = FleetStoredColor(red: 0, green: 0, blue: 0)
        let white = FleetStoredColor(red: 1, green: 1, blue: 1)
        XCTAssertEqual(FleetThemeContrast.ratio(white, black), 21, accuracy: 0.001)

        let low = FleetThemePalette(
            highlight: FleetStoredColor(red: 0.5, green: 0.5, blue: 0.5),
            text: FleetStoredColor(red: 0.5, green: 0.5, blue: 0.5),
            background: FleetStoredColor(red: 0.5, green: 0.5, blue: 0.5))
        let report = FleetThemeContrastReport(palette: low, isDark: false)
        XCTAssertTrue(report.hasWarning)
        XCTAssertEqual(report, FleetThemeContrastReport(palette: low, isDark: false))
    }

    func testIncreaseContrastCorrectsPresentationWithoutMutatingPersistedChoice() {
        let low = FleetThemePalette(
            highlight: FleetStoredColor(red: 0.5, green: 0.5, blue: 0.5),
            text: FleetStoredColor(red: 0.5, green: 0.5, blue: 0.5),
            background: FleetStoredColor(red: 0.5, green: 0.5, blue: 0.5))
        let normal = FleetThemeValues(palette: low, isDarkAppearance: false, isIncreasedContrast: false)
        let increased = FleetThemeValues(palette: low, isDarkAppearance: false, isIncreasedContrast: true)

        XCTAssertEqual(normal.palette, low)
        XCTAssertEqual(increased.palette, low)
        XCTAssertEqual(increased.resolvedPalette, FleetThemePalette(
            highlight: increased.resolvedPalette.highlight,
            text: increased.resolvedPalette.text,
            background: increased.resolvedPalette.background))
        XCTAssertGreaterThanOrEqual(
            FleetThemeContrast.ratio(increased.resolvedPalette.text, increased.resolvedPalette.background),
            FleetThemeContrast.increasedContrastMinimum)
        XCTAssertGreaterThanOrEqual(
            FleetThemeContrast.ratio(increased.resolvedPalette.highlight, increased.resolvedPalette.background),
            FleetThemeContrast.increasedContrastMinimum)
        XCTAssertNotEqual(increased.resolvedPalette, low)
    }

    func testSemanticStatusColorsDoNotFollowCustomPalette() {
        let custom = FleetThemeValues(
            palette: FleetThemePalette(
                highlight: FleetStoredColor(hex: 0xFF00FF),
                text: FleetStoredColor(hex: 0x00FF00),
                background: FleetStoredColor(hex: 0x0000FF)),
            isDarkAppearance: false,
            isIncreasedContrast: false)
        let traits = UITraitCollection(userInterfaceStyle: .light)

        XCTAssertEqual(
            UIColor(custom.semanticStatusColor(for: .online)).resolvedColor(with: traits).description,
            UIColor(FleetTheme.statusOnline).resolvedColor(with: traits).description)
        XCTAssertEqual(
            UIColor(custom.semanticStatusColor(for: .degraded)).resolvedColor(with: traits).description,
            UIColor(FleetTheme.statusDegraded).resolvedColor(with: traits).description)
        XCTAssertEqual(
            UIColor(custom.semanticStatusColor(for: .offline)).resolvedColor(with: traits).description,
            UIColor(FleetTheme.statusNeutral).resolvedColor(with: traits).description)
    }
}
