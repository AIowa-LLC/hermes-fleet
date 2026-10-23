import XCTest
import FleetCore
@testable import FleetUI

/// Header reasoning chip: label formatting (known / unknown / unsupported) and
/// the single pick path (selecting a level calls the slider's `apply`).
/// Synthetic scripted seam only: no gateway, no network.
@MainActor
final class ReasoningHeaderChipTests: XCTestCase {

    // MARK: - Label formatting

    func testKnownLevelFormatsWithPlainLabel() {
        XCTAssertEqual(
            ReasoningHeaderFormat.text(level: .medium, displayWord: "Medium"),
            "Reasoning: Medium")
        XCTAssertEqual(
            ReasoningHeaderFormat.text(level: .xhigh, displayWord: "xhigh"),
            "Reasoning: Extra High")
    }

    func testUnknownLevelShowsPlaceholder() {
        XCTAssertEqual(
            ReasoningHeaderFormat.text(level: nil, displayWord: "—"),
            "Reasoning: —")
        XCTAssertEqual(
            ReasoningHeaderFormat.text(level: nil, displayWord: "   "),
            "Reasoning: —", "a blank readback is unknown, never an empty word")
    }

    func testUnmappedReadbackShowsRawWordVerbatim() {
        XCTAssertEqual(
            ReasoningHeaderFormat.text(level: nil, displayWord: "turbo"),
            "Reasoning: turbo", "an unmapped wire word is shown honestly, not guessed")
    }

    func testUnsupportedSessionHasNoLabel() {
        XCTAssertNil(ReasoningHeaderFormat.label(for: nil),
                     "no reasoning seam means the chip is hidden (no label at all)")
    }

    func testLabelReflectsViewModelState() {
        let model = ReasoningViewModel(reasoning: FakeReasoning(), initial: .low)
        XCTAssertEqual(ReasoningHeaderFormat.label(for: model), "Reasoning: Low")
    }

    func testUnknownViewModelShowsPlaceholder() {
        let model = ReasoningViewModel(reasoning: FakeReasoning())
        XCTAssertEqual(ReasoningHeaderFormat.label(for: model), "Reasoning: —")
    }

    // MARK: - Pick path

    func testSelectingLevelCallsSliderApply() async {
        let fake = FakeReasoning()
        let model = ReasoningViewModel(reasoning: fake)
        model.bind(sessionID: "s-1")
        await model.load(sessionID: "s-1")
        XCTAssertEqual(model.level, .medium)

        var opened = false
        await ReasoningHeaderChip.select(.high, on: model) { opened = true }

        XCTAssertEqual(fake.sets, [.high], "the header pick goes through the slider's apply path")
        XCTAssertEqual(model.level, .high)
        XCTAssertEqual(ReasoningHeaderFormat.label(for: model), "Reasoning: High")
        XCTAssertFalse(opened, "a successful pick does not open the overlay")
    }

    func testFailedPickSurfacesErrorThroughOverlay() async {
        let fake = FakeReasoning()
        fake.failSets = true
        let model = ReasoningViewModel(reasoning: fake)
        model.bind(sessionID: "s-1")
        await model.load(sessionID: "s-1")

        var opened = false
        await ReasoningHeaderChip.select(.low, on: model) { opened = true }

        XCTAssertTrue(opened, "a failed pick opens the slider overlay where the error is shown")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.level, .medium, "the optimistic level reverts on failure")
        XCTAssertEqual(ReasoningHeaderFormat.label(for: model), "Reasoning: Medium")
    }
}

/// Synthetic `ReasoningProviding`: records `setReasoning` calls and can be
/// told to fail. No I/O.
private final class FakeReasoning: ReasoningProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _sets: [FleetReasoningLevel] = []
    private var _failSets = false

    var sets: [FleetReasoningLevel] {
        lock.lock(); defer { lock.unlock() }
        return _sets
    }

    var failSets: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failSets }
        set { lock.lock(); _failSets = newValue; lock.unlock() }
    }

    func reasoning(sessionID: String) async throws -> ReasoningState {
        ReasoningState(level: .medium, rawValue: "medium", display: nil)
    }

    func setReasoning(_ level: FleetReasoningLevel, sessionID: String) async throws -> FleetReasoningLevel {
        let shouldFail = record(level)
        if shouldFail {
            throw ConversationError.rpcFailed("scripted failure")
        }
        return level
    }

    private func record(_ level: FleetReasoningLevel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _sets.append(level)
        return _failSets
    }
}
