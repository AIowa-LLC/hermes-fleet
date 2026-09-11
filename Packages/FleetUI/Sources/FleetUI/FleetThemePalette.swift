import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The portable, opaque sRGB representation used by the persisted theme
/// palette. `Color` is intentionally not persisted because it can represent
/// dynamic/system colors and platform-specific color spaces.
public struct FleetStoredColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    /// Creates a color after deterministically clamping channels to 0...1.
    /// Decoding is stricter: malformed persisted channels throw instead of
    /// silently rewriting user data.
    public init(red: Double, green: Double, blue: Double) {
        self.red = Self.clamped(red)
        self.green = Self.clamped(green)
        self.blue = Self.clamped(blue)
    }

    public init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }

    private init(uncheckedRed red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var isValid: Bool {
        Self.isValidChannel(red) && Self.isValidChannel(green) && Self.isValidChannel(blue)
    }

    public var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue)
    }

    public var hexString: String {
        let red = Int((red * 255).rounded())
        let green = Int((green * 255).rounded())
        let blue = Int((blue * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    public func blended(toward other: FleetStoredColor, amount: Double) -> FleetStoredColor {
        let t = min(max(amount, 0), 1)
        return FleetStoredColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t)
    }

    #if canImport(UIKit)
    /// Converts an opaque UIKit color into sRGB for persistence.
    public init?(uiColor: UIColor) {
        let resolved = uiColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        if let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
           let converted = resolved.cgColor.converted(to: sRGB, intent: .defaultIntent, options: nil),
           let components = converted.components,
           components.count >= 4 {
            guard let red = Self.normalized(component: components[0]),
                  let green = Self.normalized(component: components[1]),
                  let blue = Self.normalized(component: components[2]),
                  Self.isOpaque(converted.alpha) else { return nil }
            self.init(uncheckedRed: red, green: green, blue: blue)
            return
        }

        // `getRed`/`getWhite` is a compatibility fallback for UIKit colors
        // whose CGColor cannot be converted directly. The same finite,
        // bounded sRGB contract is applied before storage.
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            guard let red = Self.normalized(component: red),
                  let green = Self.normalized(component: green),
                  let blue = Self.normalized(component: blue),
                  Self.isOpaque(alpha) else { return nil }
            self.init(uncheckedRed: red, green: green, blue: blue)
            return
        }

        var white: CGFloat = 0
        guard resolved.getWhite(&white, alpha: &alpha),
              let white = Self.normalized(component: white),
              Self.isOpaque(alpha) else { return nil }
        self.init(uncheckedRed: white, green: white, blue: white)
    }

    public init?(color: Color) {
        self.init(uiColor: UIColor(color))
    }

    public var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: 1)
    }
    #elseif canImport(AppKit)
    public init?(nsColor: NSColor) {
        guard let converted = nsColor.usingColorSpace(.sRGB), converted.alphaComponent >= 0.999999 else {
            return nil
        }
        guard let red = Self.normalized(component: converted.redComponent),
              let green = Self.normalized(component: converted.greenComponent),
              let blue = Self.normalized(component: converted.blueComponent) else { return nil }
        self.init(uncheckedRed: red, green: green, blue: blue)
    }

    public init?(color: Color) {
        self.init(nsColor: NSColor(color))
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
    #endif

    private static func normalized(component: CGFloat) -> Double? {
        let value = Double(component)
        guard value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    #if canImport(UIKit)
    private static func isOpaque(_ alpha: CGFloat) -> Bool {
        let value = Double(alpha)
        return value.isFinite && value >= 0.999999 && value <= 1.000001
    }
    #endif

    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private static func isValidChannel(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    private enum CodingKeys: String, CodingKey {
        case red
        case green
        case blue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let red = try container.decode(Double.self, forKey: .red)
        let green = try container.decode(Double.self, forKey: .green)
        let blue = try container.decode(Double.self, forKey: .blue)
        guard Self.isValidChannel(red), Self.isValidChannel(green), Self.isValidChannel(blue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .red,
                in: container,
                debugDescription: "FleetStoredColor channels must be finite sRGB values in 0...1")
        }
        self.init(uncheckedRed: red, green: green, blue: blue)
    }
}

/// Controls whether a persisted palette resolves to Fleet's adaptive default
/// appearance variants or remains exactly the user's selected colors.
public enum FleetThemePaletteAppearance: String, Codable, Equatable, Sendable {
    case adaptiveFleetDefault
    case adaptiveCustomHighlight
    case fixed
}

/// Versioned persisted user palette. V1 intentionally stores exactly one
/// opaque sRGB value for each user-controlled token.
public struct FleetThemePalette: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var highlight: FleetStoredColor
    public var text: FleetStoredColor
    public var background: FleetStoredColor
    public var version: Int
    public var appearance: FleetThemePaletteAppearance

    public init(
        highlight: FleetStoredColor,
        text: FleetStoredColor,
        background: FleetStoredColor,
        version: Int = FleetThemePalette.currentVersion,
        appearance: FleetThemePaletteAppearance = .fixed
    ) {
        self.highlight = highlight
        self.text = text
        self.background = background
        self.version = version
        self.appearance = appearance
    }

    /// The persisted Fleet default is the light appearance representation.
    /// Its explicit resolution mode supplies the existing dark Fleet default,
    /// while a migrated/custom highlight has its own adaptive mode that keeps
    /// that highlight and only adopts Fleet's dark text/background tokens.
    public static let fleetDefault = FleetThemePalette(
        highlight: FleetStoredColor(hex: 0x5B35D5),
        text: FleetStoredColor(hex: 0x1C1C1E),
        background: FleetStoredColor(hex: 0xF8F9FC),
        appearance: .adaptiveFleetDefault)

    public static let fleetDefaultDark = FleetThemePalette(
        highlight: FleetStoredColor(hex: 0xBDA7FF),
        text: FleetStoredColor(hex: 0xF5F5F7),
        background: FleetStoredColor(hex: 0x101216),
        appearance: .fixed)

    #if DEBUG
    public static let lowContrastFixture = FleetThemePalette(
        highlight: FleetStoredColor(hex: 0x777777),
        text: FleetStoredColor(hex: 0x777777),
        background: FleetStoredColor(hex: 0x777777))

    public static let arbitraryFixture = FleetThemePalette(
        highlight: FleetStoredColor(red: 0.123, green: 0.456, blue: 0.789),
        text: FleetStoredColor(red: 0.901, green: 0.234, blue: 0.567),
        background: FleetStoredColor(red: 0.012, green: 0.345, blue: 0.678))
    #endif

    public var isCurrent: Bool {
        version == Self.currentVersion && highlight.isValid && text.isValid && background.isValid
    }

    public func palette(forDarkAppearance isDark: Bool) -> FleetThemePalette {
        guard isDark else { return self }
        switch appearance {
        case .adaptiveFleetDefault:
            return Self.fleetDefaultDark
        case .adaptiveCustomHighlight:
            let dark = Self.fleetDefaultDark
            return FleetThemePalette(
                highlight: highlight,
                text: dark.text,
                background: dark.background,
                version: version,
                appearance: .fixed)
        case .fixed:
            return self
        }
    }

    private enum CodingKeys: String, CodingKey {
        case highlight
        case text
        case background
        case version
        case appearance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        let highlight = try container.decode(FleetStoredColor.self, forKey: .highlight)
        let text = try container.decode(FleetStoredColor.self, forKey: .text)
        let background = try container.decode(FleetStoredColor.self, forKey: .background)
        guard version == Self.currentVersion,
              highlight.isValid,
              text.isValid,
              background.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "unsupported or invalid Fleet theme palette version")
        }
        // Older V1 payloads predate the explicit resolution mode. Preserve
        // their exact custom colors, while recognizing the old serialized
        // Fleet default so a relaunch does not lose its adaptive Dark variant.
        let appearance = try container.decodeIfPresent(
            FleetThemePaletteAppearance.self,
            forKey: .appearance)
            ?? (highlight == Self.fleetDefault.highlight
                && text == Self.fleetDefault.text
                && background == Self.fleetDefault.background
                ? .adaptiveFleetDefault
                : .fixed)
        self.init(
            highlight: highlight,
            text: text,
            background: background,
            version: version,
            appearance: appearance)
    }
}

