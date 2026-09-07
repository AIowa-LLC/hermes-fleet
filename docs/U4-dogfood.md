# U4 Dogfood re-run — §32 walkthrough steps 1-10 PASS

**Task:** t_cbc5dbca · **Owner:** apple-release (independent review: apple-qa)
**Board:** hermes-fleet-ios · **Date:** 2026-08-30 (CDT) · **Status:** Evidence recorded, handed to review.

## 1. Scope executed (per card body + sequencer note)

- Re-run the full §32 DoD dogfood (M15 method, docs/M15-device-dogfood.md as
  template): own-device free-team sideload + simulator, all 10 walkthrough
  steps executable and PASS (incl. steps 2-10 that M15 HOLD'd).
- Independently re-verify U3 conversation claims as part of the walkthrough:
  streaming render, forced-disconnect mid-stream + reconnect replay dedupe,
  4401 re-auth UX, cold-start cache hydration.
- G1 debt: XCUITest target with core happy-path UI test (+ multi-gateway switch
  and reconnect lifecycle tests).
- Distribution-readiness: re-stated honestly (free team / 7-day rotation) — no
  paid-tier claims fabricated.
- Acceptance: fresh device + simulator evidence, updated docs/U4-dogfood.md,
  explicit PASS/HOLD.
- TOOLING: script files + `bash <script>` only (as mandated).

## 2. Baseline (git)

| Item | Value |
|---|---|
| main HEAD | `33e2095` (U3 FINAL PASS, clean tree at start) |
| branch | `main` |
| xcodegen | 2.46.0 |
| Xcode | 26.6 (17F113) |
| Swift | 6.3.3 |
| pbxproj after xcodegen | deterministic; now includes `HermesFleetAppUITests` target (G1) |

## 3. Independent re-verification of U3 conversation claims (scripts/u4_verify.sh)

All executed at main@33e2095. **PASS=13 FAIL=0.**

| Suite | Result |
|---|---|
| Module boundary: 0 `import FleetNetworking` in FleetUI | PASS (M0 guard preserved) |
| FleetCore (swift test) | 123 tests, 0 failures |
| FleetNetworking (swift test) | 157 tests, 0 failures |
| FleetSecurity (swift test) | 20 tests, 0 failures |
| FleetPersistence (swift test) | 15 tests, 0 failures |
| xcodebuild test (iOS Simulator, iPhone 17 Pro) | Test Suite 'All tests' passed |
| ConversationFixtureLoopTests | passed |
| ConversationViewModelTests | passed |
| ModuleBoundaryTests | passed |

### Claim → test mapping (the four U3 claims the sequencer flagged)

| U3 claim | Green test (re-verified) |
|---|---|
| Streaming render (start → deltas → complete) | `testSendStreamsDeltasIncrementallyAndCompletes` passed |
| Forced-disconnect mid-stream + reconnect replay dedupe | `testFullLoopForcedDisconnectReconnectReplayDedupe` passed |
| Replay dedupe visible in transcript (view-model level) | `testReplayDedupeVisibleInTranscript` passed |
| 4401 re-auth UX, no silent retry (M11) | `test4401SurfacesAuthRequiredNoSilentRetry` passed |
| Cold-start cache hydration (M10) | `testColdStartHydratesFromCache` passed |

The fixture-loop suite runs on the iOS Simulator against the shared
in-process WebSocket gateway (real transport, forced socket abort mid-stream,
reconnect via `session.events.since`, seq-gated replay, single assistant row
asserted — no duplicated prefix). This is the authoritative proof that
reconnect does not corrupt or duplicate the transcript.

## 4. G1 debt — XCUITest target (scripts/u4_xcuitest.sh)

Added `HermesFleetAppUITests` (bundle.ui-testing) to project.yml, wired into
the scheme's test action, with three tests driving the DEBUG scripted fleet:

| Test | §32 steps | Result |
|---|---|---|
| `testHappyPathGatewaysToConversationStreamedAnswer` | 1-7 | **passed** (17.0s) |
| `testReturnToFleetSwitchMachine` | 10 (multi-gateway) | **passed** (23.6s) |
| `testGatewayDisconnectThenReconnectLifecycle` | 8-9 (gateway lifecycle) | **passed** (16.8s) |

Evidence in `build/DerivedDataU4UITests/Logs/Test/*.xcresult` (includes a
conversation-canvas screenshot attachment of the streamed answer).

Two DEBUG-only fixes were required to make the UI tests honest (both are
simulator/scripted-fleet concerns; Release wires the live transport):

- **ConversationView accessibility:** the root view's
  `.accessibilityIdentifier("fleet.conversation")` was overriding the
  composer / send / stop leaf identifiers, so the UI tree exposed every
  control as "fleet.conversation". Removed the root-level override; leaf
  identifiers now surface correctly.
- **Scripted fleet echo bug:** `FleetSimulator.swift`'s scripted
  `message.complete` used a double-escaped `\\(text)` so the final assistant
  bubble printed a literal `\(text)` instead of echoing the sent task (would
  have made §32 step 7 non-verifiable in the UI). Fixed to a real
  interpolation. Verified via the UI test asserting the echoed text.

## 5. §32 DoD dogfood walkthrough — simulator (scripts/u4_sim_walkthrough.sh)

Fresh install (uninstall → install) on the booted iPhone 17 Pro simulator
(iOS 26.5), Debug build with the scripted fleet. **PASS=10 FAIL=0.**

| Step | Requirement | Evidence |
|---|---|---|
| 1 | open the app | ✅ launched (PID), `build/u4-sim-step1-open.png` |
| 2 | see which Hermes machines/Bots are available | ✅ `build/u4-sim-step2-gateways.png` (Workstation / Render Box / Lab Node) |
| 3 | select a Bot on a specific machine | ✅ `build/u4-sim-step3-roster.png` (union roster, bots per gateway) |
| 4 | open or create a conversation | ✅ `build/u4-sim-step4-bot-detail.png` (Bot detail → Sessions → conversation) |
| 5 | send a task | ✅ XCUITest happy path (composer → send) |
| 6 | watch Hermes work | ✅ XCUITest happy path (streaming render, deltas) |
| 7 | receive the streamed answer | ✅ XCUITest happy path (echoed answer rendered); `build/u4-xcresult/*.png` shows user bubble "hello dogfood" + assistant bubble "Hello from the scripted fleet. You said: hello dogfood" + "complete" status |
| 8 | briefly lose connectivity | ✅ gateway lifecycle: Disconnect → Disconnected (UI test) + fixture-loop mid-stream abort |
| 9 | reconnect without corrupting/duplicating | ✅ Reconnect → healthy (UI test) + fixture-loop replay dedupe (single row) |
| 10 | return to Fleet, switch machine | ✅ `build/u4-sim-step10-switch.png` + `testReturnToFleetSwitchMachine` (Render Box) |

Screenshots: `build/u4-sim-step1-open.png` … `build/u4-sim-step10-switch.png`;
conversation canvas: `build/u4-xcresult/<attachment>.png` (exported from the
XCUITest xcresult, `manifest.json` alongside).

## 6. Own-device free-team sideload — a paired iPhone (scripts/u4_device.sh)

Fresh install (uninstall → install) on the developer's iPhone
(a paired iPhone (UDID redacted — device selection is parameterized via `HERMES_FLEET_DEVICE_ID`)).

| Item | Result |
|---|---|
| Build Debug-iphoneos (free personal team, automatic) | **BUILD SUCCEEDED** |
| Codesign identity (by reference, no key material) | a personal Apple Development identity (redacted), TeamIdentifier (redacted), Identifier `the app bundle identifier` |
| Entitlements | `application-identifier` (team-qualified, redacted), `get-task-allow=true`, `com.apple.developer.team-identifier` (redacted) |
| Embedded provisioning profile | present (free-team development) |
| Fresh install (uninstall → install) | succeeded |
| **Launch** | **BLOCKED — device physically locked** (see §7) |

Checksums (recorded locally, no secrets):
- device binary sha256: `5fec14237abbab2da7767c107d875530dc75849c88fab42aae16d8cccde3e532`
- device .app content sha256 (recursive sorted): `82e14b994a9fc25b72f8956655afc6118ec1f3bbb76a2a1f50b86cac0b4738de`

## 7. Device launch — hardware dependency, not an artifact defect

`devicectl device process launch` failed with
`Unable to launch ... because the device was not, or could not be, unlocked`
(`Locked` / `RequestDenied` from SBMainWorkspace), on both the initial attempt
and a retry. The phone is passcode/Face ID locked — a physical device state a
headless agent cannot clear. This is **not** a build/sign/install problem
(all three PASS, checksums recorded) and M15 previously demonstrated launch on
this same device when unlocked. Launch/process-verification is recorded as
**HOLD pending physical unlock**, not as a release blocker.

## 8. Distribution-readiness — HOLD (as expected, stated honestly)

- The personal team = Tony's **free personal team** (Apple ID
  a personal Apple ID (redacted)). No paid Apple Developer Program membership.
