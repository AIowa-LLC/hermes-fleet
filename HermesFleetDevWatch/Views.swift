import SwiftUI
import FleetWatchKit

// MARK: - Shared

/// Lock-screen / always-on dimmed Watch: names, commands and message text are
/// shown as placeholders on every screen, not only the root.
private struct DimRedacted: ViewModifier {
    @Environment(\.isLuminanceReduced) private var dimmed
    func body(content: Content) -> some View {
        content.redacted(reason: dimmed ? .placeholder : [])
    }
}

extension View {
    fileprivate func dimRedacted() -> some View { modifier(DimRedacted()) }
}

// MARK: - Root

struct RootView: View {
    let store: WatchStore

    var body: some View {
        NavigationStack {
            List {
                if store.isFixture { MockBanner() }
                ContextHeader(store: store)
                ConnectionRows(store: store)
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
            .dimRedacted()
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

/// The current destination. Tapping it opens the machine → bot → chat picker
/// from every screen, so the destination can be changed where it matters.
struct ContextHeader: View {
    let store: WatchStore
    @State private var showPicker = false

    var body: some View {
        Button { showPicker = true } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Destination · tap to change").font(.caption2).foregroundStyle(.secondary)
                Text(store.contextLabel).font(.footnote.bold()).lineLimit(3)
            }
        }
        .accessibilityLabel("Destination \(store.contextLabel). Change.")
        .sheet(isPresented: $showPicker) { ContextPickerView(store: store) }
    }
}

/// Two separate facts that must never be merged into one "connected" claim:
/// the Watch's link to the iPhone, and how recently the iPhone sent a
/// snapshot. Gateway reachability and per-source freshness are shown where the
/// machine is shown.
struct ConnectionRows: View {
    let store: WatchStore

    var body: some View {
        let age = WatchFreshnessPolicy.ageLabel(observedAt: store.snapshot?.builtAt, now: store.now)
        VStack(alignment: .leading, spacing: 2) {
            switch store.link {
            case .reachable: Label("Watch ↔ iPhone: connected", systemImage: "iphone.gen3")
            case .phoneUnreachable: Label("iPhone not reachable. Showing saved data.", systemImage: "iphone.slash")
            case .notActivated: Label("Connecting to iPhone…", systemImage: "iphone")
            case .companionMissing: Label("iPhone app not found", systemImage: "iphone.slash")
            }
            if store.snapshot != nil {
                // When the iPhone SENT this; the machines' own data carries its own ages.
                Label("Synced from iPhone \(age)", systemImage: store.syncFreshness == .stale ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(store.syncFreshness == .stale ? .orange : .secondary)
            }
            if store.lastRefreshFailed {
                Label("Last refresh failed. Showing earlier data.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2)
    }
}

struct SourceRow: View {
    let name: String
    let state: WatchSourceState
    let observedAt: Date?
    let now: Date

    var body: some View {
        let age = WatchFreshnessPolicy.ageLabel(observedAt: observedAt, now: now)
        HStack(alignment: .firstTextBaseline) {
            Text(name)
            Spacer(minLength: 4)
            Text(state == .neverObserved ? state.label : "\(state.label) · \(age)")
                .foregroundStyle(state == .current ? Color.secondary : Color.orange)
        }
        .font(.caption2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Context picker (Machine → Bot → Overview / Main chat / Conversation)

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
                                Text(gateway.status.reachability).font(.caption2)
                                    .foregroundStyle(gateway.status == .online ? Color.secondary : Color.orange)
                            }
                        }
                    }
                } else {
                    Text("No machines yet. Add them on iPhone.").font(.footnote)
                }
                Text("Machines are managed on iPhone.").font(.caption2).foregroundStyle(.secondary)
            }
            .navigationTitle("Machine")
            .dimRedacted()
        }
    }
}

struct BotPickerView: View {
    let store: WatchStore
    let gateway: WatchGateway
    let dismissAll: () -> Void

