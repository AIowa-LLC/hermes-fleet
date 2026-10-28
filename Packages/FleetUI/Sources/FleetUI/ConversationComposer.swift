// Issue #215: the conversation composer is its own `View` type.
//
// It used to be `ConversationView.composer(_:)`, a `some View` helper inlined
// into `canvas(_:)` and from there into `ConversationView.body`. That made the
// whole screen one value type (~26 KB in a Debug build) whose unoptimized
// `body`/`canvas` frames each hold a dozen copies of it — ~1 MB of main-thread
// stack before the composer's own 34-level generic type was even resolved.
// On a device (1 MB main-thread stack) that overflowed the moment a
// conversation opened. As a nominal type the composer contributes one small
// struct to its parent, and SwiftUI evaluates its body in a separate, shallow
// graph update. The pill controls below are nominal for the same reason: they
// keep this body's own generic nesting shallow.

import SwiftUI
import FleetCore
import UIKit

struct ConversationComposer: View {
    @Environment(\.fleetTheme) private var theme

    let model: ConversationViewModel
    let environment: AppEnvironment
    let route: Route
    @Binding var composerText: String
    var composerFocused: FocusState<Bool>.Binding
    @Binding var showingAddActions: Bool
    @Binding var showingReasoningSlider: Bool
    @Binding var previewingAttachment: ConversationViewModel.PendingAttachment?
    let isResolvingPickedAttachment: Bool
    let onSubmit: () -> Void

    /// Send/stop button side length (pt) — circular, per the hero mock.
    @ScaledMetric(relativeTo: .title3) private var sendButtonSide: CGFloat = 44
    @ScaledMetric(relativeTo: .title3) private var composerGlyphSide: CGFloat = 36
    @ScaledMetric(relativeTo: .callout) private var sendGlyphSide: CGFloat = 30

    /// The composer morphs: stadium when idle (fully-rounded pill), a soft
    /// 26pt card when focused/expanding — ChatGPT/Hermex's presentation
    /// recipe. Driven by focus (the honest signal the keyboard is up).
    private var composerPillRadius: CGFloat {
        composerFocused.wrappedValue ? 26 : 22
    }

