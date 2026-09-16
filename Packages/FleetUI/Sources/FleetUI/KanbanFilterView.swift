import SwiftUI
import FleetCore

/// Build 41 — board filters sheet: text search, assignee, archived column.
public struct KanbanFilterView: View {
    @Environment(\.dismiss) private var dismiss
    private let model: KanbanBoardViewModel?

    @State private var text: String
    @State private var assignee: String
    @State private var archived: Bool

    public init(model: KanbanBoardViewModel?) {
        self.model = model
        _text = State(initialValue: model?.filterText ?? "")
        _assignee = State(initialValue: model?.filterAssignee ?? "")
        _archived = State(initialValue: model?.showArchived ?? false)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Search") {
                    TextField("Title, assignee, or id", text: $text)
                        .accessibilityIdentifier("kanban.filters.text")
                }
                Section("Assignee") {
                    Picker("Assignee", selection: $assignee) {
                        Text("All").tag("")
                        ForEach((model?.assignees ?? []).filter { $0 != "" }, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .accessibilityIdentifier("kanban.filters.assignee")
                }
                if model?.canMutate == true {
                    Section {
                        Toggle("Show archived", isOn: $archived)
                            .accessibilityIdentifier("kanban.filters.archived")
                    } footer: {
                        Text("Archived cards appear in a separate column while the toggle is on.")
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        text = ""
                        assignee = ""
                        archived = false
                        apply()
                    }
                    .accessibilityIdentifier("kanban.filters.reset")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        apply()
                        dismiss()
                    }
                    .accessibilityIdentifier("kanban.filters.apply")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func apply() {
        model?.filterText = text
        model?.filterAssignee = assignee.isEmpty ? nil : assignee
        model?.showArchived = archived
        Task {
            if archived {
                await model?.refresh()
            }
        }
    }
}
