import SwiftUI
import FleetWatchKit

// MARK: - Root

struct RootView: View {
    let store: WatchStore
    @Environment(\.isLuminanceReduced) private var dimmed
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            List {
                if store.isFixture { MockBanner() }
                ContextHeader(store: store) { showPicker = true }
                FreshnessRow(store: store)
                if let snapshot = store.snapshot, !snapshot.contentVisible {
                    Label("Locked on iPhone. Unlock Hermes Fleet Dev to see your fleet.", systemImage: "lock.fill")
                        .font(.footnote)
                } else if store.snapshot == nil {
                    Label(store.link == .companionMissing ? "Open the iPhone app first." : "Waiting for iPhone…", systemImage: "iphone")
                        .font(.footnote)
                } else {
                    NavigationLink { StatusView(store: store) } label: { Label("Check in", systemImage: "waveform.path.ecg") }
                    NavigationLink { ApprovalListView(store: store) } label: {
                        let count = store.snapshot?.approvals.count ?? 0
                        Label(count == 0 ? "Approvals" : "Approvals (\(count))", systemImage: "checkmark.shield")
                    }
                    NavigationLink { MessagesView(store: store) } label: { Label("Messages", systemImage: "bubble.left") }
                }
            }
            .navigationTitle("Fleet Dev")
            .redacted(reason: dimmed ? .placeholder : [])
            .sheet(isPresented: $showPicker) { ContextPickerView(store: store) }
        }
    }
}

struct MockBanner: View {
    var body: some View {
        Label("MOCK DATA", systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.bold()).foregroundStyle(.orange)
            .accessibilityLabel("Mock data, not live")
    }
}

struct ContextHeader: View {
    let store: WatchStore
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Context").font(.caption2).foregroundStyle(.secondary)
                Text(store.contextLabel).font(.footnote.bold()).lineLimit(2)
            }
        }
        .accessibilityLabel("Context \(store.contextLabel). Change.")
    }
}

struct FreshnessRow: View {
    let store: WatchStore

    var body: some View {
        let age = WatchFreshnessPolicy.ageLabel(observedAt: store.snapshot?.builtAt, now: store.now)
        VStack(alignment: .leading, spacing: 2) {
            switch store.link {
            case .reachable: Label("iPhone connected", systemImage: "iphone.gen3")
            case .phoneUnreachable: Label("iPhone unreachable. Showing saved data.", systemImage: "iphone.slash")
            case .notActivated: Label("Connecting to iPhone…", systemImage: "iphone")
            case .companionMissing: Label("iPhone app not found", systemImage: "iphone.slash")
            }
            switch store.freshness {
            case .fresh: Label("Updated \(age)", systemImage: "checkmark.circle")
            case .aging: Label("Updated \(age)", systemImage: "clock")
            case .stale: Label("STALE · updated \(age)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .none: EmptyView()
            }
        }
        .font(.caption2)
    }
}

// MARK: - Context picker (Machine → Bot → Conversation)

struct ContextPickerView: View {
    let store: WatchStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let snapshot = store.snapshot {
                    if case .gatewayMissing = store.resolution { Text("Selected machine was removed.").font(.footnote).foregroundStyle(.orange) }
                    ForEach(snapshot.gateways) { gateway in
                        NavigationLink {
                            BotPickerView(store: store, gateway: gateway, dismissAll: { dismiss() })
                        } label: {
                            VStack(alignment: .leading) {
                                Text(gateway.displayName)
                                Text(statusText(gateway)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("No machines yet. Add them on iPhone.").font(.footnote)
                }
                Text("Machines are managed on iPhone.").font(.caption2).foregroundStyle(.secondary)
            }
            .navigationTitle("Machine")
        }
    }

    private func statusText(_ g: WatchGateway) -> String {
        let obs = WatchFreshnessPolicy.ageLabel(observedAt: g.observedAt, now: store.now)
        return "\(g.status.label) · \(g.coverage.label) · \(obs)"
    }
}

struct BotPickerView: View {
    let store: WatchStore
    let gateway: WatchGateway
    let dismissAll: () -> Void

