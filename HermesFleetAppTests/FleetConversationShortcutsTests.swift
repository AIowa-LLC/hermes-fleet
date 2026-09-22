import XCTest
import FleetCore
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

    func testConversationDeepLinkRejectsUnsafeOrWrongURLs() {
        XCTAssertNil(FleetConversationDeepLink.target(from: URL(string: "https://example.com")!))
        XCTAssertNil(FleetConversationDeepLink.target(from: URL(string: "hermes-fleet://conversation?gateway=bad%2Fgateway&profile=default&session=s1")!))
        XCTAssertNil(FleetConversationDeepLink.target(from: URL(string: "hermes-fleet://conversation?gateway=workstation&profile=default&session=../secret&canonical=0")!))
        XCTAssertNil(FleetConversationDeepLink.target(from: URL(string: "hermes-fleet://conversation?gateway=workstation&profile=default&session=s1&canonical=1&canonical=0")!))
    }
}
