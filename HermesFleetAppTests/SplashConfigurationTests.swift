import XCTest
import FleetUI
@testable import HermesFleetApp

/// Launch-splash timing contract. Refinement Phase 1 replaced the 1.8s
/// static hold with a short branded moment: ~0.6–0.9s from the first in-app
/// frame to usable UI, with a pixel-matched handoff from the native
/// LaunchScreen. Timing is named constants, bounded here.
final class SplashConfigurationTests: XCTestCase {

    func testTotalLaunchMomentIsWithinSpec() {
        for reduceMotion in [false, true] {
            let total = SplashConfiguration.totalDuration(reduceMotion: reduceMotion)
            XCTAssertGreaterThanOrEqual(total, 0.6, "splash total must be >= 0.6s (reduceMotion: \(reduceMotion))")
            XCTAssertLessThanOrEqual(total, 0.9, "splash total must be <= 0.9s (reduceMotion: \(reduceMotion))")
        }
    }

    func testReduceMotionIsNoLongerThanTheFullMoment() {
        XCTAssertLessThanOrEqual(
            SplashConfiguration.totalDuration(reduceMotion: true),
            SplashConfiguration.totalDuration(reduceMotion: false))
    }

    func testFadeOutDurationIsPositive() {
        XCTAssertGreaterThan(
            SplashConfiguration.fadeOutDuration, 0,
            "cross-fade must be non-instant (no hard swap)")
    }

    func testMotionIsSubtle() {
        XCTAssertGreaterThan(SplashConfiguration.settleScale, 1)
        XCTAssertLessThanOrEqual(SplashConfiguration.settleScale, 1.1, "settle stays subtle")
        XCTAssertLessThanOrEqual(SplashConfiguration.liftScale, 1.2, "lift stays subtle")
    }

    /// The first in-app frame must match the native LaunchScreen so the
    /// handoff has no layout jump: same mark side and a system backdrop.
    func testFirstFrameMatchesTheNativeLaunchScreen() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let storyboard = try String(
            contentsOf: root.appendingPathComponent("HermesFleetApp/LaunchScreen.storyboard"),
            encoding: .utf8)
        let side = Int(SplashConfiguration.markSide)
        XCTAssertTrue(storyboard.contains("firstAttribute=\"width\" constant=\"\(side)\""))
        XCTAssertTrue(storyboard.contains("firstAttribute=\"height\" constant=\"\(side)\""))
        XCTAssertTrue(storyboard.contains("<color key=\"backgroundColor\" name=\"LaunchCanvas\"/>"))
        let splash = try String(
            contentsOf: root.appendingPathComponent("HermesFleetApp/SplashOverlayView.swift"),
            encoding: .utf8)
        XCTAssertTrue(splash.contains("theme.background.ignoresSafeArea()"))
    }

    /// The launch canvas asset carries the SPEC §14 canvas values, so the
    /// native launch surface equals the theme canvas the app paints next.
    func testLaunchCanvasMatchesTheThemeCanvas() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(
            "HermesFleetApp/Assets.xcassets/LaunchCanvas.colorset/Contents.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let colors = try XCTUnwrap(json["colors"] as? [[String: Any]])
        func hex(_ entry: [String: Any]) throws -> UInt32 {
            let color = try XCTUnwrap(entry["color"] as? [String: Any])
            let c = try XCTUnwrap(color["components"] as? [String: String])
            func channel(_ key: String) throws -> UInt32 {
                try XCTUnwrap(UInt32(XCTUnwrap(c[key]).dropFirst(2), radix: 16))
            }
            return try channel("red") << 16 | channel("green") << 8 | channel("blue")
        }
        let light = try XCTUnwrap(colors.first { $0["appearances"] == nil })
        let dark = try XCTUnwrap(colors.first { $0["appearances"] != nil })
        XCTAssertEqual(try hex(light), FleetColors.canvasLight)
        XCTAssertEqual(try hex(dark), FleetColors.canvasDark)
    }
}
