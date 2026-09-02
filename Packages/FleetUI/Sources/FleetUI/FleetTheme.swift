import SwiftUI
import CoreText
#if canImport(UIKit)
import UIKit
#endif

/// Solid sRGB color from a 0xRRGGBB value.
///
/// V1 (Nous direction): Fleet stays DARK-ONLY — stark near-black canvas,
/// off-white text, one pale-cyan accent. Tokens are fixed values, not
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
    public static let statusOffline: UInt32 = 0x6A6A7A   // Offline pills
}

/// The Hermes Fleet design system — V1 "Nous terminal minimalism".
///
/// Stark #0A0A0A canvas, monospace as identity (Courier Prime with SF Mono
/// fallback) for titles/stats/IDs, UPPERCASE micro-labels with wide tracking,
/// one pale-cyan accent, hairline structure, terminal artifacts as brand.
/// FLAT design: no glass soup, no gradients on surfaces, no shadows.
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

    /// 1px hairline card borders: #32373C at full opacity (a hairline IS the
    /// restraint — no soft translucency).
    public static let border: Color = Color(hex: FleetColors.border)

    // MARK: - Accent (ONE accent: pale cyan)

    /// Pale cyan — links, active states, key numbers, primary tint.
    public static let accent: Color = Color(hex: FleetColors.accent)

    // MARK: - Legacy Gold Fleet aliases (V2/V3 migrate remaining call sites)

    /// Legacy cyan accent — same semantic role as the new accent, now pale
    /// cyan. Kept so existing "link/action" call sites compile and already
    /// read Nous; screens migrate to `FleetTheme.accent` in the V3 sweep.
    @available(*, deprecated, renamed: "accent")
    public static var accentCyan: Color { accent }

    /// Gold — retained for the artwork/wordmark tie only.
    public static let accentGold: Color = Color(hex: FleetColors.accentGold)
    /// Magenta — send button / primary action only until V2 restyles it.
    public static let accentMagenta: Color = Color(hex: FleetColors.accentMagenta)

    // MARK: - Status (semantic, unchanged)

    public static let statusOnline: Color = Color(hex: FleetColors.statusOnline)
    public static let statusIdle: Color = Color(hex: FleetColors.statusIdle)
    public static let statusDegraded: Color = Color(hex: FleetColors.statusDegraded)
    public static let statusOffline: Color = Color(hex: FleetColors.statusOffline)

    /// Tinted pill background derived from a status color (~20%).
    public static func statusPillTint(_ status: Color) -> Color {
        status.opacity(0.2)
    }

    /// The magenta gradient fill for user message bubbles and the circular
    /// send button (legacy Gold Fleet role, pending the V2 component pass).
    public static let accentMagentaGradient: LinearGradient = LinearGradient(
        colors: [accentMagenta, accentMagenta.opacity(0.65)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

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

    // MARK: - Typography (mono as identity; body stays SF Pro)

    /// Screen titles / hero numbers — 28pt bold MONO (Courier Prime).
    public static let titleFont: Font = FleetFonts.monoDisplay(size: titleFontSize, weight: titleFontWeight)
    public static let titleFontSize: CGFloat = 28
    public static let titleFontWeight: Font.Weight = .bold

    /// Section headers — now the UPPERCASE micro-label role: 11pt semibold,
    /// callers apply `.textCase(.uppercase)` + `microLabelTracking`.
    public static let sectionHeaderFont: Font = .system(size: sectionHeaderFontSize, weight: sectionHeaderFontWeight)
    public static let sectionHeaderFontSize: CGFloat = FleetTheme.microLabelFontSize
    public static let sectionHeaderFontWeight: Font.Weight = .semibold

    /// Stat numbers — 28pt bold MONO with tabular figures (dashboards line up).
    public static let statFont: Font = FleetFonts.monoDisplay(size: statFontSize, weight: statFontWeight).monospacedDigit()
    public static let statFontSize: CGFloat = 28
    public static let statFontWeight: Font.Weight = .bold

    /// Secondary text — 13pt regular SF Pro (readability role).
    public static let secondaryFont: Font = .system(size: secondaryFontSize, weight: secondaryFontWeight)
    public static let secondaryFontSize: CGFloat = 13
    public static let secondaryFontWeight: Font.Weight = .regular

    /// UPPERCASE micro-label — 11pt semibold caps with wide tracking
    /// ("GATEWAYS", "ACTIVE BOTS"). Apply `.textCase(.uppercase)` and
    /// `.tracking(microLabelTracking)` at the call site (Font cannot encode
    /// either). ~0.13em at 11pt.
    public static let microLabelFont: Font = .system(size: microLabelFontSize, weight: .semibold)
    public static let microLabelFontSize: CGFloat = 11
    public static let microLabelTracking: CGFloat = 1.4

    /// Mono body role — 13pt regular MONO for IDs, uptime, telemetry, and
    /// terminal `KEY:` metadata rows (see FleetMetadataRow).
    public static let monoFont: Font = FleetFonts.monoDisplay(size: monoFontSize, weight: .regular)
    public static let monoFontSize: CGFloat = 13

    /// Mono caption — 11pt regular MONO for tight metadata (timestamps).
    public static let monoCaptionFont: Font = FleetFonts.monoDisplay(size: monoCaptionFontSize, weight: .regular)
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
    public static func monoDisplay(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let useBold: Bool
        switch weight {
        case .bold, .heavy, .black: useBold = true
        default: useBold = false
        }
        let face = useBold ? courierPrimeBold : courierPrimeRegular
        if Self.faceResolves(faceName: face) {
            return .custom(face, size: size)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }
}
