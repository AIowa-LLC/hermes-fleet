import Foundation
import Observation
import FleetCore

/// Card B — observable state for the Cron destination (dashboard REST
/// surface: list/detail/create/edit/pause/resume/trigger/delete + runs +
/// delivery targets).
///
/// - The LIST is the server's array; every mutation replaces the affected row
///   with the row the SERVER returned (never a client-side fabrication).
/// - `trigger` losing its atomic claim (409) is NOT an error: it surfaces as
///   a notice ("already running"), matching the server's own semantics.
/// - Run history is agent run sessions; `no_agent` script jobs produce none
///   BY DESIGN — the honest empty state says so instead of inventing rows.
@MainActor
@Observable
public final class CronDashboardModel {
    // MARK: Observable state

    /// Jobs for the scoped profile (paused included).
    public private(set) var jobs: [CronJobRecord] = []
    /// True while the list load is in flight.
    public private(set) var isLoading = false
    /// Pane-level error (list load / mutations that have no row to blame).
    public private(set) var errorMessage: String?
    /// Honest informational notice (run requested, already running, …).
    public private(set) var notice: String?
    /// Job ids with a mutation in flight (row buttons disable).
    public private(set) var inFlightJobs: Set<String> = []
    /// Delivery dropdown options (loaded once per pane bind).
    public private(set) var deliveryTargets: [CronDeliveryTarget] = []
    /// Form-sheet error (create/edit failure).
    public private(set) var formError: String?

    /// The job the detail screen is showing (server truth, refreshed after
    /// every mutation).
    public private(set) var detail: CronJobRecord?
    public private(set) var isLoadingDetail = false
    public private(set) var detailError: String?
    /// Agent run sessions for the detail job (newest first).
    public private(set) var detailRuns: [CronRunSession] = []
    public private(set) var isLoadingRuns = false
    public private(set) var runsError: String?

    // MARK: Dependencies

    public let gatewayID: GatewayID
    private let dashboard: any CronDashboardProviding

    public init(gatewayID: GatewayID, dashboard: any CronDashboardProviding) {
        self.gatewayID = gatewayID
        self.dashboard = dashboard
    }

    // MARK: Lifecycle

    /// Load the list + delivery targets for the scoped profile.
    /// The profile scope the model last loaded (used by the Cron tab's
    /// shared-section refresh).
    public private(set) var lastProfile: String?

    public func start(profile: String?) async {
        lastProfile = profile
        isLoading = true
        defer { isLoading = false }
        await reload(profile: profile)
        if deliveryTargets.isEmpty {
            deliveryTargets = (try? await dashboard.deliveryTargets()) ?? []
        }
    }

    public func refresh(profile: String?) async {
        lastProfile = profile
        await reload(profile: profile)
    }

