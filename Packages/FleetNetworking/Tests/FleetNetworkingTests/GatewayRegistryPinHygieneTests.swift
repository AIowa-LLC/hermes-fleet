import XCTest
import Foundation
import FleetCore
@testable import FleetNetworking

/// T3 — gateway removal retires the TLS pin with the credential (no orphaned
/// trust material for a removed peer), and pin-delete failures surface
/// (mirroring the P1-8 credential-cleanup contract).
final class GatewayRegistryPinHygieneTests: XCTestCase {

    private func makeRegistry(
        credentials: any CredentialStoring = EmptyCredentialStore(),
        pins: any TLSPinStoring = InMemoryPinStore(),
        enrollmentCleanup: (any GatewayEnrollmentCleanupProviding)? = nil
    ) -> GatewayRegistryService {
        GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { _, _ in
                UnconnectableConnection()
            },
            recordStore: nil,
            pinStore: pins,
            enrollmentCleanup: enrollmentCleanup
        )
    }

    private func registration(id: String = "workstation") -> GatewayRegistration {
        GatewayRegistration(
            id: GatewayID(rawValue: id),
            displayName: "MacBook",
            endpoint: URL(string: "https://gateway.example.invalid:9120")!
        )
    }

    func testRemoveGatewayDeletesStoredPin() async throws {
        let pins = InMemoryPinStore()
        let registry = makeRegistry(pins: pins)
        let gateway = try await registry.addGateway(registration())

        guard let pin = SPKIFingerprint(base64: "u7z1yV0LbgXWZmh2PmXVvUPXrlLof3S2bEpTQpFjOxY=") else {
            return XCTFail("fixture pin must parse")
        }
        try await pins.savePin(pin, for: gateway.id)
        let before = try await pins.loadPin(for: gateway.id)
        XCTAssertNotNil(before)

        try await registry.removeGateway(gateway.id)

        let after = try await pins.loadPin(for: gateway.id)
        XCTAssertNil(after, "removing a gateway must retire its TLS pin")
    }

    /// #210: removal is local; a pin-store failure is logged, not surfaced.
    func testPinDeleteFailureDoesNotBlockRemoval() async throws {
        let pins = FailingDeletePinStore()
        let registry = makeRegistry(pins: pins)
        let gateway = try await registry.addGateway(registration())

        try await registry.removeGateway(gateway.id)

        let remaining = await registry.gateway(for: gateway.id)
        XCTAssertNil(remaining)
    }

    func testEditEndpointDoesNotClearPin() async throws {
        // The pin identifies the gateway's KEY, not its address — a host/port
        // edit (e.g. LAN → tailnet IP move) must keep the pinned trust.
        let pins = InMemoryPinStore()
        let registry = makeRegistry(pins: pins)
        let gateway = try await registry.addGateway(registration())

        guard let pin = SPKIFingerprint(base64: "u7z1yV0LbgXWZmh2PmXVvUPXrlLof3S2bEpTQpFjOxY=") else {
            return XCTFail("fixture pin must parse")
        }
        try await pins.savePin(pin, for: gateway.id)

        _ = try await registry.updateGateway(
            gateway.id,
            edits: GatewayEdit(
                displayName: nil,
                endpoint: URL(string: "https://gateway.example.invalid:9443")!,
                authConfiguration: nil))

        let after = try await pins.loadPin(for: gateway.id)
        XCTAssertNotNil(after, "an endpoint edit must not clear the pin")
    }

    func testRemovalRunsEnrollmentCleanupBeforeDeletingGateway() async throws {
        let cleanup = RecordingEnrollmentCleanup()
        let registry = makeRegistry(enrollmentCleanup: cleanup)
        let gateway = try await registry.addGateway(registration())

        try await registry.removeGateway(gateway.id)

        let removedIDs = await cleanup.removedIDs
        let remaining = await registry.gateway(for: gateway.id)
        XCTAssertEqual(removedIDs, [gateway.id])
        XCTAssertNil(remaining)
    }

    /// #210: an enrollment-cleanup failure (formerly surfaced as "credential
    /// store failed: Secure enrollment could not be prepared") never blocks
    /// removal of the local entry.
    func testEnrollmentCleanupFailureDoesNotBlockRemoval() async throws {
        let cleanup = RecordingEnrollmentCleanup(fail: true)
        let registry = makeRegistry(enrollmentCleanup: cleanup)
        let gateway = try await registry.addGateway(registration())

        try await registry.removeGateway(gateway.id)

        let removedIDs = await cleanup.removedIDs
        let remaining = await registry.gateway(for: gateway.id)
        XCTAssertEqual(removedIDs, [gateway.id])
        XCTAssertNil(remaining)
    }
}

private actor RecordingEnrollmentCleanup: GatewayEnrollmentCleanupProviding {
    private(set) var removedIDs: [GatewayID] = []
    private let fail: Bool

    init(fail: Bool = false) { self.fail = fail }

    func removeEnrollmentMaterial(for gateway: FleetGateway) async throws {
        removedIDs.append(gateway.id)
        if fail { throw OwnerEnrollmentError.identityStorageFailed }
    }
}

/// A connection double whose connect always fails unreachable (the registry's
/// probe path is irrelevant to these tests).
private struct UnconnectableConnection: GatewayConnectivityProviding {
    let gatewayID = GatewayID(rawValue: "unconnectable")
    nonisolated var status: GatewayStatus { .offline }
    func connect() async throws { throw GatewayConnectivityError.unreachable }
    func disconnect() async {}
    func reauthenticate() async throws {}
    func adoptedReady() async -> GatewayReadyAdoption? { nil }
    func currentGateway() async -> FleetGateway {
        FleetGateway(
            id: gatewayID,
            displayName: "unconnectable",
            endpoint: nil,
            connectionState: .disconnected)
    }
}

/// Minimal in-test credential store (pins tests must not depend on
/// FleetSecurity).
private struct EmptyCredentialStore: CredentialStoring {
    func saveCredential(_ credential: GatewayCredential, for gatewayID: GatewayID) async throws {}
    func loadCredential(for gatewayID: GatewayID) async throws -> GatewayCredential? { nil }
    func deleteCredential(for gatewayID: GatewayID) async throws {}
}

/// Pin store whose delete ALWAYS fails (keychain unavailable).
private struct FailingDeletePinStore: TLSPinStoring {
    func savePin(_ pin: SPKIFingerprint, for gatewayID: GatewayID) async throws {}
    func loadPin(for gatewayID: GatewayID) async throws -> SPKIFingerprint? { nil }
    func deletePin(for gatewayID: GatewayID) async throws {
        throw PinStoreError.unexpectedStatus(-25291)
    }
}
