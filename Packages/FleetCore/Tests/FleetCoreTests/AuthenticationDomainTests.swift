import XCTest
import os
import FleetCore

/// M11 Authentication Hardening domain values: `ConnectionAuthentication`
/// redaction (auth material never prints), `AuthenticationError` vocabulary
/// (no secret material in errors), the `AuthenticationProviding` seam
/// construction, the `Strategy.loopbackToken` vocabulary, and the `Redaction`
/// URL/query scrubber (spec §16, §29).
final class AuthenticationDomainTests: XCTestCase {

    // MARK: ConnectionAuthentication — redaction (spec §16/§29, synthesis §11)

    func testConnectionAuthenticationTicketIsRedacted() {
        let auth = ConnectionAuthentication.ticket(StoredToken(rawValue: "super-secret-ticket"))
        XCTAssertEqual(auth.description, "[REDACTED]")
        XCTAssertEqual(auth.debugDescription, "ConnectionAuthentication(redacted)")
        XCTAssertFalse(auth.description.contains("secret"), "raw value never prints")
        XCTAssertFalse("\(auth)".contains("super-secret"), "interpolation never prints")
    }

    func testConnectionAuthenticationLoopbackIsRedacted() {
        let auth = ConnectionAuthentication.loopbackToken(StoredToken(rawValue: "loop-secret-token"))
        XCTAssertEqual(auth.description, "[REDACTED]")
        XCTAssertFalse("\(auth)".contains("loop-secret"), "interpolation never prints")
    }

    func testConnectionAuthenticationEquality() {
        XCTAssertEqual(
            ConnectionAuthentication.ticket(StoredToken(rawValue: "a")),
            ConnectionAuthentication.ticket(StoredToken(rawValue: "a")))
        XCTAssertNotEqual(
            ConnectionAuthentication.ticket(StoredToken(rawValue: "a")),
            ConnectionAuthentication.ticket(StoredToken(rawValue: "b")))
        XCTAssertNotEqual(
            ConnectionAuthentication.ticket(StoredToken(rawValue: "a")),
            ConnectionAuthentication.loopbackToken(StoredToken(rawValue: "a")))
    }

    /// The "no credentials in cache / logs" structural invariant: the auth
    /// value's secret is carried by `StoredToken`, which is deliberately NOT
    /// Codable — so a `ConnectionAuthentication` can never be serialized into
    /// a SwiftData cache, a file, or a JSON log by accident (synthesis §12).
    func testConnectionAuthenticationCarriesNonCodableStoredToken() {
        let token = StoredToken(rawValue: "x")
        // Compile-time proof: `StoredToken` is not Codable, so attempting to
        // encode it cannot even type-check against `JSONEncoder`.
        XCTAssertNil(token as? Codable)
        XCTAssertFalse(
            ConnectionAuthentication.self is Codable.Type,
            "ConnectionAuthentication must not be Codable")
    }

    // MARK: AuthenticationError — no secret material (spec §29)

    func testAuthenticationErrorVocabulary() {
        XCTAssertEqual(AuthenticationError.notConfigured, .notConfigured)
        XCTAssertEqual(AuthenticationError.ticketExpired, .ticketExpired)
        XCTAssertEqual(AuthenticationError.missingLoopbackToken, .missingLoopbackToken)
        XCTAssertEqual(AuthenticationError.ticketMintFailed("x"), .ticketMintFailed("x"))
        XCTAssertEqual(AuthenticationError.storeUnavailable("y"), .storeUnavailable("y"))
        XCTAssertNotNil(AuthenticationError.ticketExpired.errorDescription)
        // Errors never carry raw secret text by construction (only a
        // caller-provided non-secret detail / vocabulary enum).
        XCTAssertTrue(AuthenticationError.ticketMintFailed("HTTP 401").errorDescription?.contains("HTTP 401") == true)
    }

    // MARK: AuthenticationProviding — seam construction (Sendable-typed, no secret params)

