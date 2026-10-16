import Foundation

/// Turns a pairing failure into one plain sentence and one action, following the
/// "Reachability diagnosis" section of `docs/universal-login.md`.
///
/// Pure and payload-free: the only input besides the failure is the host the link names (what
/// the owner sees anyway). It never sees a link, secret, key or server-supplied text.
public struct PairingDiagnosis: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// DNS failure on a `*.ts.net` name: Tailscale is probably off on this phone.
        case tailscaleDNS
        /// DNS failure on any other name.
        case dns
        /// Timeout or refused connection.
        case noAnswer
        /// The certificate is not system-trusted and the key does not match the link's pin.
        case untrustedWithoutPin
        /// The key does not match the link's pin although the certificate may be trusted.
        case pinMismatch
        /// This phone has no connection.
        case offline
    }

    public let kind: Kind
    /// The sentence the person reads.
    public let message: String
    /// Every diagnosis offers "Try again".
    public let actionTitle = "Try again"

    /// Classify `failure` for a link naming `host`. Returns nil when the failure is not a
    /// reachability or first-contact trust problem (the caller uses its ordinary wording).
    ///
    /// - Parameter linkIsPinned: whether the link carried a key pin (version 2). Without a
    ///   pin there is nothing for a certificate to "match", so the certificate failures keep
    ///   their ordinary wording.
    public static func diagnose(_ failure: PairingFailure, host: String?, linkIsPinned: Bool) -> PairingDiagnosis? {
        let name = host?.isEmpty == false ? host! : "this server"
        switch failure {
        case .hostNotFound:
            if let host = host?.lowercased(), host.hasSuffix(".ts.net") {
                return PairingDiagnosis(
                    kind: .tailscaleDNS,
                    message: "Your iPhone can\u{2019}t find \(name). Turn on Tailscale on this iPhone and sign in to the same tailnet as your computer.")
            }
            return PairingDiagnosis(
                kind: .dns,
                message: "Your iPhone can\u{2019}t find \(name). Check the link, or that this iPhone is on the same network as your computer.")
        case .timedOut, .connectionRefused:
            return PairingDiagnosis(
                kind: .noAnswer,
                message: "\(name) didn\u{2019}t answer. Make sure your computer is awake and Hermes is running (`hermes fleet status`).")
        case .untrustedCertificate where linkIsPinned:
            return PairingDiagnosis(
                kind: .untrustedWithoutPin,
                message: "\(name)\u{2019}s certificate isn\u{2019}t trusted and doesn\u{2019}t match the link. Ask Hermes for a new link.")
        case .identityMismatch where linkIsPinned:
            return PairingDiagnosis(
                kind: .pinMismatch,
                message: "This server isn\u{2019}t the one that made the link. Don\u{2019}t continue; ask Hermes for a new link.")
        case .offline:
            return PairingDiagnosis(kind: .offline, message: "This iPhone is offline.")
        default:
            return nil
        }
    }
}