- Codesigning identities: 1 valid Apple Development cert
  (`(serial redacted)...`, a personal Apple Development identity); **0 Distribution
  / Developer ID certs** (one revoked Apple Development cert present and
  unused).
- No notarytool credential profile; no App Store Connect access; ~7-day
  free-team profile rotation.
- Supported distribution path today: **own-device sideload** (as executed in
  §6). TestFlight, App Store, Developer ID, and ad-hoc-for-others all remain
  **HOLD** until a paid-membership decision + certs + ASC setup.
- This is a decision boundary for Tony, not a manufactured release PASS.

## 9. Verdict

**PASS on the §32 DoD dogfood walkthrough (steps 1-10) — simulator, fresh
install, with the G1 XCUITest suite green and U3 conversation claims
independently re-verified.**

- §32 walkthrough: steps 1-10 executable and PASS on the simulator (the DEBUG
  scripted fleet stands in for a live gateway exactly as in U1-U3 evidence).
- G1 debt: XCUITest target added; core happy-path test + multi-gateway switch
  + reconnect lifecycle all pass.
- U3 claims (streaming, forced-disconnect + replay dedupe, 4401 re-auth UX,
  cold-start hydration): independently re-verified green at 33e2095.
- Own-device: build/sign/install PASS; launch blocked only by the phone being
  physically locked (HOLD pending unlock, not a defect).
- Distribution-readiness: HOLD (free team / 7-day rotation) — stated honestly,
  no paid-tier claims.

Not self-certified — handed to apple-qa for independent review per protocol.

— End of U4 evidence. No secrets, keys, or credentials recorded. —
