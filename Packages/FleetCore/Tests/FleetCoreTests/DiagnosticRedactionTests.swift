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

    func testPlainTextIsUnchanged() {
        let text = "Roster refresh: MacBook answered — 3 bots"
        XCTAssertEqual(Redaction.safeDiagnosticText(text), text)
    }
}