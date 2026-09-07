import XCTest
@testable import FleetCore

/// M3 one-gateway connectivity domain: the spec §13 user-facing gateway state
/// vocabulary and the `gateway.ready` adoption value (spec §31 Gateway:
/// "app can determine reachable/unreachable state").
final class ConnectivityDomainTests: XCTestCase {

    // MARK: GatewayStatus — §13 vocabulary + transport-state mapping

    func testGatewayStatusVocabularyCoversSpec13() {
        // spec §13: Online, Connecting, Degraded, Authentication Required,
        // Offline, Unsupported.
        XCTAssertEqual(Set(GatewayStatus.allCases), Set([
            .online, .connecting, .degraded, .authenticationRequired, .offline, .unsupported
        ]))
    }

    func testGatewayStatusMapsFromTransportState() {
        XCTAssertEqual(GatewayStatus(transportState: .connected), .online)
        XCTAssertEqual(GatewayStatus(transportState: .connecting), .connecting)
        XCTAssertEqual(GatewayStatus(transportState: .disconnected), .offline)
        XCTAssertEqual(GatewayStatus(transportState: .failed("server error (1011)")), .degraded)
    }

    func testGatewayStatusClassifiesFailureDetails() {
        // Classifier operates on the transport's DisconnectReason.debugDescription
        // strings (CloseCodeMapping), which the transport hands to FleetCore.
        XCTAssertEqual(GatewayStatus.classify(failureDetail: "reauthentication required (4401)"), .authenticationRequired)
        XCTAssertEqual(GatewayStatus.classify(failureDetail: "invalid channel (4400)"), .unsupported)
        XCTAssertEqual(GatewayStatus.classify(failureDetail: "host mismatch (4403)"), .unsupported)
        XCTAssertEqual(GatewayStatus.classify(failureDetail: "chat disabled (4404)"), .unsupported)
        XCTAssertEqual(GatewayStatus.classify(failureDetail: "peer not allowed (4408)"), .unsupported)
        XCTAssertEqual(GatewayStatus.classify(failureDetail: "server error (1011)"), .degraded)
        XCTAssertEqual(GatewayStatus.classify(failureDetail: "TLS handshake failure"), .degraded)
        // Abnormal/unknown/normal → offline (endpoint not serving).
        XCTAssertEqual(GatewayStatus.classify(failureDetail: "abnormal closure"), .offline)
        XCTAssertEqual(GatewayStatus.classify(failureDetail: "normal closure"), .offline)
        XCTAssertEqual(GatewayStatus.classify(failureDetail: "unknown close 4999: unclassified"), .offline)
    }

    func testGatewayStatusIsReachable() {
        XCTAssertTrue(GatewayStatus.online.isReachable)
        XCTAssertTrue(GatewayStatus.degraded.isReachable)
        XCTAssertFalse(GatewayStatus.connecting.isReachable)
        XCTAssertFalse(GatewayStatus.authenticationRequired.isReachable)
        XCTAssertFalse(GatewayStatus.offline.isReachable)
        XCTAssertFalse(GatewayStatus.unsupported.isReachable)
    }

    func testGatewayStatusEquatableAndRawValue() {
        XCTAssertEqual(GatewayStatus.online.rawValue, "online")
        XCTAssertEqual(GatewayStatus.offline, .offline)
        XCTAssertNotEqual(GatewayStatus.online, .offline)
    }

    // MARK: GatewayReadyAdoption — gateway.ready adoption value

    func testReadyAdoptionCapabilities() {
        let full = GatewayReadyAdoption(
            replayEpoch: "epoch-7", heartbeatEnabled: true, changeEventsEnabled: true)
        XCTAssertEqual(full.capabilities, ["heartbeat", "change_events"])
        XCTAssertEqual(full.replayEpoch, "epoch-7")

        let minimal = GatewayReadyAdoption(
            replayEpoch: nil, heartbeatEnabled: false, changeEventsEnabled: false)
        XCTAssertTrue(minimal.capabilities.isEmpty)
        XCTAssertNil(minimal.replayEpoch)
    }

    func testReadyAdoptionHashable() {
        let a = GatewayReadyAdoption(replayEpoch: "e1", heartbeatEnabled: true, changeEventsEnabled: false)
        let b = GatewayReadyAdoption(replayEpoch: "e1", heartbeatEnabled: true, changeEventsEnabled: false)
        let c = GatewayReadyAdoption(replayEpoch: "e2", heartbeatEnabled: true, changeEventsEnabled: false)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertNotEqual(a, c)
    }

    // MARK: GatewayConnectivityError

    func testConnectivityErrorLocalizedAndEquatable() {
        XCTAssertEqual(GatewayConnectivityError.timeout, .timeout)
        XCTAssertNotEqual(GatewayConnectivityError.timeout, .unreachable)
        XCTAssertEqual(GatewayConnectivityError.authenticationRequired.errorDescription, "authentication required")
        XCTAssertTrue((GatewayConnectivityError.unsupported("chat disabled").errorDescription ?? "").contains("unsupported"))
    }
}
