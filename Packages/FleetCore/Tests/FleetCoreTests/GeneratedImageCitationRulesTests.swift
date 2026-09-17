import XCTest
import FleetCore

/// Card D — pure generated-image citation rules (no network, no transport).
///
/// Fixtures mirror the two real wire shapes:
/// - current plugin providers (`plugins/image_gen/*`) return the LOCAL
///   `cache/images` path as `image`;
/// - the legacy FAL tool returns the remote URL as `image` and adds
///   `host_image` / `agent_visible_image` on non-local terminal backends.
final class GeneratedImageCitationRulesTests: XCTestCase {

    private let gateway = GatewayID(rawValue: "workstation")

    // MARK: Citation parsing

    func testParsesLocalProviderShape() {
        let result = #"{"success": true, "image": "/Users/dev/.hermes/cache/images/image_1.png", "model": "gpt-image", "provider": "openai-codex"}"#
        let citation = GeneratedImageRules.citation(toolName: "image_generate", resultJSON: result)
        XCTAssertEqual(citation?.displaySource, "/Users/dev/.hermes/cache/images/image_1.png")
        XCTAssertEqual(citation?.echoSources, ["/Users/dev/.hermes/cache/images/image_1.png"])
        XCTAssertEqual(citation?.displayName, "image_1.png")
    }

