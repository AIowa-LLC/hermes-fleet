import XCTest
import SwiftUI
import UIKit
import FleetUI
import FleetCore

/// U2 (Gold Fleet reusable components): view-init + mapping unit tests.
///
/// Minimum bar from the plan: "view-init unit tests". These verify each
/// component instantiates with its public API, the FleetStatus mapping
/// covers every GatewayStatus/BotActivity case, and pill styling derives
/// from the FleetTheme tokens (drift-guarded in FleetThemeTests).
@MainActor
final class FleetComponentsTests: XCTestCase {

    // MARK: - View initialization (the four U2 components)

    func testFleetCardInit() {
        let card = FleetCard { Text("hello") }
        XCTAssertNotNil(card.body, "FleetCard must init with a ViewBuilder closure")
    }

    func testStatusPillInitForAllStates() {
        for status in FleetStatus.allCases {
            let pill = StatusPill(status: status)
            XCTAssertNotNil(pill.body, "StatusPill must init for \(status.label)")
        }
        XCTAssertEqual(FleetStatus.allCases.count, 10, "FOS-7 §7 vocabulary: 10 presentation states")
    }

    // MARK: - FOS-6 component family (SPEC §18)

    func testFleetListRowInit() {
        let row = FleetListRow { Text("Researcher") }
        XCTAssertNotNil(row.body, "FleetListRow must init with a ViewBuilder closure")
        let plain = FleetListRow(showsSeparator: false) { Text("x") }
        XCTAssertNotNil(plain.body, "separatorless init must be valid (List contexts)")
    }

    func testFleetGlanceStripInit() {
        let strip = FleetGlanceStrip(
            a: FleetGlanceFact(value: "2/3", label: "Connected", id: "a"),
            b: FleetGlanceFact(value: "12", label: "Known Bots", id: "b"),
            c: FleetGlanceFact(value: "—", label: "Active", id: "c"),
            d: FleetGlanceFact(value: "0", label: "Attention", id: "d")
        )
        XCTAssertNotNil(strip.body, "glance strip inits with four facts")
    }

    func testFleetNoticeBarInit() {
        let plain = FleetNoticeBar("Nothing scheduled.", id: "n1")
        XCTAssertNotNil(plain.body)
        let actionable = FleetNoticeBar(
            "Could not load.", tone: .error, id: "n2",
            actionTitle: "Retry", action: {})
        XCTAssertNotNil(actionable.body, "notice with action must init")
    }

    func testSectionHeaderInitWithAndWithoutAction() {
        XCTAssertNotNil(SectionHeader(title: "Gateways", viewAllAction: {}).body)
        XCTAssertNotNil(SectionHeader(title: "Activity").body, "nil action must be valid")
        XCTAssertNotNil(SectionHeader(title: "Bots", viewAllAction: nil, actionTitle: "Manage").body)
    }

    // MARK: - U5 shared avatar component

    func testBotAvatarInit() {
        // View-init for every initials shape (letters, multi-word, no letters).
        XCTAssertNotNil(BotAvatar(displayName: "Researcher").body)
        XCTAssertNotNil(BotAvatar(displayName: "MacBook Bot").body)
        XCTAssertNotNil(BotAvatar(displayName: "123").body, "no-letter names fall back to '?'")
    }

    // MARK: - FleetStatus labels + colors (FOS-7 §7 vocabulary)

    func testFleetStatusLabels() {
        XCTAssertEqual(FleetStatus.online.label, "Online")
        XCTAssertEqual(FleetStatus.executing(.working).label, "Working")
        XCTAssertEqual(FleetStatus.executing(.thinking).label, "Thinking")
        XCTAssertEqual(FleetStatus.executing(.usingTool).label, "Using tool")
        XCTAssertEqual(FleetStatus.waiting.label, "Waiting")
        XCTAssertEqual(FleetStatus.needsYou.label, "Needs you")
        XCTAssertEqual(FleetStatus.authRequired.label, "Sign in required")
        XCTAssertEqual(FleetStatus.degraded.label, "Degraded")
        XCTAssertEqual(FleetStatus.offline.label, "Offline")
        XCTAssertEqual(FleetStatus.unknown.label, "Unknown")
    }

