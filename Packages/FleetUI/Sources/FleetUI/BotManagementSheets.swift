import SwiftUI
import FleetCore

/// Create Bot sheet (D05/D06): quick name/title/description + TARGET
/// gateway picker (requests route to the chosen gateway — the app's active
/// gateway NEVER switches), advanced disclosure (seed mode, SOUL,
/// model/provider, credential inheritance semantics copied from the wire).
public struct CreateBotSheet: View {
    let environment: AppEnvironment
    let onCreated: (String, GatewayID) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var title = ""
    @State private var descriptionText = ""
    @State private var targetGatewayID: GatewayID?
    @State private var showAdvanced = false
    @State private var seedMode: SeedMode = .fresh
    @State private var cloneSource: String = ""
    @State private var soul = ""
    @State private var model = ""
    @State private var provider = ""
    @State private var shareAuth = false
    @State private var mirrorCredentials = true
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    public enum SeedMode: String, CaseIterable, Identifiable {
        case fresh = "Fresh (bundled skills)"
        case clone = "Clone an existing bot"
        case empty = "Empty (no skills)"
        public var id: String { rawValue }
    }

    public init(environment: AppEnvironment, onCreated: @escaping (String, GatewayID) -> Void) {
        self.environment = environment
        self.onCreated = onCreated
    }

