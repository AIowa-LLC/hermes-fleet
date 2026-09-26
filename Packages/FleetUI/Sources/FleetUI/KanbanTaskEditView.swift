import SwiftUI
import FleetCore

/// Build 41 — edit an existing card (PATCH /tasks/{id}): title, body,
/// assignee, priority, overrides.
public struct KanbanTaskEditView: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    private let model: KanbanBoardViewModel?
    private let task: KanbanTaskRecord
    private let assignees: [String]

    @State private var title: String
    @State private var bodyText: String
    @State private var assignee: String
    @State private var priority: Int
    @State private var modelOverride: String
    @State private var reasoningEffort: String
    @State private var clearModelOverride = false
    @State private var isWorking = false
    @State private var failureMessage: String?

    public init(model: KanbanBoardViewModel?, task: KanbanTaskRecord, assignees: [String]) {
        self.model = model
        self.task = task
        self.assignees = assignees
        _title = State(initialValue: task.title ?? "")
        _bodyText = State(initialValue: task.body ?? "")
        _assignee = State(initialValue: task.assignee ?? "")
        _priority = State(initialValue: task.priority ?? 0)
        _modelOverride = State(initialValue: task.modelOverride ?? "")
        _reasoningEffort = State(initialValue: task.reasoningEffort ?? "")
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Card") {
                    TextField("Title", text: $title, axis: .vertical)
                        .accessibilityIdentifier("kanban.edit.title")
                    TextField("Description", text: $bodyText, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("kanban.edit.body")
                }
                Section("Routing") {
                    Picker("Assignee", selection: $assignee) {
                        Text("Unassigned").tag("")
                        ForEach(assignees, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .accessibilityIdentifier("kanban.edit.assignee")
                    Stepper("Priority \(priority)", value: $priority, in: -5...10)
                        .accessibilityIdentifier("kanban.edit.priority")
                }
                Section("Overrides") {
                    TextField("Model override", text: $modelOverride)
                        .accessibilityIdentifier("kanban.edit.model")
                    if task.modelOverride != nil {
                        Toggle("Clear model override", isOn: $clearModelOverride)
                            .accessibilityIdentifier("kanban.edit.clearmodel")
                    }
                    TextField("Reasoning effort", text: $reasoningEffort)
                        .accessibilityIdentifier("kanban.edit.reasoning")
                }
                if let failureMessage {
                    Section {
                        Text(failureMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isWorking {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                    .accessibilityIdentifier("kanban.edit.submit")
                }
            }
        }
    }

    private func submit() async {
        guard let model else { return }
        isWorking = true
        defer { isWorking = false }
        var patch = KanbanTaskPatch()
        if title != (task.title ?? "") {
            patch.title = title
        }
        if bodyText != (task.body ?? "") {
            patch.body = bodyText
        }
        if assignee != (task.assignee ?? "") {
            // Empty string = explicit unassign (wire semantics).
            patch.assignee = assignee
        }
        if priority != (task.priority ?? 0) {
            patch.priority = priority
        }
        if clearModelOverride {
            patch.clearModelOverride = true
        } else if modelOverride != (task.modelOverride ?? "") {
            patch.modelOverride = modelOverride
        }
        if reasoningEffort != (task.reasoningEffort ?? "") {
            patch.reasoningEffort = reasoningEffort.isEmpty ? nil : reasoningEffort
            if reasoningEffort.isEmpty { patch.clearReasoningEffort = true; patch.reasoningEffort = nil }
        }
        await model.updateTask(id: task.id, patch: patch)
        if let message = model.mutationErrorMessage {
            failureMessage = message
        } else {
            dismiss()
        }
    }
}
