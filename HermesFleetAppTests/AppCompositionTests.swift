import XCTest
import FleetUI
import FleetCore
@testable import HermesFleetApp

/// Composition smoke tests: the app starts with a clean, inert fleet model.
@MainActor
final class AppCompositionTests: XCTestCase {
    func testAppTabModelCoversFiveOwningDomains() {
        // Build 41: the root shell exposes exactly the five plan-of-record
        // tabs, in order (Bots / Chats / Kanban / Fleet / Gateways).
        XCTAssertEqual(
            FleetTab.allCases.map(\.label),
            ["Bots", "Chats", "Kanban", "Fleet", "Gateways"],
            "the tab bar must match the five approved domains in order"
        )
    }

    func testBotsIsDefaultLaunchTab() {
        XCTAssertEqual(
            FleetNavigationState().selection,
            .bots,
            "Bots must be the normal launch tab (Build 41 navigation)")
    }

    func testEveryTabHasDistinctSymbolAndLabel() {
        XCTAssertEqual(Set(FleetTab.allCases.map(\.label)).count, FleetTab.allCases.count,
                       "tab labels must be distinct")
        XCTAssertEqual(Set(FleetTab.allCases.map(\.systemImage)).count, FleetTab.allCases.count,
                       "tab symbols must be distinct")
    }
}

// MARK: P0-5 — default environment selection (scripted fleet = simulator only)

extension AppCompositionTests {

    /// P0-5 regression: on the SIMULATOR the default environment must remain
    /// the scripted fleet (CI deterministic suites + local dev walkthrough).
    /// The device-Debug branch (production graph) cannot be unit-tested here
    /// — it is enforced by `#if DEBUG && targetEnvironment(simulator)` around
    /// FleetSimulator (the fake fleet cannot even COMPILE into a device
    /// build) and by the device-binary gate in the device build scripts (see scripts/u4_device.sh).
    @MainActor
    func testDefaultEnvironmentOnSimulatorIsScriptedFleet() async {
        let environment = FleetServiceGraph.makeDefaultEnvironment()
        await environment.load()
        let ids = environment.gateways.map(\.id.rawValue)
        XCTAssertTrue(
            ids.contains("workstation"),
            "simulator default environment must seed the scripted fleet (got: \(ids))"
        )
    }
}


extension AppCompositionTests {
    func testCanonicalAndOrdinarySessionsHaveDifferentOwners() {
        let route = Route(gatewayID: GatewayID(rawValue: "a"), profileSlug: ProfileSlug(rawValue: "default"))
        XCTAssertEqual(FleetScreen.conversation(route, sessionID: "same").owner, .chats)
        XCTAssertEqual(FleetScreen.conversation(route, sessionID: "same", canonical: true).owner, .bots)
    }

    func testSourceQualifiedNavigationPreservesIndependentStacksAndDeduplicates() {
        let a = Route(gatewayID: GatewayID(rawValue: "a"), profileSlug: ProfileSlug(rawValue: "default"))
        let b = Route(gatewayID: GatewayID(rawValue: "b"), profileSlug: ProfileSlug(rawValue: "default"))
        var state = FleetNavigationState()
        state.open(.botDetail(a))
        state.open(.botDetail(b))
        state.open(.projects(a.gatewayID, profile: a.profileSlug, focusPath: "src/App.swift"))
        XCTAssertEqual(state.selection, .gateways)
        XCTAssertEqual(state.paths[.bots], [.botDetail(a), .botDetail(b)])
        state.open(.botDetail(a))
        XCTAssertEqual(state.paths[.bots], [.botDetail(a)])
        XCTAssertEqual(state.paths[.gateways]?.count, 1)
    }

    func testNavigationRestoresExactScopeAndMissingTargetsWithoutSubstitution() throws {
        let id = GatewayID(rawValue: "removed-gateway")
        var state = FleetNavigationState()
        state.open(.gatewayKanban(id, board: "release"))
        state.open(.projects(id, profile: ProfileSlug(rawValue: "review"), focusPath: "src/File.swift"))
        let data = try JSONEncoder().encode(state)
        let restored = FleetNavigationState.restore(data)
        XCTAssertEqual(restored, state)
        XCTAssertEqual(restored.paths[.gateways]?.last?.gatewayID, id)
        XCTAssertEqual(FleetNavigationState.restore(Data("{}".utf8)), FleetNavigationState())
        XCTAssertEqual(FleetNavigationState.restore(Data("{\"version\":99}".utf8)), FleetNavigationState())
    }

    func testLegacyRootsResolveToOwningDomains() {
        let id = GatewayID(rawValue: "a")
        XCTAssertEqual(FleetNavigationState.legacyTab("home"), .fleet)
        XCTAssertEqual(FleetNavigationState.legacyTab("control"), .gateways)
        XCTAssertEqual(FleetNavigationState.legacyTab("workspace"), .gateways)
        // Build 41: the Kanban tab owns the Kanban experience.
        XCTAssertEqual(FleetScreen.kanban.owner, .kanban)
        XCTAssertEqual(FleetScreen.gatewayKanban(id).owner, .kanban)
    }
}


extension AppCompositionTests {
    func testCanonicalOpenEmitsBotsIntentFromEnvironment() async {
        let environment = FleetServiceGraph.makeDefaultEnvironment()
        await environment.load()
        let route = Route(gatewayID: GatewayID(rawValue: "workstation"), profileSlug: ProfileSlug(rawValue: "default"))
        environment.openBotChat(route: route, sessionID: "canonical-fixture")
        XCTAssertEqual(environment.pendingBotChatNavigation, .conversation(route, sessionID: "canonical-fixture", canonical: true))
        var state = FleetNavigationState()
        state.open(.conversation(route, sessionID: "ordinary"))
        if let target = environment.pendingBotChatNavigation { state.open(target) }
        XCTAssertEqual(state.selection, .bots)
        XCTAssertEqual(state.paths[.chats], [.conversation(route, sessionID: "ordinary")])
    }
}
