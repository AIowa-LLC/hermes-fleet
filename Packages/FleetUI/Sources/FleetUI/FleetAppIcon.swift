import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Refinement Phase 3 — alternate app icons (Settings ▸ Theme ▸ App Icon).
///
/// The primary icon is the Icon Composer `FleetWing.icon`; the alternates
/// are the wing-v4 variants registered as `ASSETCATALOG_COMPILER_ALTERNATE_
/// APPICON_NAMES` in project.yml. iOS cannot load an app icon as a UIImage by
/// name, so each choice also has a small `…Preview` image in the app's asset
/// catalog for the Settings row.
public enum FleetAppIcon: String, CaseIterable, Identifiable, Sendable {
    case standard
    case midnight
    case violet
    case graphite
    case silver

    public var id: String { rawValue }

    /// The `setAlternateIconName` value; nil selects the primary icon.
    public var alternateIconName: String? {
        switch self {
        case .standard: nil
        case .midnight: "AppIconMidnight"
        case .violet: "AppIconViolet"
        case .graphite: "AppIconGraphite"
        case .silver: "AppIconSilver"
        }
    }

    public var label: String {
        switch self {
        case .standard: "Fleet"
        case .midnight: "Midnight"
        case .violet: "Violet"
        case .graphite: "Graphite"
        case .silver: "Silver"
        }
    }

    /// Main-bundle preview image (180 pt source).
    public var previewImageName: String {
        switch self {
        case .standard: "AppIconDefaultPreview"
        default: "\(alternateIconName ?? "AppIconDefault")Preview"
        }
    }

    /// The choice for the system's current alternate name; an unknown name
    /// (a retired icon) reads as the primary.
    public static func matching(alternateIconName name: String?) -> FleetAppIcon {
        allCases.first { $0.alternateIconName == name } ?? .standard
    }
}

/// Reads and applies the alternate icon. The system call is injected so the
/// selection logic is testable without UIApplication.
@MainActor
@Observable
public final class FleetAppIconController {
    public private(set) var current: FleetAppIcon
    public let supportsAlternateIcons: Bool
    private let apply: @MainActor (String?) async throws -> Void

    public init(
        currentAlternateName: String?,
        supportsAlternateIcons: Bool,
        apply: @escaping @MainActor (String?) async throws -> Void
    ) {
        self.current = FleetAppIcon.matching(alternateIconName: currentAlternateName)
        self.supportsAlternateIcons = supportsAlternateIcons
        self.apply = apply
    }

    #if canImport(UIKit)
    public static let shared = FleetAppIconController(
        currentAlternateName: UIApplication.shared.alternateIconName,
        supportsAlternateIcons: UIApplication.shared.supportsAlternateIcons,
        apply: { name in try await UIApplication.shared.setAlternateIconName(name) })
    #endif

    /// Applies `icon`; `current` changes only after the system accepts it.
    @discardableResult
    public func select(_ icon: FleetAppIcon) async -> Bool {
        guard supportsAlternateIcons, icon != current else { return false }
        do {
            try await apply(icon.alternateIconName)
            current = icon
            return true
        } catch {
            return false
        }
    }
}
