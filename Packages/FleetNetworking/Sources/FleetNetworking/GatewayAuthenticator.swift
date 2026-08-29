import Foundation
import FleetCore

/// Concrete `AuthenticationProviding` for a registered gateway (v0 concrete
/// of synthesis §11 / spec §16):
///
/// - `.sessionToken` / `.bearerToken` strategy → mint a single-use 30s WS
///   ticket via `WSTicketMinting` (`POST /api/auth/ws-ticket`), enforce the
///   client-side TTL, and return `.ticket(StoredToken)` → `?ticket=`.
/// - `.loopbackToken` strategy → load the stored loopback token via
///   `TokenStoring` (Keychain) and return `.loopbackToken(StoredToken)` →
///   `?token=`.
/// - `.none` → `.none` (no auth query).
///
/// Safety (spec §16/§29): the provider never logs or echoes the raw ticket or
/// token — `ConnectionAuthentication` redacts its printable representation and
/// is not Codable, so auth material can never reach logs, cache, or UI.
public struct GatewayAuthenticator: AuthenticationProviding {
    /// The gateway this provider authenticates for (loopback token lookup is
    /// per-peer in the token store).
    public let gatewayID: GatewayID
    /// The gateway's authentication strategy.
    public let strategy: GatewayAuthConfiguration.Strategy
    /// Mints single-use WS tickets (session-token/bearer strategy).
    private let ticketMinter: (any WSTicketMinting)?
    /// Loads stored loopback tokens from Keychain (loopback strategy).
    private let tokenStore: (any TokenStoring)?

    public init(
        gatewayID: GatewayID,
        strategy: GatewayAuthConfiguration.Strategy,
        ticketMinter: (any WSTicketMinting)? = nil,
        tokenStore: (any TokenStoring)? = nil
    ) {
        self.gatewayID = gatewayID
        self.strategy = strategy
        self.ticketMinter = ticketMinter
        self.tokenStore = tokenStore
    }

    public func authenticate() async throws -> ConnectionAuthentication {
        switch strategy {
        case .none:
            return .none
        case .loopbackToken:
            guard let tokenStore else {
                throw AuthenticationError.notConfigured
            }
            guard let token = try await tokenStore.loadToken(for: gatewayID) else {
                throw AuthenticationError.missingLoopbackToken
            }
            return .loopbackToken(token)
        case .sessionToken, .bearerToken:
            guard let ticketMinter else {
                throw AuthenticationError.notConfigured
            }
            let ticket = try await ticketMinter.mintTicket()
            // Single-use + 30s TTL (synthesis §11): never connect with a
            // stale ticket — re-mint instead.
            guard !ticket.isExpired() else {
                throw AuthenticationError.ticketExpired
            }
            return .ticket(StoredToken(rawValue: ticket.token))
        }
    }
}

/// Adapter from a plain `WSTicketMinting` to `AuthenticationProviding`, so the
/// transport's legacy `ticketMinter:` init and existing tests keep working
/// while the seam is the auth provider. Mints a single-use ticket, enforces
/// TTL, returns `.ticket`.
public struct TicketOnlyAuthenticator: AuthenticationProviding {
    private let ticketMinter: any WSTicketMinting

    public init(ticketMinter: any WSTicketMinting) {
        self.ticketMinter = ticketMinter
    }

    public func authenticate() async throws -> ConnectionAuthentication {
        let ticket = try await ticketMinter.mintTicket()
        guard !ticket.isExpired() else {
            throw AuthenticationError.ticketExpired
        }
        return .ticket(StoredToken(rawValue: ticket.token))
    }
}
