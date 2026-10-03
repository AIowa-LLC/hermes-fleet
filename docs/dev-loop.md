# Dev Loop v3: fast protected integration

## Contract

`CI Gate` remains the required GitHub Actions check. Pull requests, the merge
queue, force-push/deletion protection, and exact-candidate validation remain in
place. This workflow change does not grant a bypass or authorize a release.

| Event | Required validation |
| --- | --- |
| Pull request | Static/security/project guards, package tests, hosted unit tests, and changed-area UI preflight. |
| Merge group | The same checks on the exact combined candidate, plus critical UI smoke. |
| Push to main | Static guards, package tests, and hosted units as post-merge confirmation. |
| Nightly/manual deep run | Complete deterministic UI inventory in five shards, with an independent `Full UI Regression Gate`. |

The full UI inventory is not an unconditional dependency of every merge.
It is still mandatory when selected by a broad changed area and available for
release/deep validation. A failure in a nonblocking workflow remains a failure.

## Changed-area coverage

`scripts/c1_ui_preflight.sh` selects suites from the actual PR or merge-group
base, not from a stale local branch or another build. CI partitions the selected
suites over twelve smaller jobs, with at most six running concurrently. All must succeed; failure or cancellation cannot be
converted into a successful aggregate.

The former 12-suite cap and fallback to two CORE journeys are removed. Every
selected suite is assigned exactly once. `c1_ui_partition.py` balances by the canonical historical suite
runtime weights. These are balancing inputs, not completion-time promises.

Shared FleetCore, networking, persistence, security, dependency manifests/lock
files, and composition-root changes select the complete deterministic inventory.
Feature-specific UI changes retain their mapped suites. Unmapped product files
retain CORE journeys and require review of whether a more specific mapping is
needed. New deterministic suites must be registered in the canonical inventory.
A broad reconciliation PR can therefore still be expensive; routine changes no
longer inherit the entire suite automatically.

```sh
bash scripts/c1_ui_preflight.sh --base origin/main --print
bash scripts/c1_ui_preflight.sh --base origin/main --shard 1 --shards 12 --print
bash scripts/c1_ui_preflight_test.sh
```

## Critical merge smoke

The reviewed method-level set covers fresh-install onboarding, Bots navigation,
a streamed conversation, and hosted-room open/send/render. Build 87 and later
also require `testGroupConversationOpensAtLatestWithDeepHistory`.

The Build 86 integration baseline predates that test. The policy explicitly
allows that migration baseline but rejects a Build 87+ candidate that omits the
known regression. The smoke is not proof that all other product behavior works.

```sh
bash scripts/c1_critical_smoke.sh --list-tests
bash scripts/c1_critical_smoke.sh
```

## Local simulators for parallel lanes

