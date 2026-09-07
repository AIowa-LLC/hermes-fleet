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
            XCTAssertNotNil(pill.body, "StatusPill must init for \(status.rawValue)")
        }
        XCTAssertEqual(FleetStatus.allCases.count, 4, "exactly four pill states per the mock")
    }

    func testStatCardInit() {
        // V2 (Nous Direction A): icon/tint params removed — mono number tile
        // with uppercase micro-label.
        let stat = StatCard(
            value: "3",
            label: "Active Bots"
        )
        XCTAssertNotNil(stat.body)
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

    // MARK: - FleetStatus labels + colors (all four states)

    func testFleetStatusLabels() {
        XCTAssertEqual(FleetStatus.online.label, "Online")
        XCTAssertEqual(FleetStatus.idle.label, "Idle")
        XCTAssertEqual(FleetStatus.degraded.label, "Degraded")
        XCTAssertEqual(FleetStatus.offline.label, "Offline")
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
        assertSameColor(FleetStatus.idle.color, FleetTheme.statusIdle, "idle")
        assertSameColor(FleetStatus.degraded.color, FleetTheme.statusDegraded, "degraded")
        assertSameColor(FleetStatus.offline.color, FleetTheme.statusOffline, "offline")
    }

    // MARK: - GatewayStatus collapse (exhaustive: all 6 cases)

    func testFleetStatusFromGatewayStatusIsExhaustive() {
        XCTAssertEqual(FleetStatus(gatewayStatus: .online), .online)
        XCTAssertEqual(FleetStatus(gatewayStatus: .connecting), .idle)
        XCTAssertEqual(FleetStatus(gatewayStatus: .degraded), .degraded)
        XCTAssertEqual(FleetStatus(gatewayStatus: .authenticationRequired), .offline)
        XCTAssertEqual(FleetStatus(gatewayStatus: .offline), .offline)
        XCTAssertEqual(FleetStatus(gatewayStatus: .unsupported), .offline)
    }

    // MARK: - BotActivity collapse (exhaustive: all 8 cases)

    func testFleetStatusFromBotActivityIsExhaustive() {
        XCTAssertEqual(FleetStatus(activity: .working), .online)
        XCTAssertEqual(FleetStatus(activity: .thinking), .online)
        XCTAssertEqual(FleetStatus(activity: .usingTool), .online)
        XCTAssertEqual(FleetStatus(activity: .waiting), .idle)
        XCTAssertEqual(FleetStatus(activity: .idle), .idle)
        XCTAssertEqual(FleetStatus(activity: .needsAttention), .degraded)
        XCTAssertEqual(FleetStatus(activity: .offline), .offline)
        XCTAssertEqual(FleetStatus(activity: .unknown), .offline, "unknown never fabricates activity")
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
        XCTAssertEqual(FleetStatus(activity: .working, presence: .reachable), .online)
        XCTAssertEqual(FleetStatus(activity: .thinking, presence: .reachable), .online)
        XCTAssertEqual(FleetStatus(activity: .usingTool, presence: .reachable), .online)
        XCTAssertEqual(FleetStatus(activity: .waiting, presence: .reachable), .idle)
        XCTAssertEqual(FleetStatus(activity: .idle, presence: .reachable), .idle)
        XCTAssertEqual(FleetStatus(activity: .needsAttention, presence: .reachable), .degraded)
    }

    func testFleetStatusUnreachableOrUnknownPresenceIsOfflineRegardlessOfActivity() {
        for activity in [BotActivity.working, .thinking, .usingTool, .waiting, .idle, .needsAttention, .offline, .unknown] {
            XCTAssertEqual(FleetStatus(activity: activity, presence: .unreachable), .offline)
            XCTAssertEqual(FleetStatus(activity: activity, presence: .unknown), .offline)
        }
    }

    func testGatewayRunningBadgeInit() {
        // Badge renders (non-nil body) in both states; hidden-when-false is
        // the design (empty view) — init must not crash either way.
        XCTAssertNotNil(GatewayRunningBadge(isRunning: true).body)
        XCTAssertNotNil(GatewayRunningBadge(isRunning: false).body)
    }
}
