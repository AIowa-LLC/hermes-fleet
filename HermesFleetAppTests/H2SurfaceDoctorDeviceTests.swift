import XCTest
@testable import HermesFleetApp
import FleetCore
import FleetUI

/// H2 (t_eb6b573d) — on-device live verification of the surface doctor
/// against the REAL Mac Fleet box (two surfaces, one host):
///
///   http://100.100.105.61:8642  = api_server (OpenAI-compatible REST):
///       POST /api/auth/ws-ticket → 404  (not the app surface)
///       GET  /health             → 200 {"platform": "hermes-agent"}
///   https://mac-fleet.tonysimons.dev = the chat gateway (hermes serve
///       behind the Cloudflare tunnel) — the CORRECT phone endpoint; its
///       /health is auth-gated (login HTML), so the doctor must NOT flag it.
///
/// Asserts the H2 acceptance on Tony's physical iPhone, hosted in the
/// unit-test bundle so it signs with the app profile (same pattern as
/// B1LiveBoardSelectorDeviceTests / F1LiveATSProbeTests):
///   1. register the api_server endpoint with a dummy session token →
///      roster refresh fails `.unsupported` AND the doctor recognizes the
///      Hermes REST surface (detail carries the hermesServerMarker);
///   2. GatewayFailureCopy renders the doctor hint (names the Hermes
///      server / not-the-chat-gateway mix-up), never the marker itself;
///   3. the tunnel endpoint is NOT flagged as a Hermes REST surface
///      (auth-gated /health → HTML → doctor stays silent);
///   4. cleanup — the probe gateway is removed (removeGateway clears its
///      Keychain credential with it).
///
/// No real credentials are used or printed: the api_server port 404s the
/// ws-ticket mint BEFORE any credential is validated, so a dummy token is
/// enough to reach the classified `.unsupported` path.
#if !targetEnvironment(simulator)
@MainActor
final class H2SurfaceDoctorDeviceTests: XCTestCase {

    /// The Mac Fleet api_server REST surface (wrong port for the app).
    private static let apiServerURL = URL(string: "http://100.100.105.61:8642")!
    /// The canonical chat-gateway endpoint (Cloudflare tunnel → :9119).
    private static let gatewayHost = "mac-fleet.tonysimons.dev"

    private var environment: AppEnvironment!

    override func setUpWithError() throws {
        environment = FleetServiceGraph.makeDefaultEnvironment()
    }

    func testApiServerSurfaceTriggersDoctorHintOnDevice() async throws {
        await environment.load()

        // Arrange: temp gateway at the REST port with a dummy token — the
        // mint 404s before the credential is ever validated.
        let probeID = GatewayID(rawValue: "h2-doctor-probe")
        try? await environment.removeGateway(probeID) // idempotent pre-clean
        _ = try await environment.addGateway(
            GatewayRegistration(
                id: probeID,
                displayName: "H2 Doctor Probe",
                endpoint: Self.apiServerURL,
                authConfiguration: GatewayAuthConfiguration(strategy: .sessionToken)))
        try await environment.saveCredential(
            GatewayCredential(rawValue: "h2-probe-not-a-real-token"),
            for: probeID)

        // Act: one roster refresh through the real production stack (the
        // refresh never throws on per-gateway failure — partial-outage
        // contract — it records the classified outcome).
        await environment.refreshRoster()
        defer { Task { try? await environment.removeGateway(probeID) } }

        // Assert: classification unchanged (.unsupported) + doctor hit.
        let snapshot = try XCTUnwrap(environment.rosterSnapshot)
        guard case .failed(let status, let detail)? = snapshot.gatewayOutcomes[probeID] else {
            XCTFail("probe gateway did not report a classified failure: " +
                    String(describing: snapshot.gatewayOutcomes[probeID]))
            return
        }
        XCTAssertEqual(status, .unsupported,
                       "the doctor must never change the classification: \(String(describing: detail))")
        let marker = GatewaySurfaceDoctorDetail.hermesServerMarker
        XCTAssertTrue(detail?.contains(marker) ?? false,
                      "the live api_server /health must be recognized: \(String(describing: detail))")

        // And the copy the user sees names the mix-up.
        let copy = GatewayFailureCopy.detail(status: status, detail: detail)
        XCTAssertTrue(copy.contains("Hermes server"), copy)
        XCTAssertTrue(copy.contains("not the chat gateway"), copy)
        XCTAssertFalse(copy.contains(marker), "raw marker never reaches the user: \(copy)")
    }

    func testGatewayTunnelHealthIsNotFlaggedAsRestSurface() async throws {
        await environment.load()

        // The tunnel endpoint (the CORRECT phone endpoint). If it is
        // registered on this device, its roster refresh must not carry the
        // doctor marker: /health is auth-gated (login HTML), and a healthy
        // gateway never reaches the doctor at all.
        guard let tunnelGateway = environment.gateways.first(where: {
            $0.endpoint?.host == Self.gatewayHost
        }) else {
            throw XCTSkip("the tunnel gateway is not registered on this device")
        }

        await environment.refreshRoster()
        let snapshot = try XCTUnwrap(environment.rosterSnapshot)
        let marker = GatewaySurfaceDoctorDetail.hermesServerMarker
        switch snapshot.gatewayOutcomes[tunnelGateway.id] {
        case .loaded:
            break // healthy gateway — the doctor never ran; nothing to flag
        case .failed(let status, let detail):
            XCTAssertFalse(detail?.contains(marker) ?? false,
                           "the auth-gated gateway /health (login HTML) must not be flagged as a Hermes REST surface: \(String(describing: detail))")
            XCTAssertNotEqual(status, .unsupported,
                              "the tunnel is the correct surface: \(String(describing: detail))")
        case nil:
            XCTFail("tunnel gateway missing from the roster snapshot")
        }
    }
}
#endif
