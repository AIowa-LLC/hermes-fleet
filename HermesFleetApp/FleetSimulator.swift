import Foundation
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
import FleetUI

#if DEBUG

/// Scripted fleet simulator — DEBUG builds ONLY.
///
/// U1 acceptance requires the navigation skeleton to be walkable in the
/// simulator: Gateways → Bots → Sessions → Conversation. Without a live Hermes
/// gateway wired with credentials, the real transport would classify every
/// gateway offline and the shell would show empty states end-to-end. This
/// simulator drives the SAME observable `AppEnvironment` runtime and the SAME
/// FleetCore seams with scripted services that return deterministic,
/// in-memory fleet data — so the whole cockpit flow is navigable on a booted
/// simulator. Release builds use the real production graph
/// (`FleetServiceGraph.makeProductionEnvironment`).
extension FleetServiceGraph {

    static func makeSimulatorEnvironment() -> AppEnvironment {
        // Scripted registry: in-memory credential store (no Keychain writes).
        let credentials = InMemoryCredentialStore()
        let registry: any GatewayRegistryManaging = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                ScriptedGatewayConnection(gatewayID: gateway.id)
            }
        )
        // Scripted union roster: FleetRosterService over scripted per-gateway
        // sessions (real M8 aggregation, scripted transport + roster RPCs).
        let roster: any FleetRosterProviding = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                ScriptedRosterSession(gatewayID: gateway.id)
            }
        )
        // Scripted session.list read path for Bot detail.
        let sessionList: any SessionListProviding = ScriptedSessionListService()
        // In-memory cache (scripted; no file-backed store in the simulator).
        let cache: any CacheStoring = (try! SwiftDataCacheStore.makeInMemory())

        return AppEnvironment(
            registry: registry,
            roster: roster,
            cache: cache,
            sessionList: sessionList,
            connectionFactory: { gateway, _ in
                ScriptedGatewayConnection(gatewayID: gateway.id)
            },
            conversationFactory: { gateway, _ in
                ScriptedConversationSession(gatewayID: gateway.id)
            },
            seedRegistrations: ScriptedFleet.registrations
        )
    }
}

/// Scripted read-only `session.list` for Bot detail (DEBUG only).
/// Returns the scripted fleet's sessions for a route; never mutates.
private struct ScriptedSessionListService: SessionListProviding {
    func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
        ScriptedFleet.sessions(on: route)
    }
}

/// Scripted per-gateway conversation session (DEBUG only): a scripted
/// connection + a scripted conversation client that streams a canned turn
/// (message.start → deltas → message.complete) after each prompt.submit, a
/// no-op replay (nothing to replay), and scripted history. Makes the U3
/// Conversation canvas fully walkable in the simulator without a live gateway.
private struct ScriptedConversationSession: ConversationSessionProviding {
    let gatewayID: GatewayID
    private let client: ScriptedConversationClient

    init(gatewayID: GatewayID) {
        self.gatewayID = gatewayID
        self.client = ScriptedConversationClient(gatewayID: gatewayID)
    }

    var status: GatewayStatus {
        // The `arch` gateway is scripted UNREACHABLE (partial-outage demo).
        gatewayID.rawValue == "arch" ? .offline : .online
    }

    func adoptedReady() async -> GatewayReadyAdoption? {
        gatewayID.rawValue == "arch"
            ? nil
            : GatewayReadyAdoption(replayEpoch: "scripted-1", heartbeatEnabled: true, changeEventsEnabled: true)
    }

    func connect() async throws {
        if gatewayID.rawValue == "arch" {
            throw GatewayConnectivityError.unreachable
        }
    }

    func disconnect() async {}

    func currentGateway() async -> FleetGateway {
        FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
    }

    func reauthenticate() async throws {
        if gatewayID.rawValue == "arch" {
            throw GatewayConnectivityError.unreachable
        }
    }

    var conversation: any ConversationProviding {
        client
    }

    var replay: any ReplayProviding {
        ScriptedReplay(gatewayID: gatewayID)
    }

    var history: any SessionHistoryProviding {
        ScriptedHistory(gatewayID: gatewayID)
    }
}

/// Scripted `ConversationProviding` that streams a canned turn after submit.
private final class ScriptedConversationClient: ConversationProviding, @unchecked Sendable {
    private let gatewayID: GatewayID
    private let streamBox = ScriptedEventStreamBox()

