import SwiftUI
import FleetCore

/// r9 toolbelt — the working-folder switcher sheet (folder chip's new job).
///
/// The folder chip used to be a read-only path popover; now it opens this:
/// the current absolute cwd (monospace, scrollable), a path field, and
/// quick picks. Apply rides `session.cwd.set` (session-scoped working
/// directory — never a global). Errors surface inline (4009 busy, 4017
/// invalid path), never silent.
struct WorkingFolderSheet: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ConversationToolingViewModel
    let currentCWD: String
    /// Called with the readback after a successful change so the owner
    /// refreshes its header state (sessionCWD).
    let onChanged: (SessionCWDInfo) -> Void

    @State private var pathText = ""
    @State private var isApplying = false
    @FocusState private var fieldFocused: Bool

    /// Sibling quick picks derived from the current cwd (parent + root).
    private var quickPicks: [String] {
        var picks: [String] = []
        let parts = currentCWD.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count > 1 {
            picks.append("/" + parts.dropLast().joined(separator: "/"))
        }
        if let root = parts.first.map({ "/\($0)" }), root != currentCWD {
            picks.append(root)
        }
        return Array(Set(picks)).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            Capsule()
                .fill(theme.border)
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, FleetTheme.spacingSm)

            Text("Working folder")
                .font(.headline)
                .foregroundStyle(theme.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(currentCWD)
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
            }

            TextField("Absolute path, e.g. /home/dev/project", text: $pathText)
                .font(FleetTheme.monoCaptionFont)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($fieldFocused)
                .submitLabel(.go)
                .onSubmit { Task { await apply() } }
                .accessibilityIdentifier("fleet.conversation.folder.field")

            if !quickPicks.isEmpty {
                VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                    Text("Quick picks")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                    ForEach(quickPicks, id: \.self) { pick in
                        Button {
                            pathText = pick
                            Task { await apply() }
                        } label: {
                            Label(pick, systemImage: "folder")
                                .font(FleetTheme.monoCaptionFont)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("fleet.conversation.folder.pick.\(pick.hashValue)")
                    }
                }
            }

            if let error = model.cwdError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(FleetTheme.statusDestructive)
                    .accessibilityIdentifier("fleet.conversation.folder.error")
            }

            Button {
                Task { await apply() }
            } label: {
                HStack {
                    if isApplying { ProgressView().tint(theme.onHighlight) }
                    Text(isApplying ? "Changing…" : "Change folder")
                        .font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.highlight)
            .disabled(isApplying || pathText.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("fleet.conversation.folder.apply")
        }
        .padding(FleetTheme.spacingMd)
        .onAppear { fieldFocused = true }
    }

    private func apply() async {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        if let info = await model.changeWorkingFolder(to: pathText) {
            onChanged(info)
            dismiss()
        }
    }
}

/// r9 toolbelt — the session dossier sheet (profile chip's new job).
///
/// The profile chip used to be a display-only label; now it opens a small
/// identity card: profile, owning gateway, session id (copyable), and the
/// two quick actions that already had wires — rename (`session.title`) and
/// branch (`session.branch`).
struct SessionDossierSheet: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ConversationToolingViewModel
    let profileName: String?
    let gatewayName: String
    let sessionID: String
    let sessionTitle: String
    /// Called with the branch result so the owner navigates to the fork.
    let onBranch: (ConversationSession) -> Void

    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var isBranching = false

    var body: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
            Capsule()
                .fill(theme.border)
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, FleetTheme.spacingSm)

            HStack(spacing: FleetTheme.spacingSm) {
                Image(systemName: "person.crop.circle")
                    .font(.title3)
                    .foregroundStyle(theme.highlight)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profileName ?? "Profile")
                        .font(.headline)
                        .foregroundStyle(theme.textPrimary)
                    Text("via \(gatewayName)")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                Text("Session")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                HStack {
                    Text(sessionID)
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: FleetTheme.spacingXs)
                    Button {
                        UIPasteboard.general.string = sessionID
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("fleet.conversation.dossier.copy")
                }
            }

            Divider().overlay(theme.border)

            Text("Rename")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
            HStack {
                TextField(sessionTitle, text: $renameText)
                    .font(.body)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit { Task { await rename() } }
                    .accessibilityIdentifier("fleet.conversation.dossier.rename.field")
                Button {
                    Task { await rename() }
                } label: {
                    if isRenaming {
                        ProgressView().tint(theme.onHighlight)
                    } else {
                        Text("Rename")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.highlight)
                .disabled(isRenaming || renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("fleet.conversation.dossier.rename.apply")
            }

            Button {
                Task {
                    isBranching = true
                    defer { isBranching = false }
                    if let branch = await model.fork(name: nil) {
                        dismiss()
                        onBranch(branch)
                    }
                }
            } label: {
                HStack {
                    if isBranching { ProgressView().tint(theme.onHighlight) }
                    Label("Branch this session", systemImage: "arrow.triangle.branch")
                        .font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(theme.highlight)
            .disabled(isBranching)
            .accessibilityIdentifier("fleet.conversation.dossier.branch")

            if let error = model.forkError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(FleetTheme.statusDestructive)
                    .accessibilityIdentifier("fleet.conversation.dossier.error")
            }
        }
        .padding(FleetTheme.spacingMd)
    }

    private func rename() async {
        guard !isRenaming else { return }
        isRenaming = true
        defer { isRenaming = false }
        if await model.rename(title: renameText) != nil {
            dismiss()
        }
    }
}
