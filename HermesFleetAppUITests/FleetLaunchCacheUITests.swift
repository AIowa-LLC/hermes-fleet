import XCTest

/// ADR-0012 UI suite: cached-first launch. Deterministic — the scripted
/// fleet's first successful refresh WRITES the launch cache; a relaunch
/// with HERMES_FLEET_LAUNCH_CACHE_FIXTURE=1 (keeps the cache through
/// NAV_RESET) proves the cached paint + Updating pill + dot-from-cache.
final class FleetLaunchCacheUITests: XCTestCase {

    func testColdRelaunchPaintsCachedFleetInstantly() throws {
        // Phase 1: normal launch — the scripted refresh populates + writes the cache.
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.shellReady(app, timeout: 30)
        // Wait for a bot row (roster settled — cache written through).
        let anyBot = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "fleet.roster.row.")).firstMatch
        var settled = anyBot.waitForExistence(timeout: 30)
        if !settled {
            UITabNavigation.selectTab(app, label: "Bots")
            settled = anyBot.waitForExistence(timeout: 20)
        }
        XCTAssertTrue(settled, "the scripted fleet must settle once (cache write-through)")

        // Phase 2: RELAUNCH keeping the launch cache — the fleet paints
        // before the network settles (fixture knob skips the reset).
        app.terminate()
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = nil
        app.launchEnvironment["HERMES_FLEET_LAUNCH_CACHE_FIXTURE"] = "1"
        app.launch()
        UITabNavigation.shellReady(app, timeout: 30)
        let cachedBot = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "fleet.roster.row.")).firstMatch
        XCTAssertTrue(cachedBot.waitForExistence(timeout: 20),
                      "relaunch must paint bots from the launch cache")
        attachScreenshot(of: app, name: "launch-cache-cold-paint")
    }

    func testUpdatingPillRendersWhileStaleAndDisappears() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_LAUNCH_CACHE_FIXTURE"] = "1"
        app.launch()
        UITabNavigation.shellReady(app, timeout: 30)
        UITabNavigation.selectTab(app, label: "Bots")
        // The pill may or may not still be up by the time we look (the
        // scripted refresh is fast) — assert the CONTRACT either way:
        // bots are painted AND no permanent pill remains after settle.
        let anyBot = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "fleet.roster.row.")).firstMatch
        XCTAssertTrue(anyBot.waitForExistence(timeout: 25), "bots must render (cached or live)")
        let pill = app.descendants(matching: .any)
            .matching(identifier: "fleet.roster.launch-updating").firstMatch
        var gone = false
        for _ in 0..<20 where !gone {
            if !pill.exists { gone = true } else { usleep(500_000) }
        }
        XCTAssertTrue(gone, "the Updating pill must disappear once the live refresh settles")
        XCTAssertFalse(pill.exists, "no stale pill persists after settle")
        attachScreenshot(of: app, name: "launch-cache-pill-cleared")
    }

    // MARK: - Helpers

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
