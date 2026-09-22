import SwiftUI
import FleetCore

/// Card B — the per-gateway Cron destination over the dashboard REST
/// contract (`/api/cron/jobs*`): rows with schedule / next-run / state /
/// delivery, a job DETAIL screen (ledger + run history + edit + run-now +
/// delete-with-confirm), and a create/edit form that edits in place (PUT),
/// never delete-recreate.
///
/// The pane is scoped to one gateway + profile; both are named on screen
/// (`cron.attribution`) so a job can never be mistaken for another gateway's.
public struct CronView: View {
    @Environment(\.fleetTheme) private var theme
    private let environment: AppEnvironment
    private let gatewayID: GatewayID
    private let profile: ProfileSlug
    @State private var model: CronDashboardModel?
    @State private var isShowingForm = false
    @State private var pendingDelete: CronJobRecord?

    public init(environment: AppEnvironment, gatewayID: GatewayID, profile: ProfileSlug) {
        self.environment = environment
        self.gatewayID = gatewayID
        self.profile = profile
    }

    public var body: some View {
        Group {
            if let model {
                cronContent(model)
            } else {
                unavailableContent
            }
        }
        .background(theme.background)
        .navigationTitle("Schedules")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: profileScope) {
            await bindModel()
        }
        .onDisappear {
            Task { model = nil }
        }
        .sheet(isPresented: $isShowingForm) {
            if let model {
                CronJobFormSheet(model: model, profile: profileScope, mode: .create)
            }
        }
        .alert(
            "Delete \"\(pendingDelete?.name ?? "job")\"?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                // No-op on dismiss: alert buttons run AFTER SwiftUI flips
                // isPresented to false (BotRoutinesView's trusted pattern).
                set: { _ in }
            ),
            presenting: pendingDelete
        ) { job in
            Button("Delete", role: .destructive) {
                let id = job.id
                pendingDelete = nil
                Task { await model?.deleteJob(id, profile: profileScope) }
            }
            .accessibilityIdentifier("cron.delete.confirm")
            Button("Cancel", role: .cancel) { pendingDelete = nil }
                .accessibilityIdentifier("cron.delete.cancel")
        } message: { job in
            Text("\(job.name) will be removed from this gateway. Its run history stays in the gateway's records.")
        }
        // Alert (not confirmationDialog): the codebase's trusted pattern for
        // destructive confirms (GatewaysView / BotRoutinesView) — dialog
        // cancel-role buttons don't expose reliably in the AX tree on iOS 26.
    }

    /// The profile whose cron store is shown.
    private var profileScope: String { profile.rawValue }

    private func bindModel() async {
        guard let seam = environment.makeCronDashboard(for: gatewayID) else {
            model = nil
            return
        }
        let next = CronDashboardModel(gatewayID: gatewayID, dashboard: seam)
        model = next
        await next.start(profile: profileScope)
    }

    /// "Gateway · profile" attribution — the scope is always named.
    private var attributionLine: String {
        let gateway = environment.gateway(for: gatewayID)?.displayName ?? gatewayID.rawValue
        return "\(gateway) · profile \(profileScope)"
    }

    // MARK: content

    @ViewBuilder
    private func cronContent(_ model: CronDashboardModel) -> some View {
        List {
            Section {
                Text(attributionLine)
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("cron.attribution")
                if let notice = model.notice {
                    FleetNoticeBar(notice, systemImage: "info.circle", id: "cron.notice")
                }
                if let error = model.errorMessage, !model.jobs.isEmpty {
                    FleetNoticeBar(
                        error,
                        systemImage: "exclamationmark.triangle.fill",
                        tone: .error,
                        id: "cron.error",
                        actionTitle: "Retry",
                        actionID: "cron.retry",
                        action: { Task { await model.refresh(profile: profileScope) } })
                }
            }

            if model.isLoading && model.jobs.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("Loading jobs…")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("cron.loading")
            } else if let error = model.errorMessage, model.jobs.isEmpty {
                errorContent(error, model: model)
            } else if model.jobs.isEmpty {
                emptyContent
            } else {
                ForEach(model.jobs) { job in
                    cronRow(job, model: model)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(
                            top: FleetTheme.spacingXs,
                            leading: FleetTheme.spacingLg,
                            bottom: FleetTheme.spacingXs,
                            trailing: FleetTheme.spacingLg))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await model.refresh(profile: profileScope)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingForm = true
                } label: {
                    Image(systemName: "plus")
                }
                .foregroundStyle(theme.highlight)
                .accessibilityLabel("New cron job")
                .accessibilityIdentifier("cron.new")
            }
        }
    }

    private func cronRow(_ job: CronJobRecord, model: CronDashboardModel) -> some View {
        // FOS-6: operational row (the List's own separators are the
        // hairlines — SPEC §18).
        FleetListRow(showsSeparator: false) {
            CronJobRow(
                job: job,
                model: model,
                profile: profile,
                gatewayID: gatewayID,
                environment: environment,
                onDelete: { record in
                    pendingDelete = record
                })

        }
    }

    private var emptyContent: some View {
        // FOS-6: inline empty state (SPEC §18 empty-state instruction).
        FleetNoticeBar(
            "No cron jobs on this profile. Tap + to schedule one.",
            systemImage: "clock.badge.checkmark",
            id: "cron.empty"
        )
    }

    private func errorContent(_ error: String, model: CronDashboardModel) -> some View {
        // FOS-6: contextual error notice with bounded Retry (SPEC §18
        // "contextual status" — no card per state).
        FleetNoticeBar(
            error,
            systemImage: "exclamationmark.triangle.fill",
            tone: .error,
            id: "cron.error",
            actionTitle: "Retry",
            actionID: "cron.retry",
            action: { Task { await model.refresh(profile: profileScope) } }
        )
    }

    private var unavailableContent: some View {
        ContentUnavailableView {
            Label("Cron Unavailable", systemImage: "clock.badge.exclamationmark")
        } description: {
            Text("This gateway has no dashboard cron surface wired. Reconnect and try again.")
        }
        .accessibilityIdentifier("cron.unavailable")
    }
}