    func testAuthenticationProvidingSeamIsConstructible() {
        struct Stub: AuthenticationProviding {
            func authenticate() async throws -> ConnectionAuthentication { .none }
        }
        let provider: any AuthenticationProviding = Stub()
        let expectation = XCTestExpectation(description: "authenticate")
        Task {
            let auth = try await provider.authenticate()
            XCTAssertEqual(auth, .none)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    // MARK: Strategy — loopbackToken vocabulary (synthesis §11)

    func testLoopbackTokenStrategyCaseExists() {
        XCTAssertEqual(GatewayAuthConfiguration.Strategy.loopbackToken.rawValue, "loopbackToken")
        let config = GatewayAuthConfiguration(strategy: .loopbackToken, credentialStored: true)
        XCTAssertEqual(config.strategy, .loopbackToken)
    }

    // MARK: Redaction — spec §29 (redact credentials + sensitive query params)

    func testRedactionScrubsSensitiveQueryValues() {
        let url = URL(string: "http://192.168.50.58:9119/api/ws?ticket=abc123&channel=chat")!
        let redacted = Redaction.redactedURL(url)
        XCTAssertFalse(redacted.contains("abc123"), "ticket value must never appear")
        XCTAssertTrue(redacted.contains("ticket="), "sensitive key redacted (encoded [REDACTED] or raw)")
        XCTAssertTrue(redacted.contains("channel=chat"), "non-secret query preserved")
        XCTAssertTrue(redacted.contains("192.168.50.58"), "host preserved for §30 classification")
    }

    func testRedactionScrubsTokenAndAccessToken() {
        let url = URL(string: "https://gw.example.com/api/ws?token=loopsecret&access_token=ats&foo=1")!
        let redacted = Redaction.redactedURL(url)
        XCTAssertFalse(redacted.contains("loopsecret"))
        XCTAssertFalse(redacted.contains("ats"))
        XCTAssertTrue(redacted.contains("token="))
        XCTAssertTrue(redacted.contains("access_token="))
        XCTAssertTrue(redacted.contains("foo=1"))
    }

    func testRedactionLeavesNonSensitiveURLsUnchanged() {
        let url = URL(string: "http://192.168.50.58:8642/profiles.list?limit=10")!
        let redacted = Redaction.redactedURL(url)
        XCTAssertTrue(redacted.contains("limit=10"))
    }

    // MARK: P1-6 — user-info / password never survive redaction (spec §29)

    func testRedactionStripsURLUserInfoPassword() {
        // A pasted endpoint with embedded credentials must not print the
        // user:password@ half of the URL (red-team P1-6).
        let url = URL(string: "http://alice:super-secret-pw@192.168.50.58:9119/api/ws")!
        let redacted = Redaction.redactedURL(url)
        XCTAssertFalse(redacted.contains("super-secret-pw"), "URL password must never be printed")
        XCTAssertFalse(redacted.contains("alice:"), "URL user-info must be stripped")
        XCTAssertFalse(redacted.contains("@"), "the user-info delimiter must not survive")
        XCTAssertTrue(redacted.contains("192.168.50.58"), "host preserved for §30 classification")
    }

    func testRedactionStripsUserInfoAndStillRedactsSensitiveQuery() {
        // user-info + a secret query key together: BOTH must be scrubbed.
        let url = URL(string: "http://user:pass@192.168.50.58:9119/api/ws?ticket=abc123&channel=chat")!
        let redacted = Redaction.redactedURL(url)
        XCTAssertFalse(redacted.contains("pass"))
        XCTAssertFalse(redacted.contains("user:"))
        XCTAssertFalse(redacted.contains("abc123"), "ticket value never appears")
        XCTAssertTrue(redacted.contains("ticket="), "sensitive key redacted")
        XCTAssertTrue(redacted.contains("channel=chat"), "non-secret query preserved")
        XCTAssertTrue(redacted.contains("192.168.50.58"), "host preserved")
    }

    func testRedactionPlaceholderValue() {
        XCTAssertEqual(Redaction.redacted("anything"), "[REDACTED]")
    }
}
