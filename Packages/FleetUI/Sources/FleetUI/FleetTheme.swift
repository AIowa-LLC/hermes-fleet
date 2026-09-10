import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Shared UI tokens for the Hermes Fleet interface (FOS-7, SPEC §14).
///
/// The visual system uses one fixed Fleet violet for interactive tint and
/// selected navigation, balanced by near-neutral surfaces and high-contrast
/// names. Status hues are semantic and never the only differentiator:
/// connectivity is green, active execution is cyan, intervention is amber,
/// degraded service is orange, destructive/error is red. Waiting, offline,
/// and unknown render as secondary label — no alarm tint.
///
/// The sRGB values below are specification values for OPAQUE content
/// (canvas / grouped surface). Navigation keeps native platform materials.
/// `FleetThemeTests` pins the light/dark resolution of every semantic token;
/// `scripts/fos7_contrast_gate.py` gates the WCAG ratios against SPEC §14.
public enum FleetColors {
    // MARK: - Interactive (fixed Fleet violet, SPEC §14 identity decision)

    public static let interactiveLight: UInt32 = 0x5B35D5
    public static let interactiveDark: UInt32 = 0xBDA7FF
    /// Increase Contrast variants (SPEC §14).
    public static let interactiveHighContrastLight: UInt32 = 0x422093
    public static let interactiveHighContrastDark: UInt32 = 0xD5C7FF

    // MARK: - Status (SPEC §14 token table)

    public static let onlineLight: UInt32 = 0x176B46
    public static let onlineDark: UInt32 = 0x73D6A0

    public static let executingLight: UInt32 = 0x006D87
    public static let executingDark: UInt32 = 0x65D9F0

    public static let needsInterventionLight: UInt32 = 0x865400
    public static let needsInterventionDark: UInt32 = 0xFFD080

    public static let degradedLight: UInt32 = 0x9D4713
    public static let degradedDark: UInt32 = 0xFFBA8A

    public static let destructiveLight: UInt32 = 0xB42335
    public static let destructiveDark: UInt32 = 0xFF97A3

    // MARK: - Surfaces (opaque content; SPEC §14 canvas / grouped surface)

    public static let canvasLight: UInt32 = 0xF8F9FC
    public static let canvasDark: UInt32 = 0x101216

    public static let groupedSurfaceLight: UInt32 = 0xFFFFFF
    public static let groupedSurfaceDark: UInt32 = 0x1B1E24
}

/// FOS-7 visual system tokens: fixed Fleet violet interactive tint, semantic
/// status colors, opaque canvas/grouped surfaces, system labels/separators,
/// and the SPEC §14 typography scale (system SF default design, Dynamic Type
/// text styles only — never fixed unscaled pixel fonts).
public enum FleetTheme {

