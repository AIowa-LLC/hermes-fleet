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

    private func repoPath(_ relativePath: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relativePath).path
    }

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

    // MARK: Universal login: one default path, one legacy prompt source

    func testFirstRunAndAdditionalGatewayShareOneConnectPathAndOneLegacyPromptSource() throws {
        XCTAssertTrue(PairingSetupPrompt.ownerMessage.contains("private Telegram message from the verified owner"))
        let owner = PairingSetupPrompt.ownerMessage
        for needle in ["/fleetsetup", "/fleetstatus", "/fleetqr", "/fleetdevices", "two minutes", "existing owner binding"] {
            XCTAssertTrue(owner.contains(needle), "legacy setup prompt must describe the connector contract: \(needle)")
        }
        let sources = "Packages/FleetUI/Sources/FleetUI/"
        for file in ["QRFirstServerView", "AdditionalGatewaySheet"] {
            let source = try repoSource("\(sources)\(file).swift")
            XCTAssertTrue(source.contains("PairingConnectContent("), "\(file) must use the shared connect content")
            XCTAssertTrue(source.contains("PairingOtherWaysEntry("), "\(file) must offer Other ways to connect")
            XCTAssertTrue(source.contains("PairingOtherWaysPage("), "\(file) must present the shared Other ways page")
            XCTAssertFalse(source.contains("PairingSetupPromptCard("),
                           "\(file) must keep the Telegram prompt out of the default path")
            XCTAssertFalse(source.contains("Telegram"), "\(file) must not mention Telegram on the default path")
            XCTAssertFalse(source.contains("Help me set up Hermes Fleet on this host"),
                           "\(file) must not carry its own copy of the prompt")
        }
        let components = try repoSource("\(sources)PairingSetupComponents.swift")
        let connect = try XCTUnwrap(components.range(of: "struct PairingConnectContent"))
        let other = try XCTUnwrap(components.range(of: "/// \"Other ways to connect\": the existing owner sign-in"))
        let connectSource = String(components[connect.lowerBound..<other.lowerBound])
        XCTAssertFalse(connectSource.contains("Telegram"), "the default connect content must not mention Telegram")
        XCTAssertTrue(connectSource.contains("/fleet pair"))
        XCTAssertTrue(connectSource.contains("Scan QR code") && connectSource.contains("Paste link"))
        XCTAssertTrue(components[other.lowerBound...].contains("PairingSetupPromptCard("),
                      "the legacy prompt lives under Other ways to connect")
        XCTAssertEqual(components.components(separatedBy: "PairingSetupPrompt.ownerMessage").count - 1, 2,
                       "the card copies and renders the single maintained prompt")
        XCTAssertFalse(try repoSource("\(sources)GatewaysView.swift").contains("GatewayOnboardingView("),
                       "Gateways must present the connect sheet, not the old address flow")
        XCTAssertFalse(try repoSource("\(sources)FleetSettingsView.swift").contains("GatewayOnboardingView("),
                       "Settings must present the connect sheet, not the old address flow")
    }

    func testPasteReadsThePasteboardOnlyWhenTheButtonIsTapped() throws {
        let components = try repoSource("Packages/FleetUI/Sources/FleetUI/PairingSetupComponents.swift")
        XCTAssertEqual(components.components(separatedBy: "UIPasteboard.general.string").count - 1, 2,
                       "one copy action plus the single tap-only read in PairingPasteboard")
        let tap = try XCTUnwrap(components.range(of: "// Read the pasteboard only now, on the person's tap."))
        XCTAssertTrue(components[tap.upperBound...].prefix(200).contains("PairingPasteboard.text()"))
        for file in try FileManager.default.contentsOfDirectory(atPath: repoPath("Packages/FleetUI/Sources/FleetUI"))
        where file.hasSuffix(".swift") && file != "PairingSetupComponents.swift" {
            let source = try repoSource("Packages/FleetUI/Sources/FleetUI/\(file)")
            XCTAssertFalse(source.contains("UIPasteboard.general.string") && source.contains("PairingInvitationLink"),
                           "\(file) must not read the pasteboard for pairing links")
        }
    }
}
