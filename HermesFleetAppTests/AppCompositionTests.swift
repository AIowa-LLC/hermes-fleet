import XCTest
import UIKit
import FleetUI
import FleetCore
@testable import HermesFleetApp

/// Composition smoke tests: the app starts with a clean, inert fleet model.
@MainActor
final class AppCompositionTests: XCTestCase {
    func testAppTabModelCoversAllOwningDomains() {
        // Build 43: Bots / Chats / Kanban / Fleet / Settings. ADR-0011:
        // About is a first-class tab directly after Settings (identity,
        // version, legal, support).
        XCTAssertEqual(
            FleetTab.allCases.map(\.label),
            ["Bots", "Chats", "Groups", "Scheduled", "Kanban", "Fleet", "Settings", "About"],
            "the tab bar must match the approved domains in order (Scheduled sits between Chats and Kanban; About follows Settings)"
        )
    }

    /// QA round-3: every tab's SF Symbol must be a REAL symbol — a bad name
    /// renders a silent blank icon (build 49's `clock.badge.circle` ghost).
    /// ChatGPT-style accent picker: every one of the 8 curated accents maps
    /// to a palette the FleetThemeController's invisible-pair guard ACCEPTS
    /// (they apply cleanly over the Fleet-default backgrounds).
    func testShellChromeInkAndMenuGlyphGuards() throws {
        // Dogfood r3 (blank menu glyph + themed search icon on build 57):
        // pin the shell chrome contracts at the source level.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Packages/FleetUI/Sources/FleetUI/FleetTabView.swift"),
            encoding: .utf8)
        // `equals` is NOT a real SF Symbol (verified against CoreGlyphs
        // 2026-09-19) — Image(systemName:) renders BLANK. The menu glyph is
        // custom-drawn capsule bars; the retired name may not return.
        XCTAssertFalse(source.contains("systemName: \"equals\""),
                      "the menu glyph must stay custom-drawn — 'equals' renders blank")
        XCTAssertTrue(source.contains("Capsule().fill(Color.primary)"),
                      "the menu glyph must be the two custom capsule bars")
        // The search (Command Center) icon's neutral ink must be INSIDE the
        // label (on the Image); a Button-level style loses to the root tint.
        // Dogfood r4: search is DRAWER-ONLY. The root toolbar block must NOT
        // carry the retired button; the drawer hosts the magnifyingglass
        // circle (fleet.drawer.search) and the menu button carries the
        // unread badge aggregate.
        let toolbarStart = source.range(of: "private var rootShellToolbar")
        let toolbarEnd = source.range(of: "private var destinationShellToolbar")
        if let s = toolbarStart, let e = toolbarEnd, s.lowerBound < e.lowerBound {
            let block = String(source[s.lowerBound..<e.lowerBound])
            XCTAssertFalse(block.contains("fleet.command-center.open"),
                          "the toolbar search button is retired (drawer-only, r4)")
            XCTAssertFalse(block.contains("systemName: \"magnifyingglass\""),
                          "no search glyph may render in the root toolbar")
        } else {
            XCTFail("rootShellToolbar block not found for the chrome guard")
        }
    }

    func testAccentPickerPalettesAllApply() {
        for accent in FleetAccent.allCases {
            let palette = accent.palette
            XCTAssertFalse(palette.hasInvisiblePair,
                           "\(accent.label) must not be an invisible pair")
            XCTAssertNotNil(try? JSONEncoder().encode(palette),
                           "\(accent.label) palette must be encodable")
        }
        // The matching() reverse lookup finds each accent from its palette.
        for accent in FleetAccent.allCases {
            XCTAssertEqual(FleetAccent.matching(active: accent.palette), accent,
                           "matching() must round-trip \(accent.label)")
        }
    }

    func testEveryTabSystemImageResolvesToRealSFSymbol() {
        for tab in FleetTab.allCases {
            XCTAssertNotNil(UIImage(systemName: tab.systemImage),
                            "\(tab.label)'s symbol '\(tab.systemImage)' must resolve")
        }
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
        // Build 43: gateway-resource screens are owned by Fleet.
        XCTAssertEqual(state.selection, .fleet)
        XCTAssertEqual(state.paths[.bots], [.botDetail(a), .botDetail(b)])
        state.open(.botDetail(a))
        XCTAssertEqual(state.paths[.bots], [.botDetail(a)])
        XCTAssertEqual(state.paths[.fleet]?.count, 1)
    }

    func testNavigationRestoresExactScopeAndMissingTargetsWithoutSubstitution() throws {
        let id = GatewayID(rawValue: "removed-gateway")
        var state = FleetNavigationState()
        state.open(.gatewayKanban(id, board: "release"))
        state.open(.projects(id, profile: ProfileSlug(rawValue: "review"), focusPath: "src/File.swift"))
        let data = try JSONEncoder().encode(state)
        let restored = FleetNavigationState.restore(data)
        XCTAssertEqual(restored, state)
        // Build 43: those destinations ride the Fleet stack now.
        XCTAssertEqual(restored.paths[.fleet]?.last?.gatewayID, id)
        XCTAssertEqual(FleetNavigationState.restore(Data("{}".utf8)), FleetNavigationState())
        XCTAssertEqual(FleetNavigationState.restore(Data("{\"version\":99}".utf8)), FleetNavigationState())
    }

    func testLegacyRootsResolveToOwningDomains() {
        let id = GatewayID(rawValue: "a")
        XCTAssertEqual(FleetNavigationState.legacyTab("home"), .fleet)
        // Build 43: legacy gateway roots land on Fleet (gateway management
        // moved under Fleet); settings resolves to the Settings tab.
        XCTAssertEqual(FleetNavigationState.legacyTab("control"), .fleet)
        XCTAssertEqual(FleetNavigationState.legacyTab("workspace"), .fleet)
        XCTAssertEqual(FleetNavigationState.legacyTab("gateways"), .fleet)
        XCTAssertEqual(FleetNavigationState.legacyTab("settings"), .settings)
        // ADR-0011: the About tab resolves by its raw name.
        XCTAssertEqual(FleetNavigationState.legacyTab("about"), .about)
        XCTAssertEqual(FleetScreen.settingsSecurity.owner, .settings)
        XCTAssertEqual(FleetScreen.settingsData.owner, .settings)
        // Build 41: the Kanban tab owns the Kanban experience.
        XCTAssertEqual(FleetScreen.kanban.owner, .kanban)
        XCTAssertEqual(FleetScreen.gatewayKanban(id).owner, .kanban)
        // Build 43: gateway-management screens are owned by Fleet.
        XCTAssertEqual(FleetScreen.gateways.owner, .fleet)
        XCTAssertEqual(FleetScreen.gatewayDetail(id).owner, .fleet)
        XCTAssertEqual(FleetScreen.gatewayConnection(id).owner, .fleet)
        XCTAssertEqual(FleetScreen.gatewayHealth(id).owner, .fleet)
        XCTAssertEqual(FleetScreen.cron(id).owner, .fleet)
        XCTAssertEqual(FleetScreen.skills(id).owner, .fleet)
        XCTAssertEqual(FleetScreen.memoryGraph(id).owner, .fleet)
        XCTAssertEqual(FleetScreen.projects(id).owner, .fleet)
        XCTAssertEqual(FleetScreen.health.owner, .fleet)
    }

    /// Build 43 legacy restore: a persisted Build ≤42 navigation state can
    /// carry the retired `gateways` tab as selection and as a paths entry.
    /// Decoding must NOT discard the rest of the state — selection maps to
    /// Fleet and the gateway screens are appended to Fleet's stack. The
    /// legacy payloads are assembled from REAL encoders (screen fragments
    /// encoded by JSONEncoder, paths assembled in Swift's actual wire shape:
    /// an UNKEYED alternating key/value array) so the fixture cannot drift
    /// from the format.
    func testLegacyGatewaysTabRestoreMapsToFleetWithoutDiscardingState() throws {
        func legacyJSON(selection: String, fleet: [FleetScreen], gateways: [FleetScreen]) throws -> Data {
            let fleetFrag = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fleet))
            let gatewaysFrag = try JSONSerialization.jsonObject(with: JSONEncoder().encode(gateways))
            // [FleetTab: [FleetScreen]] encodes as ["fleet",[…],"gateways",[…]].
            let paths: [Any] = ["fleet", fleetFrag, "gateways", gatewaysFrag]
            return try JSONSerialization.data(withJSONObject: [
                "version": 1,
                "selection": selection,
                "paths": paths,
            ] as [String: Any])
        }

        let restored = FleetNavigationState.restore(try legacyJSON(
            selection: "gateways", fleet: [], gateways: [.health]))
        XCTAssertEqual(restored.selection, .fleet,
                       "a persisted gateways selection must restore onto Fleet")
        XCTAssertEqual(restored.paths[.fleet], [.health],
                       "the retired tab's stack must survive on the Fleet stack")
        XCTAssertTrue(restored.paths[.bots]?.isEmpty ?? true)

        // A FLEET path and a legacy gateways path both present: Fleet's own
        // path stays first, the gateway screens append after it.
        let restoredBoth = FleetNavigationState.restore(try legacyJSON(
            selection: "gateways", fleet: [.activity], gateways: [.health]))
        XCTAssertEqual(restoredBoth.paths[.fleet], [.activity, .health])

        // Unknown selection values fall back to the launch tab without
        // discarding the rest of the state. (Wire shape note: the paths
        // value is an unkeyed array of alternating key,value PAIRS —
        // ["bots",[…],"chats",[…]] — no colons.)
        let json2 = """
        {"version":1,"selection":"made-up",
         "paths":["bots",[{"roster":{}}],"chats",[],"kanban",[],"fleet",[]]}
        """
        let restored2 = FleetNavigationState.restore(Data(json2.utf8))
        XCTAssertEqual(restored2.selection, .bots)
        XCTAssertEqual(restored2.paths[.bots], [.roster])
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
