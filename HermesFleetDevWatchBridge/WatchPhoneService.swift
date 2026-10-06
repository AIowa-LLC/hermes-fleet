import Foundation
import WatchConnectivity
import FleetUI
import FleetWatchKit

/// iPhone half of the WatchConnectivity link. State goes out through
/// `updateApplicationContext` (latest wins; the system decides when it lands),
/// requests come in through interactive `sendMessage` only, so a decision the
/// phone never received is never reported as delivered.
@MainActor
final class WatchPhoneService: NSObject {
    private let coordinator: WatchPhoneCoordinator
    private let flavor: WatchAppFlavor
    private var pushTask: Task<Void, Never>?
    private var session: WCSession?
    private(set) var lastPushError: String?
    /// Called with true while a Watch app is installed, so the phone only
    /// polls gateways for the Watch when there is a Watch to show it on.
    var setObservingForWatch: (Bool) -> Void = { _ in }
    private var observing = false

    private func setObserving(_ on: Bool) {
        guard on != observing else { return }
        observing = on
        setObservingForWatch(on)
    }

    init(coordinator: WatchPhoneCoordinator, flavor: WatchAppFlavor) {
        self.coordinator = coordinator
        self.flavor = flavor
    }

    func start() {
        guard WCSession.isSupported(), session == nil else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        session = s
        pushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.pushSnapshot()
            }
        }
    }

    func stop() {
        pushTask?.cancel()
        pushTask = nil
    }

    /// Pushes the latest observed state when a Watch app is actually installed.
    func pushSnapshot() {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else {
            setObserving(false)
            return
        }
        setObserving(true)
        do {
            let snapshot = coordinator.makeSnapshot()
            try session.updateApplicationContext(try WatchCodec.pack(WatchReply.snapshot(snapshot)))
            lastPushError = nil
        } catch {
            lastPushError = String(describing: error)
        }
    }

    private func process(_ data: Data?) async -> [String: Any] {
        guard let data else { return Self.pack(.rejected(reason: "Unreadable request.")) }
        let request: WatchRequest
        do { request = try WatchCodec.unpack(WatchRequest.self, from: [WatchCodec.key: data]) } catch {
            return Self.pack(.rejected(reason: "Unreadable request."))
        }
        return Self.pack(await coordinator.handle(request))
    }

    private static func pack(_ reply: WatchReply) -> [String: Any] {
        (try? WatchCodec.pack(reply)) ?? [:]
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void
    init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
    func send(_ value: [String: Any]) { handler(value) }
}

extension WatchPhoneService: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.pushSnapshot() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // A new Watch was paired/switched: reactivate so the link survives.
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.pushSnapshot() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.pushSnapshot() }
    }

    nonisolated func session(
        _ session: WCSession, didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let data = message[WatchCodec.key] as? Data
        let box = ReplyBox(replyHandler)
        Task { @MainActor in box.send(await self.process(data)) }
    }
}
