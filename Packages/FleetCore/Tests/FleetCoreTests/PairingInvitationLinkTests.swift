import XCTest
@testable import FleetCore

/// The pairing link is parsed from untrusted text (a paste, a QR code, a
/// system-delivered URL). Every rejection here is a destination or format an
/// issuer never produces.
final class PairingInvitationLinkTests: XCTestCase {
    private let id = "AbCdEfGhIjKlMnOpQrStUv"                       // 22
    private let secret = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"   // 43
    /// Base64url (no padding) of 32 bytes 0x00...0x1f.
    private let pin = PairingInvitationLink.base64URLEncode(Data(0..<32))

    private func link(
        host: String = "gateway.example.test", port: String = "", path: String = "/pair",
        fragment: String? = nil, scheme: String = "https"
    ) -> String {
        "\(scheme)://\(host)\(port)\(path)#\(fragment ?? "v=1&i=\(id)&s=\(secret)")"
    }

    // MARK: accepted

    func testParsesAWellFormedLink() throws {
        let parsed = try PairingInvitationLink.parse(link())
        XCTAssertEqual(parsed.origin.absoluteString, "https://gateway.example.test")
        XCTAssertEqual(parsed.host, "gateway.example.test")
        XCTAssertEqual(parsed.invitationID, id)
        XCTAssertEqual(parsed.secret.rawValue, secret)
    }

    func testNormalisesHostCaseAndKeepsNonDefaultPort() throws {
        let parsed = try PairingInvitationLink.parse(link(host: "Gateway.Example.TEST", port: ":8443"))
        XCTAssertEqual(parsed.origin.absoluteString, "https://gateway.example.test:8443")
        XCTAssertEqual(try PairingInvitationLink.parse(link(port: ":443")).origin.absoluteString,
                       "https://gateway.example.test")
    }

    func testToleratesSurroundingWhitespaceAndProse() throws {
        let plain = try PairingInvitationLink.parse("\n  \(link())  \n")
        XCTAssertEqual(plain.invitationID, id)
        let prose = try PairingInvitationLink.parse("Here is your link: \(link()) -- expires soon")
        XCTAssertEqual(prose.invitationID, id)
    }

    func testParsesASystemDeliveredURL() throws {
        let url = try XCTUnwrap(URL(string: link()))
        XCTAssertEqual(try PairingInvitationLink.parse(url).invitationID, id)
        XCTAssertTrue(PairingInvitationLink.looksLikePairingLink(url))
        XCTAssertFalse(PairingInvitationLink.looksLikePairingLink(try XCTUnwrap(URL(string: "https://x.example.test/other"))))
        XCTAssertFalse(PairingInvitationLink.looksLikePairingLink(try XCTUnwrap(URL(string: "mailto:a@example.test"))))
    }

    func testIgnoresUnknownExtraFragmentFieldsForForwardCompatibility() throws {
        let parsed = try PairingInvitationLink.parse(link(fragment: "v=1&i=\(id)&s=\(secret)&x=whatever"))
        XCTAssertEqual(parsed.invitationID, id)
    }

    // MARK: rejected destinations

    func testRejectsPlainHTTP() {
        XCTAssertThrowsError(try PairingInvitationLink.parse(link(scheme: "http"))) {
            XCTAssertEqual($0 as? PairingInvitationLink.ParseError, .insecureScheme)
        }
    }

    func testRejectsNonWebSchemes() {
        for scheme in ["ftp", "javascript", "hermes-fleet-dev", "file", "data"] {
            XCTAssertThrowsError(try PairingInvitationLink.parse(link(scheme: scheme)), scheme)
        }
    }

    func testRejectsIPLiteralsLocalhostAndSingleLabelHosts() {
        for host in ["127.0.0.1", "10.0.0.5", "192.168.1.20", "[::1]", "[2001:db8::1]", "localhost",
                     "app.localhost", "intranet", "1.2.3", "gateway.example.123", "gateway.example.test."] {
            XCTAssertThrowsError(try PairingInvitationLink.parse(link(host: host)), host) {
                XCTAssertEqual($0 as? PairingInvitationLink.ParseError, .invalidHost, host)
            }
        }
    }

    func testRejectsLookAlikeAndMalformedHosts() {
        for host in ["gatewäy.example.test", "gateway_.example.test", "-bad.example.test",
                     "bad-.example.test", "gate way.example.test", "", "..", "a..b.test"] {
            XCTAssertThrowsError(try PairingInvitationLink.parse(link(host: host)), host)
        }
    }