    private var gateway: FleetGateway? {
        environment.gateway(for: targetGatewayID ?? environment.gateways.first?.id ?? GatewayID(rawValue: ""))
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("New Bot") {
                    TextField("Name (profile slug)", text: $name)
                        .accessibilityIdentifier("fleet.bot.create.name")
                    TextField("Title (display name, optional)", text: $title)
                        .accessibilityIdentifier("fleet.bot.create.title")
                    TextField("Description (optional)", text: $descriptionText)
                        .accessibilityIdentifier("fleet.bot.create.description")
                }
                Section("Target Gateway") {
                    Picker("Create on", selection: $targetGatewayID) {
                        ForEach(environment.gateways) { gateway in
                            Text(gateway.displayName).tag(Optional.some(gateway.id))
                        }
                    }
                    .accessibilityIdentifier("fleet.bot.create.gateway")
                    Text("The bot is created on the chosen gateway. Your active gateway doesn't change.")
                        .font(.caption)
                        .foregroundStyle(FleetTheme.textSecondary)
                }
                Section {
                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                        Picker("Start from", selection: $seedMode) {
                            ForEach(SeedMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        if seedMode == .clone {
                            TextField("Clone from (profile name)", text: $cloneSource)
                        }
                        TextField("SOUL (optional)", text: $soul, axis: .vertical)
                            .lineLimit(3...6)
                        TextField("Model (optional)", text: $model)
                        TextField("Provider (optional)", text: $provider)
                        Toggle("Share auth (share_auth)", isOn: $shareAuth)
                        Toggle("Mirror credentials (mirror_credentials)", isOn: $mirrorCredentials)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(FleetTheme.statusDegraded)
                            .accessibilityIdentifier("fleet.bot.create.error")
                    }
                }
            }
            .navigationTitle("Create Bot")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await submit() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
                    .accessibilityIdentifier("fleet.bot.create.submit")
                }
            }
        }
        .onAppear {
            if targetGatewayID == nil {
                targetGatewayID = environment.gateways.first?.id
            }
        }
    }

    private func submit() async {
        guard let gatewayID = targetGatewayID else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        let seed: BotCreateSpec.Seed = switch seedMode {
        case .fresh: .fresh
        case .clone: .clone(profile: cloneSource, cloneAll: false)
        case .empty: .emptyNoSkills
        }
        let spec = BotCreateSpec(
            name: name.trimmingCharacters(in: .whitespaces),
            title: title.isEmpty ? nil : title,
            descriptionText: descriptionText.isEmpty ? nil : descriptionText,
            seed: seed,
            soul: soul.isEmpty ? nil : soul,
            model: model.isEmpty ? nil : model,
            provider: provider.isEmpty ? nil : provider,
            shareAuth: shareAuth,
            mirrorCredentials: mirrorCredentials
        )
        do {
            let created = try await environment.botManagement.createBot(spec, on: gatewayID)
            await environment.refreshRoster()
            dismiss()
            onCreated(created, gatewayID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Edit Bot sheet (D07): title/description/SOUL/model/provider/skills/
/// toolsets/MCP/hidden/section from profiles.describe, saved with CAS.
/// Surfaces the model-policy confirmation as a native dialog (never
/// bypassed) and per-key partial success (applied vs failed sections —
/// the P3 residual this slice closes).
public struct EditBotSheet: View {
    let environment: AppEnvironment
    let bot: FleetBot
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var descriptionText = ""
    @State private var soul = ""
    @State private var model = ""
    @State private var provider = ""
    @State private var hidden = false
    @State private var pinned = false
    @State private var avatarShape = ""
    @State private var avatarColor = ""
    @State private var draftDescription: BotProfileDescription?
    @State private var baselineMetadata = BotModeMetadata()
    @State private var metadataRevision: Int?
    @State private var sectionID: String?
    @State private var loadedDescription: BotProfileDescription?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var outcome: BotProfileEditOutcome?
    @State private var pendingModelEdit: BotProfileEdit?
    @State private var confirmMessage: String?

    public init(environment: AppEnvironment, bot: FleetBot) {
        self.environment = environment
        self.bot = bot
    }

    public var body: some View {
        NavigationStack {
            Form {
                metadataSection
                Section("Avatar") {
                    BotAvatarEditor(environment: environment, bot: bot)
                    Picker("Shape", selection: $avatarShape) {
                        Text("Deterministic default").tag("")
                        ForEach(Array(Set(BotAvatarIdentity.pickerShapes + [avatarShape, "blobatar"]).subtracting([""])).sorted(), id: \.self) {
                            Text($0.capitalized).tag($0)
                        }
                    }.accessibilityIdentifier("fleet.bot.avatar.shape")
                    TextField("Color (#RRGGBB)", text: $avatarColor)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("fleet.bot.avatar.color")
                }
                soulSection
                modelSection
                if let description = draftDescription {
                    skillsSection(description)
                    toolsetsSection(description)
                    mcpSection(description)
                }
                organizationSection
                if let outcome, !outcome.succeeded {
                    partialSuccessSection(outcome)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(FleetTheme.statusDegraded)
                            .accessibilityIdentifier("fleet.bot.edit.error")
                    }
                }
            }
            .navigationTitle("Edit \(BotRosterPresentation.displayTitle(for: bot))")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(isSubmitting || loadedDescription == nil)
                    .accessibilityIdentifier("fleet.bot.edit.submit")
                }
            }
            .confirmationDialog(
                "Switch model?",
                isPresented: Binding(
                    get: { pendingModelEdit != nil },
                    set: { if !$0 { pendingModelEdit = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Confirm Switch", role: .destructive) {
                    Task { await confirmModelSwitch() }
                }
                Button("Cancel", role: .cancel) { pendingModelEdit = nil }
            } message: {
                Text(confirmMessage ?? "The gateway flagged this model switch for confirmation.")
            }
            .task { await load() }
        }
    }

    private var metadataSection: some View {
        Section("Identity") {
            TextField("Title", text: $title)
            TextField("Description", text: $descriptionText)
            Toggle("Hidden from roster", isOn: $hidden)
            Toggle("Pinned", isOn: $pinned)
        }
    }

    private var soulSection: some View {
        Section("SOUL") {
            TextField("SOUL", text: $soul, axis: .vertical)
                .lineLimit(4...10)
        }
    }

    private var modelSection: some View {
        Section("Model") {
            TextField("Model", text: $model)
            TextField("Provider", text: $provider)
        }
    }

    private func skillsSection(_ description: BotProfileDescription) -> some View {
        Section("Skills") {
            ForEach(description.skills, id: \.name) { skill in
                Toggle(skill.name, isOn: Binding(
                    get: { draftDescription?.skills.first { $0.name == skill.name }?.enabled ?? false },
                    set: { value in
                        if let i = draftDescription?.skills.firstIndex(where: { $0.name == skill.name }) {
                            draftDescription?.skills[i].enabled = value
                        }
                    }))
                    .accessibilityIdentifier("fleet.bot.edit.skill.\(skill.name)")
            }
        }
    }

    private func toolsetsSection(_ description: BotProfileDescription) -> some View {
        Section("Toolsets") {
            ForEach(description.toolsets, id: \.name) { toolset in
                Toggle(toolset.label ?? toolset.name, isOn: Binding(
                    get: { draftDescription?.toolsets.first { $0.name == toolset.name }?.enabled ?? false },
                    set: { value in
                        if let i = draftDescription?.toolsets.firstIndex(where: { $0.name == toolset.name }) {
                            draftDescription?.toolsets[i].enabled = value
                        }
                    }))
                    .accessibilityIdentifier("fleet.bot.edit.toolset.\(toolset.name)")
            }
        }
    }

    private func mcpSection(_ description: BotProfileDescription) -> some View {
        Section("MCP Servers") {
            if description.mcpServers.isEmpty {
                Text("None configured")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.textSecondary)
            }
            ForEach(description.mcpServers, id: \.name) { server in
                Toggle(server.name, isOn: Binding(
                    get: { draftDescription?.mcpServers.first { $0.name == server.name }?.enabled ?? false },
                    set: { value in
                        if let i = draftDescription?.mcpServers.firstIndex(where: { $0.name == server.name }) {
                            draftDescription?.mcpServers[i].enabled = value
                        }
                    }))
                    .accessibilityIdentifier("fleet.bot.edit.mcp.\(server.name)")
            }
        }
    }

    private var organizationSection: some View {
        Section("Organization") {
            Picker("Section", selection: $sectionID) {
                Text("Unassigned").tag(Optional<String>.none)
                ForEach(environment.botManagement.sectionsByGateway[bot.route.gatewayID] ?? []) { section in
                    Text(section.name).tag(Optional.some(section.id))
                }
            }
            .accessibilityIdentifier("fleet.bot.edit.section")
        }
    }

    /// Per-key partial success (P3): applied vs failed sections listed
    /// explicitly — never a single generic result.
    private func partialSuccessSection(_ outcome: BotProfileEditOutcome) -> some View {
        Section("Partially Applied") {
            if !outcome.appliedSections.isEmpty {
                Label(
                    "Applied: \(outcome.appliedSections.map(\.rawValue).sorted().joined(separator: ", "))",
                    systemImage: "checkmark.circle"
                )
                .foregroundStyle(FleetTheme.statusOnline)
            }
            if !outcome.failedSections.isEmpty {
                Label(
                    "Not applied: \(outcome.failedSections.map(\.rawValue).sorted().joined(separator: ", "))",
                    systemImage: "exclamationmark.circle"
                )
                .foregroundStyle(FleetTheme.statusDegraded)
            }
        }
        .accessibilityIdentifier("fleet.bot.edit.partial")
    }

    private func load() async {
        let meta = bot.botModeMetadata
        title = meta?.title ?? ""
        descriptionText = meta?.descriptionText ?? bot.profileDescription ?? ""
        hidden = meta?.hidden ?? false
        pinned = meta?.pinned ?? false
        avatarShape = meta?.shape ?? ""
        avatarColor = meta?.color ?? ""
        baselineMetadata = meta ?? BotModeMetadata()
        metadataRevision = bot.uiMetaRevisions?[BotModeContract.botsMetaKey]
        sectionID = meta?.sectionID
        model = bot.model ?? ""
        provider = bot.provider ?? ""
        do {
            let description = try await environment.botManagement.describeBot(bot)
            loadedDescription = description
            draftDescription = description
            soul = description.soul ?? ""
            model = description.defaultModel ?? ""
            provider = description.provider ?? ""
            descriptionText = description.descriptionText ?? descriptionText
        } catch {
            errorMessage = "Could not load the current profile. Reopen the editor to retry."
        }
    }

    private func save() async {
        isSubmitting = true
        defer { isSubmitting = false }
        errorMessage = nil
        var metadata = baselineMetadata
        metadata.shape = avatarShape.isEmpty ? nil : avatarShape
        metadata.color = avatarColor.isEmpty ? nil : avatarColor
        metadata.title = title.isEmpty ? nil : title
        metadata.descriptionText = descriptionText.isEmpty ? nil : descriptionText
        metadata.hidden = hidden == (baselineMetadata.hidden ?? false) ? baselineMetadata.hidden : hidden
        metadata.pinned = pinned == (baselineMetadata.pinned ?? false) ? baselineMetadata.pinned : pinned
        metadata.sectionID = sectionID
        let edit = BotProfileEdit(
            metadata: metadata == baselineMetadata ? nil : metadata,
            metadataExpectedRevision: metadataRevision,
            previousMetadataRaw: bot.uiMeta?[BotModeContract.botsMetaKey],
            soul: soul == (loadedDescription?.soul ?? "") ? nil : soul,
            descriptionText: descriptionText == (loadedDescription?.descriptionText ?? "") ? nil : descriptionText,
            model: model == (loadedDescription?.defaultModel ?? "") ? nil : model,
            provider: provider == (loadedDescription?.provider ?? "") ? nil : provider,
            disabledSkills: draftDescription?.skills == loadedDescription?.skills ? nil : draftDescription?.disabledSkillNames,
            enabledToolsets: draftDescription?.toolsets == loadedDescription?.toolsets ? nil : draftDescription?.enabledToolsetNames,
            enabledMCPServers: draftDescription?.mcpServers == loadedDescription?.mcpServers ? nil : draftDescription?.enabledMCPServerNames
        )
        do {
            let result = try await environment.botManagement.applyEdit(edit, to: bot)
            record(result, edit: edit)
            if result.confirmRequired {
                pendingModelEdit = edit
                confirmMessage = result.confirmMessage
            } else if result.succeeded {
                await environment.refreshRoster()
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func record(_ result: BotProfileEditOutcome, edit: BotProfileEdit) {
        var combined = outcome ?? BotProfileEditOutcome()
        combined.appliedSections.formUnion(result.appliedSections)
        combined.failedSections.subtract(result.appliedSections)
        combined.failedSections.formUnion(result.failedSections)
        combined.confirmRequired = result.confirmRequired
        combined.confirmMessage = result.confirmMessage
        combined.metadataConflict = result.metadataConflict
        outcome = combined
        if result.appliedSections.contains(.metadata), let metadata = edit.metadata {
            baselineMetadata = metadata
            metadataRevision = result.newMetadataRevisions[BotModeContract.botsMetaKey] ?? metadataRevision
        }
        if result.appliedSections.contains(.soul) { loadedDescription?.soul = soul }
        if result.appliedSections.contains(.description) { loadedDescription?.descriptionText = descriptionText }
        if result.appliedSections.contains(.model) {
            loadedDescription?.defaultModel = model
            loadedDescription?.provider = provider
        }
        if result.appliedSections.contains(.skills) { loadedDescription?.skills = draftDescription?.skills ?? [] }
        if result.appliedSections.contains(.toolsets) { loadedDescription?.toolsets = draftDescription?.toolsets ?? [] }
        if result.appliedSections.contains(.mcpServers) { loadedDescription?.mcpServers = draftDescription?.mcpServers ?? [] }
    }

    private func confirmModelSwitch() async {
        guard let pending = pendingModelEdit else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let result = try await environment.botManagement.confirmModelEdit(pending, for: bot)
            record(result, edit: pending.modelOnlyResend)
            pendingModelEdit = nil
            if outcome?.succeeded == true {
                await environment.refreshRoster()
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Sections management sheet (D10): create/rename/delete/reorder + move
/// bots between sections. Registry writes ride the Fleet ui_meta key with
/// per-key CAS; deleting a section NEVER deletes bots (they fall to
/// unassigned — copy says so).
public struct SectionsManagementSheet: View {
    let environment: AppEnvironment
    let gateway: FleetGateway
    @Environment(\.dismiss) private var dismiss

    @State private var sections: [BotSection] = []
    @State private var newSectionName = ""
    @State private var renaming: BotSection?
    @State private var renameText = ""
    @State private var deleting: BotSection?
    @State private var errorMessage: String?
    @State private var isLoading = true

    public init(environment: AppEnvironment, gateway: FleetGateway) {
        self.environment = environment
        self.gateway = gateway
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Sections") {
                    if isLoading {
                        ProgressView("Loading sections…")
                    } else if sections.isEmpty {
                        Text("No sections yet.")
                            .foregroundStyle(FleetTheme.textSecondary)
                    }
                    ForEach(sections) { section in
                        Button {
                            renaming = section
                            renameText = section.name
                        } label: {
                            HStack {
                                Text(section.name)
                                Spacer()
                                Image(systemName: "pencil")
                                    .foregroundStyle(FleetTheme.textSecondary)
                            }
                        }
                        .accessibilityIdentifier("fleet.sections.row.\(section.id)")
                    }
                    .onMove { source, destination in
                        sections.move(fromOffsets: source, toOffset: destination)
                        Task { await persist() }
                    }
                    .onDelete { offsets in
                        if let first = offsets.first {
                            deleting = sections[first]
                        }
                    }
                }
                Section("New Section") {
                    TextField("Section name", text: $newSectionName)
                        .accessibilityIdentifier("fleet.sections.new-name")
                    Button("Add Section") {
                        Task { await addSection() }
                    }
                    .disabled(newSectionName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("fleet.sections.add")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(FleetTheme.statusDegraded)
                    }
                }
            }
            .navigationTitle("Edit Sections")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Delete section?", isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            )) {
                Button("Delete Section", role: .destructive) {
                    Task { await deleteSection() }
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text("Bots in “\(deleting?.name ?? "")” move to Unassigned. No bots are deleted.")
            }
            .alert("Rename section", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("New name", text: $renameText)
                Button("Rename") { Task { await renameSection() } }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .task { await load() }
        }
    }

    private func load() async {
        await environment.botManagement.loadSections(from: gateway.id)
        sections = environment.botManagement.sectionsByGateway[gateway.id] ?? []
        isLoading = false
    }

    private func addSection() async {
        let section = BotSection(
            id: BotSectionRegistry.newSectionID(),
            name: newSectionName.trimmingCharacters(in: .whitespaces))
        sections.append(section)
        newSectionName = ""
        await persist()
    }

    private func renameSection() async {
        guard let target = renaming else { return }
        if let index = sections.firstIndex(where: { $0.id == target.id }) {
            sections[index] = BotSection(id: target.id, name: renameText)
        }
        renaming = nil
        await persist()
    }

    private func deleteSection() async {
        guard let target = deleting else { return }
        sections.removeAll { $0.id == target.id }
        deleting = nil
        // NOTE: bots whose sectionId pointed here fall to Unassigned on the
        // NEXT metadata sync — upstream semantics; deleting a section never
        // deletes bots.
        await persist()
    }

    private func persist() async {
        do {
            try await environment.botManagement.saveSections(sections, on: gateway.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            await load()
        }
    }
}

/// Bot actions menu pieces: Duplicate (D11, confirmation listing inherited
/// vs never-copied) and Delete (D12, capability-gated with explanation).
public struct BotActionsMenu: View {
    let environment: AppEnvironment
    let bot: FleetBot

    @State private var duplicating = false
    @State private var duplicateSummary: BotDuplicateSummary?
    @State private var isWorking = false
    @State private var message: String?

    public init(environment: AppEnvironment, bot: FleetBot) {
        self.environment = environment
        self.bot = bot
    }

    public var body: some View {
        Menu {
            Button {
                duplicating = true
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .accessibilityIdentifier("fleet.bot.action.duplicate")

            // D12: delete is capability-gated for the current gateway
            // generation — disabled with an honest explanation, no facade.
            Button {
                message = environment.botManagement.deleteGate(for: bot.route.gatewayID).explanation
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("fleet.bot.action.delete")
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .disabled(isWorking)
        .sheet(isPresented: $duplicating) {
            DuplicateConfirmSheet(
                bot: bot,
                summary: duplicateSummary ?? BotDuplicateSummary.standard(
                    newProfileName: "…", source: bot, cloneAll: true)
            ) {
                Task { await runDuplicate() }
            }
        }
        .alert("Delete unavailable", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .task {
            // Pre-compute the duplicate name for the summary.
            let occupied = Set(
                (environment.rosterSnapshot?.roster.bots(on: bot.route.gatewayID) ?? [])
                    .map { $0.route.profileSlug.rawValue })
            if let name = BotDuplicateNaming.candidateName(
                base: bot.route.profileSlug.rawValue, occupiedNames: occupied) {
                duplicateSummary = BotDuplicateSummary.standard(
                    newProfileName: name, source: bot, cloneAll: true)
            }
        }
    }

    private func runDuplicate() async {
        isWorking = true
        defer { isWorking = false }
        let occupied = Set(
            (environment.rosterSnapshot?.roster.bots(on: bot.route.gatewayID) ?? [])
                .map { $0.route.profileSlug.rawValue })
        do {
            _ = try await environment.botManagement.duplicateBot(bot, occupiedNames: occupied)
            await environment.refreshRoster()
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Duplicate confirmation: lists what's inherited and what is never copied
/// (identity, canonical chat, created date).
struct DuplicateConfirmSheet: View {
    let bot: FleetBot
    let summary: BotDuplicateSummary
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("New bot") {
                    Text(summary.newProfileName)
                        .font(.body.weight(.semibold))
                }
                Section("Inherited") {
                    ForEach(summary.inherited, id: \.self) { item in
                        Label(item, systemImage: "checkmark")
                            .foregroundStyle(FleetTheme.textPrimary)
                    }
                }
                Section("Not copied") {
                    ForEach(summary.notInherited, id: \.self) { item in
                        Label(item, systemImage: "xmark")
                            .foregroundStyle(FleetTheme.textSecondary)
                    }
                }
            }
            .navigationTitle("Duplicate \(BotRosterPresentation.displayTitle(for: bot))")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Duplicate") {
                        dismiss()
                        onConfirm()
                    }
                    .accessibilityIdentifier("fleet.bot.duplicate.confirm")
                }
            }
        }
    }
}
