import SwiftUI
import FleetCore

/// R9-T4 — session steering / rename / fork surface: a toolbar menu plus
/// the steer sheet (mid-turn guidance) and rename alert.
///
/// - STEER (`session.steer`): sends text into the RUNNING turn without
///   interrupting it — the model sees the guidance on its next tool batch.
///   Enabled only while a turn is streaming.
/// - RENAME (`session.title`): updates the session's persisted title.
/// - FORK (`session.branch`): copies the visible history into a new session
///   and routes to it (the host navigates on success).
public struct SessionSteerControls: View {
    @Bindable var model: ConversationToolingViewModel
    /// Whether a turn is currently streaming (gates steer).
    let isStreaming: Bool
    /// The current session title (rename placeholder).
    let sessionTitle: String?
    /// Called with the NEW conversation session after a successful fork —
    /// the host replaces the open conversation.
    let onFork: (ConversationSession) -> Void

    @State private var showingSteerSheet = false
    @State private var steerText = ""
    @State private var showingRenameAlert = false
    @State private var renameText = ""

    @FocusState private var steerFieldFocused: Bool

    public init(
        model: ConversationToolingViewModel,
        isStreaming: Bool,
        sessionTitle: String?,
        onFork: @escaping (ConversationSession) -> Void
    ) {
        self.model = model
        self.isStreaming = isStreaming
        self.sessionTitle = sessionTitle
        self.onFork = onFork
    }

    public var body: some View {
        Menu {
            Button {
                steerText = ""
                showingSteerSheet = true
            } label: {
                Label("Steer this turn…", systemImage: "arrow.turn.down.right")
            }
            .disabled(!isStreaming)

            Button {
                renameText = sessionTitle ?? ""
                showingRenameAlert = true
            } label: {
                Label("Rename session…", systemImage: "pencil")
            }

            Button {
                Task { await performFork() }
            } label: {
                Label("Fork from here", systemImage: "arrow.triangle.branch")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(FleetTheme.textSecondary)
        }
        .buttonStyle(.fleetPressable)
        .accessibilityLabel("Session actions")
        .accessibilityHint("Steer the running turn, rename, or fork this session")
        .accessibilityIdentifier("session.actions.menu")
        .sheet(isPresented: $showingSteerSheet) {
            steerSheet
        }
        .alert("Rename Session", isPresented: $showingRenameAlert) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                Task { await model.rename(title: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sets the title saved with this session.")
        }
    }

    // MARK: Steer sheet

    private var steerSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                Text("Steering text lands on the model's next step — the current turn keeps running, nothing is interrupted.")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.textSecondary)
                TextField("e.g. keep it short, skip the web search", text: $steerText, axis: .vertical)
                    .lineLimit(3...6)
                    .font(.body)
                    .foregroundStyle(FleetTheme.textPrimary)
                    .tint(FleetTheme.accent)
                    .padding(FleetTheme.spacingMd)
                    .background(FleetTheme.surface, in: RoundedRectangle(cornerRadius: FleetTheme.radiusRow))
                    .focused($steerFieldFocused)
                    .accessibilityIdentifier("session.steer.field")
                if let notice = model.steerNotice {
                    Text(notice)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.accent)
                        .accessibilityIdentifier("session.steer.notice")
                }
                Spacer()
            }
            .padding(FleetTheme.spacingLg)
            .navigationTitle("Steer Turn")
            .navigationBarTitleDisplayMode(.inline)
            .background(FleetTheme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingSteerSheet = false }
                        .foregroundStyle(FleetTheme.accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Steer") {
                        Task {
                            await model.steer(text: steerText)
                            steerText = ""
                            // Keep the sheet up briefly so the notice reads;
                            // auto-dismiss after the queued ack.
                            try? await Task.sleep(for: .milliseconds(600))
                            showingSteerSheet = false
                        }
                    }
                    .foregroundStyle(FleetTheme.accent)
                    .disabled(steerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("session.steer.send")
                }
            }
            .onAppear { steerFieldFocused = true }
        }
        .presentationDetents([.medium])
        .accessibilityIdentifier("session.steer.sheet")
    }

    // MARK: Fork

    private func performFork() async {
        if let branch = await model.fork(name: nil) {
            onFork(branch)
        }
        // Failure surfaces via model.forkError — the host renders it.
    }
}

/// R9-T4 — transient error/notice banner for tooling actions (fork failure,
/// rename failure). Renders nothing when clear.
public struct ToolingNoticeBanner: View {
    @Bindable var model: ConversationToolingViewModel

    public init(model: ConversationToolingViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let forkError = model.forkError {
                row(text: forkError, symbol: "arrow.triangle.branch", tint: FleetTheme.statusDegraded)
            }
            if let renameNotice = model.renameNotice {
                row(text: renameNotice, symbol: "pencil", tint: FleetTheme.statusDegraded)
            }
        }
    }

    private func row(text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(FleetTheme.textSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(FleetTheme.surface)
        .accessibilityElement(children: .combine)
    }
}
