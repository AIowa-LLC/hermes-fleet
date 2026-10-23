import SwiftUI
import FleetCore

/// One inbox item, decidable without opening its session: the full command or
/// question, the agent identity, the choices the gateway offered, and the
/// decision record for this item. Decisions go through `InboxStore.decide`,
/// which owns the presence check, review gate, and gateway routing.
struct FleetInboxDetailView: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let environment: AppEnvironment
    let itemID: InboxItemID

    @State private var busy = false
    @State private var errorText: String?
    @State private var answer = ""
    @State private var secretValue = ""
    @State private var reviewing = false
    /// Set once the user has read the whole command in this sheet. The store
    /// keeps its own review record; this gates the button before any call.
    @State private var reviewedHere = false
    /// An approve the store refused with `.reviewRequired`. Retried once the
    /// user has reviewed the full command.
    @State private var retryAfterReview: InboxDecision?

    private var item: InboxItem? {
        environment.inbox.items.first { $0.id == itemID }
    }

    private var reachable: Bool {
        guard let item else { return false }
        return environment.connectionStates[item.agent.gatewayID] == .connected
    }

    var body: some View {
        NavigationStack {
            Group {
                if let item {
                    content(for: item)
                } else {
                    ContentUnavailableView(
                        "No longer in the inbox",
                        systemImage: "tray",
                        description: Text("This request was answered or withdrawn."))
                        .accessibilityIdentifier("fleet.inbox.detail.gone")
                }
            }
            .navigationTitle(item.map { FleetInboxPresentation.kindTitle($0.kind) } ?? "Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("fleet.inbox.detail.close")
                }
            }
            .background(theme.background)
            .sheet(isPresented: $reviewing) {
                if let item, let command = item.context.command {
                    ApprovalReviewSheet(
                        origin: origin(for: item),
                        command: command,
                        detail: item.context.detail,
                        isReviewed: reviewedHere
                    ) {
                        reviewedHere = true
                        environment.inbox.markReviewed(itemID)
                        if let retry = retryAfterReview {
                            retryAfterReview = nil
                            decide(retry)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("fleet.inbox.detail")
    }

    @ViewBuilder
    private func content(for item: InboxItem) -> some View {
        let availability = FleetInboxPresentation.availability(for: item, reachable: reachable)
        ScrollView {
            VStack(alignment: .leading, spacing: FleetTheme.spacingLg) {
                header(item)
                if FleetInboxPresentation.isOffline(connected: connectedSet) {
                    offlineNote
                }
                contextBlock(item)
                // Pending decisions stay on screen; when no gateway can receive
                // them they are shown disabled, never hidden.
                if item.status == .pending, item.kind == .approval {
                    approveBlock(item, enabled: availability.canApprove)
                }
                if item.status == .pending, item.kind != .approval, !availability.answersInSessionOnly {
                    answerBlock(item)
                        .disabled(!availability.canAnswer)
                }
                if availability.answersInSessionOnly {
                    Text("Batch questions are answered one at a time in their conversation.")
                        .font(.footnote)
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityIdentifier("fleet.inbox.detail.batch.note")
                }
                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(FleetTheme.statusNeedsIntervention)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fleet.inbox.detail.error")
                }
                sessionButton(item)
                decisionRecords
            }
            .padding(FleetTheme.spacingLg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("fleet.inbox.detail.scroll")
    }

    private var connectedSet: Set<GatewayID> {
        FleetInboxPresentation.connectedGatewayIDs(
            gatewayIDs: environment.gateways.map(\.id),
            state: { environment.connectionStates[$0] ?? .idle })
    }

    // MARK: Sections

    private func header(_ item: InboxItem) -> some View {
        let chip = FleetInboxPresentation.chip(for: item)
        // The kind is the nav title (one heading only); the body carries the
        // agent identity, the session title when known, and the status.
        return VStack(alignment: .leading, spacing: 6) {
            Text(FleetInboxPresentation.agentLine(item))
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
                .accessibilityIdentifier("fleet.inbox.detail.agent")
            if let session = FleetInboxPresentation.sessionLine(item) {
                Text(session)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("fleet.inbox.detail.session")
            }
            Text(chip.text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.textSecondary)
                .accessibilityIdentifier("fleet.inbox.detail.status")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var offlineNote: some View {
        Label {
            Text("This gateway is offline. Pending items may be out of date, and decisions can't be sent until it reconnects.")
                .font(.footnote)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "wifi.slash")
                .foregroundStyle(FleetTheme.statusNeedsIntervention)
                .accessibilityHidden(true)
        }
        .accessibilityIdentifier("fleet.inbox.detail.offline")
    }

    @ViewBuilder
    private func contextBlock(_ item: InboxItem) -> some View {
        switch item.kind {
        case .approval:
            if let command = item.context.command {
                VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                    Text("Command")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textSecondary)
                    ApprovalCommandPreviewView(command: command) {
                        reviewing = true
                    }
                }
            }
            if let detail = item.context.detail, !detail.isEmpty {
                ApprovalUntrustedDetail(detail: detail)
            }
        case .sudo:
            if let command = item.context.command {
                VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                    Text("Command that needs sudo")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textSecondary)
                    ApprovalCommandPreviewView(command: command) {
                        reviewing = true
                    }
                }
            } else {
                Text("The agent needs your sudo password to continue.")
                    .font(.body)
                    .foregroundStyle(theme.textPrimary)
            }
        case .question:
            if let text = item.context.detail, !text.isEmpty {
                Text(text)
                    .font(.body)
                    .foregroundStyle(theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("fleet.inbox.detail.question")
            }
        case .secret:
            VStack(alignment: .leading, spacing: 4) {
                Text("Secret requested: \(item.context.envVarName ?? "value")")
                    .font(FleetTheme.monoFont)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityIdentifier("fleet.inbox.detail.secret.name")
                if let prompt = item.context.detail, !prompt.isEmpty {
                    Text(prompt)
                        .font(.footnote)
                        .foregroundStyle(theme.textSecondary)
                }
                Text("The value is sent to the gateway once and is never stored or shown here.")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    // MARK: Approve and deny

    private func approveBlock(_ item: InboxItem, enabled: Bool) -> some View {
        let needsReview = FleetInboxPresentation.requiresReview(item)
        let approveEnabled = enabled && !busy && (!needsReview || reviewedHere)
        return VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            if needsReview && !reviewedHere {
                Text("Approve stays off until you review the full command. Deny is always available.")
                    .font(.caption)
                    .foregroundStyle(FleetTheme.statusNeedsIntervention)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fleet.inbox.detail.review.hint")
            }
            ForEach(FleetInboxPresentation.approveChoices(for: item), id: \.self) { choice in
                Button {
                    decide(.approve(choice))
                } label: {
                    Label(FleetInboxPresentation.approveTitle(choice), systemImage: "faceid")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.highlight)
                .disabled(!approveEnabled)
                .accessibilityIdentifier(approveIdentifier(choice))
            }
            Text("Requires Face ID or your device passcode")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
            Button(role: .destructive) {
                decide(.deny)
            } label: {
                Text("Deny")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!enabled || busy)
            .accessibilityIdentifier("fleet.inbox.detail.deny")
        }
    }

    private func approveIdentifier(_ choice: ApprovalChoice) -> String {
        switch choice {
        case .once: "fleet.inbox.detail.approve"
        case .session: "fleet.inbox.detail.approve-session"
        case .always: "fleet.inbox.detail.approve-always"
        case .deny: "fleet.inbox.detail.deny"
        }
    }

    // MARK: Answer

    @ViewBuilder
    private func answerBlock(_ item: InboxItem) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            switch item.kind {
            case .question:
                ForEach(FleetInboxPresentation.answerChoices(item), id: \.self) { choice in
                    Button(choice) { decide(.answer(choice)) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(busy)
                        .accessibilityIdentifier("fleet.inbox.detail.choice")
                }
                TextField("Your answer", text: $answer, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("fleet.inbox.detail.answer.field")
                answerButtons(send: answer, sendID: "fleet.inbox.detail.answer.send") { value in
                    decide(.answer(value))
                }
            case .sudo:
                SecureField("Sudo password", text: $secretValue)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .accessibilityIdentifier("fleet.inbox.detail.sudo.field")
                answerButtons(send: secretValue, sendID: "fleet.inbox.detail.sudo.send") { value in
                    decide(.answer(value))
                }
            case .secret:
                SecureField("Value", text: $secretValue)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .accessibilityIdentifier("fleet.inbox.detail.secret.field")
                answerButtons(send: secretValue, sendID: "fleet.inbox.detail.secret.send") { value in
                    decide(.answer(value))
                }
            case .approval:
                EmptyView()
            }
            if item.kind == .sudo || item.kind == .secret {
                Text("Approval with Face ID or your device passcode is needed before the value is sent.")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private func answerButtons(
        send value: String,
        sendID: String,
        onSend: @escaping (String) -> Void
    ) -> some View {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(spacing: FleetTheme.spacingMd) {
            Button("Skip") { decide(.skip) }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .disabled(busy)
                .accessibilityIdentifier("fleet.inbox.detail.skip")
            Button("Send") { onSend(value) }
                .buttonStyle(.borderedProminent)
                .tint(theme.highlight)
                .frame(minHeight: 44)
                .disabled(busy || trimmed.isEmpty)
                .accessibilityIdentifier(sendID)
        }
    }

    // MARK: Session and records

    @ViewBuilder
    private func sessionButton(_ item: InboxItem) -> some View {
        let route = FleetInboxPresentation.route(for: item, in: environment.sessionsByRoute)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard let route else { return }
                dismiss()
                environment.requestScreen(.conversation(route, sessionID: item.agent.sessionID, canonical: false))
            } label: {
                Label("Open session", systemImage: "bubble.left.and.bubble.right")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(route == nil)
            .accessibilityIdentifier("fleet.inbox.detail.open-session")
            if route == nil {
                Text("This session isn't loaded on this device yet.")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("fleet.inbox.detail.open-session.unavailable")
            }
        }
    }

    @ViewBuilder
    private var decisionRecords: some View {
        let records = FleetInboxPresentation.audit(environment.inbox.auditTrail, for: itemID)
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                Text("Decisions on this request")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.textSecondary)
                ForEach(records) { record in
                    FleetInboxAuditRow(record: record)
                }
            }
            .accessibilityIdentifier("fleet.inbox.detail.records")
        }
    }

    // MARK: Actions

    private func origin(for item: InboxItem) -> ApprovalOrigin {
        ApprovalOrigin(
            gateway: item.agent.gatewayLabel,
            bot: item.agent.profileName,
            cwd: nil,
            session: FleetInboxPresentation.sessionLine(item),
            gatewayID: item.agent.gatewayID)
    }

    private func decide(_ decision: InboxDecision) {
        guard !busy else { return }
        busy = true
        errorText = nil
        Task {
            do {
                _ = try await environment.inbox.decide(itemID, decision)
                busy = false
                switch decision {
                case .answer, .skip:
                    answer = ""
                    secretValue = ""
                default:
                    break
                }
                dismiss()
            } catch InboxError.reviewRequired {
                busy = false
                reviewedHere = false
                retryAfterReview = decision
                reviewing = true
            } catch {
                busy = false
                if let item, FleetInboxPresentation.needsOpenSession(error, item: item) {
                    // Live server requests are answered only from their open
                    // conversation. The session button below is the way there;
                    // once it is open the store accepts the decision again.
                    errorText = FleetInboxPresentation.openSessionToAnswerMessage
                } else {
                    errorText = FleetInboxPresentation.message(for: error)
                }
                AccessibilityNotification.Announcement(errorText ?? "").post()
            }
        }
    }
}
