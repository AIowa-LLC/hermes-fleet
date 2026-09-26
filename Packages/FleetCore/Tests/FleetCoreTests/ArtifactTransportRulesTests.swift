import XCTest
import FleetCore

/// Card C — pure guard rules for artifact transport (no network).
final class ArtifactTransportRulesTests: XCTestCase {

    // MARK: Path guards

    func testAcceptsAbsoluteAndHomeRelativeImagePaths() throws {
        XCTAssertEqual(
            try ArtifactTransportRules.validatedPath("/var/lib/gateway/cache/images/a.png"),
            "/var/lib/gateway/cache/images/a.png")
        XCTAssertEqual(
            try ArtifactTransportRules.validatedPath("~/cache/images/a.webp"),
            "~/cache/images/a.webp")
        XCTAssertEqual(
            try ArtifactTransportRules.validatedPath("  /tmp/x.JPG  "),
            "/tmp/x.JPG")
    }

    func testRejectsEmptyAndWhitespacePaths() {
        assertInvalid("", contains: "empty")
        assertInvalid("   ", contains: "empty")
    }

    func testRejectsControlCharactersAndNUL() {
        assertInvalid("/tmp/a\u{0}.png", contains: "control")
        assertInvalid("/tmp/a\n.png", contains: "control")
    }

    func testRejectsURLForms() {
        assertInvalid("file:///tmp/a.png", contains: "URL")
        assertInvalid("https://example.com/a.png", contains: "URL")
    }

    func testRejectsRelativePaths() {
        assertInvalid("cache/images/a.png", contains: "absolute")
        assertInvalid("./a.png", contains: "absolute")
    }

    func testRejectsTraversalComponents() {
        assertInvalid("/tmp/../etc/a.png", contains: "traversal")
        assertInvalid("/../a.png", contains: "traversal")
    }

    func testRejectsNonAllowlistedExtensions() {
        assertInvalid("/tmp/a.txt", contains: "allowlist")
        assertInvalid("/tmp/a.heic", contains: "allowlist")
        assertInvalid("/tmp/a", contains: "allowlist")
    }

    func testRejectsDirectoryPaths() {
        assertInvalid("/tmp/a.png/", contains: "directory")
    }

    func testRejectsRelativeDotComponents() {
        assertInvalid("/tmp/./a.png", contains: "relative component")
    }

    func testRejectsOverlongPaths() {
        let long = "/tmp/" + String(repeating: "a", count: ArtifactTransportRules.maxPathLength) + ".png"
        assertInvalid(long, contains: "longer than")
    }

