import Foundation
import os
import FleetCore

/// A short-lived, single-use WebSocket upgrade ticket minted by the gateway.
///
/// Wire contract (verified in `hermes_cli/dashboard_auth/routes.py:932` and
/// `ws_tickets.py`): `POST {base}/api/auth/ws-ticket` → `{"ticket": "...",
/// "ttl_seconds": 30}`. The ticket is base64url, single-use, TTL 30s — a
/// fresh ticket must be minted immediately before every WebSocket connect.
public struct WSTicket: Sendable, Hashable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let token: String
    public let ttlSeconds: Int
    /// When this ticket was minted, for client-side TTL enforcement
    /// (single-use, 30s TTL — synthesis §11; never connect with a stale
    /// ticket). Defaults to now so existing call sites stay unchanged.
    public let mintedAt: Date

    public init(token: String, ttlSeconds: Int, mintedAt: Date = Date()) {
        self.token = token
        self.ttlSeconds = ttlSeconds
        self.mintedAt = mintedAt
    }

    /// The auth query param to attach: `?ticket=<token>`.
    public var authQueryItem: URLQueryItem { URLQueryItem(name: "ticket", value: token) }

    /// Client-side TTL enforcement (synthesis §11: single-use, 30s TTL).
    /// A ticket whose TTL has elapsed must be re-minted — never reused.
    public func isExpired(asOf now: Date = Date()) -> Bool {
        now.timeIntervalSince(mintedAt) > Double(ttlSeconds)
    }

    public var description: String { "[REDACTED]" }
    public var debugDescription: String { "WSTicket(redacted)" }
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
    /// Optional session cookie from `POST /auth/password-login`, replayed as
    /// the `Cookie` header on the mint (P3 LAN-gateway username/password
    /// flow). Mutually exclusive in practice with `sessionToken`.
    public let sessionCookie: SessionCookie?
    public let urlSession: URLSession

    /// Non-secret diagnostics (endpoint + HTTP status only).
    private static let log = Logger(subsystem: "com.aiowa.hermesfleet", category: "ws-ticket")

    public init(
        baseURL: URL,
        sessionToken: String? = nil,
        sessionCookie: SessionCookie? = nil,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.sessionToken = sessionToken
        self.sessionCookie = sessionCookie
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
        if let sessionCookie {
            request.setValue(sessionCookie.headerValue, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Self.log.error("ws-ticket: HTTP \(http.statusCode)")
            throw TicketMintError.httpStatus(http.statusCode)
        }
        Self.log.info("ws-ticket: minted ok (\(Redaction.redactedURL(self.baseURL), privacy: .public))")
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

// MARK: - Redaction (spec §29: no credentials in logs/UI)

extension WSTicketClient: CustomStringConvertible, CustomDebugStringConvertible {
    /// The client's printable form never includes the session token OR any
    /// user-info/password that may be embedded in the endpoint (P1-6).
    public var description: String { "WSTicketClient(baseURL: \(Redaction.redactedURL(baseURL)))" }
    public var debugDescription: String { description }
}
