import XCTest
import SwiftUI
import UIKit
@testable import FleetUI

/// V7 HIG-native drift guard (t_9ce36690 / D5 spec, 2026-09-04): every
/// bespoke palette token was DELETED from FleetTheme. The guard now pins
/// SYSTEM RESOLUTION — each FleetTheme color must resolve identically to its
/// corresponding system color in BOTH light and dark appearances. Any future
/// bespoke drift (a hex sneaking back in) fails here. Old bespoke pins live
/// in git history, not in this file.
@MainActor
final class FleetThemeTests: XCTestCase {

    /// Hermetic accent state (t_5d722cea): FleetTheme.accent resolves through
    /// FleetAccentController.shared, which reads persisted standard defaults —
    /// on a long-lived simulator the interactive app may have saved a
    /// non-default pick (e.g. "gold"), silently failing every accent
    /// assertion. Pin the default for the duration of each test and restore
    /// BOTH the in-memory selection and its persisted backing afterwards.
    private var savedAccentRaw: String?

    override func setUp() {
        super.setUp()
        savedAccentRaw = UserDefaults.standard.string(forKey: FleetAccentController.persistKey)
        FleetAccentController.shared.selection = .blue
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

    // MARK: - System resolution drift guard

    /// Resolves a FleetTheme Color and a system UIColor under the given
    /// appearance and asserts they are the SAME color.
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
        XCTAssertEqual(rr, er, accuracy: 0.001, "\(name) red (system-resolved) \(appearance == .dark ? "dark" : "light")", file: file, line: line)
        XCTAssertEqual(rg, eg, accuracy: 0.001, "\(name) green (system-resolved)", file: file, line: line)
        XCTAssertEqual(rb, eb, accuracy: 0.001, "\(name) blue (system-resolved)", file: file, line: line)
        XCTAssertEqual(ra, ea, accuracy: 0.001, "\(name) alpha (system-resolved)", file: file, line: line)
    }

