import Foundation
import os
import FleetCore

/// Exchanges a paired device's credential for a session cookie:
/// `POST /auth/device-login` with `{"device_credential": ...}` -> `Set-Cookie`.
///
/// The cookie then rides the same path as the password flow (`POST /api/auth/ws-ticket` ->
/// `?ticket=`, or the dashboard REST routes). The credential lives only in the request body
/// of this call; the cookie is a short-lived secret whose printable form is redacted.
public struct DeviceLoginClient: Sendable {
    public let baseURL: URL
    public let urlSession: URLSession

    private static let log = Logger(subsystem: "com.aiowa.hermesfleet", category: "device-login")

    public init(baseURL: URL, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    public func login(credential: String) async throws -> SessionCookie {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/device-login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["device_credential": credential])
        AuthREST.bounded(&request)

        Self.log.info("device-login: POST /auth/device-login (\(Redaction.redactedURL(self.baseURL), privacy: .private))")
        let (data, response) = try await urlSession.boundedData(for: request)
        guard data.count <= AuthREST.maxResponseBytes else {
            throw PasswordLoginError.missingSessionCookie
        }
        guard let http = response as? HTTPURLResponse else {
            throw AuthenticationError.httpStatus(-1)
        }
        Self.log.info("device-login: HTTP \(http.statusCode)")
        guard (200..<300).contains(http.statusCode) else {
            // 401 = revoked or unknown device; 404/409 = gateway without pairing support.
            throw AuthenticationError.httpStatus(http.statusCode)
        }
        guard let cookie = PasswordLoginClient.parseSessionCookie(from: http) else {
            throw PasswordLoginError.missingSessionCookie
        }
        return cookie
    }
}

extension DeviceLoginClient: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "DeviceLoginClient(baseURL: \(Redaction.redactedURL(baseURL)))" }
    public var debugDescription: String { description }
}
