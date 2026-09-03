import XCTest
@testable import HermesFleetApp

/// F2 (t_b678fb38) — LIVE tunnel probe: proves the app binary reaches the
/// converged public HTTPS surface (`https://<legacy-fleet-endpoint>`) with NO
/// ATS exceptions needed — the default ATS policy itself allows it.
///
/// F1 history: this probe asserted the private tailnet hosts were reachable
/// through their (now-stripped) raw-IP NSExceptionDomains entries. F2
/// converges the fleet on the tunnel; the pre-auth providers endpoint must
/// answer 200 over TLS from the app sandbox with zero per-domain ATS
/// configuration.
///
/// DEVICE-ONLY: `#if !targetEnvironment(simulator)` so the simulator-based
/// CI unit bundle auto-excludes it (the probe requires the live tunnel).
/// Run on device:
///   xcodebuild test -destination 'platform=iOS,id=<UDID>' \
///     -only-testing:HermesFleetAppTests/F1LiveATSProbeTests
#if !targetEnvironment(simulator)
final class F1LiveATSProbeTests: XCTestCase {

    /// The converged endpoint, read from the app's shipped configuration
    /// (data, not a compiled Swift literal).
    private var endpoint: String {
        Bundle.main.object(forInfoDictionaryKey: "FleetDefaultEndpoint") as? String ?? ""
    }

    private func probe(_ endpoint: String) async throws {
        let url = try XCTUnwrap(URL(string: endpoint + "/api/auth/providers"),
                                "bad probe endpoint")
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200,
                       "\(endpoint) must be reachable over HTTPS under DEFAULT ATS (got \(http.statusCode)) — the converged tunnel is down or ATS-regressed")
    }

    func testTunnelProvidersReachableOverHTTPS() async throws {
        try await probe(endpoint)
    }
}
#endif
