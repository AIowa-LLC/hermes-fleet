import Foundation
import os
import Security
import FleetCore

// MARK: - Trust

/// Decides whether a presented server trust is acceptable for a host. Production
/// always uses the system's own evaluation; there is no "accept anything" implementation.
public protocol PairingTrustEvaluating: Sendable {
    func isTrusted(_ trust: SecTrust, host: String) -> Bool
}

/// The platform's normal TLS server evaluation for `host` (chain to a trusted root, hostname,
/// validity period, revocation policy). The pairing exchange never trusts a certificate the
/// system would not.
public struct SystemPairingTrust: PairingTrustEvaluating {
    public init() {}

    public func isTrusted(_ trust: SecTrust, host: String) -> Bool {
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess else { return false }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
}

/// One pairing HTTP exchange. A single delegate object handles everything that must not be
/// left to URLSession's defaults:
/// - it evaluates the server trust with the injected evaluator and refuses otherwise;
/// - it records the leaf key (SPKI) that the validated connection used;
/// - when told which key to expect, it cancels the handshake on any other key, so no request
///   (and no secret) is ever sent to a gateway whose identity changed;
/// - it refuses every redirect (a redirect could carry the secret to another host);
/// - it caps the response body while receiving it.
///
/// It drives a classic data task rather than `URLSession.bytes(for:)`: the async-bytes API does
/// not deliver server-trust challenges to a session delegate (verified; it fails `-1202`),
/// which would silently skip the trust and key checks above.
final class PairingExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Observed: Sendable {
        var fingerprint: SPKIFingerprint?
        var untrusted = false
        var keyMismatch = false
        /// The key matched the link's pin although the system would not trust the certificate.
        var acceptedByPinOnly = false
        var redirected = false
        var oversized = false
    }

    struct Outcome {
        let data: Data
        let response: HTTPURLResponse?
        let error: Error?
        let observed: Observed
    }

    private struct State {
        var observed = Observed()
        var data = Data()
        var response: HTTPURLResponse?
        var continuation: CheckedContinuation<Outcome, Never>?
        var task: URLSessionTask?
        var cancelled = false
        var finished = false
    }

    private let trust: any PairingTrustEvaluating
    private let expected: SPKIFingerprint?
    private let pin: SPKIFingerprint?
    private let limit: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// - Parameters:
    ///   - expected: the key already confirmed for this exchange; any other key is refused.
    ///   - pin: the key a version 2 link vouches for (S6). With a pin the server is accepted
    ///     when the leaf key matches it, whether or not the system trusts the certificate; a
    ///     different key is refused either way (`keyMismatch` when the system trusted the
    ///     certificate, `untrusted` when it did not).
    init(trust: any PairingTrustEvaluating, expected: SPKIFingerprint?, pin: SPKIFingerprint? = nil, limit: Int) {
        self.trust = trust
        self.expected = expected
        self.pin = pin
        self.limit = limit
    }

