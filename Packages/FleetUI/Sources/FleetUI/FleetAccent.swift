import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// FOS-7 (SPEC §14) — accent selection RETIRED. Fleet uses one fixed
/// interface accent (the Fleet violet in `FleetTheme.accent`).
///
/// This type is preserved ONLY as a stored-value holder for rollback: the
/// persisted `fleet.settings.accent` UserDefaults pick is migration-unsafe
/// to delete, so the controller continues to round-trip it untouched. The
/// value NO LONGER APPLIES anywhere in the interface — `FleetTheme.accent`
/// does not read it, Settings no longer renders a picker, and the app root
/// no longer applies it as tint. Do not add new call sites.
public enum FleetAccent: String, CaseIterable, Identifiable, Sendable {
    /// ChatGPT-style accent set (dogfood: replaces the full theme editor).
    case blue
    case green
    case yellow
    case pink
    case orange
    case purple
    case black
    /// ADR-0009 mono accent: near-black in light mode, white in dark mode.
    case white

    public var id: String { rawValue }

    public static let `default`: FleetAccent = .blue
}

/// One-way migration input for the retired V7.5 preference. These colors are
/// not a new persistence contract; they are used only when an install has an
/// old accent and no V1 palette yet.
extension FleetAccent {
    /// The accent's highlight color (Apple-system-toned, ChatGPT's set).
    public var highlight: FleetStoredColor {
        switch self {
        case .blue: FleetStoredColor(hex: 0x0A84FF)
        case .green: FleetStoredColor(hex: 0x30B94D)
        case .yellow: FleetStoredColor(hex: 0xE2B203)
        case .pink: FleetStoredColor(hex: 0xFF2D8A)
        case .orange: FleetStoredColor(hex: 0xFF8A00)
        case .purple: FleetStoredColor(hex: 0x8B5CF6)
        case .black: FleetStoredColor(hex: 0x2C2C2E)
        case .white: FleetStoredColor(hex: 0x1C1C1E)
        }
    }

    /// Display name (the picker row label).
    public var label: String {
        switch self {
        case .blue: "Blue"
        case .green: "Green"
        case .yellow: "Yellow"
        case .pink: "Pink"
        case .orange: "Orange"
        case .purple: "Purple"
        case .black: "Black"
        case .white: "White"
        }
    }

    /// The palette this accent applies: its highlight over the Fleet-default
    /// text/background, adaptive — the existing contrast/ink pipeline and the
    /// FleetThemeController apply-guard keep working unchanged.
    ///
    /// MONO accents (ADR-0009, extended to Black): their highlight resolves
    /// per appearance. White stores near-black and resolves white in dark;
    /// Black stores #2C2C2E — a near-black highlight is as invisible on the
    /// #101216 dark canvas (1.35:1) as white is on the light canvas, and the
    /// invisible-pair guard passes it, so Black must take the same inverse
    /// (white-in-dark) resolution. Tint, unread dots, and the unread badge
    /// stay legible in both appearances for both.
    public var palette: FleetThemePalette {
        FleetThemePalette(
            highlight: highlight,
            text: FleetThemePalette.fleetDefault.text,
            background: FleetThemePalette.fleetDefault.background,
            appearance: isMono ? .adaptiveMono : .adaptiveCustomHighlight)
    }

    /// The accents whose highlight is defined per appearance (ADR-0009).
    var isMono: Bool {
        self == .white || self == .black
    }

    /// The accent whose palette matches (for showing the current pick when a
    /// legacy custom palette is active); nil -> "Custom".
    public static func matching(active: FleetThemePalette) -> FleetAccent? {
        allCases.first { $0.palette.highlight == active.highlight
            && $0.palette.text == active.text
            && $0.palette.background == active.background }
    }

    var legacyHighlight: FleetStoredColor { highlight }
}

/// Persistence-only companion for the retired accent pick (see
/// `FleetAccent`). Reads and writes keep the stored rollback value alive;
/// nothing in the rendered interface consumes the selection.
@Observable
public final class FleetAccentController: @unchecked Sendable {
    public static let persistKey = "fleet.settings.accent"

    public static let shared = FleetAccentController()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selection = FleetAccent(rawValue: defaults.string(forKey: Self.persistKey) ?? "") ?? .default
    }

    public var selection: FleetAccent {
        didSet { defaults.set(selection.rawValue, forKey: Self.persistKey) }
    }
}
