import Foundation

/// R9-T5/T6 — per-gateway management panes (cron jobs + skills).
///
/// Wire ground truth (hermes-agent 0.21.0, installed source):
/// - `cron.manage` (tui_gateway/methods_tools.py:1753-1827):
///   params `{action, name?, profile?, ...}` with actions
///   `list` (plus `include_disabled: true` or paused jobs VANISH from the
///   list — methods_tools.py:1770-1779 comment), `add`
///   (name/schedule/prompt[/deliver]), `remove` / `pause` / `resume`
///   (job id in `name`). Result rows via `_format_job`
///   (tools/cronjob_tools.py:753-791): `{job_id, name, schedule,
///   next_run_at, last_run_at, last_status, enabled, state,
///   prompt_preview, deliver, repeat}`; the list envelope is
///   `{success, count, jobs: [...]}` (+ `scoped: <profile>` when a
///   profile scope was honored, methods_tools.py:1786-1790).
/// - FIRE-NOW GAP: `cronjob(action="run"|"run_now"|"trigger")` EXISTS in
///   the tool layer (cronjob_tools.py:1765) but the WS handler does NOT
///   forward it — an unknown action returns err 4016
///   (methods_tools.py:1826-1827). The client still sends
///   `action:"run"`; a 4016 maps to a typed `unsupportedAction` so the
///   row can surface an honest "gateway doesn't support run-over-WS"
///   state until the handler is extended.
/// - `skills.manage` (methods_tools.py:1897-1959): actions
///   list/search/install/browse/inspect. `list` returns
///   `{skills: {category: [names]}}` (banner.py:102). There is NO toggle
///   action on this surface.
/// - Skill enable/disable is PROFILE CONFIG: `profiles.describe`
///   (methods_profiles.py:596) returns `skills: [{name, enabled}]`
///   (enabled = installed unless in `skills.disabled`,
///   methods_profiles.py:625-640), and `profiles.configure`
///   (methods_profiles.py:767) applies `disabled_skills` (list[str],
///   REPLACE semantics, methods_profiles.py:935-969) → `{ok, applied}`.
///   A toggle therefore round-trips describe → set-toggle → configure
///   (full replacement list) and verifies via a fresh describe.
public struct CronJob: Identifiable, Hashable, Sendable {
    /// Stable id on the wire (`job_id`).
    public let jobID: String
    /// Human name (falls back to prompt head/skill on the server).
    public let name: String
    /// Display schedule (mono in the UI).
    public let schedule: String
    /// ISO instant of the next scheduled run (nil when paused/one-shot done).
    public let nextRunAt: String?
    /// ISO instant of the last run.
    public let lastRunAt: String?
    /// Last run status (ok / delivery_failed / …).
    public let lastStatus: String?
    /// Server-truth enabled flag.
    public let isEnabled: Bool
    /// Derived server state (enabled-aware; paused records never render
    /// enabled — cronjob_tools.py:768 `effective_job_state`).
    public let state: String
    /// Up-to-100-char prompt preview (already truncated server-side).
    public let promptPreview: String?

    public init(
        jobID: String,
        name: String,
        schedule: String,
        nextRunAt: String? = nil,
        lastRunAt: String? = nil,
        lastStatus: String? = nil,
        isEnabled: Bool = true,
        state: String = "",
        promptPreview: String? = nil
    ) {
        self.jobID = jobID
        self.name = name
        self.schedule = schedule
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
        self.isEnabled = isEnabled
        self.state = state
        self.promptPreview = promptPreview
    }

    public var id: String { jobID }
}

/// One installed skill on a profile, with its enablement.
public struct ProfileSkill: Identifiable, Hashable, Sendable {
    public let name: String
    public let isEnabled: Bool

    public init(name: String, isEnabled: Bool) {
        self.name = name
        self.isEnabled = isEnabled
    }

    public var id: String { name }
}

