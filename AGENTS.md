# Agent and contributor working conventions

This file defines repository-wide working conventions for automated coding agents and human contributors.

## Project facts

- `project.yml` is the source of truth for the Xcode project.
- `HermesFleetApp.xcodeproj` is generated output and should not be hand-edited.
- The deployment target is iOS 26.0 and the project uses Swift 6 language mode.
- Local Swift packages live under `Packages/`.
- `HermesFleetApp` is the composition root.

## Module boundary

The dependency direction is intentionally one-way:

```text
FleetCore
  ↑
  ├─ FleetNetworking
  ├─ FleetSecurity
  ├─ FleetPersistence
  └─ FleetUI

HermesFleetApp depends on all modules.
```

`FleetUI` must never import `FleetNetworking`. UI code depends on abstractions defined in `FleetCore`; concrete networking is wired by the app target.

## Working rules

1. **Verify source before changing behavior.** Protocol and gateway claims should be grounded in current code or wire evidence, not old milestone notes.
2. **Keep changes focused.** Avoid unrelated refactors in bug fixes and documentation updates.
3. **Preserve security boundaries.** Never add credentials, private endpoints, personal hostnames, device identifiers, signing identifiers, or local filesystem paths to public fixtures, logs, docs, screenshots, or commits.
4. **Use synthetic fixtures.** Tests should be deterministic and should not require a maintainer's live gateway, account, or device.
5. **Keep generated project state deterministic.** After editing `project.yml`, run `xcodegen generate` and verify the generated project diff.
6. **Treat visual assets as implementation assets, not permanent brand specifications.** Visual direction can change independently of architecture and protocol behavior.
7. **Do not weaken validation to make a change pass.** Classify environmental failures separately from product failures.

## Standard validation

Run the smallest relevant tests while iterating, then the broader gate appropriate to the change:

```sh
make dev-check        # fast local loop: static + build + packages + focused UI subset
xcodegen generate
make test-core
make test
bash scripts/public_safety_guard.sh
gitleaks detect --source . --no-git
```

For changes covered by the full CI matrix:

```sh
bash scripts/c1_ci_validate.sh
```

Dev Loop v2 — the focused pull-request preflight and the merge-queue integration gate — is documented in `docs/dev-loop.md`.

Live gateway, physical-device, signing, and deployment checks are environmental validation and should remain optional unless a change specifically requires them.

## Documentation

Current public documentation starts at `docs/README.md`. Historical milestone files are retained only as stable references and must not be treated as current product or release status.

---

## DOGFOOD LANE GROUND TRUTH (build-41 worktree — read before ANY change)

**This worktree carries ~95 unpushed commits of shipped work. The wrong-tree mistake is THE regression vector.**

| Tree | Path | State | Role |
|---|---|---|---|
| **LANE (the work)** | `~/code/hermes-fleet/.worktrees/build-41` | `dogfood/build-41-integration`, ~95 commits ahead of `origin/main`, **nothing pushed** | ALL shipped dogfood work (ADR-0011/0012, r2–r7). Build 80 (0.2.0) submitted to external TestFlight from here. |
| MAIN | `~/code/hermes-fleet` | `main` @ `f081da3`, synced with origin | Landing target only — do NOT build dogfood features there. |

- **Orient before writing**: `git branch --show-current` must say `dogfood/build-41-integration`; HEAD must sit at or after tag **`fleet-dogfood-baseline-61`** (`18debb9`). If you see `main`/`f081da3`, you are in the wrong tree — `cd` to the lane path.
- **Never push, never PR, never touch origin** from this lane without Tony's word-for-word instruction. ~95 unpushed commits is the normal state.
- **Commit discipline**: explicit paths only (no `-A`), author Tony Simons <tony@aiowa.dev>, message via `git commit -F /tmp/msg.txt`, `~/.local/bin/gitleaks protect --staged` before committing. `xcodegen generate` (binary `~/.local/bin/xcodegen`) after any file add/remove — pbxproj diff belongs in the same commit. A new `*UITests.swift` class needs its `scripts/c1_ui_matrix.sh` `UI_CLASSES` row in the same change.
- **UI-test hygiene**: every persisted store (pins, read watermarks, launch cache) resets under `HERMES_FLEET_NAV_RESET=1` BEFORE first hydration; UI-rendered state reads `@Observable` environment properties, never raw UserDefaults.
- **Verified SwiftUI traps on this codebase**: Form `Button` with `HStack{Label;Spacer;Image}` label never fires (use `Button{}label:{Label}` + `.plain`); toolbar ink goes INSIDE the label (`Image.foregroundStyle`), root `.tint` wins otherwise; SF Symbol names must exist in the host `symbol_order.plist` (bad names render silent blanks that pass AX tests); flat (unfilled) rows need a background-host for long-press context menus (text-selection steals glyph presses).
- **Testing gates**: fresh dedicated sim per task (`xcrun simctl create QA<name> "iPhone 18 Pro"`, own `-derivedDataPath`, delete after; never share a sim across xcodebuilds); full unit scheme `HermesFleetAppUnitTests` with `-skipMacroValidation`; `-only-testing:` needs the full class name incl. `UITests` suffix; the verdict is the `Executed N tests` line, never TEST SUCCEEDED alone.
- **Gateway context**: `last_active` now projects on `session.list` across all fleet machines (upstream PR NousResearch/hermes-agent#116548, local patch ahead of merge) — do not "fix" missing `last_active` client-side.

