// p07_transport_verify_main.swift — t_8a7f3dce (P0-7) LIVE verification driver.
//
// Compiled together with the REAL FleetCore + FleetNetworking package sources:
//   swiftc Packages/FleetCore/Sources/FleetCore/*.swift \
//          Packages/FleetNetworking/Sources/FleetNetworking/*.swift \
//          scripts/p07_transport_verify_main.swift -o build/p07_verify
// (orchestrated by scripts/p07_transport_verify.sh). This exercises the exact
// classes the app's composition root builds — GatewayConversationSession over
// GatewayWebSocketTransport with the username/password GatewayAuthenticator —
// against the LIVE tailnet gateway through the loopback forwarder.
//
// Proves the dogfood defect fixed at the seam where it occurred:
//   [A] connect → create session → send → reply streams (first entry);
//   [B] POP (subscriber released) → RE-ENTER (fresh subscription, connect()
//       again on the SAME still-open session) → send → reply streams, with
//       NO "connect() from open" error;
//   [C] NEW session via session.create → usable (send → reply streams).
//
// Credential safety: creds come from /tmp/hermes_lan_surface/.cred (0600),
// sourced by the shell wrapper into P07_USER/P07_PASS env vars; they are
// NEVER printed or logged.

import Foundation
import FleetCore
import FleetNetworking
import FleetSecurity

let forwardBase = URL(string: ProcessInfo.processInfo.environment["P07_BASE"] ?? "http://127.0.0.1:19120")!
guard let user = ProcessInfo.processInfo.environment["P07_USER"],
      let pass = ProcessInfo.processInfo.environment["P07_PASS"],
      !user.isEmpty, !pass.isEmpty else {
    FileHandle.standardError.write("FATAL: P07_USER/P07_PASS not set\n".data(using: .utf8)!)
    exit(2)
}

let gatewayID = GatewayID(rawValue: "p07-verify")
let store = InMemoryCredentialStore()
try? await store.saveCredential(
    GatewayCredential(rawValue: pass, username: user), for: gatewayID)
let session = GatewayConversationSession(
    gatewayID: gatewayID,
    displayName: "P0-7 Verify",
    endpoint: forwardBase,
    transport: GatewayWebSocketTransport(
        baseURL: forwardBase,
        authentication: GatewayAuthenticator(
            gatewayID: gatewayID,
            strategy: .usernamePassword,
            credentialStore: store,
            baseURL: forwardBase
        ),
        configuration: TransportConfiguration(
            pingInterval: .seconds(15),
            inboundDeadline: .seconds(45),
            connectTimeout: .seconds(15),
            requestTimeout: .seconds(60)
        )
    )
)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
    exit(1)
}

/// Accumulates streamed assistant text (message.delta + message.complete).
actor EventBag {
    private(set) var texts: [String] = []
    func add(_ event: ConversationEvent) {
        switch event {
        case .messageDelta(_, let text, _): texts.append(text)
        case .messageComplete(_, let text, _, _): texts.append(text)
        default: break
        }
    }
    func joined() -> String { texts.joined() }
}

/// One "screen entry": a live event subscription like the view model's.
func subscribe() async -> (task: Task<Void, Never>, bag: EventBag) {
    let bag = EventBag()
    let events = await session.conversation.events
    let task = Task {
        for await event in events {
            await bag.add(event)
        }
    }
    return (task, bag)
}

func waitFor(_ name: String, timeout: TimeInterval = 60,
             _ check: @escaping () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await check() { print("PASS  \(name)"); return }
        try? await Task.sleep(for: .milliseconds(250))
    }
    fail("\(name): condition not met within \(timeout)s")
}

// ---- [A] connect + first entry: create + send + stream --------------------
print("=== [A] connect + create + send (first entry) ===")
do { try await session.connect() } catch { fail("connect: \(error)") }
guard session.status == .online else { fail("status after connect: \(session.status)") }

let (sub1, bag1) = await subscribe()
let created: ConversationSession
do {
    created = try await session.conversation.createSession(
        title: "P0-7 live verify", profile: "default", model: nil, provider: nil, cols: nil)
} catch { fail("session.create: \(error)") }
let sid = created.sessionID
print("      session \(sid)")

do { try await session.conversation.submitPrompt(sessionID: sid, text: "Reply with exactly: P0-7 ALPHA") }
catch { fail("prompt.submit #1: \(error)") }
await waitFor("[A] reply streams on first entry") { await bag1.joined().contains("P0-7 ALPHA") }

// ---- [B] POP + RE-ENTER on the SAME still-open transport ------------------
print("=== [B] pop + re-enter on still-open transport ===")
sub1.cancel()
try? await Task.sleep(for: .milliseconds(500))
guard session.status == .online else { fail("transport must stay open after pop (got \(session.status))") }

let (sub2, bag2) = await subscribe()
do { try await session.connect() } catch {
    fail("RE-ENTRY connect() must be an idempotent no-op, got: \(error)")
}
guard session.status == .online else { fail("re-entry status: \(session.status)") }

do { try await session.conversation.submitPrompt(sessionID: sid, text: "Reply with exactly: P0-7 BETA") }
catch { fail("prompt.submit #2 (re-entry): \(error)") }
await waitFor("[B] reply streams after re-entry (fresh fan-out pipe)") {
    await bag2.joined().contains("P0-7 BETA")
}
sub2.cancel()

// ---- [C] NEW session via session.create is usable -------------------------
print("=== [C] new session via session.create ===")
let (sub3, bag3) = await subscribe()
let fresh: ConversationSession
do {
    fresh = try await session.conversation.createSession(
        title: "P0-7 new session", profile: "default", model: nil, provider: nil, cols: nil)
} catch { fail("session.create #2: \(error)") }
do { try await session.conversation.submitPrompt(sessionID: fresh.sessionID, text: "Reply with exactly: P0-7 GAMMA") }
catch { fail("prompt.submit #3 (new session): \(error)") }
await waitFor("[C] new session usable — reply streams") {
    await bag3.joined().contains("P0-7 GAMMA")
}
sub3.cancel()

await session.disconnect()
print("ALL P0-7 LIVE CHECKS PASSED")
exit(0)
