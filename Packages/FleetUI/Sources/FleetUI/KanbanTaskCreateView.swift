import SwiftUI
import FleetCore

/// Build 41 — new-card composer (POST /tasks).
///
/// Exposes the fields the stock Hermes contract supports. Advanced fields
/// (workspace, skills, overrides) fold into a DisclosureGroup so the
/// default surface stays comfortable on iPhone.
public struct KanbanTaskCreateView: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    private let model: KanbanBoardViewModel?

    @State private var title = ""
    @State private var body_ = ""
    @State private var assignee = ""
    @State private var priority = 0
    @State private var startInTriage = false
    @State private var showAdvanced = false
    @State private var workspaceKind = ""
    @State private var skills = ""
    @State private var goalMode = false
    @State private var maxRuntime = ""
    @State private var parents = ""
    @State private var modelOverride = ""
    @State private var reasoningEffort = ""
    @State private var isWorking = false
    @State private var failureMessage: String?
    @State private var warningMessage: String?

    public init(model: KanbanBoardViewModel?) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical)
                        .accessibilityIdentifier("kanban.create.title")
                    TextField("Description", text: $body_, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("kanban.create.body")
                } header: {
                    Text("Card")
                }
                Section {
                    Picker("Assignee", selection: $assignee) {
                        Text("Unassigned").tag("")
                        ForEach(model?.assignees ?? [], id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .accessibilityIdentifier("kanban.create.assignee")
                    Stepper("Priority \(priority)", value: $priority, in: -5...10)
                        .accessibilityIdentifier("kanban.create.priority")
                    Toggle("Start in Triage", isOn: $startInTriage)
                        .accessibilityIdentifier("kanban.create.triage")
                } header: {
                    Text("Routing")
                }
                Section {
                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                        Picker("Workspace", selection: $workspaceKind) {
                            Text("Board default").tag("")
                            Text("Scratch").tag("scratch")
                            Text("Worktree").tag("worktree")
                            Text("Directory").tag("dir")
                        }
                        .accessibilityIdentifier("kanban.create.workspace")
                        TextField("Skills (comma-separated)", text: $skills)
                            .accessibilityIdentifier("kanban.create.skills")
                        Toggle("Goal mode", isOn: $goalMode)
                            .accessibilityIdentifier("kanban.create.goalmode")
                        TextField("Max runtime seconds", text: $maxRuntime)
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier("kanban.create.maxruntime")
                        TextField("Parents (comma-separated task ids)", text: $parents)
                            .accessibilityIdentifier("kanban.create.parents")
                        TextField("Model override", text: $modelOverride)
                            .accessibilityIdentifier("kanban.create.model")
                        TextField("Reasoning effort", text: $reasoningEffort)
                            .accessibilityIdentifier("kanban.create.reasoning")
                    }
                }
                if let failureMessage {
                    Section {
                        Text(failureMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("kanban.create.error")
                    }
                }
                if let warningMessage {
                    Section {
                        Label(warningMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(theme.textSecondary)
                            .accessibilityIdentifier("kanban.create.warning")
                    }
                }
            }
            .navigationTitle("New Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("kanban.create.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if warningMessage == nil {
                            Task { await submit() }
                        } else {
                            // The card EXISTS — the warning is the server's
                            // note about it. Done just closes the sheet.
                            dismiss()
                        }
                    } label: {
                        if isWorking {
                            ProgressView()
                        } else {
                            Text(warningMessage == nil ? "Create" : "Done")
                        }
                    }
                    .disabled(
                        warningMessage == nil
                            && (title.trimmingCharacters(in: .whitespaces).isEmpty || isWorking))
                    .accessibilityIdentifier("kanban.create.submit")
                }
            }
        }
    }

    private func submit() async {
        guard let model else { return }
        isWorking = true
        defer { isWorking = false }
        let trimmedSkills = skills
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let trimmedParents = parents
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let draft = KanbanTaskDraft(
            title: title,
            body: body_.isEmpty ? nil : body_,
            assignee: assignee.isEmpty ? nil : assignee,
            priority: priority,
            workspaceKind: workspaceKind.isEmpty ? nil : workspaceKind,
            parents: trimmedParents,
            triage: startInTriage,
            maxRuntimeSeconds: Int(maxRuntime),
            skills: trimmedSkills.isEmpty ? nil : trimmedSkills,
            goalMode: goalMode,
            modelOverride: modelOverride.isEmpty ? nil : modelOverride,
            reasoningEffort: reasoningEffort.isEmpty ? nil : reasoningEffort)
        // `createTask` reports through the model — nil means nothing was
        // created (read-only board or a refusal) and the reason is already in
        // `mutationErrorMessage`. It deliberately does not throw.
        let created = await model.createTask(draft)
        guard created != nil else {
            failureMessage = model.mutationErrorMessage
                ?? "This gateway's board is read-only."
            return
        }
        // A ready+assigned create without a dispatcher gets the server's
        // warning banner: the card EXISTS, so keep the sheet up for the
        // warning and let the confirm button read "Done" (never a second
        // create).
        if let warning = model.createWarning {
            warningMessage = warning
            return
        }
        dismiss()
    }
}
