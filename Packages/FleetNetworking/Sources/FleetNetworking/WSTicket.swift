import Foundation

/// A short-lived, single-use WebSocket upgrade ticket minted by the gateway.
///
/// Wire contract (verified in `hermes_cli/dashboard_auth/routes.py:932` and
/// `ws_tickets.py`): `POST {base}/api/auth/ws-ticket` → `{"ticket": "...",
/// "ttl_seconds": 30}`. The ticket is base64url, single-use, TTL 30s — a
/// fresh ticket must be minted immediately before every WebSocket connect.
public struct WSTicket: Sendable, Hashable, Equatable {
    public let token: String
    public let ttlSeconds: Int

    public init(token: String, ttlSeconds: Int) {
        self.token = token
        self.ttlSeconds = ttlSeconds
    }

    /// The auth query param to attach: `?ticket=<token>`.
    public var authQueryItem: URLQueryItem { URLQueryItem(name: "ticket", value: token) }
}

/// Abstraction over ticket minting so the transport can be tested with a
/// fixture and swapped for a real REST client in the app.
public protocol WSTicketMinting: Sendable {
    func mintTicket() async throws -> WSTicket
}

/// Real REST client for `POST /api/auth/ws-ticket`.
///
/// Auth modes match the SPA (`web/src/lib/api.ts`): loopback sends the
/// `X-Hermes-Session-Token` header; gated OAuth sends the `hermes_session_at`
/// cookie. M1 implements the header path (native clients set headers on REST
/// calls); cookie handling is a later milestone and out of M1 scope.
public struct WSTicketClient: WSTicketMinting {
    public let baseURL: URL
    public let sessionToken: String?
    public let urlSession: URLSession

    public init(baseURL: URL, sessionToken: String?, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.sessionToken = sessionToken
        self.urlSession = urlSession
    }

    public enum TicketMintError: Error, Sendable, Equatable, LocalizedError {
        case httpStatus(Int)
        case malformedResponse
        case missingTicket
        case missingTTL

        public var errorDescription: String? {
            switch self {
            case .httpStatus(let code): return "/api/auth/ws-ticket: HTTP \(code)"
            case .malformedResponse: return "/api/auth/ws-ticket: malformed body"
            case .missingTicket: return "/api/auth/ws-ticket: missing ticket"
            case .missingTTL: return "/api/auth/ws-ticket: missing ttl_seconds"
            }
        }
    }

    private struct TicketEnvelope: Codable, Sendable {
        let ticket: String?
        let ttl_seconds: Int?
    }

    public func mintTicket() async throws -> WSTicket {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/auth/ws-ticket"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Hermes-Session-Token")
        }

        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TicketMintError.httpStatus(http.statusCode)
        }
        let envelope: TicketEnvelope
        do {
            envelope = try JSONDecoder().decode(TicketEnvelope.self, from: data)
        } catch {
            throw TicketMintError.malformedResponse
        }
        guard let ticket = envelope.ticket, !ticket.isEmpty else {
            throw TicketMintError.missingTicket
        }
        guard let ttl = envelope.ttl_seconds else {
            throw TicketMintError.missingTTL
        }
        return WSTicket(token: ticket, ttlSeconds: ttl)
    }
}
