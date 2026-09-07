import Foundation
import Observation
import FleetCore

/// R9-T5/T6 — observable state for the per-gateway management panes
/// (Cron + Skills). One view model serves both: both panes are scoped to
/// the same `(gateway, profile)` and share the error/notice surfaces.
///
/// - `start(profile:)` loads the cron list AND the skills catalog for the
///   profile; a pane that is not showing skills simply ignores those rows.
/// - Mutations are applied through the seam and REFRESH the list from the
///   server's returned row (never a client-side fabrication of state).
/// - Fire-now honesty: `GatewayManagementError.unsupportedAction` surfaces
///   as a `notice` (the 0.21.0 gateway does not forward cron `run` over
///   WS — methods_tools.py:1826), NOT as a pane error; everything else
///   that throws surfaces as `errorMessage`.
@MainActor
@Observable
public final class ManagementPanesViewModel {
    // MARK: Observable state

    /// Cron jobs for the scoped profile (paused included).
    public private(set) var cronJobs: [CronJob] = []
    /// Skills rows (catalog joined with profile enablement), category order.
    public private(set) var skillsRows: [ProfileSkill] = []
    /// Category grouping for the Skills pane (category → rows, catalog order).
    public private(set) var categoryGroups: [(category: String, rows: [ProfileSkill])] = []
    /// True while the initial load is in flight.
    public private(set) var isLoading = false
    /// Skills toggles that are pending on the wire (lowercased names).
    public private(set) var pendingSkills: Set<String> = []
    /// Cron actions in flight (job ids).
    public private(set) var inFlightJobs: Set<String> = []
    /// Last pane-level error (non-secret).
    public private(set) var errorMessage: String?
    /// Honest informational notice (e.g. fire-now unsupported on gateway).
    public private(set) var notice: String?
    /// Form-sheet error (create job failure).
    public private(set) var formError: String?
    /// Count of successful toggles (row feedback / test observability).
    public private(set) var jobsToggled = 0

    // MARK: Dependencies

    public let gatewayID: GatewayID
    private let management: any GatewayManagementProviding

    public init(gatewayID: GatewayID, management: any GatewayManagementProviding) {
        self.gatewayID = gatewayID
        self.management = management
    }

    // MARK: Lifecycle

    /// Load the cron list + skills catalog for the profile.
    public func start(profile: String?) async {
        isLoading = true
        defer { isLoading = false }
        await reloadCron(profile: profile)
        if let profile {
            await reloadSkills(profile: profile)
        }
    }

    public func refresh(profile: String?) async {
        await reloadCron(profile: profile)
        if let profile {
            await reloadSkills(profile: profile)
        }
    }

    // MARK: Cron

    private func reloadCron(profile: String?) async {
        do {
            cronJobs = try await management.listCronJobs(profile: profile)
            errorMessage = nil
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// Toggle enable/disable (`pause`/`resume` on the wire).
    public func setCronJob(_ jobID: String, enabled: Bool, profile: String?) async {
        guard !inFlightJobs.contains(jobID) else { return }
        inFlightJobs.insert(jobID)
        defer { inFlightJobs.remove(jobID) }
        do {
            let updated = try await management.setCronJob(jobID, enabled: enabled, profile: profile)
            applyCronRow(updated)
            jobsToggled += 1
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// Fire now — an `unsupportedAction` error surfaces as a notice.
    public func fireCronJob(_ jobID: String, profile: String?) async {
        guard !inFlightJobs.contains(jobID) else { return }
        inFlightJobs.insert(jobID)
        defer { inFlightJobs.remove(jobID) }
        do {
            try await management.fireCronJob(jobID, profile: profile)
            notice = "Run requested — the job is firing now."
            // next_run_at / last_run refresh on the next list read.
            await reloadCron(profile: profile)
        } catch let error as GatewayManagementError {
            if case .unsupportedAction = error {
                notice = error.errorDescription
            } else {
                errorMessage = error.errorDescription
            }
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    public func deleteCronJob(_ jobID: String, profile: String?) async {
        guard !inFlightJobs.contains(jobID) else { return }
        inFlightJobs.insert(jobID)
        defer { inFlightJobs.remove(jobID) }
        do {
            try await management.deleteCronJob(jobID, profile: profile)
            cronJobs.removeAll { $0.jobID == jobID }
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    @discardableResult
    public func createCronJob(_ draft: CronJobDraft, profile: String?) async -> Bool {
        do {
            let created = try await management.createCronJob(draft: draft, profile: profile)
            cronJobs.append(created)
            formError = nil
            return true
        } catch {
            formError = Self.describe(error)
            return false
        }
    }

    private func applyCronRow(_ updated: CronJob) {
        guard let index = cronJobs.firstIndex(where: { $0.jobID == updated.jobID }) else {
            cronJobs.append(updated)
            return
        }
        cronJobs[index] = updated
    }

    // MARK: Skills

    private func reloadSkills(profile: String) async {
        do {
            let catalog = try await management.skillsCatalog(profile: profile)
            skillsRows = catalog.rows
            categoryGroups = catalog.categories.map { category in
                let names = Set(category.skills.map { $0.lowercased() })
                return (category.category, skillsRows.filter { names.contains($0.name.lowercased()) })
            }
        } catch {
            // The skills pane shares the error surface with cron; a skills
            // failure must not blank the (already loaded) cron list.
            errorMessage = Self.describe(error)
        }
    }

    public func setSkill(_ name: String, enabled: Bool, profile: String) async {
        let key = name.lowercased()
        guard !pendingSkills.contains(key) else { return }
        pendingSkills.insert(key)
        defer { pendingSkills.remove(key) }
        do {
            let resulting = try await management.setSkill(name, enabled: enabled, profile: profile)
            if let index = skillsRows.firstIndex(where: { $0.name.lowercased() == key }) {
                skillsRows[index] = ProfileSkill(name: skillsRows[index].name, isEnabled: resulting)
            }
            // The Skills pane renders categoryGroups — keep BOTH row views
            // in sync or the toggle never settles in the UI.
            for gi in categoryGroups.indices {
                if let ri = categoryGroups[gi].rows.firstIndex(where: { $0.name.lowercased() == key }) {
                    categoryGroups[gi].rows[ri] = ProfileSkill(
                        name: categoryGroups[gi].rows[ri].name, isEnabled: resulting)
                }
            }
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// Test/preview hook mirroring the pending-toggle guard.
    public func markSkillPending(_ name: String, pending: Bool) {
        let key = name.lowercased()
        if pending {
            pendingSkills.insert(key)
        } else {
            pendingSkills.remove(key)
        }
    }

    // MARK: helpers

    /// Non-secret error description for display.
    static func describe(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return String(describing: error)
    }
}
