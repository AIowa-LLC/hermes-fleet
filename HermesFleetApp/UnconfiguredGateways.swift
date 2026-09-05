import Foundation
import FleetCore

// F2 (t_b678fb38): the compiled loopback default (`http://127.0.0.1:8642`)
// is GONE — a gateway with no persisted endpoint no longer pretends to live
// on loopback. These stubs are what the composition-root factories return
// for such a row: every operation fails honestly with a notConfigured /
// notConnected error and `connect()` classifies as an invalid state, so the
// UI surfaces "add a gateway" instead of silently probing a phantom
// localhost that can never answer on a real device.
//
// These paths are defensive by construction: registration REQUIRES an
// endpoint, so only a corrupt/legacy persisted row reaches them. They exist
// so the no-default world fails closed instead of force-unwrapping.

/// Connectivity stub for a gateway with no endpoint: connect() throws,
/// status stays offline, teardown is a no-op.
struct UnconfiguredGatewayConnection: GatewayConnectivityProviding {
    let gateway: FleetGateway

    var gatewayID: GatewayID { gateway.id }
    var status: GatewayStatus { .offline }
    func adoptedReady() async -> GatewayReadyAdoption? { nil }
    func connect() async throws {
        throw GatewayConnectivityError.invalidState(
            "no gateway endpoint configured — add a gateway"
        )
    }
    func disconnect() async {}
    func currentGateway() async -> FleetGateway { gateway }
}

/// Roster-session stub (probe + union-roster factories): connectivity above,
/// roster reads fail closed with `RosterError.notConnected` so the union
/// roster's partial-availability contract treats the row as an outage.
struct UnconfiguredRosterSession: GatewayRosterSession {
    let gateway: FleetGateway

    var gatewayID: GatewayID { gateway.id }
    var status: GatewayStatus { .offline }
    func adoptedReady() async -> GatewayReadyAdoption? { nil }
    func connect() async throws {
        throw GatewayConnectivityError.invalidState(
            "no gateway endpoint configured — add a gateway"
        )
    }
    func disconnect() async {}
    func currentGateway() async -> FleetGateway { gateway }

    func fetchProfiles() async throws -> [ProfileDescriptor] {
        throw RosterError.notConnected
    }
    func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
        throw RosterError.notConnected
    }
}

/// Conversation-session stub: the full `ConversationSessionProviding`
/// surface, every leg failing closed. Streams finish immediately (no events
/// ever fabricated).
struct UnconfiguredConversationSession: ConversationSessionProviding {
    let gateway: FleetGateway

    var gatewayID: GatewayID { gateway.id }
    var status: GatewayStatus { .offline }
    func adoptedReady() async -> GatewayReadyAdoption? { nil }
    func connect() async throws {
        throw GatewayConnectivityError.invalidState(
            "no gateway endpoint configured — add a gateway"
        )
    }
    func disconnect() async {}
    func currentGateway() async -> FleetGateway { gateway }

    var conversation: any ConversationProviding { UnconfiguredConversation() }
    var replay: any ReplayProviding { UnconfiguredReplay(gatewayID: gateway.id) }
    var history: any SessionHistoryProviding { UnconfiguredHistory() }

    func reauthenticate() async throws {
        throw ConversationError.notConnected
    }
}

private struct UnconfiguredConversation: ConversationProviding {
    var events: AsyncStream<ConversationEvent> {
        AsyncStream { $0.finish() }
    }
    func createSession(
        title: String?, profile: String?, model: String?, provider: String?, cols: Int?
    ) async throws -> ConversationSession {
        throw ConversationError.notConnected
    }
    func resumeSession(sessionID: String, lastEventID: Int?) async throws -> ConversationSession {
        throw ConversationError.notConnected
    }
    func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission {
        throw ConversationError.notConnected
    }
    func interrupt(sessionID: String) async throws -> InterruptResult {
        throw ConversationError.notConnected
    }
    func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] {
        throw ConversationError.notConnected
    }
}

private struct UnconfiguredReplay: ReplayProviding {
    let gatewayID: GatewayID
    func watermarks() async -> [SessionEventWatermark] { [] }
    func replayAfterReconnect() async throws -> [ReplayOutcome] {
        throw ReplayError.notConnected
    }
}

private struct UnconfiguredHistory: SessionHistoryProviding {
    func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
        throw SessionHistoryError.notConnected
    }
    func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
        throw SessionHistoryError.notConnected
    }
}

/// Kanban-watcher stub: the board fetch fails closed; the event stream
/// finishes immediately (reconnect logic sees a terminal stream, not a
/// fabricated board). t_624b81cd: selector surface is honest — no boards
/// to list, no pin to hold.
struct UnconfiguredKanbanWatcher: KanbanBoardWatching {
    func snapshot() async throws -> KanbanBoardSnapshot {
        throw KanbanBoardError.streamDropped("no gateway endpoint configured — add a gateway")
    }
    func changeEvents() async -> AsyncStream<KanbanEventBatch> {
        AsyncStream { $0.finish() }
    }
    func stop() async {}
    func fetchBoards() async throws -> KanbanBoardList {
        KanbanBoardList(boards: [], current: nil)
    }
    func pinBoard(_ slug: String?) async {}
}
