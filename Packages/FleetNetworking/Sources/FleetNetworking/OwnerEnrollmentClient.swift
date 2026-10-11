import Foundation
import Security
import FleetCore

private actor EnrollmentEndpointLock {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private actor EnrollmentEndpointLocks {
    static let shared = EnrollmentEndpointLocks()
    private var locks: [GatewayID: EnrollmentEndpointLock] = [:]

    func lock(for endpointID: GatewayID) -> EnrollmentEndpointLock {
        if let lock = locks[endpointID] { return lock }
        let lock = EnrollmentEndpointLock()
        locks[endpointID] = lock
        return lock
    }
}

/// Owner-authenticated Fleet device enrollment. The owner authorization is
/// accepted only by HTTPS endpoints, redirects are stopped before credentials
/// can be forwarded, and the resulting device credential is written directly
/// to the existing per-gateway credential store.
public struct OwnerEnrollmentClient: OwnerEnrollmentProviding, GatewayEnrollmentCleanupProviding {
    private let credentials: any CredentialStoring
    private let identities: any OwnerEnrollmentIdentityStoring
    private let sessionOverride: URLSession?
    private let fixedTrustHandler: PinningTrustHandler?
    private let trustHandlerFactory: (@Sendable (GatewayID) -> PinningTrustHandler)?
    private let pinStore: (any SynchronousPinStoring)?
    private let approvalStore: (any SynchronousTLSFirstUseApprovalStoring)?

    public init(
        credentialStore: any CredentialStoring,
        identityStore: any OwnerEnrollmentIdentityStoring,
        pinningTrustHandler: PinningTrustHandler? = nil,
        trustHandlerFactory: (@Sendable (GatewayID) -> PinningTrustHandler)? = nil,
        pinStore: (any SynchronousPinStoring)? = nil,
        approvalStore: (any SynchronousTLSFirstUseApprovalStoring)? = nil,
        urlSession: URLSession? = nil
    ) {
        self.credentials = credentialStore
        self.identities = identityStore
        self.fixedTrustHandler = pinningTrustHandler
        self.trustHandlerFactory = trustHandlerFactory
        self.pinStore = pinStore
        self.approvalStore = approvalStore
        self.sessionOverride = urlSession
    }

    private struct ProvidersEnvelope: Decodable {
        struct Provider: Decodable {
            let name: String?
            let display_name: String?
            let supports_password: Bool?
        }
        let providers: [Provider]?
    }

    private struct ConnectionEnvelope: Decodable {
        let authenticated: Bool?
        let can_enroll: Bool?
        let enrollment_version: Int?
        let gateway: Gateway?
        let scopes: [String]?
        struct Gateway: Decodable {
            let instance_id: String?
            let display_name: String?
            let origin: String?
        }
    }

    private struct EnrollBody: Encodable {
        let device_id: String
        let device_secret: String
        let device_name: String?
        let device_model: String?
    }

    private struct EnrollEnvelope: Decodable {
        let device: Device?
        let device_credential: String?
        let gateway: ConnectionEnvelope.Gateway?
        let scopes: [String]?
        struct Device: Decodable {
            let id: String?
            let label: String?
        }
    }

    public func discoverProviders(at address: URL) async throws -> [OwnerIdentityProvider] {
        let base = try validatedBase(address)
        let (data, response) = try await request(path: "api/auth/providers", base: base, method: "GET")
        guard let http = response as? HTTPURLResponse else { throw OwnerEnrollmentError.unreachable }
        try validateStatus(http, data: data)
        let envelope: ProvidersEnvelope = try decode(data)
        guard let providers = envelope.providers, !providers.isEmpty else {
            throw OwnerEnrollmentError.malformedResponse
        }
        return providers.compactMap { provider in
            guard let name = provider.name, !name.isEmpty else { return nil }
            return OwnerIdentityProvider(
                id: name,
                displayName: provider.display_name ?? name,
                supportsPassword: provider.supports_password == true)
        }
    }

    public func signIn(
        at address: URL,
        providerID: String,
        username: String,
        password: String
    ) async throws -> OwnerAuthorization {
        let base = try validatedBase(address)
        guard !providerID.isEmpty, !username.isEmpty, !password.isEmpty else {
            throw OwnerEnrollmentError.unauthorized
        }
        var request = URLRequest(url: base.appendingPathComponent("auth/password-login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "provider": providerID, "username": username, "password": password
        ])
        AuthREST.bounded(&request)
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw OwnerEnrollmentError.unreachable }
        try validateStatus(http, data: data)
        guard let cookie = PasswordLoginClient.parseSessionCookie(from: http) else {
            throw OwnerEnrollmentError.malformedResponse
        }
        return .sessionCookie(name: cookie.name, value: cookie.value)
    }

    public func approveTLSFirstUse(at address: URL, fingerprint: SPKIFingerprint) async throws {
        let endpoint = try validatedBase(address)
        guard let pinStore else { throw OwnerEnrollmentError.tlsApprovalUnavailable }
        let endpointID = GatewayID(endpoint: endpoint)
        do {
            // Persist exactly the key the user reviewed. This avoids an
            // approval flag that could accept a different certificate on the
            // next connection if the endpoint changes between review/retry.
            if let existing = try pinStore.syncLoadPin(for: endpointID) {
                guard existing == fingerprint else { throw OwnerEnrollmentError.tlsPinMismatch }
                return
            }
            try pinStore.syncSavePin(fingerprint, for: endpointID)
        }
        catch let error as OwnerEnrollmentError { throw error }
        catch { throw OwnerEnrollmentError.tlsApprovalUnavailable }
    }

    public func inspectConnection(at address: URL, authorization: OwnerAuthorization) async throws -> OwnerConnectionMetadata {
        try await inspectConnection(at: address, authorization: authorization, pinningGatewayID: nil)
    }

    private func inspectConnection(
        at address: URL,
        authorization: OwnerAuthorization,
        pinningGatewayID: GatewayID?
    ) async throws -> OwnerConnectionMetadata {
        let base = try validatedBase(address)
        var request = URLRequest(url: base.appendingPathComponent("api/fleet/connection"))
        request.httpMethod = "GET"
        apply(authorization, to: &request)
        let (data, response) = try await perform(request, pinningGatewayID: pinningGatewayID)
        guard let http = response as? HTTPURLResponse else { throw OwnerEnrollmentError.unreachable }
        try validateStatus(http, data: data)
        let envelope: ConnectionEnvelope = try decode(data)
        guard envelope.authenticated == true, envelope.can_enroll == true,
              let version = envelope.enrollment_version, version == 1,
              let gateway = envelope.gateway,
              let rawID = gateway.instance_id, !rawID.isEmpty,
              let display = gateway.display_name, !display.isEmpty,
              let rawOrigin = gateway.origin, let origin = URL(string: rawOrigin),
              let scopes = envelope.scopes, scopes == ["fleet:operator"] else {
            throw OwnerEnrollmentError.ownerRequired
        }
        let gatewayID = GatewayID(rawValue: rawID)
        guard sameOrigin(base, origin), gatewayID.isRoutingSafe else { throw OwnerEnrollmentError.malformedResponse }
        try adoptPinIfAvailable(endpoint: base, gatewayID: gatewayID)
        return OwnerConnectionMetadata(
            gatewayID: gatewayID, displayName: display,
            origin: origin, scopes: scopes, enrollmentVersion: version)
    }

    public func enrollDevice(
        at address: URL,
        authorization: OwnerAuthorization,
        deviceName: String?,
        deviceModel: String?
    ) async throws -> OwnerEnrolledDevice {
        let base = try validatedBase(address)
        let endpointLock = await EnrollmentEndpointLocks.shared.lock(for: GatewayID(endpoint: base))
        await endpointLock.acquire()
        defer { Task { await endpointLock.release() } }
        let metadata = try await inspectConnection(at: base, authorization: authorization)
        let endpointID = GatewayID(endpoint: base)
        let existing = try await credentials.loadCredential(for: metadata.gatewayID)
        let identity: PendingOwnerDeviceIdentity
        do {
            if let pending = try await identities.loadIdentity(for: endpointID) {
                identity = pending
            } else if let existing,
                      let committed = Self.identity(from: existing.rawValue) {
                // Recover when credential commit succeeded but a later local
                // cleanup step was interrupted. This is the exact durable
                // identity already held in Keychain, never a new credential.
                try await identities.saveIdentity(committed, for: endpointID)
                identity = committed
            } else {
                let fresh = try Self.makeIdentity()
                try await identities.saveIdentity(fresh, for: endpointID)
                identity = fresh
            }
        } catch let error as OwnerEnrollmentError { throw error }
        catch { throw OwnerEnrollmentError.identityStorageFailed }

        if let existing,
           existing.rawValue != "hfd1.\(identity.deviceID).\(identity.secret)" {
            // Existing credentials are never overwritten unless the durable
            // pending identity proves this is recovery of the same enrollment.
            throw OwnerEnrollmentError.gatewayAlreadyRegistered
        }

        let body = EnrollBody(
            device_id: identity.deviceID,
            device_secret: identity.secret,
            device_name: deviceName,
            device_model: deviceModel)
        var request = URLRequest(url: base.appendingPathComponent("api/fleet/devices/enroll"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(base.originString, forHTTPHeaderField: "Origin")
        apply(authorization, to: &request)
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw OwnerEnrollmentError.unreachable }
        do {
            try validateStatus(http, data: data)
        } catch let error as OwnerEnrollmentError {
            guard http.statusCode == 409, Self.isRevokedEnrollment(data) else { throw error }
            // Only the server's authenticated exact-digest revoked response
            // confirms this identity cannot be reused. Remove only the local
            // material that exactly matches it; keep trust alias for retry.
            do {
                try await identities.deleteIdentity(for: endpointID)
                if let existing,
                   existing.rawValue == "hfd1.\(identity.deviceID).\(identity.secret)" {
                    try await credentials.deleteCredential(for: metadata.gatewayID)
                }
            } catch {
                throw OwnerEnrollmentError.identityStorageFailed
            }
            throw OwnerEnrollmentError.previousEnrollmentRevoked
        }
        let envelope: EnrollEnvelope = try decode(data)
        guard let device = envelope.device, device.id == identity.deviceID,
              let credential = envelope.device_credential,
              credential == "hfd1.\(identity.deviceID).\(identity.secret)",
              let gateway = envelope.gateway,
              let rawGatewayID = gateway.instance_id, !rawGatewayID.isEmpty,
              let gatewayName = gateway.display_name, !gatewayName.isEmpty,
              let returnedOrigin = gateway.origin.flatMap(URL.init(string:)),
              sameOrigin(base, returnedOrigin),
              rawGatewayID == metadata.gatewayID.rawValue,
              gatewayName == metadata.displayName,
              let scopes = envelope.scopes, scopes == metadata.scopes else {
            throw OwnerEnrollmentError.malformedResponse
        }
        let gatewayID = GatewayID(rawValue: rawGatewayID)
        do {
            // A retry after a completed commit can arrive while local cleanup
            // is still being recovered. Do not rewrite the known credential:
            // a redundant Keychain failure must never revoke a valid device.
            if existing == nil {
                try await credentials.saveCredential(GatewayCredential(rawValue: credential), for: gatewayID)
            }
        } catch {
            do {
                try await revokeRemoteDevice(deviceID: identity.deviceID, at: base, authorization: authorization)
            } catch {
                throw OwnerEnrollmentError.rollbackFailed
            }
            // After confirmed revoke, deleting the persisted retry identity
            // is mandatory before returning. A future attempt generates a
            // fresh ID; never replace/overwrite an identity if deletion
            // itself failed.
            do { try await identities.deleteIdentity(for: endpointID) }
            catch { throw OwnerEnrollmentError.identityStorageFailed }
            do { try await credentials.deleteCredential(for: gatewayID) }
            catch { throw OwnerEnrollmentError.credentialStorageFailed }
            throw OwnerEnrollmentError.credentialStorageFailed
        }
        do {
            try await cleanupLocalEnrollmentMaterial(endpointID: endpointID, gatewayID: gatewayID)
        } catch {
            throw OwnerEnrollmentError.identityStorageFailed
        }
        return OwnerEnrolledDevice(
            gatewayID: gatewayID, displayName: gatewayName,
            deviceID: identity.deviceID, scopes: scopes)
    }

    public func cancelEnrollment(
        at address: URL,
        authorization: OwnerAuthorization,
        deviceID: String,
        gatewayID: GatewayID
    ) async throws {
        guard deviceID.count == 32, deviceID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw OwnerEnrollmentError.invalidAddress
        }
        let base = try validatedBase(address)
        let endpointID = GatewayID(endpoint: base)
        let endpointLock = await EnrollmentEndpointLocks.shared.lock(for: endpointID)
        await endpointLock.acquire()
        defer { Task { await endpointLock.release() } }
        let metadata = try await inspectConnection(
            at: base, authorization: authorization, pinningGatewayID: gatewayID)
        guard metadata.gatewayID == gatewayID else { throw OwnerEnrollmentError.malformedResponse }
        do {
            let pending = try await identities.loadIdentity(for: endpointID)
            if let pending {
                guard pending.deviceID == deviceID else { throw OwnerEnrollmentError.malformedResponse }
            } else if let credential = try await credentials.loadCredential(for: metadata.gatewayID),
                      let identity = Self.identity(from: credential.rawValue), identity.deviceID == deviceID {
                // UI adoption can fail after the ordinary credential is
                // committed. Recreate the secure retry identity before trying
                // owner revoke so an interrupted cancel can resume after relaunch.
                try await identities.saveIdentity(identity, for: endpointID)
            }
        } catch let error as OwnerEnrollmentError { throw error }
        catch { throw OwnerEnrollmentError.identityStorageFailed }
        try await revokeRemoteDevice(
            deviceID: deviceID, at: base, authorization: authorization, pinningGatewayID: gatewayID)
        do {
            try await identities.deleteIdentity(for: endpointID)
            try await credentials.deleteCredential(for: metadata.gatewayID)
            try await cleanupLocalEnrollmentMaterial(endpointID: endpointID, gatewayID: metadata.gatewayID)
        } catch {
            throw OwnerEnrollmentError.credentialStorageFailed
        }
    }

    public func removeEnrollmentMaterial(for gateway: FleetGateway) async throws {
        guard let rawEndpoint = gateway.endpoint else {
            if gateway.authConfiguration.strategy == .deviceCredential {
                throw OwnerEnrollmentError.invalidAddress
            }
            return
        }
        let endpoint: URL
        if gateway.authConfiguration.strategy == .deviceCredential {
            endpoint = try validatedBase(rawEndpoint)
        } else {
            // The registry also handles advanced/manual HTTP loopback entries.
            // Their local removal cleanup must not force a new HTTPS policy.
            do { endpoint = try GatewayEndpoint.normalizedOrigin(from: rawEndpoint) }
            catch { throw OwnerEnrollmentError.invalidAddress }
        }
        let endpointID = GatewayID(endpoint: endpoint)
        let endpointLock = await EnrollmentEndpointLocks.shared.lock(for: endpointID)
        await endpointLock.acquire()
        defer { Task { await endpointLock.release() } }
        do {
            if gateway.authConfiguration.strategy == .deviceCredential {
                if let credential = try await credentials.loadCredential(for: gateway.id),
                   credential.rawValue.hasPrefix("hfd1.") {
                    try await revokeDeviceCredential(credential.rawValue, at: endpoint, gatewayID: gateway.id)
                }
            }
            try await cleanupLocalEnrollmentMaterial(endpointID: endpointID, gatewayID: gateway.id)
        } catch {
            throw OwnerEnrollmentError.identityStorageFailed
        }
    }

    private func revokeDeviceCredential(_ credential: String, at base: URL, gatewayID: GatewayID) async throws {
        let fields = credential.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == "hfd1", fields[1].count == 32, fields[2].count == 43 else {
            throw OwnerEnrollmentError.malformedResponse
        }
        var request = URLRequest(url: base.appendingPathComponent("auth/device-revoke"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["device_credential": credential])
        let (data, response) = try await perform(request, pinningGatewayID: gatewayID)
        guard let http = response as? HTTPURLResponse else { throw OwnerEnrollmentError.unreachable }
        try validateStatus(http, data: data)
    }

    private func cleanupLocalEnrollmentMaterial(
        endpointID: GatewayID,
        gatewayID: GatewayID
    ) async throws {
        do {
            // Delete the pending retry identity first. If that secure delete
            // fails, keep the endpoint pin alias so the app can still reach
            // the canonical gateway key on retry. If pin retirement fails,
            // the remaining alias is safe and removal can retry it later.
            try await identities.deleteIdentity(for: endpointID)
            if endpointID != gatewayID, let pinStore {
                try pinStore.syncDeletePin(for: endpointID)
                try approvalStore?.syncSetFirstUseApproved(false, for: endpointID)
            }
        } catch {
            throw OwnerEnrollmentError.identityStorageFailed
        }
    }

    private func validatedBase(_ address: URL) throws -> URL {
        guard let scheme = address.scheme?.lowercased(), let host = address.host,
              !host.isEmpty, address.user == nil, address.password == nil,
              address.port.map({ (1...65535).contains($0) }) ?? true else {
            throw OwnerEnrollmentError.invalidAddress
        }
        guard scheme == "https" else { throw OwnerEnrollmentError.insecureTransport }
        var components = URLComponents(url: address, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        if scheme == "https", components?.port == 443 { components?.port = nil }
        guard let url = components?.url else { throw OwnerEnrollmentError.invalidAddress }
        return url.appending(path: url.path.hasSuffix("/") ? "" : "/")
    }

    private func request(path: String, base: URL, method: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        AuthREST.bounded(&request)
        return try await perform(request)
    }

    private func apply(_ authorization: OwnerAuthorization, to request: inout URLRequest) {
        switch authorization.kind {
        case .bearer:
            request.setValue("Bearer \(authorization.secret)", forHTTPHeaderField: "Authorization")
        case .sessionCookie:
            guard let name = authorization.cookieName else { return }
            request.setValue("\(name)=\(authorization.secret)", forHTTPHeaderField: "Cookie")
        }
    }

    private func revokeRemoteDevice(
        deviceID: String,
        at base: URL,
        authorization: OwnerAuthorization,
        pinningGatewayID: GatewayID? = nil
    ) async throws {
        var request = URLRequest(url: base.appendingPathComponent("api/fleet/devices").appendingPathComponent(deviceID))
        request.httpMethod = "DELETE"
        request.setValue(base.originString, forHTTPHeaderField: "Origin")
        apply(authorization, to: &request)
        let (data, response) = try await perform(request, pinningGatewayID: pinningGatewayID)
        guard let http = response as? HTTPURLResponse else { throw OwnerEnrollmentError.unreachable }
        try validateStatus(http, data: data)
    }

    private static func identity(from credential: String) -> PendingOwnerDeviceIdentity? {
        let fields = credential.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == "hfd1",
              fields[1].count == 32,
              fields[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              fields[2].count == 43,
              fields[2].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return PendingOwnerDeviceIdentity(deviceID: String(fields[1]), secret: String(fields[2]))
    }

    private static func isRevokedEnrollment(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["error"] as? String == "enrollment_revoked"
    }

    private func perform(
        _ request: URLRequest,
        pinningGatewayID override: GatewayID? = nil
    ) async throws -> (Data, URLResponse) {
        let pinningID = override ?? request.url.map(GatewayID.init(endpoint:))
        let handler = fixedTrustHandler ?? pinningID.flatMap { gatewayID in
            if let trustHandlerFactory { return trustHandlerFactory(gatewayID) }
            guard let pinStore else { return nil }
            return PinningTrustHandler(gatewayID: gatewayID, pinStore: pinStore, approvalStore: approvalStore)
        }
        let sessionDelegate = EnrollmentURLSessionDelegate(trustHandler: handler)
        let ownsSession = sessionOverride == nil
        let session: URLSession
        if let sessionOverride {
            session = sessionOverride
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            session = URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
        }
        defer { if ownsSession { session.invalidateAndCancel() } }
        do {
            let result = try await session.data(for: request)
            guard result.0.count <= AuthREST.maxResponseBytes else { throw OwnerEnrollmentError.malformedResponse }
            return result
        } catch let error as OwnerEnrollmentError { throw error }
        catch {
            if let handler {
                switch handler.lastVerdict {
                case .firstUseRequiresConfirmation(let fingerprint):
                    throw OwnerEnrollmentError.tlsFirstUse(fingerprint)
                case .pinMismatch, .internalError:
                    throw OwnerEnrollmentError.tlsPinMismatch
                case .tofuAccept, .pinMatched, .none:
                    break
                }
            }
            throw OwnerEnrollmentError.unreachable
        }
    }

    private func validateStatus(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200..<300: return
        case 300..<400: throw OwnerEnrollmentError.redirectedToUntrustedOrigin
        case 401: throw OwnerEnrollmentError.unauthorized
        case 403:
            let text = String(data: data, encoding: .utf8) ?? ""
            if text.contains("owner_required") { throw OwnerEnrollmentError.ownerRequired }
            throw OwnerEnrollmentError.forbidden
        case 429:
            let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw OwnerEnrollmentError.rateLimited(retryAfterSeconds: seconds)
        default: throw OwnerEnrollmentError.serverRejected(statusCode: response.statusCode)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw OwnerEnrollmentError.malformedResponse }
    }

    private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? 443) == (rhs.port ?? 443)
    }

    private func adoptPinIfAvailable(endpoint: URL, gatewayID: GatewayID) throws {
        guard let pinStore else { return }
        let endpointID = GatewayID(endpoint: endpoint)
        guard endpointID != gatewayID else { return }
        do {
            guard let endpointPin = try pinStore.syncLoadPin(for: endpointID) else { return }
            if let existing = try pinStore.syncLoadPin(for: gatewayID) {
                // A previously registered gateway identity must match. Never
                // replace a pin based on an endpoint alias.
                guard existing == endpointPin else { throw OwnerEnrollmentError.tlsPinMismatch }
            } else {
                try pinStore.syncSavePin(endpointPin, for: gatewayID)
            }
        } catch let error as OwnerEnrollmentError {
            throw error
        } catch {
            throw OwnerEnrollmentError.tlsApprovalUnavailable
        }
    }

    private static func makeIdentity() throws -> PendingOwnerDeviceIdentity {
        var id = [UInt8](repeating: 0, count: 16)
        var secret = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, id.count, &id) == errSecSuccess,
              SecRandomCopyBytes(kSecRandomDefault, secret.count, &secret) == errSecSuccess else {
            throw OwnerEnrollmentError.identityStorageFailed
        }
        let deviceID = id.map { String(format: "%02x", $0) }.joined()
        let encoded = Data(secret).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return PendingOwnerDeviceIdentity(deviceID: deviceID, secret: encoded)
    }
}

private extension URL {
    var originString: String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        return components.string ?? absoluteString
    }
}

final class EnrollmentURLSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let trustHandler: PinningTrustHandler?

    init(trustHandler: PinningTrustHandler?) { self.trustHandler = trustHandler }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trustHandler else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        trustHandler.evaluate(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never forward owner credentials or device secrets to a redirected
        // endpoint, including a same-host path redirect.
        completionHandler(nil)
    }
}
