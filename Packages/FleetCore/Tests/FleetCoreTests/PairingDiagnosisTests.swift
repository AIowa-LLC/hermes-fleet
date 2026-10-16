import XCTest
@testable import FleetCore

/// Reachability diagnosis: one plain sentence per failure class (docs/universal-login.md).
final class PairingDiagnosisTests: XCTestCase {
    private func diagnose(_ failure: PairingFailure, host: String? = "fleet.example.test",
                          pinned: Bool = true) -> PairingDiagnosis? {
        PairingDiagnosis.diagnose(failure, host: host, linkIsPinned: pinned)
    }

    func testDNSFailureOnTailnetNameMentionsTailscale() throws {
        let d = try XCTUnwrap(diagnose(.hostNotFound, host: "studio.tail1234.ts.net"))
        XCTAssertEqual(d.kind, .tailscaleDNS)
        XCTAssertEqual(d.message, "Your iPhone can\u{2019}t find studio.tail1234.ts.net. Turn on Tailscale on this iPhone and sign in to the same tailnet as your computer.")
        XCTAssertEqual(try XCTUnwrap(diagnose(.hostNotFound, host: "Studio.TAIL1234.TS.NET")).kind, .tailscaleDNS)
    }

    func testDNSFailureElsewhere() throws {
        let d = try XCTUnwrap(diagnose(.hostNotFound))
        XCTAssertEqual(d.kind, .dns)
        XCTAssertEqual(d.message, "Your iPhone can\u{2019}t find fleet.example.test. Check the link, or that this iPhone is on the same network as your computer.")
        // A name that merely contains ts.net is not a tailnet name.
        XCTAssertEqual(try XCTUnwrap(diagnose(.hostNotFound, host: "ts.net.example.test")).kind, .dns)
    }

    func testTimeoutAndRefusedShareTheNoAnswerSentence() throws {
        for failure in [PairingFailure.timedOut, .connectionRefused] {
            let d = try XCTUnwrap(diagnose(failure))
            XCTAssertEqual(d.kind, .noAnswer)
            XCTAssertEqual(d.message, "fleet.example.test didn\u{2019}t answer. Make sure your computer is awake and Hermes is running (`hermes fleet status`).")
        }
    }

    func testCertificateAndPinFailuresOnPinnedLinks() throws {
        XCTAssertEqual(try XCTUnwrap(diagnose(.untrustedCertificate)).message,
                       "fleet.example.test\u{2019}s certificate isn\u{2019}t trusted and doesn\u{2019}t match the link. Ask Hermes for a new link.")
        XCTAssertEqual(try XCTUnwrap(diagnose(.identityMismatch)).message,
                       "This server isn\u{2019}t the one that made the link. Don\u{2019}t continue; ask Hermes for a new link.")
    }

    func testCertificateFailuresOnUnpinnedLinksKeepOrdinaryWording() {
        XCTAssertNil(diagnose(.untrustedCertificate, pinned: false))
        XCTAssertNil(diagnose(.identityMismatch, pinned: false))
    }

    func testOffline() throws {
        let d = try XCTUnwrap(diagnose(.offline, host: nil))
        XCTAssertEqual(d.kind, .offline)
        XCTAssertEqual(d.message, "This iPhone is offline.")
    }

    func testEveryDiagnosisOffersTryAgainAndOthersAreNotDiagnosed() throws {
        for failure in [PairingFailure.hostNotFound, .timedOut, .connectionRefused, .offline, .untrustedCertificate, .identityMismatch] {
            XCTAssertEqual(try XCTUnwrap(diagnose(failure)).actionTitle, "Try again")
        }
        for failure in [PairingFailure.expired, .alreadyUsed, .cancelled, .rateLimited, .invalidRequest, .unreachable, .malformedLink] {
            XCTAssertNil(diagnose(failure), "\(failure)")
        }
    }

    func testMissingHostUsesAGenericNameAndNeverEmptyText() throws {
        XCTAssertTrue(try XCTUnwrap(diagnose(.timedOut, host: nil)).message.hasPrefix("this server didn"))
    }

    func testNetworkFailuresAreRetryableAndClassified() {
        for failure in [PairingFailure.unreachable, .hostNotFound, .timedOut, .connectionRefused, .offline] {
            XCTAssertTrue(failure.isRetryable)
            XCTAssertTrue(failure.isNetworkFailure)
        }
        XCTAssertFalse(PairingFailure.untrustedCertificate.isNetworkFailure)
    }

    func testClientSecretShapeAndRedaction() throws {
        let first = PairingClientSecret.generate()
        let second = PairingClientSecret.generate()
        XCTAssertEqual(first.rawValue.count, 43)
        XCTAssertNotEqual(first, second)
        XCTAssertNotNil(PairingClientSecret(validating: first.rawValue))
        XCTAssertEqual(PairingInvitationLink.base64URLDecode(first.rawValue)?.count, 32)
        for text in ["\(first)", String(reflecting: first)] {
            XCTAssertFalse(text.contains(first.rawValue))
        }
        XCTAssertNil(PairingClientSecret(validating: "short"))
        XCTAssertNil(PairingClientSecret(validating: String(repeating: "!", count: 43)))
    }

    func testSpacedMatchCode() throws {
        let request = PairingApprovalRequest(
            id: "r", matchCode: "482913", expiresAt: Date(), pollInterval: 2,
            gateway: PairingGatewayIdentity(instanceID: String(repeating: "a", count: 32), displayName: "x",
                                            origin: try XCTUnwrap(URL(string: "https://fleet.example.test"))),
            scopes: ["fleet:operator"], tlsFingerprint: try XCTUnwrap(SPKIFingerprint(sha256Digest: Data(repeating: 1, count: 32))))
        XCTAssertEqual(request.spacedMatchCode, "482 913")
    }

    func testMatchCodePresentation() {
        XCTAssertEqual(PairingMatchCode.spaced("482913"), "482 913")
        XCTAssertEqual(PairingMatchCode.spaced("48291"), "48291")
        XCTAssertEqual(PairingMatchCode.spaced("48a913"), "48a913")
        XCTAssertEqual(PairingMatchCode.spoken("482913"), "4, 8, 2, 9, 1, 3")
        XCTAssertEqual(PairingMatchCode.approveCommand("482913"), "/fleet approve 482913")
        XCTAssertEqual(PairingMatchCode.normalized("482 913"), "482913")
    }
}
