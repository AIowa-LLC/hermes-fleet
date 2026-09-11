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
    case blue
    case gold
    case amber
    case indigo
    case green

    public var id: String { rawValue }

    public static let `default`: FleetAccent = .blue
}

/// One-way migration input for the retired V7.5 preference. These colors are
/// not a new persistence contract; they are used only when an install has an
/// old accent and no V1 palette yet.
extension FleetAccent {
    var legacyHighlight: FleetStoredColor {
        switch self {
        case .blue: FleetStoredColor(hex: 0x0A84FF)
        case .gold: FleetStoredColor(hex: 0xD9A441)
        case .amber: FleetStoredColor(hex: 0xD97706)
        case .indigo: FleetStoredColor(hex: 0x4F46E5)
        case .green: FleetStoredColor(hex: 0x16A34A)
        }
    }
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
