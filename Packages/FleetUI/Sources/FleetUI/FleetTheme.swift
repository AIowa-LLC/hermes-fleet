import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Shared UI tokens for the current Hermes Fleet interface.
///
/// Surfaces, text, borders, and the default interaction palette resolve through
/// system semantic colors so light/dark appearance, Increase Contrast, and
/// platform evolution remain native to iOS. These tokens describe the current
/// implementation; they are not a frozen brand or visual-direction contract.
///
/// `FleetThemeTests` guards semantic-color resolution in light and dark
/// appearances. Future visual work may intentionally evolve this layer as long
/// as accessibility and semantic-state behavior remain explicit and tested.
public enum FleetColors {
    // MARK: Status

    // Semantic status colors are implementation tokens rather than brand
    // colors. They remain adaptive and are pinned by accessibility tests.
    public static let statusOnline: UInt32 = 0x00C853    // Running/Online pills
    public static let statusIdle: UInt32 = 0xFFC107      // Idle pills
    public static let statusDegraded: UInt32 = 0xFF5252  // Degraded/error pills
    public static let statusOffline: UInt32 = 0x8A8A9A   // Offline pills

    public static let statusOnlineLight: UInt32 = 0x00753B
    public static let statusIdleLight: UInt32 = 0x856000
    public static let statusDegradedLight: UInt32 = 0xC02835
    public static let statusOfflineLight: UInt32 = 0x626879
}

/// Current system-native theme implementation: semantic surfaces, labels,
/// separators, typography, a user-selectable accent, and explicit status
/// colors. Visual identity may evolve independently of these APIs.
public enum FleetTheme {

    #if canImport(UIKit)
    /// Adaptive sRGB color from 0xRRGGBB values, used for semantic status
    /// tokens whose light/dark values are pinned by tests.
    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
    #endif

    // MARK: - Neutrals

    public static let background: Color = Color(uiColor: .systemBackground)
    public static let surface: Color = Color(uiColor: .secondarySystemBackground)
    public static let surfaceElevated: Color = Color(uiColor: .tertiarySystemBackground)

    // MARK: - Text

    public static let textPrimary: Color = Color(uiColor: .label)
    public static let textSecondary: Color = Color(uiColor: .secondaryLabel)
    public static let textMuted: Color = Color(uiColor: .tertiaryLabel)

    /// Contrast-aware card surface. System colors remap automatically; this
    /// explicit seam keeps increased-contrast behavior testable.
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

    /// Hairline separators use the system separator.
    public static let border: Color = Color(uiColor: .separator)

    /// Strengthen the separator when Increase Contrast is enabled.
    public static func borderColor(colorSchemeContrast: ColorSchemeContrast) -> Color {
        colorSchemeContrast == .increased
            ? Color(uiColor: .opaqueSeparator)
            : Color(uiColor: .separator)
    }

    // MARK: - Accent

    /// Links, active states, and primary tint resolve to the persisted accent
    /// selected in Settings > Appearance.
    public static var accent: Color {
        FleetAccentController.shared.selection.color
    }

    // MARK: - Status

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

    // MARK: - Typography

    /// Screen titles: system large title, rounded, bold.
    public static let titleFont: Font = .system(.largeTitle, design: .rounded, weight: .bold)
    public static let titleFontSize: CGFloat = 28
    public static let titleFontWeight: Font.Weight = .bold

    /// Section headers: caption2 semibold; callers apply uppercase casing and
    /// `microLabelTracking` when appropriate.
    public static let sectionHeaderFont: Font = .caption2.weight(sectionHeaderFontWeight)
    public static let sectionHeaderFontSize: CGFloat = FleetTheme.microLabelFontSize
    public static let sectionHeaderFontWeight: Font.Weight = .semibold

    /// Stat numbers: system title with tabular figures.
    public static let statFont: Font = .system(.title, design: .rounded, weight: .semibold).monospacedDigit()
    public static let statFontSize: CGFloat = 28
    public static let statFontWeight: Font.Weight = .bold

    /// Secondary text: footnote regular.
    public static let secondaryFont: Font = .footnote.weight(secondaryFontWeight)
    public static let secondaryFontSize: CGFloat = 13
    public static let secondaryFontWeight: Font.Weight = .regular

    /// Uppercase micro-label: caption2 semibold caps, tracking at call site.
    public static let microLabelFont: Font = .caption2.weight(.semibold)
    public static let microLabelFontSize: CGFloat = 11
    public static let microLabelTracking: CGFloat = 1.4

    /// Monospaced body text.
    public static let monoFont: Font = .system(.footnote, design: .monospaced)
    public static let monoFontSize: CGFloat = 13

    /// Monospaced compact caption text.
    public static let monoCaptionFont: Font = .system(.caption2, design: .monospaced)
    public static let monoCaptionFontSize: CGFloat = 11
}
