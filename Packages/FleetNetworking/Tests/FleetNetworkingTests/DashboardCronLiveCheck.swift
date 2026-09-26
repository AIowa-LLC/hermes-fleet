import XCTest
import FleetCore
@testable import FleetNetworking

/// Card B — ENVIRONMENTAL live check (opt-in): proves the real
/// `DashboardCronClient` drives the FULL management contract against a
/// running Hermes dashboard: list → create → detail → edit (PUT, identity
/// preserved) → pause → resume → trigger → runs → delete, plus the auth and
/// not-found classifications on the wire.
///
/// Skipped unless `FLEET_LIVE_CRON_*` env vars are present, so CI stays
/// hermetic. Driven by `scripts/b_cron_live_check.sh`, which supplies:
/// - `FLEET_LIVE_CRON_BASE_URL`     dashboard base (e.g. http://127.0.0.1:18923)
/// - `FLEET_LIVE_CRON_TOKEN_FILE`   file holding the session token
/// - `FLEET_LIVE_CRON_PROFILE`      profile whose store the check uses
/// - `FLEET_LIVE_CRON_EVIDENCE_OUT` where to write the evidence JSON
final class DashboardCronLiveCheck: XCTestCase {

    private struct LiveConfig {
        let baseURL: URL
        let token: String
        let profile: String
        let evidenceOut: String?
    }

    private func liveConfig() throws -> LiveConfig {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["FLEET_LIVE_CRON_BASE_URL"], let url = URL(string: base),
              let tokenFile = env["FLEET_LIVE_CRON_TOKEN_FILE"] else {
            throw XCTSkip("live cron check not configured (set FLEET_LIVE_CRON_* env)")
        }
        let token = try String(contentsOfFile: tokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw XCTSkip("live cron token file was empty") }
        return LiveConfig(
            baseURL: url,
            token: token,
            profile: env["FLEET_LIVE_CRON_PROFILE"] ?? "default",
            evidenceOut: env["FLEET_LIVE_CRON_EVIDENCE_OUT"])
    }

    private func makeClient(_ config: LiveConfig, token: String?) -> DashboardCronClient {
        DashboardCronClient(
            gatewayID: GatewayID(rawValue: "live-dev-gateway"),
            baseURL: config.baseURL,
            httpCredential: { token.map { .sessionTokenHeader($0) } ?? .none })
    }