    var body: some View {
        List {
            Section {
                SourceRow(name: "Bots", state: store.rosterState(gateway), observedAt: gateway.rosterObservedAt, now: store.now)
            }
            Button("Whole machine (status only)") {
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
        .dimRedacted()
    }
}

/// Three different things, kept visibly apart: the bot overview (status only,
/// can't be messaged), the bot's Main chat, and its named conversations.
struct ConversationPickerView: View {
    let store: WatchStore
    let gateway: WatchGateway
    let bot: WatchBot
    let dismissAll: () -> Void

    var body: some View {
        List {
            Section("Bot overview") {
                Button("Overview · status only") {
                    store.selection = .init(gatewayID: gateway.id, profileSlug: bot.ref.profileSlug)
                    dismissAll()
                }
            }
            Section("Main chat") {
                if let main = bot.mainChat {
                    Button("Main chat") { choose(main) }
                } else {
                    Label("Main chat isn't set up yet. Establish it on iPhone, then refresh.", systemImage: "iphone")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Section("Conversations") {
                let named = bot.conversations.filter { !$0.isMain }
                if named.isEmpty { Text("None reported").font(.caption2).foregroundStyle(.secondary) }
                ForEach(named) { conversation in
                    Button(conversation.title) { choose(conversation) }
                }
                if bot.omittedConversationCount > 0 {
                    Text("Showing \(bot.conversations.count) of \(bot.totalConversations ?? bot.conversations.count). Others: use iPhone.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                SourceRow(name: "List", state: store.conversationsState(gateway),
                          observedAt: gateway.conversationsObservedAt, now: store.now)
            }
        }
        .navigationTitle(bot.displayName)
        .dimRedacted()
    }

    private func choose(_ conversation: WatchConversation) {
        store.selection = .init(gatewayID: gateway.id, profileSlug: bot.ref.profileSlug, conversationID: conversation.id)
        // Tell the phone, so it keeps this chat in the capped snapshot.
        Task { await store.refresh() }
        dismissAll()
    }
}

// MARK: - Check in

struct StatusView: View {
    let store: WatchStore

    var body: some View {
        List {
            ContextHeader(store: store)
            ConnectionRows(store: store)
            if let snapshot = store.snapshot {
                switch store.resolution {
                case .unselected:
                    Text("Tap the destination above to choose a machine.").font(.footnote)
                case .gatewayMissing, .botMissing, .conversationMissing:
                    Text("Your selected destination is no longer available. Choose another. Nothing was substituted.")
                        .font(.footnote).foregroundStyle(.orange)
                case .conversationNotShown(_, _, let omitted):
                    Text("Your chat isn't in the list the iPhone sent (\(omitted) more than shown). It was not removed. Refresh to bring it back.")
                        .font(.footnote).foregroundStyle(.orange)
                    Button("Refresh") { Task { await store.refresh() } }
                case .resolved(let gateway, _, _):
                    gatewaySection(gateway)
                    let others = snapshot.attention.filter { $0.gatewayID != gateway.id }.count
                    if others > 0 { Text("\(others) item\(others == 1 ? "" : "s") need attention on other machines.").font(.caption2) }
                }
            }
        }
        .navigationTitle("Check in")
        .dimRedacted()
        .refreshable { await store.refresh() }
    }

    @ViewBuilder
    private func gatewaySection(_ gateway: WatchGateway) -> some View {
        Section("iPhone → \(gateway.displayName)") {
            Label(gateway.status.reachability, systemImage: gateway.status.symbol)
            if gateway.status != .online {
                Text("Cached information below may be out of date. This is the iPhone's connection, not proof the computer is off.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            SourceRow(name: "Bots", state: store.rosterState(gateway), observedAt: gateway.rosterObservedAt, now: store.now)
            SourceRow(name: "Chats", state: store.conversationsState(gateway), observedAt: gateway.conversationsObservedAt, now: store.now)
            SourceRow(name: "Running work", state: store.liveState(gateway), observedAt: gateway.observedAt, now: store.now)
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
        let scoped = all.filter { WatchApprovalScope.isInContext($0, resolution) }
        let others = all.filter { a in !scoped.contains { $0.id == a.id } }
        List {
            ContextHeader(store: store)
            ConnectionRows(store: store)
            Section("This context") {
                if scoped.isEmpty { Text("No pending approvals here").font(.footnote) }
                ForEach(scoped) { link($0) }
            }
            if !others.isEmpty {
                Section("Other machines, bots or chats") {
                    ForEach(others) { link($0) }
                }
            }
        }
        .navigationTitle("Approvals")
        .dimRedacted()
        .refreshable { await store.refresh() }
    }

    private func link(_ approval: WatchApproval) -> some View {
        NavigationLink { ApprovalDetailView(store: store, approval: approval) } label: {
            VStack(alignment: .leading) {
                Text("\(approval.gatewayName) › \(approval.botName ?? "unknown bot") › \(approval.sessionLabel)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Text(approval.commandPreview).font(.footnote).lineLimit(2)
            }
        }
    }
}

struct ApprovalDetailView: View {
    let store: WatchStore
    let approval: WatchApproval

    var body: some View {
        let state = store.approvalStates[approval.id]
        let presence = store.approvalPresence(approval)
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
            ConnectionRows(store: store)
            SourceRow(name: "Approval seen",
                      state: approval.observedAt == nil ? .neverObserved
                          : (WatchFreshnessPolicy.approvalActionable(observedAt: approval.observedAt, now: store.now) ? .current : .stale),
                      observedAt: approval.observedAt, now: store.now)
            actions(state: state, presence: presence)
        }
        .dimRedacted()
        .navigationTitle("Approval")
    }

    @ViewBuilder
    private func actions(state: ApprovalActionState?, presence: WatchApprovalPresence) -> some View {
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
            switch presence {
            case .resolved:
                Text("No longer pending. The machine is reporting and doesn't list it.").font(.footnote)
            case .unverifiable(let reason):
                Label(reason, systemImage: "questionmark.circle").font(.footnote).foregroundStyle(.orange)
                Text("Not actionable until confirmed. Open on iPhone or refresh.").font(.caption2)
                Button("Refresh") { Task { await store.refresh() } }
            case .pending:
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

    var body: some View {
        List {
            ContextHeader(store: store)
            ConnectionRows(store: store)
            Section("New message") {
                if let error = store.outboxPersistenceError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                }
                if let reason = store.sendBlockReason {
                    Text(reason).font(.footnote)
                    if store.selectedBotLacksMainChat {
                        Label("This bot has no Main chat yet. Establish it on iPhone. The Watch never creates one.", systemImage: "iphone")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                } else {
                    // The exact frozen destination, shown right above the Send button.
                    Text("To: \(store.contextLabel)").font(.footnote.bold())
                    TextField("Message", text: $text)
                    Button("Send") {
                        if store.send(text: text) { text = "" }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if store.link != .reachable {
                        Text("iPhone not reachable. A message you send now stays queued, unsent, and goes out when it reconnects. Discard it to cancel.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            Section("Delivery") {
                if store.outbox.messages.isEmpty { Text("No messages yet").font(.footnote) }
                ForEach(store.outbox.messages.reversed()) { OutboxRow(store: store, message: $0) }
            }
        }
        .navigationTitle("Messages")
        .dimRedacted()
    }
}

struct OutboxRow: View {
    let store: WatchStore
    let message: WatchOutboxMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Frozen at compose time; later context changes never relabel it.
            Text("To: \(message.targetLabel)").font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            Text(message.request.text).font(.footnote).lineLimit(2)
            Label(message.state.userText, systemImage: message.state.symbol).font(.caption2)
            if let diagnostic = message.diagnostic, message.state != .acknowledged {
                Text("Step: \(diagnostic)").font(.caption2).foregroundStyle(.secondary)
            }
            switch message.state {
            case .queued:
                Button("Discard", role: .destructive) { store.discard(message.id) }.font(.caption2)
            case .sentToPhone:
                EmptyView()
            case .failed:
                Text("Known not to have reached the gateway, so it is safe to send again.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Send again") { store.retry(message.id) }.font(.caption2)
                Button("Discard", role: .destructive) { store.discard(message.id) }.font(.caption2)
            case .uncertain:
                Text("It may already have been sent, so the Watch won't resend it. Check this chat on iPhone, or discard.")
                    .font(.caption2).foregroundStyle(.orange)
                Button("Discard", role: .destructive) { store.discard(message.id) }.font(.caption2)
            case .acknowledged:
                Text("Reply isn't shown here. Open this chat on iPhone.").font(.caption2).foregroundStyle(.secondary)
                Button("Clear") { store.discard(message.id) }.font(.caption2)
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
        case .notConnected: return "Not connected"
        }
    }
    /// What the status actually means: the iPhone's connection to the gateway.
    var reachability: String {
        switch self {
        case .online: return "Reachable from iPhone"
        case .connecting: return "iPhone is connecting…"
        case .degraded: return "Reachable from iPhone, degraded"
        case .authenticationRequired: return "Sign-in needed on iPhone"
        case .offline: return "Unreachable from iPhone"
        case .unsupported: return "Unsupported by this iPhone build"
        case .notConnected: return "iPhone isn't connected to it"
        }
    }
    var symbol: String {
        switch self {
        case .online: return "checkmark.circle"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .degraded: return "exclamationmark.circle"
        case .authenticationRequired: return "person.crop.circle.badge.exclamationmark"
        case .offline: return "wifi.slash"
        case .unsupported, .notConnected: return "questionmark.circle"
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
        case .queued: return "Queued on Watch. Never sent."
        case .sentToPhone: return "Handed to iPhone. Awaiting the gateway…"
        case .acknowledged: return "Accepted by the gateway. Not a reply."
        case .failed(let reason): return "Not sent: \(reason)"
        case .uncertain(let reason): return "Unknown if sent: \(reason)"
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