    func testRejectsUserInfoQueryAndWrongPath() {
        XCTAssertThrowsError(try PairingInvitationLink.parse("https://user:pw@gateway.example.test/pair#v=1&i=\(id)&s=\(secret)")) {
            XCTAssertEqual($0 as? PairingInvitationLink.ParseError, .unexpectedComponents)
        }
        XCTAssertThrowsError(try PairingInvitationLink.parse("https://gateway.example.test/pair?s=\(secret)#v=1&i=\(id)&s=\(secret)")) {
            XCTAssertEqual($0 as? PairingInvitationLink.ParseError, .unexpectedComponents)
        }
        for path in ["/", "/pair/", "/pairing", "/api/pair", ""] {
            XCTAssertThrowsError(try PairingInvitationLink.parse(link(path: path)), path)
        }
    }

    func testRejectsOutOfRangePorts() {
        for port in [":0", ":65536", ":99999"] {
            XCTAssertThrowsError(try PairingInvitationLink.parse(link(port: port)), port)
        }
    }

    // MARK: rejected fragments

    func testRejectsMissingDuplicateAndMalformedFields() {
        let bad = [
            "", "v=1", "v=1&i=\(id)", "v=1&s=\(secret)", "i=\(id)&s=\(secret)",
            "v=1&i=\(id)&i=\(id)&s=\(secret)", "v=1&i=\(id)&s=\(secret)&s=\(secret)",
            "v=1&i=short&s=\(secret)", "v=1&i=\(id)&s=short",
            "v=1&i=\(id)&s=\(secret)!", "v=1&i=\(id)&s=\(String(repeating: "a", count: 129))",
            "v=1&i=\(id.dropLast())%20&s=\(secret)", "v=x&i=\(id)&s=\(secret)", "v&i=\(id)&s=\(secret)",
            "=1&i=\(id)&s=\(secret)",
        ]
        for fragment in bad {
            XCTAssertThrowsError(try PairingInvitationLink.parse(link(fragment: fragment)), fragment)
        }
    }

    func testRejectsNoFragmentAtAll() {
        XCTAssertThrowsError(try PairingInvitationLink.parse("https://gateway.example.test/pair")) {
            XCTAssertEqual($0 as? PairingInvitationLink.ParseError, .malformedFields)
        }
    }

    func testUnknownVersionIsUnsupportedNotMisread() {
        XCTAssertThrowsError(try PairingInvitationLink.parse(link(fragment: "v=3&i=\(id)&s=\(secret)&k=\(pin)"))) {
            XCTAssertEqual($0 as? PairingInvitationLink.ParseError, .unsupportedVersion(3))
        }
    }

    func testRejectsGarbageAndOversizedInput() {
        for text in ["", "   ", "hello", "not a url", "ftp://gateway.example.test/pair", "\u{0}"] {
            XCTAssertThrowsError(try PairingInvitationLink.parse(text), text)
        }
        XCTAssertThrowsError(try PairingInvitationLink.parse(link() + String(repeating: "a", count: 5000)))
        XCTAssertThrowsError(try PairingInvitationLink.parse(String(repeating: "x", count: 20_000))) {
            XCTAssertEqual($0 as? PairingInvitationLink.ParseError, .tooLong)
        }
    }

    func testRejectsControlCharactersAndNonASCIIInsideTheLink() {
        XCTAssertThrowsError(try PairingInvitationLink.parse("https://gateway.example.test/pair#v=1&i=\(id)&s=\(secret)\u{7}"))
        XCTAssertThrowsError(try PairingInvitationLink.parse("https://gateway.example.test/pair#v=1&i=\(id)&s=\(secret)é"))
    }

    // MARK: redaction

    func testPrintedFormsNeverContainTheSecretOrTheInvitationID() throws {
        let parsed = try PairingInvitationLink.parse(link())
        let renderings = [
            "\(parsed)", String(describing: parsed), String(reflecting: parsed),
            "\(parsed.secret)", String(reflecting: parsed.secret), "\(parsed.debugDescription)",
        ]
        for text in renderings {
            XCTAssertFalse(text.contains(secret), text)
            XCTAssertFalse(text.contains(id), text)
        }
        XCTAssertTrue("\(parsed)".contains("gateway.example.test"))
    }

    func testLinkIsNotCodable() {
        // A compile-time property, recorded here as documentation: the type has no Codable conformance.
        XCTAssertFalse((PairingInvitationLink.self as Any) is Encodable.Type)
        XCTAssertFalse((PairingInvitationLink.self as Any) is Decodable.Type)
    }

    // MARK: testing seam is not the production path

    func testProductionParserRefusesLoopbackThatTheTestSeamAllows() throws {
        let loopback = "https://127.0.0.1:8443/pair#v=1&i=\(id)&s=\(secret)"
        XCTAssertThrowsError(try PairingInvitationLink.parse(loopback))
        XCTAssertEqual(try PairingInvitationLink.parseForTesting(loopback).origin.absoluteString,
                       "https://127.0.0.1:8443")
    }

    // MARK: stable identity

