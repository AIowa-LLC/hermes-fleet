import XCTest
import FleetCore
@testable import FleetNetworking

final class DashboardLiveOpsClientTests: XCTestCase {
    private let gateway = GatewayID(rawValue: "fixture-gateway")

    private func client(status: Int = 200, body: String,
                        transport: GatewayWebSocketTransport? = nil) -> DashboardLiveOpsClient {
        MediaStubURLProtocol.plan = .init(status: status, body: Data(body.utf8))
        MediaStubURLProtocol.capturedRequests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let legacyTransport = transport ?? GatewayWebSocketTransport(
            baseURL: URL(string: "https://gateway.example.test")!,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture", ttlSeconds: 30)))
        return DashboardLiveOpsClient(
            gatewayID: gateway, baseURL: URL(string: "https://gateway.example.test")!,
            legacy: GatewayLiveOpsClient(gatewayID: gateway, transport: legacyTransport),
            httpCredential: { .sessionTokenHeader("synthetic-token") }, urlSession: session)
    }

    func testDesktopProcessesAndAsyncChildrenAreVisibleWithoutLegacySocket() async throws {
        let client = client(body: #"{"schema":1,"publishers":2,"sessions":[{"id":"fleet:a:rt","session_key":"stored-a","title":"Delegate fixture","status":"idle","subagents":[{"subagent_id":"child","status":"running","goal":"Synthetic work"}]},{"id":"fleet:b:rt","session_key":"stored-b","status":"working","subagents":[]}]}"#)
        let snapshot = await client.snapshot(gateway: gateway)
        XCTAssertEqual(snapshot.coverage, .reporting)
        XCTAssertEqual(snapshot.reportingSetup, .reporting(backends: 2))
        XCTAssertEqual(Set(snapshot.operations.map(\.id)).count, 2)
        let parent = try XCTUnwrap(snapshot.operations.first)
        XCTAssertTrue(parent.isDelegating)
        XCTAssertEqual(parent.subagents?.first?.goal, "Synthetic work")
        XCTAssertEqual(LiveOpsSnapshot(gateways: [snapshot]).activeCount.value, 2)
        XCTAssertEqual(MediaStubURLProtocol.capturedRequests.first?.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "synthetic-token")
        XCTAssertEqual(MediaStubURLProtocol.capturedRequests.first?.url?.path, "/api/plugins/fleet-liveops/snapshot")
    }

    func testNoPublisherIsUnavailableNotKnownZero() async {
        let snapshot = await client(body: #"{"schema":1,"publishers":0,"sessions":[]}"#).snapshot(gateway: gateway)
        XCTAssertFalse(snapshot.coverage.isReporting)
        XCTAssertEqual(snapshot.reportingSetup, .unavailable)
        XCTAssertTrue(LiveOpsSnapshot(gateways: [snapshot]).activeCount.isPartial)
        let partial = await client(body: #"{"schema":1,"publishers":1,"stale_publishers":1,"sessions":[]}"#).snapshot(gateway: gateway)
        XCTAssertFalse(partial.coverage.isReporting, "another quiet publisher cannot conceal a stalled Desktop reporter")
        XCTAssertEqual(partial.reportingSetup, .unavailable)
    }

    func testMalformedPayloadDoesNotBecomeQuietFleet() async {
        for body in [#"{"schema":1,"publishers":1}"#, #"{"schema":2,"publishers":1,"sessions":[]}"#,
                     #"{"schema":1,"publishers":1,"sessions":[{"id":"rt","session_key":"stored","subagents":[]}]}"#] {
            let snapshot = await client(body: body).snapshot(gateway: gateway)
            XCTAssertFalse(snapshot.coverage.isReporting)
        }
    }

    func testAuthenticationRejectionDoesNotFallBackToDifferentScope() async {
        let snapshot = await client(status: 403, body: "{}").snapshot(gateway: gateway)
        XCTAssertEqual(snapshot.coverage, .authFailed)
        XCTAssertEqual(snapshot.reportingSetup, .unknown, "authentication failure is not evidence of a missing plugin")
        XCTAssertEqual(MediaStubURLProtocol.capturedRequests.count, 1)
    }

    func testDesktopObservationDoesNotGrantControlAuthority() async {
        let client = client(body: "{}")
        do {
            _ = try await client.listSubagents(sessionID: "fleet:a:rt")
            XCTFail("observation cannot attach to a Desktop session")
        } catch {
            XCTAssertEqual(error as? LiveOpsControlError, .notAttached)
        }
        XCTAssertTrue(MediaStubURLProtocol.capturedRequests.isEmpty)
    }

    func testMissingPluginUsesLegacySnapshotWithScopeNotice() async throws {
        let server = try InProcessWebSocketServer(script: .init(
            onOpen: [#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"change_events":true}}}"#],
            onText: { frame in
                guard let data = frame.data(using: .utf8),
                      let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = request["id"] as? String, let method = request["method"] as? String else { return [] }
                let result: [String: Any] = method == "session.active_list" ? ["sessions": []] : ["active": []]
                let response = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
                return [String(data: response, encoding: .utf8)!]
            }))
        try await server.start()
        defer { server.stop() }
        let transport = GatewayWebSocketTransport(
            baseURL: URL(string: "http://127.0.0.1:\(server.listeningPort)")!,
            ticketMinter: StaticTicketMinter(ticket: WSTicket(token: "fixture", ttlSeconds: 30)))
        defer { Task { await transport.disconnect() } }
        let snapshot = await client(status: 404, body: "{}", transport: transport).snapshot(gateway: gateway)
        XCTAssertEqual(snapshot.coverage, .reporting)
        XCTAssertTrue(snapshot.operations.isEmpty)
        XCTAssertEqual(snapshot.reportingSetup, .required)
        XCTAssertTrue(snapshot.observationNote?.contains("Desktop") == true)
    }

    func testSetupDetectionRecoversAfterPluginIsInstalledWithoutRecreatingClient() async {
        let client = client(status: 404, body: "{}")
        let missing = await client.snapshot(gateway: gateway)
        XCTAssertEqual(missing.reportingSetup, .required)
        MediaStubURLProtocol.plan = .init(status: 200, body: Data(#"{"schema":1,"publishers":2,"sessions":[]}"#.utf8))
        let installed = await client.snapshot(gateway: gateway)
        XCTAssertEqual(installed.coverage, .reporting)
        XCTAssertEqual(installed.reportingSetup, .reporting(backends: 2))
        XCTAssertEqual(MediaStubURLProtocol.capturedRequests.count, 2)
    }
}