/// Pure WCAG relative-luminance and deterministic Increase Contrast helpers.
public enum FleetThemeContrast {
    public static let normalTextMinimum = 4.5
    public static let highlightMinimum = 3.0
    public static let increasedContrastMinimum = 4.5

    public static func relativeLuminance(_ color: FleetStoredColor) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red)
            + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
    }

    public static func ratio(_ foreground: FleetStoredColor, _ background: FleetStoredColor) -> Double {
        let first = relativeLuminance(foreground)
        let second = relativeLuminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// Corrects a foreground only at render resolution. The nearest candidate
    /// that meets the requested ratio is selected while interpolating toward
    /// black or white to retain as much of the user's color as possible.
    public static func correctedForeground(
        _ foreground: FleetStoredColor,
        on background: FleetStoredColor,
        minimum: Double = increasedContrastMinimum
    ) -> FleetStoredColor {
        guard ratio(foreground, background) < minimum else { return foreground }

        let black = FleetStoredColor(red: 0, green: 0, blue: 0)
        let white = FleetStoredColor(red: 1, green: 1, blue: 1)
        var best: (color: FleetStoredColor, distance: Double)?

        for step in 1...100 {
            let amount = Double(step) / 100
            for candidate in [foreground.blended(toward: black, amount: amount),
                              foreground.blended(toward: white, amount: amount)] {
                guard ratio(candidate, background) >= minimum else { continue }
                let distance = squaredDistance(foreground, candidate)
                if best == nil || distance < best!.distance {
                    best = (candidate, distance)
                }
            }
            if best != nil { break }
        }

        guard let best else {
            let blackRatio = ratio(black, background)
            let whiteRatio = ratio(white, background)
            return blackRatio >= whiteRatio ? black : white
        }
        return best.color
    }

    private static func squaredDistance(_ lhs: FleetStoredColor, _ rhs: FleetStoredColor) -> Double {
        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        return red * red + green * green + blue * blue
    }
}

