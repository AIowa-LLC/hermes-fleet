import XCTest
import FleetCore
@testable import FleetUI

/// Refinement Phase 3: curated themes, alternate app icons, avatar ink, and
/// the Reduce Motion gating of the new micro-interactions.
@MainActor
final class RefinementPhase3Tests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Curated themes

    func testCuratedSetIsFiveThemesLedByTheFleetDefault() {
        XCTAssertEqual(FleetCuratedTheme.allCases.map(\.label),
                       ["Fleet", "Violet", "Ocean", "Orchid", "Graphite"])
        XCTAssertEqual(FleetCuratedTheme.fleet.palette, .fleetDefault)
    }

    /// Every theme, in both appearances, at render resolution: highlight
    /// reaches text contrast on the canvas and the derived surfaces, and the
    /// ink drawn on a highlight fill does too.
    func testEveryThemePassesContrastInBothAppearances() {
        for curated in FleetCuratedTheme.allCases {
            for isDark in [false, true] {
                let values = FleetThemeValues(
                    palette: curated.palette, isDarkAppearance: isDark, isIncreasedContrast: false)
                let resolved = curated.palette.palette(forDarkAppearance: isDark)
                let highlight = resolved.highlight
                let mode = isDark ? "dark" : "light"
                XCTAssertEqual(highlight, isDark ? curated.darkHighlight : curated.lightHighlight,
                               "\(curated.label) \(mode) resolves its own highlight")
                XCTAssertGreaterThanOrEqual(
                    FleetThemeContrast.ratio(highlight, resolved.background), 4.5,
                    "\(curated.label) \(mode) highlight on canvas")
                XCTAssertGreaterThanOrEqual(
                    FleetThemeContrast.ratio(highlight, values.surfaceElevatedStored), 4.5,
                    "\(curated.label) \(mode) highlight on elevated surface")
                let ink = FleetThemeContrast.maxContrastInk(on: highlight)
                XCTAssertGreaterThanOrEqual(FleetThemeContrast.ratio(ink, highlight), 4.5,
                                            "\(curated.label) \(mode) ink on highlight fill")
                XCTAssertFalse(curated.palette.hasInvisiblePair)
            }
        }
    }

    /// The Python gate and the Swift table must describe the same themes.
    func testContrastGateScriptPinsTheSameThemeTable() throws {
        let script = try source("scripts/fos7_contrast_gate.py")
        for curated in FleetCuratedTheme.allCases {
            let light = String(curated.lightHighlight.hexString.dropFirst())
            let dark = String(curated.darkHighlight.hexString.dropFirst())
            let pattern = "(\"\(curated.rawValue)\",\\s*0x\(light),\\s*0x\(dark))"
            XCTAssertNotNil(script.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
                            "gate script must list \(curated.rawValue) as \(light)/\(dark)")
        }
    }

    func testMatchingRecognisesThemesAndLeavesLegacyAccentsCustom() {
        XCTAssertEqual(FleetCuratedTheme.matching(active: .fleetDefault), .fleet)
        for curated in FleetCuratedTheme.allCases {
            XCTAssertEqual(FleetCuratedTheme.matching(active: curated.palette), curated)
        }
        // The legacy White accent is the Graphite palette exactly.
        XCTAssertEqual(FleetCuratedTheme.matching(active: FleetAccent.white.palette), .graphite)
        // A legacy accent outside the set stays Custom and is never rewritten.
        XCTAssertNil(FleetCuratedTheme.matching(active: FleetAccent.blue.palette))
        // Violet shares the default's light highlight; the resolution mode
        // keeps them distinct.
        XCTAssertNotEqual(FleetCuratedTheme.violet.palette, FleetCuratedTheme.fleet.palette)
    }

    func testCuratedPaletteRoundTripsAndApplies() throws {
        let defaults = UserDefaults(suiteName: "RefinementPhase3Tests.\(UUID().uuidString)")!
        let controller = FleetThemeController(defaults: defaults)
        XCTAssertTrue(controller.apply(FleetCuratedTheme.ocean.palette))
        let reloaded = FleetThemeController(defaults: defaults)
        XCTAssertEqual(reloaded.activePalette, FleetCuratedTheme.ocean.palette)
        XCTAssertEqual(reloaded.activePalette.palette(forDarkAppearance: true).highlight,
                       FleetCuratedTheme.ocean.darkHighlight)
    }

    func testUnknownCuratedHighlightKeepsItsStoredColorInDark() {
        let stray = FleetThemePalette(
            highlight: FleetStoredColor(hex: 0x334455),
            text: FleetThemePalette.fleetDefault.text,
            background: FleetThemePalette.fleetDefault.background,
            appearance: .adaptiveCurated)
        let dark = stray.palette(forDarkAppearance: true)
        XCTAssertEqual(dark.highlight, FleetStoredColor(hex: 0x334455))
        XCTAssertEqual(dark.background, FleetThemePalette.fleetDefaultDark.background)
    }

    // MARK: - Alternate app icons

    func testAlternateIconNamesMatchProjectRegistration() throws {
        let project = try source("project.yml")
        let alternates = FleetAppIcon.allCases.compactMap(\.alternateIconName)
        let registered = "ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES: \"\(alternates.joined(separator: " "))\""
        XCTAssertEqual(project.components(separatedBy: registered).count - 1, 2,
                       "both app targets register exactly the picker's alternates")
        for name in alternates {
            let set = repoRoot.appendingPathComponent("HermesFleetApp/Assets.xcassets/\(name).appiconset/icon-1024.png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: set.path), "\(name) icon source")
        }
        for icon in FleetAppIcon.allCases {
            let preview = repoRoot.appendingPathComponent(
                "HermesFleetApp/Assets.xcassets/\(icon.previewImageName).imageset/preview.png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path), "\(icon.label) preview")
        }
    }

    func testIconMatchingFallsBackToTheStandardIcon() {
        XCTAssertEqual(FleetAppIcon.matching(alternateIconName: nil), .standard)
        XCTAssertEqual(FleetAppIcon.matching(alternateIconName: "AppIconViolet"), .violet)
        XCTAssertEqual(FleetAppIcon.matching(alternateIconName: "RetiredIcon"), .standard)
    }

    func testIconControllerChangesOnlyAfterTheSystemAccepts() async {
        struct Refused: Error {}
        final class Log { var names: [String?] = [] }
        let log = Log()
        let accepting = FleetAppIconController(
            currentAlternateName: nil, supportsAlternateIcons: true,
            apply: { log.names.append($0) })
        let changed = await accepting.select(.midnight)
        XCTAssertTrue(changed)
        XCTAssertEqual(accepting.current, .midnight)
        XCTAssertEqual(log.names, ["AppIconMidnight"])

        let refusing = FleetAppIconController(
            currentAlternateName: "AppIconSilver", supportsAlternateIcons: true,
            apply: { _ in throw Refused() })
        let refused = await refusing.select(.standard)
        XCTAssertFalse(refused)
        XCTAssertEqual(refusing.current, .silver)

        let unsupported = FleetAppIconController(
            currentAlternateName: nil, supportsAlternateIcons: false,
            apply: { _ in XCTFail("must not apply when unsupported") })
        let ignored = await unsupported.select(.violet)
        XCTAssertFalse(ignored)
        XCTAssertEqual(unsupported.current, .standard)
    }

    // MARK: - Avatar

    func testAvatarEyesStayLegibleOnDarkAndLightFaces() {
        for hex: UInt32 in [0x1A1A2E, 0x000000, 0xF5E663, 0xFFFFFF, 0x5B35D5] {
            let tint = FleetStoredColor(hex: hex)
            let ink = FleetStoredColor(color: BotAvatarFace.eyeInk(on: tint.swiftUIColor))!
            XCTAssertGreaterThanOrEqual(FleetThemeContrast.ratio(ink, tint), 4.5,
                                        "eyes on \(tint.hexString)")
        }
    }

    // MARK: - Motion gating (source guards)

    func testNewMotionIsGatedOnReduceMotion() throws {
        let pill = try source("Packages/FleetUI/Sources/FleetUI/Components/StatusPill.swift")
        XCTAssertTrue(pill.contains("isActive: !reduceMotion && isExecuting"))
        XCTAssertTrue(pill.contains("reduceMotion ? .identity : .symbolEffect(.replace)"))

        let tabs = try source("Packages/FleetUI/Sources/FleetUI/FleetTabView.swift")
        XCTAssertTrue(tabs.contains("reduceMotion ? nil : Self.drawerSpring"))
        XCTAssertTrue(tabs.contains("reduceMotion ? nil : .easeInOut(duration: Self.destinationCrossfade)"))

        let banner = try source("Packages/FleetUI/Sources/FleetUI/ApprovalBanner.swift")
        XCTAssertTrue(banner.contains("if !reduceMotion { landed = true }"))
        XCTAssertTrue(banner.contains("AccessibilityNotification.Announcement(\"Approved\")"))

        let skeleton = try source("Packages/FleetUI/Sources/FleetUI/Components/FleetSkeleton.swift")
        XCTAssertTrue(skeleton.contains("if !reduceMotion { dimmed = true }"))
    }

    func testApprovedMomentHoldsBriefly() {
        XCTAssertGreaterThanOrEqual(ApprovalApprovedMoment.holdSeconds, 1.0)
        XCTAssertLessThanOrEqual(ApprovalApprovedMoment.holdSeconds, 2.0)
    }
}
