import SwiftUI
import FleetCore

/// Card B — the Cron job DETAIL screen: full record (schedule, next run,
/// last run/status, delivery, definition), the execution ledger, agent run
/// history, gateway + profile attribution, and the job actions (run now,
/// pause/resume, edit-in-place, delete-with-confirm).
struct CronJobDetailView: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let environment: AppEnvironment
    let gatewayID: GatewayID
    let profile: ProfileSlug
    let jobID: String
    @Bindable var model: CronDashboardModel

    @State private var isShowingEdit = false
    @State private var isConfirmingDelete = false

    private var profileScope: String { profile.rawValue }

    private var attributionLine: String {
        let gateway = environment.gateway(for: gatewayID)?.displayName ?? gatewayID.rawValue
        return "\(gateway) · profile \(profileScope)"
    }

    var body: some View {
        List {
            // Guard by id: the model is shared per gateway, so a record that
            // belongs to ANOTHER job must never paint here (the model also
            // clears it when the requested id changes — this closes the window
            // before the first read lands).
            if let job = model.detail, job.id == jobID {
                headerSection(job)
                scheduleSection(job)
                deliverySection(job)
                definitionSection(job)
                ledgerSection(job)
                runsSection(job)
                actionsSection(job)
            } else if model.isLoadingDetail || model.detail != nil {
                // A mismatched record means a switch is in flight: show the
                // loading state, never the other job's data.
                HStack {
                    Spacer()
                    ProgressView("Loading job…")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("cron.detail.loading")
            } else if let error = model.detailError {
                FleetNoticeBar(
                    error,
                    systemImage: "exclamationmark.triangle.fill",
                    tone: .error,
                    id: "cron.detail.error",
                    actionTitle: "Retry",
                    actionID: "cron.detail.retry",
                    action: { Task { await model.refreshDetail(id: jobID, profile: profileScope) } })
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .navigationTitle(model.detail?.name ?? "Job")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refreshDetail(id: jobID, profile: profileScope) }
        .task(id: jobID) {
            await model.refreshDetail(id: jobID, profile: profileScope)
        }
        .sheet(isPresented: $isShowingEdit) {
            if let job = model.detail {
                CronJobFormSheet(model: model, profile: profileScope, mode: .edit(job))
            }
        }
        .alert(
            "Delete \"\(model.detail?.name ?? "job")\"?",
            isPresented: $isConfirmingDelete
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    if await model.deleteJob(jobID, profile: profileScope) {
                        dismiss()
                    }
                }
            }
            .accessibilityIdentifier("cron.detail.delete.confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("cron.detail.delete.cancel")
        } message: {
            Text("The job is removed from this gateway. Its run history stays in the gateway's records.")
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func headerSection(_ job: CronJobRecord) -> some View {
        Section {
            Text(job.name)
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
                .accessibilityIdentifier("cron.detail.name")
            HStack(spacing: FleetTheme.spacingSm) {
                Circle()
                    .fill(job.enabled ? FleetTheme.statusOnline : theme.textMuted)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(job.displayState)
                    .font(FleetTheme.monoFont)
                    .foregroundStyle(job.isTerminalOrError ? FleetTheme.statusDestructive : theme.textSecondary)
                    .accessibilityIdentifier("cron.detail.state")
                Spacer()
                if !job.enabled {
                    Text("paused")
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textMuted)
                }
            }
            Text(attributionLine)
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(theme.textSecondary)
                .accessibilityIdentifier("cron.detail.attribution")
            Text("job \(job.id)")
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(theme.textMuted)
                .accessibilityIdentifier("cron.detail.id")
        } header: {
            Text("Job")
                .foregroundStyle(theme.textSecondary)
        }
    }

    @ViewBuilder
    private func scheduleSection(_ job: CronJobRecord) -> some View {
        Section {
            detailRow("Schedule", value: job.scheduleDisplay, mono: true, id: "cron.detail.schedule")
            if !job.schedule.kind.isEmpty {
                detailRow("Kind", value: job.schedule.kind, mono: true, id: "cron.detail.kind")
            }
            detailRow(
                "Next run",
                value: job.enabled ? (CronTimestamp.display(job.nextRunAt) ?? "no upcoming run") : "paused — no upcoming run",
                mono: true, id: "cron.detail.next")
            detailRow("Last run", value: CronTimestamp.display(job.lastRunAt) ?? "never", mono: true, id: "cron.detail.last")
            if let status = job.lastStatus, !status.isEmpty {
                // The tone follows the STATUS, never the job state: a scheduled
                // job can carry a failed last run, and a completed one-shot has
                // a healthy status (see `CronJobRecord.isFailureStatus`).
                detailRow("Last status", value: status, mono: true, id: "cron.detail.lastStatus",
                          tone: job.isFailureStatus ? FleetTheme.statusDestructive : nil)
            }
            if let streak = job.failureStreak, streak > 0 {
                detailRow("Failure streak", value: "\(streak)", mono: true, id: "cron.detail.failureStreak")
            }
            if let reason = job.pausedReason, !reason.isEmpty {
                detailRow("Paused because", value: reason, id: "cron.detail.pausedReason")
            }
            if let error = job.lastError, !error.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last error")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                    Text(error)
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(FleetTheme.statusDestructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("cron.detail.lastError")
            }
        } header: {
            Text("Schedule")
                .foregroundStyle(theme.textSecondary)
        }
    }

    @ViewBuilder
    private func deliverySection(_ job: CronJobRecord) -> some View {
        Section {
            detailRow("Deliver to", value: model.deliveryLabel(for: job.deliver), mono: true, id: "cron.detail.deliver")
            if let failure = job.failureDeliver, !failure.isEmpty {
                detailRow("Failures deliver to", value: model.deliveryLabel(for: failure), mono: true, id: "cron.detail.failureDeliver")
            }
            if let error = job.lastDeliveryError, !error.isEmpty {
                detailRow("Last delivery error", value: error, id: "cron.detail.deliveryError",
                          tone: FleetTheme.statusDestructive)
            }
            if let unverified = job.lastDeliveryUnverified, !unverified.isEmpty {
                detailRow("Delivery unverified", value: unverified, id: "cron.detail.deliveryUnverified")
            }
        } header: {
            Text("Delivery")
                .foregroundStyle(theme.textSecondary)
        }
    }

    @ViewBuilder
    private func definitionSection(_ job: CronJobRecord) -> some View {
        Section {
            if !job.prompt.isEmpty {
                Text(job.prompt)
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cron.detail.prompt")
            }
            if let script = job.script, !script.isEmpty {
                detailRow("Script", value: script, mono: true, id: "cron.detail.script")
            }
            if job.noAgent {
                detailRow("Mode", value: "script (no agent turn)", mono: true, id: "cron.detail.mode")
            }
            if !job.skills.isEmpty {
                detailRow("Skills", value: job.skills.joined(separator: ", "), mono: true, id: "cron.detail.skills")
            }
            if let model = job.model, !model.isEmpty {
                detailRow("Model", value: model, mono: true, id: "cron.detail.model")
            }
            if let provider = job.provider, !provider.isEmpty {
                detailRow("Provider", value: provider, mono: true, id: "cron.detail.provider")
            }
            if let times = job.repeatTimes {
                detailRow("Repeats", value: "\(times)", mono: true, id: "cron.detail.repeat")
            } else if let completed = job.repeatCompleted, completed > 0 {
                detailRow("Runs completed", value: "\(completed)", mono: true, id: "cron.detail.repeat")
            }
            detailRow("Created", value: CronTimestamp.display(job.createdAt) ?? "unknown", mono: true, id: "cron.detail.created")
            if let updated = job.updatedAt, !updated.isEmpty {
                detailRow("Updated", value: CronTimestamp.display(updated) ?? updated, mono: true, id: "cron.detail.updated")
            }
        } header: {
            Text("Definition")
                .foregroundStyle(theme.textSecondary)
        }
    }

    @ViewBuilder
    private func ledgerSection(_ job: CronJobRecord) -> some View {
        Section {
            if let execution = model.ledger(for: job.id) {
                detailRow("Status", value: execution.status, mono: true, id: "cron.detail.execution.status",
                          tone: ["failed", "error"].contains(execution.status.lowercased()) ? FleetTheme.statusDestructive : nil)
                detailRow("Started", value: CronTimestamp.display(execution.startedAt) ?? "unknown", mono: true, id: "cron.detail.execution.started")
                detailRow("Finished", value: CronTimestamp.display(execution.finishedAt) ?? "still running", mono: true, id: "cron.detail.execution.finished")
                if let outcome = execution.deliveryOutcome, !outcome.isEmpty {
                    detailRow("Delivery", value: outcome, mono: true, id: "cron.detail.execution.delivery")
                }
                if let error = execution.error, !error.isEmpty {
                    Text(error)
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(FleetTheme.statusDestructive)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("cron.detail.execution.error")
                }
            } else {
                Text("No execution recorded yet — this job has not fired.")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("cron.detail.execution.empty")
            }
        } header: {
            Text("Latest execution")
                .foregroundStyle(theme.textSecondary)
        } footer: {
            Text("The execution ledger is recorded for every fire — script jobs included.")
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(theme.textMuted)
        }
    }

    @ViewBuilder
    private func runsSection(_ job: CronJobRecord) -> some View {
        Section {
            if model.isLoadingRuns && model.detailRuns.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("cron.detail.runs.loading")
            } else if let error = model.runsError {
                FleetNoticeBar(
                    error,
                    systemImage: "exclamationmark.triangle.fill",
                    tone: .error,
                    id: "cron.detail.runs.error")
            } else if model.detailRuns.isEmpty {
                // Honest empty state: script jobs short-circuit before the
                // session store, so they have NO run sessions by design.
                Text(job.noAgent
                     ? "Script jobs run without a session — the execution ledger above is their history."
                     : "No run sessions recorded yet. A run appears here after the job produces an agent session.")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cron.detail.runs.empty")
            } else {
                ForEach(model.detailRuns) { run in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.title.isEmpty ? run.id : run.title)
                            .font(.body)
                            .foregroundStyle(theme.textPrimary)
                            .accessibilityIdentifier("cron.detail.run.\(run.id)")
                        HStack(spacing: FleetTheme.spacingSm) {
                            Text(CronTimestamp.display(epochSeconds: run.startedAt) ?? "unknown start")
                            if run.isActive {
                                Text("· running")
                                    .foregroundStyle(FleetTheme.statusOnline)
                            } else if let ended = CronTimestamp.display(epochSeconds: run.endedAt) {
                                Text("· ended \(ended)")
                            }
                            if let count = run.messageCount {
                                Text("· \(count) messages")
                            }
                        }
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textSecondary)
                    }
                }
            }
        } header: {
            Text("Run history")
                .foregroundStyle(theme.textSecondary)
        } footer: {
            if job.noAgent {
                Text("Runs are agent sessions; script jobs do not create one.")
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(theme.textMuted)
            }
        }
    }

    @ViewBuilder
    private func actionsSection(_ job: CronJobRecord) -> some View {
        Section {
            Button {
                Task { await model.triggerJob(job.id, profile: profileScope) }
            } label: {
                Label("Run now", systemImage: "play.circle")
            }
            .disabled(model.inFlightJobs.contains(job.id))
            .accessibilityIdentifier("cron.detail.fire")

            Button {
                Task { await model.setJob(job.id, enabled: !job.enabled, profile: profileScope) }
            } label: {
                Label(job.enabled ? "Pause" : "Resume",
                      systemImage: job.enabled ? "pause.circle" : "arrow.up.circle")
            }
            .disabled(model.inFlightJobs.contains(job.id))
            .accessibilityIdentifier("cron.detail.toggle")

            Button {
                isShowingEdit = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .accessibilityIdentifier("cron.detail.edit")

            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("cron.detail.delete")
        } footer: {
            if let notice = model.notice {
                Text(notice)
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("cron.detail.notice")
            }
        }
    }

    // MARK: Row helper

    private func detailRow(
        _ label: String,
        value: String,
        mono: Bool = false,
        id: String,
        tone: Color? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: FleetTheme.spacingSm)
            Text(value)
                .font(mono ? FleetTheme.monoCaptionFont : FleetTheme.secondaryFont)
                .foregroundStyle(tone ?? theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
        .accessibilityIdentifier(id)
    }
}