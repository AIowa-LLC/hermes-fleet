import XCTest
import FleetCore
import FleetUI

/// Cause-differentiated connection-failure copy. Every failure surface renders
/// the same mapping from classified gateway status to a concise, actionable
/// sentence. Compact status labels stay short; the detail line carries the
/// cause without echoing endpoints or secrets.
final class F1FailureCopyTests: XCTestCase {

    func testTimeoutCopySaysTimeoutAndIsActionable() {
        let copy = GatewayFailureCopy.detail(
            status: .offline,
            detail: "gateway connect timed out",
            gatewayName: "Arch #2")
        XCTAssertTrue(copy.contains("timed out"), copy)
        XCTAssertTrue(copy.contains("Arch #2"), copy)
        XCTAssertTrue(copy.contains("Check"), "must say what to do: \(copy)")
    }

    func testWrongPort404CopySaysAnsweredButNotServing() {
        // A reachable TCP port that returns HTTP 404 is an unsupported gateway
        // surface, not a timeout.
        let copy = GatewayFailureCopy.detail(
            status: .unsupported,
            detail: "auth endpoint returned HTTP 404")
        XCTAssertTrue(copy.contains("answered"), copy)
        XCTAssertTrue(copy.contains("isn't serving"), copy)
        XCTAssertTrue(copy.contains("port"), copy)
        XCTAssertFalse(copy.lowercased().contains("timed out"),
                       "a 404 must NOT be reported as a timeout: \(copy)")
    }

    func testAuthRequiredCopySaysSignIn() {
        let copy = GatewayFailureCopy.detail(
            status: .authenticationRequired,
            detail: "auth endpoint returned HTTP 401")
        XCTAssertTrue(copy.contains("sign in"), copy)
        XCTAssertTrue(copy.contains("Re-authenticate"), copy)
    }

    func testAuthStrategyMismatchCopySaysUsernamePasswordNotToken() {
        // A token-based sign-in against a gateway that requires username and
        // password should name the strategy mismatch instead of suggesting the
        // same authentication attempt again.
        let copy = GatewayFailureCopy.detail(
            status: .authenticationRequired,
            detail: "auth rejected: no_cookie")
        XCTAssertTrue(copy.contains("username & password"), copy)
        XCTAssertTrue(copy.contains("sign-in"), copy)
        XCTAssertFalse(copy.contains("Re-authenticate"),
                       "a strategy mismatch must not tell the user to re-authenticate the same token: \(copy)")
    }

    func testAuthStrategyMismatchCopyNeverEchoesSecrets() {
        let copy = GatewayFailureCopy.detail(
            status: .authenticationRequired,
            detail: "auth rejected: no_cookie")
        XCTAssertFalse(copy.lowercased().contains("password="), copy)
        XCTAssertFalse(copy.lowercased().contains("token="), copy)
        XCTAssertFalse(copy.contains("no_cookie"),
                       "raw server vocabulary stays out of user copy: \(copy)")
    }

    func testDegradedCopyMentionsServerError() {
        let copy = GatewayFailureCopy.detail(
            status: .degraded,
            detail: "server error (1011)")
        XCTAssertTrue(copy.contains("server error"), copy)
    }

    func testCopyNeverEchoesEndpointHost() {
        let cases: [(GatewayStatus, String?)] = [
            (.offline, "connection to 100.127.200.89:8642 timed out"),
            (.unsupported, "auth endpoint returned HTTP 404"),
            (.authenticationRequired, "auth endpoint returned HTTP 401"),
        ]
        for (status, detail) in cases {
            let copy = GatewayFailureCopy.detail(status: status, detail: detail)
            XCTAssertFalse(copy.contains("100.127.200.89"),
                          "copy must not echo the endpoint host: \(copy)")
            XCTAssertFalse(copy.contains("8642"),
                          "copy must not echo the endpoint port: \(copy)")
        }
    }

    func testNilDetailFallsBackToCauseCopy() {
        let copy = GatewayFailureCopy.detail(status: .offline, detail: nil)
        XCTAssertTrue(copy.contains("timed out"), copy)
    }

    // MARK: H2 surface doctor (t_eb6b573d)

    func testSurfaceDoctorHitNamesHermesServerNotChatGateway() {
        // ws-ticket 404 + /health 200 hermes-agent: the endpoint IS a Hermes
        // box — the copy must say which surface was hit and what to ask for.
        let copy = GatewayFailureCopy.detail(
            status: .unsupported,
            detail: "auth endpoint returned HTTP 404 (/health: hermes-agent)")
        XCTAssertTrue(copy.contains("Hermes server"), copy)
        XCTAssertTrue(copy.contains("not the chat gateway"), copy)
        XCTAssertTrue(copy.contains("gateway"), copy)
        XCTAssertFalse(copy.lowercased().contains("timed out"), copy)
    }

    func testSurfaceDoctorCopyNeverLeaksMarkerOrInternals() {
        let copy = GatewayFailureCopy.detail(
            status: .unsupported,
            detail: "auth endpoint returned HTTP 404 (/health: hermes-agent)")
        XCTAssertFalse(copy.contains("/health"), "raw route names stay out of user copy: \(copy)")
        XCTAssertFalse(copy.contains("hermes-agent"), "raw platform vocabulary stays out: \(copy)")
        XCTAssertFalse(copy.contains("HTTP 404"), "raw status codes stay out: \(copy)")
        XCTAssertFalse(copy.contains("api_server"), copy)
    }

    func testUnsupportedWithoutDoctorHitKeepsGenericCopy() {
        // ws-ticket 404 and NO doctor marker → the existing F1 wrong-port copy,
        // never the doctor hint.
        let copy = GatewayFailureCopy.detail(
            status: .unsupported,
            detail: "auth endpoint returned HTTP 404")
        XCTAssertFalse(copy.contains("Hermes server"), copy)
        XCTAssertTrue(copy.contains("isn't serving the app"), copy)
        // And a non-404 unsupported detail (disconnect-classified) keeps the
        // generic surface copy.
        let generic = GatewayFailureCopy.detail(
            status: .unsupported,
            detail: "unsupported gateway: chat disabled")
        XCTAssertFalse(generic.contains("Hermes server"), generic)
        XCTAssertTrue(generic.contains("isn't a supported Hermes surface"), generic)
    }

    func testTimeoutCopyUnchangedByDoctor() {
        // Timeout classification never reaches the doctor; copy is unchanged.
        let copy = GatewayFailureCopy.detail(
            status: .offline,
            detail: "gateway connect timed out (/health: hermes-agent)")
        XCTAssertTrue(copy.contains("timed out"), copy)
        XCTAssertFalse(copy.contains("Hermes server"), copy)
    }
}
