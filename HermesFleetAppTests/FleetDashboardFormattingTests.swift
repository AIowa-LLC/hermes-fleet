import XCTest
import FleetUI
import FleetCore

/// U4 (Gold Fleet) — Home dashboard formatting + composition unit tests.
///
/// Pure presentation logic (no UI host needed): initials, relative time,
/// last-active honesty, connected fraction, fleet connectivity classes, and
/// the Recent Activity timeline derivation from real `GatewayHealthStats`.
final class FleetDashboardFormattingTests: XCTestCase {

    // MARK: Avatars

    func testAvatarInitialsFromNames() {
        XCTAssertEqual(FleetDashboardFormatting.avatarInitials(from: "Researcher"), "R")
        XCTAssertEqual(FleetDashboardFormatting.avatarInitials(from: "MacBook Bot"), "MB")
        XCTAssertEqual(FleetDashboardFormatting.avatarInitials(from: "arch-lab-primary"), "AL")
    }

    func testAvatarInitialsNeverEmpty() {
        // A name with no letters must still render a stable avatar square.
        XCTAssertEqual(FleetDashboardFormatting.avatarInitials(from: ""), "?")
        XCTAssertEqual(FleetDashboardFormatting.avatarInitials(from: "123 456"), "?")
    }

    // MARK: Relative time

    func testRelativeTimeBuckets() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ secondsAgo: Double) -> Date { now.addingTimeInterval(-secondsAgo) }
        XCTAssertEqual(FleetDashboardFormatting.relativeTime(from: at(5), since: now), "now")
        XCTAssertEqual(FleetDashboardFormatting.relativeTime(from: at(90), since: now), "1m ago")
        XCTAssertEqual(FleetDashboardFormatting.relativeTime(from: at(3 * 3600), since: now), "3h ago")
        XCTAssertEqual(FleetDashboardFormatting.relativeTime(from: at(2 * 86_400), since: now), "2d ago")
    }

    func testRelativeTimeClockSkewGuard() {
        // A future date must not render a negative interval.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(
            FleetDashboardFormatting.relativeTime(from: now.addingTimeInterval(60), since: now),
            "now"
        )
    }

    // MARK: Last active (real data only)

    private func bot(lastSession: SessionSummary?) -> FleetBot {
        FleetBot(
            route: Route(gatewayID: GatewayID(rawValue: "workstation"), profileSlug: ProfileSlug(rawValue: "default")),
            displayName: "Default",
            latestSession: lastSession
        )
    }

    func testLastActiveLabelFromRealSession() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bot = bot(lastSession: SessionSummary(
            id: "s1", title: "Fleet setup", startedAt: now.timeIntervalSince1970 - 300
        ))
        XCTAssertEqual(FleetDashboardFormatting.lastActiveLabel(bot: bot, now: now), "5m ago")
    }

    func testLastActiveLabelHonestWhenNoSession() {
        // No session knowledge → honest "No sessions yet", never a fabricated uptime.
        XCTAssertEqual(FleetDashboardFormatting.lastActiveLabel(bot: bot(lastSession: nil)), "No sessions yet")
        let zero = bot(lastSession: SessionSummary(id: "s0", title: "t", startedAt: 0))
        XCTAssertEqual(FleetDashboardFormatting.lastActiveLabel(bot: zero), "No sessions yet")
    }

    // MARK: Connected fraction

    private func gateway(_ raw: String) -> FleetGateway {
        FleetGateway(
            id: GatewayID(rawValue: raw),
            displayName: raw,
            endpoint: URL(string: "http://127.0.0.1:8000")
        )
    }

    func testConnectedFraction() {
        let fleet = [gateway("a"), gateway("b"), gateway("c")]
        let text = FleetDashboardFormatting.connectedFraction(gateways: fleet) { $0.id.rawValue == "a" }
        XCTAssertEqual(text, "1/3")
    }

    func testConnectedFractionEmptyFleetRendersDash() {
        XCTAssertEqual(
            FleetDashboardFormatting.connectedFraction(gateways: []) { _ in true },
            "—",
            "0/0 is not a fraction; an empty fleet renders an honest dash"
        )
    }

    // MARK: Fleet connectivity

    func testFleetConnectivityClasses() {
        let fleet = [gateway("a"), gateway("b")]
        XCTAssertEqual(
            FleetDashboardFormatting.connectivity(gateways: []) { _ in nil },
            .empty
        )
        XCTAssertEqual(
            FleetDashboardFormatting.connectivity(gateways: fleet) { _ in nil },
            .offline
        )
        XCTAssertEqual(
            FleetDashboardFormatting.connectivity(gateways: fleet) {
                $0.id.rawValue == "a" ? .connecting : nil
            },
            .connecting
        )
        XCTAssertEqual(
            FleetDashboardFormatting.connectivity(gateways: fleet) {
                $0.id.rawValue == "b" ? .connected : nil
            },
            .online(connected: 1, total: 2)
        )
    }

    // MARK: Recent Activity timeline (real H2 stats only)

    func testActivityEntriesFromRealStats() {
        let now = Date()
        var stats: [GatewayID: GatewayHealthStats] = [
            GatewayID(rawValue: "gw"): GatewayHealthStats(
                currentState: .online,
                connectedMilliseconds: 11_520_000, // 3h 12m
                disconnectedMilliseconds: 0,
                reconnectCount: 2,
                lastDisconnectReason: "transport closed",
                lastDisconnectAt: now.addingTimeInterval(-600),
                lastPingRTTMilliseconds: 42,
                pingSampleCount: 3
            )
        ]
        var entries = FleetDashboardFormatting.activityEntries(gateways: [gateway("gw")], stats: stats)
        XCTAssertEqual(entries.count, 3, "reconnects + last-disconnect + connected-time")
        // Newest first: the only timestamped entry leads.
        XCTAssertEqual(entries.first?.id, "gw#last-disconnect")
        XCTAssertTrue(entries.contains { $0.text.contains("reconnected 2×") })
        XCTAssertTrue(entries.contains { $0.text.contains("disconnected — transport closed") })
        XCTAssertTrue(entries.contains { $0.text.contains("connected 3h 12m") })

        // A never-observed gateway contributes nothing (no zeroed-stat noise).
        stats[GatewayID(rawValue: "gw")] = GatewayHealthStats()
        entries = FleetDashboardFormatting.activityEntries(gateways: [gateway("gw")], stats: stats)
        XCTAssertTrue(entries.isEmpty, "a zeroed stats block is 'never observed', not 0 events")
    }

    func testActivityEntriesEmptyFleetIsEmpty() {
        XCTAssertTrue(
            FleetDashboardFormatting.activityEntries(gateways: [], stats: [:]).isEmpty
        )
    }

    // MARK: Duration

    func testDurationLabel() {
        XCTAssertEqual(FleetDashboardFormatting.durationLabel(milliseconds: 45 * 60_000), "45m")
        XCTAssertEqual(FleetDashboardFormatting.durationLabel(milliseconds: 3 * 3_600_000 + 12 * 60_000), "3h 12m")
        XCTAssertEqual(FleetDashboardFormatting.durationLabel(milliseconds: 26 * 3_600_000), "1d 2h")
    }
}
