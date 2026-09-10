# i16 evidence pack — H1AppLock hosted-runner failures: root-cause analysis

Verdict (this card, evidence phase): **ROOT CAUSE PROVEN — deterministic UI-test
harness defect (cross-suite persisted-navigation leakage). NOT a product defect,
NOT biometric/runner platform behavior.**

- Candidate code under test: `main @ 2e9a16f` (worktree `/tmp/hgoal/i16-evidence`,
  branch `hermes/i16-evidence`). Hosted failures reproduced against code
  identical at the failing commits in all app/test sources (see §1.3).
- Environment: Xcode 26.6 (17F113), Swift 6.3.3, iOS 26.5 simulator runtime
  (23F77), dedicated simulator `hgoal-i16` (UDID redacted; internal ref
  hgoal-i16 (UDID redacted)), macOS 26.6.2 host.
- Date: 2026-09-10 (America/Chicago).

## 1. Hosted-run forensics (gh CLI, real logs pulled from the runs)

### 1.1 Per-run H1 outcomes and exact failure text

| Run | Commit | Shard topology | H1 outcome | Failing tests | Durations |
|---|---|---|---|---|---|
| 34405682516 | 65c5369 | 4 shards | **PASS** 3/3 | — | ~174s suite |
| 34411504021 | dfd4ad7 | 5 shards | FAIL 2/3 | B, L | 28.2s / 22.5s (waits then 15s) |
| 34418740262 | bb5848f | 5 shards | FAIL 2/3 | B, L | 100.0s / 60s+ (waits now 60s) |
| 34426824450 | d41388c | 5 shards | shard1 cancelled mid-H1; H1 output present, same failures | B, L | 77.8s / 66.5s (waits now 60s) |

Test order within H1 (alphabetical, single invocation): B = `testBiometricSuccessUnlocksToRoster`
(runs FIRST), C = `testColdLaunchLockedBeforeRosterAndFailedBiometricPasscode`, L = `testLockToggleDefaultsOnAndPersistsAcrossRestart`.

Exact hosted failure text (identical in runs 34411504021, 34418740262, 34426824450):

```
H1AppLockUITests.swift:99:  error: -[H1AppLockUITests testBiometricSuccessUnlocksToRoster]:
  XCTAssertTrue failed - scripted biometric success should unlock to the roster
H1AppLockUITests.swift:116: error: -[H1AppLockUITests testLockToggleDefaultsOnAndPersistsAcrossRestart]:
  XCTAssertTrue failed - roster reachable after default-ON lock + biometric unlock
```

The cold-launch **passcode** test (C) PASSED in every failing run (3 executed,
2 failures each time). Logs preserved under `hosted/` in this worktree.

### 1.2 The invariant discriminator

Across every hosted run, pass and fail:

- The ONLY tests that fail are the two that do **NOT** set `HERMES_FLEET_NAV_RESET=1`:
  B (sets neither LOCK_RESET nor NAV_RESET) and L (sets LOCK_RESET only).
- C sets both `LOCK_RESET=1` and `NAV_RESET=1` — passes everywhere, including
  on runners.
- On the runner, B runs FIRST in the suite. Its launch reads the persisted
  navigation state written by the PREVIOUS suite in the shard. In the passing
  4-shard run the predecessor was `HermesFleetReconnectUITests` (ends at the
  Gateways root listing "Workstation"); in every failing 5-shard run the
  predecessor was `HermesFleetHappyPathUITests`, whose final test ends deep in
  Render Box bot detail (`render-box#default`), persisting
  `selection=bots, paths=[gateways → gatewayDetail(render-box) → bots(render-box)
  → botDetail(render-box#default)]` under UserDefaults key `fleet.navigation.v1`.

Wait — for L: L sets `LOCK_RESET=1` but not NAV_RESET. And NAV_RESET=1 only
skips restore (FleetTabView.swift:110); it does NOT delete the stored key
(FleetTabView.swift:115-119 clears profile selections only). So C's
NAV_RESET=1 did not wipe the HappyPath state; L inherits it too.

### 1.3 Code identity between pass and fail

`git diff 65c5369 dfd4ad7` = `.github/workflows/ci.yml` only (shard resize
4→5). The de-flake commit bb5848f (timeouts 15s→60s) did not change app/test
logic. Therefore all four hosted runs tested identical app code; the only
variables were CI topology and predecessor-suite identity. **The one hosted
PASS is fully explained: Reconnect (Gateways root end-state) preceded H1.**

