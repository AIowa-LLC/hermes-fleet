import SwiftUI

/// U1 (Gold Fleet design tokens) — solid sRGB color from a 0xRRGGBB value.
///
/// Gold Fleet is a DARK-ONLY flat design (see the hero mock,
/// `assets/hero/hermes-fleet-hero-source.png`): tokens are fixed values, not
/// light/dark adaptive pairs. The app forces the dark appearance at the root
/// (`.preferredColorScheme(.dark)` in HermesFleetApp); tokens still resolve
/// identically under light trait collections so nothing shifts or crashes if
/// a system presentation leaks light traits (guarded by FleetThemeTests).
extension Color {
    /// Solid sRGB color from a 0xRRGGBB value.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Raw Gold Fleet palette — the single source of truth for every hex value.
///
/// Drift guard: `FleetThemeTests.testPaletteHexValuesMatchSpecExactly` pins
/// these to the plan-of-record token table. Change a value here ONLY with a
/// matching design decision (plan: 2026-09-01 Gold Fleet UI overhaul).
public enum FleetColors {
    // MARK: Neutrals
    public static let background: UInt32 = 0x0A0A0F      // screen background
    public static let surface: UInt32 = 0x1A1A24         // cards, list rows
    public static let surfaceElevated: UInt32 = 0x1E1E2A // elevated surface (range #1A1A24–#1E1E2A)
    public static let border: UInt32 = 0x2A2A3A          // 1px card borders (use @ ~8%)
    public static let textPrimary: UInt32 = 0xFFFFFF     // titles, numbers
    public static let textSecondary: UInt32 = 0x8A8A9A   // labels, subtitles

    // MARK: Accents
    public static let accentGold: UInt32 = 0xFFD700      // brand: app title, key numbers
    public static let accentMagenta: UInt32 = 0xFF1F6A   // primary action, active tab, send
    public static let accentCyan: UInt32 = 0x00E5FF      // links, "View All", network detail

    // MARK: Status
    public static let statusOnline: UInt32 = 0x00C853    // Running/Online pills
    public static let statusIdle: UInt32 = 0xFFC107      // Idle pills
    public static let statusDegraded: UInt32 = 0xFF5252  // Degraded/error pills
    public static let statusOffline: UInt32 = 0x6A6A7A   // Offline pills
}

/// The Hermes Fleet design system — Gold Fleet foundation (U1).
///
/// Dark blue-gray surfaces on near-black, gold brand accents, magenta/cyan
/// functional accents, semantic status colors. FLAT design: no glass, no
/// neumorphism, no in-app shadows. Type is SF Pro (system).
///
/// Radii: cards 16, rows 12, bubbles 18, pills fully-rounded (Capsule).
/// Spacing scale: 4 / 8 / 12 / 16 / 24 / 32.
public enum FleetTheme {

    // MARK: - Neutrals

    public static let background: Color = Color(hex: FleetColors.background)
    public static let surface: Color = Color(hex: FleetColors.surface)
    public static let surfaceElevated: Color = Color(hex: FleetColors.surfaceElevated)
    public static let textPrimary: Color = Color(hex: FleetColors.textPrimary)
    public static let textSecondary: Color = Color(hex: FleetColors.textSecondary)

    /// 1px card borders: #2A2A3A at ~8% opacity.
    public static let border: Color = Color(hex: FleetColors.border).opacity(0.08)

    // MARK: - Accents

    /// Gold — the brand accent: app title, key numbers.
    public static let accentGold: Color = Color(hex: FleetColors.accentGold)
    /// Magenta — primary actions, active tab, send button.
    public static let accentMagenta: Color = Color(hex: FleetColors.accentMagenta)
    /// Cyan — links, "View All", network detail.
    public static let accentCyan: Color = Color(hex: FleetColors.accentCyan)

    // MARK: - Status

    public static let statusOnline: Color = Color(hex: FleetColors.statusOnline)
    public static let statusIdle: Color = Color(hex: FleetColors.statusIdle)
    public static let statusDegraded: Color = Color(hex: FleetColors.statusDegraded)
    public static let statusOffline: Color = Color(hex: FleetColors.statusOffline)

    /// Tinted pill background derived from a status color (~20%, per mock).
    /// Every status pill computes its background through this token so the
    /// tint stays uniform when U2 introduces `StatusPill`.
    public static func statusPillTint(_ status: Color) -> Color {
        status.opacity(0.2)
    }

    /// U6 (Gold Fleet) — the magenta gradient fill for user message bubbles
    /// and the circular send button (hero mock screen 2). Derived from the
    /// single magenta accent token (no second hex value enters the palette):
    /// full-strength magenta fading toward the dark ground at ~65%.
    public static let accentMagentaGradient: LinearGradient = LinearGradient(
        colors: [accentMagenta, accentMagenta.opacity(0.65)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Legacy aliases (pre-Gold-Fleet token names, still referenced
    // MARK:   by existing screens; re-skin cards U3–U7 migrate call sites)

    /// Primary interactive accent — now Magenta (was Signal Red).
    @available(*, deprecated, renamed: "accentMagenta")
    public static var accent: Color { accentMagenta }

    /// Cold categorical accent — now Cyan (was Electric Blue).
    @available(*, deprecated, renamed: "accentCyan")
    public static var accentColdBlue: Color { accentCyan }

    /// Hairline separator — now the border token.
    @available(*, deprecated, renamed: "border")
    public static var separator: Color { border }

    // MARK: - Radii

    /// Cards.
    public static let radiusCard: CGFloat = 16
    /// List rows.
    public static let radiusRow: CGFloat = 12
    /// Message bubbles.
    public static let radiusBubble: CGFloat = 18
    /// Pills are fully rounded: use `.clipShape(Capsule())`; `.infinity`
    /// communicates "not a fixed radius" for any cornerRadius-based layout.
    public static let radiusPill: CGFloat = .infinity

    // MARK: - Spacing scale

    public static let spacingXs: CGFloat = 4
    public static let spacingSm: CGFloat = 8
    public static let spacingMd: CGFloat = 12
    public static let spacingLg: CGFloat = 16
    public static let spacingXl: CGFloat = 24
    public static let spacingXxl: CGFloat = 32

    // MARK: - Typography (SF Pro / system)

    /// Gold app title — 28pt bold.
    public static let titleFont: Font = .system(size: titleFontSize, weight: titleFontWeight)
    public static let titleFontSize: CGFloat = 28
    public static let titleFontWeight: Font.Weight = .bold

    /// Section headers — 17pt semibold (white).
    public static let sectionHeaderFont: Font = .system(size: sectionHeaderFontSize, weight: sectionHeaderFontWeight)
    public static let sectionHeaderFontSize: CGFloat = 17
    public static let sectionHeaderFontWeight: Font.Weight = .semibold

    /// Stat numbers — 28pt bold.
    public static let statFont: Font = .system(size: statFontSize, weight: statFontWeight)
    public static let statFontSize: CGFloat = 28
    public static let statFontWeight: Font.Weight = .bold

    /// Secondary text — 13pt regular.
    public static let secondaryFont: Font = .system(size: secondaryFontSize, weight: secondaryFontWeight)
    public static let secondaryFontSize: CGFloat = 13
    public static let secondaryFontWeight: Font.Weight = .regular
}
