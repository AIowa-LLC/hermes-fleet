import XCTest
import Security
@testable import FleetCore
@testable import FleetNetworking

/// The pairing client against a REAL HTTPS server on loopback (see `ScriptedPairingServer`):
/// real TLS handshakes, real certificate validation, real URLSession behavior.
final class GatewayPairingClientTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ScriptedPairingServer.isAvailable, "python3/openssl not available")
    }

    private func make(_ behavior: ScriptedPairingServer.Behavior) throws
        -> (ScriptedPairingServer, GatewayPairingClient, PairingInvitationLink) {
        let server = try ScriptedPairingServer(behavior)
        addTeardownBlock { server.stop() }
        return (server, GatewayPairingClient(trust: server.trust()), try server.link())
    }

    private let secret = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"

    // MARK: happy path

    func testPreviewReturnsTheGatewayIdentityAndAccessWithoutRedeeming() async throws {
        let (server, client, link) = try make(.ok)
        let preview = try await client.preview(link)

        XCTAssertEqual(preview.gateway.displayName, "Scripted Gateway")
        XCTAssertEqual(preview.gateway.instanceID, String(repeating: "ab12cd34", count: 4))
        XCTAssertEqual(preview.gateway.origin, server.origin)
        XCTAssertEqual(preview.access.map(\.scope), ["fleet:operator"])
        XCTAssertEqual(preview.access.first?.summary, PairingScope.fleetOperator.summary,
                       "the app shows its OWN wording, not server text")
        XCTAssertEqual(preview.label, "Tony's phone")
        XCTAssertEqual(preview.expiresAt.timeIntervalSinceNow, 600, accuracy: 5)
        XCTAssertEqual(server.requests.map(\.path), ["/api/fleet/pairing/preview"],
                       "previewing sends exactly one request and never redeems")
    }

    func testSecretTravelsOnlyInThePostBody() async throws {
        let (server, client, link) = try make(.ok)
        _ = try await client.preview(link)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.query, "")
        XCTAssertFalse(request.path.contains(secret))
        for (name, value) in request.headers {
            XCTAssertFalse(value.contains(secret), "secret leaked into header \(name)")
            XCTAssertFalse(value.contains("AbCdEfGhIjKlMnOpQrStUv"), "invitation id leaked into header \(name)")
        }
        XCTAssertTrue(request.body.contains(secret))
        XCTAssertNil(request.headers["cookie"])
        XCTAssertNil(request.headers["authorization"])
        XCTAssertEqual(request.headers["cache-control"], "no-store")
    }

    func testRedeemYieldsAGrantBoundToTheConfirmedKey() async throws {
        let (server, client, link) = try make(.ok)
        let preview = try await client.preview(link)
        let grant = try await client.redeem(link, deviceName: "Tony's iPhone", expecting: preview)

        XCTAssertEqual(grant.gateway.instanceID, preview.gateway.instanceID)
        XCTAssertEqual(grant.tlsFingerprint, preview.tlsFingerprint)
        XCTAssertEqual(grant.deviceID, String(repeating: "0123abcd", count: 4))
        XCTAssertTrue(grant.credential.rawValue.hasPrefix("hfd1."))
        XCTAssertEqual(server.requests.map(\.path),
                       ["/api/fleet/pairing/preview", "/api/fleet/pairing/redeem"])
        XCTAssertTrue(try XCTUnwrap(server.requests.last).body.contains("Tony's iPhone"))
        // The key pinned for later connections is the SPKI of the validated certificate.
        let expected = try XCTUnwrap(SPKIExtractor.fingerprint(from: server.certificate))
        XCTAssertEqual(grant.tlsFingerprint, expected)
    }

    func testGrantAndCredentialNeverPrintTheSecret() async throws {
        let (_, client, link) = try make(.ok)
        let preview = try await client.preview(link)
        let grant = try await client.redeem(link, deviceName: "x", expecting: preview)
        for text in ["\(grant)", String(reflecting: grant.credential), "\(grant.credential)", "\(client)", "\(link)"] {
            XCTAssertFalse(text.contains("hfd1"), text)
            XCTAssertFalse(text.contains(secret), text)
        }
    }

    // MARK: TLS

    func testRefusesACertificateTheSystemDoesNotTrust() async throws {
        let server = try ScriptedPairingServer(.ok)
        addTeardownBlock { server.stop() }
        let client = GatewayPairingClient()      // the system's own evaluation
        let link = try server.link()
        do {
            _ = try await client.preview(link)
            XCTFail("a self-signed certificate must not be trusted")
        } catch {
            XCTAssertEqual(error, .untrustedCertificate)
        }
        XCTAssertTrue(server.requests.isEmpty, "no request body may be sent to an untrusted peer")
    }

    func testRefusesToRedeemWhenTheGatewayKeyChangedAfterThePreview() async throws {
        let (server, client, link) = try make(.rotateKey)
        let preview = try await client.preview(link)

        do {
            _ = try await client.redeem(link, deviceName: "x", expecting: preview)
            XCTFail("a different key must stop the redemption")
        } catch {
            XCTAssertEqual(error, .identityMismatch)
        }
        XCTAssertEqual(server.requests.map(\.path), ["/api/fleet/pairing/preview"],
                       "the secret must never be sent to a gateway whose key changed")
    }

    // MARK: hostile responses

    func testRefusesRedirects() async throws {
        let (server, client, link) = try make(.redirect)
        do {
            _ = try await client.preview(link)
            XCTFail("a redirect must not be followed")
        } catch {
            XCTAssertEqual(error, .malformedResponse)
        }
        XCTAssertEqual(server.requests.count, 1)
    }

    func testAnOlderGatewayThatAnswersWithItsWebPageIsReportedAsUnsupported() async throws {
        let (_, client, link) = try make(.html)
        do {
            _ = try await client.preview(link)
            XCTFail()
        } catch {
            XCTAssertEqual(error, .pairingUnavailable)
        }
    }

    func testRejectsOversizedAndNonProtocolResponses() async throws {
        for behavior: ScriptedPairingServer.Behavior in [.huge, .garbage] {
            let (_, client, link) = try make(behavior)
            do {
                _ = try await client.preview(link)
                XCTFail("\(behavior)")
            } catch {
                XCTAssertEqual(error, .malformedResponse, "\(behavior)")
            }
        }
    }

    func testRejectsAnIdentityThatDoesNotMatchTheLink() async throws {
        let (_, client, link) = try make(.wrongOrigin)
        do {
            _ = try await client.preview(link)
            XCTFail()
        } catch {
            XCTAssertEqual(error, .identityMismatch)
        }
    }

    func testRefusesAccessItDoesNotUnderstand() async throws {
        let (_, client, link) = try make(.unknownScope)
        do {
            _ = try await client.preview(link)
            XCTFail()
        } catch {
            XCTAssertEqual(error, .unsupportedAccess)
        }
    }

    func testAGatewayThatChangesIdentityAtRedemptionIsRevokedAndRefused() async throws {
        let (server, okClient, link) = try make(.ok)
        let preview = try await okClient.preview(link)
        let (evilServer, evilClient, evilLink) = try make(.wrongInstance)
        let evilPreview = try await evilClient.preview(evilLink)
        _ = (server, preview)

        do {
            _ = try await evilClient.redeem(evilLink, deviceName: "x", expecting: evilPreview)
            XCTFail("a different installation at redemption must be refused")
        } catch {
            XCTAssertEqual(error, .identityMismatch)
        }
        XCTAssertTrue(evilServer.requests.map(\.path).contains("/auth/device-revoke"),
                      "a credential that cannot be kept is revoked on the gateway")
    }

    func testAMalformedCredentialIsRevokedAndRefused() async throws {
        let (server, client, link) = try make(.badCredential)
        let preview = try await client.preview(link)
        do {
            _ = try await client.redeem(link, deviceName: "x", expecting: preview)
            XCTFail()
        } catch {
            XCTAssertEqual(error, .identityMismatch)
        }
        XCTAssertTrue(server.requests.map(\.path).contains("/auth/device-revoke"))
    }

    // MARK: classified failures

    func testServerErrorsMapToSpecificFailures() async throws {
        let cases: [(ScriptedPairingServer.Behavior, PairingFailure)] = [
            (.expired, .expired), (.alreadyUsed, .alreadyUsed), (.cancelled, .cancelled),
            (.invalid, .invalidInvitation), (.rateLimited, .rateLimited),
            (.unavailable, .pairingUnavailable), (.serverError, .serverError),
        ]
        for (behavior, expected) in cases {
            let (_, client, link) = try make(behavior)
            do {
                _ = try await client.preview(link)
                XCTFail("\(behavior)")
            } catch {
                XCTAssertEqual(error, expected, "\(behavior)")
            }
        }
    }

    /// Nothing listens on TCP port 1, so the connection is refused: an offline/unreachable
    /// gateway. (A stopped test server's port could be reused by another test's server, so a
    /// fixed closed port is used instead.)
    private var closedOrigin: URL { URL(string: "https://localhost:1")! }

    func testAnUnreachableGatewayIsReportedAsUnreachableNotAsAnAuthProblem() async throws {
        let client = GatewayPairingClient()
        let link = try PairingInvitationLink.parseForTesting(
            "https://localhost:1/pair#v=1&i=AbCdEfGhIjKlMnOpQrStUv&s=\(secret)")
        do {
            _ = try await client.preview(link)
            XCTFail()
        } catch {
            XCTAssertEqual(error, .unreachable)
            XCTAssertTrue(error.isRetryable)
        }
    }

    func testRefusesAnInsecureDestinationWithoutAnyNetworkAccess() async throws {
        let client = GatewayPairingClient()
        let insecure = PairingInvitationLink(
            origin: URL(string: "http://gateway.example.test")!, invitationID: "AbCdEfGhIjKlMnOpQrStUv",
            secret: PairingInvitationSecret(secret))
        do {
            _ = try await client.preview(insecure)
            XCTFail()
        } catch {
            XCTAssertEqual(error, .insecureDestination)
        }
    }

    // MARK: revocation

    func testRevocationOutcomes() async throws {
        let (server, client, _) = try make(.ok)
        let good = PairingDeviceCredential("hfd1." + String(repeating: "0123abcd", count: 4) + "." + String(repeating: "S", count: 43))
        let outcomeOK = await client.revoke(origin: server.origin, credential: good)
        XCTAssertEqual(outcomeOK, .revoked)
        let outcomeUnknown = await client.revoke(origin: server.origin, credential: PairingDeviceCredential("hfd1.nope"))
        XCTAssertEqual(outcomeUnknown, .alreadyRevoked)

        let outcomeDown = await GatewayPairingClient().revoke(origin: closedOrigin, credential: good)
        XCTAssertEqual(outcomeDown, .unreachable)
    }

    // MARK: helpers under test

    func testFailureMappingForStatusesWithoutAProtocolBody() {
        XCTAssertEqual(GatewayPairingClient.failure(forStatus: 404, body: Data()), .pairingUnavailable)
        XCTAssertEqual(GatewayPairingClient.failure(forStatus: 405, body: Data()), .pairingUnavailable)
        XCTAssertEqual(GatewayPairingClient.failure(forStatus: 429, body: Data()), .rateLimited)
        XCTAssertEqual(GatewayPairingClient.failure(forStatus: 502, body: Data()), .serverError)
        XCTAssertEqual(GatewayPairingClient.failure(forStatus: 418, body: Data()), .malformedResponse)
        XCTAssertEqual(GatewayPairingClient.failure(forStatus: 404, body: Data(#"{"error":"expired"}"#.utf8)), .expired)
    }

    func testDisplayTextIsBoundedAndPrintable() {
        XCTAssertEqual(GatewayPairingClient.displayText("  Hello\u{0}\u{202E}World  ", limit: 64), "HelloWorld")
        XCTAssertEqual(GatewayPairingClient.displayText(String(repeating: "x", count: 500), limit: 64).count, 64)
        XCTAssertEqual(GatewayPairingClient.displayText("a\nb", limit: 64), "ab")
    }

    func testCredentialShapeValidation() {
        let device = String(repeating: "0123abcd", count: 4)
        XCTAssertTrue(GatewayPairingClient.isCredential("hfd1.\(device).\(String(repeating: "S", count: 43))"))
        for bad in ["", "hfd1.x.y", "hfd2.\(device).\(String(repeating: "S", count: 43))",
                    "hfd1.\(device).short", "hfd1.\(device).\(String(repeating: "S", count: 200))",
                    "hfd1.\(device).\(String(repeating: "S", count: 43)) "] {
            XCTAssertFalse(GatewayPairingClient.isCredential(bad), bad)
        }
    }
}
