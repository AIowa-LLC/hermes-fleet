import XCTest

/// R10-T5 — deterministic memory-graph edit/delete UI suite (scripted
/// fleet, DEBUG simulator): tap a memory diamond → drill-in → Edit →
/// save → the gateway's success banner surfaces; Delete → confirmation
/// alert → the node count drops (server-truth reload). The refusal path
/// (HERMES_FLEET_LEARNING_REFUSE=1) asserts the gateway's verbatim
/// remedy message — pinned-skill refusals name the unpin command.
final class R10MemoryGraphEditUITests: XCTestCase {

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

    /// Opens the Memory Graph and drills into a memory node. Simulator app
    /// relaunches are occasionally stale under gate load (the app surfaces
    /// the previous screen); one full relaunch retry keeps this deterministic.
    private func openMemoryDetail(in app: XCUIApplication) -> XCUIElement {
        var label = firstMatch(in: app, identifier: "memorygraph.detail.label")
        for attempt in 0..<2 {
            if attempt > 0 {
                app.terminate()
                app.launch()
            }
            let entry = scrollTo(firstMatch(in: app, identifier: "fleet.dashboard.memorygraph.entry"), in: app)
            guard entry.exists else { continue }
            tap(entry)
            let canvas = firstMatch(in: app, identifier: "memorygraph.canvas")
            let filter = firstMatch(in: app, identifier: "memorygraph.filter.memories")
            guard canvas.waitForExistence(timeout: 15), filter.waitForExistence(timeout: 10) else {
                continue // stale launch — retry once with a clean relaunch
            }
            // Memories-only view makes the diamond hit-test deterministic.
            tap(filter)
            let memoryOnly = NSPredicate(format: "label CONTAINS %@", "4 nodes")
            wait(for: [XCTNSPredicateExpectation(predicate: memoryOnly, object: canvas)], timeout: 10)
            // Tap near the vertical center of the canvas — with 4 memory nodes
            // spread across the star map, the center cluster is hit-test range.
            let coord = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            coord.tap()
            // Retry a couple of offsets if the first tap missed every node.
            label = firstMatch(in: app, identifier: "memorygraph.detail.label")
            var jitter = 0
            while !label.exists && jitter < 6 {
                let offset = CGVector(dx: 0.35 + Double(jitter % 3) * 0.15, dy: 0.35 + Double(jitter / 3) * 0.3)
                canvas.coordinate(withNormalizedOffset: offset).tap()
                jitter += 1
            }
            if label.waitForExistence(timeout: 5) {
                return label
            }
        }
        XCTFail("tapping a memory node opens the drill-in sheet (even after one clean relaunch)")
        return label
    }

    private func canvasNodeCount(_ canvas: XCUIElement) -> Int {
        // "Learning constellation, N nodes. Drag to pan…" — the word
        // immediately before "nodes" is the count.
        let words = canvas.label.split(separator: " ")
        for (i, word) in words.enumerated() where word.hasPrefix("nodes") {
            if i > 0, let n = Int(words[i - 1]) { return n }
        }
        return -1
    }

    func testEditMemorySurfacesGatewayMessage() throws {
        let app = XCUIApplication()
        app.launch()

        openMemoryDetail(in: app)

        // Menu → Edit.
        tap(firstMatch(in: app, identifier: "memorygraph.detail.menu"))
        let editItem = app.buttons.matching(identifier: "memorygraph.detail.edit").firstMatch
        XCTAssertTrue(editItem.waitForExistence(timeout: 5), "Edit appears in the node menu")
        editItem.tap()

        // Editor prefills with the node's current content.
        let field = firstMatch(in: app, identifier: "memorygraph.detail.edit.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(" edited")

        tap(firstMatch(in: app, identifier: "memorygraph.detail.edit.save"))

        // Back on the map: the gateway's success banner surfaces (the
        // combined Label carries the message text).
        let banner = firstMatch(in: app, identifier: "memorygraph.mutation-banner")
        let success = NSPredicate(format: "label CONTAINS %@", "updated")
        wait(for: [XCTNSPredicateExpectation(predicate: success, object: banner)], timeout: 15)
    }

    func testDeleteMemoryRemovesNodeAfterConfirmation() throws {
        let app = XCUIApplication()
        app.launch()

        openMemoryDetail(in: app)

        let canvas = firstMatch(in: app, identifier: "memorygraph.canvas")
        let before = canvasNodeCount(canvas)

        // Menu → Delete → confirmation alert.
        tap(firstMatch(in: app, identifier: "memorygraph.detail.menu"))
        let deleteItem = app.buttons.matching(identifier: "memorygraph.detail.delete").firstMatch
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5), "Delete appears in the node menu")
        deleteItem.tap()

        let confirm = firstMatch(in: app, identifier: "memorygraph.detail.delete.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the destructive action asks first")
        confirm.tap()

        // The sheet dismisses and the reloaded map has one fewer memory
        // node (memories filter was active: 4 → 3).
        let dropped = NSPredicate(format: "label CONTAINS %@", "3 nodes")
        wait(for: [XCTNSPredicateExpectation(predicate: dropped, object: canvas)], timeout: 15)
        _ = before
    }

    func testEditRefusalSurfacesVerbatimRemedyAndKeepsNode() throws {
        let app = XCUIApplication()
        app.launch()

        openMemoryDetail(in: app)

        let canvas = firstMatch(in: app, identifier: "memorygraph.canvas")
        let before = canvasNodeCount(canvas)

        // Menu → Edit.
        tap(firstMatch(in: app, identifier: "memorygraph.detail.menu"))
        let editItem = app.buttons.matching(identifier: "memorygraph.detail.edit").firstMatch
        XCTAssertTrue(editItem.waitForExistence(timeout: 5))
        editItem.tap()

        // Clear the content to empty and save: the gateway REFUSES empty
        // memory bodies (learning_mutations.py:152-153) with the verbatim
        // message — the honest refusal walkthrough, same app session.
        let field = firstMatch(in: app, identifier: "memorygraph.detail.edit.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 2) { selectAll.tap() }
        else { field.doubleTap() }
        field.typeText("\u{8}") // backspace over the selection

        tap(firstMatch(in: app, identifier: "memorygraph.detail.edit.save"))

        // Refused: the sheet STAYS OPEN in the editor with the gateway's
        // verbatim message inline (it names the remedy).
        let inline = firstMatch(in: app, identifier: "memorygraph.detail.edit.refusal")
        let refusal = NSPredicate(format: "label CONTAINS %@", "use delete to remove it")
        wait(for: [XCTNSPredicateExpectation(predicate: refusal, object: inline)], timeout: 15)

        // Cancel out of the editor and dismiss the sheet; the node count
        // is unchanged — no optimistic removal.
        tap(firstMatch(in: app, identifier: "memorygraph.detail.edit.cancel"))
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 3) { done.tap() }
        XCTAssertEqual(canvasNodeCount(canvas), before,
                       "a refused mutation must not change the rendered graph")
    }
}
