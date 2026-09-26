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
suites over four jobs. All four must succeed; failure or cancellation cannot be
converted into a successful aggregate.

The former 12-suite cap and fallback to two CORE journeys are removed. Every
selected suite is assigned exactly once. `c1_ui_partition.py` balances by source
test-method count, a deterministic heuristic, not a claim of measured duration.

Shared FleetCore, networking, persistence, security, dependency manifests/lock
files, and composition-root changes select the complete deterministic inventory.
Feature-specific UI changes retain their mapped suites. Unmapped product files
retain CORE journeys and require review of whether a more specific mapping is
needed. New deterministic suites must be registered in the canonical inventory.
A broad reconciliation PR can therefore still be expensive; routine changes no
longer inherit the entire suite automatically.

```sh
bash scripts/c1_ui_preflight.sh --base origin/main --print
bash scripts/c1_ui_preflight.sh --base origin/main --shard 1 --shards 4 --print
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

## Local tests of CI plumbing

These tests do not start a simulator and are not product acceptance evidence:

```sh
bash scripts/ci_gate_policy_check.sh
bash scripts/ci_gate_policy_contract_test.sh
bash scripts/c1_ui_preflight_test.sh
python3 scripts/c1_ui_runner_contract_test.py
python3 scripts/c1_xcresult_parse_test.py
bash scripts/c1_packages_contract_test.sh
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
Package baselines follow the unchanged source: 619 core, 545 networking,
39 persistence, and 37 security tests. Focused selection maps the newer Kanban,
artifacts, image generation, cron, reasoning, slash-parity, cached-launch,
unread-state, About, and compact-chrome surfaces to their registered suites.

Run `python3 scripts/build90_source_check.py --source <snapshot-sha> --target
<candidate-commit-or-tree>` to compare every non-infrastructure tracked entry.
The allowlist permits only scripts, workflows, documentation, AGENTS.md, and
the release ledger to differ. This checks source preservation, not archive
provenance or product correctness. The reported public release is not a waiver
of required tests on the integrated candidate.