/// Skills grouped the way `skills.manage list` reports them
/// (`{category: [names]}` — banner.py:102), plus per-skill enablement from
/// the profile describe pass.
///
/// UNION DISCIPLINE (review round 1): `skills.manage list` EXCLUDES disabled
/// skills on hermes-agent 0.21.0 (tools/skills_tool.py:773
/// `if name in disabled: continue`; no include-disabled flag on the WS
/// handler — methods_tools.py:1916-1919), while `profiles.describe` walks
/// the profile skills dir UNFILTERED and reports disabled skills with
/// enabled:false (methods_profiles.py:625-640). Without a union, a
/// disabled skill vanishes from the catalog on the next reload — a
/// one-way door on live gateways. `categories` is therefore the JOINED
/// view: every listed category in list order, plus describe-only names
/// (i.e. skills the list pass filtered out) under the `installed`
/// fallback group so they always render with their toggle.
public struct SkillsCatalog: Sendable {
    /// Fallback group for describe-only skills whose category the (filtered)
    /// list pass no longer reports.
    public static let fallbackCategory = "installed"

    public let categories: [(category: String, skills: [String])]
    /// Enablement by lowercased skill name (profiles.describe's model:
    /// enabled unless listed in the profile's skills.disabled config).
    public let enabledByName: [String: Bool]

    public init(categories: [(category: String, skills: [String])], enabledByName: [String: Bool]) {
        self.categories = categories
        self.enabledByName = enabledByName
    }

    /// Flat rows in category order: name + enablement (unknown → enabled,
    /// matching the installed-unless-disabled model).
    public var rows: [ProfileSkill] {
        categories.flatMap { category in
            category.skills.map { name in
                ProfileSkill(
                    name: name,
                    isEnabled: enabledByName[name.lowercased()] ?? true
                )
            }
        }
    }
}

extension SkillsCatalog {
    /// UNION of the `skills.manage list` categories with `profiles.describe`'s
    /// unfiltered skills set — the anti-one-way-door join. List categories
    /// keep their wire order and canonical casing; describe-only names
    /// (disabled skills the list pass filtered out — skills_tool.py:773) go
    /// to the `installed` fallback group (sorted, lowercased spelling from
    /// describe). Names are matched case-insensitively; describe is the
    /// floor — an empty list pass still yields every described skill.
    public init(
        unionOf listCategories: [(category: String, skills: [String])],
        describedSkills: [String: Bool]
    ) {
        var seen = Set<String>()
        var merged: [(category: String, skills: [String])] = []
        for group in listCategories {
            var names: [String] = []
            for name in group.skills {
                let key = name.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                names.append(name)
            }
            if !names.isEmpty {
                merged.append((group.category, names))
            }
        }
        // Describe-only names the filtered list no longer categorizes: the
        // `installed` fallback group (sorted) — describe is the floor, so a
        // disabled skill always keeps its row + toggle.
        let orphans = describedSkills
            .keys
            .filter { !seen.contains($0) }
            .sorted()
        if !orphans.isEmpty {
            merged.append((Self.fallbackCategory, orphans))
        }
        self.init(categories: merged, enabledByName: describedSkills)
    }
}

/// A new-job draft for the create form (cron.manage action=add).
public struct CronJobDraft: Hashable, Sendable {
    public var name: String
    public var schedule: String
    public var prompt: String

    public init(name: String = "", schedule: String = "", prompt: String = "") {
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
    }

    /// Client-side validity (the server re-validates): a job needs a name,
    /// a schedule, and a prompt (create requires either prompt or a skill —
    /// cronjob_tools.py:1580-1583; this form is the prompt flavor).
    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Errors surfaced by the management panes. Non-secret (spec §29 discipline).
public enum GatewayManagementError: Error, Sendable, Equatable, LocalizedError {
    /// The gateway rejected the action vocabulary (e.g. cron run-over-WS is
    /// not forwarded by hermes-agent 0.21.0's tui_gateway handler).
    case unsupportedAction(String)
    /// The requested profile scope does not exist (err 4064).
    case profileNotFound(String)
    /// The response body was not the expected shape.
    case malformedResponse(String)
    /// A transport/RPC failure (classified detail, non-secret).
    case rpcFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedAction(let detail):
            return "gateway does not support this action (\(detail))"
        case .profileNotFound(let name):
            return "profile '\(name)' not found on this gateway"
        case .malformedResponse(let detail):
            return "malformed gateway response (\(detail))"
        case .rpcFailed(let detail):
            return detail
        }
    }
}