    func testFleetStatusColorsUseThemeStatusTokens() {
        // Colors are not directly equatable; resolve via UIColor and compare
        // against the token's resolved values (tokens themselves are pinned
        // by FleetThemeTests.testPaletteHexValuesMatchSpecExactly).
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        func assertSameColor(_ a: Color, _ b: Color, _ name: String) {
            XCTAssertEqual(
                UIColor(a).resolvedColor(with: dark),
                UIColor(b).resolvedColor(with: dark),
                name
            )
        }
        assertSameColor(FleetStatus.online.color, FleetTheme.statusOnline, "online")
        assertSameColor(FleetStatus.executing(.working).color, FleetTheme.statusExecuting, "executing")
        assertSameColor(FleetStatus.needsYou.color, FleetTheme.statusNeedsIntervention, "needsYou")
        assertSameColor(FleetStatus.authRequired.color, FleetTheme.statusNeedsIntervention, "authRequired")
        assertSameColor(FleetStatus.degraded.color, FleetTheme.statusDegraded, "degraded")
        assertSameColor(FleetStatus.waiting.color, FleetTheme.textSecondary, "waiting (no alarm tint)")
        assertSameColor(FleetStatus.offline.color, FleetTheme.textSecondary, "offline (no alarm tint)")
        assertSameColor(FleetStatus.unknown.color, FleetTheme.textSecondary, "unknown (no alarm tint)")
    }

    // MARK: - GatewayStatus collapse (exhaustive: all 6 cases)

    func testFleetStatusFromGatewayStatusIsExhaustive() {
        XCTAssertEqual(FleetStatus(gatewayStatus: .online), .online)
        XCTAssertEqual(FleetStatus(gatewayStatus: .connecting), .waiting)
        XCTAssertEqual(FleetStatus(gatewayStatus: .degraded), .degraded)
        XCTAssertEqual(FleetStatus(gatewayStatus: .authenticationRequired), .authRequired)
        XCTAssertEqual(FleetStatus(gatewayStatus: .offline), .offline)
        XCTAssertEqual(FleetStatus(gatewayStatus: .unsupported), .degraded)
    }

    // MARK: - BotActivity collapse via presence (exhaustive: all 8 cases)

    func testFleetStatusFromBotActivityIsExhaustive() {
        XCTAssertEqual(FleetStatus(activity: .working, presence: .reachable), .executing(.working))
        XCTAssertEqual(FleetStatus(activity: .thinking, presence: .reachable), .executing(.thinking))
        XCTAssertEqual(FleetStatus(activity: .usingTool, presence: .reachable), .executing(.usingTool))
        XCTAssertEqual(FleetStatus(activity: .waiting, presence: .reachable), .waiting)
        XCTAssertEqual(FleetStatus(activity: .idle, presence: .reachable), .online)
        XCTAssertEqual(FleetStatus(activity: .needsAttention, presence: .reachable), .needsYou)
        XCTAssertEqual(FleetStatus(activity: .offline, presence: .unreachable), .offline)
        XCTAssertEqual(FleetStatus(activity: .unknown, presence: .unknown), .unknown, "unknown never fabricates activity or offline")
    }

    // MARK: - P0-7 presence-aware pill (multiplexer model)

    /// The fix for "bots show offline despite server ONLINE": an unobserved
    /// bot on a gateway that ANSWERED the roster refresh is Online — presence
    /// (owning gateway outcome) is the primary signal, activity only refines.
    func testFleetStatusReachablePresenceLiftsUnobservedActivityToOnline() {
        XCTAssertEqual(FleetStatus(activity: .unknown, presence: .reachable), .online)
        XCTAssertEqual(FleetStatus(activity: .offline, presence: .reachable), .online)
    }

    func testFleetStatusReachablePresenceRefinesWithRealActivity() {
        XCTAssertEqual(FleetStatus(activity: .working, presence: .reachable), .executing(.working))
        XCTAssertEqual(FleetStatus(activity: .thinking, presence: .reachable), .executing(.thinking))
        XCTAssertEqual(FleetStatus(activity: .usingTool, presence: .reachable), .executing(.usingTool))
        XCTAssertEqual(FleetStatus(activity: .waiting, presence: .reachable), .waiting)
        XCTAssertEqual(FleetStatus(activity: .idle, presence: .reachable), .online)
        XCTAssertEqual(FleetStatus(activity: .needsAttention, presence: .reachable), .needsYou)
    }

    func testFleetStatusUnreachableOrUnknownPresence() {
        for activity in [BotActivity.working, .thinking, .usingTool, .waiting, .idle, .needsAttention, .offline, .unknown] {
            XCTAssertEqual(FleetStatus(activity: activity, presence: .unreachable), .offline)
        }
        // Presence-unknown never claims idle/offline — "Unknown" (SPEC §7).
        for activity in [BotActivity.working, .waiting, .idle, .unknown] {
            XCTAssertEqual(FleetStatus(activity: activity, presence: .unknown), .unknown)
        }
    }

    func testGatewayRunningBadgeInit() {
        // Badge renders (non-nil body) in both states; hidden-when-false is
        // the design (empty view) — init must not crash either way.
        XCTAssertNotNil(GatewayRunningBadge(isRunning: true).body)
        XCTAssertNotNil(GatewayRunningBadge(isRunning: false).body)
    }
}
