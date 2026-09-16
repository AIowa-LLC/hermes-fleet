import SwiftUI
import FleetCore

/// Build 41 — card detail (GET /tasks/{id}): the full task, comments, runs,
/// parents/children, events, and the action set (edit, status moves, block/
/// unblock, complete, archive, delete, reclaim, reassign, specify, decompose,
/// comment, dependency add/remove).
public struct KanbanTaskDetailView: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    private let environment: AppEnvironment
    private let gatewayID: GatewayID
    private let taskID: String
    private let boardModel: KanbanBoardViewModel?
    @State private var detail: KanbanTaskDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingEdit = false
    @State private var commentText = ""
    @State private var isCommenting = false
    @State private var pendingDestructive: PendingDestructive?
    @State private var actionNote: String?
    @State private var showingAddDependency = false
    @State private var dependencyParentID = ""
    @State private var dependencyChildID = ""

    enum PendingDestructive: Identifiable {
        case delete(String)
        case archive(String)
        var id: String {
            switch self {
            case .delete(let id): return "delete-\(id)"
            case .archive(let id): return "archive-\(id)"
            }
        }
    }

    public init(
        environment: AppEnvironment,
        gatewayID: GatewayID,
        taskID: String,
        model: KanbanBoardViewModel?
    ) {
        self.environment = environment
        self.gatewayID = gatewayID
        self.taskID = taskID
        self.boardModel = model
    }

    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading card…")
                        .accessibilityIdentifier("kanban.detail.loading")
                } else if let detail {
                    detailList(detail)
                } else if let errorMessage {
                    VStack(spacing: FleetTheme.spacingMd) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(theme.textSecondary)
                        Text(errorMessage)
                        Button("Retry") { Task { await load() } }
                            .accessibilityIdentifier("kanban.detail.retry")
                    }
                    .padding()
                }
            }
            .navigationTitle(detail?.task.title ?? taskID)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("kanban.detail.done")
                }
                if let task = detail?.task, boardModel?.canMutate == true {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showingEdit = true
                        } label: {
                            Label("Edit", systemImage: "square.and.pencil")
                        }
                        .accessibilityIdentifier("kanban.detail.edit")
                    }
                }
            }
            .sheet(isPresented: $showingEdit) {
                if let task = detail?.task {
                    KanbanTaskEditView(model: boardModel, task: task, assignees: boardModel?.assignees ?? [])
                }
            }
            .sheet(isPresented: $showingAddDependency) {
                dependencySheet
            }
            .alert("Delete card", isPresented: Binding(
                get: { pendingDestructive?.isDelete == true },
                set: { if !$0 { pendingDestructive = nil } })) {
                Button("Delete", role: .destructive) {
                    Task {
                        await boardModel?.deleteTask(id: taskID)
                        await load()
                        dismissIfGone()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes the card from the board. This cannot be undone.")
            }
            .alert("Archive card", isPresented: Binding(
                get: { pendingDestructive?.isArchive == true },
                set: { if !$0 { pendingDestructive = nil } })) {
                Button("Archive", role: .destructive) {
                    Task {
                        await boardModel?.archiveTask(id: taskID)
                        await load()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Archive removes the card from the live board; restore it from the archived filter.")
            }
            .task { await load() }
        }
    }

    private func dismissIfGone() {
        if let error = boardModel?.mutationErrorMessage, error.contains("not found") {
            dismiss()
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let gateway = environment.gateways.first(where: { $0.id == gatewayID }),
              let boardOperator = environment.makeKanbanOperator(for: gateway) else {
            errorMessage = "This gateway's board is read-only."
            return
        }
        do {
            detail = try await boardOperator.fetchTaskDetail(id: taskID)
            errorMessage = nil
        } catch {
            errorMessage = Redaction.safeErrorDescription(error)
        }
    }

    // MARK: Detail list

    private func detailList(_ detail: KanbanTaskDetail) -> some View {
        List {
            taskSection(detail.task)
            if let note = actionNote {
                Section {
                    Text(note)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            actionsSection(detail.task)
            if !detail.comments.isEmpty {
                commentsSection(detail.comments)
            }
            commentComposerSection
            if !detail.links.parents.isEmpty || !detail.links.children.isEmpty {
                dependencySection(detail)
            }
            dependencyActionsSection
            if !detail.runs.isEmpty {
                runsSection(detail.runs)
            }
            if !detail.events.isEmpty {
                eventsSection(detail.events)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    private func taskSection(_ task: KanbanTaskRecord) -> some View {
        Section {
            LabeledContent("Status", value: (task.status ?? "—").capitalized)
            if let assignee = task.assignee {
                LabeledContent("Assignee", value: assignee)
            } else {
                LabeledContent("Assignee", value: "Unassigned")
            }
            LabeledContent("Priority", value: task.priority.map(String.init) ?? "0")
            if let body = task.body, !body.isEmpty {
                Text(body)
                    .font(FleetTheme.secondaryFont)
                    .accessibilityIdentifier("kanban.detail.body")
            }
            if let result = task.result, !result.isEmpty {
                LabeledContent("Result") {
                    Text(result)
                        .font(FleetTheme.secondaryFont)
                        .multilineTextAlignment(.trailing)
                }
            }
            if let summary = task.latestSummary, !summary.isEmpty {
                LabeledContent("Latest summary") {
                    Text(summary)
                        .font(FleetTheme.secondaryFont)
                        .multilineTextAlignment(.trailing)
                }
            }
            if let created = task.createdAt {
                LabeledContent("Created", value: Self.timestamp(created))
            }
            if let started = task.startedAt {
                LabeledContent("Started", value: Self.timestamp(started))
            }
            if let completed = task.completedAt {
                LabeledContent("Completed", value: Self.timestamp(completed))
            }
            LabeledContent("Workspace", value: task.workspaceKind ?? "—")
            if let skills = task.skills, !skills.isEmpty {
                LabeledContent("Skills", value: skills.joined(separator: ", "))
            }
            if let model = task.modelOverride {
                LabeledContent("Model", value: model)
            }
            if let effort = task.reasoningEffort {
                LabeledContent("Reasoning", value: effort)
            }
            if task.goalMode == true {
                LabeledContent("Goal mode", value: "On")
            }
        } header: {
            Text("Task")
        }
    }

    private func actionsSection(_ task: KanbanTaskRecord) -> some View {
        Section {
            if boardModel?.canMutate == true {
                Picker("Status", selection: Binding(
                    get: { task.status ?? "todo" },
                    set: { newValue in
                        Task {
                            await boardModel?.moveTask(id: task.id, to: newValue)
                            await load()
                        }
                    })) {
                    ForEach(KanbanStatus.settable, id: \.self) { status in
                        Text(status.capitalized).tag(status)
                    }
                }
                .accessibilityIdentifier("kanban.detail.status")
                if task.status != "blocked" {
                    Button {
                        Task {
                            await boardModel?.blockTask(id: task.id, reason: nil)
                            await load()
                        }
                    } label: {
                        Label("Block", systemImage: "minus.circle")
                    }
                } else {
                    Button {
                        Task {
                            await boardModel?.unblockTask(id: task.id)
                            await load()
                        }
                    } label: {
                        Label("Unblock", systemImage: "plus.circle")
                    }
                }
                if task.status == "running" {
                    Button {
                        Task {
                            await boardModel?.reclaimTask(id: task.id, reason: "Reclaimed from iOS")
                            await load()
                        }
                    } label: {
                        Label("Reclaim", systemImage: "arrow.uturn.backward.circle")
                    }
                }
                if task.status == "triage" {
                    Button {
                        Task {
                            await boardModel?.specifyTask(id: task.id)
                            await load()
                        }
                    } label: {
                        Label("Specify", systemImage: "wand.and.stars")
                    }
                    Button {
                        Task {
                            await boardModel?.decomposeTask(id: task.id)
                            await load()
                        }
                    } label: {
                        Label("Decompose", systemImage: "arrow.triangle.branch")
                    }
                }
                Menu {
                    ForEach(boardModel?.assignees ?? [], id: \.self) { name in
                        Button(name) {
                            Task {
                                await boardModel?.reassignTask(
                                    id: task.id, profile: name, reclaimFirst: false, reason: nil)
                                await load()
                            }
                        }
                    }
                    Button("Unassign") {
                        Task {
                            await boardModel?.reassignTask(
                                id: task.id, profile: nil, reclaimFirst: false, reason: nil)
                            await load()
                        }
                    }
                } label: {
                    Label(
                        task.assignee.map { "Reassign (from \($0))" } ?? "Assign",
                        systemImage: "person.crop.circle.badge.arrow.right")
                }
                .accessibilityIdentifier("kanban.detail.reassign")
                if task.status != "done" {
                    Button {
                        Task {
                            await boardModel?.completeTask(id: task.id, result: nil, summary: nil)
                            await load()
                        }
                    } label: {
                        Label("Complete", systemImage: "checkmark.circle")
                    }
                }
                Button(role: .destructive) {
                    pendingDestructive = .archive(task.id)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                Button(role: .destructive) {
                    pendingDestructive = .delete(task.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        } header: {
            Text("Actions")
        }
    }

    // MARK: Comments

    private var commentComposerSection: some View {
        Section {
            HStack {
                TextField("Add a comment", text: $commentText, axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("kanban.detail.comment.field")
                Button {
                    Task { await submitComment() }
                } label: {
                    if isCommenting {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                }
                .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCommenting)
                .accessibilityIdentifier("kanban.detail.comment.submit")
            }
        } footer: {
            if boardModel?.canMutate != true {
                Text("This gateway's board is read-only.")
            }
        }
    }

    private func submitComment() async {
        guard let boardModel, !commentText.isEmpty else { return }
        isCommenting = true
        defer { isCommenting = false }
        await boardModel.addComment(taskID: taskID, body: commentText)
        commentText = ""
        await load()
    }

    private func commentsSection(_ comments: [KanbanComment]) -> some View {
        Section {
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                    HStack {
                        Text(comment.author ?? "unknown")
                            .font(FleetTheme.secondaryFont.weight(.semibold))
                        Spacer()
                        if let at = comment.createdAt {
                            Text(Self.timestamp(at))
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(theme.textMuted)
                        }
                    }
                    Text(comment.body)
                        .font(FleetTheme.secondaryFont)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Comments")
        }
    }

    // MARK: Dependencies

    private func dependencySection(_ detail: KanbanTaskDetail) -> some View {
        Section {
            ForEach(detail.links.parents, id: \.self) { parentID in
                HStack {
                    Text(parentID)
                        .font(FleetTheme.monoFont)
                    Spacer()
                    if let child = detail.childResults.first(where: { $0.id == parentID }) {
                        Text(child.title ?? "")
                            .font(FleetTheme.secondaryFont)
                            .lineLimit(1)
                    }
                }
            }
            ForEach(detail.links.children, id: \.self) { childID in
                HStack {
                    Text(childID)
                        .font(FleetTheme.monoFont)
                    Spacer()
                    if let child = detail.childResults.first(where: { $0.id == childID }) {
                        HStack(spacing: FleetTheme.spacingXs) {
                            Text(child.status?.capitalized ?? "")
                                .font(FleetTheme.monoCaptionFont)
                            Text(child.title ?? "")
                                .font(FleetTheme.secondaryFont)
                                .lineLimit(1)
                        }
                    }
                }
            }
        } header: {
            Text("Parents & Children")
        }
    }

    private var dependencyActionsSection: some View {
        Group {
            if boardModel?.canMutate == true {
                Section {
                    Button {
                        showingAddDependency = true
                    } label: {
                        Label("Add dependency", systemImage: "link")
                    }
                    .accessibilityIdentifier("kanban.detail.dependency.add")
                }
            }
        }
    }

    private var dependencySheet: some View {
        NavigationStack {
            Form {
                TextField("Parent task id", text: $dependencyParentID)
                    .accessibilityIdentifier("kanban.dependency.parent")
                TextField("Child task id", text: $dependencyChildID)
                    .accessibilityIdentifier("kanban.dependency.child")
            }
            .navigationTitle("Link tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingAddDependency = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Link") {
                        Task {
                            await boardModel?.linkTasks(
                                parentID: dependencyParentID, childID: dependencyChildID)
                            showingAddDependency = false
                            await load()
                        }
                    }
                    .disabled(dependencyParentID.isEmpty || dependencyChildID.isEmpty)
                    .accessibilityIdentifier("kanban.dependency.link")
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: Runs / events

    private func runsSection(_ runs: [KanbanRunRecord]) -> some View {
        Section {
            ForEach(runs) { run in
                VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                    HStack {
                        Text("Run \(run.id)")
                            .font(FleetTheme.secondaryFont.weight(.semibold))
                        Spacer()
                        Text(run.status?.capitalized ?? "—")
                            .font(FleetTheme.monoCaptionFont)
                    }
                    if let profile = run.profile {
                        Text(profile)
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(theme.textSecondary)
                    }
                    if let outcome = run.outcome {
                        Text("Outcome: \(outcome)")
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(theme.textSecondary)
                    }
                    if let summary = run.summary, !summary.isEmpty {
                        Text(summary)
                            .font(FleetTheme.secondaryFont)
                            .lineLimit(4)
                    }
                    if let error = run.error, !error.isEmpty {
                        Text(error)
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Runs")
        }
    }

    private func eventsSection(_ events: [KanbanTaskEventRecord]) -> some View {
        Section {
            ForEach(events.reversed()) { event in
                HStack {
                    Text(event.kind)
                        .font(FleetTheme.monoCaptionFont)
                    Spacer()
                    if let at = event.createdAt {
                        Text(Self.timestamp(at))
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(theme.textMuted)
                    }
                }
            }
        } header: {
            Text("Recent Events")
        }
    }

    private static func timestamp(_ epoch: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }
}

private extension KanbanTaskDetailView.PendingDestructive {
    var isDelete: Bool {
        if case .delete = self { return true }
        return false
    }
    var isArchive: Bool {
        if case .archive = self { return true }
        return false
    }
}
