import SwiftUI
import FleetCore

/// R9-T5 — the per-gateway Cron pane (Gold Fleet design).
///
/// Rows: name, mono schedule, next-fire, status dot. Swipe actions
/// enable/disable and delete; a toolbar + row menu offer fire-now (the
/// gateway's run action) and New Job (form sheet reusing the
/// GatewayFormSheet styling). Jobs are scoped to the gateway's profile —
/// the profile picker rides the header (scripted/simulator: default).
public struct CronView: View {
    private let environment: AppEnvironment
    private let gatewayID: GatewayID
    private let profile: ProfileSlug
    @State private var model: ManagementPanesViewModel?
    @State private var isShowingForm = false

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
        .background(FleetTheme.background)
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
                CronJobFormSheet(model: model, profile: profileScope)
            }
        }
    }

    /// The profile whose cron store is shown. The roster's bot routes for
    /// this gateway enumerate its profiles; single-profile gateways (the
    /// common case) skip the picker entirely.
    private var profileScope: String { profile.rawValue }

    private func bindModel() async {
        guard let seam = environment.makeManagementSeam(for: gatewayID) else {
            model = nil
            return
        }
        let next = ManagementPanesViewModel(gatewayID: gatewayID, management: seam)
        model = next
        await next.start(profile: profileScope)
    }

    // MARK: content

    @ViewBuilder
    private func cronContent(_ model: ManagementPanesViewModel) -> some View {
        List {
            if model.isLoading && model.cronJobs.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("Loading jobs…")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("cron.loading")
            } else if let error = model.errorMessage, model.cronJobs.isEmpty {
                errorContent(error, model: model)
            } else if model.cronJobs.isEmpty {
                emptyContent
            } else {
                if let notice = model.notice {
                    noticeCard(notice)
                }
                ForEach(model.cronJobs) { job in
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
                .foregroundStyle(FleetTheme.accent)
                .accessibilityLabel("New cron job")
                .accessibilityIdentifier("cron.new")
            }
        }
    }

    private func cronRow(_ job: CronJob, model: ManagementPanesViewModel) -> some View {
        // FOS-6: operational row (the List's own separators are the
        // hairlines — SPEC §18).
        FleetListRow(showsSeparator: false) {
            HStack(spacing: FleetTheme.spacingMd) {
                Circle()
                    .fill(job.isEnabled ? FleetTheme.statusOnline : FleetTheme.statusOffline)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FleetTheme.textPrimary)
                        // The row identity rides the NAME text — a
                        // container-level identifier propagates to every
                        // descendant and overrides the per-control ids.
                        .accessibilityIdentifier("cron.row.\(job.jobID)")
                    // Schedule is machine data — mono, the terminal voice.
                    Text(job.schedule)
                        .font(FleetTheme.monoFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("cron.row.schedule.\(job.jobID)")
                    if let preview = job.promptPreview, !preview.isEmpty {
                        Text(preview)
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(FleetTheme.textSecondary)
                            .lineLimit(1)
                    }
                    nextFireLine(job)
                }
                Spacer()
                Button {
                    Task { await model.fireCronJob(job.jobID, profile: profileScope) }
                } label: {
                    Image(systemName: "play.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(FleetTheme.accent)
                }
                .buttonStyle(.borderless)
                // FOS-6 tap-target: the 18pt icon is a real action — pad to
                // the 44pt actionable bar (SPEC §21 gate 15).
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .disabled(model.inFlightJobs.contains(job.jobID))
                .accessibilityLabel("Run \(job.name) now")
                .accessibilityIdentifier("cron.row.fire.\(job.jobID)")

                Button {
                    Task { await model.setCronJob(job.jobID, enabled: !job.isEnabled, profile: profileScope) }
                } label: {
                    Image(systemName: job.isEnabled ? "pause.circle" : "arrow.up.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(job.isEnabled ? FleetTheme.textSecondary : FleetTheme.statusOnline)
                }
                .buttonStyle(.borderless)
                // FOS-6 tap-target: pad to the 44pt actionable bar.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .disabled(model.inFlightJobs.contains(job.jobID))
                .accessibilityLabel(job.isEnabled ? "Disable \(job.name)" : "Enable \(job.name)")
                .accessibilityIdentifier("cron.row.toggle.\(job.jobID)")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                Task { await model.setCronJob(job.jobID, enabled: !job.isEnabled, profile: profileScope) }
            } label: {
                Label(job.isEnabled ? "Disable" : "Enable", systemImage: job.isEnabled ? "pause.circle" : "arrow.up.circle")
            }
            .tint(job.isEnabled ? FleetTheme.statusIdle : FleetTheme.statusOnline)
            .accessibilityIdentifier("cron.swipe.toggle.\(job.jobID)")

            Button(role: .destructive) {
                Task { await model.deleteCronJob(job.jobID, profile: profileScope) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("cron.swipe.delete.\(job.jobID)")
        }
        // NOTE: NO container-level identifier or .combine — SwiftUI
        // propagates a container's identifier to every descendant,
        // REPLACING the per-control ids (fire/toggle/swipe). Row identity
        // rides the job-name text; controls keep their own ids.
    }

    @ViewBuilder
    private func nextFireLine(_ job: CronJob) -> some View {
        // Telemetry timestamps — mono caption.
        HStack(spacing: FleetTheme.spacingSm) {
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(FleetTheme.textMuted)
                .accessibilityHidden(true)
            Text(job.isEnabled ? (job.nextRunAt ?? "no upcoming run") : "Paused")
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(job.isEnabled ? FleetTheme.textSecondary : FleetTheme.statusOffline)
            if let last = job.lastStatus, !last.isEmpty {
                Label(last, systemImage: ["failed", "error", "failure"].contains(last.lowercased()) ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath")
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(["failed", "error", "failure"].contains(last.lowercased()) ? FleetTheme.statusDegraded : FleetTheme.textMuted)
            }
        }
    }

    private func noticeCard(_ text: String) -> some View {
        // FOS-6: bounded notice, not a card.
        FleetNoticeBar(text, systemImage: "info.circle", id: "cron.notice")
    }

    private var emptyContent: some View {
        // FOS-6: inline empty state (SPEC §18 empty-state instruction).
        FleetNoticeBar(
            "No cron jobs on this profile. Tap + to schedule one.",
            systemImage: "clock.badge.checkmark",
            id: "cron.empty"
        )
    }

    private func errorContent(_ error: String, model: ManagementPanesViewModel) -> some View {
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
            Text("This gateway has no management session wired. Reconnect and try again.")
        }
        .accessibilityIdentifier("cron.unavailable")
    }
}

/// R9-T5 — new-job form sheet (GatewayFormSheet styling: Form sections,
/// FleetTheme surfaces, explicit Save/Cancel, non-dismissable while saving).
struct CronJobFormSheet: View {
    @Bindable var model: ManagementPanesViewModel
    let profile: String?

    @Environment(\.dismiss) private var dismiss
    @State private var draft = CronJobDraft()
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Job Name", text: $draft.name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("cron.form.name")
                    TextField("Schedule (e.g. every day at 07:00)", text: $draft.schedule)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("cron.form.schedule")
                } header: {
                    Text("Job")
                        .foregroundStyle(FleetTheme.textSecondary)
                }
                Section {
                    TextField("Prompt", text: $draft.prompt, axis: .vertical)
                        .lineLimit(4...10)
                        .accessibilityIdentifier("cron.form.prompt")
                } header: {
                    Text("Prompt")
                        .foregroundStyle(FleetTheme.textSecondary)
                } footer: {
                    Text("The gateway validates the schedule and scans the prompt before storing it.")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                }
                if let formError = model.formError {
                    Section {
                        Label {
                            Text(formError)
                                .font(.caption)
                                .foregroundStyle(FleetTheme.statusDegraded)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(FleetTheme.statusDegraded)
                        }
                        .accessibilityIdentifier("cron.form.error")
                    } header: {
                        Text("Save Failed")
                            .foregroundStyle(FleetTheme.statusDegraded)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(FleetTheme.background.ignoresSafeArea())
            .navigationTitle("New Cron Job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("cron.form.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard draft.isValid, !isSaving else { return }
                        isSaving = true
                        Task {
                            let ok = await model.createCronJob(draft, profile: profile)
                            isSaving = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(!draft.isValid || isSaving)
                    .foregroundStyle(FleetTheme.accent)
                    .accessibilityIdentifier("cron.form.save")
                }
            }
        }
        .tint(FleetTheme.accent)
        .presentationDetents([.large])
        .accessibilityIdentifier("cron.form.sheet")
    }
}
