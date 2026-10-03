import Foundation
import Testing

@testable import FleetCore

@Suite("Notification tap routing (R3 seam)")
struct NotificationRoutingTests {
    // Mirrors the push_v1 plaintext in the shared HPKE vector file (synthetic).
    static var base: [String: Any] { [
        "bot": "default", "command_digest": String(repeating: "0", count: 64),
        "created_at": 1_800_000_000, "expires_at": 1_800_000_300,
        "gateway_label": "Example Host", "kind": "approval", "nonce": "AAAAAAAAAAAAAAAA",
        "redacted_preview": "example command --flag", "request_id": "req-example",
        "request_ref": "0123456789abcdef", "response_token": "example-token-not-real",
        "risk": "normal", "session_id": "session-example", "v": 1,
    ] }
    static let t0 = Date(timeIntervalSince1970: 1_800_000_010)
    static let gw = GatewayID(rawValue: "gw-a")

    static func payload(_ overrides: [String: Any?] = [:]) throws -> OpenedNotificationPayload {
        var dict = base
        for (k, v) in overrides {
            if let v { dict[k] = v } else { dict.removeValue(forKey: k) }
        }
        return try OpenedNotificationPayload(json: JSONSerialization.data(withJSONObject: dict))
    }

    static func gateway(_ id: GatewayID = gw, name: String = "Example Host", state: TransportState = .connected) -> FleetGateway {
        FleetGateway(id: id, displayName: name, connectionState: state)
    }

    // MARK: decoding

    @Test func decodesSharedVectorShape() throws {
        let p = try Self.payload()
        #expect(p.kind == .approval)
        #expect(p.requestID == "req-example")
        #expect(p.sessionID == "session-example")
        #expect(!p.isHighRisk)
        #expect(p.expiresAt.timeIntervalSince(p.createdAt) == 300)
    }

    @Test func rejectsMalformedAndTamperedShapes() {
        #expect(throws: NotificationPayloadError.malformed) { try OpenedNotificationPayload(json: Data("{".utf8)) }
        #expect(throws: NotificationPayloadError.unsupportedVersion) { try Self.payload(["v": 2]) }
        #expect(throws: NotificationPayloadError.unknownKind) { try Self.payload(["kind": "root"]) }
        #expect(throws: NotificationPayloadError.invalidTimes) { try Self.payload(["expires_at": 1_800_000_000]) }
        #expect(throws: NotificationPayloadError.invalidIdentity) { try Self.payload(["session_id": ""]) }
        #expect(throws: NotificationPayloadError.invalidIdentity) { try Self.payload(["request_id": "a\u{0007}b"]) }
        #expect(throws: NotificationPayloadError.invalidIdentity) { try Self.payload(["nonce": String(repeating: "x", count: 500)]) }
        #expect(throws: NotificationPayloadError.invalidIdentity) { try Self.payload(["kind": "withdraw"]) }
    }

    @Test func responseTokenIsNeverRetained() throws {
        let p = try Self.payload()
        let mirror = String(describing: p)
        #expect(!mirror.contains("example-token-not-real"))
        let target = NotificationTapTarget(payload: p, registeredGatewayID: Self.gw)
        let encoded = try String(decoding: JSONEncoder().encode(target), as: UTF8.self)
        #expect(!encoded.contains("example-token-not-real"))
        #expect(!encoded.contains("example command"))
    }

    // MARK: presentation / redaction

    @Test func unlockedShowsPreviewAndLabelWithStableThread() throws {
        let p = try Self.payload()
        let c = NotificationPresentation.Context(appLockEnabled: false, deviceLocked: false, hidePreviews: false)
        let out = NotificationPresentation.content(for: p, context: c, now: Self.t0)
        #expect(out.body == "example command --flag")
        #expect(out.title.contains("Example Host"))
        #expect(out.threadIdentifier == p.deliveryKey)
    }

    @Test func highRiskNeverShowsCommandText() throws {
        let p = try Self.payload(["risk": "high"])
        let c = NotificationPresentation.Context(appLockEnabled: false, deviceLocked: false, hidePreviews: false)
        let out = NotificationPresentation.content(for: p, context: c, now: Self.t0)
        #expect(!out.body.contains("example command"))
    }

