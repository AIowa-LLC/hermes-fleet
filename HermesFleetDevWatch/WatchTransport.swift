import Foundation
import WatchConnectivity
import FleetWatchKit

enum WatchTransportError: Error, Equatable {
    /// Verified before sending: the phone link is not reachable, nothing left the Watch.
    case notReachable
    /// The request may have left the Watch but no valid reply arrived.
    case noReply
}

/// The Watch's only way to reach Fleet. There is no other network path and no
/// credential on this device.
@MainActor
protocol WatchTransport: AnyObject {
    var linkState: WatchLinkState { get }
    var onSnapshot: ((WatchSnapshot) -> Void)? { get set }
    var onLinkChange: ((WatchLinkState) -> Void)? { get set }
    func activate()
    func send(_ request: WatchRequest) async throws -> WatchReply
    var isFixture: Bool { get }
}

// MARK: - WatchConnectivity

@MainActor
final class ConnectivityTransport: NSObject, WatchTransport {
    private(set) var linkState: WatchLinkState = .notActivated
    var onSnapshot: ((WatchSnapshot) -> Void)?
    var onLinkChange: ((WatchLinkState) -> Void)?
    let isFixture = false
    private let flavor: WatchAppFlavor

    init(flavor: WatchAppFlavor) { self.flavor = flavor }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    fileprivate struct LinkFacts: Sendable {
        let activated: Bool
        let installed: Bool
        let reachable: Bool
        init(_ session: WCSession) {
            activated = session.activationState == .activated
            installed = session.isCompanionAppInstalled
            reachable = session.isReachable
        }
    }

    fileprivate func recompute(_ facts: LinkFacts) {
        let new: WatchLinkState
        if !facts.activated { new = .notActivated }
        else if !facts.installed { new = .companionMissing }
        else { new = facts.reachable ? .reachable : .phoneUnreachable }
        guard new != linkState else { return }
        linkState = new
        onLinkChange?(new)
    }

    private func ingest(_ context: [String: Any]) {
        guard !context.isEmpty,
              let reply = try? WatchCodec.unpack(WatchReply.self, from: context),
              case .snapshot(let snapshot) = reply,
              (try? WatchCodec.validate(snapshot, expecting: flavor)) != nil else { return }
        onSnapshot?(snapshot)
    }

    func send(_ request: WatchRequest) async throws -> WatchReply {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            throw WatchTransportError.notReachable
        }
        let payload = try WatchCodec.pack(request)
        let reply: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) let payload = payload
            session.sendMessage(payload, replyHandler: { reply in
                nonisolated(unsafe) let reply = reply
                continuation.resume(returning: reply)
            }, errorHandler: { _ in
                continuation.resume(throwing: WatchTransportError.noReply)
            })
        }
        guard let decoded = try? WatchCodec.unpack(WatchReply.self, from: reply) else {
            throw WatchTransportError.noReply
        }
        if case .snapshot(let snapshot) = decoded, (try? WatchCodec.validate(snapshot, expecting: flavor)) == nil {
            throw WatchTransportError.noReply
        }
        return decoded
    }
}

extension ConnectivityTransport: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let facts = LinkFacts(session)
        nonisolated(unsafe) let boxed = session.receivedApplicationContext
        Task { @MainActor in
            self.recompute(facts)
            self.ingest(boxed)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let facts = LinkFacts(session)
        Task { @MainActor in self.recompute(facts) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let facts = LinkFacts(session)
        nonisolated(unsafe) let boxed = applicationContext
        Task { @MainActor in
            self.recompute(facts)
            self.ingest(boxed)
        }
    }
}