/// Contrast values shown by the editor. Values are calculated from the
/// resolved appearance palette, while Apply remains non-blocking.
public struct FleetThemeContrastReport: Equatable, Sendable {
    public let textToBackground: Double
    public let highlightToBackground: Double
    public let highlightControlText: Double

    public init(palette: FleetThemePalette, isDark: Bool) {
        let resolved = palette.palette(forDarkAppearance: isDark)
        self.textToBackground = FleetThemeContrast.ratio(resolved.text, resolved.background)
        self.highlightToBackground = FleetThemeContrast.ratio(resolved.highlight, resolved.background)
        let controlText = FleetThemeContrast.relativeLuminance(resolved.highlight) > 0.5
            ? FleetStoredColor(red: 0.05, green: 0.05, blue: 0.06)
            : FleetStoredColor(red: 1, green: 1, blue: 1)
        self.highlightControlText = FleetThemeContrast.ratio(controlText, resolved.highlight)
    }

    public var hasWarning: Bool {
        textToBackground < FleetThemeContrast.normalTextMinimum
            || highlightToBackground < FleetThemeContrast.highlightMinimum
            || highlightControlText < FleetThemeContrast.normalTextMinimum
    }
}

/// Resolved app-wide presentation tokens. The raw `FleetThemePalette` remains
/// available for persistence and preview; derived values never become a second
/// persisted color schema.
public struct FleetThemeValues: Sendable {
    public let palette: FleetThemePalette
    public let isDarkAppearance: Bool
    public let isIncreasedContrast: Bool

