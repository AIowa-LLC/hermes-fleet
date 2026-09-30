# Development workflow

Use small, protected integrations rather than accumulating several releases on a
long-lived local branch. `main` represents the latest accepted integration;
immutable release tags identify the source actually distributed to testers.
A green integration does not by itself authorize distribution.

## Branches and ownership

| Branch | Purpose |
| --- | --- |
| `main` | Protected integration baseline. Changes arrive only through PRs and the merge queue. Never force-push or directly edit it. |
| `feature/*`, `fix/*`, `ci/*`, `docs/*` | Short-lived branches from current main for one coherent change. |
| `release/*` | Optional frozen release candidate when a candidate must remain unchanged during independent work. |
| `dogfood-next` | Optional temporary integration branch for a coordinated batch, not a mandatory extra merge stage. |

Do not switch, reset, stash, clean, or rebase another worker's active checkout.
Use an isolated worktree or clone. Back up committed source branches promptly;
pushing a source branch is not the same as merging or distributing a build.

## Normal feature loop

1. Record the upstream feature contract and supported gateway behavior. See
   [upstream-compatibility.md](upstream-compatibility.md).
2. Branch from synchronized main and implement one small vertical slice with
   synthetic fixtures and a regression test.
3. Run the relevant local checks, review the diff, and open a focused PR.
4. Require Dev Loop v3 validation on the PR and exact merge candidate.
5. Produce an internal build when useful. Promote only with the appropriate
   source, archive, device, and release evidence and explicit authorization.

Every beta or production bug fix should add a practical regression test. New UI
suites must be registered and mapped deliberately. Do not turn incomplete tests
into passes, delete known regressions, or weaken security boundaries to merge.

## Validation

The required gate includes static/security/project checks, package tests, hosted
units, and coverage-preserving changed-area UI tests. Merge candidates also run
critical smoke. Broad shared-layer changes retain broader validation; the full
nightly/manual suite is not an unconditional lock on every narrow change.
See [dev-loop.md](dev-loop.md) for exact commands and limitations.

## Local cache schema versioning

The on-device SwiftData store (`FleetPersistence`) is built through
`FleetMigrationPlan`, whose current and only schema is `FleetSchemaV1`
(1.0.0). It lists exactly the models that shipped before versioning, so
existing stores open in place.

**Every `@Model` change requires a new schema version.** That covers adding,
removing or renaming a model or stored property, changing a property type, and
changing a uniqueness constraint. Checklist:

1. Freeze the current shape: move the previous models into the old
   `VersionedSchema` as nested `@Model` copies (V1 references the live
   top-level classes only while they are unchanged).
2. Add `FleetSchemaVN` with the next `versionIdentifier` and the new model list.
3. Append it to `FleetMigrationPlan.schemas` and add a `MigrationStage`
   (lightweight when the change is additive, custom otherwise).
4. Add a test that creates a store with the previous version's models, opens it
   through the plan, and asserts the rows survive.
5. Keep `CachedGatewayRow` readable: the saved-gateway registry lives in this
   store and recovery salvages it (`CacheStoreRecovery.swift`).

If the store still cannot be opened, the app quarantines the old files into
`HermesFleetCache/Quarantine/<timestamp>/` (one generation, file-protected and
backup-excluded), rebuilds an empty store, re-inserts the salvaged gateway rows,
and records a type-only `persistence` diagnostics entry. If no file-backed store
can be created it runs in memory and shows a persistent notice. The
`HermesFleetCache` directory itself is never removed or renamed. Tests simulate
failures with `CacheOpenFaultInjection`. If even the SwiftData in-memory
container cannot be built, a final SwiftData-independent store keeps new gateway
registrations and health for this process while transcript/replay caching and
Learning/Projects snapshot persistence stay disabled. Recovery still surfaces
notices and diagnostics; no cache-open failure traps the composition root.

## Release provenance and catch-up

Every TestFlight build maps to an exact commit and immutable tag recorded in
[RELEASES.md](../RELEASES.md), with build configuration, archive/IPA provenance,
and acceptance evidence. Follow the actual release tooling and authorization
requirements in [release-preflight.md](release-preflight.md); this document does
not bypass them.

Preserve an already accepted historical release source while reconciling it to
main. Do not rebuild or relabel it merely to make a squash-merge SHA match.
Record the original source and integration SHA separately. Product or build-input
changes during reconciliation require fresh validation. See
[integration-safe-main.md](integration-safe-main.md).

## Parallel agent lanes

The primary checkout stays on synchronized `main` as the operator base. Each
Codex, Hermes, or Claude worker owns an isolated worktree for one coherent
feature or fix. Start every lane from a freshly fetched `origin/main`:

```sh
git fetch origin --prune
git worktree add -b feature/example .worktrees/example origin/main
```

Record the starting SHA, scope, owned files, and dependencies in the PR or lane
handoff. Coordinate overlapping runtime/domain changes before editing them.
Independent lanes can proceed concurrently; a dependent lane refreshes from
main after its prerequisite merges. Never use a historical dogfood, recovery,
or worker branch as the default base for new work.

