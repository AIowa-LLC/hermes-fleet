import XCTest
import FleetCore
import FleetPersistence
import FleetUI

/// P0.2a — the approval header is built from the conversation's own context
/// (route, session, cwd), never from the wire payload. Two gateways that run
/// a bot with the same profile name must produce distinguishable headers.
@MainActor
final class ApprovalOriginTests: XCTestCase {

    private struct Session: ConversationSessionProviding {
        let gatewayID: GatewayID
        var status: GatewayStatus { .online }
        var conversation: any ConversationProviding { Conversation() }
        var replay: any ReplayProviding { Replay(gatewayID: gatewayID) }
        var history: any SessionHistoryProviding { History() }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway { FleetGateway(id: gatewayID, displayName: gatewayID.rawValue) }
        func reauthenticate() async throws {}
    }

    private struct Conversation: ConversationProviding {
        var events: AsyncStream<ConversationEvent> { AsyncStream { $0.finish() } }
        func createSession(title: String?, profile: String?, model: String?, provider: String?, cols: Int?) async throws -> ConversationSession {
            ConversationSession(sessionID: "fresh-1", profileName: profile)
        }
        func resumeEvents(since lastEventID: Int, sessionID: String) async throws -> [ConversationEvent] { [] }
        func resumeSession(sessionID: String, lastEventID: Int?, profile: String? = nil) async throws -> ConversationSession {
            ConversationSession(sessionID: sessionID, profileName: profile)
        }
        func submitPrompt(sessionID: String, text: String) async throws -> PromptSubmission { PromptSubmission(status: "ok") }
        func interrupt(sessionID: String) async throws -> InterruptResult { InterruptResult(status: "ok") }
    }

    private struct Replay: ReplayProviding {
        let gatewayID: GatewayID
        func watermarks() async -> [SessionEventWatermark] { [] }
        func replayAfterReconnect() async throws -> [ReplayOutcome] { [] }
    }

    private struct History: SessionHistoryProviding {
        func fetchSessionHistory(sessionID: String) async throws -> SessionHistory {
            SessionHistory(sessionID: sessionID, count: 0, messages: [])
        }
        func fetchSessionStatus(sessionID: String) async throws -> SessionStatus {
            SessionStatus(rawOutput: "", sessionID: sessionID)
        }
    }

    private func makeViewModel(gateway: String, profile: String, sessionID: String?) -> ConversationViewModel {
        let id = GatewayID(rawValue: gateway)
        let route = Route(gatewayID: id, profileSlug: ProfileSlug(rawValue: profile))
        return ConversationViewModel(
            session: Session(gatewayID: id),
            cache: try! SwiftDataCacheStore.makeInMemory(),
            route: route,
            sessionID: sessionID)
    }

    func testOriginIsBuiltFromRouteNotFromWire() {
        let vm = makeViewModel(gateway: "gw-one", profile: "default", sessionID: "abcdef1234567890")
        let origin = vm.approvalOrigin(gatewayLabel: "Studio Mac", botLabel: nil)
        XCTAssertEqual(origin.gatewayLabel, "Studio Mac")
        XCTAssertEqual(origin.botLabel, "default", "falls back to the route's profile slug")
        XCTAssertEqual(origin.cwd, "unknown", "cwd is unknown until session.info reports it")
        XCTAssertEqual(origin.sessionLabel, "abcdef12", "no title yet, so a short session id")
    }

    func testSameProfileOnTwoGatewaysProducesDistinctHeaders() {
        let one = makeViewModel(gateway: "gw-one", profile: "default", sessionID: "s1")
        let two = makeViewModel(gateway: "gw-two", profile: "default", sessionID: "s1")
        let a = one.approvalOrigin(gatewayLabel: "Studio Mac", botLabel: "Default")
        let b = two.approvalOrigin(gatewayLabel: "Lab Mac", botLabel: "Default")
        XCTAssertEqual(a.botLabel, b.botLabel)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a.accessibilityDescription, b.accessibilityDescription)
    }

    func testMissingGatewayLabelReadsUnknown() {
        let vm = makeViewModel(gateway: "gw-one", profile: "default", sessionID: nil)
        XCTAssertEqual(vm.approvalOrigin(gatewayLabel: nil, botLabel: nil).gatewayLabel, "unknown")
    }
}
