import Foundation

/// Seam for canonical Bot Chat operations — the FleetUI-facing contract.
///
/// FleetUI depends on this protocol only; the concrete
/// `GatewayBotModeClient` (FleetNetworking) conforms app-side in the
/// composition root, and the DEBUG simulator provides a scripted double.
/// This mirrors the `RosterProviding` / `SessionListProviding` pattern.
public protocol BotModeChatProviding: Sendable {
    /// Title-exact hidden lookup of the canonical "Bot Chat" session for a
    /// profile on the owning gateway. See `CanonicalChatResolver` for the
    /// fail-closed interpretation of the result.
    func lookupCanonicalChat(profile: String) async throws -> CanonicalLookup

    /// Safe canonical creation (confirmed-miss path only): hidden session +
    /// eager exact title. Returns the session id to open.
    func createCanonicalChat(profile: String) async throws -> String
}

/// Result of a canonical tap resolution driven by a seam — the same rules as
/// `CanonicalChatResolver` but carried over the seam boundary.
public struct CanonicalLookup: Hashable, Sendable {
    public let rows: [CanonicalLookupRow]

    public init(rows: [CanonicalLookupRow]) {
        self.rows = rows
    }

    public var isEmpty: Bool { rows.isEmpty }
    public var first: CanonicalLookupRow? { rows.first }
}

public struct CanonicalLookupRow: Hashable, Sendable {
    public let id: String
    public let resolvedID: String?
    public let title: String
    public let preview: String
    public let messageCount: Int

    public init(id: String, resolvedID: String? = nil, title: String, preview: String = "", messageCount: Int = 0) {
        self.id = id
        self.resolvedID = resolvedID
        self.title = title
        self.preview = preview
        self.messageCount = messageCount
    }

    /// Open target: compression tip preferred, malformed ids rejected.
    public var openID: String? {
        let tip = resolvedID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !tip.isEmpty { return tip }
        let base = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? nil : base
    }
}

/// Fail-closed default for gateways without a Bot Mode chat surface (no
/// endpoint configured): every call throws instead of silently pretending
/// the gateway answered (`UnsupportedGatewayManagement` discipline).
public struct UnsupportedBotModeChat: BotModeChatProviding {
    public init() {}

    public func lookupCanonicalChat(profile: String) async throws -> CanonicalLookup {
        throw RosterError.notConnected
    }

    public func createCanonicalChat(profile: String) async throws -> String {
        throw RosterError.notConnected
    }
}

/// Which step of canonical Bot Chat resolution failed. Lookup and creation
/// are different failures with different safety implications (a failed lookup
/// must never lead to creation), so they are reported separately.
public enum BotChatFailureStage: String, Sendable, Hashable {
    case seamUnavailable
    case lookup
    case malformedRegistry
    case unconfirmed
    case create
}

/// Retryable canonical-chat open failure. Carries a user-facing message;
/// the caller shows it and offers retry — NEVER creates or forks a chat.
/// `stage` and `errorCategory` are safe diagnostics: a stage name and a Swift
/// error case name, never a token, URL, payload or message content.
public struct BotChatUnavailable: Error, Sendable, Hashable {
    public let message: String
    public let stage: BotChatFailureStage?
    public let errorCategory: String?

    public init(message: String, stage: BotChatFailureStage? = nil, errorCategory: String? = nil) {
        self.message = message
        self.stage = stage
        self.errorCategory = errorCategory
    }

    /// One-line diagnostic such as "lookup: BotModeProfileError.unsupportedMethod".
    public var diagnostic: String? {
        guard let stage else { return nil }
        return errorCategory.map { "\(stage.rawValue): \($0)" } ?? stage.rawValue
    }
}

/// Reduces an error to a diagnostic category that cannot carry secrets or
/// content: the type name plus, for enums, the case name — never the
/// associated payload (which may hold gateway text).
public enum SafeErrorCategory {
    public static func of(_ error: Error) -> String {
        let type = String(describing: Swift.type(of: error))
        let mirror = Mirror(reflecting: error)
        if mirror.displayStyle == .enum {
            if let label = mirror.children.first?.label { return "\(type).\(label)" }
            return "\(type).\(String(describing: error))"
        }
        if let url = error as? URLError { return "URLError.\(url.code.rawValue)" }
        return type
    }
}
