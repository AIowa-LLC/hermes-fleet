import XCTest
@testable import FleetCore

final class ConversationPinningTests: XCTestCase {
    func testIndividualIdentityIncludesRouteAndSession() {
        let workstation = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default")
        )
        let laptop = Route(
            gatewayID: GatewayID(rawValue: "laptop"),
            profileSlug: ProfileSlug(rawValue: "default")
        )

        let first = FleetConversationIdentity.individual(route: workstation, sessionID: "same")
        let second = FleetConversationIdentity.individual(route: laptop, sessionID: "same")

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testGroupIdentityDoesNotUseDisplayNameOrAdvertisingGateway() {
        let first = FleetConversationIdentity.group(canonicalID: "room-42")
        let second = FleetConversationIdentity.group(canonicalID: "room-42")

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.id, "group:room-42")
    }

    func testUserDefaultsPinStoreRestoresPins() async throws {
        let suite = "ConversationPinningTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsConversationPinStore(suiteName: suite)
        let route = Route(
            gatewayID: GatewayID(rawValue: "workstation"),
            profileSlug: ProfileSlug(rawValue: "default")
        )
        let pin = FleetConversationPin(
            identity: .individual(route: route, sessionID: "s1"),
            title: "A long-lived chat",
            authoritativeGatewayID: route.gatewayID
        )

        try await store.savePins([pin])
        let restored = try await store.loadPins()

        XCTAssertEqual(restored, [pin])
    }

    func testInMemoryStoreKeepsCanonicalGroupPinAsOneItem() async throws {
        let store = InMemoryConversationPinStore()
        let first = FleetConversationPin(
            identity: .group(canonicalID: "room-42"),
            title: "Fleet Room",
            authoritativeGatewayID: GatewayID(rawValue: "workstation")
        )
        let second = FleetConversationPin(
            identity: .group(canonicalID: "room-42"),
            title: "Fleet Room",
            authoritativeGatewayID: GatewayID(rawValue: "laptop")
        )

        try await store.savePins([first])
        try await store.savePins([second])

        let pins = try await store.loadPins()
        XCTAssertEqual(pins.count, 1)
        XCTAssertEqual(pins.first?.identity, first.identity)
        XCTAssertEqual(pins.first?.authoritativeGatewayID?.rawValue, "laptop")
    }
}