    private let resolvedHighlight: FleetStoredColor
    private let resolvedText: FleetStoredColor
    private let resolvedBackground: FleetStoredColor
    private let resolvedSecondaryText: FleetStoredColor
    private let resolvedMutedText: FleetStoredColor
    private let resolvedSurface: FleetStoredColor
    private let resolvedSurfaceElevated: FleetStoredColor
    private let resolvedBorder: FleetStoredColor

    public init(palette: FleetThemePalette, isDarkAppearance: Bool, isIncreasedContrast: Bool) {
        self.palette = palette
        self.isDarkAppearance = isDarkAppearance
        self.isIncreasedContrast = isIncreasedContrast

        let base = palette.palette(forDarkAppearance: isDarkAppearance)
        let background = base.background
        let text = isIncreasedContrast
            ? FleetThemeContrast.correctedForeground(
                base.text,
                on: background,
                minimum: FleetThemeContrast.increasedContrastMinimum)
            : base.text
        let highlight = isIncreasedContrast
            ? FleetThemeContrast.correctedForeground(
                base.highlight,
                on: background,
                minimum: FleetThemeContrast.increasedContrastMinimum)
            : base.highlight

        self.resolvedHighlight = highlight
        self.resolvedText = text
        self.resolvedBackground = background

        let secondary = text.blended(toward: background, amount: isIncreasedContrast ? 0.28 : 0.46)
        self.resolvedSecondaryText = FleetThemeValues.readableDerivedText(
            secondary,
            source: text,
            on: background,
            minimum: isIncreasedContrast ? 4.5 : 3.0)
        let muted = text.blended(toward: background, amount: isIncreasedContrast ? 0.48 : 0.68)
        self.resolvedMutedText = FleetThemeValues.readableDerivedText(
            muted,
            source: text,
            on: background,
            minimum: isIncreasedContrast ? 4.5 : 2.0)

        let surfaceTarget = isDarkAppearance
            ? FleetStoredColor(red: 1, green: 1, blue: 1)
            : FleetStoredColor(red: 1, green: 1, blue: 1)
        let surfaceAmount = isIncreasedContrast ? 0.28 : (isDarkAppearance ? 0.12 : 0.42)
        let surface = background.blended(toward: surfaceTarget, amount: surfaceAmount)
        self.resolvedSurface = surface
        self.resolvedSurfaceElevated = background.blended(toward: surface, amount: 0.5)
        self.resolvedBorder = text.blended(toward: background, amount: isIncreasedContrast ? 0.35 : 0.58)
    }

    public static let `default` = FleetThemeValues(
        palette: .fleetDefault,
        isDarkAppearance: false,
        isIncreasedContrast: false)

    public var highlight: Color { resolvedHighlight.swiftUIColor }
    public var textPrimary: Color { resolvedText.swiftUIColor }
    public var textSecondary: Color { resolvedSecondaryText.swiftUIColor }
    public var textMuted: Color { resolvedMutedText.swiftUIColor }
    public var background: Color { resolvedBackground.swiftUIColor }
    public var surface: Color { resolvedSurface.swiftUIColor }
    public var surfaceElevated: Color { resolvedSurfaceElevated.swiftUIColor }
    public var surfaceIncreased: Color { isIncreasedContrast ? resolvedBackground.swiftUIColor : surface }
    public var border: Color { resolvedBorder.swiftUIColor }

    /// Render-time correction result. This is diagnostic/presentation state;
    /// the controller persists only `palette` and never this derived value.
    public var resolvedPalette: FleetThemePalette {
        FleetThemePalette(
            highlight: resolvedHighlight,
            text: resolvedText,
            background: resolvedBackground,
            version: palette.version)
    }

    public func borderColor() -> Color { border }

    /// Semantic operational colors intentionally do not use user palette
    /// channels. Waiting/offline/unknown stay neutral and keep their glyph and
    /// labels; status meaning remains stable under arbitrary themes.
    public func semanticStatusColor(for status: FleetStatus) -> Color {
        switch status {
        case .online: FleetTheme.statusOnline
        case .executing: FleetTheme.statusExecuting
        case .waiting: FleetTheme.statusNeutral
        case .needsYou, .authRequired: FleetTheme.statusNeedsIntervention
        case .degraded: FleetTheme.statusDegraded
        case .offline, .unknown: FleetTheme.statusNeutral
        }
    }

