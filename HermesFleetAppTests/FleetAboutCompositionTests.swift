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
}
