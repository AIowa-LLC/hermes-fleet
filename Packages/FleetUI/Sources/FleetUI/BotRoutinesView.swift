import SwiftUI
import Observation
import FleetCore

/// TRUE BOTS MODE slice 3 (D13) — observable state for the bot-scoped
/// Routines surface (a bot's namespaced cron jobs over the existing
/// `GatewayManagementProviding` seam).
///
/// Scope rules (card + mission item 10):
/// - Lists ONLY this bot's `[bot:<slug>] <routine>` jobs (profile-scoped
///   list with include_disabled so paused routines stay visible).
/// - The gateway-wide Cron pane keeps the FULL list — this view model
///   never mutates or filters the general cron surface.
/// - Create stamps the `[bot:<slug>]` namespace on the name and defaults
///   deliver to the bot's canonical Bot Chat (`bot-chat:<slug>`).
/// - Run-now honesty: `cron.manage` does not expose `run` on the ws
///   surface (methods_tools.py:1033-1057 — unknown action → 4016). The
///   first attempt sends the correct wire spelling; a typed
///   `unsupportedAction` answer flips `runNowUnsupported` on and the UI
///   gates the control with an explanation. Never a facade, never
///   cli.exec.
@MainActor
@Observable
public final class BotRoutinesViewModel {
    // MARK: Observable state

    /// This bot's routines (namespace-parsed, paused included).
    public private(set) var routines: [BotRoutine] = []
    /// True while the initial load is in flight.
    public private(set) var isLoading = false
    /// Routine actions in flight (job ids).
    public private(set) var inFlight: Set<String> = []
    /// Last surface error (non-secret).
    public private(set) var errorMessage: String?
    /// Honest informational notice (e.g. run-now result).
    public private(set) var notice: String?
    /// Create-form error.
    public private(set) var formError: String?
    /// True once the gateway answered 4016 for `run` — the honest
    /// unsupported capability state (no retry loop against a wall).
    public private(set) var runNowUnsupported = false
    /// Job id pending destructive remove confirmation.
    public private(set) var pendingRemoval: BotRoutine?
    /// Count of successful pause/resume toggles (test observability).
    public private(set) var toggled = 0

    // MARK: Dependencies

    public let route: Route
    private let management: any GatewayManagementProviding

    /// The owning bot's profile slug — the cron store scope AND the
    /// namespace owner.
    public var profileSlug: String { route.profileSlug.rawValue }

    public init(route: Route, management: any GatewayManagementProviding) {
        self.route = route
        self.management = management
    }

    // MARK: Lifecycle

    /// Load the bot's routines (include_disabled semantics ride the seam's
    /// list call — paused routines must stay visible).
    public func start() async {
        isLoading = true
        defer { isLoading = false }
        await reload()
    }

    public func refresh() async {
        await reload()
    }

