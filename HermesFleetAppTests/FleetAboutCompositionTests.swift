import XCTest
@testable import FleetUI

/// ADR-0011 hosted guards: legal URL constants, About tab model facts, and
/// the retired-identifier source pins (the settings version/legal rows moved
/// to About — reintroducing them in Settings must fail here).
final class FleetAboutCompositionTests: XCTestCase {

    // MARK: Legal URLs (ADR-0011 decisions 1–2)

    func testLegalURLsPointAtTheOfficialSubdomain() {
        XCTAssertEqual(FleetLegal.baseURL.absoluteString, "https://hermes-fleet.aiowa.dev")
        XCTAssertEqual(FleetLegal.termsURL.absoluteString, "https://hermes-fleet.aiowa.dev/terms")
        XCTAssertEqual(FleetLegal.privacyPolicyURL.absoluteString, "https://hermes-fleet.aiowa.dev/privacy")
        XCTAssertEqual(FleetLegal.supportURL.absoluteString, "https://github.com/AIowa-LLC/hermes-fleet/issues")
    }

    // MARK: Tab model (ADR-0011 decision 3)

    func testAboutTabModelFacts() {
        XCTAssertEqual(FleetTab.about.label, "About")
        XCTAssertEqual(FleetTab.about.systemImage, "info.circle")
        XCTAssertFalse(FleetTab.about.isPrimary, "About renders as a drawer dedicated row, not a Navigate primary")
        XCTAssertEqual(FleetTab.allCases.last, .about, "About is the last tab")
    }

    func testSettingsSubScreensOwnToTheSettingsTab() {
        XCTAssertEqual(FleetScreen.settingsSecurity.owner, .settings)
        XCTAssertEqual(FleetScreen.settingsData.owner, .settings)
    }

    // MARK: Retired-identifier source pins

    private func repoSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testSettingsViewRetiresVersionAndLegalRows() throws {
        let source = try repoSource("Packages/FleetUI/Sources/FleetUI/FleetSettingsView.swift")
        for retired in ["fleet.settings.version", "fleet.settings.privacy-policy", "fleet.settings.support"] {
            XCTAssertFalse(source.contains(retired),
                           "\(retired) must not render in Settings — it moved to About (ADR-0011)")
        }
        XCTAssertTrue(source.contains("fleet.settings.security"),
                      "the Security chevron row must replace the inline toggle")
        XCTAssertTrue(source.contains("fleet.settings.data"),
                      "the Data & Storage chevron row must replace the inline cache button")
    }

    func testAboutViewCarriesTheMovedIdentifiers() throws {
        let source = try repoSource("Packages/FleetUI/Sources/FleetUI/FleetAboutView.swift")
        XCTAssertTrue(source.contains("\"fleet.about.version\""))
        XCTAssertTrue(source.contains("\"fleet.about.terms\""))
        XCTAssertTrue(source.contains("\"fleet.about.privacy-policy\""))
        XCTAssertTrue(source.contains("\"fleet.about.support\""))
        XCTAssertTrue(source.contains("FleetLegal.privacyPolicyURL"))
    }

    // MARK: DEV14 brand consistency

    func testAboutAndOnboardingUseTheSharedBrandMarkNotSFSymbols() throws {
        let about = try repoSource("Packages/FleetUI/Sources/FleetUI/FleetAboutView.swift")
        XCTAssertTrue(about.contains("FleetBrandMark("), "About must use the approved wing mark")
        XCTAssertFalse(about.contains("square.grid.2x2"), "the placeholder SF Symbol must not return")
        let owner = try repoSource("Packages/FleetUI/Sources/FleetUI/GatewayOnboardingView.swift")
        XCTAssertTrue(owner.contains("FleetBrandMark("))
        XCTAssertFalse(owner.contains("circle.hexagongrid"), "the seven-dot symbol must not return")
        for file in ["QRFirstServerView", "AdditionalGatewaySheet"] {
            let source = try repoSource("Packages/FleetUI/Sources/FleetUI/\(file).swift")
            XCTAssertTrue(source.contains("FleetBrandMark("), "\(file) must show the shared brand mark")
        }
    }

    func testBrandMarkCornerRadiusMatchesFirstRunHeaderAtDefaultSize() {
        XCTAssertEqual(FleetBrandMark.cornerRadius(for: 72), FleetTheme.radiusCard)
        XCTAssertEqual(FleetBrandMark.cornerRadius(for: 36), FleetTheme.radiusCard / 2)
    }

    // MARK: DEV14 single setup-prompt source

    func testFirstRunAndAdditionalGatewayShareOneSetupPromptSource() throws {
        XCTAssertTrue(PairingSetupPrompt.ownerMessage.contains("actual incoming event is a private Telegram message"))
        let sources = "Packages/FleetUI/Sources/FleetUI/"
        for file in ["QRFirstServerView", "AdditionalGatewaySheet"] {
            let source = try repoSource("\(sources)\(file).swift")
            XCTAssertTrue(source.contains("PairingSetupPromptCard("), "\(file) must use the shared prompt card")
            XCTAssertTrue(source.contains("PairingScanAction("), "\(file) must use the shared scan action")
            XCTAssertFalse(source.contains("First verify that this actual incoming event"),
                           "\(file) must not carry its own copy of the prompt")
        }
        let card = try repoSource("\(sources)PairingSetupComponents.swift")
        XCTAssertEqual(card.components(separatedBy: "PairingSetupPrompt.ownerMessage").count - 1, 2,
                       "the card copies and renders the single maintained prompt")
        XCTAssertFalse(try repoSource("\(sources)GatewaysView.swift").contains("GatewayOnboardingView("),
                       "Gateways must present the QR-first sheet, not the old address flow")
        XCTAssertFalse(try repoSource("\(sources)FleetSettingsView.swift").contains("GatewayOnboardingView("),
                       "Settings must present the QR-first sheet, not the old address flow")
    }
}
