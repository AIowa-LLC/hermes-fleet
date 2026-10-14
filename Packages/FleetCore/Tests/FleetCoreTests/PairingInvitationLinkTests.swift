import XCTest
@testable import FleetCore

/// The pairing link is parsed from untrusted text (a paste, a QR code, a
/// system-delivered URL). Every rejection here is a destination or format an
/// issuer never produces.
final class PairingInvitationLinkTests: XCTestCase {
    private let id = "AbCdEfGhIjKlMnOpQrStUv"                       // 22
    private let secret = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"   // 43

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
        XCTAssertThrowsError(try PairingInvitationLink.parse(link(fragment: "v=2&i=\(id)&s=\(secret)"))) {
            XCTAssertEqual($0 as? PairingInvitationLink.ParseError, .unsupportedVersion(2))
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
}