    func testNeutralsResolveToSystemSurfaces() {
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            assertSystemResolved(FleetTheme.background, system: .systemBackground, appearance: appearance, name: "background")
            assertSystemResolved(FleetTheme.surface, system: .secondarySystemBackground, appearance: appearance, name: "surface")
            assertSystemResolved(FleetTheme.surfaceElevated, system: .tertiarySystemBackground, appearance: appearance, name: "surfaceElevated")
        }
    }

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
        let standard = UIColor(FleetTheme.borderColor(colorSchemeContrast: .standard)).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        let increased = UIColor(FleetTheme.borderColor(colorSchemeContrast: .increased)).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        let expectedStandard = UIColor.separator.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        let expectedIncreased = UIColor.opaqueSeparator.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        XCTAssertEqual(standard.description, expectedStandard.description)
        XCTAssertEqual(increased.description, expectedIncreased.description)
        // And the helper must actually STRENGTHEN under increased contrast.
        XCTAssertNotEqual(standard.description, increased.description, "borderColor(.increased) must differ from standard")
    }

    func testSurfaceIncreasedLiftsUnderHighAccessibilityContrast() {
        // Standard contrast: resolves as the base secondary surface.
        let standardTraits = UITraitCollection(userInterfaceStyle: .dark)
        let resolvedStandard = UIColor(FleetTheme.surfaceIncreased).resolvedColor(with: standardTraits)
        let expectedStandard = UIColor.secondarySystemBackground.resolvedColor(with: standardTraits)
        XCTAssertEqual(resolvedStandard.description, expectedStandard.description)
        // Increase Contrast: lifts to the HIGH-contrast system background.
        let highTraits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .dark),
            UITraitCollection(accessibilityContrast: .high),
        ])
        let resolvedHigh = UIColor(FleetTheme.surfaceIncreased).resolvedColor(with: highTraits)
        let expectedHigh = UIColor.systemBackground.resolvedColor(with: highTraits)
        XCTAssertEqual(resolvedHigh.description, expectedHigh.description)
    }

    /// ONE accent, now user-choosable: resolves to the controller's current
    /// selection — systemBlue under the default (fresh-install) selection.
    func testAccentResolvesToSystemBlue() {
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            assertSystemResolved(FleetTheme.accent, system: .systemBlue, appearance: appearance, name: "accent")
        }
    }

    /// Non-default selections resolve to their adaptive pair, in both modes.
    /// Drives the real seam (FleetAccentController.shared) — a suite-backed
    /// controller instance would not affect FleetTheme.accent.
    func testAccentFollowsUserSelection() {
        let original = FleetAccentController.shared.selection
        defer { FleetAccentController.shared.selection = original }   // load-bearing restore
        FleetAccentController.shared.selection = .gold
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: appearance)
            let resolved = UIColor(FleetTheme.accent).resolvedColor(with: traits)
            let expected = UIColor(FleetAccent.gold.color).resolvedColor(with: traits)
            XCTAssertEqual(resolved.description, expected.description,
                           "accent must follow selection (gold), \(appearance == .dark ? "dark" : "light")")
        }
    }

    /// The bespoke era must stay DEAD: none of the retired hex values may
    /// reappear as the resolved value of any primary token (catches a hex
    /// sneaking back under a different token name).
    func testRetiredBespokeHexesStayDead() {
        typealias Check = (name: String, color: Color)
        let retiredDark: [UInt32] = [
            0x0A0A0A, 0x16161A, 0x1D1E22, 0x32373C, 0xEDEDED, 0x9BA1A6,
            0x858B91, 0x5A646D, 0x1F2025, 0x98F3F9, 0xFFD700, 0xFF1F6A,
        ]
        let retiredLight: [UInt32] = [0x006B78, 0x866000, 0xB51D58]
        let tokens: [Check] = [
            ("background", FleetTheme.background),
            ("surface", FleetTheme.surface),
            ("surfaceElevated", FleetTheme.surfaceElevated),
            ("border", FleetTheme.border),
            ("textPrimary", FleetTheme.textPrimary),
            ("textSecondary", FleetTheme.textSecondary),
            ("textMuted", FleetTheme.textMuted),
            ("accent", FleetTheme.accent),
        ]
        for (appearance, retired) in [(UIUserInterfaceStyle.dark, retiredDark), (.light, retiredLight)] {
            let traits = UITraitCollection(userInterfaceStyle: appearance)
            for token in tokens {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(token.color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
                let hex = UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
                XCTAssertFalse(retired.contains(hex), "\(token.name) resolved to retired bespoke hex 0x\(String(hex, radix: 16)) in \(appearance == .dark ? "dark" : "light")")
            }
        }
    }

    // MARK: - Status (semantic, V5 AA-fixed adaptive values retained per D5)

    func testStatusTokensKeepPinnedAdaptiveValues() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let light = UITraitCollection(userInterfaceStyle: .light)

        assertResolvedHex(FleetTheme.statusOnline, hex: 0x00C853, traits: dark, name: "statusOnline dark")
        assertResolvedHex(FleetTheme.statusOnline, hex: 0x00753B, traits: light, name: "statusOnline light")
        assertResolvedHex(FleetTheme.statusIdle, hex: 0xFFC107, traits: dark, name: "statusIdle dark")
        assertResolvedHex(FleetTheme.statusIdle, hex: 0x856000, traits: light, name: "statusIdle light")
        assertResolvedHex(FleetTheme.statusDegraded, hex: 0xFF5252, traits: dark, name: "statusDegraded dark")
        assertResolvedHex(FleetTheme.statusDegraded, hex: 0xC02835, traits: light, name: "statusDegraded light")
        assertResolvedHex(FleetTheme.statusOffline, hex: 0x8A8A9A, traits: dark, name: "statusOffline dark")
        assertResolvedHex(FleetTheme.statusOffline, hex: 0x626879, traits: light, name: "statusOffline light")
    }

    /// V5 (t_b2628d33): the OFFLINE pill label renders textPrimary (the
    /// statusOffline gray is below AA for text on its own tint). Colored
    /// states keep their status color on the label. Unchanged by V7.
    func testStatusPillLabelColorPolicy() {
        XCTAssertEqual(FleetStatus.offline.labelColor, FleetTheme.textPrimary)
        XCTAssertEqual(FleetStatus.online.labelColor, FleetTheme.statusOnline)
        XCTAssertEqual(FleetStatus.idle.labelColor, FleetTheme.statusIdle)
        XCTAssertEqual(FleetStatus.degraded.labelColor, FleetTheme.statusDegraded)
        for status in FleetStatus.allCases {
            XCTAssertFalse(status.symbolName.isEmpty, "\(status.rawValue) needs a reinforcement symbol")
        }
    }

    func testStatusPillTintIsTwentyPercent() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        assertResolvedHex(
            FleetTheme.statusPillTint(FleetTheme.statusOnline),
            hex: 0x00C853, alpha: 0.2, traits: dark, name: "statusPillTint(online)"
        )
    }

    // MARK: - Radii (cards 16, rows 12, bubbles 18)

    func testRadiusScale() {
        XCTAssertEqual(FleetTheme.radiusCard, 16)
        XCTAssertEqual(FleetTheme.radiusRow, 12)
        XCTAssertEqual(FleetTheme.radiusBubble, 18)
    }

    // MARK: - Spacing scale

    func testSpacingScale() {
        XCTAssertEqual(FleetTheme.spacingXs, 4)
        XCTAssertEqual(FleetTheme.spacingSm, 8)
        XCTAssertEqual(FleetTheme.spacingMd, 12)
        XCTAssertEqual(FleetTheme.spacingLg, 16)
        XCTAssertEqual(FleetTheme.spacingXl, 24)
        XCTAssertEqual(FleetTheme.spacingXxl, 32)
    }

    // MARK: - Typography (SF Pro + SF Mono; size/weight pins)

    func testTypographyScale() {
        XCTAssertEqual(FleetTheme.titleFontSize, 28)
        XCTAssertEqual(FleetTheme.statFontSize, 28)
        XCTAssertEqual(FleetTheme.titleFontWeight, .bold)
        XCTAssertEqual(FleetTheme.statFontWeight, .bold)
        XCTAssertEqual(FleetTheme.sectionHeaderFontSize, FleetTheme.microLabelFontSize)
        XCTAssertEqual(FleetTheme.sectionHeaderFontWeight, .semibold)
        XCTAssertEqual(FleetTheme.microLabelFontSize, 11)
        XCTAssertEqual(FleetTheme.microLabelTracking, 1.4, accuracy: 0.001)
        XCTAssertEqual(FleetTheme.secondaryFontSize, 13)
        XCTAssertEqual(FleetTheme.secondaryFontWeight, .regular)
        XCTAssertEqual(FleetTheme.monoFontSize, 13)
        XCTAssertEqual(FleetTheme.monoCaptionFontSize, 11)
    }

    // MARK: - Accent chooser (V7.5)

    /// The vetted accent catalog: exactly the five approved candidates, in
    /// display order, each with a stable raw value and adaptive dark/light hexes.
    func testAccentCatalogIsVettedAndOrdered() {
        XCTAssertEqual(FleetAccent.allCases.map(\.rawValue),
                       ["blue", "gold", "amber", "indigo", "green"])
        XCTAssertEqual(FleetAccent.default, .blue)
    }

    /// Persistence: unknown/stale raw values fall back to the default; the
    /// controller round-trips a pick through UserDefaults.
    func testAccentControllerRoundTripAndUnknownFallback() {
        let suite = UserDefaults(suiteName: "testAccentController")!
        suite.removePersistentDomain(forName: "testAccentController")
        let controller = FleetAccentController(defaults: suite)
        XCTAssertEqual(controller.selection, .blue, "fresh install defaults to blue")

        controller.selection = .gold
        XCTAssertEqual(suite.string(forKey: FleetAccentController.persistKey), "gold")
        XCTAssertEqual(FleetAccentController(defaults: suite).selection, .gold,
                       "new controller instance reads persisted pick")

        suite.set("teal-not-a-real-accent", forKey: FleetAccentController.persistKey)
        XCTAssertEqual(FleetAccentController(defaults: suite).selection, .blue,
                       "stale/unknown raw value falls back to default")
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
}
