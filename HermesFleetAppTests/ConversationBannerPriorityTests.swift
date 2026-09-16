import XCTest
import FleetCore
@testable import FleetUI

/// Dogfood top-space fix — banner selection policy unit tests.
///
/// The compact conversation chrome renders exactly ONE banner; these tests
/// pin the priority ladder (authRequired > disconnected > failed >
/// progress > informational), the preserved copy, and the streaming-phase
/// notice suppression that the old stacked implementation carried.
@MainActor
final class ConversationBannerPriorityTests: XCTestCase {

    private func select(
        phase: ConversationViewModel.Phase,
        integrityNotice: String? = nil,
        replayNotice: String? = nil,
        hydratedFromCache: Bool = false,
        historyLoadError: String? = nil,
        errorMessage: String? = nil
    ) -> ConversationBanner? {
        ConversationBannerSelector.select(
            phase: phase,
            integrityNotice: integrityNotice,
            replayNotice: replayNotice,
            hydratedFromCache: hydratedFromCache,
            historyLoadError: historyLoadError,
            errorMessage: errorMessage
        )
    }

    // MARK: - Priority ladder

    func testAuthRequiredOutranksEverything() {
        let banner = select(
            phase: .authRequired,
            integrityNotice: "integrity",
            replayNotice: "replay",
            historyLoadError: "history error",
            errorMessage: "auth exploded"
        )
        XCTAssertEqual(banner?.kind, .authRequired)
        XCTAssertEqual(banner?.text, "auth exploded")
    }

    func testDisconnectedOutranksFailedAndInformational() {
        let banner = select(
            phase: .disconnected,
            integrityNotice: "integrity",
            historyLoadError: "history error"
        )
        XCTAssertEqual(banner?.kind, .disconnected)
        XCTAssertEqual(banner?.text, ConversationBannerSelector.disconnectedText)
    }

    func testFailedPhaseShowsDetail() {
        let banner = select(phase: .failed("gateway exploded"))
        XCTAssertEqual(banner?.kind, .failed)
        XCTAssertEqual(banner?.text, "gateway exploded")
    }

    // MARK: - Progress states

    func testProgressStatesRenderTheirExactCopy() {
        XCTAssertEqual(select(phase: .idle)?.kind, .opening)
        XCTAssertEqual(select(phase: .idle)?.text, ConversationBannerSelector.openingText)
        XCTAssertEqual(select(phase: .opening)?.text, ConversationBannerSelector.openingText)
        XCTAssertEqual(select(phase: .connecting)?.text, ConversationBannerSelector.connectingText)
        XCTAssertEqual(select(phase: .reconnecting)?.text, ConversationBannerSelector.reconnectingText)
    }

    func testProgressStatesShowSpinner() {
        XCTAssertTrue(ConversationBannerKind.opening.showsSpinner)
        XCTAssertTrue(ConversationBannerKind.connecting.showsSpinner)
        XCTAssertTrue(ConversationBannerKind.reconnecting.showsSpinner)
        XCTAssertFalse(ConversationBannerKind.disconnected.showsSpinner)
        XCTAssertFalse(ConversationBannerKind.authRequired.showsSpinner)
        XCTAssertFalse(ConversationBannerKind.replay.showsSpinner)
    }

    // MARK: - Settled states (ready/streaming)

    func testReadyWithNoStateRendersNothing() {
        XCTAssertNil(select(phase: .ready))
        XCTAssertNil(select(phase: .streaming))
    }

    func testHistoryLoadErrorBeatsErrorMessage() {
        // H1 copy discipline: the authoritative fetch failure wins over a
        // stale generic error message.
        let banner = select(phase: .ready, historyLoadError: "history fetch failed", errorMessage: "old error")
        XCTAssertEqual(banner?.kind, .failed)
        XCTAssertEqual(banner?.text, "history fetch failed")
    }

    func testErrorMessageRendersAsFailed() {
        let banner = select(phase: .ready, errorMessage: "send failed")
        XCTAssertEqual(banner?.kind, .failed)
        XCTAssertEqual(banner?.text, "send failed")
    }

    func testNoticesHiddenWhileStreaming() {
        XCTAssertNil(select(phase: .streaming, integrityNotice: "integrity", replayNotice: "replay"))
    }

    func testNoticesRenderWhenReady() {
        XCTAssertEqual(select(phase: .ready, integrityNotice: "integrity")?.kind, .integrity)
        XCTAssertEqual(select(phase: .ready, replayNotice: "replay")?.kind, .replay)
        XCTAssertEqual(select(phase: .ready, integrityNotice: "i", replayNotice: "r")?.kind, .integrity,
                       "integrity outranks replay at the same band")
    }

    func testHydratedFromCacheNoticeRendersLowest() {
        XCTAssertEqual(select(phase: .ready, hydratedFromCache: true)?.kind, .info)
        XCTAssertEqual(
            select(phase: .ready, replayNotice: "replay", hydratedFromCache: true)?.kind,
            .replay,
            "replay notice outranks the cold-cache notice"
        )
        XCTAssertEqual(
            select(phase: .ready, hydratedFromCache: true)?.text,
            ConversationBannerSelector.hydratedFromCacheText
        )
    }

    // MARK: - Ordering contract

    func testPriorityOrdering() {
        XCTAssertLessThan(ConversationBannerPriority.informational, ConversationBannerPriority.progress)
        XCTAssertLessThan(ConversationBannerPriority.progress, ConversationBannerPriority.failed)
        XCTAssertLessThan(ConversationBannerPriority.failed, ConversationBannerPriority.disconnected)
        XCTAssertLessThan(ConversationBannerPriority.disconnected, ConversationBannerPriority.authRequired)
    }

    // MARK: - Actionable states carry their identifiers (source guard)

    func testActionableBannerIdentifiersPreserved() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Packages/FleetUI/Sources/FleetUI/ConversationView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("\"fleet.conversation.reconnect\""),
                      "Reconnect must keep its identifier")
        XCTAssertTrue(source.contains("\"fleet.conversation.reauthenticate\""),
                      "Re-authenticate must keep its identifier")
        XCTAssertTrue(source.contains("\"model.chip\""),
                      "the model chip must keep its identifier")
        XCTAssertTrue(source.contains("\"fleet.conversation.timeline.open\""),
                      "timeline.open must stay reachable")
        XCTAssertTrue(source.contains("\"fleet.conversation.timeline.latest\""),
                      "timeline.latest must stay reachable")
        XCTAssertFalse(source.contains("safeAreaInset(edge: .top"),
                       "the permanent transcript top inset must stay gone")
        XCTAssertTrue(source.contains(".navigationBarTitleDisplayMode(.inline)"),
                       "the conversation must use the inline navigation title")
        XCTAssertFalse(source.contains("Text(\"Conversation timeline\")"),
                       "the permanent Conversation timeline row must stay gone")
    }
}