Worktrees isolate source and the runners' derived-data directories
(`build/DevCheck`, `build/C1Ci`, `build/C1Ui`, `build/ipad-smoke`), and local
runs also get their own iOS Simulator device. `scripts/lane_simulator.sh`
derives a short id from the worktree path (the path is never printed or
embedded in a name) and creates or reuses a simulator named `HF-<id>` (iPad:
`HF-<id>-iPad`) from an iPhone device type and the newest installed iOS
runtime. Concurrent lanes therefore install and launch Fleet on different
devices; no "one lane at a time" coordination is needed.

All runners pick their destination through `scripts/sim_destination.sh`, in
this order:

1. `HERMES_FLEET_SIM_UDID=<udid>`: explicit device, overrides everything. The
   iPad smoke uses `HERMES_FLEET_IPAD_SIM_UDID` (or the existing
   `HERMES_FLEET_IPAD_DESTINATION` name) instead, because an iPhone UDID is the
   wrong device family.
2. `HERMES_FLEET_LANE_SIM=1`: this worktree's `HF-<id>` simulator. `make
   dev-check` (and so `scripts/dev_check.sh`) turns this on by default for
   local runs; `CI=true` turns it off. `HERMES_FLEET_LANE_SIM=0` opts out.
3. Otherwise the original behavior: the first available iPhone (iPad smoke: a
   named iPad Pro). Hosted CI, and the C1 runners when invoked directly, keep
   this selection unchanged; set `HERMES_FLEET_LANE_SIM=1` to use the lane
   simulator with `make ci`, `make test`/`make build`, `c1_units.sh`,
   `c1_ui_matrix.sh`, `c1_critical_smoke.sh` or `c1_ipad_smoke.sh`.

The chosen simulator selection and UDID are recorded in the hosted-unit
`metadata.txt` and the UI matrix `provenance.log` (no hostnames or paths). If a
lane simulator cannot be prepared the run fails instead of silently falling
back to the shared device.

Manage lane simulators explicitly; nothing deletes them automatically:

```sh
bash scripts/lane_simulator.sh ensure [ipad] [--boot]  # create/reuse, print UDID
bash scripts/lane_simulator.sh list                     # HF-* devices and owner status
bash scripts/lane_simulator.sh shutdown                 # this worktree's devices
bash scripts/lane_simulator.sh delete                   # this worktree's devices
bash scripts/lane_simulator.sh gc [--dry-run]           # HF-* devices whose worktree is gone
```

`shutdown` and `delete` touch only this worktree's `HF-<id>` devices. `gc`
removes only devices named exactly `HF-<8 hex>[-iPad]` whose id matches no
existing worktree of this repository, so run it from any worktree after
removing old lanes; use `--dry-run` first on hosts that also run other
projects' `HF-*` devices. Delete the lane simulator (`delete`) when removing a
worktree. Static and package-only checks never need a simulator.

One CI/release integrator coordinates shared integration surfaces per batch:

| Surface | Integration responsibility |
| --- | --- |
| `scripts/c1_packages.sh` and its contract tests | Reconcile exact package counts with the combined test inventory; preserve failure evidence and real exit status. |
| `scripts/c1_ui_matrix.sh`, `c1_ui_preflight.sh`, `c1_ui_partition.py`, critical smoke and their contracts | Register every new suite, deterministic/environmental classification, selection mapping, and runtime weight without dropping coverage. |
| `project.yml` and generated Xcode project | Combine target/resources/dependency edits, generate once from the final inputs, and review drift. Never hand-edit generated output. |
| `.github/workflows/` and CI gate policy | Preserve required check identity, event topology, merge-candidate coverage, concurrency, and diagnostics. |
| Version/build settings, `RELEASES.md`, release baseline pin and release tooling | Coordinate the exact release source and approved build number; preserve historical provenance and immutable tags. |

Feature workers describe required integration edits alongside their code and
can propose them in their PR. The integrator reconciles concurrent proposals
against current main before queueing; this is coordination, not a mandatory
extra branch or serial feature-development stage. Review the resulting suite
selection and exact counts rather than restoring numbers from an older lane.

Run the smallest relevant local tests while iterating, then the gate warranted
by the changed area. CI confirms a candidate believed correct locally. Use the
normal PR and protected merge queue; refresh after each dependent merge.
Retain logs for failures and recovered retries. Rerun the same candidate only
when evidence supports an infrastructure failure; fix deterministic defects
at their source. See [dev-loop.md](dev-loop.md).

Before removing an old lane, account for both committed and uncommitted work,
stashes, ignored evidence, and release/recovery history. Preserve useful work
on main or retain a named recovery snapshot with a reason. A branch ahead of
main after a squash merge is not by itself evidence of unmerged product work.
Release-only privacy, signing, device, gateway, and App Store Connect evidence
is tracked separately from ordinary feature-development readiness.
