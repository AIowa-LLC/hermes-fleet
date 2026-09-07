# Architecture

Hermes Fleet is a thin native client that connects directly to user-owned Hermes gateways. The phone is the control surface; Hermes hosts remain the agent and compute plane.

## Module layout

### FleetCore

Owns domain models, identity and routing types, security-neutral policies, and the protocols used as seams between modules.

### FleetNetworking

Owns JSON-RPC/WebSocket transport, authentication helpers, gateway clients, replay handling, roster aggregation, management clients, and other wire-facing behavior.

### FleetSecurity

Owns Keychain-backed credential, token, and trust-pin storage. Secret persistence should not leak into UI or cache modules.

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
  ├─ FleetPersistence
  └─ FleetUI

HermesFleetApp → all modules
```

The module-boundary test guards the rule that `FleetUI` does not import `FleetNetworking`.

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
