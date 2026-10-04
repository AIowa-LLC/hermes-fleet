import XCTest
@testable import FleetCore

/// PKCE (RFC 7636) and OAuth token-pair domain tests. Synthetic fixtures
/// only — no live tokens or hostnames.
final class PKCETests: XCTestCase {

    func testCodeVerifierIsBase64URLWithoutPadding() {
        let verifier = PKCE.generateCodeVerifier()
        XCTAssertFalse(verifier.contains("+"))
        XCTAssertFalse(verifier.contains("/"))
        XCTAssertFalse(verifier.contains("="))
        XCTAssertGreaterThanOrEqual(verifier.count, 100)
        XCTAssertLessThanOrEqual(verifier.count, 150)
    }

    func testCodeVerifierIsUnique() {
        var verifiers = Set<String>()
        for _ in 0..<100 {
            verifiers.insert(PKCE.generateCodeVerifier())
        }
        XCTAssertEqual(verifiers.count, 100)
    }

    func testCodeChallengeFormat() {
        let challenge = PKCE.codeChallengeS256(for: "test_verifier_123")
        XCTAssertFalse(challenge.contains("+"))
        XCTAssertFalse(challenge.contains("/"))
        XCTAssertFalse(challenge.contains("="))
        XCTAssertEqual(challenge.count, 43)
    }

    func testCodeChallengeIsDeterministic() {
        let verifier = "fixed_verifier_for_testing"
        XCTAssertEqual(
            PKCE.codeChallengeS256(for: verifier),
            PKCE.codeChallengeS256(for: verifier)
        )
    }

    /// RFC 7636 Appendix B test vector.
    func testCodeChallengeMatchesRFC7636AppendixB() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        XCTAssertEqual(PKCE.codeChallengeS256(for: verifier), expected)
    }
}

final class OAuthTokenPairTests: XCTestCase {

    func testAccessTokenNotExpiredForFutureExpiry() {
        let pair = OAuthTokenPair(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600,
            provider: "nous",
            userId: "user"
        )
        XCTAssertFalse(pair.isAccessTokenExpired())
    }

    func testAccessTokenExpiredForPastExpiry() {
        let pair = OAuthTokenPair(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Int(Date().timeIntervalSince1970) - 3600,
            provider: "nous",
            userId: "user"
        )
        XCTAssertTrue(pair.isAccessTokenExpired())
    }

    func testAccessTokenExpiredAccountsForThirtySecondSkew() {
        let pair = OAuthTokenPair(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Int(Date().timeIntervalSince1970) + 20,
            provider: "nous",
            userId: "user"
        )
        XCTAssertTrue(pair.isAccessTokenExpired())
    }

    func testDescriptionIsRedacted() {
        let pair = OAuthTokenPair(
            accessToken: "secret_access",
            refreshToken: "secret_refresh",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600,
            provider: "nous",
            userId: "user"
        )
        XCTAssertEqual(pair.description, "[REDACTED]")
        XCTAssertEqual(pair.debugDescription, "OAuthTokenPair(redacted)")
        XCTAssertFalse(pair.description.contains("secret_access"))
        XCTAssertFalse("\(pair)".contains("secret_refresh"))
    }
}

final class NativeOAuthErrorTests: XCTestCase {

    func testErrorTextCarriesNoSecrets() {
        let errors: [NativeOAuthError] = [
            .noSessionProviders,
            .unknownProvider("nous"),
            .multipleProviders,
            .cancelled,
            .callbackTimeout,
            .missingCode,
            .stateMismatch,
            .sessionExpired,
            .providerUnreachable,
            .tokenExchangeFailed("HTTP 400"),
            .malformedTokenResponse,
        ]
        for error in errors {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.contains("sk-"), "error text must not look like a token: \(text)")
            XCTAssertFalse(text.contains("Bearer "), "error text must not echo a bearer token: \(text)")
        }
    }
}
