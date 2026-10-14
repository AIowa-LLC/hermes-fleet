import XCTest
import SwiftUI
import FleetUI
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence

/// First-run owner enrollment adoption behavior. All values are synthetic;
/// no live gateway, account, or device is required.
@MainActor
final class OnboardingPromptTests: XCTestCase {
    func testFirstRunViewsInitialize() {
        let environment = TestEnvironments.empty()
        XCTAssertNotNil(GatewayOnboardingView(environment: environment).body)
        XCTAssertNotNil(FirstRunSetupView(environment: environment).body)
    }

    func testAdoptionRegistersDeviceCredentialAndConnectsWithoutRegistryWrite() async throws {
        let counter = ConnectionCounter()
        let environment = TestEnvironments.empty(connectionCounter: counter)
        await environment.load()
        let (metadata, device) = enrollment()

        try await environment.adoptOwnerEnrollment(metadata: metadata, device: device)

        XCTAssertEqual(environment.hydrationPhase, .configured)
        XCTAssertEqual(environment.gateways.count, 1)
        XCTAssertEqual(environment.gateways[0].id, metadata.gatewayID)
        XCTAssertEqual(environment.gateways[0].endpoint, metadata.origin)
        XCTAssertEqual(environment.gateways[0].authConfiguration.strategy, .deviceCredential)
        XCTAssertTrue(environment.gateways[0].authConfiguration.credentialStored)
        let connectionCount = await counter.value
        XCTAssertEqual(connectionCount, 1, "adoption should connect the new gateway")
        let storedCredential = try await TestEnvironments.latestCredentials.loadCredential(for: metadata.gatewayID)
        XCTAssertNil(storedCredential,
                     "adoption must not duplicate the credential already saved by enrollment")
    }

    func testDuplicateGatewayIsRejectedBeforeChangingRegistry() async throws {
        let environment = TestEnvironments.seeded()
        await environment.load()
        let (metadata, device) = enrollment(
            gatewayID: GatewayID(rawValue: "workstation"),
            origin: URL(string: "https://gateway.example.invalid:8642")!)

        do {
            try await environment.adoptOwnerEnrollment(metadata: metadata, device: device)
            XCTFail("duplicate adoption must fail")
        } catch let error as GatewayRegistryError {
            XCTAssertEqual(error, .duplicate(metadata.gatewayID))
        }
        XCTAssertEqual(environment.gateways.count, 1)
        XCTAssertEqual(environment.gateways[0].displayName, "Workstation")
    }

    func testMismatchedEnrollmentIdentityIsRejectedBeforeRegistryMutation() async throws {
        let environment = TestEnvironments.empty()
        await environment.load()
        let (metadata, _) = enrollment()
        let mismatched = OwnerEnrolledDevice(
            gatewayID: GatewayID(rawValue: "other-server"),
            displayName: "Hermes Server",
            deviceID: "synthetic-device",
            scopes: ["fleet:operator"])

        do {
            try await environment.adoptOwnerEnrollment(metadata: metadata, device: mismatched)
            XCTFail("a mismatched gateway identity must fail closed")
        } catch let error as OwnerEnrollmentError {
            XCTAssertEqual(error, .malformedResponse)
        }
        XCTAssertTrue(environment.gateways.isEmpty)
    }

    func testPersistenceFailureLeavesNoRegisteredGatewayOrConnection() async throws {
        let counter = ConnectionCounter()
        let environment = TestEnvironments.empty(
            recordStore: FailingGatewayRecordStore(),
            connectionCounter: counter)
        await environment.load()
        let (metadata, device) = enrollment()

        do {
            try await environment.adoptOwnerEnrollment(metadata: metadata, device: device)
            XCTFail("failed gateway persistence must fail adoption")
        } catch {
            XCTAssertTrue(error is GatewayRegistryError)
        }
        XCTAssertTrue(environment.gateways.isEmpty)
        let connectionCount = await counter.value
        XCTAssertEqual(connectionCount, 0)
    }