    var body: some View {
        List {
            Button("Whole machine") {
                store.selection = .init(gatewayID: gateway.id)
                dismissAll()
            }
            ForEach(gateway.bots) { bot in
                NavigationLink {
                    ConversationPickerView(store: store, gateway: gateway, bot: bot, dismissAll: dismissAll)
                } label: {
                    VStack(alignment: .leading) {
                        Text(bot.displayName)
                        Text(bot.activity).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if gateway.bots.isEmpty { Text("No bots reported by this machine.").font(.footnote) }
        }
        .navigationTitle(gateway.displayName)
    }
}

struct ConversationPickerView: View {
    let store: WatchStore
    let gateway: WatchGateway
    let bot: WatchBot
    let dismissAll: () -> Void

    var body: some View {
        List {
            Button("Bot only") {
                store.selection = .init(gatewayID: gateway.id, profileSlug: bot.ref.profileSlug)
                dismissAll()
            }
            ForEach(bot.conversations) { conversation in
                Button(conversation.isMain ? "Main chat" : conversation.title) {
                    store.selection = .init(gatewayID: gateway.id, profileSlug: bot.ref.profileSlug,
                                            conversationID: conversation.id)
                    dismissAll()
                }
            }
        }
        .navigationTitle(bot.displayName)
    }
}

// MARK: - Check in

struct StatusView: View {
    let store: WatchStore

    var body: some View {
        List {
            ContextHeader(store: store) {}.disabled(true)
            FreshnessRow(store: store)
            if let snapshot = store.snapshot {
                switch store.resolution {
                case .unselected:
                    Text("Choose a machine from the context header on the main screen.").font(.footnote)
                case .gatewayMissing, .botMissing, .conversationMissing:
                    Text("Your selected destination is no longer available. Choose another. Nothing was substituted.")
                        .font(.footnote).foregroundStyle(.orange)
                case .resolved(let gateway, _, _):
                    gatewaySection(gateway)
                    let others = snapshot.attention.filter { $0.gatewayID != gateway.id }.count
                    if others > 0 { Text("\(others) item\(others == 1 ? "" : "s") need attention on other machines.").font(.caption2) }
                }
            }
        }
        .navigationTitle("Check in")
    }

    @ViewBuilder
    private func gatewaySection(_ gateway: WatchGateway) -> some View {
        Section("Connection") {
            Label(gateway.status.label, systemImage: gateway.status.symbol)
            Text("Observed \(WatchFreshnessPolicy.ageLabel(observedAt: gateway.observedAt, now: store.now))")
                .font(.caption2)
            if gateway.coverage != .reporting {
                Label(gateway.coverage.explanation, systemImage: "eye.slash").font(.caption2).foregroundStyle(.orange)
            }
        }
        Section("Running work") {
            if gateway.running.isEmpty {
                Text(gateway.coverage == .reporting ? "Nothing running" : "Unknown. Not reported.").font(.footnote)
            }
            ForEach(gateway.running) { Text("\($0.title) · \($0.status)").font(.footnote) }
        }
        let attention = store.snapshot?.attention.filter { $0.gatewayID == gateway.id } ?? []
        Section("Needs attention") {
            if attention.isEmpty { Text("Nothing observed").font(.footnote) }
            ForEach(attention) { item in
                VStack(alignment: .leading) {
                    Text(item.title).font(.footnote)
                    if let detail = item.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

// MARK: - Approvals

struct ApprovalListView: View {
    let store: WatchStore

    var body: some View {
        let all = store.snapshot?.approvals ?? []
        let resolution = store.resolution
        let scoped = all.filter { approval in
            guard case .resolved(let gateway, let bot, _) = resolution, gateway.id == approval.gatewayID else { return false }
            if let bot { return approval.profileSlug == bot.ref.profileSlug }
            return true
        }
        let others = all.filter { a in !scoped.contains { $0.id == a.id } }
        List {
            ContextHeader(store: store) {}.disabled(true)
            FreshnessRow(store: store)
            Section("This context") {
                if scoped.isEmpty { Text("No pending approvals").font(.footnote) }
                ForEach(scoped) { link($0) }
            }
            if !others.isEmpty {
                Section("Other machines/bots") {
                    ForEach(others) { link($0) }
                }
            }
        }
        .navigationTitle("Approvals")
    }

    private func link(_ approval: WatchApproval) -> some View {
        NavigationLink { ApprovalDetailView(store: store, approval: approval) } label: {
            VStack(alignment: .leading) {
                Text("\(approval.gatewayName) › \(approval.botName ?? "unknown bot")").font(.caption2).foregroundStyle(.secondary)
                Text(approval.commandPreview).font(.footnote).lineLimit(2)
            }
        }
    }
}

struct ApprovalDetailView: View {
    let store: WatchStore
    let approval: WatchApproval
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        let state = store.approvalStates[approval.id]
        let still = store.snapshot?.approvals.contains { $0.id == approval.id } == true
        List {
            // Always the ORIGINAL origin, never the picker selection.
            Section("From") {
                Text("Machine: \(approval.gatewayName)")
                Text("Bot: \(approval.botName ?? "unknown")")
                Text("Chat: \(approval.sessionLabel)")
            }.font(.caption)
            Section("Command") {
                Text(approval.commandPreview).font(.system(.footnote, design: .monospaced))
                if approval.requiresFullReview {
                    Label("Long command. Review it in full on iPhone.", systemImage: "iphone").font(.caption2).foregroundStyle(.orange)
                }
            }
            FreshnessRow(store: store)
            actions(state: state, stillPending: still)
        }
        .redacted(reason: dimmed ? .placeholder : [])
        .navigationTitle("Approval")
    }

    @ViewBuilder
    private func actions(state: ApprovalActionState?, stillPending: Bool) -> some View {
        switch state {
        case .sending(let decision):
            ProgressView(decision == .deny ? "Denying…" : "Waiting for iPhone…")
        case .settled(let outcome):
            Section("Result") {
                Text(outcome.userText).font(.footnote)
                Button("Look again") {
                    store.dismissApprovalState(approval.id)
                    Task { await store.refresh() }
                }
            }
        case .notSent(let message):
            Section { Text(message).font(.footnote).foregroundStyle(.orange)
                Button("Dismiss") { store.dismissApprovalState(approval.id) } }
        case nil:
            if !stillPending {
                Text("No longer pending.").font(.footnote)
            } else {
                switch store.affordance(for: approval) {
                case .denyOrApproveOnce:
                    Button("Approve once") { Task { await store.decide(approval, .approveOnce) } }.tint(.green)
                    Button("Deny", role: .destructive) { Task { await store.decide(approval, .deny) } }
                    Text("Approving asks you to confirm with Face ID on iPhone.").font(.caption2).foregroundStyle(.secondary)
                case .denyOnly(let reason):
                    Text(reason).font(.caption2).foregroundStyle(.orange)
                    Button("Deny", role: .destructive) { Task { await store.decide(approval, .deny) } }
                case .none(let reason):
                    Text(reason).font(.footnote).foregroundStyle(.orange)
                    Button("Refresh") { Task { await store.refresh() } }
                }
            }
        }
    }
}

// MARK: - Messages

struct MessagesView: View {
    let store: WatchStore
    @State private var text = ""
    @State private var confirmation: String?

    var body: some View {
        List {
            ContextHeader(store: store) {}.disabled(true)
            FreshnessRow(store: store)
            let resolution = store.resolution
            if resolution.isFullyTargeted {
                Section("To: \(store.contextLabel)") {
                    TextField("Message", text: $text)
                    Button("Send") {
                        if store.send(text: text) { text = "" }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if store.link != .reachable {
                        Text("iPhone not reachable. A message you send now stays queued and goes out when it reconnects. Discard it to cancel.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            } else {
                Text("Pick a machine and bot from the context header first. Nothing is sent to a default.")
                    .font(.footnote)
            }
            Section("Delivery") {
                if store.outbox.messages.isEmpty { Text("No messages yet").font(.footnote) }
                ForEach(store.outbox.messages.reversed()) { OutboxRow(store: store, message: $0) }
            }
        }
        .navigationTitle("Messages")
    }
}

struct OutboxRow: View {
    let store: WatchStore
    let message: WatchOutboxMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message.targetLabel).font(.caption2).foregroundStyle(.secondary)
            Text(message.request.text).font(.footnote).lineLimit(2)
            Label(message.state.userText, systemImage: message.state.symbol).font(.caption2)
            switch message.state {
            case .failed:
                HStack {
                    Button("Send again") { store.retry(message.id) }
                    Button("Discard", role: .destructive) { store.discard(message.id) }
                }.font(.caption2)
            case .uncertain:
                Text("Not resent automatically. Check the chat on iPhone, or send again.").font(.caption2).foregroundStyle(.orange)
                HStack {
                    Button("Send again") { store.retry(message.id) }
                    Button("Discard", role: .destructive) { store.discard(message.id) }
                }.font(.caption2)
            case .acknowledged:
                Button("Clear") { store.discard(message.id) }.font(.caption2)
            case .queued, .sentToPhone: EmptyView()
            }
        }
    }
}

// MARK: - Labels

extension WatchGatewayStatus {
    var label: String {
        switch self {
        case .online: return "Online"
        case .connecting: return "Connecting"
        case .degraded: return "Degraded"
        case .authenticationRequired: return "Sign-in needed (iPhone)"
        case .offline: return "Offline"
        case .unsupported: return "Unsupported"
        }
    }
    var symbol: String {
        switch self {
        case .online: return "checkmark.circle"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .degraded: return "exclamationmark.circle"
        case .authenticationRequired: return "person.crop.circle.badge.exclamationmark"
        case .offline: return "wifi.slash"
        case .unsupported: return "questionmark.circle"
        }
    }
}

extension WatchCoverage {
    var label: String {
        switch self {
        case .reporting: return "reporting"
        case .limited: return "limited"
        case .heldOver: return "held-over"
        case .unknown: return "unknown"
        }
    }
    var explanation: String {
        switch self {
        case .reporting: return ""
        case .limited: return "Limited coverage: this machine can't report running work."
        case .heldOver: return "Not reporting now. Showing last known data."
        case .unknown: return "Never observed."
        }
    }
}

extension WatchApprovalOutcome {
    var userText: String {
        switch self {
        case .applied: return "Done. The machine confirmed your answer."
        case .alreadyResolved: return "Already resolved elsewhere. Nothing was changed."
        case .expired: return "Expired. That request is gone. Nothing was changed."
        case .changed: return "The request changed, so nothing was sent. Review it again."
        case .staleSnapshot: return "Out of date. Refreshing. Nothing was sent."
        case .handOffToPhone(let reason): return "Use iPhone: \(reason)"
        case .unavailable(let reason): return "Unavailable: \(reason) Nothing was sent."
        case .duplicate: return "Already handled. No duplicate was sent."
        case .uncertain(let reason): return "Unconfirmed: \(reason) Check iPhone before retrying."
        case .failed(let reason): return "Failed: \(reason)"
        }
    }
}

extension WatchMessageState {
    var userText: String {
        switch self {
        case .queued: return "Queued on Watch. Not sent yet."
        case .sentToPhone: return "Sent to iPhone. Awaiting confirmation…"
        case .acknowledged: return "Delivered. The machine acknowledged it."
        case .failed(let reason): return "Not delivered: \(reason)"
        case .uncertain(let reason): return "Delivery unknown: \(reason)"
        }
    }
    var symbol: String {
        switch self {
        case .queued: return "tray"
        case .sentToPhone: return "arrow.up.right.circle"
        case .acknowledged: return "checkmark.circle.fill"
        case .failed: return "xmark.circle"
        case .uncertain: return "questionmark.circle"
        }
    }
}
