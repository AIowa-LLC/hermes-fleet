import Foundation
import FleetCore

/// Card C — per-gateway construction of the artifact retriever.
///
/// Mirrors the credential resolution the kanban watcher uses (one seam per
/// gateway, no second credential path), so the app graph can wire artifacts
/// with a single line:
///
/// ```swift
/// let artifacts = GatewayArtifactRetrieval.make(
///     gateway: gateway, credentialStore: credentialStore, pinStore: pinStore)
/// ```
///
/// - Token strategies (`loopbackToken` / `sessionToken` / `bearerToken`):
///   the stored credential rides `X-Hermes-Session-Token` on the media fetch
///   (the same path the ws-ticket mint and the kanban board fetch use).
/// - `usernamePassword`: a fresh `POST /auth/password-login` per retrieval,
///   replayed as the login `Cookie`.
/// - `none`: anonymous (a 401 from the gateway surfaces honestly).
/// - A gateway row with no endpoint gets the fail-closed
///   `UnsupportedArtifactRetrieval` stub — never a phantom loopback probe.
/// - https gateways receive the SAME per-gateway TOFU pin policy
///   (`PinningTrustHandler`) as every other credential-bearing REST session.
public enum GatewayArtifactRetrieval {

    public static func make(
        gateway: FleetGateway,
        credentialStore: any CredentialStoring,
        pinStore: (any SynchronousPinStoring)? = nil,
        limits: ArtifactTransferLimits = .standard,
        urlSessionConfiguration: URLSessionConfiguration = .ephemeral
    ) -> any ArtifactRetrieving {
        guard let base = gateway.endpoint else {
            return UnsupportedArtifactRetrieval(gatewayID: gateway.id)
        }

        // The gateway-scoped trust policy (https only; http is explicitly
        // cleartext and handled by the endpoint warning policy).
        var trustHandler: PinningTrustHandler?
        if base.scheme?.lowercased() == "https", let pinStore {
            trustHandler = PinningTrustHandler(
                gatewayID: gateway.id,
                pinStore: pinStore,
                approvalStore: pinStore as? any SynchronousTLSFirstUseApprovalStoring)
        }
        let loginSession: URLSession
        if let trustHandler {
            loginSession = URLSession(
                configuration: urlSessionConfiguration,
                delegate: URLSessionPinningDelegate(trustHandler: trustHandler),
                delegateQueue: nil)
        } else {
            loginSession = URLSession(configuration: urlSessionConfiguration)
        }

        let strategy = gateway.authConfiguration.strategy
        let gatewayID = gateway.id
        let credential: @Sendable () async throws -> GatewayArtifactClient.HTTPCredential = {
            switch strategy {
            case .none:
                return .none
            case .loopbackToken, .sessionToken, .bearerToken:
                guard let stored = try? await credentialStore.loadCredential(for: gatewayID) else {
                    throw ArtifactTransportError.authenticationRequired(
                        detail: "no stored credential for this gateway")
                }
                return .sessionTokenHeader(stored.rawValue)
            case .usernamePassword:
                guard let stored = try? await credentialStore.loadCredential(for: gatewayID),
                      let username = stored.username else {
                    throw ArtifactTransportError.authenticationRequired(
                        detail: "no stored credential for this gateway")
                }
                let cookie = try await PasswordLoginClient(
                    baseURL: base, urlSession: loginSession
                ).login(username: username, password: stored.rawValue)
                return .cookie(cookie)
            }
        }

        return GatewayArtifactClient(
            gatewayID: gatewayID,
            baseURL: base,
            credential: credential,
            limits: limits,
            urlSessionConfiguration: urlSessionConfiguration,
            trustHandler: trustHandler)
    }
}
