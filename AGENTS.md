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
