import Foundation

/// Refinement Phase 3 — the curated theme set offered by Settings ▸ Theme.
///
/// A curated theme is a highlight defined PER APPEARANCE over the
/// Fleet-default canvases. The canvases (and therefore every §14 status
/// token ratio) are untouched, so each theme only has to prove its own
/// highlight: `scripts/fos7_contrast_gate.py` checks every entry below in
/// both appearances (highlight on canvas, grouped surface and derived dark
/// surface; ink on a highlight fill), and `RefinementPhase3Tests` pins the
/// script and this table to the same values. A theme that cannot pass does
/// not ship.
///
/// Green, amber, red and cyan families are deliberately absent: those hues
/// carry status meaning (online, attention/degraded, destructive,
/// executing) and an interface tint in them would read as status.
public enum FleetCuratedTheme: String, CaseIterable, Identifiable, Sendable {
    /// The Fleet default: violet in light, white in dark (B41).
    case fleet
    /// The §14 violet in both appearances (#BDA7FF is the spec's dark
    /// interactive token).
    case violet
    case ocean
    case orchid
    /// Mono: near-black in light, white in dark (ADR-0009 resolution).
    case graphite

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fleet: "Fleet"
        case .violet: "Violet"
        case .ocean: "Ocean"
        case .orchid: "Orchid"
        case .graphite: "Graphite"
        }
    }

    public var lightHighlight: FleetStoredColor {
        switch self {
        case .fleet, .violet: FleetStoredColor(hex: 0x5B35D5)
        case .ocean: FleetStoredColor(hex: 0x1A5FC4)
        case .orchid: FleetStoredColor(hex: 0x9C2A8F)
        case .graphite: FleetStoredColor(hex: 0x1C1C1E)
        }
    }

    public var darkHighlight: FleetStoredColor {
        switch self {
        case .fleet, .graphite: FleetStoredColor(hex: 0xFFFFFF)
        case .violet: FleetStoredColor(hex: 0xBDA7FF)
        case .ocean: FleetStoredColor(hex: 0x8CBBFF)
        case .orchid: FleetStoredColor(hex: 0xF0A6E4)
        }
    }

    /// The persisted palette this theme applies. Fleet and Graphite reuse
    /// their existing resolution modes, so an install that already holds the
    /// default (or the legacy White accent) reads as that theme with no
    /// migration. The rest store the light highlight and resolve their dark
    /// highlight through `curatedDarkHighlight(forLight:)`.
    public var palette: FleetThemePalette {
        switch self {
        case .fleet:
            return .fleetDefault
        case .graphite:
            return FleetThemePalette(
                highlight: lightHighlight,
                text: FleetThemePalette.fleetDefault.text,
                background: FleetThemePalette.fleetDefault.background,
                appearance: .adaptiveMono)
        case .violet, .ocean, .orchid:
            return FleetThemePalette(
                highlight: lightHighlight,
                text: FleetThemePalette.fleetDefault.text,
                background: FleetThemePalette.fleetDefault.background,
                appearance: .adaptiveCurated)
        }
    }

    /// The curated theme the active palette IS (exact match, including its
    /// resolution mode); nil means a custom or legacy palette, which is
    /// preserved verbatim and shown as "Custom".
    public static func matching(active: FleetThemePalette) -> FleetCuratedTheme? {
        allCases.first { candidate in
            let palette = candidate.palette
            return palette.highlight == active.highlight
                && palette.text == active.text
                && palette.background == active.background
                && palette.appearance == active.appearance
        }
    }

    /// Dark highlight for an `.adaptiveCurated` palette, keyed by its stored
    /// light highlight. nil for an unknown value (the palette then keeps its
    /// stored highlight in dark, like `.adaptiveCustomHighlight`).
    static func curatedDarkHighlight(forLight light: FleetStoredColor) -> FleetStoredColor? {
        allCases.first { $0.palette.appearance == .adaptiveCurated && $0.lightHighlight == light }?
            .darkHighlight
    }
}
