import Foundation
import FleetCore

/// Exchanges an hfd1 paired-device credential for the gateway's short-lived
/// owner-compatible session cookie. The long-lived credential is sent only in
/// an HTTPS request body and is never logged or placed in a URL.
public struct DeviceLoginClient: Sendable {
    public let baseURL: URL
    private let deviceCredential: String
    private let sessionOverride: URLSession?
    private let trustHandler: PinningTrustHandler?

    public init(
        baseURL: URL,
        deviceCredential: String,
        trustHandler: PinningTrustHandler? = nil,
        urlSession: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.deviceCredential = deviceCredential
        self.trustHandler = trustHandler
        self.sessionOverride = urlSession
    }

    private struct LoginBody: Encodable { let device_credential: String }
    private struct LoginResponse: Decodable {
        let ok: Bool?
        let expires_at: String?
    }

    public func login() async throws -> SessionCookie {
        guard baseURL.scheme?.lowercased() == "https" else { throw AuthenticationError.httpStatus(400) }
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/device-login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(LoginBody(device_credential: deviceCredential))
        AuthREST.bounded(&request)

        let delegate = DeviceLoginURLSessionDelegate(trustHandler: trustHandler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let ownsSession = sessionOverride == nil
        let session = sessionOverride ?? URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { if ownsSession { session.invalidateAndCancel() } }
        do {
            // Supply redirect policy as a per-task delegate so it also
            // applies when the caller injects the production pinned session.
            // That preserves the session's trust delegate while preventing
            // an hfd1 credential from being forwarded to a redirect target.
            let (data, response) = try await session.data(for: request, delegate: delegate)
            guard data.count <= AuthREST.maxResponseBytes,
                  let http = response as? HTTPURLResponse else {
                throw AuthenticationError.ticketMintFailed("device login response malformed")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw AuthenticationError.httpStatus(http.statusCode)
            }
            guard let decoded = try? JSONDecoder().decode(LoginResponse.self, from: data), decoded.ok == true,
                  let parsed = PasswordLoginClient.parseSessionCookie(from: http) else {
                throw AuthenticationError.ticketMintFailed("device login response malformed")
            }
            return SessionCookie(
                name: parsed.name,
                value: parsed.value,
                expiresAt: parsed.expiresAt ?? decoded.expires_at.flatMap(Self.parseDate))
        } catch let error as AuthenticationError { throw error }
        catch {
            if case .pinMismatch = trustHandler?.lastVerdict { throw AuthenticationError.httpStatus(495) }
            throw AuthenticationError.ticketMintFailed("device login unavailable")
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

private final class DeviceLoginURLSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let trustHandler: PinningTrustHandler?
    init(trustHandler: PinningTrustHandler?) { self.trustHandler = trustHandler }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trustHandler else { completionHandler(.performDefaultHandling, nil); return }
        trustHandler.evaluate(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