    func testPairedGatewayIdentityIsDerivedFromTheInstanceID() {
        let instance = String(repeating: "ab12", count: 8)
        XCTAssertEqual(GatewayID(pairedInstanceID: instance)?.rawValue, "gw-\(instance)")
        for bad in ["", "short", String(repeating: "g", count: 32), String(repeating: "A", count: 32),
                    String(repeating: "a", count: 33), "../" + String(repeating: "a", count: 29)] {
            XCTAssertNil(GatewayID(pairedInstanceID: bad), bad)
        }
        XCTAssertTrue(GatewayID(pairedInstanceID: instance)?.isRoutingSafe ?? false)
    }

    func testFailureRetryability() {
        XCTAssertTrue(PairingFailure.unreachable.isRetryable)
        XCTAssertTrue(PairingFailure.rateLimited.isRetryable)
        for terminal: PairingFailure in [.expired, .alreadyUsed, .cancelled, .invalidInvitation, .malformedLink,
                                         .insecureDestination, .untrustedCertificate, .identityMismatch] {
            XCTAssertFalse(terminal.isRetryable, "\(terminal)")
        }
    }

    // MARK: v2 (approval) links

    private func v2(
        host: String = "gateway.example.test", fragment: String? = nil
    ) -> String {
        link(host: host, fragment: fragment ?? "v=2&i=\(id)&s=\(secret)&k=\(pin)")
    }

    func testParsesAV2LinkWithPin() throws {
        let parsed = try PairingInvitationLink.parse(v2())
        XCTAssertEqual(parsed.version, 2)
        XCTAssertTrue(parsed.requiresApproval)
        XCTAssertEqual(parsed.pin?.sha256Digest, Data(0..<32))
        XCTAssertEqual(parsed.invitationID, id)
        XCTAssertEqual(parsed.origin.absoluteString, "https://gateway.example.test")
    }

    func testV1LinkIsUnchangedAndHasNoPin() throws {
        let parsed = try PairingInvitationLink.parse(link())
        XCTAssertEqual(parsed.version, 1)
        XCTAssertFalse(parsed.requiresApproval)
        XCTAssertNil(parsed.pin)
    }

    func testV2RequiresAWellFormedPin() {
        let canonical = pin
        let lastChar = canonical.last!
        // The final base64 character carries 2 spare bits that must be zero.
        let nonCanonical = String(canonical.dropLast()) + (lastChar == "f" ? "g" : "f")
        let bad: [String] = [
            "",                                            // missing
            String(canonical.dropLast()),                  // 42 chars
            canonical + "A",                               // 44 chars
            canonical + "=",                               // padded
            String(canonical.dropLast(1)) + "=",           // padding in place of a character
            "+" + canonical.dropFirst(),                    // standard-alphabet character
            String(canonical.dropFirst()) + "/",           // standard-alphabet character
            String(canonical.dropFirst()) + "!",
            nonCanonical,
        ]
        for value in bad {
            XCTAssertThrowsError(try PairingInvitationLink.parse(v2(fragment: "v=2&i=\(id)&s=\(secret)&k=\(value)")), value) {
                XCTAssertEqual($0 as? PairingInvitationLink.ParseError, .malformedFields, value)
            }
        }
        XCTAssertThrowsError(try PairingInvitationLink.parse(v2(fragment: "v=2&i=\(id)&s=\(secret)"))) {
            XCTAssertEqual($0 as? PairingInvitationLink.ParseError, .malformedFields)
        }
        // An all-zero digest is a valid canonical spelling.
        XCTAssertNoThrow(try PairingInvitationLink.parse(v2(fragment: "v=2&i=\(id)&s=\(secret)&k=\(String(repeating: "A", count: 43))")))
    }

    func testRejectsMixedAndDuplicateFields() {
        let bad = [
            "v=1&i=\(id)&s=\(secret)&k=\(pin)",                    // v1 never carries a pin
            "v=2&i=\(id)&s=\(secret)&k=\(pin)&k=\(pin)",          // duplicate pin
            "v=2&v=2&i=\(id)&s=\(secret)&k=\(pin)",
            "v=2&i=\(id)&s=\(secret)&k=\(pin)&o=aHR0cHM6Ly9nYXRld2F5LmV4YW1wbGUudGVzdA", // origin belongs to the app-scheme form
            "v=1&v=2&i=\(id)&s=\(secret)&k=\(pin)",
        ]
        for fragment in bad {
            XCTAssertThrowsError(try PairingInvitationLink.parse(v2(fragment: fragment)), fragment)
        }
    }

    func testV2HostRulesAreUnchanged() {
        for host in ["localhost", "192.168.1.1", "single", "[::1]", "xn--bcher-kva.example.test"] {
            XCTAssertThrowsError(try PairingInvitationLink.parse(v2(host: host)), host)
        }
        XCTAssertThrowsError(try PairingInvitationLink.parse(link(fragment: "v=2&i=\(id)&s=\(secret)&k=\(pin)", scheme: "http")))
    }

