import XCTest
import FleetCore
import FleetUI
@testable import HermesFleetApp

@MainActor
final class FleetConversationShortcutsTests: XCTestCase {
    func testConversationDeepLinkRoundTripsSourceQualifiedIdentity() {
        let route = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default"))
        let entity = FleetConversationShortcutEntity(
            id: "conv|workstation#default|session-42",
            route: route,
            sessionID: "session-42",
            canonical: true)

        let url = FleetConversationDeepLink.url(for: entity)
        let target = FleetConversationDeepLink.target(from: url)

        XCTAssertEqual(target?.route, route)
        XCTAssertEqual(target?.sessionID, "session-42")
        XCTAssertEqual(target?.canonical, true)
        XCTAssertFalse(url.absoluteString.contains("Private title"))
    }

    /// OCR review t_ba85b063: the picker renders the entry's own non-secret
    /// labels. A constant title made every saved conversation
    /// indistinguishable in the Shortcuts/Siri entity picker.
    func testConversationEntityRendersStoredDisplayLabels() {
        let route = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default"))
        let labelled = FleetConversationShortcutEntity(
            id: "conv|workstation#default|session-7",
            route: route,
            sessionID: "session-7",
            canonical: false,
            title: "Deploy review",
            subtitle: "workstation#default")
        XCTAssertEqual(labelled.displayRepresentation.title.key, "Deploy review")
        XCTAssertEqual(labelled.displayRepresentation.subtitle?.key, "workstation#default")

        // No stored labels (an old index row) keeps the honest generic copy.
        let unlabelled = FleetConversationShortcutEntity(
            id: "conv|workstation#default|session-8",
            route: route,
            sessionID: "session-8",
            canonical: true)
        XCTAssertEqual(unlabelled.displayRepresentation.title.key, "Fleet conversation")
        XCTAssertEqual(unlabelled.displayRepresentation.subtitle?.key, "Bot Chat")
    }

    func testShortcutQueryHidesConversationLabelsWhenAppLockIsEnabled() async throws {
        let indexURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("continue-index.json")
        defer { try? FileManager.default.removeItem(at: indexURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let route = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default"))
        FleetContinueIndexStore(url: indexURL).recordConversationOpen(
            route: route,
            sessionID: "session-privacy-check",
            canonical: false,
            title: "Private conversation title",
            subtitle: "Private gateway label")

        let lockedQuery = FleetConversationShortcutQuery(
            indexURL: indexURL,
            appLockIsEnabled: { true })
        let locked = try await lockedQuery.suggestedEntities()
        XCTAssertEqual(locked.count, 1)
        XCTAssertEqual(locked[0].displayRepresentation.title.key, "Fleet conversation")
        XCTAssertEqual(locked[0].displayRepresentation.subtitle?.key, "Saved conversation")
        XCTAssertFalse(locked[0].displayRepresentation.title.key.contains("Private"))
        XCTAssertFalse(locked[0].displayRepresentation.subtitle?.key.contains("Private") ?? false)
        let resolvedWhileLocked = try await lockedQuery.entities(for: [locked[0].id])
        XCTAssertEqual(resolvedWhileLocked.first?.displayRepresentation.title.key, "Fleet conversation")
        XCTAssertEqual(resolvedWhileLocked.first?.displayRepresentation.subtitle?.key, "Saved conversation")

        let unlockedQuery = FleetConversationShortcutQuery(
            indexURL: indexURL,
            appLockIsEnabled: { false })
        let unlocked = try await unlockedQuery.suggestedEntities()
        XCTAssertEqual(unlocked[0].displayRepresentation.title.key, "Private conversation title")
        XCTAssertEqual(unlocked[0].displayRepresentation.subtitle?.key, "Private gateway label")
    }

    func testConversationDeepLinkRejectsUnsafeOrWrongURLs() {
        XCTAssertNil(FleetConversationDeepLink.target(from: URL(string: "https://example.com")!))
        XCTAssertNil(FleetConversationDeepLink.target(from: URL(string: "hermes-fleet://conversation?gateway=bad%2Fgateway&profile=default&session=s1")!))
        XCTAssertNil(FleetConversationDeepLink.target(from: URL(string: "hermes-fleet://conversation?gateway=workstation&profile=default&session=../secret&canonical=0")!))
        XCTAssertNil(FleetConversationDeepLink.target(from: URL(string: "hermes-fleet://conversation?gateway=workstation&profile=default&session=s1&canonical=1&canonical=0")!))
    }
}
