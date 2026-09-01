import XCTest
import SwiftUI
import UIKit
@testable import FleetUI

/// U1 (Gold Fleet design tokens): drift guard — the FleetTheme palette MUST
/// match the plan-of-record token table exactly. If a value changes here
/// without a matching design decision, this test fails.
///
/// Source of truth: Plans/2026-09-01 "Gold Fleet" UI overhaul,
/// `assets/hero/hermes-fleet-hero-source.png`.
@MainActor
final class FleetThemeTests: XCTestCase {

    // MARK: - Raw hex drift guard (single source of truth: FleetColors)

    func testPaletteHexValuesMatchSpecExactly() {
        XCTAssertEqual(FleetColors.background, 0x0A0A0F)
        XCTAssertEqual(FleetColors.surface, 0x1A1A24)
        XCTAssertEqual(FleetColors.surfaceElevated, 0x1E1E2A)
        XCTAssertEqual(FleetColors.border, 0x2A2A3A)
        XCTAssertEqual(FleetColors.textPrimary, 0xFFFFFF)
        XCTAssertEqual(FleetColors.textSecondary, 0x8A8A9A)
        XCTAssertEqual(FleetColors.accentGold, 0xFFD700)
        XCTAssertEqual(FleetColors.accentMagenta, 0xFF1F6A)
        XCTAssertEqual(FleetColors.accentCyan, 0x00E5FF)
        XCTAssertEqual(FleetColors.statusOnline, 0x00C853)
        XCTAssertEqual(FleetColors.statusIdle, 0xFFC107)
        XCTAssertEqual(FleetColors.statusDegraded, 0xFF5252)
        XCTAssertEqual(FleetColors.statusOffline, 0x6A6A7A)
    }

    // MARK: - Resolved color values (what actually renders)

    func testTokenColorsResolveToSpecInDarkAppearance() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)

        assertResolved(FleetTheme.background, hex: 0x0A0A0F, alpha: 1, traits: dark, name: "background")
        assertResolved(FleetTheme.surface, hex: 0x1A1A24, alpha: 1, traits: dark, name: "surface")
        assertResolved(FleetTheme.surfaceElevated, hex: 0x1E1E2A, alpha: 1, traits: dark, name: "surfaceElevated")
        assertResolved(FleetTheme.textPrimary, hex: 0xFFFFFF, alpha: 1, traits: dark, name: "textPrimary")
        assertResolved(FleetTheme.textSecondary, hex: 0x8A8A9A, alpha: 1, traits: dark, name: "textSecondary")
        assertResolved(FleetTheme.accentGold, hex: 0xFFD700, alpha: 1, traits: dark, name: "accentGold")
        assertResolved(FleetTheme.accentMagenta, hex: 0xFF1F6A, alpha: 1, traits: dark, name: "accentMagenta")
        assertResolved(FleetTheme.accentCyan, hex: 0x00E5FF, alpha: 1, traits: dark, name: "accentCyan")
        assertResolved(FleetTheme.statusOnline, hex: 0x00C853, alpha: 1, traits: dark, name: "statusOnline")
        assertResolved(FleetTheme.statusIdle, hex: 0xFFC107, alpha: 1, traits: dark, name: "statusIdle")
        assertResolved(FleetTheme.statusDegraded, hex: 0xFF5252, alpha: 1, traits: dark, name: "statusDegraded")
        assertResolved(FleetTheme.statusOffline, hex: 0x6A6A7A, alpha: 1, traits: dark, name: "statusOffline")
    }

    /// U1 policy: dark-only palette. The app forces dark at the root
    /// (`.preferredColorScheme(.dark)`), but tokens must still resolve to the
    /// SAME values under a light trait collection so nothing crashes or shifts
    /// if a sheet/system presentation leaks light traits.
    func testTokenColorsResolveIdenticallyInLightAppearance() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)

        for (name, color) in [
            ("background", FleetTheme.background),
            ("surface", FleetTheme.surface),
            ("surfaceElevated", FleetTheme.surfaceElevated),
            ("textPrimary", FleetTheme.textPrimary),
            ("textSecondary", FleetTheme.textSecondary),
            ("accentGold", FleetTheme.accentGold),
            ("accentMagenta", FleetTheme.accentMagenta),
            ("accentCyan", FleetTheme.accentCyan),
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
            XCTAssertEqual(lr, dr, accuracy: 0.001, "\(name) red differs between light/dark")
            XCTAssertEqual(lg, dg, accuracy: 0.001, "\(name) green differs between light/dark")
            XCTAssertEqual(lb, db, accuracy: 0.001, "\(name) blue differs between light/dark")
            XCTAssertEqual(la, da, accuracy: 0.001, "\(name) alpha differs between light/dark")
        }
    }

    /// `fleet.border` = #2A2A3A @ ~8% — 1px card borders.
    func testBorderIsSpecColorAtEightPercentOpacity() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        assertResolved(FleetTheme.border, hex: 0x2A2A3A, alpha: 0.08, traits: dark, name: "border")
    }

    /// Status pills get a tinted background derived from the status color
    /// (mock: ~20% tint). Exposed as a token so every pill computes it the
    /// same way in U2.
    func testStatusPillTintIsTwentyPercent() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        assertResolved(
            FleetTheme.statusPillTint(FleetTheme.statusOnline),
            hex: 0x00C853, alpha: 0.2, traits: dark, name: "statusPillTint(online)"
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

    // MARK: - Typography (SF Pro system fonts)

    func testTypographyScale() {
        XCTAssertEqual(FleetTheme.titleFontSize, 28)
        XCTAssertEqual(FleetTheme.sectionHeaderFontSize, 17)
        XCTAssertEqual(FleetTheme.statFontSize, 28)
        XCTAssertEqual(FleetTheme.secondaryFontSize, 13)

        // Font itself is not Equatable; the size constants above plus the
        // fixed weight mapping below ARE the drift guard.
        XCTAssertEqual(FleetTheme.titleFontWeight, .bold)
        XCTAssertEqual(FleetTheme.sectionHeaderFontWeight, .semibold)
        XCTAssertEqual(FleetTheme.statFontWeight, .bold)
        XCTAssertEqual(FleetTheme.secondaryFontWeight, .regular)
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
