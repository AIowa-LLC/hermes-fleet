import SwiftUI

// MARK: - Adaptive color helper (cross-platform, light/dark)

extension Color {
    /// An adaptive color that resolves to `lightHex` in light appearance and
    /// `darkHex` in dark appearance. Works on both iOS (UIKit) and macOS
    /// (AppKit) so the FleetUI package stays buildable for host-side checks.
    static func adaptive(lightHex: UInt32, darkHex: UInt32) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor(lightHex: lightHex, darkHex: darkHex))
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(lightHex: lightHex, darkHex: darkHex))
        #else
        return Color(hex: lightHex)
        #endif
    }

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

#if canImport(UIKit)
import UIKit

extension UIColor {
    convenience init(lightHex: UInt32, darkHex: UInt32) {
        self.init { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: darkHex)
                : UIColor(hex: lightHex)
        }
    }

    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#elseif canImport(AppKit)
import AppKit

extension NSColor {
    convenience init(lightHex: UInt32, darkHex: UInt32) {
        self.init(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: darkHex)
                : NSColor(hex: lightHex)
        }
    }

    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif

// MARK: - FleetTheme (Black / White / Signal Red)

/// The Hermes Fleet design system — a Black / White / Signal Red foundation
/// with optional Hot Magenta / Cold Electric Blue accents (M14, synthesis §23).
///
/// Every color is light/dark adaptive; contrast values were verified against
/// WCAG 2.1 in `scripts/m14_contrast_gate.py` (text ≥ 4.5:1, UI ≥ 3.0:1).
public enum FleetTheme {

    // MARK: Neutrals

    public static let background: Color = .adaptive(lightHex: 0xFFFFFF, darkHex: 0x0A0A0B)
    public static let surface: Color = .adaptive(lightHex: 0xF2F2F7, darkHex: 0x161618)
    public static let surfaceElevated: Color = .adaptive(lightHex: 0xFFFFFF, darkHex: 0x1F1F22)
    public static let textPrimary: Color = .adaptive(lightHex: 0x17171A, darkHex: 0xF5F5F7)
    public static let textSecondary: Color = .adaptive(lightHex: 0x3C3C43, darkHex: 0x9C9CA4)
    public static let separator: Color = .adaptive(lightHex: 0xC6C6CC, darkHex: 0x2C2C30)

    // MARK: Accents

    /// Signal Red — the single brand/attention accent. Text-capable (≥4.5:1).
    public static let accent: Color = .adaptive(lightHex: 0xC8102E, darkHex: 0xFF453A)
    /// Hot Magenta — optional categorical accent (UI/icon only).
    public static let accentMagenta: Color = .adaptive(lightHex: 0xB4003C, darkHex: 0xFF2D55)
    /// Cold Electric Blue — optional categorical accent (UI/icon only).
    public static let accentColdBlue: Color = .adaptive(lightHex: 0x0064C8, darkHex: 0x0A84FF)
}
