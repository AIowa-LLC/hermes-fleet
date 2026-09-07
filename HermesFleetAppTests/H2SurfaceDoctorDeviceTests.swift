import XCTest
@testable import HermesFleetApp
import FleetCore
import FleetUI

/// H2 (t_eb6b573d) — on-device live verification of the surface doctor
/// against the REAL Mac Fleet box (two surfaces, one host):
///
///   the api_server REST port = OpenAI-compatible surface:
///       POST /api/auth/ws-ticket → 404  (not the app surface)
///       GET  /health             → 200 {"platform": "hermes-agent"}
///   the chat gateway (hermes serve behind the Cloudflare tunnel) = the
///       CORRECT phone endpoint; its /health is auth-gated (login HTML),
///       so the doctor must NOT flag it.
///
/// LIVE ENDPOINTS ARE RUNTIME CONFIG (public-safety guard: no private
/// endpoint literals in the tracked tree). Two sources, first found wins:
///   env  H2_PROBE_URL   — the wrong-surface REST endpoint (http://…)
///   env  H2_TUNNEL_HOST — the correct gateway hostname
///   file /tmp/h2_doctor_surface/endpoint   — same, one URL per line:
///       line 1 probe URL, line 2 tunnel host (operator-written, 0600)
/// Both tests skip when their source is absent.
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

    /// Operator-pushed runtime config: `devicectl device copy to
    /// --domain-type appDataContainer --domain-identifier <bundle-id>`
    /// lands the file in the app container's Documents; try that, then the
    /// temporary domain, then the Mac-side operator path (sim runs).
    private static func pushedConfig() -> String? {
        for url in [
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("h2_doctor_surface_endpoint"),
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("h2_doctor_surface_endpoint"),
            URL(fileURLWithPath: "/tmp/h2_doctor_surface_endpoint"),
        ].compactMap({ $0 }) {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static let probeURL: URL? = {
        if let raw = ProcessInfo.processInfo.environment["H2_PROBE_URL"],
           let url = URL(string: raw), url.scheme?.hasPrefix("http") == true {
            return url
        }
        guard let text = pushedConfig(),
              let first = text.split(whereSeparator: \.isNewline).first,
              let url = URL(string: String(first).trimmingCharacters(in: .whitespaces)),
              url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }()

    private static let tunnelHost: String? = {
        if let host = ProcessInfo.processInfo.environment["H2_TUNNEL_HOST"], !host.isEmpty {
            return host
        }
        guard let text = pushedConfig() else { return nil }
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count > 1 else { return nil }
        let host = String(lines[1]).trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? nil : host
    }()

    private var environment: AppEnvironment!

    override func setUpWithError() throws {
        environment = FleetServiceGraph.makeDefaultEnvironment()
    }

    func testApiServerSurfaceTriggersDoctorHintOnDevice() async throws {
        let apiServerURL = try XCTUnwrap(Self.probeURL)
        await environment.load()

        // Arrange: temp gateway at the REST port with a dummy session token.
        // The mint POSTs /api/auth/ws-ticket, which 404s on the api_server
        // surface (route miss) → TransportError.authSurfaceStatus(404) →
        // .unsupported — the exact dogfood path the doctor keys off.
        let probeID = GatewayID(rawValue: "h2-doctor-probe")
        try? await environment.removeGateway(probeID) // idempotent pre-clean
        _ = try await environment.addGateway(
            GatewayRegistration(
                id: probeID,
                displayName: "H2 Doctor Probe",
                endpoint: apiServerURL,
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
        let gatewayHost = try XCTUnwrap(Self.tunnelHost)
        await environment.load()

        // The tunnel endpoint (the CORRECT phone endpoint). If it is
        // registered on this device, its roster refresh must not carry the
        // doctor marker: /health is auth-gated (login HTML), and a healthy
        // gateway never reaches the doctor at all.
        guard let tunnelGateway = environment.gateways.first(where: {
            $0.endpoint?.host == gatewayHost
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
            // A 429 here is the gateway's known login rate limit (10/60s,
            // B1 pacing note) — test amplification, not a wrong surface.
            // Any OTHER unsupported classification would mean the tunnel
            // itself looks like a wrong port, which would be a real defect.
            if detail?.contains("HTTP 429") == false {
                XCTAssertNotEqual(status, .unsupported,
                                  "the tunnel is the correct surface: \(String(describing: detail))")
            }
        case nil:
            XCTFail("tunnel gateway missing from the roster snapshot")
        }
    }
}
#endif
