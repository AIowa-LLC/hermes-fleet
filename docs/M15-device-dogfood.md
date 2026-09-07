# M15 Device Dogfood (GATED) — evidence

**Task:** t_f5c549c0 · **Owner:** apple-release (independent review: apple-qa)
**Board:** hermes-fleet-ios · **Date:** 2026-08-29 (CDT) · **Status:** Evidence recorded, handed to review.

## 1. Scope executed (per card body + synthesis §32)

- Merge D1 fix branch into main **before** building (sequencer routing).
- Own-device build (free-team sideload) + simulator & device validation.
- §32 DoD dogfood walkthrough attempt.
- Distribution-readiness note (HOLD unless paid membership).
- Acceptance: spec §32 Definition of Done; explicit PASS/HOLD.

## 2. Baseline (git)

| Item | Value |
|---|---|
| main HEAD after merge | `47cacef` (D1 fix, fast-forward from `be8ba3e`) |
| branch | `main` |
| working tree | clean |
| pbxproj after `xcodegen generate` | unchanged (deterministic) |
| xcodegen | 2.46.0 |
| Xcode | 26.6 (17F113) |

## 3. Test evidence (all green)

| Suite | Result |
|---|---|
| FleetCore package (swift test) | 123 tests, 0 failures |
| FleetNetworking package (swift test) | 151 tests, 0 failures |
| FleetSecurity package (swift test) | 20 tests, 0 failures |
| FleetPersistence package (swift test) | 15 tests, 0 failures |
| xcodebuild test (iOS Simulator, iPhone 17 Pro) | Test Suite 'All tests' passed |
| D1 regression tests (d1_validate.sh, at 47cacef) | PASS (previously reviewed at 47cacef) |

Total package tests: **309, 0 failures**.

## 4. Simulator validation (iPhone 17 Pro, iOS 26.5)

- App bundle: `build/DerivedDataM15/Build/Products/Debug-iphonesimulator/HermesFleetApp.app`
- Installed via `simctl install`, launched via `simctl launch` (PID returned), process alive after launch.
- Screenshot: `docs/M15-dogfood-simulator.png` — app renders "Hermes Fleet" title, "No Gateways"
  empty state, Black/White/Signal Red theme, correct M14 identity.

## 5. Own-device build + install (free-team sideload, a paired iPhone)

- Build: `xcodebuild -sdk iphoneos -destination 'generic/platform=iOS' -allowProvisioningUpdates`
  `CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=(personal team, redacted)` — **BUILD SUCCEEDED**.
- Artifact: `build/DerivedDataM15Device/Build/Products/Debug-iphoneos/HermesFleetApp.app`
- Codesign (by reference, no key material): Authority a personal Apple Development identity (redacted),
  TeamIdentifier (redacted), Identifier `the app bundle identifier`.
- Entitlements: `application-identifier` (team-qualified, redacted),
  `get-task-allow=true` (development), `com.apple.developer.team-identifier` (redacted).
- Embedded provisioning profile: present (free-team development profile, a free personal team (ID redacted)).
- Install: `devicectl device install app` → **succeeded** on a paired iPhone
  (a paired iPhone (UDID redacted — device selection is parameterized via `HERMES_FLEET_DEVICE_ID`)).
- Launch: `devicectl device process launch the app bundle identifier` → **launched**; process
  confirmed running in `devicectl device info processes` (HermesFleetApp, PID observed).
- Installed app record: `Hermes Fleet   the app bundle identifier   0.1.0   1`.

Checksums (recorded locally, no secrets):
- device binary sha256: `e9dae3e4e7a871a79a722d07626fa53663f7726851f6fefab1922ba92ae01109`
- simulator binary sha256: `bad25f0344a035190ffd9e01eb66bce4589b24c334e9ea02601b5589955f29a2`
- device .app content sha256 (recursive, sorted): `e86cb01b74223a732c9ffd07b6e79824a7176e56167fd8a6e87a88756a2426fa`

## 6. §32 DoD dogfood walkthrough — HOLD

The 10-step §32 walkthrough was attempted on the booted simulator (same build as installed on device).
**Steps 1 is executable; steps 2–10 are NOT executable on this build.**

| Step | Requirement | On this build |
|---|---|---|
| 1 | open the app | ✅ launches and renders |
| 2 | see which Hermes machines/Bots are available | ❌ app target exposes only the dashboard shell (4 UI files: Root/Dashboard/Model/Theme); gateways injected empty; no roster UI |
| 3 | select a Bot on a specific machine | ❌ no Bot/session/conversation screens |
| 4 | open or create a conversation | ❌ not in app target |
| 5 | send a task | ❌ not in app target |
| 6 | watch Hermes work | ❌ not in app target |
| 7 | receive the streamed answer | ❌ not in app target |
| 8 | briefly lose connectivity | ❌ no live connection UI in app target |
| 9 | reconnect without corrupting/duplicating | ❌ not in app target |
| 10 | return to Fleet, switch machine | ❌ not in app target |

**Why:** M5–M11 delivered the **service-layer seams and protocols at package level** (FleetCore/
FleetNetworking: transport, replay, roster, conversation, registry, auth — all tested, 309 green),
and the gateway is reachable (127.0.0.1:8642, 100.100.200.61:8642, 127.0.0.1:9900 all open), but
the **app target's UI composition never wires those services into screens**. The installed app shows
the M14-themed "No Gateways" empty dashboard. The M15 milestone gates on §32 DoD, which requires the
conversation/multi-gateway UI that is not yet implemented in the app target.

**Verdict: HOLD on §32 DoD dogfood walkthrough** — the own-device build, signing, install, and launch
all PASS and are fully validated, but the end-to-end dogfood flow cannot be exercised until the app
target implements the conversation/bot/session/multi-gateway UI (a feature-implementation scope for
apple-dev, outside apple-release's release-preparation boundary).

This is a genuine capability gap in the current build, not a tooling or environment blocker.

## 7. Distribution-readiness note — HOLD (as expected)

- Signing used a **free personal team** (IDs redacted for the public tree).
- Codesigning identities: 1 valid Apple Development cert; **0 Distribution / Developer ID certs**.
- No notarytool credential profile; no App Store Connect access; 7-day free-team profile rotation.
- Own-device sideload (as executed here) is the supported path; TestFlight / App Store / Developer ID
  distribution remain HOLD until Tony's paid Apple Developer Program decision + certs + ASC setup.

## 8. Residual risk / observations (carried forward, not fixed — out of scope)

- The app currently can't demonstrate reconnect/replay/multi-gateway behavior end-to-end because the
  UI wiring doesn't exist yet; package-level behavior is covered by the 309-test suite.
- The free-team provisioning profile carries the standard 7-day expiry — own-device dogfood of the
  current build will require re-signing/re-install after that window.

— End of M15 evidence. No secrets, keys, or credentials recorded. —
