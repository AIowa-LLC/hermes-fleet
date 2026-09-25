# Local development loop (Dev Loop v3)

Dev Loop v3 keeps high-signal, bounded checks on the merge path and retains
the complete deterministic UI inventory in a separate deep-validation lane.
Merge confidence and release confidence are related evidence, but they answer
different questions.

## Fast local loop

1. Iterate on a feature branch and run the local check:

   ```bash
   make dev-check
   ```

   This runs static guards, a simulator build, package tests, and focused UI
   suites selected from the working diff. It never runs the complete UI
   matrix.

   Useful flags:

   ```bash
   bash scripts/dev_check.sh --base main   # diff against an explicit ref
   bash scripts/dev_check.sh --skip-ui     # static + build + packages only
   ```

   The broad local gate remains available: `make ci` runs the full C1
   validation serially.

2. Optional physical-device dogfood uses the existing deployment scripts:

   ```bash
   bash scripts/u4_device.sh
   ```

   Device deployment is environmental validation; see the script's usage for
   its current flags and environment inputs.

3. Push and open a pull request. Hosted CI runs the required pull-request
   checks below.

4. After the pull request is green and current with `main`, the merge queue
   validates the exact candidate with the same high-signal checks plus the
   critical UI smoke set.

## Required merge checks

| Event | Static/privacy/security | Packages | Hosted units | Changed-area UI | Critical UI smoke | Full matrix | Required gate |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `pull_request` | yes | yes | yes | yes | skipped | separate lane | `CI Gate`, fail-closed |
| `merge_group` | yes | yes | yes | yes | 4 core methods, plus deep-history room opening when present in the candidate | separate lane | `CI Gate`, fail-closed |
| `push` to `main` | yes | yes | yes | skipped | skipped | separate lane | `CI Gate`, informational |
| manual or nightly deep run | not part of this workflow | not part of this workflow | not part of this workflow | not part of this workflow | not part of this workflow | all 59 suites, five shards | `Full UI Regression Gate`, informational |

The static phase includes XcodeGen drift, module boundaries, privacy and
required-reason audits, public safety, and gitleaks. Package checks retain
their exact-count guards, and the complete hosted unit suite remains required.

### Changed-area UI preflight

`scripts/c1_ui_preflight.sh` selects deterministic suites from the changed
files against the pull request or merge-group base:

- UI test class files map to their own suite when the class is in the
  deterministic inventory;
- product areas map to their focused suites through the ordered rules in the
  script;
- ambiguous or broad product changes fall back to a bounded core set;
- docs and tooling changes can select no UI suites, while the preflight job
  still succeeds as a required dependency.

The selector is self-tested by `scripts/c1_ui_preflight_test.sh`, and every
suite it selects is validated against `scripts/c1_ui_matrix.sh`. This is
focused coverage for the changed area, not a replacement for deep regression
validation.

### Critical merge smoke

Every merge-group candidate runs four exact core test methods:

- `F3Onboarding/testFreshInstallLandsOnOnboardingAsRootSurface`: fresh-install
  launch and the onboarding root;
- `U3TabNavigation/testBotsTabOpensFleetRoster`: root navigation into the Bots
  roster;
- `HermesFleetHappyPath/testHappyPathGatewaysToConversationStreamedAnswer`:
  gateway navigation, message send, and streamed reply;
- `RoomChat/testHostedRoomOpenSendAndTranscriptRender`: hosted group-room open
  and basic send.

When the candidate includes the Build 87 deep-history test, the smoke also
runs `FOS8Accessibility/testGroupConversationOpensAtLatestWithDeepHistory`.
That method guards group-room opening at the latest transcript entry and
keeps the known Build 87 defect from passing the v3 merge gate.

Method-level selectors keep unrelated, flaky cases in those suites out of the
merge lock while preserving the full suite inventory in deep regression. The
selection is checked against the canonical suite inventory and the exact test
method names. Historical full-suite timings put the three original smoke
suites at about 30 minutes combined; the selected methods and optional fifth
method should take less, but their combined hosted duration has not yet been
measured. The smoke job has a 45-minute ceiling. Changed-area preflight and
the full regression lane provide the additional area-specific coverage.

### Full UI regression and release confidence

The complete Build 87 deterministic inventory of 59 suites remains intact in
`scripts/c1_ui_matrix.sh` and runs across five non-cancelling macOS shards from
`.github/workflows/ui-regression.yml`. It runs nightly and can be started
manually against a selected ref, including an exact release-candidate ref.
The runtime-weighted shard estimates peak near 105 minutes; each shard has a
150-minute timeout for setup, retries, and hosted-runner variance. Each shard
uploads xcresult bundles and xcodebuild logs after success or failure. `Full
UI Regression Gate` reports the aggregate result, but it is not a required
branch-protection check.

A full-matrix failure still needs investigation using its test results and
artifacts. A confirmed product defect blocks release. A test-harness or runner
failure should be classified and repaired or rerun in its own lane; it should
not cause a product change unless there is evidence of a real application
defect.

Release confidence follows the exact source SHA through local validation,
archive, Internal TestFlight, physical-device verification, and public
promotion. CI supports that chain; a passing simulator run does not replace
verification of the delivered TestFlight binary.

## Adding a UI suite

1. Add the class to `HermesFleetAppUITests`.
2. Classify it in `scripts/c1_ui_matrix.sh` (`UI_CLASSES` for deterministic CI
   suites; `ENVIRONMENTAL_CLASSES` for live-gateway/local-only suites). The
   inventory audit fails until every class is classified exactly once.
3. If it has a natural source-area trigger, add an ordered rule to
   `scripts/c1_ui_preflight.sh`; otherwise the bounded core fallback covers
   it.
4. Add a test method to `scripts/c1_critical_smoke.sh` only when failure means
   the application should not merge, and update its topology contract guard.

## Safety properties

- `CI Gate` fails closed: every check expected for the event must succeed, and
  event-specific jobs must be skipped only where the contract says they are
  inapplicable.
- The required CI workflow is not path-filtered, so its check cannot vanish
  for docs-only or otherwise unmatched changes.
- Merge-group checks are never cancelled by a later CI event.
- The full matrix remains five-way, complete, and available in a separate
  scheduled/manual lane; it is not a dependency of `CI Gate`.
- `scripts/ci_gate_policy_check.sh` and
  `scripts/ci_gate_policy_contract_test.sh` guard the workflow topology and
  event-specific fail-closed behavior.