    /// Run `request` on a fresh, single-use session (so no connection or TLS session is reused
    /// from an earlier exchange and every request faces the trust decision).
    func run(_ request: URLRequest, configuration: URLSessionConfiguration) async -> Outcome {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                let task = session.dataTask(with: request)
                let startNow: Bool = state.withLock {
                    $0.continuation = continuation
                    $0.task = task
                    return !$0.cancelled
                }
                if startNow { task.resume() } else { task.cancel() }
            }
        } onCancel: {
            let task: URLSessionTask? = state.withLock {
                $0.cancelled = true
                return $0.task
            }
            task?.cancel()
        }
    }

    // MARK: trust

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            // No client-certificate or HTTP-auth challenge is ever answered here.
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let systemTrusted = trust.isTrusted(serverTrust, host: challenge.protectionSpace.host)
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let leaf = chain.first,
              let fingerprint = SPKIExtractor.fingerprint(from: leaf) else {
            state.withLock { $0.observed.untrusted = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if let pin {
            guard fingerprint == pin else {
                // Wrong key. If the system would have trusted it this is a different server
                // than the link's (identity mismatch); otherwise it is simply untrusted.
                state.withLock {
                    if systemTrusted { $0.observed.keyMismatch = true } else { $0.observed.untrusted = true }
                }
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            if !systemTrusted { state.withLock { $0.observed.acceptedByPinOnly = true } }
        } else if !systemTrusted {
            state.withLock { $0.observed.untrusted = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if let expected, expected != fingerprint {
            state.withLock { $0.observed.keyMismatch = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        state.withLock { $0.observed.fingerprint = fingerprint }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    // MARK: redirects

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        state.withLock { $0.observed.redirected = true }
        completionHandler(nil)   // deliver the 3xx response itself; never follow it
    }

    // MARK: body

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        state.withLock { $0.response = response as? HTTPURLResponse }
        if response.expectedContentLength > Int64(limit) {
            state.withLock { $0.observed.oversized = true }
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow: Bool = state.withLock {
            $0.data.append(data)
            if $0.data.count > limit {
                $0.observed.oversized = true
                return true
            }
            return false
        }
        if overflow { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let finish: (CheckedContinuation<Outcome, Never>, Outcome)? = state.withLock {
            guard !$0.finished, let continuation = $0.continuation else { return nil }
            $0.finished = true
            $0.continuation = nil
            return (continuation, Outcome(
                data: $0.data, response: $0.response, error: error, observed: $0.observed))
        }
        if let (continuation, outcome) = finish { continuation.resume(returning: outcome) }
    }
}

// MARK: - Client

/// The HTTPS client for the Add to Fleet pairing exchange:
/// `POST /api/fleet/pairing/preview`, `POST /api/fleet/pairing/redeem`, `POST /auth/device-revoke`.
///
/// Security properties (each covered by tests):
/// - https only, to exactly the link's origin; the TLS chain must pass the system's evaluation,
///   there is no override and no pin-on-first-sight for the secret-bearing requests;
/// - the invitation secret travels only in a POST body over that connection: never in a URL, a
///   header, a query, a log, or an error;
/// - redemption refuses (before sending anything) a gateway whose key differs from the one the
///   person confirmed, and validates the returned identity against the confirmed preview;
/// - no cookies, no URL cache, no redirects, bounded response size, short timeouts;
/// - every failure maps to a payload-free `PairingFailure`.
public final class GatewayPairingClient: GatewayPairing, @unchecked Sendable {
    /// Largest response body accepted (the real ones are a few hundred bytes).
    static let maxResponseBytes = 64 * 1024
    /// Invitation issuers cap their lifetime at fifteen minutes. Refuse a forged or
    /// future protocol response that would keep an approval screen actionable longer.
    static let maxInvitationLifetimeSeconds = 15 * 60
    static let timeout: TimeInterval = 12

    private let trust: any PairingTrustEvaluating
    private let configuration: URLSessionConfiguration
    /// Keys this client admitted because a version 2 link pinned them. A cleanup revocation
    /// to such a key must be admitted the same way (the system never trusted that certificate);
    /// every other key still needs system trust.
    private let pinnedKeys = OSAllocatedUnfairLock(initialState: Set<SPKIFingerprint>())

    /// - Parameter trust: the server-trust policy. Production uses the default (the system's);
    ///   tests inject an evaluator anchored to a throwaway certificate.
    public init(trust: any PairingTrustEvaluating = SystemPairingTrust()) {
        self.trust = trust
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = Self.timeout
        config.timeoutIntervalForResource = Self.timeout * 2
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.httpAdditionalHeaders = nil
        self.configuration = config
    }

    // MARK: GatewayPairing

    public func preview(_ link: PairingInvitationLink) async throws(PairingFailure) -> PairingPreview {
        try Self.validate(link: link)
        let reply = try await post(
            origin: link.origin, path: "api/fleet/pairing/preview",
            body: ["invitation_id": link.invitationID, "secret": link.secret.rawValue],
            expecting: nil, pin: link.pin)
        let envelope = try Self.decode(PreviewEnvelope.self, from: reply.data)
        let gateway = try envelope.gateway.validated(against: link.origin)
        guard envelope.invitation.id == link.invitationID else { throw .identityMismatch }
        let access = try envelope.invitation.scopes.map { scope throws(PairingFailure) -> PairingAccess in
            guard let known = PairingScope(rawValue: scope) else { throw .unsupportedAccess }
            return PairingAccess(scope: known.rawValue, summary: known.summary)
        }
        guard !access.isEmpty, Set(access.map(\.scope)).count == access.count else {
            throw .unsupportedAccess
        }
        let expiresAt = envelope.invitation.expires_at
        let serverTime = envelope.invitation.server_time
        guard serverTime > 0, expiresAt > serverTime,
              expiresAt - serverTime <= Self.maxInvitationLifetimeSeconds else {
            throw .malformedResponse
        }
        let remaining = expiresAt - serverTime
        let approvalRequired = envelope.invitation.approval_required ?? false
        let protocols = envelope.protocols ?? []
        if link.requiresApproval {
            // A version 2 link only works through the approval path.
            guard approvalRequired else { throw .malformedResponse }
            if !protocols.isEmpty, !protocols.contains(PairingInvitationLink.approvalVersion) {
                throw .approvalNotSupported
            }
        } else if approvalRequired {
            // A legacy link to an invitation that must be approved can never be redeemed.
            throw .approvalRequired
        }
        return PairingPreview(
            gateway: gateway,
            label: Self.displayText(envelope.invitation.label, limit: 64),
            access: access,
            expiresAt: Date().addingTimeInterval(TimeInterval(remaining)),
            tlsFingerprint: reply.fingerprint,
            approvalRequired: approvalRequired,
            protocols: protocols)
    }

    public func redeem(
        _ link: PairingInvitationLink, deviceName: String, expecting: PairingPreview
    ) async throws(PairingFailure) -> PairingGrant {
        try Self.validate(link: link)
        guard expecting.gateway.origin == link.origin else { throw .identityMismatch }
        let approvedScopes = expecting.access.map(\.scope)
        guard !approvedScopes.isEmpty, Set(approvedScopes).count == approvedScopes.count,
              approvedScopes.allSatisfy({ PairingScope(rawValue: $0) != nil }) else {
            throw .unsupportedAccess
        }
        let reply = try await post(
            origin: link.origin, path: "api/fleet/pairing/redeem",
            body: [
                "invitation_id": link.invitationID, "secret": link.secret.rawValue,
                "device_name": Self.displayText(deviceName, limit: 64),
            ],
            expecting: expecting.tlsFingerprint)
        let envelope = try Self.decode(RedeemEnvelope.self, from: reply.data)
        return try await grant(
            from: envelope, origin: link.origin, expectingGateway: expecting.gateway,
            approvedScopes: approvedScopes, confirmedKey: expecting.tlsFingerprint,
            presentedKey: reply.fingerprint)
    }

    /// Validate a credential-bearing answer (redeem, or an approved poll) and turn it into a
    /// grant. From the moment a credential arrives, anything wrong with the answer means the
    /// credential must not be kept: revoke it (best effort, to the confirmed key) and fail.
    private func grant(
        from envelope: RedeemEnvelope, origin: URL, expectingGateway: PairingGatewayIdentity,
        approvedScopes: [String], confirmedKey: SPKIFingerprint, presentedKey: SPKIFingerprint
    ) async throws(PairingFailure) -> PairingGrant {
        let credential = envelope.credential
        let gateway: PairingGatewayIdentity
        do {
            gateway = try envelope.gateway.validated(against: origin)
            guard gateway.instanceID == expectingGateway.instanceID,
                  Self.isCredential(credential), Self.isDeviceID(envelope.device.id) else {
                throw PairingFailure.identityMismatch
            }
            guard !envelope.scopes.isEmpty,
                  Set(envelope.scopes).count == envelope.scopes.count,
                  envelope.scopes.allSatisfy({ PairingScope(rawValue: $0) != nil }),
                  Set(envelope.scopes) == Set(approvedScopes) else {
                throw PairingFailure.unsupportedAccess
            }
        } catch let failure as PairingFailure {
            if Self.isCredential(credential) {
                let cleanup = await revoke(
                    origin: origin, credential: PairingDeviceCredential(credential),
                    expecting: confirmedKey)
                guard cleanup == .revoked || cleanup == .alreadyRevoked else {
                    throw .rollbackUnconfirmed
                }
            }
            throw failure
        } catch {
            throw .malformedResponse
        }
        return PairingGrant(
            gateway: gateway, deviceID: envelope.device.id,
            credential: PairingDeviceCredential(credential), tlsFingerprint: presentedKey)
    }

    // MARK: Approval (v2)

    public func requestApproval(
        _ link: PairingInvitationLink, deviceName: String, deviceModel: String,
        clientSecret: PairingClientSecret, expecting: PairingPreview
    ) async throws(PairingFailure) -> PairingApprovalRequest {
        try Self.validate(link: link)
        guard link.requiresApproval, let pin = link.pin else { throw .approvalNotSupported }
        guard expecting.gateway.origin == link.origin, expecting.tlsFingerprint == pin else {
            throw .identityMismatch
        }
        let scopes = expecting.access.map(\.scope)
        guard !scopes.isEmpty, Set(scopes).count == scopes.count,
              scopes.allSatisfy({ PairingScope(rawValue: $0) != nil }) else { throw .unsupportedAccess }
        let reply = try await post(
            origin: link.origin, path: "api/fleet/pairing/request",
            body: [
                "invitation_id": link.invitationID, "secret": link.secret.rawValue,
                "device_name": Self.displayText(deviceName, limit: 64),
                "device_model": Self.displayText(deviceModel, limit: 64),
                "client_secret": clientSecret.rawValue,
            ],
            expecting: expecting.tlsFingerprint, pin: pin)
        let envelope = try Self.decode(RequestEnvelope.self, from: reply.data)
        let gateway = try envelope.gateway.validated(against: link.origin)
        let wire = envelope.request
        guard gateway.instanceID == expecting.gateway.instanceID, Self.isRequestID(wire.id),
              Self.isMatchCode(wire.match_code), wire.server_time > 0, wire.expires_at > wire.server_time,
              wire.expires_at - wire.server_time <= Self.maxInvitationLifetimeSeconds else {
            throw .malformedResponse
        }
        return PairingApprovalRequest(
            id: wire.id, matchCode: wire.match_code,
            expiresAt: Date().addingTimeInterval(TimeInterval(wire.expires_at - wire.server_time)),
            pollInterval: Self.clampedPollInterval(wire.poll_interval),
            gateway: gateway, scopes: scopes, tlsFingerprint: reply.fingerprint)
    }

    public func pollApproval(
        _ request: PairingApprovalRequest, clientSecret: PairingClientSecret
    ) async throws(PairingFailure) -> PairingApprovalStatus {
        guard Self.isRequestID(request.id) else { throw .malformedLink }
        // Every poll must reach the very key the request was made to: it is the link's pin.
        let reply = try await post(
            origin: request.gateway.origin, path: "api/fleet/pairing/request/status",
            body: ["request_id": request.id, "client_secret": clientSecret.rawValue],
            expecting: request.tlsFingerprint, pin: request.tlsFingerprint)
        let envelope = try Self.decode(StatusEnvelope.self, from: reply.data)
        switch envelope.status {
        case "pending": return .pending
        case "delivered": return .delivered
        case "denied": return .denied
        case "expired": return .expired
        case "approved":
            guard let device = envelope.device, let credential = envelope.credential,
                  let gateway = envelope.gateway, let scopes = envelope.scopes else {
                throw .malformedResponse
            }
            let grant = try await grant(
                from: RedeemEnvelope(device: device, credential: credential, gateway: gateway, scopes: scopes),
                origin: request.gateway.origin, expectingGateway: request.gateway,
                approvedScopes: request.scopes, confirmedKey: request.tlsFingerprint,
                presentedKey: reply.fingerprint)
            return .approved(grant)
        default:
            throw .malformedResponse
        }
    }

    public func revoke(origin: URL, credential: PairingDeviceCredential) async -> PairingRevocationOutcome {
        await revoke(origin: origin, credential: credential, expecting: nil)
    }

    /// Revokes with the TLS identity already confirmed for this gateway. Callers
    /// handling an invalid redemption response must provide the preview fingerprint
    /// so cleanup cannot disclose the credential after key rotation.
    public func revoke(
        origin: URL, credential: PairingDeviceCredential, expecting: SPKIFingerprint?
    ) async -> PairingRevocationOutcome {
        guard Self.isSafeCredentialPayload(credential.rawValue), Self.isHTTPSOrigin(origin) else { return .failed }
        do {
            let pinned: SPKIFingerprint? = expecting.flatMap { key in
                pinnedKeys.withLock { $0.contains(key) } ? key : nil
            }
            let reply = try await post(
                origin: origin, path: "auth/device-revoke",
                body: ["device_credential": credential.rawValue], expecting: expecting, pin: pinned)
            let envelope = try Self.decode(RevocationEnvelope.self, from: reply.data)
            guard envelope.ok else { return .failed }
            return .revoked
        } catch {
            switch error {
            case .untrustedCertificate: return .unreachable
            case _ where error.isNetworkFailure: return .unreachable
            case .invalidInvitation: return .alreadyRevoked   // 401 invalid_credential maps here
            default: return .failed
            }
        }
    }

    // MARK: Transport

    struct Reply {
        let data: Data
        let fingerprint: SPKIFingerprint
    }

    private func post(
        origin: URL, path: String, body: [String: String], expecting: SPKIFingerprint?,
        pin: SPKIFingerprint? = nil
    ) async throws(PairingFailure) -> Reply {
        guard Self.isHTTPSOrigin(origin),
              let url = URL(string: path, relativeTo: origin)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == origin.host?.lowercased(), url.port == origin.port,
              let payload = try? JSONEncoder().encode(body) else {
            throw .insecureDestination
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let exchange = PairingExchange(trust: trust, expected: expecting, pin: pin, limit: Self.maxResponseBytes)
        let outcome = await exchange.run(request, configuration: configuration)
        let observed = outcome.observed
        if observed.keyMismatch { throw .identityMismatch }
        if observed.untrusted { throw .untrustedCertificate }
        if observed.acceptedByPinOnly, let key = observed.fingerprint {
            pinnedKeys.withLock { _ = $0.insert(key) }
        }
        if observed.oversized { throw .malformedResponse }
        if observed.redirected { throw .malformedResponse }
        if let error = outcome.error { throw Self.failure(for: error, observed: observed) }
        guard let http = outcome.response, let fingerprint = observed.fingerprint else {
            throw .malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.failure(forStatus: http.statusCode, body: outcome.data)
        }
        return Reply(data: outcome.data, fingerprint: fingerprint)
    }

    // MARK: Mapping

    static func failure(for error: Error, observed: PairingExchange.Observed) -> PairingFailure {
        if observed.keyMismatch { return .identityMismatch }
        if observed.untrusted { return .untrustedCertificate }
        guard let urlError = error as? URLError else { return .unreachable }
        switch urlError.code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return .untrustedCertificate
        case .cancelled:
            return .interrupted
        case .cannotFindHost, .dnsLookupFailed:
            return .hostNotFound
        case .timedOut:
            return .timedOut
        case .cannotConnectToHost:
            return .connectionRefused
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return .offline
        default:
            // Includes a generic TLS handshake failure (`secureConnectionFailed`): that is what a
            // reset connection or a port that does not speak TLS produces, and it says nothing
            // about the certificate. A certificate the phone rejects is identified precisely by
            // the trust delegate (`observed.untrusted`), not by this code.
            return .unreachable
        }
    }

    static func failure(forStatus status: Int, body: Data) -> PairingFailure {
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body), let code = envelope.error {
            switch code {
            case "invalid": return .invalidInvitation
            case "expired": return .expired
            case "already_used": return .alreadyUsed
            case "cancelled": return .cancelled
            case "rate_limited": return .rateLimited
            case "pairing_unavailable": return .pairingUnavailable
            case "invalid_credential": return .invalidInvitation
            case "too_many_pending": return .rateLimited
            case "invalid_request": return .invalidRequest
            case "already_redeemed": return .alreadyUsed
            case "approval_not_supported": return .approvalNotSupported
            case "approval_required": return .approvalRequired
            default: break
            }
        }
        switch status {
        case 404, 405, 501: return .pairingUnavailable      // no such route: an older gateway
        case 429: return .rateLimited
        case 500...599: return .serverError
        default: return .malformedResponse
        }
    }

    // MARK: Wire shapes

    private struct ErrorEnvelope: Decodable { let error: String? }
    private struct RevocationEnvelope: Decodable { let ok: Bool }

    private struct GatewayWire: Decodable {
        let instance_id: String
        let display_name: String
        let origin: String

        func validated(against expected: URL) throws(PairingFailure) -> PairingGatewayIdentity {
            guard GatewayPairingClient.isInstanceID(instance_id),
                  let reported = URL(string: origin), Self.sameOrigin(reported, expected) else {
                throw .identityMismatch
            }
            return PairingGatewayIdentity(
                instanceID: instance_id,
                displayName: GatewayPairingClient.displayText(display_name, limit: 64),
                origin: expected)
        }

        private static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
            func key(_ url: URL) -> String {
                "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? 443)"
            }
            return key(a) == key(b) && (a.path.isEmpty || a.path == "/")
        }
    }

    private struct PreviewEnvelope: Decodable {
        struct Invitation: Decodable {
            let id: String
            let label: String
            let scopes: [String]
            let expires_at: Int
            let server_time: Int
            let approval_required: Bool?
        }
        let gateway: GatewayWire
        let invitation: Invitation
        let protocols: [Int]?
    }

    private struct RequestEnvelope: Decodable {
        struct Request: Decodable {
            let id: String
            let match_code: String
            let expires_at: Int
            let poll_interval: Double?
            let server_time: Int
        }
        let request: Request
        let gateway: GatewayWire
    }

    private struct StatusEnvelope: Decodable {
        let status: String
        let device: RedeemEnvelope.Device?
        let credential: String?
        let gateway: GatewayWire?
        let scopes: [String]?
    }

    private struct RedeemEnvelope: Decodable {
        struct Device: Decodable { let id: String }
        let device: Device
        let credential: String
        let gateway: GatewayWire
        let scopes: [String]
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws(PairingFailure) -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            // A gateway without pairing answers an unknown path with its web page, not JSON.
            let first = data.first(where: { !$0.isASCIIWhitespace })
            throw first == UInt8(ascii: "<") ? .pairingUnavailable : .malformedResponse
        }
    }

    // MARK: Validation helpers

    private static func validate(link: PairingInvitationLink) throws(PairingFailure) {
        guard isInvitationID(link.invitationID), isInvitationSecret(link.secret.rawValue) else {
            throw .malformedLink
        }
        guard isHTTPSOrigin(link.origin) else { throw .insecureDestination }
    }

    private static func isHTTPSOrigin(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.host?.isEmpty == false,
              url.path.isEmpty || url.path == "/" else { return false }
        if let port = url.port, !(1...65535).contains(port) { return false }
        return true
    }

    private static func isInvitationID(_ text: String) -> Bool {
        isToken(text, length: 16...64)
    }

    private static func isInvitationSecret(_ text: String) -> Bool {
        isToken(text, length: 32...128)
    }

    private static func isToken(_ text: String, length: ClosedRange<Int>) -> Bool {
        length.contains(text.count) && text.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A)
                || ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "-" || $0 == "_"
        }
    }

    /// Request ids are opaque handles issued by the gateway; accept a bounded token only.
    static func isRequestID(_ text: String) -> Bool { isToken(text, length: 8...128) }

    static func isMatchCode(_ text: String) -> Bool {
        text.utf8.count == 6 && text.unicodeScalars.allSatisfy { $0.value >= 0x30 && $0.value <= 0x39 }
    }

    /// The gateway suggests a polling pace; the phone never polls faster than once a second
    /// (the gateway rate-limits) nor slower than every ten.
    static func clampedPollInterval(_ seconds: Double?) -> TimeInterval {
        min(max(seconds ?? 2, 1), 10)
    }

    static func isInstanceID(_ text: String) -> Bool { GatewayID(pairedInstanceID: text) != nil }

    static func isDeviceID(_ text: String) -> Bool { isInstanceID(text) }

    static func isCredential(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard text.count <= 200, parts.count == 3, parts[0] == "hfd1",
              isDeviceID(String(parts[1])), (32...128).contains(parts[2].count) else { return false }
        return text.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A)
                || ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    /// Credentials that came back malformed still need best-effort cleanup after a
    /// successful redemption. Restrict their size and alphabet before putting them
    /// in a bounded JSON request; normal saved credentials also satisfy this check.
    private static func isSafeCredentialPayload(_ text: String) -> Bool {
        (1...200).contains(text.utf8.count) && text.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A)
                || ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    /// Text that came from the network and will be shown: printable, bounded, single line.
    static func displayText(_ raw: String, limit: Int) -> String {
        let cleaned = raw.unicodeScalars
            .filter { !$0.properties.isDefaultIgnorableCodePoint && ($0.value >= 0x20 && $0.value != 0x7F) }
            .map(Character.init)
        return String(String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

private extension UInt8 {
    var isASCIIWhitespace: Bool { self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D }
}

extension GatewayPairingClient: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "GatewayPairingClient" }
    public var debugDescription: String { description }
}
