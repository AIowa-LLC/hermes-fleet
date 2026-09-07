import XCTest
import SwiftUI
import FleetUI

/// F3/C2 — agent bootstrap prompt content tests.
///
/// The prompt is a versioned artifact that ships with the app: these tests
/// pin its SHAPE (mission coverage, hygiene, conciseness, non-empty) so copy
/// edits are safe, but silently dropping a mission leg or embedding a
/// cleartext/private endpoint fails the build.
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

    func testInstallLegNamesWiFiSideloadWithoutTestFlight() {
        // (1) APP INSTALL — Wi-Fi sideload is the path; TestFlight is called
        // out only to tell the agent NOT to use it.
        let text = OnboardingPrompt.text
        XCTAssertTrue(text.contains("Wi-Fi"))
        XCTAssertTrue(text.contains("sideload"))
        XCTAssertTrue(text.contains("no TestFlight"))
    }

    func testNetworkLegDescribesUserOwnedHttpsEndpoint() {
        // (2) NETWORK PATH — the user's OWN HTTPS-reachable endpoint, with a
        // certificate check; no maintainer host, raw LAN/tailnet IP, or
        // cleartext address in the prompt.
        let text = OnboardingPrompt.text
        XCTAssertTrue(text.contains("HTTPS"))
        XCTAssertTrue(text.contains("I control"),
                      "the endpoint must be user-owned, not maintainer-owned")
        XCTAssertTrue(text.contains("certificate"),
                      "the agent must verify the endpoint certificate")
        XCTAssertTrue(text.range(of: "HTTPS")!.lowerBound
                      < text.range(of: "authentication request")!.lowerBound,
                      "network guidance must precede the verify leg")
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
        // (5) REPLY — exactly URL, username, password + open-the-app guidance.
        let text = OnboardingPrompt.text
        XCTAssertTrue(text.contains("URL"))
        XCTAssertTrue(text.contains("username"))
        XCTAssertTrue(text.contains("password"))
    }

    func testVerifyLegConfirmsAuthFromPhoneNetworkPath() {
        // (6) VERIFY — endpoint answers auth from the path the phone will use.
        XCTAssertTrue(OnboardingPrompt.text.contains("authentication request"))
    }

    // MARK: Hygiene — no secrets, no private endpoints

    func testContainsNoSecretsOrEndpoints() throws {
        // Parameterization guard: cleartext http, private/tailnet IP literals,
        // and credential shapes must never appear. Describing the user's own
        // HTTPS endpoint generically is allowed — naming any maintainer or
        // per-user host is not.
        XCTAssertTrue(OnboardingPrompt.containsNoSecrets(),
                      "prompt contains a forbidden substring: \(OnboardingPrompt.forbiddenSubstrings.filter { OnboardingPrompt.text.contains($0) })")
    }

    func testNoMaintainerOrPrivateDetails() {
        // Belt-and-braces beyond the forbidden list: no maintainer identity,
        // host, or private address shape may appear — the prompt describes
        // the USER's endpoint generically (public release, prompt v3).
        let text = OnboardingPrompt.text
        for banned in ["tonysimons", "aiowa", "hermesfleet.gateway",
                       ".ts.net", "9120", "100.100.", "192.168."] {
            XCTAssertFalse(text.contains(banned), "prompt must not embed maintainer or per-user detail \"\(banned)\"")
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

    func testSetupPromptSheetInitializes() {
        // C2: the Settings-hosted setup-prompt sheet builds standalone.
        let view = SetupPromptSheet()
        XCTAssertNotNil(view.body)
    }

    func testDocsURLIsHTTPSAndPointsAtDocs() throws {
        let url = OnboardingDocs.bootstrapURL
        XCTAssertEqual(url.scheme, "https")
        XCTAssertTrue(url.absoluteString.contains("hermes-agent.nousresearch.com/docs"))
    }
}