    @Test(arguments: [(true, false, false), (false, true, false), (false, false, true)])
    func appLockLockedDeviceAndHidePreviewsRedact(lock: Bool, locked: Bool, hide: Bool) throws {
        let p = try Self.payload()
        let c = NotificationPresentation.Context(appLockEnabled: lock, deviceLocked: locked, hidePreviews: hide)
        let out = NotificationPresentation.content(for: p, context: c, now: Self.t0)
        #expect(out == NotificationPresentation.generic(for: .approval))
        #expect(!out.title.contains("Example Host"))
        #expect(out.threadIdentifier == nil)
    }

    @Test func decryptionFailureOrExpiryIsGeneric() throws {
        let c = NotificationPresentation.Context(appLockEnabled: false, deviceLocked: false, hidePreviews: false)
        #expect(NotificationPresentation.content(for: nil, context: c, now: Self.t0) == .generic())
        let p = try Self.payload()
        let late = Date(timeIntervalSince1970: 1_800_000_400)
        #expect(NotificationPresentation.content(for: p, context: c, now: late) == .generic())
    }

    // MARK: replay

    @Test func repeatedNonceAndReconnectRepushDoNotDuplicate() throws {
        var ledger = NotificationReplayLedger()
        let first = try Self.payload()
        #expect(ledger.admit(first, now: Self.t0) == .present)
        #expect(ledger.admit(first, now: Self.t0) == .replayedNonce)
        let repush = try Self.payload(["nonce": "BBBBBBBBBBBBBBBB"])
        #expect(ledger.admit(repush, now: Self.t0) == .duplicateRequest)
        let other = try Self.payload(["nonce": "CCCCCCCCCCCCCCCC", "request_id": "req-two"])
        #expect(ledger.admit(other, now: Self.t0) == .present)
    }

    @Test func expiredDeliveryIsRejectedAndSettledKeyIsFreed() throws {
        var ledger = NotificationReplayLedger()
        let p = try Self.payload()
        #expect(ledger.admit(p, now: Date(timeIntervalSince1970: 1_800_000_301)) == .expired)
        #expect(ledger.admit(p, now: Self.t0) == .present)
        ledger.settle(deliveryKey: p.deliveryKey)
        let again = try Self.payload(["nonce": "DDDDDDDDDDDDDDDD"])
        #expect(ledger.admit(again, now: Self.t0) == .present)
    }

    @Test func withdrawalIsAdmittedAndLedgerStaysBounded() throws {
        var ledger = NotificationReplayLedger(capacity: 8)
        for i in 0..<40 {
            _ = ledger.admit(try Self.payload(["nonce": "n\(i)", "request_id": "r\(i)"]), now: Self.t0)
        }
        // Oldest nonce evicted: bounded memory, newest still protected.
        #expect(ledger.admit(try Self.payload(["nonce": "n39", "request_id": "r39"]), now: Self.t0) == .replayedNonce)
        let w = try Self.payload(["kind": "withdraw", "collapse_id": "abc", "nonce": "W1"])
        #expect(ledger.admit(w, now: Self.t0) == .present)
    }

    // MARK: tap routing

    private func target(_ p: OpenedNotificationPayload, id: GatewayID? = gw) -> NotificationTapTarget {
        NotificationTapTarget(payload: p, registeredGatewayID: id)
    }

    @Test func pendingRequestOpensExactIdentity() throws {
        let out = NotificationTapResolver.resolve(target(try Self.payload()), now: Self.t0, gateways: [Self.gateway()], requestStatus: .pending)
        #expect(out.state == .opening(verified: true))
        #expect(out.destination == .request(gatewayID: Self.gw, sessionID: "session-example", requestID: "req-example"))
    }

    @Test func resolvedRequestIsTruthfulAndOnlyNavigates() throws {
        let out = NotificationTapResolver.resolve(target(try Self.payload()), now: Self.t0, gateways: [Self.gateway()], requestStatus: .notPending)
        #expect(out.state == .resolved)
        #expect(out.destination == .session(gatewayID: Self.gw, sessionID: "session-example"))
        #expect(out.message != nil)
    }

