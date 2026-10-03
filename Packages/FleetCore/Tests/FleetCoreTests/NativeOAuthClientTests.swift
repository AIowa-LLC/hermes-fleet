import XCTest
@testable import FleetCore

/// Native OAuth client construction and stored-token fail-closed paths.
/// Synthetic fixtures only — no live tokens or hostnames.
final class NativeOAuthClientTests: XCTestCase {

    func testClientConstructionPreservesIdentity() async {
        let baseURL = URL(string: "https://gateway.example.invalid")!
        let gatewayID = GatewayID(rawValue: "test-gateway")
        let store = InMemoryOAuthTokenStoreForTests()
        let client = NativeOAuthClient(
            baseURL: baseURL,
            gatewayID: gatewayID,
            tokenStore: store,
            browser: NeverPresentingBrowser()
        )
        let storedBase = await client.baseURL
        let storedID = await client.gatewayID
        XCTAssertEqual(storedBase, baseURL)
        XCTAssertEqual(storedID, gatewayID)
    }

    func testValidAccessTokenThrowsWhenNothingStored() async {
        let client = NativeOAuthClient(
            baseURL: URL(string: "https://gateway.example.invalid")!,
            gatewayID: GatewayID(rawValue: "test-gateway"),
            tokenStore: InMemoryOAuthTokenStoreForTests(),
            browser: NeverPresentingBrowser()
        )
        do {
            _ = try await client.validAccessToken()
            XCTFail("expected sessionExpired")
        } catch NativeOAuthError.sessionExpired {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testValidAccessTokenReturnsUnexpiredStoredTokenWithoutNetwork() async throws {
        let store = InMemoryOAuthTokenStoreForTests()
        let gatewayID = GatewayID(rawValue: "test-gateway")
        let pair = OAuthTokenPair(
            accessToken: "access-live",
            refreshToken: "refresh-live",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600,
            provider: "nous",
            userId: "user"
        )
        try await store.saveTokenPair(pair, for: gatewayID)
        let client = NativeOAuthClient(
            baseURL: URL(string: "https://gateway.example.invalid")!,
            gatewayID: gatewayID,
            tokenStore: store,
            browser: NeverPresentingBrowser()
        )
        let token = try await client.validAccessToken()
        XCTAssertEqual(token, "access-live")
    }

    func testLogoutDeletesStoredPair() async throws {
        let store = InMemoryOAuthTokenStoreForTests()
        let gatewayID = GatewayID(rawValue: "test-gateway")
        try await store.saveTokenPair(
            OAuthTokenPair(
                accessToken: "a", refreshToken: "r",
                expiresAt: Int(Date().timeIntervalSince1970) + 3600,
                provider: "nous", userId: "user"
            ),
            for: gatewayID
        )
        let client = NativeOAuthClient(
            baseURL: URL(string: "https://gateway.example.invalid")!,
            gatewayID: gatewayID,
            tokenStore: store,
            browser: NeverPresentingBrowser()
        )
        try await client.logout()
        let loaded = try await store.loadTokenPair(for: gatewayID)
        XCTAssertNil(loaded)
    }
}

private final class InMemoryOAuthTokenStoreForTests: OAuthTokenStoring, @unchecked Sendable {
    private var storage: [String: OAuthTokenPair] = [:]

    func saveTokenPair(_ pair: OAuthTokenPair, for gatewayID: GatewayID) async throws {
        storage[gatewayID.rawValue] = pair
    }

    func loadTokenPair(for gatewayID: GatewayID) async throws -> OAuthTokenPair? {
        storage[gatewayID.rawValue]
    }

    func deleteTokenPair(for gatewayID: GatewayID) async throws {
        storage.removeValue(forKey: gatewayID.rawValue)
    }
}

private struct NeverPresentingBrowser: NativeOAuthBrowserPresenting {
    func presentAuthorizeURL(_ url: URL) async throws {
        throw NativeOAuthError.cancelled
    }
}
