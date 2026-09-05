import SwiftUI
import CoreText
#if canImport(UIKit)
import UIKit
#endif

/// Solid sRGB color from a 0xRRGGBB value.
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

/// Raw palette — the single source of truth for every hex value.
///
/// V1 design pivot (2026-09-02, plan: gold-fleet-v2 "Direction A — Nous
/// terminal minimalism", Tony-approved): the Gold Fleet blue-gray/gold table
/// is REPLACED, not extended. Nous DNA (from nousresearch.com): near-black
/// canvas, off-white text, pale-cyan accent, #32373C-family grays. Semantic
/// status colors are unchanged.
///
/// Drift guard: `FleetThemeTests` pins this table. Change a value here ONLY
/// with a matching design decision.
public enum FleetColors {
    // MARK: Neutrals (Nous #32373C family on stark near-black)
    public static let background: UInt32 = 0x0A0A0A      // screen canvas
    public static let surface: UInt32 = 0x16161A         // cards, list rows
    public static let surfaceElevated: UInt32 = 0x1D1E22 // elevated surface
    public static let border: UInt32 = 0x32373C          // hairline strokes (full opacity)
    public static let textPrimary: UInt32 = 0xEDEDED     // titles, values (off-white)
    public static let textSecondary: UInt32 = 0x9BA1A6   // labels, metadata keys

    // MARK: V5 accessibility tokens (design review t_b2628d33)
    /// Muted foreground — the FIXED replacement for opacity-dimmed
    /// textSecondary (0.6–0.7 alpha blends landed at 3.27–4.0:1, below AA).
    /// 5.24:1 on surface, 4.84:1 on elevated, 4.72:1 on surfaceIncreased —
    /// AA on every surface it renders on.
    public static let textMuted: UInt32 = 0x858B91
    /// Increase Contrast: stronger hairline (1.65:1 → 3.28:1 vs canvas).
    public static let borderIncreased: UInt32 = 0x5A646D
    /// Increase Contrast: lifted card surface (1.1:1 → 1.22:1 vs canvas;
    /// every text token GAINS contrast on it — textPrimary 13.89:1,
    /// textSecondary 6.23:1, textMuted 4.19:1, accent 12.79:1).
    public static let surfaceIncreased: UInt32 = 0x1F2025

    // MARK: Accent — ONE accent: pale cyan (links, active states, key numbers)
    public static let accent: UInt32 = 0x98F3F9

    // MARK: Legacy Gold Fleet accents (V1 keeps the tokens so unmigrated
    // MARK: screens compile; V2/V3 migrate call sites. Gold survives only as
    // MARK: the artwork/wordmark tie; magenta is demoted to send/action.)
    public static let accentGold: UInt32 = 0xFFD700
    public static let accentMagenta: UInt32 = 0xFF1F6A

    // MARK: Status (semantic — unchanged by the design pivot)
    public static let statusOnline: UInt32 = 0x00C853    // Running/Online pills
    public static let statusIdle: UInt32 = 0xFFC107      // Idle pills
    public static let statusDegraded: UInt32 = 0xFF5252  // Degraded/error pills
    /// V5 accessibility fix (t_b2628d33): was 0x6A6A7A (3.4:1 on surface —
    /// below WCAG AA). 0x8A8A9A is 5.31:1 on surface / 4.9:1 on elevated.
    /// The OFFLINE PILL LABEL renders in textPrimary (13:1+); this token is
    /// the dot/tint/grays (it is also textSecondary-adjacent metadata gray
    /// elsewhere, where 5.31:1 clears AA on its own).
    public static let statusOffline: UInt32 = 0x8A8A9A   // Offline pills
}

