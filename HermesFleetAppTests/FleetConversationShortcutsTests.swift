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

    func testConversationDeepLinkRejectsUnsafeOrWrongURLs() {
        XCTAssertNil(FleetConversationDeepLink.target(from: URL(string: "https://example.com")!))
        XCTAssertNil(FleetConversationDeepLink.target(from: URL(string: "hermes-fleet://conversation?gateway=bad%2Fgateway&profile=default&session=s1")!))
        XCTAssertNil(FleetConversationDeepLink.target(from: URL(string: "hermes-fleet://conversation?gateway=workstation&profile=default&session=../secret&canonical=0")!))
        XCTAssertNil(FleetConversationDeepLink.target(from: URL(string: "hermes-fleet://conversation?gateway=workstation&profile=default&session=s1&canonical=1&canonical=0")!))
    }
}
