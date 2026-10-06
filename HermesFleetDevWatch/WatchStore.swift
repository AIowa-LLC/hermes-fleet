import Foundation
import Observation
import FleetWatchKit

/// What the UI shows for one approval's most recent action.
enum ApprovalActionState: Equatable {
    case sending(WatchApprovalDecision)
    case settled(WatchApprovalOutcome)
    /// Never reached the phone: link was down. Nothing happened.
    case notSent(String)
}

@MainActor
@Observable
final class WatchStore {
    // MARK: Observed state
    private(set) var snapshot: WatchSnapshot?
    private(set) var link: WatchLinkState
    private(set) var now: Date
    private(set) var approvalStates: [String: ApprovalActionState] = [:]
    private(set) var outbox: WatchMessageOutbox
    private(set) var isRefreshing = false
    var selection: WatchContextSelection { didSet { persistSelection() } }

    let flavor: WatchAppFlavor = .dev
    private let transport: any WatchTransport
    private let defaults: UserDefaults
    private let outboxURL: URL
    private let clock: () -> Date
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var flushing = false

    init(transport: any WatchTransport, defaults: UserDefaults = .standard,
         outboxURL: URL = WatchStore.defaultOutboxURL(), clock: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.defaults = defaults
        self.outboxURL = outboxURL
        self.clock = clock
        self.now = clock()
        self.link = transport.linkState
        self.selection = Self.loadSelection(defaults)
        var box = Self.loadOutbox(outboxURL)
        box.recoverAfterRelaunch(now: clock())
        self.outbox = box
        persistOutbox()
    }

    var isFixture: Bool { transport.isFixture || snapshot?.isFixture == true }

