// Issue #215: the conversation screen's chrome as nominal `View` types.
//
// These were `some View` helpers on `ConversationView` and inlined their
// values into `canvas(_:)` and `body`. In an unoptimized build each of those
// frames keeps a dozen copies of the screen's whole body value, so its size
// is what decides how much main-thread stack opening a conversation takes
// (it reached ~1 MB — the device limit). A nominal child contributes one
// small struct to its parent and its body is evaluated in its own graph
// update. Inputs are explicit; state stays owned by `ConversationView`.

import SwiftUI
import FleetCore
import UIKit

/// The compact header: back, drawer, identity, find, session controls.
struct ConversationHeader: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.openFleetDrawer) private var openDrawer

    let model: ConversationViewModel
    let route: Route
    let bot: FleetBot?
    let name: String
    let status: FleetStatus
    let management: BotManagementController
    let isFindActive: Bool
    let showsTimeline: Bool
    let showsLatest: Bool
    let onBack: () -> Void
    let onToggleFind: () -> Void
    let onTimeline: () -> Void
    let onLatest: () -> Void

    @ScaledMetric(relativeTo: .callout) private var headerGlyphSide: CGFloat = 32

    /// ONE row: [‹] [☰] [avatar●status] Name / session-title … [3%] [chip] [⋯]
    /// - Back: custom chevron (NavigationStack pop; swipe-back survives —
    ///   the gesture rides the interactive pop, not the bar).
    /// - Drawer: same `openFleetDrawer` action + `fleet.drawer.open` id.
    /// - Status: colored dot on the avatar's corner (semantic color); the
    ///   spoken form stays on the identity element ("Status: Online").
    /// - Identity: 28pt avatar, name + title stacked; at accessibility
    ///   sizes the trailing metadata drops (still reachable via ⋯).
    /// - Timeline + jump-to-latest moved into the ⋯ session-actions menu;
    ///   latest ALSO has a zero-chrome floating chevron on the transcript.
    var body: some View {
        HStack(spacing: FleetTheme.spacingSm) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: min(headerGlyphSide, ConversationView.maxChromeGlyph), height: min(headerGlyphSide, ConversationView.maxChromeGlyph))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.fleetPressable)
            .accessibilityLabel("Back")
            .accessibilityIdentifier("fleet.conversation.back")

            Button {
                openDrawer?()
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: min(headerGlyphSide, ConversationView.maxChromeGlyph), height: min(headerGlyphSide, ConversationView.maxChromeGlyph))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.fleetPressable)
            .accessibilityLabel("Menu")
            .accessibilityIdentifier("fleet.drawer.open")

            avatarWithStatus(bot: bot, status: status)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .accessibilityIdentifier("fleet.conversation.header.name")
                Text(model.sessionTitle ?? route.id)
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("fleet.conversation.header.title")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(name), status \(status.label)")
            .accessibilityIdentifier("fleet.conversation.header.identity")

            // Keep the session actions trailing and make the custom chrome
            // span the full width. Without a flexible spacer this HStack is
            // content-sized and the header visibly collapses on entry.
            Spacer(minLength: FleetTheme.spacingXs)

            // P0-B (RC-84): Find in Conversation — a fixed 44pt control
            // (the header's Spacer geometry keeps the row full-width).
            Button {
                onToggleFind()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isFindActive ? theme.highlight : theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.fleetPressable)
            .accessibilityLabel("Find in Conversation")
            .accessibilityIdentifier("fleet.conversation.find")

            // r9: the chip zone moved UNDER the composer (the Toolbelt) —
            // nothing renders here anymore.
            if let toolingModel = model.toolingViewModel {
                SessionSteerControls(
                    model: toolingModel,
                    isStreaming: model.isStreaming,
                    sessionTitle: model.sessionTitle,
                    showsTimeline: showsTimeline,
                    showsLatest: showsLatest,
                    onTimeline: onTimeline,
                    onLatest: onLatest,
                    onFork: { _ in }
                )
            }

            // R9-T3: per-session YOLO toggle (session-scoped only, confirmed
            // on enable). Hidden when the session has no approvals seam.
            // (Restored: e748746's single-row header dropped this mount while
            // claiming identifier preservation; R9ApprovalBanner is the guard.)
            if let approvalModel = model.approvalViewModel {
                SessionYoloToggle(model: approvalModel)
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, FleetTheme.spacingSm)
        .padding(.vertical, 4)
        // DEV19 AX5: header chrome stops growing past accessibility XL (the
        // size its UI test pins) so the identity never collapses at AX4/AX5.
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .background(theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet.conversation.header")
    }

    /// 28pt avatar with a 10pt status dot pinned bottom-trailing. The dot is
    /// decorative (the identity element carries the spoken status).
    private func avatarWithStatus(bot: FleetBot?, status: FleetStatus) -> some View {
        BotAvatar(bot: bot, management: management)
            .frame(width: 28, height: 28)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(theme.semanticStatusColor(for: status))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(theme.surface, lineWidth: 2))
            }
    }
}

