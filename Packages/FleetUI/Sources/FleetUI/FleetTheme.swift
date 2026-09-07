import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// V7 HIG-native theme (t_9ce36690 / D5 spec, 2026-09-04): every bespoke
/// palette token is DELETED — no descendants. Surfaces, text, borders and the
/// single accent resolve through system semantic colors, so light/dark,
/// Increase Contrast and platform evolution come from the OS, not from us.
///
/// Drift guard: `FleetThemeTests` now pins SYSTEM resolution — each FleetTheme
/// color must resolve identically to its corresponding system color in BOTH
/// light and dark appearances. Any future bespoke drift fails there.
///
/// Brand anchor: the white-wing icon (HermesFleetApp/FleetWing.icon) is
/// FINAL. The only brand color in the app is the single accent below
/// (system blue pending Tony's swatch pick).
public enum FleetColors {
    // MARK: Status (semantic status, not brand skin — V5 AA-fixed adaptive
    // values retained per D5; revisit in the V7.5 AX pass only).
    public static let statusOnline: UInt32 = 0x00C853    // Running/Online pills
    public static let statusIdle: UInt32 = 0xFFC107      // Idle pills
    public static let statusDegraded: UInt32 = 0xFF5252  // Degraded/error pills
    public static let statusOffline: UInt32 = 0x8A8A9A   // Offline pills

    // Status light-mode counterparts (V5 AA fixes, unchanged).
    public static let statusOnlineLight: UInt32 = 0x00753B
    public static let statusIdleLight: UInt32 = 0x856000
    public static let statusDegradedLight: UInt32 = 0xC02835
    public static let statusOfflineLight: UInt32 = 0x626879
}

/// HIG-native theme: system surfaces, semantic labels, separators, SF type,
/// ONE system accent. No custom hex anywhere outside semantic status.
public enum FleetTheme {

    #if canImport(UIKit)
    /// Adaptive sRGB color from 0xRRGGBB values — retained ONLY for the
    /// semantic status tokens (their adaptive values are pinned by tests).
    /// Not for brand/skin colors (V7: those are gone).
    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
    #endif

    // MARK: - Neutrals (system surfaces)

    public static let background: Color = Color(uiColor: .systemBackground)
    public static let surface: Color = Color(uiColor: .secondarySystemBackground)
    public static let surfaceElevated: Color = Color(uiColor: .tertiarySystemBackground)

    // MARK: - Text (semantic labels)

    public static let textPrimary: Color = Color(uiColor: .label)
    public static let textSecondary: Color = Color(uiColor: .secondaryLabel)
    public static let textMuted: Color = Color(uiColor: .tertiaryLabel)

    /// V5 increase-contrast remap, system era: with Increase Contrast the
    /// card surface lifts to the high-contrast system background. System
    /// colors remap automatically; this token keeps the explicit seam.
    public static let surfaceIncreased: Color = {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            if traits.accessibilityContrast == .high {
                return .systemBackground
            }
            return .secondarySystemBackground
        })
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }()

    /// Hairline separators: the system separator.
    public static let border: Color = Color(uiColor: .separator)

    /// Contrast-aware hairline: the standard separator, strengthened to the
    /// opaque separator when the user enables Increase Contrast.
    public static func borderColor(colorSchemeContrast: ColorSchemeContrast) -> Color {
        colorSchemeContrast == .increased
            ? Color(uiColor: .opaqueSeparator)
            : Color(uiColor: .separator)
    }

    // MARK: - Accent (ONE accent, user-choosable — V7.5)

    /// The single accent — links, active states, primary tint. Resolves to
    /// the user's persisted FleetAccent selection (Settings ▸ Appearance);
    /// systemBlue until they pick otherwise.
    public static var accent: Color {
        FleetAccentController.shared.selection.color
    }

    // MARK: - Status (semantic, V5 AA-fixed values retained)

    #if canImport(UIKit)
    public static let statusOnline: Color = adaptive(dark: FleetColors.statusOnline, light: FleetColors.statusOnlineLight)
    public static let statusIdle: Color = adaptive(dark: FleetColors.statusIdle, light: FleetColors.statusIdleLight)
    public static let statusDegraded: Color = adaptive(dark: FleetColors.statusDegraded, light: FleetColors.statusDegradedLight)
    public static let statusOffline: Color = adaptive(dark: FleetColors.statusOffline, light: FleetColors.statusOfflineLight)
    #endif

    /// Tinted pill background derived from a status color (~20%).
    public static func statusPillTint(_ status: Color) -> Color {
        status.opacity(0.2)
    }

    // MARK: - Radii

    /// Cards.
    public static let radiusCard: CGFloat = 16
    /// List rows.
    public static let radiusRow: CGFloat = 12
    /// Message bubbles.
    public static let radiusBubble: CGFloat = 18
    /// Pills are fully rounded: use `.clipShape(Capsule())`.

    // MARK: - Spacing scale

    public static let spacingXs: CGFloat = 4
    public static let spacingSm: CGFloat = 8
    public static let spacingMd: CGFloat = 12
    public static let spacingLg: CGFloat = 16
    public static let spacingXl: CGFloat = 24
    public static let spacingXxl: CGFloat = 32

    // MARK: - Typography (SF Pro + SF Mono — Q1 default, D5)

    /// Screen titles — system large title, rounded, bold.
    public static let titleFont: Font = .system(.largeTitle, design: .rounded, weight: .bold)
    public static let titleFontSize: CGFloat = 28
    public static let titleFontWeight: Font.Weight = .bold

    /// Section headers — caption2 semibold; callers apply
    /// `.textCase(.uppercase)` + `microLabelTracking`.
    public static let sectionHeaderFont: Font = .caption2.weight(sectionHeaderFontWeight)
    public static let sectionHeaderFontSize: CGFloat = FleetTheme.microLabelFontSize
    public static let sectionHeaderFontWeight: Font.Weight = .semibold

    /// Stat numbers — system title, tabular figures.
    public static let statFont: Font = .system(.title, design: .rounded, weight: .semibold).monospacedDigit()
    public static let statFontSize: CGFloat = 28
    public static let statFontWeight: Font.Weight = .bold

    /// Secondary text — footnote regular.
    public static let secondaryFont: Font = .footnote.weight(secondaryFontWeight)
    public static let secondaryFontSize: CGFloat = 13
    public static let secondaryFontWeight: Font.Weight = .regular

    /// UPPERCASE micro-label — caption2 semibold caps, tracking at call site.
    public static let microLabelFont: Font = .caption2.weight(.semibold)
    public static let microLabelFontSize: CGFloat = 11
    public static let microLabelTracking: CGFloat = 1.4

    /// Mono body — SF Mono (system monospaced design), text-style scaled.
    public static let monoFont: Font = .system(.footnote, design: .monospaced)
    public static let monoFontSize: CGFloat = 13

    /// Mono caption — SF Mono caption2-class.
    public static let monoCaptionFont: Font = .system(.caption2, design: .monospaced)
    public static let monoCaptionFontSize: CGFloat = 11
}