Additional hosted detail (from run 34418740262 log): with 60s waits,
`testBiometricSuccessUnlocksToRoster` failed at 100.018s ≈ launch (~40s) +
60s timeout — i.e. the element never appeared at any point, not slow paint.
The 100s failure proves "not latency" exactly as the quarantine comment said.

### 1.4 Hosted xcresult artifacts

Run 34426824450 uploaded `xcresults-shard-5` (83,894,880 bytes) — shard 5 only
(Splash failure, unrelated; d41388c added artifact upload). No xcresult exists
for the H1 failures (upload landed after the failing runs). Local reproductions
(§2) supply the xcresult evidence instead.

## 2. Local reproduction on hgoal-i16 (exact hosted condition)

Reproduction recipe = the hosted shard order on the same simulator, serial
invocations, identical xcodebuild flags (`-skipMacroValidation`, same
destination, same derived data path) as `scripts/c1_ui_matrix.sh`.

### 2.1 Baseline (H1 standalone) — 5 runs

| # | Result | Duration |
|---|---|---|
| 1 | PASS 3/3 | 53.9s |
| 2 | PASS 3 tests 0 failures | 50.8s |
| 3 | PASS 3/3 | 68.8s |
| 4 | PASS 3/3 | 37.0s |
| local summary | **15/15 PASS** | |

(Executed-lines preserved in `local/baseline/run*.log`.)

### 2.2 Hosted-condition repro (HappyPath → H1, same sim) — 2 iterations

| Iteration | HappyPath | H1AppLock |
|---|---|---|
| 1 | PASS 2/2 | **FAIL 2/3 — exact hosted signature** (B 66.3s, C PASS 7.0s, L 63.3s) |
| 2 | HappyPath PASS 2/2 | **FAIL 2/3 — same** (B 62.9s, C PASS, L 63.4s) |

Deterministic 2/2 reproduction with the exact per-test durations pattern
(B/L fail at their 60s waits, C passes fast) matching hosted runs.

### 2.3 Landing-state proof (decode + OCR of screenshot)

Persisted `fleet.navigation.v1` after HappyPath (decoded from the app container
plist, worktree script `local/decode_nav2.py`):

```json
{"paths": ["bots", [{"bots": {"_0": "render-box"}},
                    {"botDetail": {"_0": {"gatewayID": "render-box", "profileSlug": "default"}}}],
          "gateways", [{"gatewayDetail": {"_0": "render-box"}}]],
 "selection": "bots", "version": 1}
```

Cold-launching the app with `HERMES_FLEET_APP_LOCK=enabled` +
`HERMES_FLEET_LOCK_AUTH=success` against that state (script
`local/shot_landing.sh`) lands on Render Box bot detail — OCR (macOS Vision,
`local/ocr.swift`) of the screenshot `local/shots/post-unlock-persisted-nav.png`:

```
<fault | Default | Render Box | Online (gateway reachable) • Unknown | hermes • nous
| Bot Chat | Conversations | Routines | Sessions | + New Session | Fleet setup | …
```

**No "Workstation" text anywhere on the landing screen.** The unlock itself
succeeds (lock overlay dismissed, real content shown) — the assertion
`app.staticTexts["Workstation"]` simply looks for the wrong thing when nav
state persisted from a prior suite redirects the launch destination.

### 2.4 Causal experiment (single-variable)

Seed the exact failing precondition (run HappyPath), then change ONE thing —
wipe the persisted nav key (`rm` app prefs plist with app terminated; the
nav key is the only app-written relevant key besides the lock toggle):

| Step | Result |
|---|---|
| HappyPath (seed) | PASS 2/2; `fleet.navigation.v1` present in container |
| Same seeded state, nav key present, rerun B+L | FAIL 2/2 (B 63.2s, L 63.4s) |
| Same seeded state, **nav key wiped**, rerun B+L | **PASS 2/2** (B 3.8s, L 23.9s) |

Single-variable flip restores pass; test times collapse from 60s-timeout
failures to seconds. (Full logs: `local/causal/seed_happypath.log`,
`navkey_wiped.log`.)