    #if canImport(UIKit)
    /// Adaptive sRGB color from 0xRRGGBB values. Light/dark values are
    /// pinned by `FleetThemeTests`.
    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return Self.rgb(hex)
        })
    }

    /// Adaptive sRGB color with an Increase Contrast variant (SPEC §14).
    private static func adaptiveHighContrast(
        dark: UInt32, light: UInt32,
        highContrastDark: UInt32, highContrastLight: UInt32
    ) -> Color {
        Color(uiColor: UIColor { traits in
            let highContrast = traits.accessibilityContrast == .high
            let style = traits.userInterfaceStyle == .dark
            if highContrast {
                return Self.rgb(style ? highContrastDark : highContrastLight)
            }
            return Self.rgb(style ? dark : light)
        })
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    #endif

    // MARK: - Surfaces

    /// Canvas — the main operational background (opaque content token).
    /// Increase Contrast falls back to the opaque system background
    /// (SPEC §14: "an opaque system background" under Increase Contrast).
    public static let background: Color = {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            if traits.accessibilityContrast == .high {
                return .systemBackground
            }
            return traits.userInterfaceStyle == .dark
                ? Self.rgb(FleetColors.canvasDark)
                : Self.rgb(FleetColors.canvasLight)
        })
        #else
        Color(uiColor: .systemBackground)
        #endif
    }()

    /// Grouped surface — attention groups, inspectors, meaningful aggregates
    /// (opaque content token; cards stay opaque per SPEC §14 materials).
    public static let surface: Color = {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            if traits.accessibilityContrast == .high {
                return .systemBackground
            }
            return traits.userInterfaceStyle == .dark
                ? Self.rgb(FleetColors.groupedSurfaceDark)
                : Self.rgb(FleetColors.groupedSurfaceLight)
        })
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }()

    /// Elevated inline surface (chips, active-now capsules). System tertiary
    /// so it adapts natively; never translucent glass behind body content.
    public static let surfaceElevated: Color = Color(uiColor: .tertiarySystemBackground)

    /// Contrast-aware card surface. Increase Contrast lifts to the opaque
    /// system background; this seam keeps that behavior testable.
    public static let surfaceIncreased: Color = surface

    // MARK: - Text (system labels remain preferred for text, SPEC §14)

    public static let textPrimary: Color = Color(uiColor: .label)
    public static let textSecondary: Color = Color(uiColor: .secondaryLabel)
    public static let textMuted: Color = Color(uiColor: .tertiaryLabel)

    /// Hairline separators use the system separator.
    public static let border: Color = Color(uiColor: .separator)

    /// Strengthen the separator when Increase Contrast is enabled
    /// (SPEC §14: opaqueSeparator in Increase Contrast).
    public static func borderColor(colorSchemeContrast: ColorSchemeContrast) -> Color {
        colorSchemeContrast == .increased
            ? Color(uiColor: .opaqueSeparator)
            : Color(uiColor: .separator)
    }

    // MARK: - Interactive (fixed Fleet violet)

    /// Links, selected controls, and the primary action tint. FOS-7 (SPEC
    /// §14): one fixed Fleet violet — the V7.5 accent picker no longer
    /// applies. The stored pick is preserved untouched for rollback.
    /// Increase Contrast resolves to the stronger silhouette variants.
    public static let accent: Color = adaptiveHighContrast(
        dark: FleetColors.interactiveDark,
        light: FleetColors.interactiveLight,
        highContrastDark: FleetColors.interactiveHighContrastDark,
        highContrastLight: FleetColors.interactiveHighContrastLight
    )

    // MARK: - Status (semantic, SPEC §14 table)

    /// Online / connected — checkmark + "Connected"; does not mean working.
    public static let statusOnline: Color = adaptive(
        dark: FleetColors.onlineDark, light: FleetColors.onlineLight)

    /// Executing — Working / Thinking / Using tool glyph accent.
    public static let statusExecuting: Color = adaptive(
        dark: FleetColors.executingDark, light: FleetColors.executingLight)

    /// Needs intervention — person/exclamation cue + "Needs you".
    public static let statusNeedsIntervention: Color = adaptive(
        dark: FleetColors.needsInterventionDark, light: FleetColors.needsInterventionLight)

    /// Degraded — triangle + precise degraded reason (partial service).
    public static let statusDegraded: Color = adaptive(
        dark: FleetColors.degradedDark, light: FleetColors.degradedLight)

    /// Destructive actions and terminal failure labels (with explanation).
    public static let statusDestructive: Color = adaptive(
        dark: FleetColors.destructiveDark, light: FleetColors.destructiveLight)

    /// Neutral status reinforcement for waiting, offline, and unknown. This
    /// remains a platform semantic label rather than inheriting a user's
    /// custom primary/secondary text choice.
    public static let statusNeutral: Color = Color(uiColor: .secondaryLabel)

    /// Waiting, offline, and unknown never take an alarm tint — they render
    /// as secondary label (SPEC §14 waiting/offline/unknown rows).

    /// Tinted pill background derived from a status color (~20%).
    public static func statusPillTint(_ status: Color) -> Color {
        status.opacity(0.2)
    }

    // MARK: - Radii

    /// Meaningful grouped surfaces (SPEC §14: 12–16-point radius).
    public static let radiusCard: CGFloat = 16
    /// List rows.
    public static let radiusRow: CGFloat = 12
    /// Message bubbles.
    public static let radiusBubble: CGFloat = 18
    /// Pills are fully rounded: use `.clipShape(Capsule())`.

    // MARK: - Spacing scale (SPEC §14 base rhythm 4/8/12/16/24)

    public static let spacingXs: CGFloat = 4
    public static let spacingSm: CGFloat = 8
    public static let spacingMd: CGFloat = 12
    public static let spacingLg: CGFloat = 16
    public static let spacingXl: CGFloat = 24
    public static let spacingXxl: CGFloat = 32

    // MARK: - Typography (SPEC §14: system SF default design, Dynamic Type)

    /// Screen titles: system large title, default design (rounded-bold is
    /// retired by SPEC §14).
    public static let titleFont: Font = .system(.largeTitle, design: .default, weight: .bold)
    public static let titleFontSize: CGFloat = 34
    public static let titleFontWeight: Font.Weight = .bold

    /// Section headings: headline semibold, sentence/title case — no wide
    /// letter spacing, no tracked uppercase micro-labels (SPEC §14).
    public static let sectionHeaderFont: Font = .headline.weight(sectionHeaderFontWeight)
    public static let sectionHeaderFontSize: CGFloat = 17
    public static let sectionHeaderFontWeight: Font.Weight = .semibold

    /// Glance numbers: Title 3 semibold with monospaced (tabular) digits —
    /// approximately 20 points, no giant stat tile (SPEC §14).
    public static let statFont: Font = .system(.title3, design: .default, weight: .semibold).monospacedDigit()
    public static let statFontSize: CGFloat = 20
    public static let statFontWeight: Font.Weight = .semibold

    /// Secondary / supporting text: footnote regular (13-point default —
    /// also the provenance/timestamp role per SPEC §14).
    public static let secondaryFont: Font = .footnote.weight(secondaryFontWeight)
    public static let secondaryFontSize: CGFloat = 13
    public static let secondaryFontWeight: Font.Weight = .regular

    /// Small inline label (badges, chips): caption2 semibold, no tracking.
    public static let microLabelFont: Font = .caption2.weight(.semibold)
    public static let microLabelFontSize: CGFloat = 11

    /// Monospaced text — machine tokens and tabular values ONLY (SPEC §14).
    public static let monoFont: Font = .system(.footnote, design: .monospaced)
    public static let monoFontSize: CGFloat = 13

    /// Monospaced compact caption text (ids, endpoints, timestamps).
    public static let monoCaptionFont: Font = .system(.caption2, design: .monospaced)
    public static let monoCaptionFontSize: CGFloat = 11
}
