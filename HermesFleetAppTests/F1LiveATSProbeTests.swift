import XCTest
@testable import HermesFleetApp

/// LIVE endpoint probe: proves the app binary reaches an HTTPS gateway
/// surface with NO ATS exceptions needed — the default ATS policy itself
/// allows it.
///
/// OPT-IN: the probe requires `HERMES_FLEET_LIVE_ENDPOINT` (a public HTTPS
/// origin you control) in the test-runner environment. When the variable is
/// absent the probe SKIPs — it never falls back to any compiled or
/// maintainer-owned endpoint.
///
/// F1/F2 history: this probe asserted a maintainer-owned tunnel and private
/// tailnet hosts. The public-release pass made the endpoint fully external:
/// run it against your own gateway with
///   HERMES_FLEET_LIVE_ENDPOINT=https://your-gateway.example.net \
///   xcodebuild test -destination 'platform=iOS,id=<UDID>' \
///     -only-testing:HermesFleetAppTests/F1LiveATSProbeTests
#if !targetEnvironment(simulator)
final class F1LiveATSProbeTests: XCTestCase {

    /// The live endpoint, supplied explicitly via environment (never a
    /// compiled or maintainer-owned literal).
    private var endpoint: String {
        ProcessInfo.processInfo.environment["HERMES_FLEET_LIVE_ENDPOINT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

    func testLiveProvidersReachableOverHTTPS() async throws {
        guard !endpoint.isEmpty else {
            throw XCTSkip("HERMES_FLEET_LIVE_ENDPOINT not set — live ATS probe is opt-in (point it at your own HTTPS gateway)")
        }
        try await probe(endpoint)
    }
}
#endif