    private func reload(profile: String?) async {
        do {
            jobs = try await dashboard.listJobs(profile: profile)
            errorMessage = nil
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// Delivery target display: the server's name for a known id, else the raw
    /// target string (an operator-set value must never be hidden).
    public func deliveryLabel(for target: String) -> String {
        deliveryTargets.first { $0.id == target }?.name ?? target
    }

    // MARK: Detail

    public func loadDetail(id: String, profile: String?) async {
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            detail = try await dashboard.job(id: id, profile: profile)
            detailError = nil
        } catch {
            detailError = Self.describe(error)
        }
    }

    public func loadRuns(id: String, profile: String?) async {
        isLoadingRuns = true
        defer { isLoadingRuns = false }
        do {
            detailRuns = try await dashboard.runSessions(jobID: id, profile: profile, limit: 20)
            runsError = nil
        } catch {
            runsError = Self.describe(error)
        }
    }

    /// Detail-screen refresh: the list snapshot (which carries the execution
    /// ledger), the job record, and its run history.
    public func refreshDetail(id: String, profile: String?) async {
        await reload(profile: profile)
        await loadDetail(id: id, profile: profile)
        await loadRuns(id: id, profile: profile)
    }

    /// The execution ledger for a job. The REST DETAIL endpoint does not
    /// attach `latest_execution` (only list rows carry it —
    /// `cron/jobs.py:list_jobs`), so the pane composes it from its list
    /// snapshot; a ledger that already rode the detail record wins.
    public func ledger(for id: String) -> CronExecution? {
        if let ledger = detail?.latestExecution, detail?.id == id { return ledger }
        return jobs.first { $0.id == id }?.latestExecution
    }

    // MARK: Mutations

    /// Create (POST). Returns true on success; failure lands in `formError`.
    @discardableResult
    public func createJob(_ request: CronJobCreateRequest, profile: String?) async -> Bool {
        do {
            let created = try await dashboard.createJob(request, profile: profile)
            applyRow(created)
            formError = nil
            notice = "Job created."
            return true
        } catch {
            formError = Self.describe(error)
            return false
        }
    }

    /// Edit in place (PUT — identity preserved). Returns true on success.
    @discardableResult
    public func updateJob(id: String, patch: CronJobPatch, profile: String?) async -> Bool {
        guard !inFlightJobs.contains(id) else { return false }
        inFlightJobs.insert(id)
        defer { inFlightJobs.remove(id) }
        do {
            let updated = try await dashboard.updateJob(id: id, patch: patch, profile: profile)
            applyRow(updated)
            if detail?.id == updated.id { detail = updated }
            formError = nil
            notice = "Job updated."
            return true
        } catch {
            formError = Self.describe(error)
            return false
        }
    }

    /// Pause/resume. Returns true when the server confirmed the new state.
    @discardableResult
    public func setJob(_ id: String, enabled: Bool, profile: String?) async -> Bool {
        guard !inFlightJobs.contains(id) else { return false }
        inFlightJobs.insert(id)
        defer { inFlightJobs.remove(id) }
        do {
            let updated = enabled
                ? try await dashboard.resumeJob(id: id, profile: profile)
                : try await dashboard.pauseJob(id: id, profile: profile)
            applyRow(updated)
            if detail?.id == updated.id { detail = updated }
            return true
        } catch {
            errorMessage = Self.describe(error)
            return false
        }
    }

    /// Run now (POST trigger). A lost claim (409) is an honest notice.
    public func triggerJob(_ id: String, profile: String?) async {
        guard !inFlightJobs.contains(id) else { return }
        inFlightJobs.insert(id)
        defer { inFlightJobs.remove(id) }
        do {
            let updated = try await dashboard.triggerJob(id: id, profile: profile)
            applyRow(updated)
            if detail?.id == updated.id { detail = updated }
            notice = "Run requested — the job is firing now."
            // last_run_at / the execution ledger refresh on the next read.
            await reload(profile: profile)
            if detail?.id == id {
                await loadRuns(id: id, profile: profile)
                await loadDetail(id: id, profile: profile)
            }
        } catch let error as CronDashboardError where error.isAlreadyRunning {
            notice = error.errorDescription
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// Delete (DELETE). Returns true when the row is gone server-side.
    @discardableResult
    public func deleteJob(_ id: String, profile: String?) async -> Bool {
        guard !inFlightJobs.contains(id) else { return false }
        inFlightJobs.insert(id)
        defer { inFlightJobs.remove(id) }
        do {
            try await dashboard.deleteJob(id: id, profile: profile)
            jobs.removeAll { $0.id == id }
            if detail?.id == id { detail = nil }
            notice = "Job deleted."
            return true
        } catch {
            errorMessage = Self.describe(error)
            return false
        }
    }

    /// Apply a server record onto the list. Mutation responses (pause /
    /// resume / PUT / trigger) carry NO `latest_execution` — the wire attaches
    /// the ledger to LIST rows only — so the row being replaced is the pane's
    /// only holder of a ledger the operator can already see (Last run /
    /// Last status on the same screen). Losing it here made the detail screen
    /// fabricate "this job has not fired" for a job that demonstrably has
    /// (review round 1); an omitted ledger keeps the last known one instead.
    private func applyRow(_ updated: CronJobRecord) {
        let merged = preservingKnownLedger(updated)
        guard let index = jobs.firstIndex(where: { $0.id == merged.id }) else {
            jobs.append(merged)
            return
        }
        jobs[index] = merged
    }

    /// A response that omits the ledger keeps the last one known for this job:
    /// the list row first (the snapshot the wire attaches ledgers to), then
    /// the detail record (which may carry one it was given). A job that never
    /// fired has none anywhere — that stays the honest empty state.
    private func preservingKnownLedger(_ incoming: CronJobRecord) -> CronJobRecord {
        guard incoming.latestExecution == nil else { return incoming }
        let known = jobs.first { $0.id == incoming.id }?.latestExecution
            ?? (detail?.id == incoming.id ? detail?.latestExecution : nil)
        guard let known else { return incoming }
        return incoming.withLatestExecution(known)
    }

    /// Clear a stale form error when a form sheet opens.
    public func clearFormError() {
        formError = nil
    }

    /// Non-secret error description for display.
    static func describe(_ error: any Error) -> String {
        Redaction.safeErrorDescription(error)
    }
}