import XCTest
import FleetCore
import FleetUI

/// F1 (t_e41b16e0) — cause-differentiated connection-failure copy
/// (apple-design D1 audit). Every failure surface renders the SAME mapping
/// from the classified §13 status to a one-line, sentence-case, actionable
/// sentence. The compact pill label stays short; the CAUSE lives in the
/// detail line. No raw endpoint or secret is ever echoed.
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
        // The exact Tony case: 8642 answers TCP but 404s every app route.
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

    // MARK: P0-9 (t_635bbf99) — strategy-mismatch copy is cause-specific

    func testAuthStrategyMismatchCopySaysUsernamePasswordNotToken() {
        // The exact tunnel defect: ws-ticket 401 {"reason":"no_cookie"} —
        // the saved sign-in method is a token, but this gateway only accepts
        // username & password. Generic "Re-authenticate" guidance would loop
        // the same failure, so the copy must name the fix.
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
        // The detail string is non-secret by construction, but the copy must
        // not repeat the endpoint either — the row already shows it redacted.
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
}