    private static func readableDerivedText(
        _ candidate: FleetStoredColor,
        source: FleetStoredColor,
        on background: FleetStoredColor,
        minimum: Double
    ) -> FleetStoredColor {
        FleetThemeContrast.ratio(candidate, background) >= minimum
            ? candidate
            : FleetThemeContrast.correctedForeground(source, on: background, minimum: minimum)
    }
}

private struct FleetThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = FleetThemeValues.default
}

public extension EnvironmentValues {
    var fleetTheme: FleetThemeValues {
        get { self[FleetThemeEnvironmentKey.self] }
        set { self[FleetThemeEnvironmentKey.self] = newValue }
    }
}

/// Root bridge from persisted theme state and platform accessibility traits to
/// the SwiftUI environment. Descendant views observe one value seam; no view
/// reads the persistence controller or singleton directly.
public struct FleetThemeRoot<Content: View>: View {
    private let controller: FleetThemeController
    private let content: Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    public init(
        controller: FleetThemeController,
        @ViewBuilder content: () -> Content
    ) {
        self.controller = controller
        self.content = content()
    }

    public var body: some View {
        let theme = controller.resolvedTheme(
            isDarkAppearance: colorScheme == .dark,
            isIncreasedContrast: colorSchemeContrast == .increased)
        content
            .environment(\.fleetTheme, theme)
            .tint(theme.highlight)
    }
}

/// UserDefaults-backed controller for the applied palette. Draft edits stay in
/// the editor until `apply(_:)` is called. Invalid persisted data falls back
/// in memory and is not overwritten until the user explicitly saves.
@Observable
public final class FleetThemeController: @unchecked Sendable {
    public static let persistKey = "fleet.settings.theme.palette.v1"
    public static let shared = FleetThemeController()

    private let defaults: UserDefaults
    public private(set) var activePalette: FleetThemePalette

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.activePalette = Self.load(from: defaults)
    }

    public var defaultPalette: FleetThemePalette { .fleetDefault }

    @discardableResult
    public func apply(_ palette: FleetThemePalette) -> Bool {
        guard palette.isCurrent,
              let data = try? JSONEncoder().encode(palette) else { return false }
        defaults.set(data, forKey: Self.persistKey)
        activePalette = palette
        return true
    }

    public func reset() {
        apply(.fleetDefault)
    }

    public func resolvedTheme(isDarkAppearance: Bool, isIncreasedContrast: Bool) -> FleetThemeValues {
        FleetThemeValues(
            palette: activePalette,
            isDarkAppearance: isDarkAppearance,
            isIncreasedContrast: isIncreasedContrast)
    }

    private static func load(from defaults: UserDefaults) -> FleetThemePalette {
        // A present V1 key has precedence over the retired accent key even
        // when its value is malformed. This keeps corrupt state fail-safe and
        // prevents stale legacy preferences from being resurrected.
        if defaults.object(forKey: persistKey) != nil {
            guard let data = defaults.data(forKey: persistKey),
                  let decoded = try? JSONDecoder().decode(FleetThemePalette.self, from: data),
                  decoded.isCurrent else {
                return .fleetDefault
            }
            return decoded
        }

        // Migration is intentionally in-memory. The retired key remains
        // untouched, and the new schema is written only by explicit Apply or
        // Reset, so corrupt/recoverable legacy state is never destroyed.
        guard let raw = defaults.string(forKey: FleetAccentController.persistKey),
              let legacy = FleetAccent(rawValue: raw) else {
            return .fleetDefault
        }
        return FleetThemePalette(
            highlight: legacy.legacyHighlight,
            text: FleetThemePalette.fleetDefault.text,
            background: FleetThemePalette.fleetDefault.background,
            appearance: .adaptiveCustomHighlight)
    }
}
