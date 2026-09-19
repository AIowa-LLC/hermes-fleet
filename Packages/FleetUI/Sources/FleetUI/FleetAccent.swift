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
        }
    }

    /// The palette this accent applies: its highlight over the Fleet-default
    /// text/background, adaptive — the existing contrast/ink pipeline and the
    /// FleetThemeController apply-guard keep working unchanged.
    public var palette: FleetThemePalette {
        FleetThemePalette(
            highlight: highlight,
            text: FleetThemePalette.fleetDefault.text,
            background: FleetThemePalette.fleetDefault.background,
            appearance: .adaptiveCustomHighlight)
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
