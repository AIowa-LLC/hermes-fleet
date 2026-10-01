import Foundation
import FleetCore

/// Concrete `AuthenticationProviding` for the gateway-brokered RFC 8252
/// native OAuth flow (strategy `.oauthNative`).
///
/// Loads a stored token pair, refreshes if expired, then mints a single-use
/// WS ticket with `Authorization: Bearer <access_token>` on
/// `POST /api/auth/ws-ticket`. A `sessionExpired` refresh failure maps to
/// `AuthenticationError.missingLoopbackToken` so the UI can re-run sign-in
/// without leaking token material.
public struct NativeOAuthAuthenticator: AuthenticationProviding {
    public let gatewayID: GatewayID
    private let oauthClient: NativeOAuthClient
    private let ticketMinter: any WSTicketMinting

    public init(
        gatewayID: GatewayID,
        oauthClient: NativeOAuthClient,
        ticketMinter: any WSTicketMinting
    ) {
        self.gatewayID = gatewayID
        self.oauthClient = oauthClient
        self.ticketMinter = ticketMinter
    }

    public func authenticate() async throws -> ConnectionAuthentication {
        do {
            _ = try await oauthClient.validAccessToken()
        } catch NativeOAuthError.sessionExpired {
            throw AuthenticationError.missingLoopbackToken
        } catch {
            throw AuthenticationError.storeUnavailable("oauth refresh failed")
        }

        let ticket: WSTicket
        do {
            ticket = try await ticketMinter.mintTicket()
        } catch {
            throw AuthenticationError.ticketMintFailed("oauth ticket mint failed")
        }
        guard !ticket.isExpired() else {
            throw AuthenticationError.ticketExpired
        }
        return .ticket(StoredToken(rawValue: ticket.token))
    }
}
