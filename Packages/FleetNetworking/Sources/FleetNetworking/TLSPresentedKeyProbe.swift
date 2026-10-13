import Foundation
import Security
import FleetCore

/// Observes the SPKI key a secure endpoint presents, then abandons the
/// connection. The server-trust challenge is cancelled right after the key is
/// read, so no HTTP request (and no credential) is ever sent to the peer.
public struct TLSPresentedKeyProbe: TLSKeyProbing {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 8) {
        self.timeout = timeout
    }

    public func presentedKey(for endpoint: URL) async throws -> SPKIFingerprint {
        guard endpoint.scheme?.lowercased() == "https" else { throw TLSKeyReviewError.probeFailed }
        let observer = Observer()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration, delegate: observer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "HEAD"
        // No headers, cookies or credentials: nothing sensitive can leave
        // because the challenge is cancelled before any request is written.
        _ = try? await session.data(for: request)
        guard let fingerprint = observer.fingerprint else { throw TLSKeyReviewError.probeFailed }
        return fingerprint
    }

    private final class Observer: NSObject, URLSessionDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var observed: SPKIFingerprint?
        var fingerprint: SPKIFingerprint? { lock.withLock { observed } }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust,
               let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
               let leaf = chain.first,
               let fingerprint = SPKIExtractor.fingerprint(from: leaf) {
                lock.withLock { if observed == nil { observed = fingerprint } }
            }
            // Always abandon: the probe only reads the key.
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// First-use approvals that never approve. Used where a pin store lacks an
/// approval seam, so an unknown store fails closed instead of trusting
/// whichever certificate appears first.
public struct DenyAllFirstUseApprovals: SynchronousTLSFirstUseApprovalStoring {
    public init() {}
    public func syncIsFirstUseApproved(for gatewayID: GatewayID) throws -> Bool { false }
    public func syncApproveFirstUse(boundTo fingerprint: SPKIFingerprint, for gatewayID: GatewayID) throws {}
    public func syncClearFirstUseApproval(for gatewayID: GatewayID) throws {}
    public func syncConsumeFirstUseApproval(matching presented: SPKIFingerprint, for gatewayID: GatewayID) throws -> Bool { false }
}

extension SynchronousPinStoring {
    /// The approval seam for this pin store, or deny-all when it has none.
    public func firstUseApprovalsOrDenyAll() -> any SynchronousTLSFirstUseApprovalStoring {
        (self as? any SynchronousTLSFirstUseApprovalStoring) ?? DenyAllFirstUseApprovals()
    }
}
