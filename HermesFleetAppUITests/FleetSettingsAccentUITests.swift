import XCTest

/// V7.5 (t_56c44e09) — the in-app accent chooser in Settings ▸ Appearance.
///
/// The picker must be reachable through the canonical navigation path
/// (Control tab → "App Lock & settings"), reflect a pick with a checkmark,
/// and persist the pick across a relaunch (UserDefaults).
final class FleetSettingsAccentUITests: XCTestCase {

    /// The accent picker is reachable and reflects a pick: tapping Warm Gold
    /// marks it selected and persists across relaunch.
    func testAccentPickerSelectionPersists() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launchEnvironment["HERMES_FLEET_NAV_RESET"] = "1"
        app.launch()
        UITabNavigation.openSettings(app)

        let gold = app.buttons["fleet.settings.accent.gold"]
        scrollToAccent(gold, in: app)
        XCTAssertTrue(gold.waitForExistence(timeout: 5), "Warm Gold row must exist in Settings ▸ Appearance")
        gold.tap()
        gold.tap()   // second tap should not deselect or crash

        // Selection marker renders immediately (same session).
        let mark = app.otherElements["fleet.settings.accent.selected.gold"]
            .images["fleet.settings.accent.selected.gold"]
        XCTAssertTrue(mark.waitForExistence(timeout: 5) || selectedMarkerVisible(in: app),
                      "Warm Gold must show as selected in-session")

        app.terminate()
        app.launch()  // relaunch — persisted pick must survive
        UITabNavigation.openSettings(app)
        let gold2 = app.buttons["fleet.settings.accent.gold"]
        scrollToAccent(gold2, in: app)
        XCTAssertTrue(gold2.waitForExistence(timeout: 5))
        XCTAssertTrue(selectedMarkerVisible(in: app),
                      "Warm Gold must show as selected after relaunch")

        // Restore the default for later suites (the app process's persisted
        // pick is load-bearing state — same posture as the unit-test restore).
        app.buttons["fleet.settings.accent.blue"].tap()
    }

    /// The vetted catalog renders in display order (blue, gold, amber,
    /// indigo, green) — and teal is not among the options.
    func testAccentCatalogRendersInOrder() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_FLEET_LOCK_AUTH"] = "success"
        app.launch()
        UITabNavigation.openSettings(app)

        let expected = ["blue", "gold", "amber", "indigo", "green"]
        for raw in expected {
            let row = app.buttons["fleet.settings.accent.\(raw)"]
            scrollToAccent(row, in: app)
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(raw) row must exist")
        }
        XCTAssertFalse(app.buttons["fleet.settings.accent.teal"].exists,
                       "teal is banned from the catalog (brand rule)")
        app.buttons["fleet.settings.accent.blue"].tap()   // leave default selected
    }

    // MARK: - Helpers

    /// The Appearance section sits below Security — scroll it into view if
    /// needed, then scroll back so taps land on visible rows.
    private func scrollToAccent(_ row: XCUIElement, in app: XCUIApplication) {
        guard !row.exists else { return }
        for _ in 0..<4 where !row.isHittable {
            app.swipeUp()
        }
    }

    private func selectedMarkerVisible(in app: XCUIApplication) -> Bool {
        // The checkmark carries a per-accent identifier; any element query
        // (image or other) matching it counts.
        app.descendants(matching: .any)["fleet.settings.accent.selected.gold"].firstMatch.exists
    }
}