    private func reload() async {
        do {
            let jobs = try await management.listCronJobs(profile: profileSlug)
            routines = BotRoutineFilter.routines(in: jobs, owner: profileSlug)
            errorMessage = nil
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    // MARK: Pause / resume

    /// Toggle pause/resume on the wire; the server's returned row is the
    /// truth (never a client-side fabrication of state).
    public func setRoutine(_ routine: BotRoutine, enabled: Bool) async {
        guard !inFlight.contains(routine.jobID) else { return }
        inFlight.insert(routine.jobID)
        defer { inFlight.remove(routine.jobID) }
        do {
            _ = try await management.setCronJob(routine.jobID, enabled: enabled, profile: profileSlug)
            await reload()
            toggled += 1
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    // MARK: Remove (destructive confirm)

    /// Arm the destructive confirmation for a routine.
    public func requestRemoval(of routine: BotRoutine) {
        pendingRemoval = routine
    }

    public func cancelRemoval() {
        pendingRemoval = nil
    }

    /// Confirmed remove — `cron.manage {action:"remove"}` on the wire.
    public func confirmRemoval() async {
        guard let routine = pendingRemoval else { return }
        pendingRemoval = nil
        guard !inFlight.contains(routine.jobID) else { return }
        inFlight.insert(routine.jobID)
        defer { inFlight.remove(routine.jobID) }
        do {
            try await management.deleteCronJob(routine.jobID, profile: profileSlug)
            routines.removeAll { $0.jobID == routine.jobID }
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    // MARK: Create

    /// Create a routine: the caller-supplied label is stamped into the
    /// `[bot:<slug>]` namespace; deliver defaults to the bot's canonical
    /// Bot Chat target.
    @discardableResult
    public func createRoutine(label: String, schedule: String, prompt: String) async -> Bool {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let sched = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !sched.isEmpty, !body.isEmpty else {
            formError = "A routine needs a name, a schedule, and a prompt."
            return false
        }
        guard BotRoutineNamespace.parse(BotRoutineNamespace.jobName(owner: profileSlug, routine: name)) != nil else {
            formError = "The name can't contain line breaks or a ']' after the bot prefix."
            return false
        }
        let draft = CronJobDraft(
            name: BotRoutineNamespace.jobName(owner: profileSlug, routine: name),
            schedule: sched,
            prompt: body,
            deliver: Self.botChatDeliverTarget(for: profileSlug))
        do {
            let created = try await management.createCronJob(draft: draft, profile: profileSlug)
            if let routine = BotRoutine(job: created, owner: profileSlug) {
                routines.append(routine)
            } else {
                // The server echoed a name we could not parse back as this
                // bot's routine — reload rather than fabricate a row.
                await reload()
            }
            formError = nil
            return true
        } catch {
            formError = Self.describe(error)
            return false
        }
    }

    /// `bot-chat[:name]` deliver target for the bot's canonical chat
    /// (cronjob_job_args.py `_validate_bot_chat_deliver` — the optional
    /// `:name` form addresses a specific profile's chat).
    public static func botChatDeliverTarget(for slug: String) -> String {
        "bot-chat:\(slug)"
    }

    // MARK: Run now — honest capability gate

    /// Fire a routine now. The ws surface does not expose `run` on
    /// hermes-agent 0.21.0 — the attempt is sent with the correct wire
    /// spelling, and a typed 4016 answer flips the honest unsupported
    /// state instead of pretending success.
    public func runNow(_ routine: BotRoutine) async {
        guard !runNowUnsupported, !inFlight.contains(routine.jobID) else { return }
        inFlight.insert(routine.jobID)
        defer { inFlight.remove(routine.jobID) }
        do {
            try await management.fireCronJob(routine.jobID, profile: profileSlug)
            notice = "Run requested — \(routine.routineName) is firing now."
            await reload()
        } catch let error as GatewayManagementError {
            if case .unsupportedAction = error {
                runNowUnsupported = true
                notice = Self.runNowUnsupportedCopy
            } else {
                errorMessage = error.errorDescription
            }
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// Plain-language honest explanation for the run-now gate.
    public static let runNowUnsupportedCopy =
        "This gateway can't run routines on demand — cron.manage doesn't expose run over the socket. The routine still fires on its schedule."

    // MARK: helpers

    static func describe(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return String(describing: error)
    }
}

/// TRUE BOTS MODE slice 3 (D13) — the bot-scoped Routines surface: the
/// tapped bot's namespaced cron jobs (list / create / pause / resume /
/// remove-with-confirmation / next+last run / failure detail), Fleet
/// visual language (operational rows, mono schedule, status colors).
///
/// The gateway-wide Cron pane (CronView) is untouched — routines never
/// hijack or filter the general cron list; this surface shows only
/// `[bot:<slug>]`-namespaced jobs of THIS bot.
public struct BotRoutinesView: View {
    @Environment(\.fleetTheme) private var theme
    private let environment: AppEnvironment
    private let route: Route
    /// FOS-5: when embedded as Bot Detail's Routines segment, the view
    /// suppresses its own navigation title (the detail screen owns it).
    private let embedded: Bool
    @State private var model: BotRoutinesViewModel?
    @State private var isShowingForm = false

    public init(environment: AppEnvironment, route: Route, embedded: Bool = false) {
        self.environment = environment
        self.route = route
        self.embedded = embedded
    }

    public var body: some View {
        Group {
            if let model {
                routinesContent(model)
            } else {
                unavailableContent
            }
        }
        .background(theme.background)
        .navigationTitle(embedded ? "" : "Routines")
        .navigationBarTitleDisplayMode(embedded ? .inline : .automatic)
        .task {
            await bindModel()
        }
        .onDisappear {
            Task { model = nil }
        }
        .sheet(isPresented: $isShowingForm) {
            if let model {
                BotRoutineFormSheet(model: model)
            }
        }
    }

    private func bindModel() async {
        guard model == nil else { return }
        guard let seam = environment.makeManagementSeam(for: route.gatewayID) else {
            model = nil
            return
        }
        let next = BotRoutinesViewModel(route: route, management: seam)
        model = next
        await next.start()
    }

    // MARK: content

    @ViewBuilder
    private func routinesContent(_ model: BotRoutinesViewModel) -> some View {
        // FOS-5: a Lazy stack (not a lazy List) — embedded inside Bot
        // Detail's outer ScrollView a nested List never materializes rows
        // below the fold for accessibility. Identifiers are unchanged.
        LazyVStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
            if model.isLoading && model.routines.isEmpty {
                loadingRow
            } else if let error = model.errorMessage, model.routines.isEmpty {
                errorCard(error, model: model)
            } else if model.routines.isEmpty {
                emptyCard(model: model)
            } else {
                if model.runNowUnsupported {
                    unsupportedRunCard
                } else if let notice = model.notice {
                    noticeCard(notice)
                }
                ForEach(model.routines) { routine in
                    routineRow(routine, model: model)
                        .padding(.horizontal, FleetTheme.spacingLg)
                        .padding(.vertical, FleetTheme.spacingXs)
                }
            }
        }
        .padding(.vertical, FleetTheme.spacingSm)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingForm = true
                } label: {
                    Image(systemName: "plus")
                }
                .foregroundStyle(theme.highlight)
                .accessibilityLabel("New routine")
                .accessibilityIdentifier("routines.new")
            }
        }
        // Destructive remove confirmation — typed, names the routine.
        // Alert (not confirmationDialog): the codebase's trusted pattern
        // for destructive confirms (GatewaysView) — dialog cancel-role
        // buttons don't expose reliably in the AX tree on iOS 26.
        .alert(
            "Remove Routine",
            isPresented: Binding(
                get: { model.pendingRemoval != nil },
                // No-op on dismiss: alert buttons run AFTER SwiftUI flips
                // isPresented to false — cancelling here would nil
                // pendingRemoval before confirmRemoval() runs. Both buttons
                // own their state transition themselves.
                set: { _ in }
            )
        ) {
            Button("Remove \(model.pendingRemoval?.routineName ?? "")", role: .destructive) {
                Task { await model.confirmRemoval() }
            }
            .accessibilityIdentifier("routines.remove.confirm")
            Button("Cancel", role: .cancel) {
                model.cancelRemoval()
            }
            .accessibilityIdentifier("routines.remove.cancel")
        } message: {
            Text("The routine stops running and its schedule is deleted from the gateway. This can't be undone.")
        }
    }

    private func routineRow(_ routine: BotRoutine, model: BotRoutinesViewModel) -> some View {
        // FOS-6: operational row (SPEC §18).
        FleetListRow(showsSeparator: false) {
            HStack(spacing: FleetTheme.spacingMd) {
                Circle()
                    .fill(routine.isEnabled ? FleetTheme.statusOnline : theme.textMuted)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    // Row identity rides the name text (CronView pattern —
                    // a container identifier would override child ids).
                    Text(routine.routineName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                        .accessibilityIdentifier("routines.row.\(routine.jobID)")
                    // Schedule is machine data — mono, the terminal voice.
                    Text(routine.schedule)
                        .font(FleetTheme.monoFont)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("routines.row.schedule.\(routine.jobID)")
                    if let preview = routine.promptPreview, !preview.isEmpty {
                        Text(preview)
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                    runStatusLine(routine)
                    if let failure = routine.failureDetail, !failure.isEmpty {
                        HStack(spacing: FleetTheme.spacingXs) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(FleetTheme.statusDestructive)
                                .accessibilityHidden(true)
                            Text(failure)
                                .font(FleetTheme.monoCaptionFont)
                                .foregroundStyle(FleetTheme.statusDestructive)
                                .lineLimit(2)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Failure: \(failure)")
                        .accessibilityIdentifier("routines.row.failure.\(routine.jobID)")
                    }
                }
                Spacer()
                Menu {
                    Button {
                        Task { await model.runNow(routine) }
                    } label: {
                        Label("Run Now", systemImage: "bolt.fill")
                    }
                    .accessibilityIdentifier("routines.row.runnow.\(routine.jobID)")
                    Button {
                        Task { await model.setRoutine(routine, enabled: !routine.isEnabled) }
                    } label: {
                        Label(routine.isEnabled ? "Pause" : "Resume",
                              systemImage: routine.isEnabled ? "pause.circle" : "arrow.up.circle")
                    }
                    .accessibilityIdentifier("routines.row.toggle.\(routine.jobID)")
                    Button(role: .destructive) {
                        model.requestRemoval(of: routine)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .accessibilityIdentifier("routines.row.remove.\(routine.jobID)")
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
                // FOS-6 tap-target: pad to the 44pt actionable bar (SPEC
                // §21 gate 15).
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .disabled(model.inFlight.contains(routine.jobID))
                .accessibilityLabel("Routine actions for \(routine.routineName)")
                .accessibilityIdentifier("routines.row.menu.\(routine.jobID)")
            }
        }
        // FOS-5: the trailing swipeActions were removed — embedded in Bot
        // Detail's segment the List no longer owns scrolling, so swipes
        // could not activate; the row menu carries the identical
        // Pause/Resume/Remove actions with the same identifiers.
    }

    @ViewBuilder
    private func runStatusLine(_ routine: BotRoutine) -> some View {
        HStack(spacing: FleetTheme.spacingSm) {
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(theme.textMuted)
                .accessibilityHidden(true)
            Text(routine.isEnabled ? (routine.nextRunAt ?? "no upcoming run") : "Paused")
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(routine.isEnabled ? theme.textSecondary : theme.textMuted)
            if let last = routine.lastRunAt {
                Text("· last \(last)")
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(theme.textMuted)
            }
            if let status = routine.lastStatus, !status.isEmpty {
                Text("· \(status)")
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(
                        ["failed", "error", "failure", "fire_failed"].contains(status.lowercased())
                            ? FleetTheme.statusDestructive : theme.textMuted)
            }
        }
        .accessibilityIdentifier("routines.row.status.\(routine.jobID)")
    }

    private var unsupportedRunCard: some View {
        // FOS-6: bounded notice (capability honesty stays).
        FleetNoticeBar(
            BotRoutinesViewModel.runNowUnsupportedCopy,
            systemImage: "clock.badge.exclamationmark",
            id: "routines.runnow.unsupported"
        )
    }

    private func noticeCard(_ text: String) -> some View {
        // FOS-6: bounded notice.
        FleetNoticeBar(text, systemImage: "info.circle", id: "routines.notice")
    }

    private func emptyCard(model: BotRoutinesViewModel) -> some View {
        // FOS-6: inline empty state.
        FleetNoticeBar(
            "No routines for this bot yet. Tap + to schedule one — it runs on the gateway, on the bot's own schedule.",
            systemImage: "calendar.badge.clock",
            id: "routines.empty"
        )
    }

    private func errorCard(_ error: String, model: BotRoutinesViewModel) -> some View {
        // FOS-6: contextual error notice with bounded Retry (SPEC §18).
        FleetNoticeBar(
            error,
            systemImage: "exclamationmark.triangle.fill",
            tone: .error,
            id: "routines.error",
            actionTitle: "Retry",
            actionID: "routines.retry",
            action: { Task { await model.refresh() } }
        )
    }

    private var loadingRow: some View {
        HStack {
            Spacer()
            ProgressView("Loading routines…")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("routines.loading")
    }

    private var unavailableContent: some View {
        ContentUnavailableView {
            Label("Routines Unavailable", systemImage: "calendar.badge.exclamationmark")
        } description: {
            Text("This gateway has no management session wired. Reconnect and try again.")
        }
        .accessibilityIdentifier("routines.unavailable")
    }
}

/// New-routine form: label + schedule + prompt. The `[bot:<slug>]`
/// namespace and the `bot-chat:<slug>` deliver target are applied by the
/// view model — the user only names the routine.
struct BotRoutineFormSheet: View {
    @Environment(\.fleetTheme) private var theme
    @Bindable var model: BotRoutinesViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var schedule = ""
    @State private var scheduleMode: BotRoutineSchedule.Mode = .daily
    @State private var scheduleDate = Date().addingTimeInterval(3600)
    @State private var weekday = 1
    @State private var intervalHours = 1
    @State private var advanced = false

    private var scheduleValue: String {
        BotRoutineSchedule.value(mode: scheduleMode, date: scheduleDate,
            hour: Calendar.current.component(.hour, from: scheduleDate),
            minute: Calendar.current.component(.minute, from: scheduleDate),
            weekday: weekday, intervalHours: intervalHours, raw: schedule) ?? ""
    }
    @State private var prompt = ""
    @State private var isSaving = false

    private var isValid: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !scheduleValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Routine Name", text: $label)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("routines.form.name")
                    Picker("Schedule", selection: $scheduleMode) {
                        ForEach(BotRoutineSchedule.Mode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }.accessibilityIdentifier("routines.form.mode")
                    if scheduleMode == .once {
                        DatePicker("Run once", selection: $scheduleDate, in: Date()...)
                            .accessibilityIdentifier("routines.form.date")
                    }
                    if scheduleMode == .hourly {
                        Stepper("Every \(intervalHours) hours", value: $intervalHours, in: 1...24)
                            .accessibilityIdentifier("routines.form.interval")
                    }
                    if scheduleMode == .daily || scheduleMode == .weekly {
                        DatePicker("Time on gateway", selection: $scheduleDate, displayedComponents: .hourAndMinute)
                            .accessibilityIdentifier("routines.form.time")
                        Text("Daily and weekly times use the gateway's configured timezone.").font(.caption)
                    }
                    if scheduleMode == .weekly {
                        Picker("Weekday", selection: $weekday) {
                            ForEach(0..<7, id: \.self) { day in
                                Text(Calendar.current.weekdaySymbols[day]).tag(day)
                            }
                        }.accessibilityIdentifier("routines.form.weekday")
                    }
                    DisclosureGroup("Advanced", isExpanded: $advanced) {
                        TextField("Raw schedule", text: $schedule)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("routines.form.schedule")
                            .onChange(of: schedule) { _, _ in scheduleMode = .custom }
                        Text("Editing this field selects Custom. The gateway validates the exact value.").font(.caption)
                    }
                    .onChange(of: scheduleMode) { _, mode in if mode == .custom { advanced = true } }

                } header: {
                    Text("Routine")
                        .foregroundStyle(theme.textSecondary)
                } footer: {
                    // The namespace the gateway will store — mono, machine data.
                    Text("Stored as \(BotRoutineNamespace.jobName(owner: model.profileSlug, routine: label.isEmpty ? "…" : label))")
                        .font(FleetTheme.monoCaptionFont)
                        .foregroundStyle(theme.textSecondary)
                }
                Section {
                    TextField("Prompt", text: $prompt, axis: .vertical)
                        .lineLimit(4...10)
                        .accessibilityIdentifier("routines.form.prompt")
                } header: {
                    Text("Prompt")
                        .foregroundStyle(theme.textSecondary)
                } footer: {
                    Text("Runs on the gateway's cron and delivers to this bot's Bot Chat. The gateway validates the schedule and scans the prompt before storing it.")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textSecondary)
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
                        .accessibilityIdentifier("routines.form.error")
                    } header: {
                        Text("Save Failed")
                            .foregroundStyle(FleetTheme.statusDestructive)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("New Routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("routines.form.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard isValid, !isSaving else { return }
                        isSaving = true
                        Task {
                            let ok = await model.createRoutine(label: label, schedule: scheduleValue, prompt: prompt)
                            isSaving = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(!isValid || isSaving)
                    .foregroundStyle(theme.highlight)
                    .accessibilityIdentifier("routines.form.save")
                }
            }
        }
        .tint(theme.highlight)
        .presentationDetents([.large])
        .accessibilityIdentifier("routines.form.sheet")
    }
}
