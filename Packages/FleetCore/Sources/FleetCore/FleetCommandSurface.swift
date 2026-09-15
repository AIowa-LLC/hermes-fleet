import Foundation

// MARK: - Fleet routing value

/// How a Hermes command is fulfilled on iPhone. Hermes answers existence;
/// this router answers only fulfillment. Conceptually the iOS equivalent of
/// Desktop's `DesktopCommandSurface` (action / picker / rpc / exec /
/// unavailable), authored from the upstream `desktop=` dispositions — never
/// a clone of Desktop's TypeScript registry.
public enum FleetCommandSurface: Equatable, Sendable {
    /// Fulfilled by an existing Fleet-native control path (session creation,
    /// steer seam, rename seam, branch seam, interrupt, model picker, …).
    case action(FleetCommandAction)
    /// Fulfilled by opening a Fleet-native picker surface.
    case picker(FleetCommandPicker)
    /// Fulfilled by a dedicated typed gateway RPC through an existing
    /// FleetCore seam (e.g. `/status` → `session.status` via the history
    /// seam).
    case rpc(FleetCommandRPC)
    /// Fulfilled by canonical backend execution (`slash.exec` with
    /// `command.dispatch` fallback) interpreted by the shared dispatch
    /// interpreter.
    case exec
    /// A known Hermes registry command with genuinely no iPhone surface.
    /// Shows the reason; never executes and never falls through to chat.
    case unavailable(FleetCommandUnavailableReason)
}

/// Fleet-native command actions, each mapped to an existing Fleet control
/// path — never a new parallel implementation of an RPC.
public enum FleetCommandAction: String, Equatable, Sendable, CaseIterable {
    case new
    case steer
    case stop
    case title
    case branch
    case help
}

/// Fleet-native picker surfaces invoked by a command.
public enum FleetCommandPicker: String, Equatable, Sendable, CaseIterable {
    case model
    case sessions
}

/// Dedicated typed RPCs reachable through existing FleetCore seams.
public enum FleetCommandRPC: String, Equatable, Sendable, CaseIterable {
    case status
}

/// Why a known Hermes command has no iPhone surface.
public enum FleetCommandUnavailableReason: String, Equatable, Sendable, CaseIterable {
    case terminal
    case messaging
    case settings
    case advanced
    case composerVoice = "composer-voice"
    /// The upstream catalog marked the command `hidden` AND Fleet has no
    /// native surface for it: executable when explicitly appropriate per
    /// policy, but omitted from normal discovery.
    case hidden

    /// Human-facing copy suffix, mirroring Desktop's honest-unavailability
    /// pattern. Callers prefix the canonical `/name`.
    public var message: String {
        switch self {
        case .terminal:
            return "is available from the Hermes terminal, not Fleet."
        case .messaging:
            return "is only used from messaging platforms."
        case .settings:
            return "is managed from Fleet Settings."
        case .advanced:
            return "is an advanced command not shown in Fleet."
        case .composerVoice:
            return "is handled by Fleet's composer voice controls."
        case .hidden:
            return "is hidden from the Fleet command list."
        }
    }

    /// Init from the raw upstream `desktop` disposition string.
    public init?(disposition: String) {
        switch disposition.lowercased() {
        case "terminal": self = .terminal
        case "messaging": self = .messaging
        case "settings": self = .settings
        case "advanced": self = .advanced
        case "composer-voice": self = .composerVoice
        case "hidden": self = .hidden
        default: return nil
        }
    }
}

// MARK: - Router

/// The single Fleet-side routing authority: which Hermes commands have a
/// native iOS fulfillment. Everything not listed routes by upstream `desktop`
/// disposition, then defaults to backend `exec`. Deliberately small — it
/// defines iOS FULFILLMENT only, never command existence (the live
/// `commands.catalog` owns existence, so new skills, quick commands, and
/// plugin commands work without a Fleet release).
public enum FleetCommandRouter {
    /// Canonical name (lowercased, no slash) → native surface. Aliases are
    /// NOT listed here; they resolve through the catalog's `canon` map into
    /// these canonical names first.
    private static let native: [String: FleetCommandSurface] = [
        "new": .action(.new),
        "steer": .action(.steer),
        "stop": .action(.stop),
        "title": .action(.title),
        "branch": .action(.branch),
        "help": .action(.help),
        "model": .picker(.model),
        "resume": .picker(.sessions),
        "sessions": .picker(.sessions),
        "switch": .picker(.sessions),
        "status": .rpc(.status),
    ]

    /// The fulfillment rule:
    /// 1. Known Fleet-native command → Fleet native route
    /// 2. Known upstream unavailable disposition → unavailable
    /// 3. Everything else surfaced by Hermes → backend execution
    ///
    /// `hidden` upstream means executable-but-omitted-from-discovery; Fleet
    /// follows the same policy (still routes to exec/backend so a manually
    /// typed hidden command Hermes owns behaves per Hermes semantics).
    public static func surface(for canonicalName: String, desktopDisposition: String?) -> FleetCommandSurface {
        let key = canonicalName.lowercased()
        if let nativeSurface = native[key] {
            return nativeSurface
        }
        if let disposition = desktopDisposition,
           let reason = FleetCommandUnavailableReason(disposition: disposition) {
            if reason == .hidden {
                return .exec
            }
            return .unavailable(reason)
        }
        return .exec
    }

    /// Whether a catalog/completion row may be SUGGESTED in the palette.
    /// Aliases never appear (duplicate clutter); genuinely unavailable
    /// commands never appear. Hidden native/picker commands (e.g. `/model`)
    /// DO appear — Fleet has a first-class surface for them.
    public static func isSuggestible(_ row: SlashCommandSuggestion, canon: [String: String]) -> Bool {
        let key = row.text.lowercased()
        if let canonical = canon[key], canonical.lowercased() != key {
            return false  // alias of another canonical — never suggested
        }
        switch surface(for: key, desktopDisposition: row.desktopDisposition) {
        case .unavailable:
            return false
        case .action, .picker, .rpc, .exec:
            return true
        }
    }

    /// Whether a typed token may EXECUTE on Fleet. False only for genuinely
    /// unavailable surfaces (terminal-only etc.).
    public static func isExecutable(canonicalName: String, desktopDisposition: String?) -> Bool {
        if case .unavailable = surface(for: canonicalName, desktopDisposition: desktopDisposition) {
            return false
        }
        return true
    }
}

// MARK: - Classification

/// The router's answer for one typed token: canonical identity plus the
/// Fleet fulfillment surface.
public struct FleetCommandClassification: Equatable, Sendable {
    /// Lowercased canonical name without the leading slash (e.g. "new").
    public let canonicalName: String
    public let surface: FleetCommandSurface
    /// True when the typed token differs from its canonical form.
    public let isAlias: Bool

    public init(canonicalName: String, surface: FleetCommandSurface, isAlias: Bool) {
        self.canonicalName = canonicalName
        self.surface = surface
        self.isAlias = isAlias
    }
}