/// R9-T5/T6 seam: cron + skills management over a gateway's transport.
/// Lives in FleetCore so FleetUI never imports FleetNetworking (M0 guard);
/// the concrete `GatewayManagementClient` is injected at the composition
/// root (per-gateway, alongside the conversation session factory).
///
/// PROFILE SCOPING: cron stores jobs under the profile's HERMES_HOME
/// (methods_tools.py:1756-1759), and skills disablement is profile config —
/// so every call carries a profile name. `nil` means the gateway's launch
/// profile.
public protocol GatewayManagementProviding: Sendable {
    /// `cron.manage {action: "list", include_disabled: true}` — every job
    /// (paused included) for the profile.
    func listCronJobs(profile: String?) async throws -> [CronJob]

    /// `cron.manage {action: "add", name, schedule, prompt}`.
    /// - Returns: the created job as the server reports it.
    @discardableResult
    func createCronJob(draft: CronJobDraft, profile: String?) async throws -> CronJob

    /// `cron.manage {action: "pause"|"resume", name: jobID}` — the toggle.
    /// - Returns: the updated job.
    @discardableResult
    func setCronJob(_ jobID: String, enabled: Bool, profile: String?) async throws -> CronJob

    /// `cron.manage {action: "remove", name: jobID}` — delete.
    func deleteCronJob(_ jobID: String, profile: String?) async throws

    /// `cron.manage {action: "run", name: jobID}` — fire now. Throws
    /// `.unsupportedAction` on gateways whose WS handler does not forward
    /// the run action (hermes-agent 0.21.0: err 4016).
    func fireCronJob(_ jobID: String, profile: String?) async throws

    /// `skills.manage {action: "list"}` joined with `profiles.describe`
    /// `skills` enablement — the catalog with per-skill toggles.
    func skillsCatalog(profile: String) async throws -> SkillsCatalog

    /// Toggle one skill via `profiles.configure {disabled_skills}` (REPLACE
    /// semantics: the full disabled list is recomputed from the described
    /// set with this one flip applied, then verified by a fresh describe).
    /// - Returns: the skill's resulting enabled state.
    @discardableResult
    func setSkill(_ name: String, enabled: Bool, profile: String) async throws -> Bool
}

/// Fail-closed default for gateways without a management surface (no
/// endpoint configured): every call throws instead of silently pretending
/// the gateway answered (the `UnsupportedApprovals` discipline).
public struct UnsupportedGatewayManagement: GatewayManagementProviding {
    public init() {}

    public func listCronJobs(profile: String?) async throws -> [CronJob] {
        throw GatewayManagementError.rpcFailed("gateway not configured")
    }

    public func createCronJob(draft: CronJobDraft, profile: String?) async throws -> CronJob {
        throw GatewayManagementError.rpcFailed("gateway not configured")
    }

    public func setCronJob(_ jobID: String, enabled: Bool, profile: String?) async throws -> CronJob {
        throw GatewayManagementError.rpcFailed("gateway not configured")
    }

    public func deleteCronJob(_ jobID: String, profile: String?) async throws {
        throw GatewayManagementError.rpcFailed("gateway not configured")
    }

    public func fireCronJob(_ jobID: String, profile: String?) async throws {
        throw GatewayManagementError.rpcFailed("gateway not configured")
    }

    public func skillsCatalog(profile: String) async throws -> SkillsCatalog {
        throw GatewayManagementError.rpcFailed("gateway not configured")
    }

    public func setSkill(_ name: String, enabled: Bool, profile: String) async throws -> Bool {
        throw GatewayManagementError.rpcFailed("gateway not configured")
    }
}