    private func enrollment(
        gatewayID: GatewayID = GatewayID(rawValue: "onboarding-fixture"),
        origin: URL = URL(string: "https://onboarding.fixture.test")!
    ) -> (OwnerConnectionMetadata, OwnerEnrolledDevice) {
        let metadata = OwnerConnectionMetadata(
            gatewayID: gatewayID,
            displayName: "Hermes Server",
            origin: origin,
            scopes: ["fleet:operator"],
            enrollmentVersion: 1)
        let device = OwnerEnrolledDevice(
            gatewayID: gatewayID,
            displayName: "Hermes Server",
            deviceID: "synthetic-device",
            scopes: ["fleet:operator"])
        return (metadata, device)
    }
}

private actor ConnectionCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private struct FailingGatewayRecordStore: GatewayRecordStoring {
    func saveGatewayRecord(_ record: StoredGatewayRecord) async throws {
        throw GatewayRegistryError.recordStoreFailed("synthetic persistence failure")
    }
    func deleteGatewayRecord(id: GatewayID) async throws {}
    func loadGatewayRecords() async throws -> [StoredGatewayRecord] { [] }
}

@MainActor
private enum TestEnvironments {
    struct TestSessionList: SessionListProviding {
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    final class TestHealthAccumulator: ConnectionHealthAccumulating, @unchecked Sendable {
        func record(_ event: ConnectionHealthEvent, for gatewayID: GatewayID) async {}
        func snapshot() async -> [GatewayID: GatewayHealthStats] { [:] }
        func stats(for gatewayID: GatewayID) async -> GatewayHealthStats? { nil }
        func rehydrate(gatewayIDs: [GatewayID]) async {}
        func forget(gatewayID: GatewayID) async {}
    }

    struct TestRosterSession: GatewayRosterSession {
        let gatewayID: GatewayID
        var status: GatewayStatus { .offline }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws {}
        func disconnect() async {}
        func currentGateway() async -> FleetGateway { FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil) }
        func fetchProfiles() async throws -> [ProfileDescriptor] { [] }
        func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] { [] }
    }

    struct TestConnection: GatewayConnectivityProviding {
        let gatewayID: GatewayID
        let counter: ConnectionCounter?
        var status: GatewayStatus { .offline }
        func adoptedReady() async -> GatewayReadyAdoption? { nil }
        func connect() async throws { await counter?.increment() }
        func disconnect() async {}
        func currentGateway() async -> FleetGateway { FleetGateway(id: gatewayID, displayName: "stub", endpoint: nil) }
    }

    private(set) static var latestCredentials = InMemoryCredentialStore()

    static func make(
        seed: [GatewayRegistration],
        recordStore: (any GatewayRecordStoring)? = nil,
        connectionCounter: ConnectionCounter? = nil
    ) -> AppEnvironment {
        let credentialStore = InMemoryCredentialStore()
        latestCredentials = credentialStore
        let registry = GatewayRegistryService(
            credentials: credentialStore,
            connectionFactory: { gateway, _ in TestConnection(gatewayID: gateway.id, counter: connectionCounter) },
            recordStore: recordStore)
        return AppEnvironment(
            registry: registry,
            roster: FleetRosterService(
                registry: registry,
                credentials: credentialStore,
                sessionFactory: { gateway, _ in TestRosterSession(gatewayID: gateway.id) }),
            cache: try! SwiftDataCacheStore.makeInMemory(),
            sessionList: TestSessionList(),
            connectionFactory: { gateway, _ in TestConnection(gatewayID: gateway.id, counter: connectionCounter) },
            health: TestHealthAccumulator(),
            seedRegistrations: seed)
    }

    static func empty(
        recordStore: (any GatewayRecordStoring)? = nil,
        connectionCounter: ConnectionCounter? = nil
    ) -> AppEnvironment {
        make(seed: [], recordStore: recordStore, connectionCounter: connectionCounter)
    }

    static func seeded() -> AppEnvironment {
        make(seed: [GatewayRegistration(
            id: GatewayID(rawValue: "workstation"),
            displayName: "Workstation",
            endpoint: URL(string: "https://gateway.example.invalid:8642")!)])
    }
}
