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
        let stat = StatCard(
            icon: "cpu",
            tint: FleetTheme.accentMagenta,
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
}