    func testLiveCronContract() async throws {
        let config = try liveConfig()
        let client = makeClient(config, token: config.token)
        var checks: [[String: Any]] = []

        func record(_ name: String, ok: Bool, detail: Any) {
            checks.append(["name": name, "ok": ok, "detail": detail])
        }

        var createdID: String?

        // 1. LIST — decodes the bare array with the execution ledger.
        do {
            let jobs = try await client.listJobs(profile: "all")
            record("list-jobs", ok: true, detail: [
                "count": jobs.count,
                "with_ledger": jobs.filter { $0.latestExecution != nil }.count,
                "profiles": Array(Set(jobs.compactMap(\.profile))).sorted(),
            ])
        } catch {
            record("list-jobs", ok: false, detail: "\(error)")
        }

        // 2. DELIVERY TARGETS.
        do {
            let targets = try await client.deliveryTargets()
            record("delivery-targets", ok: targets.contains { $0.id == "local" },
                   detail: targets.map(\.id))
        } catch {
            record("delivery-targets", ok: false, detail: "\(error)")
        }

        // 3. CREATE (script flavor — runs without a provider key).
        do {
            let created = try await client.createJob(
                CronJobCreateRequest(
                    name: "fleet-b-live-check", schedule: "*/30 * * * *",
                    prompt: "", deliver: "local", script: "fleet_pin.sh", noAgent: true),
                profile: config.profile)
            createdID = created.id
            record("create-job", ok: !created.id.isEmpty && created.noAgent, detail: [
                "id": created.id, "state": created.displayState, "deliver": created.deliver,
                "no_agent": created.noAgent, "script": created.script ?? "nil",
                "profile": created.profile ?? "nil",
            ])
        } catch {
            record("create-job", ok: false, detail: "\(error)")
        }

        if let id = createdID {
            // 4. DETAIL.
            do {
                let job = try await client.job(id: id, profile: config.profile)
                record("get-job", ok: job.id == id, detail: ["id": job.id, "name": job.name])
            } catch {
                record("get-job", ok: false, detail: "\(error)")
            }

            // 5. EDIT — PUT preserves identity.
            do {
                let updated = try await client.updateJob(
                    id: id,
                    patch: CronJobPatch(name: "fleet-b-live-check-v2", deliver: "local"),
                    profile: config.profile)
                record("update-preserves-identity",
                       ok: updated.id == id && updated.name == "fleet-b-live-check-v2",
                       detail: ["id": updated.id, "name": updated.name])
            } catch {
                record("update-preserves-identity", ok: false, detail: "\(error)")
            }

            // 6. PAUSE / RESUME.
            do {
                let paused = try await client.pauseJob(id: id, profile: config.profile)
                let resumed = try await client.resumeJob(id: id, profile: config.profile)
                record("pause-resume",
                       ok: !paused.enabled && resumed.enabled,
                       detail: ["paused_state": paused.displayState, "resumed_state": resumed.displayState])
            } catch {
                record("pause-resume", ok: false, detail: "\(error)")
            }

            // 7. TRIGGER — runs the script job. The execution ledger is
            // asserted from a FOLLOW-UP LIST read: only list rows attach
            // `latest_execution` (the detail/trigger responses do not).
            do {
                let fired = try await client.triggerJob(id: id, profile: config.profile)
                let rows = try await client.listJobs(profile: config.profile)
                let ledger = rows.first { $0.id == id }?.latestExecution
                record("trigger-runs-job",
                       ok: ledger != nil && ledger?.status == "completed",
                       detail: [
                    "last_run_at": fired.lastRunAt ?? "nil",
                    "last_status": fired.lastStatus ?? "nil",
                    "execution_status": ledger?.status ?? "nil",
                    "delivery_outcome": ledger?.deliveryOutcome ?? "nil",
                    "ledger_source": "list row (the detail endpoint carries no ledger)",
                ])
            } catch let error as CronDashboardError where error.isAlreadyRunning {
                // A lost claim is a legitimate outcome of the atomic claim.
                record("trigger-runs-job", ok: true, detail: "already running (409 claim conflict)")
            } catch {
                record("trigger-runs-job", ok: false, detail: "\(error)")
            }

            // 8. RUNS — script jobs answer an empty list by design.
            do {
                let runs = try await client.runSessions(jobID: id, profile: config.profile, limit: 20)
                record("runs-history", ok: true, detail: ["count": runs.count])
            } catch {
                record("runs-history", ok: false, detail: "\(error)")
            }

            // 9. DELETE + the 404 classification.
            do {
                try await client.deleteJob(id: id, profile: config.profile)
                record("delete-job", ok: true, detail: ["id": id])
                do {
                    _ = try await client.job(id: id, profile: config.profile)
                    record("deleted-job-404", ok: false, detail: "deleted job still resolves")
                } catch let error as CronDashboardError {
                    record("deleted-job-404", ok: error == .notFound, detail: "\(error)")
                }
            } catch {
                record("delete-job", ok: false, detail: "\(error)")
            }
        }

        // 10. Auth is real: no credential → 401.
        do {
            _ = try await makeClient(config, token: nil).listJobs(profile: "all")
            record("auth-required", ok: false, detail: "unauthenticated list unexpectedly succeeded")
        } catch let error as CronDashboardError {
            record("auth-required", ok: error == .unauthorized, detail: "\(error)")
        } catch {
            record("auth-required", ok: false, detail: "\(error)")
        }

        // 11. Unknown job → 404.
        do {
            _ = try await client.job(id: "does-not-exist-live-check", profile: config.profile)
            record("unknown-job-404", ok: false, detail: "unknown job unexpectedly resolved")
        } catch let error as CronDashboardError {
            record("unknown-job-404", ok: error == .notFound, detail: "\(error)")
        } catch {
            record("unknown-job-404", ok: false, detail: "\(error)")
        }

        // Evidence + verdict.
        let failures = checks.filter { ($0["ok"] as? Bool) != true }.map { $0["name"] as? String ?? "?" }
        let evidence: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "base_url": config.baseURL.absoluteString,
            "profile": config.profile,
            "checks": checks,
            "verdict": ["all_pass": failures.isEmpty, "failures": failures],
        ]
        if let out = config.evidenceOut,
           let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: out))
        }
        if let summary = String(
            data: (try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])) ?? Data(),
            encoding: .utf8) {
            print("LIVE-EVIDENCE \(summary)")
        }
        XCTAssertTrue(failures.isEmpty, "live cron checks failed: \(failures)")
    }
}