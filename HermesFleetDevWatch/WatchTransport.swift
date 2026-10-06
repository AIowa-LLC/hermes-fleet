import Foundation
import WatchConnectivity
import FleetWatchKit

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
        let reply = try await Self.deliver(payload).value
        guard let decoded = try? WatchCodec.unpack(WatchReply.self, from: reply) else {
            throw WatchTransportError.noReply
        }
        if case .snapshot(let snapshot) = decoded, (try? WatchCodec.validate(snapshot, expecting: flavor)) == nil {
            throw WatchTransportError.noReply
        }
        return decoded
    }
}

private struct UncheckedDict: @unchecked Sendable { let value: [String: Any] }

extension ConnectivityTransport {
    /// Built outside the main actor: WatchConnectivity invokes both handlers on
    /// its own queue, so they must not be main-actor isolated closures.
    nonisolated fileprivate static func deliver(_ payload: [String: Any]) async throws -> UncheckedDict {
        let box = UncheckedDict(value: payload)
        let session = WCSession.default
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UncheckedDict, Error>) in
            session.sendMessage(box.value, replyHandler: { reply in
                continuation.resume(returning: UncheckedDict(value: reply))
            }, errorHandler: { _ in
                continuation.resume(throwing: WatchTransportError.noReply)
            })
        }
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
