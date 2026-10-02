import SwiftUI
import FleetCore

/// P0.1 — minimal card for clarify / sudo / secret requests, styled like
/// `ApprovalBanner` (a separate issue redesigns the approval card; this stays
/// deliberately plain).
///
/// - Skipping is one tap and never needs Face ID.
/// - sudo / secret entry is hidden behind a Face ID unlock, uses a
///   `SecureField`, and the whole card is `.privacySensitive()`.
/// - The typed value lives only in the entry subview's `@State`, is cleared the
///   moment it is submitted, and is never handed to the view model's stored
///   state.
public struct ServerPromptCard: View {
    @Environment(\.fleetTheme) private var theme
    @Bindable var model: ServerPromptViewModel

    public init(model: ServerPromptViewModel) {
        self.model = model
    }

    public var body: some View {
        if let request = model.pending {
            card(for: request)
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            EmptyView()
        }
    }

    private func card(for request: ServerRequest) -> some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            header(for: request)
            switch request.kind {
            case .clarify(let prompt):
                ClarifyEditor(model: model, requestID: request.id, prompt: prompt)
                    .id(request.id)
            case .sudo(let prompt):
                ValueEntry(
                    model: model,
                    requestID: request.id,
                    title: "The agent needs your sudo password to run:",
                    detail: prompt.command,
                    detailIsMono: true,
                    fieldLabel: "sudo password")
                    .id(request.id)
            case .secret(let prompt):
                ValueEntry(
                    model: model,
                    requestID: request.id,
                    title: prompt.prompt.isEmpty
                        ? "The agent needs a value for \(prompt.envVar)."
                        : prompt.prompt,
                    detail: prompt.envVar,
                    detailIsMono: true,
                    fieldLabel: "Secret value")
                    .id(request.id)
            case .approval:
                EmptyView()
            }
            statusHint
        }
        .padding(FleetTheme.spacingMd)
        .background(
            theme.surface,
            in: RoundedRectangle(cornerRadius: FleetTheme.radiusCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FleetTheme.radiusCard)
                .strokeBorder(FleetTheme.statusNeedsIntervention.opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, FleetTheme.spacingSm)
        .privacySensitive(isSensitive(request))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("serverprompt.card")
    }

    private func isSensitive(_ request: ServerRequest) -> Bool {
        switch request.kind {
        case .sudo, .secret: return true
        case .approval, .clarify: return false
        }
    }

    private func header(for request: ServerRequest) -> some View {
        let (title, symbol): (String, String) = {
            switch request.kind {
            case .clarify: return ("QUESTION FROM THE AGENT", "questionmark.bubble.fill")
            case .sudo: return ("SUDO PASSWORD REQUESTED", "lock.shield.fill")
            case .secret: return ("SECRET REQUESTED", "key.fill")
            case .approval: return ("", "")
            }
        }()
        return Label {
            Text(title)
                .font(FleetTheme.monoCaptionFont.weight(.semibold))
                .foregroundStyle(FleetTheme.statusNeedsIntervention)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(FleetTheme.statusNeedsIntervention)
        }
        .accessibilityIdentifier("serverprompt.title")
    }

    @ViewBuilder
    private var statusHint: some View {
        switch model.state {
        case .biometricFailed:
            hint(PresenceFeedback.message(for: .failed, action: model.pendingPresenceAction) ?? "")
        case .authCancelled:
            hint(PresenceFeedback.message(for: .cancelled, action: model.pendingPresenceAction) ?? "")
        case .passcodeNotSet:
            hint(PresenceFeedback.message(for: .passcodeNotSet, action: model.pendingPresenceAction) ?? "")
        case .failed(let message):
            hint(message)
        case .idle, .pending, .sending:
            EmptyView()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(FleetTheme.statusNeedsIntervention)
            .accessibilityIdentifier("serverprompt.hint")
    }
}

// MARK: - sudo / secret entry

/// Face-ID-gated secure entry. The typed text never leaves this view except
/// as the argument of `submitValue`, and is cleared on submit.
private struct ValueEntry: View {
    @Environment(\.fleetTheme) private var theme
    @Bindable var model: ServerPromptViewModel
    let requestID: String
    let title: String
    let detail: String
    let detailIsMono: Bool
    let fieldLabel: String
    @State private var value = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(theme.textPrimary)
            if !detail.isEmpty {
                Text(detail)
                    .font(detailIsMono ? FleetTheme.monoFont : .caption)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.isInputUnlocked {
                SecureField(fieldLabel, text: $value)
                    .textContentType(nil)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused)
                    .padding(.horizontal, FleetTheme.spacingSm)
                    .padding(.vertical, 8)
                    .background(
                        theme.background,
                        in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow))
                    .accessibilityIdentifier("serverprompt.secure")
                    .onAppear { focused = true }
            }
            HStack(spacing: FleetTheme.spacingMd) {
                Button {
                    Task {
                        guard model.pending?.id == requestID else { return }
                        await model.skipValue()
                    }
                } label: {
                    Text("Decline")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.fleetPressable)
                .accessibilityIdentifier("serverprompt.skip")

                if model.isInputUnlocked {
                    Button {
                        submit()
                    } label: {
                        actionLabel("Send", symbol: "paperplane.fill")
                    }
                    .buttonStyle(.fleetPressable)
                    .disabled(value.isEmpty || model.state == .sending)
                    .accessibilityIdentifier("serverprompt.send")
                } else {
                    Button {
                        Task {
                            guard model.pending?.id == requestID else { return }
                            await model.unlockInput()
                        }
                    } label: {
                        actionLabel("Unlock", symbol: "faceid")
                    }
                    .buttonStyle(.fleetPressable)
                    .accessibilityIdentifier("serverprompt.unlock")
                }
            }
        }
        .privacySensitive()
        .onDisappear { value = "" }
    }

    private func submit() {
        // Hand the value over and drop it in the same step.
        let entered = value
        value = ""
        Task {
            guard model.pending?.id == requestID else { return }
            await model.submitValue(entered)
        }
    }

    private func actionLabel(_ text: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.body.weight(.semibold))
        }
        .foregroundStyle(theme.highlight)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            theme.surfaceElevated,
            in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow))
        .overlay(
            RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                .strokeBorder(theme.highlight.opacity(0.4), lineWidth: 1))
    }
}

