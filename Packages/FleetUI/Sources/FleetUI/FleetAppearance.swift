import SwiftUI

/// FOS-3 (SPEC §12 Appearance) — the System / Light / Dark app appearance
/// preference. Default is System. A small LOCAL preference, deliberately
/// UserDefaults-backed (non-secret, same posture as the App Lock toggle);
/// `FleetAppearanceController.shared` is observed at the app root so the
/// override applies app-wide (tab shell, sheets, lock overlay).
public enum FleetAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    /// The `ColorScheme?` applied via `.preferredColorScheme` at the root.
    /// `nil` (System) defers to the device setting.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Holds the persisted appearance preference; `@Observable` so the app root
/// re-applies the override the moment Settings changes it.
/// Not MainActor-isolated: read from nonisolated contexts under Swift 6.
/// `@unchecked Sendable` is sound for the same reasons as
/// `FleetAccentController`: thread-safe UserDefaults + value selection.
@Observable
public final class FleetAppearanceController: @unchecked Sendable {
    public static let persistKey = "fleet.settings.appearance"

    public static let shared = FleetAppearanceController()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selection = FleetAppearance(rawValue: defaults.string(forKey: Self.persistKey) ?? "") ?? .system
    }

    public var selection: FleetAppearance {
        didSet { defaults.set(selection.rawValue, forKey: Self.persistKey) }
    }
}
