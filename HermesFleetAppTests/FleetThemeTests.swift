import XCTest
import SwiftUI
import UIKit
@testable import FleetUI

/// V1 (Nous direction, 2026-09-02 design pivot): drift guard — the FleetTheme
/// palette MUST match the plan-of-record token table exactly. If a value
/// changes here without a matching design decision, this test fails.
///
/// DELIBERATE PIVOT: the old Gold Fleet hex pins (0x0A0A0F canvas, gold/
/// magenta/cyan accents) were REPLACED by the Nous terminal-minimal table
/// (plan: 2026-09-02 gold-fleet-v2 "Direction A", Tony-approved bake-off).
/// Old pins live in git history, not in this file.
///
/// Source of truth: FleetColors (single hex table) + plan
/// `2026-09-02_115356-gold-fleet-v2-visual-upgrade.md`, Direction A.
@MainActor
final class FleetThemeTests: XCTestCase {

    // MARK: - Raw hex drift guard (single source of truth: FleetColors)

    func testPaletteHexValuesMatchSpecExactly() {
        // Neutrals — Nous #32373C family on stark near-black
        XCTAssertEqual(FleetColors.background, 0x0A0A0A)
        XCTAssertEqual(FleetColors.surface, 0x16161A)
        XCTAssertEqual(FleetColors.surfaceElevated, 0x1D1E22)
        XCTAssertEqual(FleetColors.border, 0x32373C)
        XCTAssertEqual(FleetColors.textPrimary, 0xEDEDED)
        XCTAssertEqual(FleetColors.textSecondary, 0x9BA1A6)
        // V5 accessibility tokens (design review t_b2628d33)
        XCTAssertEqual(FleetColors.textMuted, 0x858B91)
        XCTAssertEqual(FleetColors.borderIncreased, 0x5A646D)
        XCTAssertEqual(FleetColors.surfaceIncreased, 0x1F2025)
        // ONE accent: pale cyan
        XCTAssertEqual(FleetColors.accent, 0x98F3F9)
        // Legacy Gold Fleet accents (retained until V2/V3 migrate call sites)
        XCTAssertEqual(FleetColors.accentGold, 0xFFD700)
        XCTAssertEqual(FleetColors.accentMagenta, 0xFF1F6A)
        // Semantic status — unchanged by the pivot
        XCTAssertEqual(FleetColors.statusOnline, 0x00C853)
        XCTAssertEqual(FleetColors.statusIdle, 0xFFC107)
        XCTAssertEqual(FleetColors.statusDegraded, 0xFF5252)
        // DELIBERATE V5 accessibility decision (t_b2628d33 design review):
        // statusOffline was raised 0x6A6A7A → 0x8A8A9A (3.4:1 → 5.31:1 on
        // surface) to clear WCAG AA; the offline PILL LABEL additionally
        // renders in textPrimary (see FleetStatus.labelColor).
        XCTAssertEqual(FleetColors.statusOffline, 0x8A8A9A)
    }

    // MARK: - Resolved color values (what actually renders)