// MARK: - clarify

/// One question at a time. A single-question clarify answers on send; a batch
/// locks each answer (`clarify.lock`) and the last lock resolves the request.
private struct ClarifyEditor: View {
    @Environment(\.fleetTheme) private var theme
    @Bindable var model: ServerPromptViewModel
    let requestID: String
    let prompt: ClarifyPrompt
    @State private var activeIndex: Int?
    @State private var chosen: Set<String> = []
    @State private var typed = ""

    private var index: Int {
        if let activeIndex, prompt.questions.indices.contains(activeIndex) { return activeIndex }
        return prompt.questions.firstIndex { model.lockedAnswers[$0.qid] == nil } ?? 0
    }

    private var question: ClarifyQuestion { prompt.questions[index] }

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            if prompt.isBatch {
                Text("Question \(index + 1) of \(prompt.questions.count) · \(model.lockedAnswers.count) locked")
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("serverprompt.progress")
            }
            Text(question.question)
                .font(.subheadline)
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("serverprompt.question")

            ForEach(question.choices, id: \.self) { choice in
                choiceRow(choice)
            }

            TextField(question.choices.isEmpty ? "Your answer" : "Or type another answer", text: $typed)
                .padding(.horizontal, FleetTheme.spacingSm)
                .padding(.vertical, 8)
                .background(
                    theme.background,
                    in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow))
                .accessibilityIdentifier("serverprompt.text")

            HStack(spacing: FleetTheme.spacingMd) {
                Button {
                    Task {
                        guard model.pending?.id == requestID else { return }
                        await model.skipClarify()
                    }
                } label: {
                    Text(prompt.isBatch ? "Skip all" : "Skip")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.fleetPressable)
                .accessibilityIdentifier("serverprompt.skip")

                Button {
                    submit()
                } label: {
                    Text(prompt.isBatch ? "Lock answer" : "Send")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.highlight)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            theme.surfaceElevated,
                            in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow))
                }
                .buttonStyle(.fleetPressable)
                .disabled(answer == nil || model.state == .sending)
                .accessibilityIdentifier("serverprompt.send")
            }

            if prompt.isBatch, prompt.questions.count > 1 {
                HStack(spacing: FleetTheme.spacingSm) {
                    ForEach(Array(prompt.questions.enumerated()), id: \.offset) { offset, item in
                        Button {
                            activeIndex = offset
                            chosen = []
                            typed = model.lockedAnswers[item.qid] ?? ""
                        } label: {
                            Text(model.lockedAnswers[item.qid] == nil ? "\(offset + 1)" : "\(offset + 1) ✓")
                                .font(FleetTheme.monoCaptionFont)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    offset == index ? theme.surfaceElevated : Color.clear,
                                    in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("serverprompt.question.\(offset)")
                    }
                }
            }
        }
    }

    /// The answer as it goes on the wire, or nil while nothing is entered.
    private var answer: String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.multiSelect {
            var labels = question.choices.filter { chosen.contains($0) }
            if !text.isEmpty { labels.append(text) }
            return labels.isEmpty ? nil : ClarifyAnswerEncoding.multiSelect(labels)
        }
        if !text.isEmpty { return text }
        return chosen.first
    }

    private func choiceRow(_ choice: String) -> some View {
        Button {
            if question.multiSelect {
                if chosen.contains(choice) { chosen.remove(choice) } else { chosen.insert(choice) }
            } else {
                chosen = [choice]
                typed = ""
            }
        } label: {
            HStack {
                Image(systemName: chosen.contains(choice)
                      ? (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                      : (question.multiSelect ? "square" : "circle"))
                Text(choice)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.textPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("serverprompt.choice")
    }

    private func submit() {
        guard let answer else { return }
        let qid = question.qid
        chosen = []
        typed = ""
        activeIndex = nil
        Task {
            guard model.pending?.id == requestID else { return }
            if prompt.isBatch {
                await model.lockClarify(questionID: qid, answer: answer)
            } else {
                await model.answerClarify(answer)
            }
        }
    }
}
