import XCTest
import Security
@testable import FleetCore
@testable import FleetNetworking

/// The v2 approval exchange (preview with a pin, request, poll) against a REAL loopback HTTPS
/// server with throwaway certificates, so trust, pinning and wire shapes are the real ones.
final class GatewayPairingApprovalTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ScriptedPairingServer.isAvailable, "python3/openssl not available")
    }

    private let secret = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"

    /// Runs `body` and returns the typed failure it threw (nil when it succeeded).
    private func thrown<T>(_ body: () async throws -> T) async -> PairingFailure? {
        do { _ = try await body(); return nil } catch { return error as? PairingFailure }
    }

    private struct Fixture {
        let server: ScriptedPairingServer
        let client: GatewayPairingClient
        let link: PairingInvitationLink
    }

    /// `trusted`: the client's system trust is anchored to the server's certificates (an
    /// ordinary publicly-trusted server). Otherwise the client uses the real system trust, which
    /// rejects the throwaway certificate, so only the link's pin can admit the server.
    private func make(_ behavior: ScriptedPairingServer.Behavior, trusted: Bool = false) throws -> Fixture {
        let server = try ScriptedPairingServer(behavior)
        addTeardownBlock { server.stop() }
        let client = trusted ? GatewayPairingClient(trust: server.trust()) : GatewayPairingClient()
        return Fixture(server: server, client: client, link: try server.linkV2())
    }

    private func requested(_ f: Fixture, secret clientSecret: PairingClientSecret = .generate())
        async throws -> (PairingPreview, PairingApprovalRequest, PairingClientSecret) {
        let preview = try await f.client.preview(f.link)
        let request = try await f.client.requestApproval(
            f.link, deviceName: "Synthetic iPhone", deviceModel: "iPhone17,1",
            clientSecret: clientSecret, expecting: preview)
        return (preview, request, clientSecret)
    }

    // MARK: preview

    func testPinnedPreviewAcceptsASelfSignedServerWhoseKeyMatchesThePin() async throws {
        let f = try make(.approval)
        let preview = try await f.client.preview(f.link)
        XCTAssertTrue(preview.approvalRequired)
        XCTAssertEqual(preview.protocols, [1, 2])
        XCTAssertEqual(preview.tlsFingerprint, SPKIExtractor.fingerprint(from: f.server.certificate))
        XCTAssertEqual(f.server.requests.map(\.path), ["/api/fleet/pairing/preview"])
    }

    func testPinnedPreviewAlsoAcceptsASystemTrustedServerWithTheMatchingKey() async throws {
        let f = try make(.approval, trusted: true)
        let preview = try await f.client.preview(f.link)
        XCTAssertEqual(preview.gateway.displayName, "Scripted Gateway")
    }

    func testPinMismatchWithATrustedCertificateIsAnIdentityMismatchAndNothingIsSent() async throws {
        let f = try make(.approval, trusted: true)
        let wrong = try XCTUnwrap(SPKIFingerprint(sha256Digest: Data(repeating: 9, count: 32)))
        let link = try f.server.linkV2(pin: wrong)
        let failure = await thrown { try await f.client.preview(link) }
        XCTAssertEqual(failure, .identityMismatch)
        XCTAssertTrue(f.server.requests.isEmpty, "the secret must not reach a server with the wrong key")
    }

    func testPinMismatchWithAnUntrustedCertificateIsUntrusted() async throws {
        let f = try make(.approval)
        let wrong = try XCTUnwrap(SPKIFingerprint(sha256Digest: Data(repeating: 9, count: 32)))
        let failure = await thrown { try await f.client.preview(try f.server.linkV2(pin: wrong)) }
        XCTAssertEqual(failure, .untrustedCertificate)
        XCTAssertTrue(f.server.requests.isEmpty)
    }

    func testAnUnpinnedLinkStillRequiresSystemTrust() async throws {
        let server = try ScriptedPairingServer(.ok)
        addTeardownBlock { server.stop() }
        let failure = await thrown { try await GatewayPairingClient().preview(try server.link()) }
        XCTAssertEqual(failure, .untrustedCertificate)
    }

    func testV2LinkAgainstAnInvitationThatDoesNotRequireApprovalIsRefused() async throws {
        let f = try make(.ok)
        let failure = await thrown { try await f.client.preview(f.link) }
        XCTAssertEqual(failure, .malformedResponse)
    }

    func testV1LinkAgainstAnInvitationThatRequiresApprovalIsRefused() async throws {
        let server = try ScriptedPairingServer(.legacyApprovalRequired)
        addTeardownBlock { server.stop() }
        let failure = await thrown { try await GatewayPairingClient(trust: server.trust()).preview(try server.link()) }
        XCTAssertEqual(failure, .approvalRequired)
    }

    // MARK: request

    func testRequestSendsTheClientSecretOnlyInTheBodyAndReturnsTheMatchCode() async throws {
        let f = try make(.approval)
        let clientSecret = PairingClientSecret.generate()
        let (preview, request, _) = try await requested(f, secret: clientSecret)
        XCTAssertEqual(request.matchCode, "482913")
        XCTAssertEqual(request.spacedMatchCode, "482 913")
        XCTAssertEqual(request.pollInterval, 2)
        XCTAssertEqual(request.expiresAt.timeIntervalSinceNow, 600, accuracy: 5)
        XCTAssertEqual(request.scopes, ["fleet:operator"])
        XCTAssertEqual(request.tlsFingerprint, preview.tlsFingerprint)

        let sent = try XCTUnwrap(f.server.requests.last)
        XCTAssertEqual(sent.path, "/api/fleet/pairing/request")
        XCTAssertEqual(sent.query, "")
        XCTAssertTrue(sent.body.contains(clientSecret.rawValue))
        XCTAssertTrue(sent.body.contains("iPhone17,1"))
        XCTAssertTrue(sent.body.contains(secret))
        for (name, value) in sent.headers {
            XCTAssertFalse(value.contains(clientSecret.rawValue), "client secret leaked into header \(name)")
            XCTAssertFalse(value.contains(secret), "invitation secret leaked into header \(name)")
        }
    }

    func testRepeatingARequestWithTheSameClientSecretIsIdempotentAndADifferentOneIsRefused() async throws {
        let f = try make(.approval)
        let clientSecret = PairingClientSecret.generate()
        let (preview, first, _) = try await requested(f, secret: clientSecret)
        let again = try await f.client.requestApproval(
            f.link, deviceName: "x", deviceModel: "y", clientSecret: clientSecret, expecting: preview)
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(again.matchCode, first.matchCode)
        let failure = await thrown { try await f.client.requestApproval( f.link, deviceName: "x", deviceModel: "y", clientSecret: .generate(), expecting: preview) }
        XCTAssertEqual(failure, .alreadyUsed)
    }

    func testRequestRefusesAnAnnouncedUnsupportedGatewayAndBadMatchCodes() async throws {
        let unsupported = try make(.approvalNotSupported)
        // approvalNotSupported previews as a plain invitation, so the request is attempted directly.
        let preview = PairingPreview(
            gateway: PairingGatewayIdentity(instanceID: String(repeating: "ab12cd34", count: 4),
                                            displayName: "x", origin: unsupported.server.origin),
            label: "", access: [PairingAccess(scope: "fleet:operator", summary: "")],
            expiresAt: Date().addingTimeInterval(60),
            tlsFingerprint: try XCTUnwrap(SPKIExtractor.fingerprint(from: unsupported.server.certificate)))
        let unsupportedFailure = await thrown {
            try await unsupported.client.requestApproval(
                unsupported.link, deviceName: "x", deviceModel: "y", clientSecret: .generate(), expecting: preview)
        }
        XCTAssertEqual(unsupportedFailure, .approvalNotSupported)
        let bad = try make(.approvalBadMatchCode)
        let failure = await thrown { try await requested(bad) }
        XCTAssertEqual(failure, .malformedResponse)
    }

    func testRequestRefusesAPreviewWhoseKeyIsNotTheLinksPin() async throws {
        let f = try make(.approval)
        let preview = try await f.client.preview(f.link)
        let other = PairingPreview(
            gateway: preview.gateway, label: preview.label, access: preview.access, expiresAt: preview.expiresAt,
            tlsFingerprint: try XCTUnwrap(SPKIFingerprint(sha256Digest: Data(repeating: 2, count: 32))))
        let failure = await thrown { try await f.client.requestApproval( f.link, deviceName: "x", deviceModel: "y", clientSecret: .generate(), expecting: other) }
        XCTAssertEqual(failure, .identityMismatch)
        XCTAssertEqual(f.server.requests.map(\.path), ["/api/fleet/pairing/preview"])
    }

    func testRequestRequiresAV2Link() async throws {
        let server = try ScriptedPairingServer(.ok)
        addTeardownBlock { server.stop() }
        let client = GatewayPairingClient(trust: server.trust())
        let preview = try await client.preview(try server.link())
        let failure = await thrown { try await client.requestApproval( try server.link(), deviceName: "x", deviceModel: "y", clientSecret: .generate(), expecting: preview) }
        XCTAssertEqual(failure, .approvalNotSupported)
    }

    // MARK: poll

    func testPollReportsPendingThenApprovedWithAGrantBoundToThePinnedKey() async throws {
        let f = try make(.approval)
        let (_, request, clientSecret) = try await requested(f)
        let first = try await f.client.pollApproval(request, clientSecret: clientSecret)
        XCTAssertEqual(first, .pending)
        let second = try await f.client.pollApproval(request, clientSecret: clientSecret)
        guard case .approved(let grant) = second else { return XCTFail("\(second)") }
        XCTAssertEqual(grant.deviceID, String(repeating: "0123abcd", count: 4))
        XCTAssertTrue(grant.credential.rawValue.hasPrefix("hfd1."))
        XCTAssertEqual(grant.tlsFingerprint, SPKIExtractor.fingerprint(from: f.server.certificate),
                       "the confirmed key becomes the saved TLS pin")
        XCTAssertEqual(grant.gateway.instanceID, request.gateway.instanceID)
        // Approval is returned on every poll until collected (idempotent for lost responses).
        let third = try await f.client.pollApproval(request, clientSecret: clientSecret)
        guard case .approved(let again) = third else { return XCTFail("\(third)") }
        XCTAssertEqual(again, grant)
        for text in ["\(grant)", String(reflecting: grant.credential), "\(clientSecret)"] {
            XCTAssertFalse(text.contains("hfd1")); XCTAssertFalse(text.contains(clientSecret.rawValue))
        }
        let polls = f.server.requests.filter { $0.path.hasSuffix("/request/status") }
        XCTAssertEqual(polls.count, 3)
        XCTAssertTrue(polls.allSatisfy { $0.body.contains(request.id) && $0.body.contains(clientSecret.rawValue) })
    }

    func testPollWithTheWrongClientSecretIsInvalidRequest() async throws {
        let f = try make(.approval)
        let (_, request, _) = try await requested(f)
        let failure = await thrown { try await f.client.pollApproval(request, clientSecret: .generate()) }
        XCTAssertEqual(failure, .invalidRequest)
    }

    func testPollTerminalStatuses() async throws {
        let cases: [(ScriptedPairingServer.Behavior, PairingApprovalStatus)] = [
            (.approvalPending, .pending), (.approvalDenied, .denied),
            (.approvalExpired, .expired), (.approvalDelivered, .delivered),
        ]
        for (behavior, expected) in cases {
            let f = try make(behavior)
            let (_, request, clientSecret) = try await requested(f)
            let status = try await f.client.pollApproval(request, clientSecret: clientSecret)
            XCTAssertEqual(status, expected, "\(behavior)")
        }
    }

    func testPollRateLimitIsReportedAsRateLimited() async throws {
        let f = try make(.approvalPollLimited)
        let (_, request, clientSecret) = try await requested(f)
        let failure = await thrown { try await f.client.pollApproval(request, clientSecret: clientSecret) }
        XCTAssertEqual(failure, .rateLimited)
        XCTAssertEqual(failure?.isRetryable, true)
    }

    func testApprovedCredentialFromADifferentInstallationIsRevokedAndRefused() async throws {
        let f = try make(.approvalWrongInstance)
        let (_, request, clientSecret) = try await requested(f)
        let failure = await thrown { try await f.client.pollApproval(request, clientSecret: clientSecret) }
        XCTAssertEqual(failure, .identityMismatch)
        XCTAssertEqual(f.server.requests.last?.path, "/auth/device-revoke",
                       "a credential that cannot be kept is revoked on the gateway")
    }

    func testPollNeverSendsAnythingToAServerWhoseKeyChanged() async throws {
        let f = try make(.approvalPending)
        let (_, request, clientSecret) = try await requested(f)
        let moved = PairingApprovalRequest(
            id: request.id, matchCode: request.matchCode, expiresAt: request.expiresAt,
            pollInterval: request.pollInterval, gateway: request.gateway, scopes: request.scopes,
            tlsFingerprint: try XCTUnwrap(SPKIFingerprint(sha256Digest: Data(repeating: 4, count: 32))))
        let before = f.server.requests.count
        let failure = await thrown { try await f.client.pollApproval(moved, clientSecret: clientSecret) }
        XCTAssertNotNil(failure)
        XCTAssertEqual(f.server.requests.count, before, "the client secret must not reach a different key")
    }

    func testPollIntervalIsClamped() {
        XCTAssertEqual(GatewayPairingClient.clampedPollInterval(nil), 2)
        XCTAssertEqual(GatewayPairingClient.clampedPollInterval(0.1), 1)
        XCTAssertEqual(GatewayPairingClient.clampedPollInterval(3), 3)
        XCTAssertEqual(GatewayPairingClient.clampedPollInterval(600), 10)
    }

    func testNetworkFailuresAreClassified() {
        let observed = PairingExchange.Observed()
        let cases: [(URLError.Code, PairingFailure)] = [
            (.cannotFindHost, .hostNotFound), (.dnsLookupFailed, .hostNotFound), (.timedOut, .timedOut),
            (.cannotConnectToHost, .connectionRefused), (.notConnectedToInternet, .offline),
            (.dataNotAllowed, .offline), (.networkConnectionLost, .unreachable), (.cancelled, .interrupted),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(GatewayPairingClient.failure(for: URLError(code), observed: observed), expected, "\(code)")
        }
    }

    func testApprovalErrorCodesMapToFailures() {
        let cases: [(String, Int, PairingFailure)] = [
            ("invalid_request", 404, .invalidRequest), ("already_redeemed", 409, .alreadyUsed),
            ("approval_not_supported", 409, .approvalNotSupported), ("approval_required", 409, .approvalRequired),
            ("rate_limited", 429, .rateLimited),
        ]
        for (code, status, expected) in cases {
            let body = Data(#"{"error":"\#(code)"}"#.utf8)
            XCTAssertEqual(GatewayPairingClient.failure(forStatus: status, body: body), expected, code)
        }
    }
}
