#if DEBUG && targetEnvironment(simulator)
import Foundation
import FleetCore
import FleetUI

/// Phase B inbox UI-test fixture (DEBUG simulator only).
///
/// `HERMES_FLEET_INBOX_FIXTURE=1` gives the `workstation` gateway an inbox feed
/// that reports ONE pending command approval (`ls ~/Projects`, session
/// `workstation.default.s1`). The approval is answered through the real
/// `InboxStore` path (scripted biometrics, then `respond`), so a UI test can
/// watch it move from Pending to History. Without the knob no feed is built and
/// the inbox stays empty, which keeps every other suite hermetic.
enum ScriptedInboxFixture {
    static let enabled: Bool = ProcessInfo.processInfo.environment["HERMES_FLEET_INBOX_FIXTURE"] == "1"

    static let gatewayID = GatewayID(rawValue: "workstation")
    static let sessionID = "workstation.default.s1"
    static let requestID = "inbox-approval-ls-projects"
    static let command = "ls ~/Projects"

    /// The factory handed to `AppEnvironment`. Nil (no feeds at all) unless the
    /// fixture knob is set.
    static let feedFactory: FleetInboxFeedFactory? = {
        guard enabled else { return nil }
        return { (gateway: FleetGateway) -> (any InboxGatewayFeed)? in
            guard gateway.id == ScriptedInboxFixture.gatewayID else { return nil }
            return ScriptedInboxFeed(gatewayID: gateway.id)
        }
    }()

    static func pendingRequest() -> ApprovalRequest? {
        guard !ScriptedInboxEngine.shared.isResolved(requestID) else { return nil }
        return ApprovalRequest(
            requestID: requestID,
            sessionID: sessionID,
            command: command,
            detail: "List files in the Projects directory",
            choices: ["once", "session", "deny"])
    }
}

/// Resolution state shared across feed re-attachments within one process run.
final class ScriptedInboxEngine: @unchecked Sendable {
    static let shared = ScriptedInboxEngine()

    private let lock = NSLock()
    private var resolved: Set<String> = []

    func isResolved(_ requestID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolved.contains(requestID)
    }

    func resolve(_ requestID: String) {
        lock.lock()
        defer { lock.unlock() }
        resolved.insert(requestID)
    }
}

/// One gateway's scripted inbox feed. Emits the pending approval on subscribe
/// and reconciles it through `approval.pending`, like a live gateway would.
struct ScriptedInboxFeed: InboxGatewayFeed {
    let gatewayID: GatewayID

    var approvals: any ApprovalsProviding { ScriptedInboxApprovals() }
    var prompts: any ServerPromptResponding { UnsupportedServerPrompts() }

    func start() async throws {}

    func stop() async {}

    func events() -> AsyncStream<InboxFeedEvent> {
        AsyncStream { continuation in
            if let request = ScriptedInboxFixture.pendingRequest() {
                continuation.yield(.legacyApproval(request))
            }
            continuation.finish()
        }
    }

    func pendingApprovals(sessionID: String) async throws -> [ApprovalRequest] {
        guard sessionID == ScriptedInboxFixture.sessionID,
              let request = ScriptedInboxFixture.pendingRequest() else { return [] }
        return [request]
    }
}

/// Answers the scripted approval. Any choice, including deny, resolves it once.
struct ScriptedInboxApprovals: ApprovalsProviding {
    func respond(sessionID: String, requestID: String, choice: ApprovalChoice, all: Bool) async throws -> Int {
        guard requestID == ScriptedInboxFixture.requestID,
              !ScriptedInboxEngine.shared.isResolved(requestID) else { return 0 }
        ScriptedInboxEngine.shared.resolve(requestID)
        return 1
    }

    func setSessionYolo(_ enabled: Bool, sessionID: String) async throws -> Bool { false }

    func pendingApprovals(sessionID: String) async throws -> [ApprovalRequest] {
        guard sessionID == ScriptedInboxFixture.sessionID,
              let request = ScriptedInboxFixture.pendingRequest() else { return [] }
        return [request]
    }
}
#endif