    @Test func expiredUnverifiedFallsBackToSession() throws {
        let late = Date(timeIntervalSince1970: 1_800_000_400)
        let out = NotificationTapResolver.resolve(target(try Self.payload()), now: late, gateways: [Self.gateway()], requestStatus: .unverified)
        #expect(out.state == .expired)
        #expect(out.destination == .session(gatewayID: Self.gw, sessionID: "session-example"))
    }

    @Test func stillPendingBeatsNotificationExpiry() throws {
        let late = Date(timeIntervalSince1970: 1_800_000_400)
        let out = NotificationTapResolver.resolve(target(try Self.payload()), now: late, gateways: [Self.gateway()], requestStatus: .pending)
        #expect(out.state == .opening(verified: true))
    }

    @Test func disconnectedGatewayOffersReconnect() throws {
        let gws = [Self.gateway(state: .disconnected)]
        let out = NotificationTapResolver.resolve(target(try Self.payload()), now: Self.t0, gateways: gws, requestStatus: .unverified)
        #expect(out.state == .gatewayDisconnected)
        #expect(out.destination == .gatewayConnection(Self.gw))
    }

    @Test func connectedButUnverifiedOpensMarkedUnverified() throws {
        let out = NotificationTapResolver.resolve(target(try Self.payload()), now: Self.t0, gateways: [Self.gateway()], requestStatus: .unverified)
        #expect(out.state == .opening(verified: false))
    }

    @Test func removedGatewayOffersGatewayList() throws {
        let out = NotificationTapResolver.resolve(target(try Self.payload()), now: Self.t0, gateways: [], requestStatus: .pending)
        #expect(out.state == .gatewayRemoved)
        #expect(out.destination == .gatewayList)
    }

    @Test func labelFallbackRequiresExactlyOneMatch() throws {
        let p = try Self.payload()
        let one = NotificationTapTarget(payload: p, gateways: [Self.gateway(), Self.gateway(GatewayID(rawValue: "gw-b"), name: "Other")])
        #expect(one.gatewayID == Self.gw)
        let dup = NotificationTapTarget(payload: p, gateways: [Self.gateway(), Self.gateway(GatewayID(rawValue: "gw-b"))])
        #expect(dup.gatewayID == nil)
        let out = NotificationTapResolver.resolve(dup, now: Self.t0, gateways: [Self.gateway()], requestStatus: .pending)
        #expect(out.state == .gatewayUnidentified)
        #expect(out.destination == .gatewayList)
        // A registered id beats a colliding label.
        let reg = NotificationTapTarget(payload: p, registeredGatewayID: GatewayID(rawValue: "gw-b"), gateways: [Self.gateway(), Self.gateway(GatewayID(rawValue: "gw-b"))])
        #expect(reg.gatewayID == GatewayID(rawValue: "gw-b"))
    }

    @Test func unsafeIdentityInStoredTargetIsInvalidAndGoesHome() {
        let bad = NotificationTapTarget(gatewayID: Self.gw, gatewayLabel: "x", sessionID: "a\nb", requestID: nil, kind: .approval, expiresAt: Self.t0)
        let out = NotificationTapResolver.resolve(bad, now: Self.t0, gateways: [Self.gateway()], requestStatus: .pending)
        #expect(out.state == .invalid)
        #expect(out.destination == .home)
    }

    @Test func nonRequestKindsOpenSessionWithoutRequestStatus() throws {
        let p = try Self.payload(["kind": "done", "request_id": nil])
        let out = NotificationTapResolver.resolve(target(p), now: Self.t0, gateways: [Self.gateway()], requestStatus: .unverified)
        #expect(out.destination == .session(gatewayID: Self.gw, sessionID: "session-example"))
    }

    @Test func repeatedResolveIsDeterministic() throws {
        let t = target(try Self.payload())
        let a = NotificationTapResolver.resolve(t, now: Self.t0, gateways: [Self.gateway()], requestStatus: .pending)
        let b = NotificationTapResolver.resolve(t, now: Self.t0, gateways: [Self.gateway()], requestStatus: .pending)
        #expect(a == b)
    }
}
