import XCTest
@testable import HermesFleetApp

/// F1 LIVE device probe (t_10831eec): proves on Tony's REAL iPhone that the
/// new ATS exceptions let the app binary reach the Arch gateway #2 tailnet
/// surface over cleartext http://.
///
/// P0-5 history: a missing NSExceptionDomains entry makes URLSession silently
/// fail cleartext connects — this probe is the on-device proof the exception
/// works (status 200 from the pre-auth providers endpoint, no credentials).
///
/// DEVICE-ONLY: `#if !targetEnvironment(simulator)` so the simulator-based CI
/// unit bundle auto-excludes it (the sim cannot reach the tailnet directly —
/// iOS local-network privacy; see T2/P0-7 forwarder pattern). Run on device:
///   xcodebuild test -destination 'platform=iOS,id=<UDID>' \
///     -only-testing:HermesFleetAppTests/F1LiveATSProbeTests
#if !targetEnvironment(simulator)
final class F1LiveATSProbeTests: XCTestCase {

    private func probe(_ endpoint: String) async throws {
        let url = try XCTUnwrap(URL(string: endpoint + "/api/auth/providers"),
                                "bad probe endpoint")
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200,
                       "\(endpoint) must be reachable through ATS (got \(http.statusCode)) — a silent failure here means the NSExceptionDomains entry is missing")
    }

    /// Arch gateway #2 — tailnet IP surface.
    func testArchTailnetIPReachableThroughATS() async throws {
        try await probe("http://<tailnet-ip>:9119")
    }

    /// Arch gateway #2 — MagicDNS hostname surface.
    func testArchTailnetHostnameReachableThroughATS() async throws {
        try await probe("http://<private-host>:9119")
    }
}
#endif
