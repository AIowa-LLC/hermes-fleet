import Foundation
import Security
import FleetCore

/// T3 — the typed TOFU trust verdict for one presented certificate.
public enum TLSTrustVerdict: Sendable, Equatable {
    /// First use: no pin stored; the presented pin was accepted AND written
    /// to the store (trust on first use).
    case tofuAccept(SPKIFingerprint)
    /// The presented certificate's SPKI matches the stored pin.
    case pinMatched(SPKIFingerprint)
    /// First use was blocked because the user has not explicitly approved
    /// trusting this gateway's presented key.
    case firstUseRequiresConfirmation(SPKIFingerprint)
    /// The presented certificate's SPKI differs from the stored pin —
    /// MITM or replaced certificate. REJECT.
    case pinMismatch(expected: SPKIFingerprint, presented: SPKIFingerprint)
    /// The pin store failed or the certificate key could not be processed.
    /// REJECT (fail closed) — an unavailable store is not "no pin".
    case internalError(String)
}

/// T3 — TOFU (trust-on-first-use) SPKI pinning decision for a gateway.
///
/// Pure decision logic over the `SynchronousPinStoring` seam (the URLSession
/// challenge callback cannot await):
/// - no stored pin → `.tofuAccept` and the pin is WRITTEN (first use trusts);
/// - stored pin == presented pin → `.pinMatched` (connect);
/// - stored pin != presented pin → `.pinMismatch` (REJECT; the composition
///   root surfaces the warn-on-change flow to the user);
/// - store error / unextractable key → `.internalError` (REJECT, fail
///   closed).
public struct TLSTrustEvaluator: Sendable {
    public let gatewayID: GatewayID
    private let pinStore: any SynchronousPinStoring
    private let approvalStore: (any SynchronousTLSFirstUseApprovalStoring)?

    public init(
        gatewayID: GatewayID,
        pinStore: any SynchronousPinStoring,
        approvalStore: (any SynchronousTLSFirstUseApprovalStoring)? = nil
    ) {
        self.gatewayID = gatewayID
        self.pinStore = pinStore
        self.approvalStore = approvalStore
    }

    /// Evaluate the presented leaf certificate. Synchronous by design (the
    /// URLSession challenge delegate callback is sync).
    public func verdict(forPresentedCertificate certificate: SecCertificate) -> TLSTrustVerdict {
        guard let presented = SPKIExtractor.fingerprint(from: certificate) else {
            return .internalError("could not derive SPKI pin from presented certificate")
        }
        let expected: SPKIFingerprint?
        do {
            expected = try pinStore.syncLoadPin(for: gatewayID)
        } catch {
            return .internalError("pin store unavailable (fail closed)")
        }
        guard let expected else {
            // Production requires an explicit user decision before TOFU can
            // persist a key. Tests and non-production callers may omit the
            // approval seam to preserve the pure evaluator's legacy contract.
            if let approvalStore {
                do {
                    guard try approvalStore.syncIsFirstUseApproved(for: gatewayID) else {
                        return .firstUseRequiresConfirmation(presented)
                    }
                } catch {
                    return .internalError("first-use approval store unavailable (fail closed)")
                }
            }
            // Trust on first use: accept AND persist the pin only after the
            // explicit approval above.
            do {
                try pinStore.syncSavePin(presented, for: gatewayID)
            } catch {
                return .internalError("pin store write failed; refusing to trust unpinned")
            }
            return .tofuAccept(presented)
        }
        if presented == expected {
            return .pinMatched(expected)
        }
        return .pinMismatch(expected: expected, presented: presented)
    }
}