    init(gatewayID: GatewayID) {
        self.gatewayID = gatewayID
    }

    var events: AsyncStream<ConversationEvent> {
        streamBox.stream
    }

    func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
        ConversationSession(
            sessionID: "scripted-\\(gatewayID.rawValue)",
            storedSessionID: "stored-scripted-\\(gatewayID.rawValue)",
            messageCount: 0,
            messages: [],
            model: "scripted-model",
            provider: "simulator",
            profileName: profile
        )
    }

    func resumeSession(sessionID: String) async throws -> ConversationSession {
        ConversationSession(
            sessionID: sessionID,
            storedSessionID: "stored-\\(sessionID)",
            messageCount: 0,
            messages: [],
            model: "scripted-model",
            provider: "simulator",
            profileName: nil
        )
    }

    func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
        // Stream a canned assistant turn shortly after submit (async so the
        // view model's event subscription is attached).
        Task { [streamBox] in
            try? await Task.sleep(for: .milliseconds(250))
            streamBox.yield(.messageStart(sessionID: sessionID))
            streamBox.yield(.messageDelta(sessionID: sessionID, text: "Hello from the scripted fleet. ", rendered: nil))
            streamBox.yield(.messageDelta(sessionID: sessionID, text: "You said: ", rendered: nil))
            streamBox.yield(.messageDelta(sessionID: sessionID, text: text, rendered: nil))
            streamBox.yield(.statusUpdate(sessionID: sessionID, kind: "process", text: "complete"))
            streamBox.yield(.messageComplete(
                sessionID: sessionID,
                text: "Hello from the scripted fleet. You said: \(text)",
                status: nil,
                error: nil
            ))
        }
        return PromptSubmission(status: "streaming")
    }

    func interrupt(sessionID: String) async throws -> InterruptResult {
        InterruptResult(status: "interrupted")
    }
}

/// Thread-safe box bridging the scripted client's event channel to the
/// `AsyncStream` the view model subscribes to.
private final class ScriptedEventStreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private let pair: (stream: AsyncStream<ConversationEvent>, continuation: AsyncStream<ConversationEvent>.Continuation)

    init() {
        self.pair = AsyncStream<ConversationEvent>.makeStream()
    }

    var stream: AsyncStream<ConversationEvent> {
        lock.lock()
        defer { lock.unlock() }
        return pair.stream
    }

    func yield(_ event: ConversationEvent) {
        lock.lock()
        defer { lock.unlock() }
        pair.continuation.yield(event)
    }
}

/// Scripted no-op replay (DEBUG only) — nothing was missed in the simulator.
private struct ScriptedReplay: ReplayProviding {
    let gatewayID: GatewayID
    func watermarks() async -> [SessionEventWatermark] { [] }
    func replayAfterReconnect() async throws -> [ReplayOutcome] { [.nothingToReplay] }
}

/// Scripted read-only history (DEBUG only) — an empty transcript is fine for
/// the simulator walkthrough.
private struct ScriptedHistory: SessionHistoryProviding {
    let gatewayID: GatewayID
    func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
        SessionHistory(sessionID: sessionID, count: 0, messages: [])
    }
    func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
        SessionStatus.parse(output: "Session ID: \\(sessionID)")
    }
}

/// Deterministic in-memory fleet for the simulator: three gateways (two
/// healthy, one unreachable) each with a couple of bots (profiles) and
/// sessions, so every navigation destination and the partial-outage roster
/// state have content.
enum ScriptedFleet {
    static let registrations: [GatewayRegistration] = [
        GatewayRegistration(
            id: GatewayID(rawValue: "<dev-workstation>"),
            displayName: "MacBook M5",
            endpoint: URL(string: "http://127.0.0.1:8642")!
        ),
        GatewayRegistration(
            id: GatewayID(rawValue: "gaming-4090"),
            displayName: "Gaming 4090",
            endpoint: URL(string: "http://127.0.0.1:9900")!
        ),
        GatewayRegistration(
            id: GatewayID(rawValue: "arch"),
            displayName: "Arch Lab",
            endpoint: URL(string: "http://127.0.0.1:9910")!
        ),
    ]