/// Native semantic roles: adaptive light/dark colors, rounded system display
/// typography, and monospaced technical metadata. Dark raw palette values
/// remain stable; light counterparts are contrast-tested on every surface.
public enum FleetTheme {
    /// Semantic colors resolve at render time, including sheets and system controls.
    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
        #else
        return Color(hex: dark)
        #endif
    }


    // MARK: - Neutrals

    public static let background: Color = adaptive(dark: FleetColors.background, light: 0xF3F4F8)
    public static let surface: Color = adaptive(dark: FleetColors.surface, light: 0xFFFFFF)
    public static let surfaceElevated: Color = adaptive(dark: FleetColors.surfaceElevated, light: 0xE9ECF3)
    public static let textPrimary: Color = adaptive(dark: FleetColors.textPrimary, light: 0x171923)
    public static let textSecondary: Color = adaptive(dark: FleetColors.textSecondary, light: 0x515969)

    /// V5: muted foreground — the fixed-contrast replacement for opacity
    /// dimming of secondary text (card IDs, empty-lane placeholders).
    public static let textMuted: Color = adaptive(dark: FleetColors.textMuted, light: 0x606979)

    /// V5: Increase Contrast card surface — resolves to the base surface
    /// token elsewhere (views pick via `.colorSchemeContrast`).
    public static let surfaceIncreased: Color = adaptive(dark: FleetColors.surfaceIncreased, light: 0xFFFFFF)

    /// 1px hairline card borders: #32373C at full opacity (a hairline IS the
    /// restraint — no soft translucency).
    public static let border: Color = adaptive(dark: FleetColors.border, light: 0xCBD0DC)

    // MARK: - Accent (ONE accent: pale cyan)

    /// Pale cyan — links, active states, key numbers, primary tint.
    public static let accent: Color = adaptive(dark: FleetColors.accent, light: 0x006B78)

    // MARK: - Legacy Gold Fleet aliases (V2/V3 migrate remaining call sites)

    /// Legacy cyan accent — same semantic role as the new accent, now pale
    /// cyan. Kept so existing "link/action" call sites compile and already
    /// read Nous; screens migrate to `FleetTheme.accent` in the V3 sweep.
    @available(*, deprecated, renamed: "accent")
    public static var accentCyan: Color { accent }

    /// Gold — retained for the artwork/wordmark tie only.
    public static let accentGold: Color = adaptive(dark: FleetColors.accentGold, light: 0x866000)
    /// Magenta — send button / primary action only until V2 restyles it.
    public static let accentMagenta: Color = adaptive(dark: FleetColors.accentMagenta, light: 0xB51D58)

    // MARK: - Status (semantic, unchanged)

    public static let statusOnline: Color = adaptive(dark: FleetColors.statusOnline, light: 0x00753B)
    public static let statusIdle: Color = adaptive(dark: FleetColors.statusIdle, light: 0x856000)
    public static let statusDegraded: Color = adaptive(dark: FleetColors.statusDegraded, light: 0xC02835)
    public static let statusOffline: Color = adaptive(dark: FleetColors.statusOffline, light: 0x626879)

    /// Tinted pill background derived from a status color (~20%).
    public static func statusPillTint(_ status: Color) -> Color {
        status.opacity(0.2)
    }

    // MARK: - Increase Contrast (V5 accessibility, t_b2628d33)

    /// Contrast-aware hairline: the standard #32373C token, strengthened to
    /// borderIncreased (#5A646D, 1.65:1 → 3.28:1 vs canvas) when the user
    /// enables iOS Increase Contrast. Custom fixed hex colors are not remapped
    /// by the system, so the theme adapts them itself.
    public static func borderColor(colorSchemeContrast: ColorSchemeContrast) -> Color {
        colorSchemeContrast == .increased
            ? adaptive(dark: FleetColors.borderIncreased, light: 0x697384)
            : border
    }

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

    // MARK: - Typography (system display, monospaced metadata)
    //
    // V5 accessibility (t_b2628d33): every role below is Dynamic-Type aware.
    // Mono faces scale via `Font.custom(_:size:relativeTo:)` (see
    // FleetFonts.monoDisplay) and the SF roles via `.custom-scaled` system
    // text styles, so Courier Prime keeps its identity while tracking the
    // user's text size like body text does.

    /// Screen titles / hero numbers — 28pt bold MONO (Courier Prime),
    /// scaling with the user's text size (relative to .title2).
    public static let titleFont: Font = .system(.largeTitle, design: .rounded, weight: .bold)
    public static let titleFontSize: CGFloat = 28
    public static let titleFontWeight: Font.Weight = .bold

    /// Section headers — the UPPERCASE micro-label role: 11pt semibold,
    /// callers apply `.textCase(.uppercase)` + `microLabelTracking`.
    /// Scales with Dynamic Type via the .caption2 text style (11pt at the
    /// default content size — an exact base-size match).
    public static let sectionHeaderFont: Font = .caption2.weight(sectionHeaderFontWeight)
    public static let sectionHeaderFontSize: CGFloat = FleetTheme.microLabelFontSize
    public static let sectionHeaderFontWeight: Font.Weight = .semibold

    /// Stat numbers — 28pt bold MONO with tabular figures (dashboards line
    /// up), scaling with Dynamic Type (relative to .title2).
    public static let statFont: Font = .system(.title, design: .rounded, weight: .semibold).monospacedDigit()
    public static let statFontSize: CGFloat = 28
    public static let statFontWeight: Font.Weight = .bold

    /// Secondary text — 13pt regular SF Pro (readability role), scaling with
    /// Dynamic Type via the .footnote text style (13pt at the default content
    /// size — an exact base-size match).
    public static let secondaryFont: Font = .footnote.weight(secondaryFontWeight)
    public static let secondaryFontSize: CGFloat = 13
    public static let secondaryFontWeight: Font.Weight = .regular

    /// UPPERCASE micro-label — 11pt semibold caps with wide tracking
    /// ("GATEWAYS", "ACTIVE BOTS"). Apply `.textCase(.uppercase)` and
    /// `.tracking(microLabelTracking)` at the call site (Font cannot encode
    /// either). ~0.13em at 11pt. Scales with Dynamic Type via .caption2
    /// (11pt at the default content size — an exact base-size match).
    public static let microLabelFont: Font = .caption2.weight(.semibold)
    public static let microLabelFontSize: CGFloat = 11
    public static let microLabelTracking: CGFloat = 1.4

    /// Mono body role — 13pt regular MONO for IDs, uptime, telemetry, and
    /// terminal `KEY:` metadata rows (see FleetMetadataRow). Scales with
    /// Dynamic Type (footnote-class).
    public static let monoFont: Font = FleetFonts.monoDisplay(size: monoFontSize, weight: .regular, relativeTo: .footnote)
    public static let monoFontSize: CGFloat = 13

    /// Mono caption — 11pt regular MONO for tight metadata (timestamps).
    /// Scales with Dynamic Type (caption2-class: 11pt base, exact match).
    public static let monoCaptionFont: Font = FleetFonts.monoDisplay(size: monoCaptionFontSize, weight: .regular, relativeTo: .caption2)
    public static let monoCaptionFontSize: CGFloat = 11
}

