import XCTest
@testable import FleetCore

/// P0-A (RC-84) — the diagnostics-specific sanitizer: a strict superset of
/// `safeText` that also masks WebSocket URL user-info (wss:// tickets) and
/// header-style key material. Each case pins "the secret must not survive".
final class DiagnosticRedactionTests: XCTestCase {

    func testWebSocketUserInfoNeverSurvives() {
        let text = "connect wss://hermes:ticket-abc123@gateway.local:9119/ws failed"
        let safe = Redaction.safeDiagnosticText(text)
        XCTAssertFalse(safe.contains("ticket-abc123"))
        XCTAssertFalse(safe.contains("hermes:"))
        XCTAssertTrue(safe.contains("gateway.local:9119"), "host stays readable for support")
    }

    func testWebSocketUserOnlyFormNeverSurvives() {
        let text = "ws://agent-7@10.0.0.4:9119/ws"
        let safe = Redaction.safeDiagnosticText(text)
        XCTAssertFalse(safe.contains("agent-7"))
        XCTAssertTrue(safe.contains("10.0.0.4"))
    }

    func testHeaderStyleKeyMaterialNeverSurvives() {
        let text = "x-api-key: SECRETKEY123 private-token: GLPAT456"
        let safe = Redaction.safeDiagnosticText(text)
        XCTAssertFalse(safe.contains("SECRETKEY123"))
        XCTAssertFalse(safe.contains("GLPAT456"))
        XCTAssertTrue(safe.contains("x-api-key"), "header name stays readable")
    }

    func testQueryAndBearerSecretsStillCovered() {
        let text = "GET https://api.example/ws?ticket=abc123 Authorization: Bearer tok-987"
        let safe = Redaction.safeDiagnosticText(text)
        XCTAssertFalse(safe.contains("abc123"))
        XCTAssertFalse(safe.contains("tok-987"))
    }

    func testSanitizerIsIdempotent() {
        let text = "wss://u:p@h.local/ws?ticket=zzz9 x-api-key: KEY99"
        let once = Redaction.safeDiagnosticText(text)
        XCTAssertEqual(Redaction.safeDiagnosticText(once), once)
    }

    func testSharedReportSanitizerMasksEndpointHostAndPath() {
        let text = "failed at https://user:pass@gateway.example:8765/private/path?ticket=secret-value"
        let once = Redaction.safeDiagnosticReportText(text)

        XCTAssertEqual(once, "failed at [ENDPOINT REDACTED]")
        XCTAssertFalse(once.contains("gateway.example"))
        XCTAssertFalse(once.contains("private/path"))
        XCTAssertFalse(once.contains("secret-value"))
        XCTAssertEqual(Redaction.safeDiagnosticReportText(once), once)
    }

    func testPlainTextIsUnchanged() {
        let text = "Roster refresh: MacBook answered — 3 bots"
        XCTAssertEqual(Redaction.safeDiagnosticText(text), text)
    }

    // MARK: - Build 96 follow-up: cancellation vs. user-facing text

    private func urlError(_ code: Int, url: String = "https://gw.example.test:9119/api/auth/providers") -> NSError {
        NSError(domain: NSURLErrorDomain, code: code, userInfo: [
            NSLocalizedDescriptionKey: code == NSURLErrorCancelled ? "cancelled" : "The Internet connection appears to be offline.",
            NSURLErrorFailingURLStringErrorKey: url,
            "_NSURLErrorRelatedURLSessionTaskErrorKey": ["LocalDataTask <SYNTHETIC-ID>.<1>"],
        ])
    }

    func testCancellationIsRecognisedOnlyForCancelShapes() {
        XCTAssertTrue(Redaction.isCancellation(CancellationError()))
        XCTAssertTrue(Redaction.isCancellation(urlError(NSURLErrorCancelled)))
        XCTAssertTrue(Redaction.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(Redaction.isCancellation(urlError(NSURLErrorNotConnectedToInternet)))
        XCTAssertFalse(Redaction.isCancellation(URLError(.timedOut)))
        XCTAssertFalse(Redaction.isCancellation(NSError(domain: "Other", code: NSURLErrorCancelled)))
    }

    func testUserFacingDescriptionOmitsEndpointAndRequestIdentifiers() {
        let text = Redaction.userFacingErrorDescription(urlError(NSURLErrorNotConnectedToInternet))
        XCTAssertEqual(text, "The Internet connection appears to be offline.")
        XCTAssertFalse(text.contains("gw.example.test"))
        XCTAssertFalse(text.contains("SYNTHETIC-ID"))
    }

    func testSafeErrorDescriptionFallbackIsUnchangedForGenericConsumers() {
        // The verbose fallback is intentionally left alone for other callers.
        let text = Redaction.safeErrorDescription(urlError(NSURLErrorNotConnectedToInternet))
        XCTAssertTrue(text.contains("NSURLErrorDomain"))
    }
}
