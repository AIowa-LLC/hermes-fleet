import Foundation

/// FOS-2 (spec §8 scope selection rule) — the explicit profile selection
/// policy for profile-owned resource panes (Schedules / Skills / Memory /
/// Projects) entered beneath a Gateway Detail.
///
/// Rules (card + SPEC §8):
/// - Entry from Bot Detail carries that Route's profile — never re-picked.
/// - Entry from Gateway Detail: a previous EXPLICIT selection that is still
///   valid is reused; a single valid profile may preselect, but visibly
///   labeled; multiple profiles with no prior choice REQUIRE explicit
///   selection; missing profiles never fall back to `default` or `first`.
/// - A stored selection that no longer exists invalidates silently at the
///   policy layer (the view must show "choose a profile", never substitute).
public struct GatewayProfileSelectionPolicy: Sendable, Equatable {

    public init() {}

    /// One selectable profile candidate: the profile slug plus the bot
    /// display name for readable picker rows.
    public struct Candidate: Sendable, Equatable, Identifiable {
        public let profileSlug: ProfileSlug
        public let botName: String
        public var id: String { profileSlug.rawValue }
        public init(profileSlug: ProfileSlug, botName: String) {
            self.profileSlug = profileSlug
            self.botName = botName
        }
    }

    /// Resolution outcome for a pane entry.
    public enum Resolution: Sendable, Equatable {
        /// A previously stored explicit selection is still valid — reuse it.
        case reuseStored(ProfileSlug)
        /// Exactly one valid candidate exists — auto-select, but the UI must
        /// keep the selection VISIBLE (labeled), not silent.
        case singleCandidate(ProfileSlug)
        /// Multiple candidates and no valid stored choice — require explicit
        /// selection; no fallback.
        case selectionRequired(candidates: [ProfileSlug])
        /// No valid candidates (roster not loaded / empty) — nothing to
        /// select; the pane must not guess.
        case unavailable
    }

    /// Resolve the entry selection for one gateway's pane.
    ///
    /// - Parameters:
    ///   - candidates: routing-safe roster profiles for the gateway (may be
    ///     empty when the roster has not loaded).
    ///   - storedSelection: the last explicitly chosen profile for this
    ///     gateway+pane (persisted), if any.
    public func resolve(
        candidates: [Candidate],
        storedSelection: ProfileSlug?
    ) -> Resolution {
        // Dedupe by slug — multiple Bots on one profile is one candidate.
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.profileSlug.rawValue).inserted }
        guard !unique.isEmpty else { return .unavailable }
        if let stored = storedSelection,
           unique.contains(where: { $0.profileSlug == stored }) {
            return .reuseStored(stored)
        }
        if unique.count == 1, let only = unique.first {
            return .singleCandidate(only.profileSlug)
        }
        return .selectionRequired(candidates: unique.map(\.profileSlug))
    }
}