    func testGuardDetailsNeverEchoThePath() {
        let secretPath = "/Users/someone/.hermes/cache/images/private-name.exe"
        do {
            _ = try ArtifactTransportRules.validatedPath(secretPath)
            XCTFail("expected invalidReference")
        } catch let error as ArtifactTransportError {
            XCTAssertFalse(error.description.contains("private-name"))
            XCTAssertFalse(error.description.contains("/Users/"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    private func assertInvalid(_ path: String, contains needle: String) {
        do {
            _ = try ArtifactTransportRules.validatedPath(path)
            XCTFail("expected invalidReference for \(path)")
        } catch let error as ArtifactTransportError {
            guard case .invalidReference(let detail) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(detail.contains(needle), "detail '\(detail)' did not contain '\(needle)'")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: MIME table (mirrors the server's `_MEDIA_CONTENT_TYPES`)

    func testExtensionAllowlistMatchesTheServerMediaTable() {
        XCTAssertEqual(
            ArtifactTransportRules.allowedExtensions,
            ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "ico"])
        XCTAssertEqual(ArtifactTransportRules.mimeType(forExtension: "PNG"), "image/png")
        XCTAssertEqual(ArtifactTransportRules.mimeType(forExtension: "jpeg"), "image/jpeg")
        XCTAssertEqual(ArtifactTransportRules.mimeType(forExtension: "ico"), "image/x-icon")
        XCTAssertEqual(ArtifactTransportRules.mimeType(forExtension: "txt"), "application/octet-stream")
    }

    func testMIMENormalizationTreatsJPGAsJPEG() {
        XCTAssertEqual(ArtifactTransportRules.normalizedMIME("IMAGE/JPG"), "image/jpeg")
        XCTAssertEqual(ArtifactTransportRules.normalizedMIME(" image/jpeg "), "image/jpeg")
    }

    // MARK: Payload type guard

    func testPNGMagicMatchesDeclaredPNG() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        XCTAssertTrue(ArtifactTransportRules.payloadMatches(declaredMIME: "image/png", bytes: bytes))
        XCTAssertFalse(ArtifactTransportRules.payloadMatches(declaredMIME: "image/jpeg", bytes: bytes))
    }

    func testJPEGMagicMatchesDeclaredJPEG() {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])
        XCTAssertTrue(ArtifactTransportRules.payloadMatches(declaredMIME: "image/jpeg", bytes: bytes))
        XCTAssertFalse(ArtifactTransportRules.payloadMatches(declaredMIME: "image/gif", bytes: bytes))
    }

    func testMagiclessDeclaredTypesAreNotContradicted() {
        // SVG/ICO carry no magic — a declaration cannot be contradicted.
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
        XCTAssertTrue(ArtifactTransportRules.payloadMatches(declaredMIME: "image/svg+xml", bytes: svg))
        XCTAssertTrue(sniffedNil(svg))
    }

    private func sniffedNil(_ bytes: Data) -> Bool {
        ArtifactTransportRules.sniffedExtension(for: bytes) == nil
    }

    // MARK: Reference model

    func testReferenceDerivesNameAndMIMEType() {
        let ref = ArtifactReference(
            gatewayID: GatewayID(rawValue: "gw"),
            sessionID: "s1",
            profile: "default",
            path: "/var/cache/images/generated-42.png")
        XCTAssertEqual(ref.displayName, "generated-42.png")
        XCTAssertEqual(ref.resolvedMIMEType, "image/png")
    }

    func testReferenceDescriptionNeverPrintsTheHostPath() {
        let ref = ArtifactReference(
            gatewayID: GatewayID(rawValue: "gw"),
            sessionID: "s1",
            path: "/Users/someone/.hermes/cache/images/secret.png",
            name: "secret.png")
        XCTAssertFalse(ref.description.contains("/Users/someone"))
        XCTAssertFalse(ref.debugDescription.contains(".hermes"))
        XCTAssertTrue(ref.description.contains("secret.png"))
        XCTAssertTrue(ref.description.contains("gw"))
        XCTAssertTrue(ref.description.contains("s1"))
    }

    func testReferenceDefaultNameFallsBackHonestly() {
        let ref = ArtifactReference(gatewayID: GatewayID(rawValue: "gw"), path: "/")
        XCTAssertEqual(ref.displayName, "artifact")
    }

    func testReferenceRoundTripsThroughCodable() throws {
        let ref = ArtifactReference(
            gatewayID: GatewayID(rawValue: "gw"),
            sessionID: "s1",
            profile: "p",
            path: "/var/cache/images/x.png",
            byteCount: 81)
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(ArtifactReference.self, from: data)
        XCTAssertEqual(decoded, ref)
    }

    // MARK: Errors + fail-closed default

    func testOnlyExpiredIsExpiration() {
        XCTAssertTrue(ArtifactTransportError.expired(detail: "x").isExpiration)
        XCTAssertFalse(ArtifactTransportError.notPermitted(detail: "x").isExpiration)
        XCTAssertFalse(ArtifactTransportError.tooLarge(detail: "x").isExpiration)
    }

    func testUnsupportedRetrievalFailsClosedAndKeepsGatewayBinding() async {
        let id = GatewayID(rawValue: "gw")
        let retrieval = UnsupportedArtifactRetrieval(gatewayID: id)
        XCTAssertEqual(retrieval.gatewayID, id)
        do {
            _ = try await retrieval.retrieve(
                ArtifactReference(gatewayID: id, path: "/var/cache/images/x.png"))
            XCTFail("expected notConfigured")
        } catch let error as ArtifactTransportError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
