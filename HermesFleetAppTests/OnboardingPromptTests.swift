import XCTest
import SwiftUI
import FleetUI

/// F3 — agent bootstrap prompt content tests.
///
/// The prompt is a versioned artifact that ships with the app: these tests
/// pin its SHAPE (mission coverage, hygiene, conciseness, non-empty) so copy
/// edits are safe, but silently dropping a mission leg or embedding an
/// endpoint/secret fails the build.
@MainActor
final class OnboardingPromptTests: XCTestCase {

    // MARK: Mission coverage (card acceptance — every leg present)

    func testAllMissionLegsPresent() {
        for (index, keywords) in OnboardingPrompt.missionKeywords.enumerated() {
            for keyword in keywords {
                XCTAssertTrue(
                    OnboardingPrompt.text.contains(keyword),
                    "mission leg \(index + 1) missing keyword \"\(keyword)\" — a copy edit dropped a required mission element"
                )
            }
        }
    }

    func testInstallLegNamesTestFlightAndAppID() {
        // (1) APP INSTALL — TestFlight invite guidance with the app id.
        XCTAssertTrue(OnboardingPrompt.text.contains("TestFlight"))
        XCTAssertTrue(OnboardingPrompt.text.contains("6807148674"))
    }

    func testNetworkLegPrefersTailscaleWithLanFallback() {
        // (2) NETWORK PATH — Tailscale preferred, LAN fallback, cleartext warn.
        let text = OnboardingPrompt.text
        XCTAssertLessThan(
            text.range(of: "Tailscale")!.lowerBound,
            text.range(of: "LAN")!.lowerBound,
            "Tailscale must be presented as the PREFERRED path before the LAN fallback"
        )
        XCTAssertTrue(text.contains("unencrypted"), "LAN http fallback must carry the cleartext warning")
    }

    func testCredentialLegDemandsScopedCredentialWithZeroPrintHygiene() {
        // (3)/(4) CREDENTIALS — scoped + zero-print (0600 or reply, never logs).
        let text = OnboardingPrompt.text
        XCTAssertTrue(text.contains("scoped"))
        XCTAssertTrue(text.contains("credential"))
        XCTAssertTrue(text.contains("0600"))
        XCTAssertTrue(text.contains("never") && text.contains("logs"))
    }

    func testReplyLegRequestsExactlyURLUsernamePassword() {
        // (5) REPLY — exactly URL, username, password + install instruction.
        let text = OnboardingPrompt.text
        XCTAssertTrue(text.contains("URL"))
        XCTAssertTrue(text.contains("username"))
        XCTAssertTrue(text.contains("password"))
    }

    func testVerifyLegConfirmsAuthFromPhoneNetworkPath() {
        // (6) VERIFY — endpoint answers auth from the path the phone will use.
        XCTAssertTrue(OnboardingPrompt.text.contains("authentication request"))
    }

    // MARK: Hygiene — no secrets, no per-user details

    func testContainsNoSecretsOrEndpoints() throws {
        // Parameterization guard: the prompt must work for a user whose agent
        // runs on ANY Hermes box — no embedded endpoints, tailnet/LAN
        // literals, or credential shapes.
        XCTAssertTrue(OnboardingPrompt.containsNoSecrets(),
                      "prompt contains a forbidden substring: \(OnboardingPrompt.forbiddenSubstrings.filter { OnboardingPrompt.text.contains($0) })")
    }

    func testNoKnownTailnetOrPrivateDetails() {
        // Belt-and-braces beyond the forbidden list: none of Tony's actual
        // fleet identifiers may appear (the card's "parameterize, don't
        // hardcode tailnet/LAN details" rule).
        let text = OnboardingPrompt.text
        for banned in ["tailsc9f", "aiowa", "hermesfleet.gateway", "tonysimons", "9120"] {
            XCTAssertFalse(text.contains(banned), "prompt must not embed per-user detail \"\(banned)\"")
        }
    }

    // MARK: Conciseness + versioning

    func testPromptIsConcise() {
        // Card: "keep it under ~200 words".
        XCTAssertLessThanOrEqual(OnboardingPrompt.wordCount, 200,
                                  "prompt is \(OnboardingPrompt.wordCount) words — trim toward ~200")
        XCTAssertGreaterThan(OnboardingPrompt.wordCount, 50,
                             "prompt too short to cover the mission")
    }

    func testVersionIsPositiveAndTextNonEmpty() {
        XCTAssertGreaterThan(OnboardingPrompt.version, 0)
        XCTAssertFalse(OnboardingPrompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: View wiring

    func testOnboardingViewInitializes() {
        // View-init smoke (same bar as FleetComponentsTests): the onboarding
        // screen builds with its presenter seam.
        let view = GatewayOnboardingView(onEnterValues: {})
        XCTAssertNotNil(view.body)
    }

    func testDocsURLIsHTTPSAndPointsAtDocs() throws {
        let url = OnboardingDocs.bootstrapURL
        XCTAssertEqual(url.scheme, "https")
        XCTAssertTrue(url.absoluteString.contains("hermes-agent.nousresearch.com/docs"))
    }
}