    /// DEV19 AX5: the +/mic glyph frames scale with Dynamic Type up to the
    /// shared chrome cap.
    private var chromeGlyphSide: CGFloat {
        min(composerGlyphSide, ConversationView.maxChromeGlyph)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let query = BotConversationMentions.query(in: composerText) {
                let suggestions = BotConversationMentions.suggestions(query: query,
                    roster: environment.mentionCandidates(), excluding: route,
                    gatewayLabel: { environment.gateway(for: $0)?.displayName ?? $0.rawValue })
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(suggestions) { suggestion in
                            Button {
                                composerText = BotConversationMentions.inserting(suggestion.alias, into: composerText)
                            } label: {
                                HStack {
                                    BotAvatar(bot: environment.bot(for: suggestion.id), management: environment.botManagement)
                                    VStack(alignment: .leading) {
                                        Text(suggestion.candidate.friendlyTitle)
                                        Text("@\(suggestion.alias) · \(suggestion.gatewayLabel)").font(.caption)
                                    }
                                }
                            }
                            .accessibilityLabel("Mention \(suggestion.candidate.friendlyTitle) on \(suggestion.gatewayLabel)")
                            .accessibilityIdentifier("fleet.mention.\(suggestion.id.id)")
                        }
                    }
                }.frame(maxHeight: 180)
                 .accessibilityIdentifier("fleet.mentions")
            }
            if let notice = model.botDraftNotice {
                Text(notice).font(.caption).padding(8)
                    .accessibilityIdentifier("fleet.conversation.bot-notice")
            }
            // Issue #4: skill discovery lives in the same compact composer
            // surface as the input, never as a full-screen command browser.
            if model.isSlashPaletteVisible {
                slashPalette(model)
            }
            // R10-T1: pending-attachment chips (name + size, removable) and
            // the never-silent error banner sit directly above the input row.
            if !model.pendingAttachments.isEmpty || model.isUploadingAttachment {
                attachmentTray(model)
            }
            if let attachmentError = model.attachmentError {
                attachmentErrorBanner(model, message: attachmentError)
            }
            // R10-T2: reaction error banner — never silent.
            if let reactionError = model.reactionError {
                reactionErrorBanner(model, message: reactionError)
            }
            // R10-T4: voice banners — honest authorization-denied gate +
            // never-silent capture/synthesis failure.
            if model.isVoiceDenied {
                voiceDeniedBanner(model)
            }
            if let voiceError = model.voiceError {
                voiceErrorBanner(model, message: voiceError)
            }
            // R10-T4: transcript review chip — the recognized text lands for
            // review before any submit (review-first; never auto-sent unless
            // the user opted into submit-on-silence).
            if let transcript = model.latestVoiceTranscript,
               !model.isListening {
                transcriptReviewChip(model, transcript: transcript)
            }
            // Dogfood r6 (G1): ONE floating composer pill (ChatGPT
            // anatomy) — +, field, mic, and send/stop live INSIDE the
            // stadium; it morphs to a soft card when focused/expanded
            // (Hermex's ChatComposerPresentation recipe: continuous
            // corners, ultraThinMaterial glass, hairline + soft shadow).
            // All controls keep their identifiers (zero test edits).
            HStack(spacing: FleetTheme.spacingSm) {
                // R10-T1: "+" affordance — Photos picker (images) + Files
                // importer (PDF/any). Hidden while a turn streams (the
                // gateway queues attaches for the NEXT submit; allowing
                // mid-stream picks invites orphaned uploads).
                if model.phase == .ready {
                    ComposerGlyphButton(
                        systemName: "plus",
                        ink: AnyShapeStyle(theme.textSecondary),
                        glyphSide: chromeGlyphSide
                    ) {
                        showingAddActions = true
                    }
                    .disabled(isResolvingPickedAttachment || model.isUploadingAttachment)
                    .accessibilityLabel("Add to message")
                    .accessibilityIdentifier("fleet.conversation.attach")
                }

                ComposerMessageField(
                    text: $composerText,
                    focused: composerFocused,
                    isEnabled: model.phase == .ready || model.phase == .streaming,
                    onSubmit: onSubmit)

                // r8.1: thinking-level gauge — right cluster, FIRST
                // position (ChatGPT placement: field … gauge, mic, send).
                // Level-encoding needle; highlight ink once adjusted.
                if let reasoningModel = model.reasoningViewModel {
                    ReasoningChip(model: reasoningModel) {
                        showingReasoningSlider = true
                    }
                }

                // R10-T4: mic button — on-device transcription (Speech
                // framework) into the composer. Hidden entirely when no
                // voice engine is wired (fail-closed). While listening, the
                // button becomes a stop control (best-partial capture).
                // r8.1: moved to the RIGHT cluster (ChatGPT order:
                // gauge, mic, send); idle ink is pure white (textPrimary)
                // per Tony — the neutral among two accent buttons.
                if model.isVoiceAvailable {
                    ComposerGlyphButton(
                        systemName: model.isListening ? "stop.circle.fill" : "mic.fill",
                        ink: model.isListening ? AnyShapeStyle(FleetTheme.statusDestructive) : AnyShapeStyle(theme.textPrimary),
                        glyphSide: chromeGlyphSide
                    ) {
                        Task { await model.toggleMic() }
                    }
                    .accessibilityLabel(model.isListening ? "Stop Listening" : "Transcribe Voice")
                    .accessibilityIdentifier("fleet.conversation.mic")
                }

                if model.phase == .streaming || model.isStreaming {
                    ComposerStopButton(side: sendButtonSide) {
                        Task { await model.interrupt() }
                    }
                    .accessibilityLabel("Stop")
                    .accessibilityIdentifier("fleet.conversation.stop")
                } else {
                    ComposerSendButton(glyphSide: min(sendGlyphSide, ConversationView.maxChromeGlyph), action: onSubmit)
                        .disabled(model.phase != .ready || (composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingAttachments.isEmpty))
                        .accessibilityLabel("Send")
                        .accessibilityIdentifier("fleet.conversation.send")
                }
            }
            .modifier(ComposerPillChrome(radius: composerPillRadius))
        }
    }

    /// Compact, touch-friendly skill palette backed entirely by the active
    /// Hermes session's discovery/completion responses.
    private func slashPalette(_ model: ConversationViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: FleetTheme.spacingSm) {
                Image(systemName: "sparkles")
                    .foregroundStyle(theme.highlight)
                Text("Commands")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                if model.isLoadingCommandSuggestions {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.vertical, FleetTheme.spacingXs)

            if let error = model.commandSuggestionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(FleetTheme.statusDegraded)
                    .padding(.horizontal, FleetTheme.spacingLg)
                    .padding(.vertical, FleetTheme.spacingSm)
                    .accessibilityIdentifier("fleet.conversation.command.error")
            } else if model.commandSuggestions.isEmpty && !model.isLoadingCommandSuggestions {
                Text("No commands available in this Hermes profile")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, FleetTheme.spacingLg)
                    .padding(.vertical, FleetTheme.spacingSm)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("No commands available in this Hermes profile")
                    .accessibilityIdentifier("fleet.conversation.command.empty")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        let commandRows = model.commandSuggestions.filter { $0.kind != .skill }
                        let skillRows = model.commandSuggestions.filter { $0.kind == .skill }
                        if !commandRows.isEmpty {
                            paletteSectionLabel("Commands")
                        }
                        ForEach(commandRows) { suggestion in
                            paletteRow(model, suggestion)
                        }
                        if !skillRows.isEmpty {
                            paletteSectionLabel("Skills")
                        }
                        ForEach(skillRows) { suggestion in
                            paletteRow(model, suggestion)
                        }
                    }
                }
                .frame(maxHeight: 176)
            }
        }
        .background(theme.surfaceElevated)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet.conversation.command.palette")
    }

    /// One palette row: canonical token + description. Inserting the token
    /// never auto-executes; focus returns to the composer for arguments.
    private func paletteRow(_ model: ConversationViewModel, _ suggestion: SlashCommandSuggestion) -> some View {
        Button {
            composerText = model.selectedCommandText(
                suggestion,
                replacing: composerText)
            composerFocused.wrappedValue = true
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.text)
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(theme.textPrimary)
                if !suggestion.description.isEmpty {
                    Text(suggestion.description)
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.vertical, FleetTheme.spacingSm)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("fleet.conversation.command.\(suggestion.text.dropFirst())")
    }

    private func paletteSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.top, FleetTheme.spacingSm)
    }

    // MARK: R10-T1 — attachment tray + pickers

    /// Pending-attachment chips: name + human-readable size, removable with
    /// the X button; a spinner chip while an upload is in flight.
    private func attachmentTray(_ model: ConversationViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: FleetTheme.spacingSm) {
                if model.isUploadingAttachment {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Uploading…")
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: FleetTheme.radiusRow)
                            .fill(theme.surfaceElevated))
                    .accessibilityIdentifier("fleet.conversation.attachment.uploading")
                }
                ForEach(model.pendingAttachments) { chip in
                    // R10-T5: the chip now carries the picture/document
                    // preview affordance (thumbnail + tap-to-open) while
                    // keeping the R10-T1 identifier the UI tests address.
                    AttachmentChip(
                        attachment: chip,
                        onOpen: { previewingAttachment = chip },
                        onRemove: { model.removePendingAttachment(chip.id) })
                }
            }
            .padding(.horizontal, FleetTheme.spacingLg)
            .padding(.top, FleetTheme.spacingSm)
        }
    }

    /// Composer attachment error banner — never silent (R10-T1 mandate).
    private func attachmentErrorBanner(_ model: ConversationViewModel, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(FleetTheme.statusDestructive)
            Text(message)
                .font(.caption)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                model.clearAttachmentError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(theme.textSecondary)
            }
            .accessibilityLabel("Dismiss attachment error")
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, 6)
        // r6 G4: flat on canvas + hairline, no boxed card.
        .overlay(alignment: .top) {
            Rectangle().fill(FleetTheme.statusDestructive.opacity(0.35)).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.conversation.attachment.error")
    }

    /// R10-T2: reaction error banner — never silent (same mandate).
    private func reactionErrorBanner(_ model: ConversationViewModel, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(FleetTheme.statusDestructive)
            Text(message)
                .font(.caption)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                model.clearReactionError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(theme.textSecondary)
            }
            .accessibilityLabel("Dismiss reaction error")
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, 6)
        .background(theme.surfaceElevated)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.conversation.reaction.error")
    }

    // MARK: R10-T4 — voice banners + transcript review chip

    /// Honest authorization-denied gate: mic/speech permission refused — the
    /// ONLY action offered is opening Settings (never a fake retry).
    private func voiceDeniedBanner(_ model: ConversationViewModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash")
                .foregroundStyle(FleetTheme.statusDestructive)
            Text("Voice needs microphone + speech recognition access. Enable them in Settings to transcribe.")
                .font(.caption)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Settings")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.highlight)
            }
            .accessibilityIdentifier("fleet.conversation.voice.denied.settings")
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, 6)
        .background(theme.surfaceElevated)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.conversation.voice.denied")
    }

    /// Never-silent voice failure banner (capture/synthesis errors).
    private func voiceErrorBanner(_ model: ConversationViewModel, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(FleetTheme.statusDestructive)
            Text(message)
                .font(.caption)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                model.clearVoiceError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(theme.textSecondary)
            }
            .accessibilityLabel("Dismiss voice error")
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, 6)
        .background(theme.surfaceElevated)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.conversation.voice.error")
    }

    /// Transcript review chip: the recognized text lands above the composer
    /// for review. "Use" drops it into the composer field for editing;
    /// "Send" submits it as-is; "Discard" clears it. A partial (manual-stop)
    /// transcript is labeled honestly.
    private func transcriptReviewChip(_ model: ConversationViewModel, transcript: VoiceTranscript) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(theme.highlight)
            VStack(alignment: .leading, spacing: 2) {
                Text(transcript.text)
                    .font(.caption)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(3)
                if !transcript.isFinal {
                    Text("Partial — stopped early. Edit before sending.")
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Button {
                composerText = transcript.text
                model.discardTranscript()
            } label: {
                Text("Use")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.highlight)
            }
            .accessibilityIdentifier("fleet.conversation.voice.transcript.use")
            Button {
                Task {
                    model.discardTranscript()
                    await model.send(transcript.text)
                }
            } label: {
                Text("Send")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.highlight)
            }
            .accessibilityIdentifier("fleet.conversation.voice.transcript.send")
            Button {
                model.discardTranscript()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(theme.textSecondary)
            }
            .accessibilityLabel("Discard transcript")
            .accessibilityIdentifier("fleet.conversation.voice.transcript.discard")
        }
        .padding(.horizontal, FleetTheme.spacingLg)
        .padding(.vertical, 6)
        .background(theme.surfaceElevated)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet.conversation.voice.transcript")
    }
}

