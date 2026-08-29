# Hermes Fleet for iOS

Native Hermes fleet control plane for iPhone. The phone is the control plane;
Hermes machines are the agent/compute plane.

**Status:** M0 Foundation (module boundaries + skeleton). No live Hermes
connection, no JSON-RPC, no auth, no persistence yet — see the hard scope guard
in `docs/M0-foundation.md`.

## Repository / workspace

- **Path:** `<repo-root>` (<dev-workstation>)
- **Project:** generated from `project.yml` via xcodegen (single source of
  truth — never hand-edit the `.pbxproj`)
- **Toolchain:** Xcode 26.6 (Build 17F113), Swift 6.3.3, iOS 17+ deployment,
  Swift 6 language mode, iOS 26.5 simulator runtime

## Module layout (dependency direction)

```
FleetCore          pure domain: GatewayID, ProfileSlug, AuthorizationClass,
                   FleetGateway, HermesTransport seam (NO platform/UI code)
   ▲
   ├──── FleetNetworking   (JSON-RPC/WebSocket transport — M0 boundary only)
   ├──── FleetSecurity     (Keychain credential store + auth classifier — boundary only)
   ├──── FleetPersistence  (SwiftData non-secret cache — boundary only)
   └──── FleetUI           (SwiftUI: dashboard model, root shell, empty state)

HermesFleetApp     app target = composition root; depends on ALL modules;
                   wires seams into the UI. The ONLY module that imports
                   FleetNetworking.
```

One-directional, acyclic. **SwiftUI (`FleetUI`) never depends on
`FleetNetworking`** (the JSON-RPC/WebSocket module) — the M0 hard guard. The
`HermesTransport` seam lives in `FleetCore`; the composition root
(`HermesFleetApp`) is what wires transport in, later.

| Module | Responsibility | Depends on |
|---|---|---|
| FleetCore | Pure domain types + transport seam protocol | — |
| FleetNetworking | JSON-RPC/WebSocket transport (gated) | FleetCore |
| FleetSecurity | Keychain token cache, auth classifier, redaction (gated) | FleetCore |
| FleetPersistence | SwiftData non-secret cache (gated) | FleetCore |
| FleetUI | SwiftUI shell: dashboard, root navigation | FleetCore, FleetSecurity, FleetPersistence |
| HermesFleetApp | Composition root, app lifecycle | all |

## Validation commands

Prerequisites: Xcode 26.6, `xcodegen` (2.46.0), an iOS 26.x simulator.

```sh
make generate          # xcodegen generate (project.yml → .xcodeproj)
make build             # simulator build
make test              # hosted unit tests on the iOS simulator
make test-core         # FleetCore package tests on host (fast, pure domain)
make validate          # generate + build + test + test-core
```

The destination resolves `iPhone 17 Pro` dynamically; edit `DEST` in the
Makefile if your simulator set differs.

## Directory map

```
HermesFleetApp/         app target source + asset catalog
HermesFleetAppTests/    hosted unit tests (app + cross-module boundary)
Packages/
  FleetCore/            pure domain + tests
  FleetNetworking/      boundary-only skeleton
  FleetSecurity/        boundary-only skeleton
  FleetPersistence/     boundary-only skeleton
  FleetUI/              SwiftUI shell
docs/M0-foundation.md   M0 scope, decisions, dependency rules, evidence
```

## Secrets

No sensitive values live in this repo. Tokens, keys, and credentials never go
in source, logs, or artifacts — later milestones keep them in Keychain only
(FleetSecurity).

## M0 acceptance (11/11)

See `docs/M0-foundation.md` for the mapping of each acceptance criterion to its
evidence.
