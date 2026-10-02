import XCTest
import SwiftUI
import UIKit
@testable import FleetUI

@MainActor
final class ScenePrivacyShieldTests: XCTestCase {
    func testInactiveSceneIsCoveredWhileAnotherSceneStaysActive() {
        var first = ScenePrivacyShieldPolicy()
        var second = ScenePrivacyShieldPolicy()
        first.handle(.inactive, contentUnlocked: true, enabled: true, aggregateCoverIntent: false)
        second.handle(.active, contentUnlocked: true, enabled: true, aggregateCoverIntent: false)
        XCTAssertTrue(first.isVisible)
        XCTAssertFalse(second.isVisible)
        first.reconcile(contentUnlocked: true, enabled: true, aggregateCoverIntent: false)
        XCTAssertTrue(first.isVisible, "another scene becoming active cannot remove this cover")
    }

    func testScenesKeepIndependentBackgroundCovers() {
        var first = ScenePrivacyShieldPolicy()
        var second = ScenePrivacyShieldPolicy()
        first.handle(.background, contentUnlocked: true, enabled: true, aggregateCoverIntent: false)
        second.handle(.background, contentUnlocked: false, enabled: true, aggregateCoverIntent: true)
        first.handle(.active, contentUnlocked: false, enabled: true, aggregateCoverIntent: false)
        second.reconcile(contentUnlocked: false, enabled: true, aggregateCoverIntent: false)
        XCTAssertFalse(first.isVisible)
        XCTAssertTrue(second.isVisible)
    }

    func testDirectBackgroundBeforeAggregateRelockCoversContent() {
        var scene = ScenePrivacyShieldPolicy()
        scene.handle(.background, contentUnlocked: true, enabled: true, aggregateCoverIntent: false)
        scene.reconcile(contentUnlocked: false, enabled: true, aggregateCoverIntent: true)
        XCTAssertTrue(scene.isVisible)
    }

    func testDirectBackgroundAfterAggregateRelockUsesLatchedIntent() {
        var scene = ScenePrivacyShieldPolicy()
        scene.handle(.background, contentUnlocked: false, enabled: true, aggregateCoverIntent: true)
        XCTAssertTrue(scene.isVisible)
    }

    func testDisablingAppLockClearsInactiveAndBackgroundCovers() {
        for phase in [ScenePhase.inactive, .background] {
            var scene = ScenePrivacyShieldPolicy()
            scene.handle(phase, contentUnlocked: true, enabled: true, aggregateCoverIntent: true)
            XCTAssertTrue(scene.isVisible)
            scene.reconcile(contentUnlocked: true, enabled: false, aggregateCoverIntent: true)
            XCTAssertFalse(scene.isVisible)
        }
    }

    func testDisabledModeNeverArmsSceneCover() {
        var scene = ScenePrivacyShieldPolicy()
        scene.handle(.inactive, contentUnlocked: true, enabled: false, aggregateCoverIntent: true)
        XCTAssertFalse(scene.isVisible)
        scene.handle(.background, contentUnlocked: true, enabled: false, aggregateCoverIntent: true)
        XCTAssertFalse(scene.isVisible)
    }

    func testAuthenticationSheetAndInactiveUnlockNeverNewlyArmCover() {
        var scene = ScenePrivacyShieldPolicy()
        scene.handle(.inactive, contentUnlocked: false, enabled: true, aggregateCoverIntent: false)
        XCTAssertFalse(scene.isVisible)
        scene.reconcile(contentUnlocked: true, enabled: true, aggregateCoverIntent: false)
        XCTAssertFalse(scene.isVisible, "a system authentication sheet dismissal must not flash a cover")
    }

    func testUnlockInAnotherSceneProtectsBackgroundScene() {
        var scene = ScenePrivacyShieldPolicy()
        scene.handle(.background, contentUnlocked: false, enabled: true, aggregateCoverIntent: false)
        XCTAssertFalse(scene.isVisible)
        scene.reconcile(contentUnlocked: true, enabled: true, aggregateCoverIntent: false)
        XCTAssertTrue(scene.isVisible)
    }

    func testOwnActiveTransitionClearsItsCover() {
        var scene = ScenePrivacyShieldPolicy()
        scene.handle(.inactive, contentUnlocked: true, enabled: true, aggregateCoverIntent: false)
        scene.handle(.active, contentUnlocked: true, enabled: true, aggregateCoverIntent: true)
        XCTAssertFalse(scene.isVisible)
    }

    func testAggregateClearDoesNotRemoveExistingInactiveCover() {
        var scene = ScenePrivacyShieldPolicy()
        scene.handle(.inactive, contentUnlocked: true, enabled: true, aggregateCoverIntent: true)
        scene.reconcile(contentUnlocked: false, enabled: true, aggregateCoverIntent: false)
        XCTAssertTrue(scene.isVisible)
    }

    private func makeHostWindow() throws -> UIWindow {
        // Explicit hosted-test fixture. Production resolves ownership only
        // through the attached root view and never enumerates global scenes.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.isHidden = false
        return window
    }

    func testPendingCoverWaitsForExplicitOwnerAndDetachesImmediately() throws {
        let host = try makeHostWindow()
        defer { host.isHidden = true; host.rootViewController = nil }
        let renderer = PrivacyShieldWindow()
        defer { renderer.bind(to: nil) }
        renderer.setVisible(true)
        XCTAssertFalse(renderer.isShowing, "unbound covers must not select somebody else's scene")
        renderer.bind(to: host.windowScene)
        XCTAssertTrue(renderer.isShowing)
        renderer.bind(to: nil)
        XCTAssertFalse(renderer.isShowing)
        renderer.bind(to: host.windowScene)
        XCTAssertTrue(renderer.isShowing, "reattachment retains the pending cover intent")
    }

    func testReaderBindsOnlyThroughItsAttachedWindow() throws {
        let host = try makeHostWindow()
        defer { host.isHidden = true; host.rootViewController = nil }
        let renderer = PrivacyShieldWindow()
        let reader = PrivacyShieldSceneReaderView(frame: .zero)
        reader.renderer = renderer
        renderer.setVisible(true)
        XCTAssertFalse(renderer.isShowing)
        host.rootViewController!.view.addSubview(reader)
        XCTAssertTrue(reader.window === host)
        XCTAssertTrue(renderer.isShowing)
        reader.removeFromSuperview()
        XCTAssertNil(reader.window)
        XCTAssertFalse(renderer.isShowing)
        host.rootViewController!.view.addSubview(reader)
        XCTAssertTrue(renderer.isShowing)
        reader.removeFromSuperview()
    }

    func testOldFadeCannotHideReattachedCover() async throws {
        let host = try makeHostWindow()
        defer { host.isHidden = true; host.rootViewController = nil }
        let renderer = PrivacyShieldWindow()
        defer { renderer.bind(to: nil) }
        renderer.bind(to: host.windowScene)
        renderer.setVisible(true)
        renderer.setVisible(false)
        renderer.bind(to: nil)
        renderer.setVisible(true)
        renderer.bind(to: host.windowScene)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(renderer.isShowing)
    }
}
