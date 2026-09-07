# AGENTS.md — working conventions for agents (Codex, Hermes kanban workers, humans)

Hermes Fleet for iOS — native iPhone control plane for Hermes Agent.
Owner: Tony Simons
GitHub: `tony-simons-aiowa`
Organization: `AIowa-LLC`
Repo is private.

## Repo facts (verify before assuming — these drift)

- **Path:** the repository root (the dev workstation)
- **Project:** `HermesFleetApp.xcodeproj`, scheme `HermesFleetApp` — **generated
  from `project.yml` via xcodegen**. `project.yml` is the single source of
  truth: never hand-edit `project.pbxproj`. After changing `project.yml`, run
  `xcodegen generate` (binary: `xcodegen`).
  `DEVELOPMENT_TEAM: 3JS22HX92T` must stay in BOTH `project.yml` and the
  pbxproj — a regen without it in `project.yml` silently wipes signing.
- **Toolchain:** Xcode 26.x, Swift 6 language mode, iOS deployment target 26.0
  (`IPHONEOS_DEPLOYMENT_TARGET`), local Packages under `Packages/`.
- **Modules (dependency direction):** FleetCore ← FleetUI / FleetNetworking /
  FleetPersistence / FleetSecurity ← HermesFleetApp. Schemes exist per package
  (`FleetCore`, `FleetNetworking`, …) plus `HermesFleetApp` and
  `HermesFleetAppUnitTests`.
- **CI:** `.github/workflows/ci.yml`, paths-filtered (runs only when
  `Packages/**`, app/test sources, `project.yml`, `Makefile`, or `scripts/**`
  change — docs-only edits skip it to save free macOS runner minutes).

## Working rules

1. **Evidence over claims.** Read the artifact, not the commit message. QA
   verdicts are `PASS` / `PASS_WITH_KNOWN_LIMITATIONS` / `FAIL` / `BLOCKED`
   and must be bound to a specific commit SHA; a new HEAD earns a fresh run.
2. **Commit discipline.** Small, titled commits referencing the card ID
   (`t_xxxx` / `R10-Tn`). Current HEAD baseline: all R10 wave cards (T1–T5)
   done; R10-T6 (round evidence + build 19 + TestFlight upload) is parked.
3. **Builds for the device:** background long xcodebuild runs (Release device
   builds exceed foreground timeouts). Use a per-phase
   `-derivedDataPath build/<tag>` so artifacts never collide.
4. **`build/` is disposable cache + evidence.** DerivedData dirs get bulk-
   deleted; NEVER delete `*evidence*` dirs, `*.xcresult` bundles, or
   `Design/` outputs without explicit owner sign-off — round evidence backs
   QA verdicts and the TestFlight card.
5. **Icon/design assets:** `Design/` holds the wing-icon work
   (`icon-wing-v3-white` is the current direction). Icons must be opaque
   1024² (no alpha); `Design/check_icon.sh` / `check_sprite.sh` gate assets.
6. **Free-team gotchas still apply on device work:** trust gate on first
   install; simulator-first for correctness gates, device for signing/provisioning
   and feel passes. Install proof = `App installed:` line from devicectl AND a
   bumped build number (version rows lie otherwise).

## Board / orchestration context

Work is tracked on Hermes Kanban boards (`~/.hermes/kanban/boards/`):
`hermes-fleet-ios` (main) and `hermes-fleet-r10` (current round). Named
profiles own lanes: `apple-dev` (dev), `apple-qa` (independent review, never
the author), `apple-release` (builds/TestFlight), `apple-design` (visual).
Do not self-approve; QA must differ from author. If a card is blocked on a
wave gate, the orchestrator (the dev workstation default profile) unblocks it.

## Quick commands

```bash
cd $REPO
export PATH="$HOME/bin:$HOME/homebrew/bin:$PATH"

# Regenerate project after project.yml edits
xcodegen generate

# Simulator tests (correctness gate)
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test

# Device build (Release; background it)
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -configuration Release -destination 'id=<DEVICE_UDID>' \
  -derivedDataPath build/<tag> DEVELOPMENT_TEAM=3JS22HX92T build

# Install + verify on paired iPhone (UDID via `xcrun devicectl list devices`)
xcrun devicectl device install app --device <UDID> build/<tag>/Build/Products/Release-iphoneos/HermesFleetApp.app
xcrun devicectl device info apps --device <UDID> | grep hermes
```
