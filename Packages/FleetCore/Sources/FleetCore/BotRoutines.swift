import Foundation

/// TRUE BOTS MODE slice 3 (D13) — Bot Routines on the existing cron
/// infrastructure (mission item 10).
///
/// A bot routine is a per-profile cron job whose NAME carries the namespace
/// `[bot:<owner>] <routine>` (mission item 10; design.md §9). Ownership is
/// implicit: `cron.manage` stores jobs under the owning profile's cron store
/// (`~/.hermes/profiles/<name>/cron/jobs.json`, cron/jobs.py:59-64), and the
/// `[bot:<slug>]` prefix in the job name marks the job as a routine of that
/// bot. There is NO owner_profile field on the wire — the namespace IS the
/// association, so parsing is strict (fail closed: a malformed prefix is a
/// general cron job, never a routine).
///
/// Wire ground truth (hermes-agent 0.21.0):
/// - `cron.manage` actions list/add/remove/pause/resume ONLY — `run` is not
///   forwarded by the WS handler (unknown action → err 4016,
///   tui_gateway/methods_tools.py:1033-1057). Run-now is therefore an
///   HONEST capability gate: the client may send `run` (correct for
///   gateways that add it) but must surface 4016 as unsupported — never a
///   facade, never `cli.exec`.
/// - `_format_job` rows (tools/cronjob_job_args.py:346-391):
///   `{job_id, name, schedule, next_run_at, last_run_at, last_status,
///   last_fire_error, last_delivery_error, paused_reason, repeat, deliver,
///   enabled, state, prompt_preview}` — the failure/error fields are what
///   the routines surface displays (never fabricated).
public enum BotRoutineNamespace {
    /// Wire prefix of every bot-routine job name: `[bot:<owner>] <routine>`.
    public static let prefix = "[bot:"

    /// The full cron job name for a routine: `[bot:<owner>] <routine>`.
    /// `owner` is the bot's profile slug (routing-safe, no `]`), `routine`
    /// is the user-facing routine label.
    public static func jobName(owner: String, routine: String) -> String {
        "\(prefix)\(owner)] \(routine)"
    }

    /// Parse a cron job name into `(owner, routine)`.
    ///
    /// STRICT: the name must start with `[bot:`, contain `]`, and carry a
    /// non-empty owner (no spaces — a profile slug) plus a non-empty routine
    /// label. Anything else is NOT a bot routine (returns nil) — malformed
    /// prefixes must never adopt a job into a bot's routine list.
    public static func parse(_ name: String) -> (owner: String, routine: String)? {
        guard name.hasPrefix(prefix) else { return nil }
        let afterPrefix = String(name.dropFirst(prefix.count))
        guard let close = afterPrefix.firstIndex(of: "]") else { return nil }
        let owner = String(afterPrefix[..<close]).trimmingCharacters(in: .whitespaces)
        let routine = String(afterPrefix[afterPrefix.index(after: close)...])
            .trimmingCharacters(in: .whitespaces)
        guard !owner.isEmpty, !owner.contains(where: { $0.isWhitespace }), !routine.isEmpty else {
            return nil
        }
        return (owner, routine)
    }

    /// True when the cron job name carries a well-formed `[bot:<owner>]`
    /// namespace (any owner).
    public static func isBotRoutine(name: String) -> Bool {
        parse(name) != nil
    }

    /// True when the job belongs to `slug`. Owner matching is
    /// case-insensitive (upstream `normalize_profile_name` lowercases;
    /// display case may differ from the stored slug).
    public static func isBotRoutine(name: String, owner slug: String) -> Bool {
        guard let parsed = parse(name) else { return false }
        return parsed.owner.lowercased() == slug.lowercased()
    }
}

/// One bot routine — a namespaced cron job presented for a specific bot.
///
/// Displays ONLY what the cron surface returns (next/last run, last status,
/// last fire/delivery error, paused reason, deliver target); results detail
/// beyond these fields is not on the `cron.manage` ws surface and is never
/// fabricated (slice scope item 4).
public struct BotRoutine: Identifiable, Hashable, Sendable {
    /// The underlying cron job (server truth).
    public let job: CronJob
    /// The owning bot's profile slug as parsed from the namespace.
    public let ownerSlug: String
    /// The user-facing routine label (namespace stripped).
    public let routineName: String

    public var id: String { job.jobID }
    public var jobID: String { job.jobID }
    public var schedule: String { job.schedule }
    public var nextRunAt: String? { job.nextRunAt }
    public var lastRunAt: String? { job.lastRunAt }
    public var lastStatus: String? { job.lastStatus }
    public var isEnabled: Bool { job.isEnabled }
    public var promptPreview: String? { job.promptPreview }
    /// Delivery target on the job record (`bot-chat[:name]`, `local`, …).
    public var deliver: String? { job.deliver }
    /// Repeat display (e.g. "forever", "once", "3 times").
    public var repeatDisplay: String? { job.repeatDisplay }

    /// The most specific failure detail the wire provides (fire error,
    /// then delivery error, then paused reason) — nil when healthy.
    public var failureDetail: String? {
        job.lastFireError ?? job.lastDeliveryError ?? job.pausedReason
    }

    /// Parse `job` as a routine owned by `slug`. Nil when the job name is
    /// not a well-formed `[bot:<slug>]`-namespaced routine.
    public init?(job: CronJob, owner slug: String) {
        guard let parsed = BotRoutineNamespace.parse(job.name),
              parsed.owner.lowercased() == slug.lowercased() else { return nil }
        self.job = job
        self.ownerSlug = parsed.owner
        self.routineName = parsed.routine
    }
}

/// Namespace-aware presentation helpers over a raw cron job list.
public enum BotRoutineFilter {
    /// The routines of one bot: jobs whose name parses as
    /// `[bot:<slug>] <routine>`, in list order.
    public static func routines(in jobs: [CronJob], owner slug: String) -> [BotRoutine] {
        jobs.compactMap { BotRoutine(job: $0, owner: slug) }
    }

    /// The GENERAL cron jobs: everything that is not a bot routine
    /// (well-formed `[bot:...]` names of ANY owner are excluded here —
    /// they render in their owning bot's routine list, not as general
    /// rows on a bot-scoped surface). The gateway-wide Cron pane keeps
    /// showing the full unfiltered list — this filter is for bot-scoped
    /// presentation only and never mutates or hijacks the general list.
    public static func generalCronJobs(in jobs: [CronJob]) -> [CronJob] {
        jobs.filter { !BotRoutineNamespace.isBotRoutine(name: $0.name) }
    }
}
