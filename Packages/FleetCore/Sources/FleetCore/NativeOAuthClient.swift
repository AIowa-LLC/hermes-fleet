import Foundation
import os

/// Client for the gateway-brokered RFC 8252 native OAuth flow.
///
/// Flow (per hermes-agent `hermes_cli/dashboard_auth/native_flow.py` + `routes.py`):
/// 1. Discover session-capable providers via `GET /api/auth/providers`
/// 2. Generate a PKCE pair (S256) and an opaque `state`
/// 3. Start `LoopbackOAuthListener` on `127.0.0.1:<ephemeral>/cb`
/// 4. Present `/auth/native/authorize?provider=&code_challenge=&code_challenge_method=S256&redirect_uri=&state=`
///    in the system browser (injected presenter — `ASWebAuthenticationSession`
///    lives in the app target so this module stays host-testable)
/// 5. Gateway redirects to loopback → listener captures `code`+`state` → 302
///    to `hermes-fleet://oauth-callback`
/// 6. Validate `state`, redeem at `POST /auth/native/token {code, code_verifier}`
/// 7. Store `{access_token, refresh_token, expires_at, provider, user_id}` in
///    Keychain via `OAuthTokenStoring`
///
/// Refresh: `POST /auth/native/refresh {refresh_token, provider}` rotates the
/// pair. A 401 `session_expired` deletes stored tokens and requires re-login.
///
/// This type does not import AuthenticationServices or UIKit.
public actor NativeOAuthClient {
    public let baseURL: URL
    public let tokenStore: any OAuthTokenStoring
    public let gatewayID: GatewayID
    private let urlSession: URLSession
    private let browser: any NativeOAuthBrowserPresenting
    private let log = Logger(subsystem: "com.aiowa.hermesfleet", category: "native-oauth")

    public init(
        baseURL: URL,
        gatewayID: GatewayID,
        tokenStore: any OAuthTokenStoring,
        browser: any NativeOAuthBrowserPresenting,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.gatewayID = gatewayID
        self.tokenStore = tokenStore
        self.browser = browser
        self.urlSession = urlSession
    }

    /// Discover session-capable providers from the gateway.
    public func discoverProviders() async throws -> [OAuthProvider] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/auth/providers"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8

        log.info("NativeOAuth: GET /api/auth/providers (\(Redaction.redactedURL(self.baseURL), privacy: .public))")

        let (data, response) = try await urlSession.data(for: request)
        guard data.count <= 8 * 1024 * 1024 else {
            throw NativeOAuthError.malformedTokenResponse
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NativeOAuthError.authorizeFailed("HTTP \(status)")
        }

        struct ProvidersEnvelope: Codable, Sendable {
            struct Provider: Codable, Sendable {
                let name: String
                let display_name: String?
                let supports_session: Bool?
                let supports_password: Bool?
            }
            let providers: [Provider]
        }

        let envelope: ProvidersEnvelope
        do {
            envelope = try JSONDecoder().decode(ProvidersEnvelope.self, from: data)
        } catch {
            throw NativeOAuthError.malformedTokenResponse
        }
        let sessionProviders = envelope.providers.filter { $0.supports_session == true }
        guard !sessionProviders.isEmpty else {
            throw NativeOAuthError.noSessionProviders
        }
        return sessionProviders.map { provider in
            OAuthProvider(
                name: provider.name,
                displayName: provider.display_name ?? provider.name,
                supportsPassword: provider.supports_password ?? false
            )
        }
    }

    /// Perform the full native OAuth flow and store the resulting token pair.
    ///
    /// When `provider` is nil and exactly one session-capable provider is
    /// advertised, that provider is used. Multiple providers without a
    /// selection fail closed (`multipleProviders`) so the UI can present a
    /// chooser rather than silently picking one.
    public func authenticate(provider: OAuthProvider? = nil) async throws -> OAuthTokenPair {
        let providers = try await discoverProviders()
        let selected: OAuthProvider
        if let provider {
            guard let match = providers.first(where: { $0.name == provider.name }) else {
                throw NativeOAuthError.unknownProvider(provider.name)
            }
            selected = match
        } else if providers.count == 1 {
            selected = providers[0]
        } else {
            throw NativeOAuthError.multipleProviders
        }

        let codeVerifier = PKCE.generateCodeVerifier()
        let codeChallenge = PKCE.codeChallengeS256(for: codeVerifier)
        let state = PKCE.generateCodeVerifier()

        let listener = try await LoopbackOAuthListener()
        let redirectURI = await listener.redirectURI

        var components = URLComponents(
            url: baseURL.appendingPathComponent("auth/native/authorize"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "provider", value: selected.name),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authorizeURL = components?.url else {
            await listener.stop()
            throw NativeOAuthError.internalError("Failed to build authorize URL")
        }

        log.info("NativeOAuth: authorize provider \(selected.name, privacy: .public)")

        let callbackTask = Task { try await listener.waitForCallback() }
        do {
            try await browser.presentAuthorizeURL(authorizeURL)
        } catch let error as NativeOAuthError {
            callbackTask.cancel()
            await listener.stop()
            throw error
        } catch is CancellationError {
            callbackTask.cancel()
            await listener.stop()
            throw NativeOAuthError.cancelled
        } catch {
            callbackTask.cancel()
            await listener.stop()
            throw NativeOAuthError.networkError("browser presentation failed")
        }

        let result: LoopbackOAuthListener.OAuthCallbackResult
        do {
            result = try await callbackTask.value
        } catch {
            await listener.stop()
            throw error
        }
        await listener.stop()

        guard result.state == state else {
            throw NativeOAuthError.stateMismatch
        }
        guard !result.code.isEmpty else {
            throw NativeOAuthError.missingCode
        }

        let tokenPair = try await exchangeCodeForTokens(
            code: result.code,
            codeVerifier: codeVerifier
        )
        try await tokenStore.saveTokenPair(tokenPair, for: gatewayID)
        log.info("NativeOAuth: stored tokens for provider \(selected.name, privacy: .public)")
        return tokenPair
    }

    /// Refresh the access token. A 401 deletes stored tokens and throws
    /// `sessionExpired` so the UI can re-run the authorize flow.
    public func refresh() async throws -> OAuthTokenPair {
        guard let stored = try await tokenStore.loadTokenPair(for: gatewayID) else {
            throw NativeOAuthError.sessionExpired
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("auth/native/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8
        request.httpBody = try JSONEncoder().encode([
            "refresh_token": stored.refreshToken,
            "provider": stored.provider,
        ])

        log.info("NativeOAuth: POST /auth/native/refresh")

        let (data, response) = try await urlSession.data(for: request)
        guard data.count <= 8 * 1024 * 1024 else {
            throw NativeOAuthError.malformedTokenResponse
        }
        guard let http = response as? HTTPURLResponse else {
            throw NativeOAuthError.networkError("Invalid response")
        }
        if http.statusCode == 401 {
            try await tokenStore.deleteTokenPair(for: gatewayID)
            throw NativeOAuthError.sessionExpired
        }
        if http.statusCode == 503 {
            throw NativeOAuthError.providerUnreachable
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NativeOAuthError.tokenExchangeFailed("HTTP \(http.statusCode)")
        }
        let newPair = try decodeTokenPair(from: data)
        try await tokenStore.saveTokenPair(newPair, for: gatewayID)
        return newPair
    }

    /// A valid access token, refreshing first when the stored pair is expired.
    public func validAccessToken() async throws -> String {
        guard var stored = try await tokenStore.loadTokenPair(for: gatewayID) else {
            throw NativeOAuthError.sessionExpired
        }
        if stored.isAccessTokenExpired() {
            stored = try await refresh()
        }
        return stored.accessToken
    }

    /// Delete stored tokens (logout). Missing is a no-op.
    public func logout() async throws {
        try await tokenStore.deleteTokenPair(for: gatewayID)
    }

    // MARK: - Token exchange

    private func exchangeCodeForTokens(code: String, codeVerifier: String) async throws -> OAuthTokenPair {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/native/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8
        request.httpBody = try JSONEncoder().encode([
            "code": code,
            "code_verifier": codeVerifier,
        ])

        log.info("NativeOAuth: POST /auth/native/token")

        let (data, response) = try await urlSession.data(for: request)
        guard data.count <= 8 * 1024 * 1024 else {
            throw NativeOAuthError.malformedTokenResponse
        }
        guard let http = response as? HTTPURLResponse else {
            throw NativeOAuthError.networkError("Invalid response")
        }
        if http.statusCode == 400 {
            throw NativeOAuthError.tokenExchangeFailed("Invalid or expired authorization code")
        }
        if http.statusCode == 503 {
            throw NativeOAuthError.providerUnreachable
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NativeOAuthError.tokenExchangeFailed("HTTP \(http.statusCode)")
        }
        return try decodeTokenPair(from: data)
    }

    private func decodeTokenPair(from data: Data) throws -> OAuthTokenPair {
        struct TokenResponse: Codable, Sendable {
            let access_token: String
            let refresh_token: String
            let token_type: String
            let expires_at: Int
            let provider: String
            let user_id: String
        }
        let decoded: TokenResponse
        do {
            decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw NativeOAuthError.malformedTokenResponse
        }
        guard decoded.token_type.lowercased() == "bearer" else {
            throw NativeOAuthError.malformedTokenResponse
        }
        return OAuthTokenPair(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
            expiresAt: decoded.expires_at,
            provider: decoded.provider,
            userId: decoded.user_id
        )
    }
}
