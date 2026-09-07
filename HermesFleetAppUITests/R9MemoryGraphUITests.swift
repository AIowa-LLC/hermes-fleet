import XCTest

/// R9-T7 — deterministic memory-graph UI suite (scripted fleet): the
/// dashboard Management entry opens the star map, the fixture summary +
/// filter chips render, the filter hides nodes, the scrubber cuts the
/// timeline, and the canvas is exploreable (pan gesture does not crash).
final class R9MemoryGraphUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func firstMatch(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        if element.exists { return element }
        for _ in 0..<8 where !element.exists {
            app.swipeUp(velocity: .fast)
        }
        return element
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 15), "element \(element) should appear")
        element.tap()
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMemoryGraphRendersFixtureAndFilters() throws {
        let app = XCUIApplication()
        app.launch()

        // Dashboard → Management → Memory Graph (below the fold).
        let entry = scrollTo(firstMatch(in: app, identifier: "fleet.dashboard.memorygraph.entry"), in: app)
        tap(entry)

        // Summary renders (fixture: 10 learned skills · 4 memories).
        let summary = firstMatch(in: app, identifier: "memorygraph.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 15),
                      "the fixture summary header should render")
        XCTAssertTrue(summary.label.contains("learned skills"),
                      "summary carries the server-style line; got: \(summary.label)")

        // The canvas exists with the fixture node count in its label.
        let canvas = firstMatch(in: app, identifier: "memorygraph.canvas")
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertTrue(canvas.label.contains("14 nodes"),
                      "fixture graph has 14 nodes; got: \(canvas.label)")

        attachScreenshot(of: app, name: "r9-memorygraph-star-map")

        // Filter: Memories only — the canvas node count drops.
        tap(firstMatch(in: app, identifier: "memorygraph.filter.memories"))
        let memoryOnly = NSPredicate(format: "label CONTAINS %@", "4 nodes")
        let memoryExpectation = XCTNSPredicateExpectation(predicate: memoryOnly, object: canvas)
        wait(for: [memoryExpectation], timeout: 10)
        attachScreenshot(of: app, name: "r9-memorygraph-memories-only")

        // Back to All.
        tap(firstMatch(in: app, identifier: "memorygraph.filter.all"))
        let allBack = NSPredicate(format: "label CONTAINS %@", "14 nodes")
        wait(for: [XCTNSPredicateExpectation(predicate: allBack, object: canvas)], timeout: 10)

        // Scrubber to ~0 cuts the timeline to the first bucket (1 node).
        let scrubber = firstMatch(in: app, identifier: "memorygraph.scrubber")
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        scrubber.adjust(toNormalizedSliderPosition: 0.05)
        let early = NSPredicate(format: "label CONTAINS %@", "1 nodes")
        wait(for: [XCTNSPredicateExpectation(predicate: early, object: canvas)], timeout: 10)
        attachScreenshot(of: app, name: "r9-memorygraph-scrubbed-early")

        // Pan gesture does not crash and keeps the canvas present.
        canvas.swipeUp(velocity: .fast)
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
    }
}