/// Find in Conversation (P0-B / RC-84). Matching and navigation state stay on
/// `ConversationView`; this view only renders and reports intents.
struct ConversationFindBar: View {
    @Environment(\.fleetTheme) private var theme

    @Binding var query: String
    var fieldFocused: FocusState<Bool>.Binding
    let statusText: String
    let hasMatches: Bool
    let onAdvance: (Int) -> Void
    let onClose: () -> Void
    let onQuerySettled: () -> Void

    /// The find bar: field + match position + prev/next + close. Docks
    /// under the compact header while active; every control is a 44pt
    /// target. Typing is debounced via `.task(id:)` so long transcripts
    /// are not rescanned per keystroke.
    var body: some View {
        HStack(spacing: FleetTheme.spacingSm) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
                TextField("Find in conversation", text: $query)
                    .font(.subheadline)
                    .foregroundStyle(theme.textPrimary)
                    .tint(theme.highlight)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused(fieldFocused)
                    .onSubmit { onAdvance(1) }
                    .accessibilityIdentifier("fleet.conversation.find.field")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(theme.background, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))

            Text(statusText)
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)
                .accessibilityIdentifier("fleet.conversation.find.count")

            Button {
                onAdvance(-1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.fleetPressable)
            .disabled(!hasMatches)
            .accessibilityLabel("Previous match")
            .accessibilityIdentifier("fleet.conversation.find.prev")

            Button {
                onAdvance(1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.fleetPressable)
            .disabled(!hasMatches)
            .accessibilityLabel("Next match")
            .accessibilityIdentifier("fleet.conversation.find.next")

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.fleetPressable)
            .accessibilityLabel("Close find")
            .accessibilityIdentifier("fleet.conversation.find.close")
        }
        .padding(.horizontal, FleetTheme.spacingSm)
        .padding(.vertical, 2)
        .background(theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
        }
        // `.contain` (the compact-header pattern) makes the bar a container
        // element so the field/stepper/close keep their OWN identifiers —
        // without it the bar's id propagates onto every child (AX dump
        // evidence, RC-84 CC UI test).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet.conversation.find.bar")
        .task(id: query) {
            // Debounce: a short idle before rescanning keeps long
            // transcripts off the per-keystroke path.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            onQuerySettled()
        }
        .onAppear { fieldFocused.wrappedValue = true }
    }
}

/// r9 toolbelt — the chip zone UNDER the composer.
struct ConversationToolbelt: View {
    @Environment(\.fleetTheme) private var theme

    let model: ConversationViewModel
    @Binding var showingModelPicker: Bool
    @Binding var showingReasoningSlider: Bool
    @Binding var showingContextBreakdown: Bool
    @Binding var showingWorkingFolder: Bool
    @Binding var showingDossier: Bool

