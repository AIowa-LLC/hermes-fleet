import SwiftUI
import FleetCore

/// Build 41 — orchestration settings sheet (GET/PUT /orchestration) plus the
/// dispatch nudge. Mirrors the dashboard's board-level execution controls.
public struct KanbanOrchestrationView: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    private let model: KanbanBoardViewModel?

    @State private var settings: KanbanOrchestrationSettings?
    @State private var orchestratorProfile = ""
    @State private var defaultAssignee = ""
    @State private var autoDecompose = true
    @State private var autoPromoteChildren = true
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var failureMessage: String?

    public init(model: KanbanBoardViewModel?) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Loading orchestration…")
                                .font(FleetTheme.secondaryFont)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                } else if let settings {
                    Section {
                        TextField("Orchestrator profile", text: $orchestratorProfile)
                            .accessibilityIdentifier("kanban.orch.orchestrator")
                        if let resolved = settings.resolvedOrchestratorProfile,
                           resolved != orchestratorProfile, !resolved.isEmpty {
                            Text("Resolves to \(resolved)")
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(theme.textSecondary)
                        }
                        TextField("Default assignee", text: $defaultAssignee)
                            .accessibilityIdentifier("kanban.orch.assignee")
                        if let resolved = settings.resolvedDefaultAssignee,
                           resolved != defaultAssignee, !resolved.isEmpty {
                            Text("Resolves to \(resolved)")
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(theme.textSecondary)
                        }
                    } header: {
                        Text("Profiles")
                    } footer: {
                        Text("Empty fields fall back to the active profile (\(settings.activeProfile ?? "default")).")
                    }
                    Section {
                        Toggle("Auto-decompose triage", isOn: $autoDecompose)
                            .accessibilityIdentifier("kanban.orch.autodecompose")
                        Toggle("Auto-promote children", isOn: $autoPromoteChildren)
                            .accessibilityIdentifier("kanban.orch.autopromote")
                    } header: {
                        Text("Automation")
                    }
                } else if let failureMessage {
                    Section {
                        Text(failureMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Orchestration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(isLoading || isSaving)
                    .accessibilityIdentifier("kanban.orch.save")
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await model?.orchestrationSettings()
            settings = loaded
            orchestratorProfile = loaded?.orchestratorProfile ?? ""
            defaultAssignee = loaded?.defaultAssignee ?? ""
            autoDecompose = loaded?.autoDecompose ?? true
            autoPromoteChildren = loaded?.autoPromoteChildren ?? true
        } catch {
            failureMessage = Redaction.safeErrorDescription(error)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        await model?.updateOrchestrationSettings(
            KanbanOrchestrationPatch(
                orchestratorProfile: orchestratorProfile,
                defaultAssignee: defaultAssignee,
                autoDecompose: autoDecompose,
                autoPromoteChildren: autoPromoteChildren))
        if let message = model?.mutationErrorMessage {
            failureMessage = message
        } else {
            await load()
        }
    }
}
