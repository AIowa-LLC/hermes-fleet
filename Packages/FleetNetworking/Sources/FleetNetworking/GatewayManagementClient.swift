import Foundation
import os
import FleetCore

/// R9-T5/T6 — concrete `GatewayManagementProviding` over the conversation
/// transport: `cron.manage` (list/add/pause/resume/remove/run) and the
/// skills surfaces (`skills.manage` list + `profiles.describe` +
/// `profiles.configure` disabled_skills).
///
/// Wire ground truth (hermes-agent 0.21.0):
/// - `cron.manage` — tui_gateway/methods_tools.py:1753-1827. Params
///   `{action, name, profile?, ...}`. Actions: `list` (forwards
///   `include_disabled` — paused jobs are otherwise EXCLUDED, which would
///   read as deletion in a UI with a toggle), `add` (name/schedule/prompt),
///   `remove`/`pause`/`resume` (job id in `name`). The tool layer ALSO
///   accepts `run` (cronjob_tools.py:1765) but the WS handler does not
///   forward it on 0.21.0 → err 4016; the client sends `run` and maps
///   4016 to `.unsupportedAction` so the row can say so honestly.
/// - list rows — `_format_job` (tools/cronjob_tools.py:753-791):
///   `{job_id, name, schedule, next_run_at, last_run_at, last_status,
///   enabled, state, prompt_preview}`.
/// - `skills.manage {action:"list"}` — methods_tools.py:1916-1919 →
///   banner.py:102: `{skills: {category: [names]}}`. No toggle action on
///   this surface.
/// - `profiles.describe` — methods_profiles.py:596: `skills: [{name,
///   enabled}]` (enabled = installed unless in skills.disabled).
/// - `profiles.configure` — methods_profiles.py:767,935-969:
///   `{name, disabled_skills: [...]}` REPLACE semantics → `{ok, applied}`.
public struct GatewayManagementClient: GatewayManagementProviding {
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    private static let log = Logger(
        subsystem: "com.aiowa.hermesfleet", category: "gateway-management")

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    // MARK: - Cron

    public func listCronJobs(profile: String?) async throws -> [CronJob] {
        var params: [String: JSONValue] = [
            "action": .string("list"),
            "include_disabled": .bool(true),
        ]
        if let profile { params["profile"] = .string(profile) }
        let result = try await request(method: "cron.manage", params: .object(params))
        return Self.decodeJobs(result)
    }
    @discardableResult
    public func createCronJob(draft: CronJobDraft, profile: String?) async throws -> CronJob {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let schedule = draft.schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !schedule.isEmpty, !prompt.isEmpty else {
            throw GatewayManagementError.malformedResponse("job needs a name, schedule, and prompt")
        }
        var params: [String: JSONValue] = [
            "action": .string("add"),
            "name": .string(name),
            "schedule": .string(schedule),
            "prompt": .string(prompt),
        ]
        if let profile { params["profile"] = .string(profile) }
        let result = try await request(method: "cron.manage", params: .object(params))
        // Create answers the row at top level AND under "job"
        // (cronjob_tools.py:1683-1686); prefer the richer embedded row.
        if let job = Self.decodeJob(result["job"]) {
            return job
        }
        return Self.decodeJob(result) ?? CronJob(
            jobID: result["job_id"]?.stringValue ?? "",
            name: result["name"]?.stringValue ?? name,
            schedule: result["schedule"]?.stringValue ?? schedule,
            nextRunAt: result["next_run_at"]?.stringValue,
            isEnabled: true)
    }

    @discardableResult
    public func setCronJob(_ jobID: String, enabled: Bool, profile: String?) async throws -> CronJob {
        var params: [String: JSONValue] = [
            "action": .string(enabled ? "resume" : "pause"),
            "name": .string(jobID),
        ]
        if let profile { params["profile"] = .string(profile) }
        let result = try await request(method: "cron.manage", params: .object(params))
        guard let job = Self.decodeJob(result["job"]) else {
            throw GatewayManagementError.malformedResponse("cron \(enabled ? "resume" : "pause") result missing 'job'")
        }
        return job
    }

    public func deleteCronJob(_ jobID: String, profile: String?) async throws {
        var params: [String: JSONValue] = [
            "action": .string("remove"),
            "name": .string(jobID),
        ]
        if let profile { params["profile"] = .string(profile) }
        _ = try await request(method: "cron.manage", params: .object(params))
    }

    public func fireCronJob(_ jobID: String, profile: String?) async throws {
        var params: [String: JSONValue] = [
            "action": .string("run"),
            "name": .string(jobID),
        ]
        if let profile { params["profile"] = .string(profile) }
        _ = try await request(method: "cron.manage", params: .object(params))
    }

    // MARK: - Skills