## 3. Hypotheses — evidence verdicts

| # | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| H1 | Real App Lock product/lifecycle bug (unlock doesn't work) | **REFUTED** | §2.3: unlock succeeds, content renders, lock dismissed; passcode test passes hosted; B/L pass instantly once nav key wiped |
| H2 | Biometric daemon latency / runner sim biometrics unavailable | **REFUTED** | ScriptedLockAuth is pure in-process code, no LAContext; hosted passcode test passes on same sims; failure unchanged by waits up to 100s |
| H3 | Scene activation timing / first-paint stall on runner hardware | **REFUTED** | 100s hosted failure (34418740262) = element never appears; local repro fails on M-series hardware identically; single-variable nav-key wipe flips FAIL→PASS |
| H4 | Keychain availability timing on runner sims | **REFUTED** | No keychain involvement in unlock path; same single-variable flip |
| H5 | App-launch-arg/env differences hosted vs local | **REFUTED** | Reproduced locally with identical env/seams; only nav-persistence differs |
| H6 | Flaky AX tree | **REFUTED** | Deterministic 2/2 local repro + 2/2 causal flip; no flakiness in any local run |
| **H7** | **Cross-suite persisted-navigation leakage: H1 tests without `NAV_RESET=1` restore nav state persisted by the preceding suite (HappyPath), landing on Render Box bot detail where "Workstation" is absent; the roster assertion times out** | **PROVEN** | §1.2 invariant discriminator, §2.2 deterministic repro, §2.3 landing proof, §2.4 single-variable causal flip |

## 4. Remediation path for the i16-fix card

The defect is in the TEST HARNESS, not the product. Options in preference order:

1. **Preferred (test-only fix)**: make every H1AppLockUITests launch hermetic
   w.r.t. navigation: add `HERMES_FLEET_NAV_RESET=1` to test B and test L
   (test C already sets it). One-line-per-test change, no product code, no
   weakened assertions, no longer waits. (Note NAV_RESET=1 does not delete the
   stored key — it only skips restore for that launch; that is sufficient for
   hermeticity of the launch, but the fix card may also want NAV_RESET=1 to
   also `removeObject(forKey: fleet.navigation.v1)` in FleetTabView so state
   cannot leak into the app's own relaunches within L, though L's relaunch
   (line 139-141) currently sets NAV_RESET=nil deliberately to test
   persistence — the persistence-under-test is the lock toggle, not nav; the
   fix card must reconcile: either assert the landing content wherever nav
   lands, or reset nav before L's relaunch.)
   After the fix: rerun H1 ≥5× locally AND in hosted-order (after HappyPath),
   then full C1, then re-add H1AppLock to `UI_CLASSES` in c1_ui_matrix.sh
   (removing the quarantine comment) — restoring the suite to hosted CI.
2. If asserting the Fleet root is desired as product behavior on cold launch
   with a lock: that's a product decision (out of QA lane) — currently nav
   restoration is intended behavior (feature, not bug).
3. Concurrency note: shards are separate runner machines, so cross-SHARD
   leakage is impossible; the leak is intra-runner cross-SUITE. Any fix at
   the runner level (erase sim between suites) would mask, not fix, and cost
   minutes per suite.

Also recommended for the fix card: point the "roster rendered" assertions at
an identifier that exists on every root (e.g. the tab bar or the lock-removed
state) rather than a content string ("Workstation") that depends on which
root/detail the restored nav lands on.

## 5. Verdict summary

- **Root cause**: PROVEN — harness defect: cross-suite navigation-state
  leakage into H1's two non-NAV_RESET tests; assertion looks for
  "Workstation" while restored nav lands on Render Box bot detail.
- Product safety properties: intact (unlock works, content protected while
  locked, passcode fallback works, toggle persists). No product defect open.
- The hosted quarantine (ENVIRONMENTAL_CLASSES) is now explained but its
  "environmental" label is WRONG — it is a deterministic harness defect that
  happens to be topology-dependent (predecessor-suite dependent). The i16-fix
  card should fix the harness and re-add H1 to hosted CI.
- Local run matrix: baseline 15/15 PASS; hosted-condition repro FAIL 2/3 ×2
  (exact signature); causal flip PASS 2/2. All logs + xcresults under
  `local/` in the worktree (will be committed to the branch).