    func testHostImageWinsAsDisplaySource() {
        let result = #"""
        {"success": true, "image": "https://fal.media/files/cat.png",
         "host_image": "/home/u/.hermes/cache/images/cat.png",
         "agent_visible_image": "~/.hermes/cache/images/cat.png"}
        """#
        let citation = GeneratedImageRules.citation(toolName: "image_generate", resultJSON: result)
        XCTAssertEqual(citation?.displaySource, "/home/u/.hermes/cache/images/cat.png")
        XCTAssertEqual(citation?.echoSources, [
            "/home/u/.hermes/cache/images/cat.png",
            "https://fal.media/files/cat.png",
            "~/.hermes/cache/images/cat.png",
        ])
    }

    func testBlankStringsFallThroughToNextKey() {
        let result = #"{"success": true, "host_image": "   ", "image": "/tmp/cache/images/b.png"}"#
        let citation = GeneratedImageRules.citation(toolName: "image_generate", resultJSON: result)
        XCTAssertEqual(citation?.displaySource, "/tmp/cache/images/b.png")
        XCTAssertEqual(citation?.echoSources, ["/tmp/cache/images/b.png"])
    }

    func testExplicitFailureIsNeverACitation() {
        let result = #"{"success": false, "image": "/tmp/cache/images/failed.png", "error": "boom"}"#
        XCTAssertNil(GeneratedImageRules.citation(toolName: "image_generate", resultJSON: result))
    }

    func testMissingSuccessFlagStillCites() {
        // Desktop parity: only an explicit `success: false` is a failure.
        let result = #"{"image": "/tmp/cache/images/ok.png"}"#
        XCTAssertEqual(
            GeneratedImageRules.citation(toolName: "image_generate", resultJSON: result)?.displaySource,
            "/tmp/cache/images/ok.png")
    }

    func testNonObjectAndMalformedResultsAreIgnored() {
        XCTAssertNil(GeneratedImageRules.citation(toolName: "image_generate", resultJSON: #""just a string""#))
        XCTAssertNil(GeneratedImageRules.citation(toolName: "image_generate", resultJSON: "[1,2,3]"))
        XCTAssertNil(GeneratedImageRules.citation(toolName: "image_generate", resultJSON: "{not json"))
        XCTAssertNil(GeneratedImageRules.citation(toolName: "image_generate", resultJSON: nil))
        XCTAssertNil(GeneratedImageRules.citation(toolName: "image_generate", resultJSON: ""))
    }

    func testOtherToolsNeverCite() {
        let result = #"{"success": true, "image": "/tmp/cache/images/x.png"}"#
        for tool in ["terminal", "image_edit", "Image_Generate", "web_search"] {
            XCTAssertNil(GeneratedImageRules.citation(toolName: tool, resultJSON: result), tool)
        }
    }

    // MARK: Retrievable path + reference

    func testLocalPathBecomesAProvenanceBoundReference() {
        let result = #"{"success": true, "image": "/home/u/.hermes/cache/images/cat.png"}"#
        let citation = try! XCTUnwrap(GeneratedImageRules.citation(toolName: "image_generate", resultJSON: result))
        let reference = try! XCTUnwrap(GeneratedImageRules.artifactReference(
            for: citation, gatewayID: gateway, sessionID: "sess-1", profile: "default"))
        XCTAssertEqual(reference.gatewayID, gateway)
        XCTAssertEqual(reference.sessionID, "sess-1")
        XCTAssertEqual(reference.profile, "default")
        XCTAssertEqual(reference.path, "/home/u/.hermes/cache/images/cat.png")
        XCTAssertEqual(reference.displayName, "cat.png")
    }

    func testHostImageIsPreferredOverTheRemoteURL() {
        let result = #"{"success": true, "image": "https://fal.media/cat.png", "host_image": "/home/u/.hermes/cache/images/cat.png"}"#
        let citation = try! XCTUnwrap(GeneratedImageRules.citation(toolName: "image_generate", resultJSON: result))
        XCTAssertEqual(GeneratedImageRules.retrievablePath(for: citation), "/home/u/.hermes/cache/images/cat.png")
    }

    func testURLOnlyResultCitesButIsNotRetrievable() {
        // A local gateway whose terminal was local: the FAL URL is the only
        // material — honest state: cite (prose de-dupe still applies), nothing
        // to retrieve through the gateway.
        let result = #"{"success": true, "image": "https://fal.media/files/cat.png"}"#
        let citation = try! XCTUnwrap(GeneratedImageRules.citation(toolName: "image_generate", resultJSON: result))
        XCTAssertNil(GeneratedImageRules.retrievablePath(for: citation))
        XCTAssertNil(GeneratedImageRules.artifactReference(
            for: citation, gatewayID: gateway, sessionID: nil, profile: nil))
    }

    func testNonRetrievableVariantsNeverBecomeReferences() {
        let fixtures = [
            #"{"success": true, "image": "cache/images/relative.png"}"#,
            #"{"success": true, "image": "/tmp/../etc/passwd.png"}"#,
            #"{"success": true, "image": "/tmp/notes.txt"}"#,
            #"{"success": true, "image": "file:///tmp/a.png"}"#,
        ]
        for fixture in fixtures {
            let citation = try! XCTUnwrap(GeneratedImageRules.citation(toolName: "image_generate", resultJSON: fixture))
            XCTAssertNil(GeneratedImageRules.retrievablePath(for: citation), fixture)
        }
    }

    func testAgentVisibleImageAloneIsNotACitation() {
        // Desktop parity (`generatedImageFromResult`): a result without a
        // DISPLAY key cites nothing — the container path is not host-served.
        let result = #"{"success": true, "agent_visible_image": "/root/.hermes/cache/images/cat.png"}"#
        XCTAssertNil(GeneratedImageRules.citation(toolName: "image_generate", resultJSON: result))
    }

    func testAgentVisibleImageIsAnEchoSourceButNeverARetrievalCandidate() {
        let result = #"{"success": true, "image": "https://fal.media/files/cat.png", "agent_visible_image": "/root/.hermes/cache/images/cat.png"}"#
        let citation = try! XCTUnwrap(GeneratedImageRules.citation(toolName: "image_generate", resultJSON: result))
        XCTAssertEqual(citation.echoSources, [
            "https://fal.media/files/cat.png",
            "/root/.hermes/cache/images/cat.png",
        ])
        // The URL is not a gateway path and the container view is never
        // host-served: nothing to retrieve, honestly.
        XCTAssertNil(GeneratedImageRules.retrievablePath(for: citation))
    }

    // MARK: Prose de-dupe

    func testStripsMarkdownImageSpansAndMediaLinks() {
        let sources = ["/home/u/.hermes/cache/images/cat.png"]
        let text = "Here you go:\n\n![cat](https://fal.media/files/cat.png)\n\nDone."
        let stripped = GeneratedImageRules.strippingEchoes(in: text, sources: sources)
        XCTAssertFalse(stripped.contains("![cat]"))
        XCTAssertTrue(stripped.contains("Here you go:"))
        XCTAssertTrue(stripped.contains("Done."))
    }

    func testStripsMediaLinkForm() {
        let text = "Rendered [cat.png](#media:/home/u/.hermes/cache/images/cat.png) above."
        let stripped = GeneratedImageRules.strippingEchoes(
            in: text, sources: ["/home/u/.hermes/cache/images/cat.png"])
        XCTAssertFalse(stripped.contains("#media:"))
        XCTAssertTrue(stripped.contains("Rendered"))
        XCTAssertTrue(stripped.contains("above."))
    }

    func testStripsBarePathOccurrencesWithBoundaries() {
        let text = "Saved to /home/u/.hermes/cache/images/cat.png for you."
        let stripped = GeneratedImageRules.strippingEchoes(
            in: text, sources: ["/home/u/.hermes/cache/images/cat.png"])
        XCTAssertFalse(stripped.contains("cache/images"))
        XCTAssertTrue(stripped.contains("Saved to"))
        XCTAssertTrue(stripped.contains("for you."))
    }

    func testStripsAutolinkWrappedOccurrence() {
        let text = "Source: <https://fal.media/files/cat.png>\n"
        let stripped = GeneratedImageRules.strippingEchoes(in: text, sources: ["https://fal.media/files/cat.png"])
        XCTAssertFalse(stripped.contains("fal.media"))
    }

    func testLeftBoundaryDisciplineKeepsEmbeddedSubstrings() {
        // No token boundary before the source (it is embedded inside a longer
        // token) ⇒ untouched.
        let text = "prefix-/home/u/.hermes/cache/images/cat.png stays."
        let stripped = GeneratedImageRules.strippingEchoes(
            in: text, sources: ["/home/u/.hermes/cache/images/cat.png"])
        XCTAssertEqual(stripped, text)
    }

    func testTrailingPunctuationIsABoundary() {
        // Desktop parity: `.` is an accepted right boundary, so a path
        // immediately followed by a sentence period is stripped (the period
        // itself is kept).
        let text = "Saved to /home/u/.hermes/cache/images/cat.png. Next line."
        let stripped = GeneratedImageRules.strippingEchoes(
            in: text, sources: ["/home/u/.hermes/cache/images/cat.png"])
        XCTAssertEqual(stripped, "Saved to . Next line.")
    }

    func testNoSourcesLeavesProseUntouched() {
        let text = "No generation here: ![x](https://example.invalid/x.png)"
        XCTAssertEqual(GeneratedImageRules.strippingEchoes(in: text, sources: []), text)
        XCTAssertEqual(GeneratedImageRules.strippingEchoes(in: text, citations: []), text)
    }

    func testCitationConvenienceStripsEveryDeclaredVariant() {
        let result = #"{"success": true, "image": "https://fal.media/files/cat.png", "host_image": "/home/u/.hermes/cache/images/cat.png"}"#
        let citation = try! XCTUnwrap(GeneratedImageRules.citation(toolName: "image_generate", resultJSON: result))
        let text = "Local /home/u/.hermes/cache/images/cat.png and remote https://fal.media/files/cat.png."
        let stripped = GeneratedImageRules.strippingEchoes(in: text, citations: [citation])
        XCTAssertFalse(stripped.contains("cache/images"))
        XCTAssertFalse(stripped.contains("fal.media"))
        XCTAssertTrue(stripped.contains("Local"))
        XCTAssertTrue(stripped.contains("remote"))
    }

    // MARK: Redaction

    func testCitationDescriptionNeverLeaksTheFullHostPath() {
        let result = #"{"success": true, "image": "/Users/someone/private/profile/cache/images/secret-name.png"}"#
        let citation = try! XCTUnwrap(GeneratedImageRules.citation(toolName: "image_generate", resultJSON: result))
        XCTAssertFalse(citation.description.contains("/Users/"))
        XCTAssertFalse(citation.description.contains("private/profile"))
        XCTAssertTrue(citation.description.contains("secret-name.png"))
    }
}
