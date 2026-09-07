import XCTest
import FleetCore
import FleetNetworking

/// H2 (t_eb6b573d) — surface doctor classification.
///
/// The dogfood case (2026-09-07): the app was pointed at the `api_server`
/// REST port (100.100.105.61:8642). That surface 404s
/// `POST /api/auth/ws-ticket` (→ `.unsupported`) but answers
/// `GET /health` with 200 + `{"platform": "hermes-agent"}`. One cheap
/// follow-up GET can tell the user WHICH surface they hit.
///
/// These tests pin the chain:
///   ws-ticket 404 → .unsupported → doctor GET /health
///     → 200 + hermes-agent JSON  → detail carries the hermesServerMarker
///     → anything else            → detail unchanged (fail-open)
/// and the copy contract in FleetUI (F1FailureCopyTests style):
///   marker   → "Hermes server, but not the chat gateway" hint
///   404 only → existing generic wrong-port copy
///   timeout  → unreachable copy unchanged.

/// URLProtocol mock answering `/health` from a scripted response. No network.
final class HealthProbeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statusCode: Int = 200
    nonisolated(unsafe) static var body: Data = Data()
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class H2SurfaceDoctorTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HealthProbeURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        HealthProbeURLProtocol.capturedRequests = []
        session = nil
        super.tearDown()
    }

    // MARK: doctor probe (GatewaySurfaceDoctor)

    func testHealth200HermesAgentJSONMeansHermesServer() async {
        // The exact api_server envelope from the dogfood finding.
        HealthProbeURLProtocol.statusCode = 200
        HealthProbeURLProtocol.body = Data(
            #"{"platform": "hermes-agent", "version": "1.0.0"}"#.utf8)

        let finding = await GatewaySurfaceDoctor.probe(
            baseURL: URL(string: "http://192.168.4.32:8642")!,
            urlSession: session)

        XCTAssertEqual(finding, .hermesServer)
        let request = HealthProbeURLProtocol.capturedRequests.last
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(request?.url?.path, "/health")
        XCTAssertNil(request?.value(forHTTPHeaderField: "Cookie"),
                     "the doctor probe is non-secret: it must never send credentials")
    }

    func testHealthNon200IsUnknown() async {
        HealthProbeURLProtocol.statusCode = 404
        HealthProbeURLProtocol.body = Data(#"{"platform": "hermes-agent"}"#.utf8)

        let finding = await GatewaySurfaceDoctor.probe(
            baseURL: URL(string: "http://192.168.4.32:8642")!,
            urlSession: session)
        XCTAssertEqual(finding, .unknown)
    }

    func testHealthHTMLLoginRedirectIsUnknown() async {
        // The WS gateway's /health redirects unauthenticated requests to the
        // login page (verified live: mac-fleet.tonysimons.dev/health → 200
        // "Sign in — Hermes Agent" HTML). HTML must NOT decode as a Hermes
        // REST hit — that surface is the gateway, not the mix-up.
        HealthProbeURLProtocol.statusCode = 200
        HealthProbeURLProtocol.body = Data(
            #"<html><body>Sign in — Hermes Agent</body></html>"#.utf8)

        let finding = await GatewaySurfaceDoctor.probe(
            baseURL: URL(string: "https://mac-fleet.example.dev")!,
            urlSession: session)
        XCTAssertEqual(finding, .unknown)
    }

    func testHealthJSONWithoutHermesAgentIsUnknown() async {
        // A random REST box answering JSON: answered, but not identifiable.
        HealthProbeURLProtocol.statusCode = 200
        HealthProbeURLProtocol.body = Data(#"{"status": "ok"}"#.utf8)

        let finding = await GatewaySurfaceDoctor.probe(
            baseURL: URL(string: "http://192.168.4.32:8642")!,
            urlSession: session)
        XCTAssertEqual(finding, .unknown)
    }

    func testProbeNeverThrowsOnTransportError() async {
        // Dead host: URLSession error → .unknown, not a thrown error.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        let deadSession = URLSession(configuration: config)
        let finding = await GatewaySurfaceDoctor.probe(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            urlSession: deadSession)
        XCTAssertEqual(finding, .unknown)
    }

    // MARK: roster-service classification chain (fail-open contract)

    private func makeUnsupportedRoster(
        healthStatus: Int,
        healthBody: Data
    ) async -> FleetRosterSnapshot {
        HealthProbeURLProtocol.statusCode = healthStatus
        HealthProbeURLProtocol.body = healthBody

        let probeID = GatewayID(rawValue: "h2-probe")
        let failingSessionFactory: GatewayRosterSessionFactory = { gateway, _ in
            StubFailingSession(
                gatewayID: gateway.id,
                error: .authSurfaceHTTP(404))
        }
        let registry = GatewayRegistryService(credentials: TestCredentialStore()) { gateway, _ in
            StubFailingSession(gatewayID: gateway.id, error: .authSurfaceHTTP(404))
        }
        let endpoint = URL(string: "http://192.168.4.32:8642")!
        _ = try! await registry.addGateway(
            GatewayRegistration(id: probeID, displayName: "Wrong Port", endpoint: endpoint))

        let roster = FleetRosterService(
            registry: registry,
            credentials: TestCredentialStore(),
            sessionFactory: failingSessionFactory,
            doctorSession: session)
        return await roster.refreshRoster()
    }

    func testUnsupportedPlusHermesHealthCarriesDoctorMarker() async {
        // ws-ticket 404 + /health 200 hermes-agent → marker in the detail.
        let snapshot = await makeUnsupportedRoster(
            healthStatus: 200,
            healthBody: Data(#"{"platform": "hermes-agent"}"#.utf8))

        let outcome = snapshot.gatewayOutcomes[GatewayID(rawValue: "h2-probe")]
        guard case .failed(let status, let detail) = outcome else {
            return XCTFail("expected classified failure, got \(String(describing: outcome))")
        }
        XCTAssertEqual(status, .unsupported, "the doctor never changes the classification")
        XCTAssertTrue(
            detail?.contains(GatewaySurfaceDoctor.hermesServerMarker) ?? false,
            "detail must carry the hermes-agent marker: \(String(describing: detail))")
    }

    func testUnsupportedWith404HealthKeepsGenericDetail() async {
        // ws-ticket 404 + /health 404 → no marker; the existing F1 copy path.
        let snapshot = await makeUnsupportedRoster(
            healthStatus: 404,
            healthBody: Data(#"{"not":"found"}"#.utf8))

        let outcome = snapshot.gatewayOutcomes[GatewayID(rawValue: "h2-probe")]
        guard case .failed(let status, let detail) = outcome else {
            return XCTFail("expected classified failure, got \(String(describing: outcome))")
        }
        XCTAssertEqual(status, .unsupported)
        XCTAssertFalse(
            detail?.contains(GatewaySurfaceDoctor.hermesServerMarker) ?? true,
            "no hermes hit → no marker: \(String(describing: detail))")
        XCTAssertEqual(detail, "auth endpoint returned HTTP 404")
    }

    // MARK: shared marker constant (FleetCore seam)

    func testMarkerIsTheSharedFleetCoreConstant() {
        XCTAssertEqual(
            GatewaySurfaceDoctor.hermesServerMarker,
            GatewaySurfaceDoctorDetail.hermesServerMarker,
            "FleetUI keys off the FleetCore constant; FleetNetworking must use the same token")
        XCTAssertTrue(GatewaySurfaceDoctor.hermesServerMarker.contains("hermes-agent"))
    }
}

/// Minimal roster session stub whose connect() throws a scripted
/// `GatewayConnectivityError`.
private final class StubFailingSession: GatewayRosterSession, @unchecked Sendable {
    let gatewayID: GatewayID
    private let error: GatewayConnectivityError

    init(gatewayID: GatewayID, error: GatewayConnectivityError) {
        self.gatewayID = gatewayID
        self.error = error
    }

    var status: GatewayStatus { GatewayStatus(connectivityError: error) }

    func adoptedReady() async -> GatewayReadyAdoption? { nil }
    func connect() async throws { throw error }
    func disconnect() async {}
    func currentGateway() async -> FleetGateway {
        FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil)
    }
    func fetchProfiles() async throws -> [ProfileDescriptor] { [] }
    func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
}

/// Minimal credential store for registry construction in tests.
private final class TestCredentialStore: CredentialStoring, @unchecked Sendable {
    func saveCredential(_ credential: GatewayCredential, for id: GatewayID) async throws {}
    func loadCredential(for id: GatewayID) async throws -> GatewayCredential? { nil }
    func deleteCredential(for id: GatewayID) async throws {}
}
