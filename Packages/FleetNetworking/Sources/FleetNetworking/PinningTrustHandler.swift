import Foundation
import Security
import FleetCore

/// T3 — URLSession challenge evaluation applying the TOFU SPKI pin verdict.
///
/// Used as (part of) the session delegate for every gateway connection URL
/// session (WebSocket + auth HTTPS). Server-trust challenges are decided by
/// `TLSTrustEvaluator`:
/// - `.tofuAccept` / `.pinMatched` → `.useCredential` with a trust derived
///   from the CHALLENGE's SecTrust (trusts the self-signed cert by pin,
///   ignoring system roots);
/// - `.pinMismatch` / `.internalError` → `.cancelAuthenticationChallenge`
///   (REJECT — the connection never completes; no data flows to an
///   untrusted peer).
/// Non-server-trust challenges are `.performDefaultHandling` (not ours).
public final class PinningTrustHandler: @unchecked Sendable {
    public let gatewayID: GatewayID
    private let evaluator: TLSTrustEvaluator

    /// The last verdict observed (diagnostic seam for tests / logging; the
    /// pins are public key material, safe to expose).
    public private(set) var lastVerdict: TLSTrustVerdict?

    private let lock = NSLock()

    public init(gatewayID: GatewayID, pinStore: any SynchronousPinStoring) {
        self.gatewayID = gatewayID
        self.evaluator = TLSTrustEvaluator(gatewayID: gatewayID, pinStore: pinStore)
    }

    /// Evaluate a server-trust authentication challenge (the URLSession
    /// delegate entry point). The SecTrust is extracted from the challenge's
    /// protection space — it only exists on REAL session challenges.
    public func evaluate(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        evaluate(serverTrust: trust, completionHandler: completionHandler)
    }

    /// Decide a server-trust challenge from its `SecTrust` (testable seam —
    /// a synthetic URLProtectionSpace cannot carry a serverTrust, so unit
    /// tests drive this directly; the challenge-level path is exercised by
    /// the live TLS fixture suite).
    public func evaluate(
        serverTrust trust: SecTrust,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // The presented certificate chain from the challenge's server trust.
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let verdict = evaluator.verdict(forPresentedCertificate: leaf)
        lock.lock()
        lastVerdict = verdict
        lock.unlock()
        switch verdict {
        case .tofuAccept, .pinMatched:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .pinMismatch, .internalError:
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
