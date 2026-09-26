import SwiftUI
import FleetCore

/// The Cron tab root: every machine's cron jobs on one screen.
///
/// Reuses the card-B engine unchanged (CronDashboardModel over the dashboard
/// REST seam). Jobs are grouped by gateway ("machine") sections; each section
/// supports add / edit / delete / run-now / pause+resume inline, and pushes
/// the shared CronJobDetailView for ledger + run history. Profile scope per
/// gateway resolves through GatewayProfileSelectionPolicy (stored explicit
/// choice → single candidate → explicit chooser — never a silent default).
public struct CronHomeView: View {
    @Environment(\.fleetTheme) private var theme
    private let environment: AppEnvironment

    /// Create-form target: nil closes the sheet. The form is gateway + profile
    /// scoped, so the + resolves BOTH on demand (single gateway opens directly;
    /// a fleet gets an explicit per-gateway menu) — never a silent `default`,
    /// and never an empty sheet: the sheet itself resolves the scope and names
    /// anything that blocks it.
    @State private var createTarget: CronCreateRequest?

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        Group {
            if environment.gateways.isEmpty {
                ContentUnavailableView {
                    Label("No gateways", systemImage: "server.rack")
                } description: {
                    Text("Register a Hermes gateway to manage its cron jobs.")
                }
                .accessibilityIdentifier("cron.home.empty")
            } else {
                machineSections
            }
        }
        .navigationTitle("Scheduled")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                addControl
            }
        }
        .sheet(item: $createTarget) { request in
            CronCreateFormHost(
                environment: environment,
                gatewayID: request.gatewayID,
                displayName: request.displayName)
        }
    }

    /// The + opens the create form for a machine; the sheet resolves that
    /// machine's scope from its OWN bound section (else the same §8 policy the
    /// section uses) and NAMES whatever blocks it, so a create can only ever
    /// land under the profile the operator is looking at and can never render
    /// an empty form.
    ///
    /// Nothing in this body probes the environment: a menu's content is built
    /// as part of the view update, and `makeCronDashboard` MUTATES the
    /// environment (it caches the seam) — evaluating it while the menu builds
    /// tears the popover down before it can render its items.
    @ViewBuilder
    private var addControl: some View {
        if environment.gateways.count == 1, let only = environment.gateways.first {
            Button {
                openCreateForm(for: only)
            } label: {
                Image(systemName: "plus")
            }
            .foregroundStyle(Color.primary)
            .accessibilityLabel("New cron job")
            .accessibilityIdentifier("cron.new")
        } else {
            Menu {
                ForEach(environment.gateways) { gateway in
                    Button("\(gateway.displayName)") {
                        openCreateForm(for: gateway)
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .foregroundStyle(Color.primary)
            .accessibilityLabel("New cron job")
            .accessibilityIdentifier("cron.new")
        }
    }

    private func openCreateForm(for gateway: FleetGateway) {
        createTarget = CronCreateRequest(gatewayID: gateway.id, displayName: gateway.displayName)
    }

    private var machineSections: some View {
        List {
            ForEach(environment.gateways) { gateway in
                CronMachineSection(environment: environment, gateway: gateway)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await CronSectionCache.shared.refreshAll()
        }
    }
}

/// A complete create-form scope: the model of the machine's bound section plus
/// the profile that section is scoped to. Both are resolved at TAP time, so the
/// form can only create under the profile the operator is actually looking at
/// (the section's list is the same model, so the created row lands on screen)
/// and can never render empty for want of a scope.
struct CronCreateScope {
    let model: CronDashboardModel
    let profile: ProfileSlug
}

/// A tapped create: which machine the + was used for. Presented immediately —
/// the scope resolves inside the sheet (CronCreateFormHost).
struct CronCreateRequest: Identifiable, Equatable {
    let gatewayID: GatewayID
    let displayName: String
    var id: String { gatewayID.rawValue }
}

/// Why a create could not be scoped to a machine — the sheet renders the reason
/// (and what unblocks it) instead of an empty form.
enum CronCreateBlock: Equatable {
    /// No dashboard cron seam is wired for this machine (fail closed).
    case noSurface
    /// Several routable profiles and no explicit choice yet: the §8 chooser on
    /// the machine's section owns that decision.
    case needsProfile
    /// The roster never resolved inside the sheet's bounded wait.
    case rosterNotLoaded

    var systemImage: String {
        switch self {
        case .noSurface: return "clock.badge.exclamationmark"
        case .needsProfile: return "person.crop.circle.badge.questionmark"
        case .rosterNotLoaded: return "wifi.exclamationmark"
        }
    }

    var accessibilityID: String {
        switch self {
        case .noSurface: return "cron.form.unavailable"
        case .needsProfile: return "cron.form.unresolved"
        case .rosterNotLoaded: return "cron.form.unresolved"
        }
    }

    func message(displayName: String) -> String {
        switch self {
        case .noSurface:
            return "This gateway has no dashboard cron surface wired. Reconnect and try again."
        case .needsProfile:
            return "Pick a profile for \(displayName) on the Scheduled tab first: the create form files the job under the profile that machine's section is showing."
        case .rosterNotLoaded:
            return "Could not resolve a profile for \(displayName) yet — its roster has not loaded. Check the gateway connection and try again."
        }
    }
}

/// The profile a machine's cron surface resolves to, computed from the roster
/// exactly the way the section (and the gateway resource view) does. Shared so
/// the create flow can resolve on demand — before the section has bound —
/// without a second policy and without falling back to a hardcoded profile.
@MainActor
enum CronProfileResolution {
    static func storageKey(for gatewayID: GatewayID) -> String {
        "fleet.explicit-profile.v1.\(gatewayID.rawValue).cron"
    }

    static func candidates(
        for gatewayID: GatewayID,
        environment: AppEnvironment
    ) -> [GatewayProfileSelectionPolicy.Candidate] {
        let bots: [FleetBot]
        if case .loaded = environment.rosterSnapshot?.outcome(for: gatewayID) {
            bots = environment.bots(on: gatewayID)
        } else {
            bots = environment.cachedBotsByGateway[gatewayID] ?? []
        }
        return bots
            .filter { $0.route.isRoutingSafe }
            .map { GatewayProfileSelectionPolicy.Candidate(profileSlug: $0.route.profileSlug, botName: $0.displayName) }
    }

    static func resolve(
        for gatewayID: GatewayID,
        environment: AppEnvironment
    ) -> GatewayProfileSelectionPolicy.Resolution {
        GatewayProfileSelectionPolicy().resolve(
            candidates: candidates(for: gatewayID, environment: environment),
            storedSelection: UserDefaults.standard.string(forKey: storageKey(for: gatewayID))
                .map(ProfileSlug.init(rawValue:)))
    }
}

/// Hosts the create form for a machine, resolving its scope on demand: the
/// section's scope once it has bound, else the same policy resolution bound to
/// the shared model here (the section adopts that instance when its own loop
/// resolves, so both surfaces stay on one list). Says what it is waiting for
/// rather than rendering an empty form.
struct CronCreateFormHost: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fleetTheme) private var theme
    let environment: AppEnvironment
    let gatewayID: GatewayID
    let displayName: String

    @State private var scope: CronCreateScope?
    /// Set when no scope can be produced: the sheet names the reason (never an
    /// empty form).
    @State private var blocked: CronCreateBlock?
    /// True while this host holds a retain on the shared model (paired on
    /// disappear: a model bound here must not be stranded in the cache).
    @State private var holdsRetain = false

    var body: some View {
        Group {
            if let scope {
                CronJobFormSheet(model: scope.model, profile: scope.profile.rawValue, mode: .create)
            } else if let blocked {
                VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                    Label(displayName, systemImage: blocked.systemImage)
                        .font(FleetTheme.sectionHeaderFont)
                        .foregroundStyle(theme.textSecondary)
                    Text(blocked.message(displayName: displayName))
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(FleetTheme.spacingLg)
                .accessibilityIdentifier(blocked.accessibilityID)
                .toolbar { cancelToolbar }
            } else {
                VStack(spacing: FleetTheme.spacingSm) {
                    ProgressView()
                    Text("Resolving \(displayName)'s profile…")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(theme.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("cron.form.resolving")
                .toolbar { cancelToolbar }
            }
        }
        .task { await resolveScope() }
        .onDisappear {
            if holdsRetain {
                holdsRetain = false
                CronSectionCache.shared.release(gatewayID)
            }
        }
    }

    private var cancelToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
    }

    /// Resolve the create scope, or say why there is none.
    ///
    /// Precedence is the point: a machine whose section has bound has ALREADY
    /// decided its profile, so its model is the authority (the created row must
    /// land in the list the operator is looking at). Otherwise the same §8
    /// policy that section uses resolves the profile — a stored (or sole)
    /// choice binds here, and the section adopts this very instance when its
    /// own loop lands. Never a hardcoded `default`.
    private func resolveScope() async {
        if let ready = CronSectionCache.shared.createScope(for: gatewayID) {
            scope = ready
            return
        }
        // No seam = no cron surface at all: say so now, never wait for one.
        guard let seam = environment.makeCronDashboard(for: gatewayID) else {
            blocked = .noSurface
            return
        }
        // Bounded like the section's own loop: the roster's first load is the
        // real wait (an unloaded roster resolves `.unavailable`), and giving up
        // leaves an honest message rather than a blank form.
        for _ in 0..<48 {
            if let ready = CronSectionCache.shared.createScope(for: gatewayID) {
                scope = ready
                return
            }
            switch CronProfileResolution.resolve(for: gatewayID, environment: environment) {
            case .reuseStored(let profile), .singleCandidate(let profile):
                scope = await bindScope(seam: seam, profile: profile)
                return
            case .selectionRequired:
                // Several routable profiles and no explicit choice: the §8
                // chooser on the machine's section owns that decision, and the
                // operator cannot reach it from under this sheet — waiting
                // would only spin.
                blocked = .needsProfile
                return
            case .unavailable:
                break  // roster still loading — wait for it
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        blocked = .rosterNotLoaded
    }

    private func bindScope(seam: any CronDashboardProviding, profile: ProfileSlug) async -> CronCreateScope {
        let model = CronSectionCache.shared.model(for: gatewayID, seam: seam)
        if !holdsRetain {
            holdsRetain = true
            CronSectionCache.shared.retain(gatewayID)
        }
        if model.lastProfile != profile.rawValue {
            await model.start(profile: profile.rawValue)
        }
        return CronCreateScope(model: model, profile: profile)
    }
}

/// One machine's section: header + jobs (or per-gateway states).
struct CronMachineSection: View {
    @Environment(\.fleetTheme) private var theme
    let environment: AppEnvironment
    let gateway: FleetGateway

    var body: some View {
        Group {
            let seam = environment.makeCronDashboard(for: gateway.id)
            if seam == nil {
                unsupported
            } else {
                CronGatewayJobs(
                    environment: environment,
                    gatewayID: gateway.id,
                    gatewayName: gateway.displayName)
            }
        }
    }

    @ViewBuilder
    private var unsupported: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
            Label(gateway.displayName, systemImage: "server.rack")
                .font(FleetTheme.sectionHeaderFont)
                .foregroundStyle(theme.textSecondary)
            Text("This gateway has no dashboard cron surface wired. Reconnect and try again.")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, FleetTheme.spacingSm)
        .accessibilityIdentifier("cron.section.unsupported.\(gateway.id.rawValue)")
    }
}

/// The jobs list for one gateway, resolving its profile scope honestly.
struct CronGatewayJobs: View {
    @Environment(\.fleetTheme) private var theme
    let environment: AppEnvironment
    let gatewayID: GatewayID
    let gatewayName: String

    @State private var model: CronDashboardModel?
    @State private var resolvedProfile: ProfileSlug?
    @State private var candidates: [GatewayProfileSelectionPolicy.Candidate] = []
    @State private var pendingDelete: (job: CronJobRecord, profile: ProfileSlug)?
    /// True while THIS section holds a retain on the shared model. Retain and
    /// release are paired through the flag (and gated on liveness below): a
    /// bind that lands after `.onDisappear` already released must not retain,
    /// because that pair never balances and strands the model in the shared
    /// cache for the life of the process.
    @State private var hasRetainedModel = false
    /// False once the section has disappeared; a fresh section starts live.
    @State private var isSectionLive = true

    /// SAME key the scoped Schedules pane uses (paneKey(.cron) == "cron"):
    /// one remembered choice per machine across both surfaces, and
    /// NAV_RESET's stored-selection sweep covers the tab too.
    private var storageKey: String {
        CronProfileResolution.storageKey(for: gatewayID)
    }

    var body: some View {
        Group {
            if let model, let profile = resolvedProfile {
                jobsList(model: model, profile: profile)
            } else if requiresSelection {
                profileChooser
            } else {
                loading
            }
        }
        .alert(
            "Delete \"\(pendingDelete?.job.name ?? "job")\"?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { _ in }
            ),
            presenting: pendingDelete
        ) { entry in
            Button("Delete", role: .destructive) {
                let id = entry.job.id
                let scope = entry.profile
                pendingDelete = nil
                Task { await model?.deleteJob(id, profile: scope.rawValue) }
            }
            .accessibilityIdentifier("cron.delete.confirm")
            Button("Cancel", role: .cancel) { pendingDelete = nil }
                .accessibilityIdentifier("cron.delete.cancel")
        } message: { entry in
            Text("\(entry.job.name) will be removed from this gateway. Its run history stays in the gateway's records.")
        }
        .task(id: gatewayID) {
            await resolveLoop()
        }
        .onAppear {
            isSectionLive = true
        }
        .onDisappear {
            isSectionLive = false
            guard hasRetainedModel else { return }
            hasRetainedModel = false
            CronSectionCache.shared.release(gatewayID)
        }
    }

    private var requiresSelection: Bool {
        candidates.count > 1 && resolvedProfile == nil
    }

    private var loading: some View {
        HStack(spacing: FleetTheme.spacingSm) {
            ProgressView()
            Text("Loading \"\(gatewayName)\" jobs…")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, FleetTheme.spacingSm)
        .accessibilityIdentifier("cron.section.loading.\(gatewayID.rawValue)")
    }

    /// SPEC §8 honest chooser: several profiles, no valid stored choice.
    private var profileChooser: some View {
        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
            Label(gatewayName, systemImage: "server.rack")
                .font(FleetTheme.sectionHeaderFont)
                .foregroundStyle(theme.textSecondary)
            Text("Choose a profile to view its cron jobs.")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textMuted)
                .accessibilityIdentifier("cron.section.chooser.hint.\(gatewayID.rawValue)")
            ForEach(candidates) { candidate in
                Button {
                    UserDefaults.standard.set(candidate.profileSlug.rawValue, forKey: storageKey)
                    // Bind SYNCHRONOUSLY to the picked profile — the async
                    // re-resolve can strand under host load (the roster read
                    // is not needed: we already hold valid candidates).
                    resolvedProfile = candidate.profileSlug
                    let picked = candidate.profileSlug
                    Task { await bindModel(profile: picked, forceReload: true) }
                } label: {
                    Label("\(candidate.profileSlug.rawValue) · \(candidate.botName)",
                          systemImage: "person.crop.circle")
                        .font(.body)
                        .foregroundStyle(theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("cron.home.profile.\(gatewayID.rawValue)#\(candidate.profileSlug.rawValue)")
            }
        }
        .padding(.vertical, FleetTheme.spacingSm)
        // NO container identifier: a container id propagates to every
        // descendant and REPLACES the per-button profile ids above.
    }

    private func jobsList(model: CronDashboardModel, profile: ProfileSlug) -> some View {
        Group {
            // Notice/error live IN the model-owning view (the legacy pane's
            // contract); rendering them from a parent's List-section closure
            // escapes observation tracking and never updates.
            if let notice = model.notice {
                FleetNoticeBar(notice, systemImage: "info.circle", id: "cron.notice")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            // The bar carries the message for a populated list; the branches
            // below render it as the section's own state (never both).
            if let error = model.errorMessage, !model.jobs.isEmpty {
                FleetNoticeBar(
                    error,
                    systemImage: "exclamationmark.triangle.fill",
                    tone: .error,
                    id: "cron.error",
                    actionTitle: "Retry",
                    actionID: "cron.retry",
                    action: { Task { await model.refresh(profile: profile.rawValue) } })
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if model.isLoading && model.jobs.isEmpty {
                loading
            } else if let error = model.errorMessage, model.jobs.isEmpty {
                Text(error)
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.statusDestructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, FleetTheme.spacingSm)
                    .accessibilityIdentifier("cron.section.error.\(gatewayID.rawValue)")
            } else if model.jobs.isEmpty {
                emptyJobs
            } else {
                ForEach(model.jobs) { job in
                    CronJobRow(
                        job: job,
                        model: model,
                        profile: profile,
                        gatewayID: gatewayID,
                        environment: environment,
                        onDelete: { record in
                            pendingDelete = (record, profile)
                        })
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
    }

    private var emptyJobs: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(gatewayName, systemImage: "server.rack")
                .font(FleetTheme.sectionHeaderFont)
                .foregroundStyle(theme.textSecondary)
            Text("No cron jobs on this profile yet.")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, FleetTheme.spacingSm)
        .accessibilityIdentifier("cron.section.empty.\(gatewayID.rawValue)")
    }

    /// The tab can open before the roster's first load settles; poll
    /// (bounded) until candidates exist, then bind once. SelectionRequired
    /// stops the loop — it needs a user choice, not more waiting.
    private func resolveLoop() async {
        for _ in 0..<40 {
            // SwiftUI cancels this task when the section disappears; without
            // this guard the loop would keep polling (the swallowed
            // CancellationError from the sleep) and could bind a model after
            // the section's release.
            if Task.isCancelled { return }
            await resolveAndBind()
            if resolvedProfile != nil || !candidates.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    private func resolveAndBind(forceReload: Bool = false) async {
        let cands = CronProfileResolution.candidates(for: gatewayID, environment: environment)
        candidates = cands

        switch CronProfileResolution.resolve(for: gatewayID, environment: environment) {
        case .reuseStored(let p), .singleCandidate(let p):
            resolvedProfile = p
            await bindModel(profile: p, forceReload: forceReload)
        case .selectionRequired:
            resolvedProfile = nil
            model = nil
        case .unavailable:
            // Roster not loaded for this gateway yet — retry is honest.
            resolvedProfile = nil
            model = nil
        }
    }

    private func bindModel(profile: ProfileSlug, forceReload: Bool) async {
        guard let seam = environment.makeCronDashboard(for: gatewayID) else { return }
        // The section is gone (or its task was cancelled): binding now would
        // retain a model whose release already ran — an unmatched pair that
        // strands the model in the shared cache and keeps mutating state for a
        // view that no longer exists.
        guard isSectionLive, !Task.isCancelled else { return }
        let next = CronSectionCache.shared.model(for: gatewayID, seam: seam)
        model = next
        if !hasRetainedModel {
            hasRetainedModel = true
            CronSectionCache.shared.retain(gatewayID)
        }
        if forceReload || next.jobs.isEmpty {
            await next.start(profile: profile.rawValue)
        }
    }
}

/// Shares one CronDashboardModel per gateway across the home screen's
/// section lifecycle (retain/release) and the pull-to-refresh.
@MainActor
final class CronSectionCache {
    static let shared = CronSectionCache()
    private var models: [GatewayID: CronDashboardModel] = [:]
    private var retainCounts: [GatewayID: Int] = [:]

    func model(for gatewayID: GatewayID, seam: any CronDashboardProviding) -> CronDashboardModel {
        if let existing = models[gatewayID] { return existing }
        let m = CronDashboardModel(gatewayID: gatewayID, dashboard: seam)
        models[gatewayID] = m
        return m
    }

    func retain(_ gatewayID: GatewayID) {
        retainCounts[gatewayID, default: 0] += 1
    }

    func release(_ gatewayID: GatewayID) {
        guard let n = retainCounts[gatewayID] else { return }
        if n <= 1 {
            retainCounts[gatewayID] = nil
            models[gatewayID] = nil
        } else {
            retainCounts[gatewayID] = n - 1
        }
    }

    /// Peek at a retained model without creating one (create-form target).
    func modelIfRetained(_ gatewayID: GatewayID) -> CronDashboardModel? {
        guard retainCounts[gatewayID] != nil else { return nil }
        return models[gatewayID]
    }

    /// The create-form scope for a machine, or nil when its section has no
    /// bound model / resolved profile yet. NEVER a hardcoded `default`: the
    /// section can be scoped to any profile the operator chose (and a §8
    /// chooser may still be waiting), so a default-scoped create would file the
    /// job under a profile the machine's section is not showing.
    func createScope(for gatewayID: GatewayID) -> CronCreateScope? {
        guard let model = modelIfRetained(gatewayID),
              let raw = model.lastProfile, !raw.isEmpty else { return nil }
        return CronCreateScope(model: model, profile: ProfileSlug(rawValue: raw))
    }

    func refreshAll() async {
        // Refresh every retained section with its bound profile (the model
        // remembers the scope it last loaded).
        for (_, m) in models {
            await m.refresh(profile: m.lastProfile)
        }
    }
}