    /// r9 toolbelt — the chip zone UNDER the composer: model · folder ·
    /// context · profile (actions left → identity right). Extracted from
    /// the composer body (kept the parent expression type-checkable).
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: FleetTheme.spacingSm) {
                modelChipButton(model)
                // Reasoning level beside the model it applies to. Hidden when
                // the session has no reasoning seam (honest absence).
                if let reasoningModel = model.reasoningViewModel {
                    ReasoningHeaderChip(model: reasoningModel) {
                        showingReasoningSlider = true
                    }
                }
                folderChip(model)
                if let toolingModel = model.toolingViewModel {
                    ContextMeterView(model: toolingModel) {
                        showingContextBreakdown = true
                    }
                }
                profileChip(model)
            }
            .padding(.horizontal, FleetTheme.spacingMd)
            .frame(minHeight: 36)
        }
        .frame(maxWidth: .infinity)
        // DEV14: `.center` clipped BOTH edges whenever the chips overflowed
        // (long model/profile names). Start at the leading edge instead.
        .defaultScrollAnchor(.leading)
        // Accessibility sizes: keep the strip reachable but bounded — the
        // composer and transcript keep their space.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityIdentifier("fleet.conversation.header.chipzone")
        .scrollBounceBehavior(.basedOnSize)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.top, 2)
    }

    /// DEV14: a toolbelt chip never grows past this (full value remains in
    /// its accessibility value / popover) so one long model, folder or
    /// profile name cannot push its neighbours off screen.
    static let toolbeltChipMaxWidth: CGFloat = 150

    /// Working-project-folder chip: folder glyph + the LAST path component
    /// (full path in the tap popover — phone-width chips must not truncate).
    /// Hidden honestly when the gateway reports no cwd.
    @ViewBuilder
    private func folderChip(_ model: ConversationViewModel) -> some View {
        if let cwd = model.sessionCWD {
            // r9 toolbelt: the folder chip now opens the working-folder
            // SWITCHER (session.cwd.set) — copy-path moved to a long-press.
            Button {
                showingWorkingFolder = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                    Text(ConversationView.ConversationHeaderChips.lastPathComponent(cwd))
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: ConversationToolbelt.toolbeltChipMaxWidth)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(theme.background, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
            }
            .buttonStyle(.fleetPressable)
            .simultaneousGesture(LongPressGesture().onEnded { _ in
                UIPasteboard.general.string = cwd
            })
            .accessibilityLabel("Working folder")
            .accessibilityValue(cwd)
            .accessibilityHint("Changes the session's working directory")
            .accessibilityIdentifier("fleet.conversation.header.folder")
            .sheet(isPresented: $showingWorkingFolder) {
                if let toolingModel = model.toolingViewModel {
                    WorkingFolderSheet(
                        model: toolingModel,
                        currentCWD: cwd,
                        onChanged: { info in
                            model.refreshCWD(info)
                        }
                    )
                    .presentationDetents([.medium])
                }
            }
        }
    }

    /// Selected-profile chip (display-only; the conversation is bound to
    /// this profile's route).
    @ViewBuilder
    private func profileChip(_ model: ConversationViewModel) -> some View {
        if let profile = model.sessionProfileName {
            // r9 toolbelt: the profile chip opens the session DOSSIER —
            // identity card + rename + branch (wires that already existed).
            Button {
                showingDossier = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle")
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                    Text(profile)
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: ConversationToolbelt.toolbeltChipMaxWidth)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(theme.background, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
            }
            .buttonStyle(.fleetPressable)
            .accessibilityLabel("Profile")
            .accessibilityValue(profile)
            .accessibilityHint("Session details, rename, and branch")
            .accessibilityIdentifier("fleet.conversation.header.profile")
            .sheet(isPresented: $showingDossier) {
                if let toolingModel = model.toolingViewModel {
                    SessionDossierSheet(
                        model: toolingModel,
                        profileName: profile,
                        gatewayName: model.route.gatewayID.rawValue,
                        sessionID: model.sessionID ?? "—",
                        sessionTitle: model.sessionTitle ?? "Session",
                        onBranch: { branch in
                            model.adoptFork(branch)
                        }
                    )
                    .presentationDetents([.medium])
                }
            }
        }
    }

    /// The compact model chip (no longer its own dedicated full-width row).
    /// The chip shows the sticky pick (or the session's model readback);
    /// tap opens the picker. Same identifiers and semantics as before.
    private func modelChipButton(_ model: ConversationViewModel) -> some View {
        Button {
            showingModelPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
                Text(model.toolingViewModel?.selectedModel?.shortName
                     ?? model.sessionModel?.split(separator: "·").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
                     ?? "model")
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(
                        model.toolingViewModel?.selectedModel != nil
                            ? theme.highlight
                            : theme.textSecondary
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: ConversationToolbelt.toolbeltChipMaxWidth)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(theme.background, in: Capsule())
        }
        .buttonStyle(.fleetPressable)
        .accessibilityLabel("Model picker")
        .accessibilityValue(model.toolingViewModel?.selectedModel?.model ?? "profile default")
        .accessibilityHint("Choose the model for new chats on this device")
        .accessibilityIdentifier("model.chip")
    }
}

/// A pushed conversation (fork / `/new`). `navigationDestination(isPresented:)`
/// builds its destination eagerly, so the parent would otherwise carry a
/// whole `ConversationView` value per destination.
struct ConversationDestination: View {
    let environment: AppEnvironment
    let route: Route
    let sessionID: String?

    var body: some View {
        ConversationView(environment: environment, route: route, sessionID: sessionID)
            .toolbar { FleetDrawerMenu(showsUnreadBadge: environment.anyUnreadSessions) }
    }
}