/// Courier Prime (OFL, bundled in FleetUI Resources) with SF Mono fallback.
///
/// Registration is a process-scoped one-shot (lazy `static let` init is
/// swift_once, hence thread-safe without extra locking). If the custom face
/// is unavailable for ANY reason the `mono*` factories fall back to
/// `.system(design: .monospaced)` so the mono identity never breaks — it
/// degrades to SF Mono.
public enum FleetFonts {

    /// PostScript names of the bundled faces (verified against the TTFs).
    public static let courierPrimeRegular = "CourierPrime-Regular"
    public static let courierPrimeBold = "CourierPrime-Bold"

    /// One-shot registration of the bundled faces. Returns true when the
    /// Courier Prime faces are usable (registered now or already present).
    private static let registrationSucceeded: Bool = {
        var succeeded = false
        for name in [courierPrimeRegular, courierPrimeBold] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf") else {
                continue
            }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                succeeded = true
            } else if let cfError = error?.takeRetainedValue(),
                CFErrorGetCode(cfError) == CTFontManagerError.alreadyRegistered.rawValue {
                succeeded = true
            }
        }
        return succeeded
    }()

    /// Whether the bundled Courier Prime faces resolve through the platform
    /// font API. Pinned by FleetThemeTests (fonts must actually ship).
    public static var courierPrimeAvailable: Bool {
        guard registrationSucceeded else { return false }
        return Self.faceResolves(faceName: courierPrimeRegular)
            && Self.faceResolves(faceName: courierPrimeBold)
    }

    #if canImport(UIKit)
    private static func faceResolves(faceName name: String) -> Bool {
        UIFont(name: name, size: 12) != nil
    }
    #else
    // macOS host-side build convenience (the product targets iOS): treat
    // bundle presence + registration success as availability.
    private static func faceResolves(faceName name: String) -> Bool {
        Bundle.module.url(forResource: name, withExtension: "ttf") != nil
    }
    #endif

    /// Mono display font: Courier Prime when bundled, SF Mono otherwise.
    ///
    /// Weight mapping: `.bold` and heavier use the Bold face; everything
    /// lighter uses Regular (the two bundled weights are the whole family).
    ///
    /// V5 accessibility (t_b2628d33): `relativeTo:` makes the custom face
    /// track Dynamic Type — the point size is the base at the default (`.large`)
    /// content size and scales with the user's text-size setting while the
    /// Courier Prime identity is preserved. The SF Mono fallback branch is
    /// scaled the same way (the `.monospaced` design on a scaled size).
    public static func monoDisplay(size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle? = nil) -> Font {
        let useBold: Bool
        switch weight {
        case .bold, .heavy, .black: useBold = true
        default: useBold = false
        }
        let face = useBold ? courierPrimeBold : courierPrimeRegular
        if Self.faceResolves(faceName: face) {
            if let style {
                return .custom(face, size: size, relativeTo: style)
            }
            return .custom(face, size: size)
        }
        if let style {
            // SF Mono fallback: the text-style system font with the
            // monospaced design scales with Dynamic Type natively (Courier
            // Prime resolving is pinned by tests, so this is a safety net).
            return .system(style, design: .monospaced, weight: weight)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }
}