Local `make dev-check` gives each worktree its own simulator (`HF-<repo>-<id>`, see
`scripts/lane_simulator.sh`), so concurrent lanes no longer share a device and
do not need to take turns. Precedence for every runner, including the focused
preflight, hosted units, critical smoke and iPad smoke: `HERMES_FLEET_SIM_UDID`
(explicit device) over `HERMES_FLEET_LANE_SIM=1` (lane simulator, default for
local `dev-check`, off when `CI=true`) over the unchanged first-available-iPhone
selection that hosted CI uses. Runners record the selection and UDID in their
evidence metadata. Full details, the iPad variant and cleanup commands
(`shutdown`, `delete`, `gc`) are in
[DEVELOPMENT.md](DEVELOPMENT.md#parallel-agent-lanes).

## Execution and evidence

The runner performs one `xcodebuild build-for-testing` per invocation, followed
by isolated per-suite `test-without-building` processes. Method-level selection
must produce exactly the expected cases. Empty, missing, skipped without an
explicit platform exception, malformed, or incomplete results fail closed.

Focused and critical runs stop after a conclusive suite failure. The nightly
matrix continues collecting failures. Xcode may retry a failed test once;
recovered failures are reported as `FLAKE_RECOVERED`, not hidden.

Each invocation creates a unique `/tmp/hermes-c1-results.*` directory containing
build/test logs, xcresults, parsed summaries, and source/toolchain/destination
metadata. Another worker's results are never deleted. CI retains evidence on
success and failure, including successful retries.

Job ceilings are safety limits, not speed promises: static 15 minutes, packages
25, units 40, focused partitions 75, critical smoke 45, deep shards 150. Measure
actual runtimes before tightening these or changing shard balance. Hosted units
and simulator startup can still dominate. Xcode/runner pinning requires separate
validation; provenance records the selected environment.

## Hosted unit diagnostics

The hosted-unit runner retains a unique directory per invocation containing its
full Xcode log, source/toolchain/destination metadata, and the xcresult bundle
when Xcode creates one. CI uploads that exact directory on success or failure
and retains it for seven days; reruns use separate artifact names. Early
infrastructure failures retain their logs without inventing an xcresult.
Failed case names are printed before the bounded summary so later passing
suites cannot hide them. Test selection, simulator signing, macro trust, and
Xcode exit-code pass/fail behavior are unchanged.

Diagnostic package and UI artifact names also include the workflow run attempt
and the shard where applicable. Rerunning a failed job preserves its previous
evidence and uploads a distinct artifact; it cannot collide with an immutable
artifact from an earlier attempt. The CI policy guard checks producer, attempt,
and shard uniqueness against the actual CI/deep workflow templates.

## Local tests of CI plumbing

These tests do not start a simulator and are not product acceptance evidence:

```sh
bash scripts/ci_gate_policy_check.sh
python3 scripts/ci_artifact_contract_test.py
bash scripts/ci_gate_policy_contract_test.sh
bash scripts/c1_ui_preflight_test.sh
python3 scripts/c1_ui_runner_contract_test.py
python3 scripts/c1_xcresult_parse_test.py
bash scripts/c1_packages_contract_test.sh
python3 scripts/c1_units_contract_test.py
python3 scripts/lane_simulator_contract_test.py
```

Mocked-runner tests check build reuse, fail-fast behavior, retained coverage,
method selection, missing evidence, and the known-regression requirement.
Real GitHub-hosted validation remains required before merging the CI change.

## Failure handling

- Product regression: preserve the reproducer and fix it. Critical regressions
  block release and remain represented in focused checks.
- Infrastructure failure: retain diagnostics and rerun the affected job against
  the same source. Do not label it a product pass.
- Proven flaky harness: track a repair. Any temporary quarantine needs explicit
  scope, evidence, an owner, and expiry; do not delete tests to obtain green.
- Incomplete evidence: validation is incomplete, never implicitly successful.

A previous successful job can only support the source/configuration it tested.
A new commit or merge candidate needs its own required validation.

## Integration is not distribution

Follow [DEVELOPMENT.md](DEVELOPMENT.md) for branch ownership and
[integration-safe-main.md](integration-safe-main.md) for reconciliation.
A release record must connect exact source, dependencies and configuration,
archive/IPA, TestFlight build number, and device acceptance. Preserve the original
release source tag after squash integration; record the new main SHA separately.

No upload, public promotion, existing release-tag movement, automatic feature
implementation, or claim of upstream parity is implied by this CI policy.

## Package-runner migration

The historical main package runner discarded assertion details and ignored the
actual `swift test` exit code. The safer runner from the preserved newer source
is now included in this CI-only migration, with exact expected counts for this
main baseline: FleetCore 415, FleetNetworking 418, FleetPersistence 31, and
FleetSecurity 37. Those counts are source-specific, not permanent limits.

When reconciling the newer product source, preserve its corresponding counts
and update them deliberately with test additions. Do not transplant historical
counts onto a newer test inventory. A command failure, missing summary, partial
count, or failed assertion cannot become green. Full package logs are retained
and uploaded for successful and failed jobs, and assertion lines are printed
before the summary. Five mocked Swift contract cases verify these rules.

## Build 90 reconciliation

The integrated candidate retains all 59 deterministic and 11 environmental UI
suites from the recorded Build 90 source. Environmental suites still require
their real gateway/device context and are not silently counted as CI passes.
The five-way deep workflow keeps the release line's historical runtime weights;
these predate build reuse and are balancing inputs, not speed forecasts.
Package baselines are 691 core, 613 networking, 58 persistence, and 46
security tests. These include the Live Ops runtime, cold-transport,
cross-process reporting, structured ownership-refusal, and frozen-clock
launch-cache TTL boundary regressions. Launch-cache fixtures use an injected
clock so their seven-day expiry is deterministic rather than dependent on the
date CI runs. Update the exact-count gate when adding or removing tests;
partial runs must remain failures. Focused selection maps the newer Kanban,
artifacts, image generation, cron, reasoning, slash-parity, cached-launch,
unread-state, About, and compact-chrome surfaces to their registered suites.

Run `python3 scripts/build90_source_check.py --source <snapshot-sha> --target
<candidate-commit-or-tree>` to compare every non-infrastructure tracked entry.
The allowlist permits only scripts, workflows, documentation, AGENTS.md, and
the release ledger to differ. This checks source preservation, not archive
provenance or product correctness. The reported public release is not a waiver
of required tests on the integrated candidate.

## Broad catch-up timeout correction

Run 36223033127 selected all 59 deterministic suites. The original four
method-count-balanced partitions assigned 14-15 suites per job; three hit the
75-minute limit. Forty-nine suites completed, while ten did not complete.
The saved raw logs also contained failed image-test attempts, so timeout is not
evidence that the remaining product checks would pass.

The revised preflight retains the same 75-minute job limit and complete suite
selection, but splits the work into twelve runtime-weighted partitions with a
six-job concurrency cap. Queue time and total suite work still exist. This is
not a blanket timeout extension or permission to skip unfinished regressions.
Focused reproduction of the image and deep-history checks remains separate
from this scheduling correction.

## Development speed and exact-tree UI evidence

Local `dev-check` runs generation/static validation first, then overlaps the
independent simulator build and host package suites. Both exit statuses and
logs are retained under an invocation-owned evidence directory; a failed
phase still fails the check. Local lane simulators are repository-namespaced
and simulator management is locked, so concurrent worktrees and concurrent
`ensure` calls do not select or create the same device. Direct C1/Makefile
runs opt in with `HERMES_FLEET_LANE_SIM=1`; explicit destinations still win.

Navigation test helpers wait for any valid tab bar, drawer, or adaptive
control within a bounded budget. A ready alternate shell no longer waits for
an absent control. Root-destination helpers still verify the destination,
recover retained pushed stacks, and preserve drawer-dismissal assertions.
Shared navigation helper changes select the complete deterministic inventory.

Every UI class is checked against its exact source method inventory. Missing
or extra cases, unexpected skips, and incomplete results fail. The existing
explicit iPhone exception for the iPad landscape test remains visible.
Partitions use the 60 observed suite runtimes from successful run
[37081588038](https://github.com/AIowa-LLC/hermes-fleet/actions/runs/37081588038),
recorded in `ci-runtime-baseline.json`. Weights guide balancing and must be
re-profiled after harness changes; they are not completion-time guarantees.

Test invocations fail after 600 seconds without XCTest case/suite or XCUI
step progress. App startup noise does not reset the watchdog. The owned
process group is stopped, and its original log, partial result bundle, and
watchdog report are retained. An interrupted invocation is not a pass and is
not automatically retried. Slow tests with real progress keep running.
`HERMES_FLEET_UI_PROGRESS_TIMEOUT_SECONDS` accepts a finite positive override;
the hosted default remains 600 seconds.

Each of the twelve required UI jobs either executes its selected suites or
validates trusted source evidence. Static guards, package suites, hosted
units, and the five critical merge journeys always execute fresh under the
existing event policy. Required CI Gate identity and the protected merge
queue are unchanged; a skipped UI job cannot substitute for a successful one.

Reuse is allowed only for a single-PR main merge candidate with an identical
checkout tree and base, a clean checkout, and unchanged validation code.
Workflow, runner/selector/parser scripts, app/UI/package tests changing in the
PR disable reuse. The source must be a completed, successful, same-repository
PR CI run on the current PR head, at its first attempt, created within 24 hours,
with the actual GitHub Actions CI Gate and all twelve successful UI jobs.
Forks and posted checks from other apps cannot provide evidence.

The candidate verifies all twelve source receipts, the source checkout's
remote tree and ancestry, the artifact ownership and GitHub-provided SHA-256
archive digest, exact suite/case selection and outcomes, pinned dependency
locks, build policy, Xcode/Swift/SDK, macOS/runner image, simulator model and
runtime. Candidate dependency resolution is compared with the actual
transitive revisions used by the source build, including ignored generated
lockfiles. Empty partitions record no test execution or compiler evidence;
all selected partitions must carry matching environment fingerprints. The
sole reviewed orientation skip is explicit. Recovered retries
are retained in fresh results but do not qualify for reuse. Missing, expired,
malformed, tampered, failed, skipped, retried or mismatched proof executes
fresh UI automatically. Evidence validation remains a real successful job.

The receipt collector/verifier has executable failure-injection contracts
alongside the lane simulator, parallel-phase, watchdog, selector, partition,
and xcresult contracts. Rollout additionally requires an actual source-to-
queue pair proving successful reuse and fresh execution after validation
changes. A local timing experiment or mocked receipt alone is not rollout
qualification.