    func testTokenColorsResolveToSpecInDarkAppearance() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)

        assertResolved(FleetTheme.background, hex: 0x0A0A0A, alpha: 1, traits: dark, name: "background")
        assertResolved(FleetTheme.surface, hex: 0x16161A, alpha: 1, traits: dark, name: "surface")
        assertResolved(FleetTheme.surfaceElevated, hex: 0x1D1E22, alpha: 1, traits: dark, name: "surfaceElevated")
        assertResolved(FleetTheme.textPrimary, hex: 0xEDEDED, alpha: 1, traits: dark, name: "textPrimary")
        assertResolved(FleetTheme.textSecondary, hex: 0x9BA1A6, alpha: 1, traits: dark, name: "textSecondary")
        assertResolved(FleetTheme.accent, hex: 0x98F3F9, alpha: 1, traits: dark, name: "accent")
        assertResolved(FleetTheme.accentGold, hex: 0xFFD700, alpha: 1, traits: dark, name: "accentGold (legacy)")
        assertResolved(FleetTheme.accentMagenta, hex: 0xFF1F6A, alpha: 1, traits: dark, name: "accentMagenta (legacy)")
        assertResolved(FleetTheme.statusOnline, hex: 0x00C853, alpha: 1, traits: dark, name: "statusOnline")
        assertResolved(FleetTheme.statusIdle, hex: 0xFFC107, alpha: 1, traits: dark, name: "statusIdle")
        assertResolved(FleetTheme.statusDegraded, hex: 0xFF5252, alpha: 1, traits: dark, name: "statusDegraded")
        assertResolved(FleetTheme.statusOffline, hex: 0x8A8A9A, alpha: 1, traits: dark, name: "statusOffline")
        assertResolved(FleetTheme.textMuted, hex: 0x858B91, alpha: 1, traits: dark, name: "textMuted")
        assertResolved(Color(hex: FleetColors.borderIncreased), hex: 0x5A646D, alpha: 1, traits: dark, name: "borderIncreased")
        assertResolved(Color(hex: FleetColors.surfaceIncreased), hex: 0x1F2025, alpha: 1, traits: dark, name: "surfaceIncreased")
    }

    /// V5 (t_b2628d33): WCAG AA contrast guard — every text-bearing token
    /// must clear 4.5:1 against the surface it renders on. Computed with the
    /// WCAG relative-luminance formula (sRGB linearization + 2.4 gamma), so a
    /// future token change that drops below AA fails HERE instead of in
    /// design review. Note: statusOffline gray is used for text only where it
    /// clears AA on its own (5.31:1 on surface); the offline pill label
    /// renders textPrimary (11.7:1 on its own tint) via
    /// FleetStatus.labelColor.
    func testTextTokensClearWCAGAAOnTheirSurfaces() {
        typealias Pair = (name: String, foreground: UInt32, background: UInt32)
        let checks: [Pair] = [
            ("textPrimary on background", FleetColors.textPrimary, FleetColors.background),
            ("textPrimary on surface", FleetColors.textPrimary, FleetColors.surface),
            ("textPrimary on surfaceElevated", FleetColors.textPrimary, FleetColors.surfaceElevated),
            ("textPrimary on surfaceIncreased", FleetColors.textPrimary, FleetColors.surfaceIncreased),
            ("textSecondary on background", FleetColors.textSecondary, FleetColors.background),
            ("textSecondary on surface", FleetColors.textSecondary, FleetColors.surface),
            ("textSecondary on surfaceElevated", FleetColors.textSecondary, FleetColors.surfaceElevated),
            ("textSecondary on surfaceIncreased", FleetColors.textSecondary, FleetColors.surfaceIncreased),
            ("textMuted on background", FleetColors.textMuted, FleetColors.background),
            ("textMuted on surface", FleetColors.textMuted, FleetColors.surface),
            ("textMuted on surfaceElevated", FleetColors.textMuted, FleetColors.surfaceElevated),
            ("accent on background", FleetColors.accent, FleetColors.background),
            ("accent on surface", FleetColors.accent, FleetColors.surface),
            ("statusOffline (dot/tint gray) on surface", FleetColors.statusOffline, FleetColors.surface),
            ("statusOffline (dot/tint gray) on surfaceElevated", FleetColors.statusOffline, FleetColors.surfaceElevated),
        ]
        for check in checks {
            XCTAssertGreaterThanOrEqual(
                Self.wcagContrastRatio(check.foreground, check.background),
                4.5,
                "\(check.name) must clear WCAG AA (4.5:1)"
            )
        }
    }

    /// V5 (t_b2628d33): Increase Contrast tokens — the hairline must gain
    /// contrast and every text token must KEEP at least AA on the lifted
    /// surface (the strengthened tokens may not trade one failure for
    /// another).
    func testIncreaseContrastTokensStrengthenWithoutBreakingAA() {
        let standardBorder = Self.wcagContrastRatio(FleetColors.border, FleetColors.background)
        let increasedBorder = Self.wcagContrastRatio(FleetColors.borderIncreased, FleetColors.background)
        XCTAssertGreaterThan(increasedBorder, standardBorder, "borderIncreased must beat the standard hairline vs canvas")

        let standardSurface = Self.wcagContrastRatio(FleetColors.surface, FleetColors.background)
        let increasedSurface = Self.wcagContrastRatio(FleetColors.surfaceIncreased, FleetColors.background)
        XCTAssertGreaterThan(increasedSurface, standardSurface, "surfaceIncreased must separate more from canvas than surface")

        for (name, fg) in [
            ("textPrimary", FleetColors.textPrimary),
            ("textSecondary", FleetColors.textSecondary),
            ("textMuted", FleetColors.textMuted),
            ("accent", FleetColors.accent),
        ] {
            XCTAssertGreaterThanOrEqual(
                Self.wcagContrastRatio(fg, FleetColors.surfaceIncreased),
                4.5,
                "\(name) must keep WCAG AA on surfaceIncreased"
            )
        }
    }

    /// WCAG 2.x relative luminance + contrast ratio over solid sRGB hex
    /// tokens (fixed hex — no alpha, no dynamic remap, so this is exact).
    private static func wcagContrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        func linear(_ channel: UInt32) -> Double {
            let c = Double(channel) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        func luminance(_ hex: UInt32) -> Double {
            0.2126 * linear((hex >> 16) & 0xFF)
                + 0.7152 * linear((hex >> 8) & 0xFF)
                + 0.0722 * linear(hex & 0xFF)
        }
        let l1 = luminance(a), l2 = luminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// Policy: dark-only palette. The app forces dark at the root
    /// (`.preferredColorScheme(.dark)`), but tokens must still resolve to the
    /// SAME values under a light trait collection so nothing crashes or shifts
    /// if a sheet/system presentation leaks light traits.
    func testSemanticColorsAdaptToLightAppearance() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)

        for (name, color) in [
            ("background", FleetTheme.background),
            ("surface", FleetTheme.surface),
            ("surfaceElevated", FleetTheme.surfaceElevated),
            ("textPrimary", FleetTheme.textPrimary),
            ("textSecondary", FleetTheme.textSecondary),
            ("accent", FleetTheme.accent),
            ("accentGold", FleetTheme.accentGold),
            ("accentMagenta", FleetTheme.accentMagenta),
            ("statusOnline", FleetTheme.statusOnline),
            ("statusIdle", FleetTheme.statusIdle),
            ("statusDegraded", FleetTheme.statusDegraded),
            ("statusOffline", FleetTheme.statusOffline),
        ] {
            let l = UIColor(color).resolvedColor(with: light)
            let d = UIColor(color).resolvedColor(with: dark)
            var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
            var dr: CGFloat = 0, dg: CGFloat = 0, db: CGFloat = 0, da: CGFloat = 0
            l.getRed(&lr, green: &lg, blue: &lb, alpha: &la)
            d.getRed(&dr, green: &dg, blue: &db, alpha: &da)
            XCTAssertGreaterThan(abs(lr - dr) + abs(lg - dg) + abs(lb - db), 0.01, "\(name) must adapt to appearance")
            XCTAssertEqual(la, 1, accuracy: 0.001)
            XCTAssertEqual(da, 1, accuracy: 0.001)
        }
    }

    func testAdaptiveTextContrastAcrossAppearances() {
        func hex(_ color: Color, _ traits: UITraitCollection) -> UInt32 {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            return UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
        }
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: appearance)
            for foreground in [FleetTheme.textPrimary, FleetTheme.textSecondary, FleetTheme.textMuted, FleetTheme.accent] {
                for background in [FleetTheme.background, FleetTheme.surface, FleetTheme.surfaceElevated] {
                    XCTAssertGreaterThanOrEqual(Self.wcagContrastRatio(hex(foreground, traits), hex(background, traits)), 4.5)
                }
            }
        }
    }

    /// V1 Nous: hairline borders are SOLID #32373C — a hairline is the
    /// restraint (no translucency). Was #2A2A3A @ 8% in Gold Fleet.
    func testBorderIsSpecColorAtFullOpacity() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        assertResolved(FleetTheme.border, hex: 0x32373C, alpha: 1, traits: dark, name: "border")
    }

    /// Status pills get a tinted background derived from the status color
    /// (~20% tint) — unchanged by the pivot.
    func testStatusPillTintIsTwentyPercent() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        assertResolved(
            FleetTheme.statusPillTint(FleetTheme.statusOnline),
            hex: 0x00C853, alpha: 0.2, traits: dark, name: "statusPillTint(online)"
        )
    }

    /// V5 (t_b2628d33): the OFFLINE pill label renders textPrimary (the
    /// statusOffline gray is ~4:1 on its own 20% tint, below AA for text).
    /// Colored states keep their status color on the label.
    func testStatusPillLabelColorPolicy() {
        XCTAssertEqual(FleetStatus.offline.labelColor, FleetTheme.textPrimary)
        XCTAssertEqual(FleetStatus.online.labelColor, FleetTheme.statusOnline)
        XCTAssertEqual(FleetStatus.idle.labelColor, FleetTheme.statusIdle)
        XCTAssertEqual(FleetStatus.degraded.labelColor, FleetTheme.statusDegraded)
        // Differentiate-Without-Color reinforcement symbols exist per state.
        for status in FleetStatus.allCases {
            XCTAssertFalse(status.symbolName.isEmpty, "\(status.rawValue) needs a reinforcement symbol")
        }
    }

    /// V5 (t_b2628d33): the Increase Contrast hairline helper — standard
    /// contrast resolves the base token, increased resolves the strengthened
    /// one. (Resolved as static tokens; the adaptivity itself is view-layer.)
    func testBorderColorHelperPicksStrengthenedTokenUnderIncreasedContrast() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        assertResolved(
            FleetTheme.borderColor(colorSchemeContrast: .standard),
            hex: 0x32373C, alpha: 1, traits: dark, name: "border(standard)"
        )
        assertResolved(
            FleetTheme.borderColor(colorSchemeContrast: .increased),
            hex: 0x5A646D, alpha: 1, traits: dark, name: "border(increased)"
        )
    }

    // MARK: - Radii (cards 16, rows 12, bubbles 18; pills fully rounded)

    func testRadiusScale() {
        XCTAssertEqual(FleetTheme.radiusCard, 16)
        XCTAssertEqual(FleetTheme.radiusRow, 12)
        XCTAssertEqual(FleetTheme.radiusBubble, 18)
        // Pills are fully rounded — callers use .clipShape(Capsule()).
        // The pill radius is therefore infinite by convention:
        XCTAssertTrue(FleetTheme.radiusPill.isInfinite, "pill radius must stay fully-rounded (infinite)")
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

    // MARK: - Typography (mono as identity; micro-labels; SF Pro body)

    func testTypographyScale() {
        // Display/stats — 28pt bold, rendered MONO with tabular figures.
        XCTAssertEqual(FleetTheme.titleFontSize, 28)
        XCTAssertEqual(FleetTheme.statFontSize, 28)
        XCTAssertEqual(FleetTheme.titleFontWeight, .bold)
        XCTAssertEqual(FleetTheme.statFontWeight, .bold)

        // Section headers folded onto the micro-label role (11pt semibold,
        // UPPERCASE + tracking applied at call sites).
        XCTAssertEqual(FleetTheme.sectionHeaderFontSize, FleetTheme.microLabelFontSize)
        XCTAssertEqual(FleetTheme.sectionHeaderFontWeight, .semibold)
        XCTAssertEqual(FleetTheme.microLabelFontSize, 11)

        // Wide tracking for the caps micro-label (~0.13em at 11pt).
        XCTAssertEqual(FleetTheme.microLabelTracking, 1.4, accuracy: 0.001)

        // Body stays SF Pro.
        XCTAssertEqual(FleetTheme.secondaryFontSize, 13)
        XCTAssertEqual(FleetTheme.secondaryFontWeight, .regular)

        // Mono roles for IDs / uptime / telemetry / terminal metadata rows.
        XCTAssertEqual(FleetTheme.monoFontSize, 13)
        XCTAssertEqual(FleetTheme.monoCaptionFontSize, 11)
    }

    // MARK: - Mono type system (Courier Prime bundled, SF Mono fallback)

    /// The bundled Courier Prime faces must actually ship in the module
    /// bundle and resolve through UIKit — the mono identity depends on them.
    func testCourierPrimeIsBundledAndResolvable() {
        XCTAssertTrue(FleetFonts.courierPrimeAvailable, "Courier Prime faces must resolve from the FleetUI bundle")

        let regular = UIFont(name: FleetFonts.courierPrimeRegular, size: 13)
        let bold = UIFont(name: FleetFonts.courierPrimeBold, size: 13)
        XCTAssertNotNil(regular, "CourierPrime-Regular must resolve")
        XCTAssertNotNil(bold, "CourierPrime-Bold must resolve")
        XCTAssertEqual(regular?.familyName, "Courier Prime")
        XCTAssertEqual(bold?.familyName, "Courier Prime")
    }

    // MARK: - Helpers

    private func assertResolved(
        _ color: Color, hex: UInt32, alpha: CGFloat,
        traits: UITraitCollection, name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let resolved = UIColor(color).resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        let expected = (
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255
        )
        XCTAssertEqual(r, expected.0, accuracy: 0.001, "\(name) red", file: file, line: line)
        XCTAssertEqual(g, expected.1, accuracy: 0.001, "\(name) green", file: file, line: line)
        XCTAssertEqual(b, expected.2, accuracy: 0.001, "\(name) blue", file: file, line: line)
        XCTAssertEqual(a, alpha, accuracy: 0.001, "\(name) alpha", file: file, line: line)
    }
}
