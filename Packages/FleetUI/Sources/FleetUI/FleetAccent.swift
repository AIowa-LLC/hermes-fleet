import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The ONE accent — now user-choosable (V7.5). Vetted catalog only: no
/// free-text hex (same posture as Hermes Desktop's curated theme/font lists).
/// Teal is permanently banned (brand rule: teal is never Hermes).
public enum FleetAccent: String, CaseIterable, Identifiable, Sendable {
    /// System blue — the safe HIG-native default (sentinel "system default").
    case blue
    /// Warm gold — the ONLY strict-AA text-contrast passer in both modes
    /// (D5 contrast audit 2026-09-04: 5.33 light / 8.84 dark).
    case gold
    /// Bob amber — BobTheme's actual pair.
    case amber
    /// System indigo.
    case indigo
    /// System green.
    case green

    public var id: String { rawValue }

    public static let `default`: FleetAccent = .blue

    /// Adaptive color for this accent (dark/light pairs; mirrors the
    /// FleetTheme.adaptive(dark:light:) pattern for semantic status).
    public var color: Color {
        switch self {
        case .blue:   return Color(uiColor: .systemBlue)
        case .gold:   return FleetAccent.adaptive(dark: 0xD4A017, light: 0x8A6500)
        case .amber:  return FleetAccent.adaptive(dark: 0xF5A623, light: 0xC77D0A)
        case .indigo: return Color(uiColor: .systemIndigo)
        case .green:  return Color(uiColor: .systemGreen)
        }
    }

    /// Human label shown in the picker (matches D5's Telegram swatch names).
    public var label: String {
        switch self {
        case .blue:   return "Hermes Blue (System)"
        case .gold:   return "Warm Gold"
        case .amber:  return "Amber"
        case .indigo: return "Indigo"
        case .green:  return "Green"
        }
    }

    #if canImport(UIKit)
    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
    #endif
}

/// Holds the user's accent pick; @Observable so SwiftUI re-renders on change.
/// Persistence: UserDefaults (non-secret preference — same posture as
/// AppLockController's toggle; deliberately NOT Keychain).
/// Not MainActor-isolated: the static FleetTheme.accent seam reads it from
/// nonisolated contexts (Swift 6). All UI writes happen on the main thread.
/// @unchecked Sendable is sound: stored state is a thread-safe UserDefaults
/// plus a value-type selection; Observation's registrar is internally synced.
@Observable
public final class FleetAccentController: @unchecked Sendable {
    public static let persistKey = "fleet.settings.accent"

    /// Process-wide singleton used by the static FleetTheme.accent seam.
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
