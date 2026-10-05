import Foundation
import Security
import FleetCore

/// T3 — the typed TOFU trust verdict for one presented certificate.
public enum TLSTrustVerdict: Sendable, Equatable {
    /// First use: no pin stored; the presented pin was accepted after any
    /// configured explicit approval and written to the store.
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
/// - no stored pin → require an approval for exactly the presented key (a
///   fingerprint the user reviewed), consume it, then `.tofuAccept` and write
///   the pin with compare-and-set. There is no unapproved first-use path;
/// - stored pin == presented pin → `.pinMatched` (connect);
/// - stored pin != presented pin → `.pinMismatch` (REJECT; the composition
///   root surfaces the warn-on-change flow to the user);
/// - store error / unextractable key → `.internalError` (REJECT, fail
///   closed).
public struct TLSTrustEvaluator: Sendable {
    public let gatewayID: GatewayID
    private static let firstUseLock = NSLock()
    private let pinStore: any SynchronousPinStoring
    private let approvalStore: any SynchronousTLSFirstUseApprovalStoring

    public init(
        gatewayID: GatewayID,
        pinStore: any SynchronousPinStoring,
        approvalStore: any SynchronousTLSFirstUseApprovalStoring
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
            // First use is decided under ONE process-wide lock so the approval
            // consume and the pin write are atomic with respect to other
            // connections racing for the same gateway: a loser always sees the
            // winner's pin (and matches or mismatches it), never a gap.
            Self.firstUseLock.lock()
            defer { Self.firstUseLock.unlock() }
            do {
                if let raced = try pinStore.syncLoadPin(for: gatewayID) {
                    return raced == presented
                        ? .pinMatched(raced)
                        : .pinMismatch(expected: raced, presented: presented)
                }
            } catch {
                return .internalError("pin store unavailable (fail closed)")
            }
            // First use REQUIRES an approval for exactly this presented key
            // (a reviewed fingerprint). There is no unapproved TOFU path.
            do {
                // Atomic check-and-consume for THIS presented key: the
                // approval is single-use and only matches the exact SPKI the
                // user reviewed.
                guard try approvalStore.syncConsumeFirstUseApproval(
                    matching: presented, for: gatewayID) else {
                    // A concurrent connection may have pinned this same key a
                    // moment ago; that is a match, not a first use.
                    if let raced = try? pinStore.syncLoadPin(for: gatewayID) {
                        return raced == presented
                            ? .pinMatched(raced)
                            : .pinMismatch(expected: raced, presented: presented)
                    }
                    return .firstUseRequiresConfirmation(presented)
                }
            } catch {
                return .internalError("first-use approval store unavailable (fail closed)")
            }
            // Trust on first use: persist only if no pin appeared meanwhile
            // (compare-and-set), never overwriting an established pin.
            do {
                guard try pinStore.syncSavePinIfAbsent(presented, for: gatewayID) else {
                    guard let current = try pinStore.syncLoadPin(for: gatewayID) else {
                        return .internalError("pin store changed during first use (fail closed)")
                    }
                    return current == presented
                        ? .pinMatched(current)
                        : .pinMismatch(expected: current, presented: presented)
                }
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
