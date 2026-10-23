import SwiftUI
import FleetCore

/// Phase B approvals inbox: every decision an agent is waiting on, from every
/// connected gateway, in one place. Pending first (newest first), then history.
/// Pushed on the Fleet stack (`FleetScreen.inbox`); reached from the drawer or
/// a deep link (`FleetInboxDeepLink`).
struct FleetInboxView: View {
    @Environment(\.fleetTheme) private var theme
    let environment: AppEnvironment

    @State private var loaded = false
    @State private var selection: InboxSelection?
    @State private var showingAudit = false
    @State private var focusMissing = false

    private var inbox: InboxStore { environment.inbox }

    private var sections: FleetInboxPresentation.Sections {
        FleetInboxPresentation.sections(inbox.items)
    }

    private var connectedGateways: Set<GatewayID> {
        FleetInboxPresentation.connectedGatewayIDs(
            gatewayIDs: environment.gateways.map(\.id),
            state: { environment.connectionStates[$0] ?? .idle })
    }

    private var offline: Bool {
        FleetInboxPresentation.isOffline(connected: connectedGateways)
    }

    var body: some View {
        Group {
            if !loaded {
                ProgressView("Loading approvals…")
                    .accessibilityIdentifier("fleet.inbox.loading")
            } else if inbox.items.isEmpty {
                VStack(spacing: 0) {
                    if offline { offlineBanner }
                    emptyState
                }
            } else {
                list
            }
        }
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAudit = true
                } label: {
                    Label("Decision log", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("fleet.inbox.audit.open")
            }
        }
        .background(theme.background)
        // AX rule (see FleetNavigationDrawer): a container identifier without
        // `.contain` swallows every descendant identifier from the tree.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet.inbox")
        .task {
            await inbox.awaitLoaded()
            loaded = true
            consumeFocus()
        }
        // Presence: while the Inbox is on screen, its requests do not notify.
        .onAppear {
            Task { await environment.inboxNotifications.setInboxVisible(true) }
        }
        .onDisappear {
            Task { await environment.inboxNotifications.setInboxVisible(false) }
        }
        .onChange(of: environment.pendingInboxFocus) { _, _ in
            consumeFocus()
        }
        .refreshable {
            await inbox.refresh()
        }
        .sheet(item: $selection) { selected in
            FleetInboxDetailView(environment: environment, itemID: selected.id)
        }
        .sheet(isPresented: $showingAudit) {
            FleetInboxAuditView(environment: environment)
        }
    }

    // MARK: List

    private var list: some View {
        List {
            if offline {
                Section {
                    offlineBanner
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            if focusMissing {
                Section {
                    Text("That request is no longer in the inbox. It may have been answered or withdrawn.")
                        .font(.footnote)
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityIdentifier("fleet.inbox.focus.missing")
                }
            }
            pendingSection
            if !sections.history.isEmpty {
                historySection
            }
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("fleet.inbox.list")
    }

    /// Section headings are ordinary identified rows: a List header does not
    /// carry its identifier into the accessibility tree.
    @ViewBuilder
    private var pendingSection: some View {
        Section {
            sectionHeading("Pending · \(sections.pending.count)", identifier: "fleet.inbox.section.pending")
            if sections.pending.isEmpty {
                Label("Nothing is waiting on you.", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("fleet.inbox.pending.empty")
            } else {
                ForEach(sections.pending) { item in
                    row(item)
                }
            }
        }
    }

    private var historySection: some View {
        Section {
            sectionHeading("History", identifier: "fleet.inbox.section.history")
            ForEach(sections.history) { item in
                row(item)
            }
        }
    }

    private func sectionHeading(_ title: String, identifier: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(identifier)
    }

    private func row(_ item: InboxItem) -> some View {
        Button {
            selection = InboxSelection(id: item.id)
        } label: {
            FleetInboxRow(item: item)
        }
        .buttonStyle(.plain)
        .opacity(FleetInboxPresentation.isDimmed(item) ? 0.55 : 1)
        .accessibilityIdentifier("fleet.inbox.row.\(item.id.rawValue)")
    }

    // MARK: States

    private var emptyState: some View {
        // The identifier sits on a plain container: ContentUnavailableView
        // does not carry an identifier of its own into the accessibility tree.
        VStack(spacing: 0) {
            ContentUnavailableView {
                Label("No agent is waiting on you", systemImage: "tray")
            } description: {
                Text("When an agent needs a command approved, a question answered, or a secret, it appears here. Requests from every connected gateway and conversation land in this one place.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet.inbox.empty")
    }

    private var offlineBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(FleetInboxPresentation.offlineTitle, systemImage: "wifi.slash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FleetTheme.statusNeedsIntervention)
            Text(FleetInboxPresentation.offlineBody)
                .font(.footnote)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FleetTheme.spacingMd)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow))
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, FleetTheme.spacingSm)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.inbox.offline")
    }

    // MARK: Deep link

    /// Opens the detail for a deep-linked item once it is in the list.
    private func consumeFocus() {
        guard let focus = environment.pendingInboxFocus else { return }
        environment.pendingInboxFocus = nil
        if inbox.items.contains(where: { $0.id == focus }) {
            focusMissing = false
            selection = InboxSelection(id: focus)
        } else {
            focusMissing = true
        }
    }
}

/// Identifiable wrapper so the detail sheet can be driven by `sheet(item:)`.
struct InboxSelection: Identifiable, Equatable {
    let id: InboxItemID
}

// MARK: - Row

/// One inbox row: kind, action summary, agent identity, session, relative time,
/// and a status chip. Expired and withdrawn rows carry their reason.
private struct FleetInboxRow: View {
    @Environment(\.fleetTheme) private var theme
    let item: InboxItem

    private var chip: FleetInboxPresentation.Chip { FleetInboxPresentation.chip(for: item) }

    var body: some View {
        HStack(alignment: .top, spacing: FleetTheme.spacingMd) {
            Image(systemName: FleetInboxPresentation.symbol(for: item.kind))
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                summary
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(FleetInboxPresentation.agentLine(item))
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                if let session = FleetInboxPresentation.sessionLine(item) {
                    Text(session)
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: FleetTheme.spacingSm) {
                    statusChip
                    if let reason = FleetInboxPresentation.dimmedReason(item), reason != chip.text {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Text(timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var summary: some View {
        let text = FleetInboxPresentation.actionSummary(item)
        if FleetInboxPresentation.summaryIsCommand(item) {
            Text(text)
                .font(FleetTheme.monoFont)
                .foregroundStyle(theme.textPrimary)
        } else {
            Text(text)
                .font(.body.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
        }
    }

    private var statusChip: some View {
        Text(chip.text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(chipColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(chipColor.opacity(0.14), in: Capsule())
    }

    private var tint: Color {
        item.status == .pending ? FleetTheme.statusNeedsIntervention : theme.textSecondary
    }

    private var chipColor: Color {
        switch chip.tone {
        case .attention: FleetTheme.statusNeedsIntervention
        case .success: FleetTheme.statusOnline
        case .destructive: FleetTheme.statusDestructive
        case .muted: theme.textSecondary
        }
    }

    private var timestamp: Date {
        item.status == .pending ? item.createdAt : item.updatedAt
    }

    private var accessibilityText: String {
        var parts = [
            FleetInboxPresentation.kindTitle(item.kind),
            FleetInboxPresentation.actionSummary(item),
            FleetInboxPresentation.agentLine(item),
        ]
        if let session = FleetInboxPresentation.sessionLine(item) { parts.append(session) }
        parts.append(chip.text)
        if let reason = FleetInboxPresentation.dimmedReason(item) { parts.append(reason) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Audit

/// Every decision this device has recorded, newest first. Values (answers,
/// secrets) and command text are never part of a record.
struct FleetInboxAuditView: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let environment: AppEnvironment

    var body: some View {
        NavigationStack {
            Group {
                if environment.inbox.auditTrail.isEmpty {
                    ContentUnavailableView(
                        "No decisions yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Decisions made from the inbox appear here with their outcome."))
                        .accessibilityIdentifier("fleet.inbox.audit.empty")
                } else {
                    List(environment.inbox.auditTrail) { record in
                        FleetInboxAuditRow(record: record)
                            .accessibilityIdentifier("fleet.inbox.audit.row.\(record.id.uuidString)")
                    }
                    .accessibilityIdentifier("fleet.inbox.audit.list")
                }
            }
            .navigationTitle("Decision log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("fleet.inbox.audit.close")
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
        }
        .accessibilityIdentifier("fleet.inbox.audit")
    }
}

/// One audit line: action, agent, decider, time, and gateway outcome.
struct FleetInboxAuditRow: View {
    @Environment(\.fleetTheme) private var theme
    let record: InboxDecisionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(FleetInboxPresentation.actionTitle(record.action))
                .font(.body.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
            Text("\(record.agentLabel) · \(FleetInboxPresentation.deciderTitle(record.decider))")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
            HStack(spacing: FleetTheme.spacingSm) {
                Text(FleetInboxPresentation.outcomeTitle(record.outcome))
                    .font(.caption)
                    .foregroundStyle(FleetInboxPresentation.outcomeFailed(record.outcome)
                                     ? FleetTheme.statusDestructive : theme.textSecondary)
                Spacer(minLength: 0)
                Text(record.decidedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
