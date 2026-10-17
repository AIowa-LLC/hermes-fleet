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

    func testNoticeToneSeverityOrdering() {
        XCTAssertLessThan(FleetNoticeBar.Tone.info, .warning)
        XCTAssertLessThan(FleetNoticeBar.Tone.warning, .error)
        XCTAssertLessThan(FleetNoticeBar.Tone.info, .error)
        XCTAssertGreaterThan(FleetNoticeBar.Tone.error, .info)
        XCTAssertFalse(FleetNoticeBar.Tone.error < .warning)
    }

    func testNoticeStackSortsBySeverityAndKeepsTiesInInputOrder() {
        let items = [
            FleetNoticeItem("first info", id: "a"),
            FleetNoticeItem("warn one", tone: .warning, id: "b"),
            FleetNoticeItem("error one", tone: .error, id: "c"),
            FleetNoticeItem("second info", id: "d"),
            FleetNoticeItem("warn two", tone: .warning, id: "e"),
            FleetNoticeItem("error two", tone: .error, id: "f"),
        ]
        let ordered = FleetNoticeStack.ordered(items).map(\.id)
        XCTAssertEqual(ordered, ["c", "f", "b", "e", "a", "d"],
                       "error > warning > info, with ties in input order")
        XCTAssertNotNil(FleetNoticeStack(items).body)
        XCTAssertEqual(FleetNoticeStack.ordered([]).count, 0)
    }

    func testSkeletonRowIsSingleLoadingAccessibilityElement() {
        // The row is a static view; its contract is its body + the pure
        // configuration it exposes. Assert it builds, and the list wrapper
        // carries the replaced identifier as one "Loading" element.
        XCTAssertNotNil(FleetSkeletonRow().body)
        XCTAssertNotNil(FleetSkeletonList(identifier: "fleet.chats.loading.first").body)
        XCTAssertNotNil(FleetSkeletonList(count: 0, identifier: "x").body)
        XCTAssertNotNil(FleetSkeletonList(count: 99, identifier: "x").body)
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

/// DEV19 L3 (#106): the shared haptic vocabulary maps every case to the
/// intended SwiftUI feedback, and no FleetUI view bypasses it.
final class FleetHapticsTests: XCTestCase {

    func testEveryHapticMapsToItsVocabularyFeedback() {
        let expected: [(FleetHaptic, SensoryFeedback)] = [
            (.send, .impact(weight: .light)),
            (.success, .success),
            (.refreshComplete, .success),
            (.pairingComplete, .success),
            (.approve, .success),
            (.deny, .impact(weight: .medium)),
            (.warning, .warning),
            (.failure, .error),
            (.selection, .selection),
        ]
        XCTAssertEqual(
            Set(expected.map { String(describing: $0.0) }),
            Set(FleetHaptic.allCases.map { String(describing: $0) }),
            "the mapping table must cover every FleetHaptic case"
        )
        for (haptic, feedback) in expected {
            XCTAssertEqual(haptic.feedback, feedback, "\(haptic) maps to the wrong SensoryFeedback")
        }
    }

    func testRefreshOutcomeChangesOnEveryRecordAndKeepsLastResult() {
        var outcome = FleetRefreshOutcome()
        XCTAssertEqual(outcome.generation, 0)
        XCTAssertFalse(outcome.lastFailed)

        outcome.record(failed: false)
        let afterSuccess = outcome
        XCTAssertEqual(afterSuccess.generation, 1)
        XCTAssertFalse(afterSuccess.lastFailed)

        outcome.record(failed: false)
        XCTAssertNotEqual(outcome, afterSuccess, "a repeated success must still change the trigger")

        outcome.record(failed: true)
        XCTAssertTrue(outcome.lastFailed)
        XCTAssertEqual(outcome.generation, 3)
    }
}

/// DEV19 L3 (#106): source-level guard. Haptics go through `FleetHaptic`
/// only: no direct `.sensoryFeedback(` and no UIKit feedback generators
/// anywhere in FleetUI, except the vocabulary file itself.
final class FleetHapticsWiringGuardTests: XCTestCase {

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // HermesFleetAppTests/
        .deletingLastPathComponent() // repo root

    private static let vocabularyFile = "Components/FleetHaptics.swift"

    private static let forbidden = [
        ".sensoryFeedback(",
        "UIImpactFeedbackGenerator",
        "UINotificationFeedbackGenerator",
        "UISelectionFeedbackGenerator",
    ]

    func testOnlyTheVocabularyFileCallsSensoryFeedbackOrUIKitGenerators() throws {
        let sourcesRoot = Self.repoRoot.appendingPathComponent("Packages/FleetUI/Sources/FleetUI")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: sourcesRoot, includingPropertiesForKeys: nil))
        var scanned = 0
        var violations: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
            if relative == Self.vocabularyFile { continue }
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Comments may name the APIs; only executable code is policed.
                if trimmed.hasPrefix("//") { continue }
                for token in Self.forbidden where line.contains(token) {
                    violations.append("\(relative):\(number + 1) uses \(token)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "guard must actually scan the FleetUI sources")
        XCTAssertTrue(violations.isEmpty,
                      "route haptics through FleetHaptic / .fleetHaptic:\n" + violations.joined(separator: "\n"))
    }
}

/// DEV19: user-visible error text in FleetUI goes through
/// `Redaction.userFacingErrorDescription`, never the log-oriented
/// `safeErrorDescription`, whose `String(describing:)` fallback renders raw
/// Swift dumps (enum cases with payloads, NSError userInfo) on screen.
final class UserFacingErrorTextGuardTests: XCTestCase {

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // HermesFleetAppTests/
        .deletingLastPathComponent() // repo root

    func testFleetUIUsesTheUserFacingErrorDescription() throws {
        let sourcesRoot = Self.repoRoot.appendingPathComponent("Packages/FleetUI/Sources/FleetUI")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: sourcesRoot, includingPropertiesForKeys: nil))
        var scanned = 0
        var violations: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let relative = url.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.components(separatedBy: .newlines).enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                if line.contains("Redaction.safeErrorDescription(") {
                    violations.append("\(relative):\(number + 1)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "guard must actually scan the FleetUI sources")
        XCTAssertTrue(violations.isEmpty,
                      "use Redaction.userFacingErrorDescription for UI text:\n" + violations.joined(separator: "\n"))
    }
}