/// Card B — the create/edit form. Create POSTs a new job; edit PUTs only the
/// changed fields to the SAME job id (identity preserved).
struct CronJobFormSheet: View {
    enum Mode {
        case create
        case edit(CronJobRecord)
    }

    @Environment(\.fleetTheme) private var theme
    @Bindable var model: CronDashboardModel
    let profile: String?
    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var schedule = ""
    @State private var prompt = ""
    @State private var deliver = "local"
    @State private var isSaving = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var idPrefix: String { isEditing ? "cron.edit" : "cron.form" }

    /// Edit mode validates against the ORIGINAL record: blank fields are left
    /// unchanged (never silently cleared).
    private var canSave: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSchedule = !schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasName && hasSchedule else { return false }
        if case .create = mode {
            return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Job Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("\(idPrefix).name")
                    TextField("Schedule (e.g. every day at 07:00)", text: $schedule)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("\(idPrefix).schedule")
                } header: {
                    Text("Job")
                        .foregroundStyle(theme.textSecondary)
                }
                Section {
                    TextField("Prompt", text: $prompt, axis: .vertical)
                        .lineLimit(4...10)
                        .accessibilityIdentifier("\(idPrefix).prompt")
                } header: {
                    Text("Prompt")
                        .foregroundStyle(theme.textSecondary)
                } footer: {
                    Text(isEditing
                         ? "Blank fields are left unchanged. The gateway validates the schedule and scans the prompt before saving."
                         : "The gateway validates the schedule and scans the prompt before storing it.")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                }
                Section {
                    Picker("Deliver to", selection: $deliver) {
                        ForEach(deliveryOptions, id: \.id) { target in
                            Text(target.homeTargetSet ? target.name : "\(target.name) — no channel set")
                                .tag(target.id)
                        }
                    }
                    .accessibilityIdentifier("\(idPrefix).deliver")
                } header: {
                    Text("Delivery")
                        .foregroundStyle(theme.textSecondary)
                } footer: {
                    if let selected = model.deliveryTargets.first(where: { $0.id == deliver }),
                       !selected.homeTargetSet {
                        Text("This target has no cron home channel configured on the gateway; deliveries will be recorded as unverified.")
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                if let formError = model.formError {
                    Section {
                        Label {
                            Text(formError)
                                .font(.caption)
                                .foregroundStyle(FleetTheme.statusDestructive)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(FleetTheme.statusDestructive)
                        }
                        .accessibilityIdentifier("\(idPrefix).error")
                    } header: {
                        Text("Save Failed")
                            .foregroundStyle(FleetTheme.statusDestructive)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(isEditing ? "Edit Cron Job" : "New Cron Job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("\(idPrefix).cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard canSave, !isSaving else { return }
                        isSaving = true
                        Task {
                            let ok = await save()
                            isSaving = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(!canSave || isSaving)
                    .foregroundStyle(theme.highlight)
                    .accessibilityIdentifier("\(idPrefix).save")
                }
            }
        }
        .tint(theme.highlight)
        .presentationDetents([.large])
        .accessibilityIdentifier(isEditing ? "cron.edit.sheet" : "cron.form.sheet")
        .onAppear(perform: prefill)
    }

    /// `local` is always offered (the implicit target), even before the
    /// gateway answers the delivery-targets read.
    private var deliveryOptions: [CronDeliveryTarget] {
        var options = model.deliveryTargets
        if !options.contains(where: { $0.id == "local" }) {
            options.insert(CronDeliveryTarget(id: "local", name: "Local (save only)", homeTargetSet: true), at: 0)
        }
        // An operator-set target the catalog does not list must stay
        // selectable — never silently rewrite it to another target.
        if !options.contains(where: { $0.id == deliver }) {
            options.append(CronDeliveryTarget(id: deliver, name: deliver, homeTargetSet: true))
        }
        return options
    }

    private func prefill() {
        model.clearFormError()
        guard case .edit(let job) = mode else { return }
        name = job.name
        schedule = job.scheduleDisplay
        prompt = job.prompt
        deliver = job.deliver
    }

    private func save() async -> Bool {
        switch mode {
        case .create:
            return await model.createJob(
                CronJobCreateRequest(name: name, schedule: schedule, prompt: prompt, deliver: deliver),
                profile: profile)
        case .edit(let job):
            // PUT only the changed fields — a blank field means "unchanged".
            var patch = CronJobPatch()
            if name.trimmingCharacters(in: .whitespacesAndNewlines) != job.name { patch.name = name }
            if schedule.trimmingCharacters(in: .whitespacesAndNewlines) != job.scheduleDisplay { patch.schedule = schedule }
            if prompt.trimmingCharacters(in: .whitespacesAndNewlines) != job.prompt { patch.prompt = prompt }
            if deliver != job.deliver { patch.deliver = deliver }
            guard !patch.isEmpty else { return true }
            return await model.updateJob(id: job.id, patch: patch, profile: profile)
        }
    }
}

/// Shared cron job row — renders identically in the legacy scoped CronView
/// pane and the Cron tab's per-machine sections. Identity rides the NAME
/// text (container ids would override the per-control ids).
struct CronJobRow: View {
    @Environment(\.fleetTheme) private var theme
    let job: CronJobRecord
    let model: CronDashboardModel
    let profile: ProfileSlug
    let gatewayID: GatewayID
    let environment: AppEnvironment
    let onDelete: (CronJobRecord) -> Void

    private var profileScope: String { profile.rawValue }

    var body: some View {
        HStack(spacing: FleetTheme.spacingMd) {
            Circle()
                .fill(job.enabled ? FleetTheme.statusOnline : theme.textMuted)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            NavigationLink {
                CronJobDetailView(
                    environment: environment,
                    gatewayID: gatewayID,
                    profile: profile,
                    jobID: job.id,
                    model: model)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                        .accessibilityIdentifier("cron.row.\(job.id)")
                    Text(job.scheduleDisplay)
                        .font(FleetTheme.monoFont)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("cron.row.schedule.\(job.id)")
                    if let preview = CronJobRow.previewText(job), !preview.isEmpty {
                        Text(preview)
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                    nextFireLine
                    deliveryLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await model.triggerJob(job.id, profile: profileScope) }
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(theme.highlight)
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .disabled(model.inFlightJobs.contains(job.id))
            .accessibilityLabel("Run \(job.name) now")
            .accessibilityIdentifier("cron.row.fire.\(job.id)")

            Button {
                Task { await model.setJob(job.id, enabled: !job.enabled, profile: profileScope) }
            } label: {
                Image(systemName: job.enabled ? "pause.circle" : "arrow.up.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(job.enabled ? theme.textSecondary : FleetTheme.statusOnline)
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .disabled(model.inFlightJobs.contains(job.id))
            .accessibilityLabel(job.enabled ? "Disable \(job.name)" : "Enable \(job.name)")
            .accessibilityIdentifier("cron.row.toggle.\(job.id)")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                Task { await model.setJob(job.id, enabled: !job.enabled, profile: profileScope) }
            } label: {
                Label(job.enabled ? "Disable" : "Enable", systemImage: job.enabled ? "pause.circle" : "arrow.up.circle")
            }
            .tint(job.enabled ? theme.textSecondary : FleetTheme.statusOnline)
            .accessibilityIdentifier("cron.swipe.toggle.\(job.id)")

            Button(role: .destructive) {
                onDelete(job)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("cron.swipe.delete.\(job.id)")
        }
    }

    /// Prompt preview; script jobs preview their script instead.
    static func previewText(_ job: CronJobRecord) -> String? {
        if !job.prompt.isEmpty { return job.prompt }
        if let script = job.script, !script.isEmpty { return "script: \(script)" }
        return nil
    }
}

extension CronJobRow {
    /// Telemetry timestamps — mono caption.
    @ViewBuilder
    private var nextFireLine: some View {
        HStack(spacing: FleetTheme.spacingSm) {
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(theme.textMuted)
                .accessibilityHidden(true)
            Text(job.enabled
                 ? (CronTimestamp.display(job.nextRunAt) ?? "no upcoming run")
                 : "Paused")
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(job.enabled ? theme.textSecondary : theme.textMuted)
                .accessibilityIdentifier("cron.row.nextfire.\(job.id)")
            if let status = job.lastStatus, !status.isEmpty {
                // Status, not state (`CronJobRecord.isFailureStatus`): a failed
                // last run on a still-scheduled job is the operator's warning,
                // and a completed one-shot with "ok" is not.
                Label(status, systemImage: job.isFailureStatus ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath")
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(job.isFailureStatus ? FleetTheme.statusDestructive : theme.textMuted)
            }
        }
    }

    /// Delivery target + state, compact: the operator always sees where a job
    /// delivers and what state the server reports.
    @ViewBuilder
    private var deliveryLine: some View {
        HStack(spacing: FleetTheme.spacingSm) {
            Image(systemName: "paperplane")
                .font(.caption2)
                .foregroundStyle(theme.textMuted)
                .accessibilityHidden(true)
            Text(model.deliveryLabel(for: job.deliver))
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .accessibilityIdentifier("cron.row.deliver.\(job.id)")
            Text("· \(job.displayState)")
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(job.isTerminalOrError ? FleetTheme.statusDestructive : theme.textMuted)
                .accessibilityIdentifier("cron.row.state.\(job.id)")
        }
    }
}
