#if DEBUG && targetEnvironment(simulator)
import Foundation
import FleetCore
import FleetUI

/// Phase B inbox UI-test fixture (DEBUG simulator only).
///
/// - `HERMES_FLEET_INBOX_FIXTURE=1` seeds ONE pending command approval
///   (`ls ~/Projects`) on the `workstation` gateway, delivered through a
///   registered answer source the way an open conversation would deliver it.
///   The approval is answered through the real `InboxStore` path (scripted
///   biometrics, then `respond`), so a UI test sees it move to History.
/// - `HERMES_FLEET_INBOX_OFFLINE=1` also seeds the approval, and makes every
///   scripted gateway connection fail, so no gateway is connected. The inbox
///   must then show its offline banner and disable approve and deny.
///
/// Without either knob nothing is seeded and the inbox stays empty, which keeps
/// every other suite hermetic.
enum ScriptedInboxFixture {
    private static let environment = ProcessInfo.processInfo.environment

    static var seeded: Bool {
        environment["HERMES_FLEET_INBOX_FIXTURE"] == "1" || offline
    }

    static var offline: Bool {
        environment["HERMES_FLEET_INBOX_OFFLINE"] == "1"
    }

    static let gatewayID = GatewayID(rawValue: "workstation")
    static let sessionID = "workstation.default.s1"
    static let requestID = "inbox-approval-ls-projects"
    static let command = "ls ~/Projects"

    static func pendingRequest() -> ApprovalRequest? {
        guard !ScriptedInboxEngine.shared.isResolved(requestID) else { return nil }
        return ApprovalRequest(
            requestID: requestID,
            sessionID: sessionID,
            command: command,
            detail: "List files in the Projects directory",
            choices: ["once", "session", "deny"])
    }

    /// Registers the scripted answer source and records the approval on it.
    /// Called once the environment exists; a no-op unless a knob is set.
    @MainActor
    static func seed(into inbox: InboxStore) {
        guard seeded else { return }
        let sourceID = inbox.registerSource(
            ScriptedInboxAnswerSource(gatewayID: gatewayID),
            label: "Workstation")
        if let request = pendingRequest() {
            inbox.record(.legacyApproval(request), sourceID: sourceID)
        }
    }
}

/// Resolution state shared across the process run.
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

/// The scripted conversation answer source for the `workstation` gateway.
struct ScriptedInboxAnswerSource: InboxAnswerSource {
    let gatewayID: GatewayID

    var approvals: any ApprovalsProviding { ScriptedInboxApprovals() }
    var prompts: (any ServerPromptResponding)? { nil }
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
