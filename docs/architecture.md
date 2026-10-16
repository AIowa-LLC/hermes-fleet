# Architecture

Hermes Fleet is a thin native client that connects directly to user-owned Hermes gateways. The phone is the control surface; Hermes hosts remain the agent and compute plane.

## Module layout

### FleetCore

Owns domain models, identity and routing types, security-neutral policies, and the protocols used as seams between modules.

### FleetNetworking

Owns JSON-RPC/WebSocket transport, authentication helpers, gateway clients, replay handling, roster aggregation, management clients, and other wire-facing behavior.

### FleetSecurity

Owns Keychain-backed credential, token, and trust-pin storage. Secret persistence should not leak into UI or cache modules.

### FleetClientKit

The extension-safe client layer for app extensions (notification service, widgets, Live Activity, controls). Depends only on FleetCore and FleetSecurity and imports nothing else from the app: no FleetNetworking, FleetUI, FleetPersistence, UIKit, or SwiftData. It owns the shared-group configuration and container resolution (with an app-container fallback while the App Group is not enabled), the redacted extension snapshot store, and a one-shot HTTPS JSON-RPC helper with SPKI pin verification. See [`extension-kit.md`](extension-kit.md).

### FleetPersistence

Owns non-secret SwiftData cache models and snapshots used for offline or cold-start presentation.

### FleetUI

Owns SwiftUI screens and observable view models. It depends on FleetCore abstractions and selected non-networking modules, but does not import FleetNetworking.

### HermesFleetApp

The application target is the composition root. It creates concrete networking, security, persistence, and device services and injects them into the UI layer.

## Dependency rule

```text
FleetCore
  ↑
  ├─ FleetNetworking
  ├─ FleetSecurity
  │    ↑
  │    └─ FleetClientKit
  ├─ FleetPersistence
  └─ FleetUI

HermesFleetApp → all modules
App extensions → FleetCore, FleetSecurity, FleetClientKit only
```

The module-boundary test guards the rule that `FleetUI` does not import `FleetNetworking`. `ModuleBoundaryTests` and `scripts/extension_boundary_guard.py` also guard the extension-safe allow-list for `FleetClientKit` and extension targets.

## Navigation and ownership model

The app shell has eight top-level destinations — Bots, Chats, Groups, Scheduled, Kanban, Fleet, Settings, and About — with typed navigation paths, an App Lock gate over all content, and non-secret navigation state (`FleetNavigationState`, persisted under `fleet.navigation.v1`) restored on launch. Destinations are a Codable identity enum (`FleetScreen`) carrying gateway IDs, routes, session IDs, and resource scope — never credentials, grants, or mutable room-authority snapshots.

The route model assigns each screen a canonical owner: ordinary sessions → Chats; bot details, canonical chats, Routines, and the gateway room index → Bots; room conversations → Groups; board selection and boards → Kanban; schedules home → Scheduled; gateway registry, Gateway Detail, most gateway resources, artifacts, and fleet summaries → Fleet; security and data settings → Settings. About owns the app identity and legal/support information. Cross-destination navigation switches to the canonical owner and opens the target there while preserving the other paths; repeated opens focus the existing destination instead of stacking duplicates. Selecting a room from the Bots roster opens that room in Groups. See [`navigation.md`](navigation.md) for the full model.

Fleet Home and Gateway Detail render bounded observations, not fabricated telemetry: attention is known-items only, activity is limited to real execution signals, and unknown or partial coverage is displayed as such. The UI layer issues no per-bot `session.list` or per-room `groups.state` calls from Home; roster observation is coordinated through the app-seam scheduler. See [`features.md`](features.md#fleet-home-and-coverage-honesty) for the coverage contract.

## Direct-to-gateway model

A gateway is registered with a user-supplied endpoint and authentication strategy. Hermes Fleet does not require a central AIowa relay.

At the registry boundary:

- endpoints are treated as origins rather than arbitrary secret-bearing URLs
- URL user-info is rejected
- query and fragment material is not trusted as credential storage
- sensitive values are redacted before logging or display

Credentials are stored in Keychain-backed stores. Non-secret snapshots and cached conversation data use the persistence layer.

## Conversation and replay model

Conversation events are streamed over the gateway transport and may carry monotonically increasing sequence identifiers. The conversation layer tracks applied event continuity and can recover gaps from the gateway replay surface or fall back to authoritative history when a replay range is no longer available.

Transcript display is windowed for UI cost while authoritative cached history is preserved separately. See the ADRs for replay, resume, and transcript-retention decisions.

## Current architectural work

Two accepted hardening decisions are documented but are not fully represented by the current public implementation:

- [`adr/0001-per-gateway-session-ownership.md`](adr/0001-per-gateway-session-ownership.md) calls for one runtime transport/session owner per gateway.
- [`adr/0002-replay-validation-idempotence.md`](adr/0002-replay-validation-idempotence.md) calls for atomic replay hold/snapshot and strict fail-closed replay-envelope validation.

The current runtime still contains separate connectivity and conversation ownership paths. Contributors should not describe those ADRs as landed until the source actually reflects them.

## Testing strategy

The repository uses several layers of validation:

- host-side Swift package tests for pure/module behavior
- hosted iOS unit tests
- deterministic simulator UI suites backed by scripted fixtures
- module-boundary checks
- repository safety and secret scanning
- optional live gateway and physical-device checks for environmental behavior

Deterministic fixtures are for reproducibility. They are not a substitute for live-gateway evidence when a claim specifically depends on a real deployment.