    func start() {
        transport.onSnapshot = { [weak self] in self?.ingest($0) }
        transport.onLinkChange = { [weak self] state in
            guard let self else { return }
            self.link = state
            if state == .reachable {
                Task { await self.refresh(); await self.flushQueuedMessages() }
            } else {
                self.markInFlightUncertainOnDisconnect()
            }
        }
        transport.activate()
        link = transport.linkState
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                self.now = self.clock()
            }
        }
        Task { await refresh(); await flushQueuedMessages() }
    }

    // MARK: Snapshot

    private func ingest(_ incoming: WatchSnapshot) {
        // Drop out-of-order contexts; never move backwards.
        if let current = snapshot, incoming.generation < current.generation,
           incoming.builtAt <= current.builtAt { return }
        snapshot = incoming
        now = clock()
        // A resolved approval is gone from the snapshot: forget its UI state.
        let live = Set(incoming.approvals.map(\.id))
        approvalStates = approvalStates.filter { live.contains($0.key) }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; now = clock() }
        guard let reply = try? await transport.send(.refresh(flavor: flavor)) else { return }
        if case .snapshot(let s) = reply { ingest(s) }
    }

    var resolution: WatchContextResolution {
        guard let snapshot else { return .unselected }
        return WatchContextResolver.resolve(selection, in: snapshot)
    }

    var contextLabel: String { WatchContextResolver.label(for: resolution) }

    var freshness: WatchFreshness {
        WatchFreshnessPolicy.freshness(observedAt: snapshot?.builtAt, now: now)
    }

    // MARK: Approvals (always bound to the approval's own identity)

    func affordance(for approval: WatchApproval) -> WatchApprovalAffordance {
        guard let snapshot else { return .none(reason: "No data yet.") }
        if link != .reachable { return .none(reason: "iPhone not reachable. Nothing can be sent.") }
        return WatchApprovalPolicy.affordance(for: approval, snapshotBuiltAt: snapshot.builtAt, now: now)
    }

    func decide(_ approval: WatchApproval, _ decision: WatchApprovalDecision) async {
        let key = approval.id
        // One action per approval at a time; a settled/uncertain state must be
        // dismissed (after looking again) before another decision is sent.
        switch approvalStates[key] {
        case nil, .notSent: break
        case .sending, .settled: return
        }
        guard let snapshot else { return }
        switch affordance(for: approval) {
        case .denyOrApproveOnce: break
        case .denyOnly: guard decision == .deny else { return }
        case .none(let reason):
            approvalStates[key] = .notSent(reason)
            return
        }
        let request = WatchApprovalRequest(
            gatewayID: approval.gatewayID, sessionID: approval.sessionID, requestID: approval.requestID,
            commandDigest: approval.commandDigest, decision: decision,
            snapshotGeneration: snapshot.generation, sentAt: clock())
        approvalStates[key] = .sending(decision)
        do {
            let reply = try await transport.send(.approval(request, flavor: flavor))
            guard case .approval(let r) = reply, r.requestUUID == request.requestUUID else {
                approvalStates[key] = .settled(.uncertain(reason: "Unexpected reply. Check iPhone."))
                return
            }
            approvalStates[key] = .settled(r.outcome)
            switch r.outcome {
            case .changed, .alreadyResolved, .expired, .staleSnapshot, .duplicate, .uncertain: await refresh()
            default: break
            }
        } catch WatchTransportError.notReachable {
            approvalStates[key] = .notSent("iPhone not reachable. Nothing was sent.")
        } catch {
            approvalStates[key] = .settled(.uncertain(reason: "No reply from iPhone. It may or may not have been applied."))
            await refresh()
        }
    }

    /// Clears a settled/failed state so the user can look again after a refresh.
    func dismissApprovalState(_ key: String) { approvalStates[key] = nil }

    // MARK: Messages

    /// Composes and queues an explicitly-sent message to the CURRENT selection.
    @discardableResult
    func send(text: String) -> Bool {
        guard case .resolved(let gateway, let bot?, let conversation) = resolution else { return false }
        let request = WatchMessageRequest(
            gatewayID: gateway.id, profileSlug: bot.ref.profileSlug,
            conversationID: conversation?.isMain == true ? nil : conversation?.id,
            text: text, composedAt: clock())
        guard outbox.enqueue(request, targetLabel: contextLabel, now: clock()) else { return false }
        persistOutbox()
        Task { await flushQueuedMessages() }
        return true
    }

    func flushQueuedMessages() async {
        guard !flushing, link == .reachable else { return }
        flushing = true
        defer { flushing = false }
        for message in outbox.autoTransmittable {
            guard link == .reachable else { break }
            outbox.markSent(message.id, now: clock())
            persistOutbox()
            do {
                let reply = try await transport.send(.message(message.request, flavor: flavor))
                if case .message(let r) = reply, r.clientMessageID == message.id {
                    outbox.apply(r, now: clock())
                } else {
                    outbox.markUncertain(message.id, reason: "Unexpected reply from iPhone.", now: clock())
                }
            } catch WatchTransportError.notReachable {
                outbox.markUncertain(message.id, reason: "Link dropped while sending.", now: clock())
            } catch {
                outbox.markUncertain(message.id, reason: "No reply from iPhone.", now: clock())
            }
            persistOutbox()
        }
    }

    func retry(_ id: String) {
        guard outbox.userRetry(id, now: clock()) else { return }
        persistOutbox()
        Task { await flushQueuedMessages() }
    }

    func discard(_ id: String) {
        outbox.remove(id)
        persistOutbox()
    }

    private func markInFlightUncertainOnDisconnect() {
        for message in outbox.messages where message.state == .sentToPhone {
            outbox.markUncertain(message.id, reason: "Link to iPhone dropped.", now: clock())
        }
        persistOutbox()
    }

    // MARK: Persistence

    private static let selectionKey = "fleet.watch.selection.v1"

    private static func loadSelection(_ defaults: UserDefaults) -> WatchContextSelection {
        guard let data = defaults.data(forKey: selectionKey),
              let value = try? JSONDecoder().decode(WatchContextSelection.self, from: data) else { return .empty }
        return value
    }

    private func persistSelection() {
        if let data = try? JSONEncoder().encode(selection) { defaults.set(data, forKey: Self.selectionKey) }
    }

    static func defaultOutboxURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FleetWatchDev/outbox.json")
    }

    private static func loadOutbox(_ url: URL) -> WatchMessageOutbox {
        guard let data = try? Data(contentsOf: url),
              let box = try? JSONDecoder().decode(WatchMessageOutbox.self, from: data) else { return WatchMessageOutbox() }
        return box
    }

    private func persistOutbox() {
        do {
            try FileManager.default.createDirectory(at: outboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(outbox).write(to: outboxURL, options: [.atomic, .completeFileProtection])
        } catch {}
    }
}
