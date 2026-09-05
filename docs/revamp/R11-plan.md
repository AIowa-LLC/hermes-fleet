# R11 — Hermes Fleet second generation

Owner-authorized adaptation of the supplied iOS 27 revamp brief. No purchases, paid services, live model requests, pushes, or TestFlight uploads. Local device build first; Hermes owns the later TestFlight release.

## Baseline and platform

Baseline: `6717c5111caa6142772f1681661bd2ca7a3080c4`.
Installed toolchain: Xcode 26.6 (17F113), iOS SDK 26.5. Keep deployment at iOS 26.0 so the paired phone can install this build. iOS 27 validation remains unavailable on this machine; do not claim it.

## R11-T1 — native foundation and destinations

Adaptive semantic colors, system display typography, system sidebar-adaptable tabs: Command, Chats, Bots, Workspace, Control. Each tab retains its own navigation path. Command Center stays within the biometric content gate. Existing gateway credentials, transport ownership, pinning, replay, approvals and cache behavior remain behind their original seams.

Chats aggregates read-only `session.list` results with route-qualified identities. Ordering is session creation time (the wire does not supply last-active time), explicitly labeled “Newest sessions.” Search covers titles, previews and owning bot names; gateway filtering is available. Failed refreshes remain visible.

## R11-T2 — conversation and management

A bounded turn index over the retained transcript; jumping to a turn suspends automatic following until Latest or a new send. Prompt reuse reads user turns already in this conversation; no new persisted sensitive history. Busy submission retains the draft. Tool disclosures expose actual transcript detail in a selectable inspector. Skills search, visible Cron failure states, and static Memory Graph halos use existing data.

## R11-T3 — icon

New original three-plane white wing in `HermesFleetApp/FleetWing.icon`. SVGs contain only shapes and fills. Apple Icon Composer supplies material rendering, with exported Default/Dark/Tinted/Clear evidence under `Design/icon-wing-v4`. Existing design outputs are preserved. Build number 20, marketing version 0.2.0.

## Wire audit and intentional limits

Inspected local Hermes Agent sources at `~/.hermes/hermes-agent/tui_gateway/`:

- `methods_session.py`: `session.list` is the existing route-scoped observation path.
- `methods_prompt.py`: `prompt.submit` accepts busy submissions, but no complete inspect/edit/delete/pause queue interface was found in the installed TUI gateway. Do not synthesize a queue. Existing steer workflow remains available.
- `methods_projects.py`: Projects exposes workspace/tree/session metadata. Fleet's Projects seam exposes tree, project sessions and path completion, not arbitrary file bytes. Workspace promotes that real browser; tool output is the initial native inspector. Arbitrary image/PDF/file previews and an artifact index need a separately verified content/provenance seam.

Command Center searches available roster and loaded sessions, and routes to per-gateway management surfaces. It does not pretend to search unloaded files, individual memories, skills or cron jobs. No fake telemetry or observability feed. Connection history remains explicitly connection history.

## R11-T4 — validation and handoff

Run all four package suites, complete hosted unit tests, deterministic UI suites (including migrated navigation and SecondGenerationUITests), module boundary and secret checks. Preserve xcresults and visual evidence. Inspect iPhone/iPad and icon appearances. Release development build with existing signing team; require `App installed:` plus build-number readback. Do not upload to TestFlight.

Record actual validation results and limitations separately; screenshots and simulator fixtures are not live gateway evidence.
