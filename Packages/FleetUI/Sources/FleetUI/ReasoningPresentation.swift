import Foundation

/// The user's default presentation for newly-created reasoning disclosures.
/// Existing disclosures keep an explicit user override for their lifetime.
public enum ReasoningPresentationPreference: String, CaseIterable, Identifiable, Sendable {
    case collapsed
    case expanded

    public static let storageKey = "fleet.settings.reasoning-presentation.v1"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .collapsed: "Collapsed by default"
        case .expanded: "Expanded by default"
        }
    }

    public static func current(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .collapsed
    }
}

/// Per-disclosure state. A manual toggle is deliberately distinct from the
/// preference so streaming updates and preference changes cannot fight the
/// user's explicit choice.
public struct ReasoningExpansionState: Equatable, Sendable {
    public private(set) var isExpanded: Bool
    public private(set) var hasUserOverride: Bool

    public init(default preference: ReasoningPresentationPreference = .collapsed) {
        self.isExpanded = preference == .expanded
        self.hasUserOverride = false
    }

    public mutating func toggle() {
        isExpanded.toggle()
        hasUserOverride = true
    }

    /// Streaming lifecycle hook: live reasoning is the reply being written,
    /// so streaming forces visibility on without marking a user override.
    /// When the stream ends, `applyDefault` respects any manual override
    /// made while it was live.
    public mutating func expandForStreaming() {
        isExpanded = true
    }

    public mutating func applyDefault(_ preference: ReasoningPresentationPreference) {
        guard !hasUserOverride else { return }
        isExpanded = preference == .expanded
    }
}