// MARK: - Pill controls (#215: nominal so the composer body stays shallow)

/// The +/mic control: a bare glyph inside the pill (the pill is the
/// surface; 44pt target via the frame).
struct ComposerGlyphButton: View {
    let systemName: String
    let ink: AnyShapeStyle
    let glyphSide: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ink)
                .frame(width: glyphSide, height: glyphSide)
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.fleetPressable)
    }
}

/// The composer's text field. The pill is the field's surface —
/// transparent inside, no own chrome (r6).
struct ComposerMessageField: View {
    @Environment(\.fleetTheme) private var theme
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let isEnabled: Bool
    let onSubmit: () -> Void

    var body: some View {
        TextField("Message", text: $text, axis: .vertical)
            .lineLimit(1...5)
            .focused(focused)
            .font(.body)
            .foregroundStyle(theme.textPrimary)
            .tint(theme.highlight)
            .padding(.vertical, FleetTheme.spacingSm)
            .disabled(!isEnabled)
            .accessibilityIdentifier("fleet.conversation.composer")
            .onSubmit(onSubmit)
    }
}

/// Hermes parity: the live turn's interrupt reads as DESTRUCTIVE — bright
/// red glyph on a dimmed red circle (the mic-stop pattern), not a neutral
/// chip.
struct ComposerStopButton: View {
    let side: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(FleetTheme.statusDestructive)
                .frame(width: side, height: side)
                .background(Circle().fill(FleetTheme.statusDestructive.opacity(0.18)))
                .overlay(Circle().strokeBorder(FleetTheme.statusDestructive.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.fleetPressable)
    }
}

/// V2 (Nous Direction A): FLAT highlight circle, derived ink glyph — the one
/// accent, no glow, no gradient. The glyph ink is derived from the HIGHLIGHT
/// fill (not the canvas) so it stays legible for any user highlight,
/// including white or near-black. r6: the accent ORB rides inside the pill.
struct ComposerSendButton: View {
    @Environment(\.fleetTheme) private var theme
    let glyphSide: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.callout.weight(.bold))
                .foregroundStyle(theme.onHighlight)
                .frame(width: glyphSide, height: glyphSide)
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                .background(Circle().fill(theme.highlight))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.fleetPressable)
    }
}

/// Dogfood r6 (G1): ONE floating composer pill (ChatGPT anatomy) — it morphs
/// to a soft card when focused/expanded (continuous corners,
/// ultraThinMaterial glass, hairline + soft shadow).
struct ComposerPillChrome: ViewModifier {
    @Environment(\.fleetTheme) private var theme
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(theme.border.opacity(0.6), lineWidth: 0.5)
            )
            .shadow(color: theme.shadow, radius: 10, y: 4)
            .padding(.horizontal, FleetTheme.spacingMd)
            .padding(.vertical, 6)
    }
}