    static func profiles(on gatewayID: GatewayID) -> [ProfileDescriptor] {
        switch gatewayID.rawValue {
        case "<dev-workstation>":
            return [
                ProfileDescriptor(
                    name: "default", path: "~/.hermes/profiles/default",
                    isDefault: true, model: "hermes", provider: "nous",
                    displayName: "Default", skillCount: 12, hasAvatar: true,
                    lastSession: ScriptedFleet.session(on: "default")
                ),
                ProfileDescriptor(
                    name: "researcher", path: "~/.hermes/profiles/researcher",
                    isDefault: false, model: "hermes", provider: "openrouter",
                    displayName: "Researcher", skillCount: 8, hasAvatar: true,
                    lastSession: ScriptedFleet.session(on: "researcher")
                ),
            ]
        case "gaming-4090":
            return [
                ProfileDescriptor(
                    name: "default", path: "~/.hermes/profiles/default",
                    isDefault: true, model: "hermes", provider: "nous",
                    displayName: "Default", skillCount: 10, hasAvatar: true,
                    lastSession: ScriptedFleet.session(on: "default")
                ),
            ]
        default:
            return []
        }
    }

    static func sessions(on route: Route) -> [SessionSummary] {
        switch route.gatewayID.rawValue {
        case "<dev-workstation>":
            return [
                ScriptedFleet.session(on: "default"),
                SessionSummary(
                    id: "<dev-workstation>.default.s2", title: "Replay plan review",
                    preview: "Discussing the reconnect/replay design.", startedAt: 1_755_000_000,
                    messageCount: 24, source: "ios"
                ),
            ]
        default:
            return [ScriptedFleet.session(on: route.profileSlug.rawValue)]
        }
    }

    private static func session(on slug: String) -> SessionSummary {
        SessionSummary(
            id: "<dev-workstation>.\(slug).s1", title: "Fleet setup",
            preview: "Initial conversation about the Hermes fleet.",
            startedAt: 1_754_000_000, messageCount: 6, source: "ios"
        )
    }
}

/// Scripted single-gateway connection: connects instantly, adopts a ready
/// payload, never touches the network. Used for the Gateways screen lifecycle
/// and the registry probe. The `arch` gateway is scripted UNREACHABLE so the
/// simulator demonstrates the partial-outage state (§31).
private struct ScriptedGatewayConnection: GatewayConnectivityProviding {
    let gatewayID: GatewayID

    private var isOutage: Bool { gatewayID.rawValue == "arch" }

    var status: GatewayStatus {
        // Scripted connections report online immediately for healthy
        // gateways; the outage gateway reports offline so the observable
        // lifecycle state reflects partial availability.
        isOutage ? .offline : .online
    }

    func adoptedReady() async -> GatewayReadyAdoption? {
        isOutage ? nil : GatewayReadyAdoption(replayEpoch: "scripted-1", heartbeatEnabled: true, changeEventsEnabled: true)
    }

    func connect() async throws {
        if isOutage {
            throw GatewayConnectivityError.unreachable
        }
        // No-op: scripted connect succeeds instantly.
    }

    func disconnect() async {
        // No-op: scripted disconnect is safe from every state (spec §31).
    }

    func currentGateway() async -> FleetGateway {
        FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
    }
}

/// Scripted per-gateway roster session: real M8 session shape, scripted
/// `profiles.list` / `session.list` responses. The `arch` gateway is scripted
/// UNREACHABLE so the union roster refresh classifies it offline while the
/// healthy gateways still aggregate (spec §31 partial availability).
private struct ScriptedRosterSession: GatewayRosterSession {
    let gatewayID: GatewayID

    private var isOutage: Bool { gatewayID.rawValue == "arch" }

    var status: GatewayStatus { isOutage ? .offline : .online }

    func adoptedReady() async -> GatewayReadyAdoption? {
        isOutage ? nil : GatewayReadyAdoption(replayEpoch: "scripted-1", heartbeatEnabled: true, changeEventsEnabled: true)
    }

    func connect() async throws {
        if isOutage {
            throw GatewayConnectivityError.unreachable
        }
    }

    func disconnect() async {}

    func currentGateway() async -> FleetGateway {
        FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
    }

    func fetchProfiles() async throws -> [ProfileDescriptor] {
        if isOutage { throw RosterError.notConnected }
        return ScriptedFleet.profiles(on: gatewayID)
    }

    func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
        if isOutage { throw RosterError.notConnected }
        return ScriptedFleet.sessions(on: route)
    }
}

#endif