    func testDescriptionsRedactSecretAndPin() throws {
        let parsed = try PairingInvitationLink.parse(v2())
        for text in ["\(parsed)", String(reflecting: parsed)] {
            XCTAssertFalse(text.contains(secret), text)
            XCTAssertFalse(text.contains(pin), text)
            XCTAssertTrue(text.contains("gateway.example.test"))
        }
    }

    // MARK: app-scheme form

    private func origin64(_ origin: String) -> String {
        PairingInvitationLink.base64URLEncode(Data(origin.utf8))
    }

    private func appLink(
        scheme: String = "hermes-fleet-dev", host: String = "pair", origin: String? = nil,
        fragment: String? = nil
    ) -> String {
        let o = origin ?? origin64("https://gateway.example.test")
        return "\(scheme)://\(host)#\(fragment ?? "v=2&i=\(id)&s=\(secret)&k=\(pin)&o=\(o)")"
    }

    func testParsesTheAppSchemeForm() throws {
        let parsed = try PairingInvitationLink.parse(appLink(), appURLScheme: "hermes-fleet-dev")
        XCTAssertEqual(parsed.origin.absoluteString, "https://gateway.example.test")
        XCTAssertEqual(parsed.version, 2)
        XCTAssertEqual(parsed.pin?.sha256Digest, Data(0..<32))
        let url = try XCTUnwrap(URL(string: appLink()))
        XCTAssertTrue(PairingInvitationLink.looksLikePairingLink(url, appURLScheme: "hermes-fleet-dev"))
        XCTAssertEqual(try PairingInvitationLink.parse(url, appURLScheme: "hermes-fleet-dev").invitationID, id)
    }

    func testAppSchemeKeepsPortAndFindsTheLinkInProse() throws {
        let origin = origin64("https://gateway.example.test:8443")
        let parsed = try PairingInvitationLink.parse(
            "Open this: \(appLink(origin: origin)) thanks", appURLScheme: "hermes-fleet-dev")
        XCTAssertEqual(parsed.origin.absoluteString, "https://gateway.example.test:8443")
    }

    func testAppSchemeOnlyAcceptsTheAppsOwnScheme() {
        XCTAssertThrowsError(try PairingInvitationLink.parse(appLink()))                                  // no scheme configured
        XCTAssertThrowsError(try PairingInvitationLink.parse(appLink(), appURLScheme: "hermes-fleet"))    // someone else's scheme
        XCTAssertThrowsError(try PairingInvitationLink.parse(appLink(scheme: "other-app"), appURLScheme: "hermes-fleet-dev"))
        let conversation = URL(string: "hermes-fleet-dev://conversation?gateway=a")!
        XCTAssertFalse(PairingInvitationLink.looksLikePairingLink(conversation, appURLScheme: "hermes-fleet-dev"),
                       "conversation deep links on the same scheme are not pairing links")
        XCTAssertThrowsError(try PairingInvitationLink.parse(appLink(host: "conversation"), appURLScheme: "hermes-fleet-dev"))
    }

    func testAppSchemeAppliesTheSameHostRulesToTheDecodedOrigin() {
        let badOrigins = [
            "http://gateway.example.test", "https://localhost", "https://192.168.1.1",
            "https://single", "https://user@gateway.example.test", "https://gateway.example.test/path",
            "https://gateway.example.test?x=1", "ftp://gateway.example.test", "gateway.example.test",
            "https://gateway.example.test:0", "https://gateway.example.test:70000",
        ]
        for origin in badOrigins {
            XCTAssertThrowsError(
                try PairingInvitationLink.parse(appLink(origin: origin64(origin)), appURLScheme: "hermes-fleet-dev"), origin)
        }
    }

    func testAppSchemeRequiresV2PinAndOriginAndRejectsMalformedOrigin() {
        let bad = [
            "v=1&i=\(id)&s=\(secret)&o=\(origin64("https://gateway.example.test"))",
            "v=2&i=\(id)&s=\(secret)&o=\(origin64("https://gateway.example.test"))",       // no pin
            "v=2&i=\(id)&s=\(secret)&k=\(pin)",                                              // no origin
            "v=2&i=\(id)&s=\(secret)&k=\(pin)&o=not*base64",
            "v=2&i=\(id)&s=\(secret)&k=\(pin)&o=\(origin64("https://gateway.example.test"))=",   // padded
            "v=2&i=\(id)&s=\(secret)&k=\(pin)&o=\(origin64("https://gateway.example.test"))&o=\(origin64("https://other.example.test"))",
        ]
        for fragment in bad {
            XCTAssertThrowsError(
                try PairingInvitationLink.parse(appLink(fragment: fragment), appURLScheme: "hermes-fleet-dev"), fragment)
        }
    }
}
