# ADR-0001 — Per-gateway session ownership (one transport per gateway)

- **Status:** Accepted (RT1 `t_c495dd5a`; apple-qa PASS @ `9502ac2`). Landing
  note: implementation approved but **not yet merged to origin/main as of
  RT5** — carried on branch `wt/t_c495dd5a`; current `main` still uses the
  pre-RT1 split (see Consequence below).
- **Source:** Independent red-team report P1-1 (`docs/../red-team`), reviewed
  @ `273c2ad`; confirmed still reproducing at `b874325` before the fix.
- **Related:** `docs/U3-conversation-screen.md` §4 decision 1.

## Context

The composition root (`HermesFleetApp/FleetServiceGraph.swift`) built **two
independent `GatewayWebSocketTransport`s per gateway**: one inside
`SingleGatewayConnection` (lifecycle/health) and another inside
`GatewayConversationSession` (conversation/streaming/replay). `AppEnvironment`
retained each in a different map (`activeConnections` vs `conversationSessions`).
This violated the documented one-transport design (U3 §4.1): gateway status /
reconnect could affect socket A while streaming / replay affected socket B;
endpoint/auth edits stayed pinned in the existing transports; removal could
leave a conversation socket/task alive.

## Decision

One per-gateway session/coordinator owns connectivity, conversation, replay,
and subscriptions over a **single `GatewayWebSocketTransport`**.

- `AppEnvironment` holds ONE map of per-gateway sessions. `connect`,
  `disconnect`, `reconnect`, and `conversationSession(for:)` all resolve the
  **same object** (the conversation session, which conforms to
  `GatewayConnectivityProviding`).
- Edit / removal **atomically retire** the session (disconnect + drop) so no
  stale transport or task survives.
- The session is built lazily per gateway by the injected `FleetConversationFactory`
  (composition root wires the concrete `GatewayConversationSession`).

## Consequences

- Seq watermarks, the live event channel, and replayed-event injection stay on
  one socket → replay dedupe is coherent by construction; `reauthenticate()`
  (M11) is the single re-auth entry point.
- Removes the lifecycle-vs-conversation divergence and stale-transport leak.
- **Current `main` state (RT5):** this decision is approved (apple-qa PASS)
  but not yet merged — `main` still has separate `activeConnections` +
  `conversationSessions`. Merging `wt/t_c495dd5a` (rebase onto `b5e80ad`+) is
  tracked as an orchestrator follow-up so F1 builds on the unified session.
- Trade-off: one transport serializes connectivity and conversation RPCs on a
  single correlation map (bounded concurrency; acceptable for a per-gateway
  control-plane client).
