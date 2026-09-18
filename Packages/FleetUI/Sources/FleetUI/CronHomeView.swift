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

    /// Create-form target: nil closes the sheet. The form is gateway+profile
    /// scoped, so the + control first picks the machine (single gateway opens
    /// directly; a fleet gets an explicit per-gateway menu — never a silent
    /// default).
    @State private var createTarget: (gateway: FleetGateway, profile: ProfileSlug)?

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
        .sheet(isPresented: Binding(
            get: { createTarget != nil },
            set: { if !$0 { createTarget = nil } }
        )) {
            if let target = createTarget,
               let model = CronSectionCache.shared.modelIfRetained(target.gateway.id) {
                CronJobFormSheet(model: model, profile: target.profile.rawValue, mode: .create)
            }
        }
    }

    @ViewBuilder
    private var addControl: some View {
        if environment.gateways.count == 1, let only = environment.gateways.first {
            Button {
                createTarget = (only, ProfileSlug(rawValue: "default"))
            } label: {
                Image(systemName: "plus")
            }
            .foregroundStyle(theme.highlight)
            .accessibilityLabel("New cron job")
            .accessibilityIdentifier("cron.new")
        } else {
            Menu {
                ForEach(environment.gateways) { gateway in
                    Button("\(gateway.displayName)") {
                        createTarget = (gateway, ProfileSlug(rawValue: "default"))
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .foregroundStyle(theme.highlight)
            .accessibilityLabel("New cron job")
            .accessibilityIdentifier("cron.new")
        }
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
    @State private var isShowingForm = false
    @State private var pendingDelete: (job: CronJobRecord, profile: ProfileSlug)?

    /// SAME key the scoped Schedules pane uses (paneKey(.cron) == "cron"):
    /// one remembered choice per machine across both surfaces, and
    /// NAV_RESET's stored-selection sweep covers the tab too.
    private var storageKey: String {
        "fleet.explicit-profile.v1.\(gatewayID.rawValue).cron"
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
        .sheet(isPresented: $isShowingForm) {
            if let model, let profile = resolvedProfile {
                CronJobFormSheet(model: model, profile: profile.rawValue, mode: .create)
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
        .onDisappear {
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
            if let error = model.errorMessage {
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
            await resolveAndBind()
            if resolvedProfile != nil || !candidates.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    private func resolveAndBind(forceReload: Bool = false) async {
        let bots: [FleetBot]
        if case .loaded = environment.rosterSnapshot?.outcome(for: gatewayID) {
            bots = environment.bots(on: gatewayID)
        } else {
            bots = environment.cachedBotsByGateway[gatewayID] ?? []
        }
        let cands = bots
            .filter { $0.route.isRoutingSafe }
            .map { GatewayProfileSelectionPolicy.Candidate(profileSlug: $0.route.profileSlug, botName: $0.displayName) }
        candidates = cands

        let stored = UserDefaults.standard.string(forKey: storageKey).map(ProfileSlug.init(rawValue:))
        switch GatewayProfileSelectionPolicy().resolve(candidates: cands, storedSelection: stored) {
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
        let next = CronSectionCache.shared.model(for: gatewayID, seam: seam)
        model = next
        CronSectionCache.shared.retain(gatewayID)
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

    func refreshAll() async {
        // Refresh every retained section with its bound profile (the model
        // remembers the scope it last loaded).
        for (_, m) in models {
            await m.refresh(profile: m.lastProfile)
        }
    }
}