    public func skillsCatalog(profile: String) async throws -> SkillsCatalog {
        // Pass 1: the visible catalog with categories. NOTE: 0.21.0's
        // `skills.manage list` EXCLUDES disabled skills (skills_tool.py:773)
        // with no include-disabled flag on the WS handler
        // (methods_tools.py:1916-1919), so this pass alone cannot be the
        // catalog — pass 2 is the floor.
        let listResult = try await request(
            method: "skills.manage",
            params: .object([
                "action": .string("list"),
                "profile": .string(profile),
            ]))
        var categories: [(category: String, skills: [String])] = []
        if let skillsObject = listResult["skills"]?.objectValue {
            for (category, names) in skillsObject.sorted(by: { $0.key < $1.key }) {
                let names = names.arrayValue?.compactMap(\.stringValue) ?? []
                categories.append((category, names))
            }
        }
        // Pass 2: per-profile enablement from the UNFILTERED describe set —
        // the union join (review round 1: without it, disabling a skill
        // makes it vanish on the next reload; describe keeps it visible
        // with enabled:false and its toggle).
        let enabledByName = try await describedSkills(profile: profile)
        return SkillsCatalog(
            unionOf: categories, describedSkills: enabledByName)
    }

    public func setSkill(_ name: String, enabled: Bool, profile: String) async throws -> Bool {
        // The wire is REPLACE semantics: read the described set, apply this
        // one flip, send the full replacement list (methods_profiles.py:935-969).
        let enabledByName = try await describedSkills(profile: profile)
        let lower = name.lowercased()
        let nextDisabled = enabledByName
            .filter { !$0.value }
            .map(\.key)
            .filter { $0 != lower }
            + (enabled ? [] : [lower])
        let result = try await request(
            method: "profiles.configure",
            params: .object([
                "name": .string(profile),
                "disabled_skills": .array(nextDisabled.sorted().map { .string($0) }),
            ]))
        guard result["ok"]?.boolValue == true else {
            throw GatewayManagementError.rpcFailed("profiles.configure did not apply the skills section")
        }
        // Verify by a fresh describe — the readback IS the truth.
        let after = try await describedSkills(profile: profile)
        return after[lower] ?? enabled
    }

    /// `profiles.describe {name}` → `{lowercased skill name: enabled}`.
    private func describedSkills(profile: String) async throws -> [String: Bool] {
        let result = try await request(
            method: "profiles.describe",
            params: .object(["name": .string(profile)]))
        guard let rows = result["skills"]?.arrayValue else {
            throw GatewayManagementError.malformedResponse("profiles.describe result missing 'skills'")
        }
        var out: [String: Bool] = [:]
        for row in rows {
            guard let o = row.objectValue,
                  let name = o["name"]?.stringValue, !name.isEmpty else { continue }
            out[name.lowercased()] = o["enabled"]?.boolValue ?? true
        }
        return out
    }

    // MARK: - decode / error mapping

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        // Idempotent connect (P0-7: connect from .open is a no-op) — the
        // pane's transport starts cold; the first management RPC opens it.
        if !isTransportReady {
            try await transport.connect()
        }
        do {
            return try await transport.request(method: method, params: params)
        } catch let error as JSONRPCError {
            throw Self.mapError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        }
    }

    private var isTransportReady: Bool {
        if case .connected = transport.state { return true }
        return false
    }

    /// `{success, count, jobs: [...]}` → `[CronJob]` (non-array jobs
    /// decodes as empty — fail soft).
    static func decodeJobs(_ result: JSONValue) -> [CronJob] {
        result["jobs"]?.arrayValue?.compactMap(Self.decodeJob) ?? []
    }

    /// A `_format_job` row (cronjob_tools.py:753-791).
    static func decodeJob(_ value: JSONValue?) -> CronJob? {
        guard let o = value?.objectValue,
              let jobID = o["job_id"]?.stringValue, !jobID.isEmpty else { return nil }
        return CronJob(
            jobID: jobID,
            name: o["name"]?.stringValue ?? jobID,
            schedule: o["schedule"]?.stringValue ?? "?",
            nextRunAt: o["next_run_at"]?.stringValue,
            lastRunAt: o["last_run_at"]?.stringValue,
            lastStatus: o["last_status"]?.stringValue,
            isEnabled: o["enabled"]?.boolValue ?? true,
            state: o["state"]?.stringValue ?? "",
            promptPreview: o["prompt_preview"]?.stringValue
        )
    }

    static func mapError(_ error: JSONRPCError) -> GatewayManagementError {
        switch error.code {
        case 4016:
            // Unknown cron action — 0.21.0's handler does not forward `run`.
            return .unsupportedAction(error.message)
        case 4017:
            // Unknown skills action.
            return .unsupportedAction(error.message)
        case 4063, 4064:
            return .profileNotFound(error.message)
        case 5023, 5024, 5064:
            return .rpcFailed(error.message)
        default:
            return .rpcFailed("\(error.message) (\(error.code))")
        }
    }

    static func mapTransportError(_ error: TransportError) -> GatewayManagementError {
        switch error {
        case .connectionClosed(let reason):
            return .rpcFailed("connection closed: \(reason.debugDescription)")
        case .requestTimeout:
            return .rpcFailed("request timed out")
        case .invalidState(let s):
            return .rpcFailed("invalid state: \(s)")
        default:
            return .rpcFailed(String(describing: error))
        }
    }
}
