# ADR-0002: Replay validation and idempotence

**Status:** Accepted, landed

## Context

Reconnect replay must not duplicate live events, accept events for the wrong session, silently normalize malformed envelopes, or advance sequence watermarks using incoherent data.

A replay design that snapshots watermarks and begins holding live frames in separate operations can also admit an interleaving event between those operations.

## Decision

Replay should be fail-closed and idempotent.

1. Begin the replay hold and capture watermarks atomically on the transport owner.
2. Require a structurally valid replay envelope.
3. Require replay events to belong to the requested session.
4. Require sequence identifiers to be non-negative, strictly increasing, and unique.
5. Require replay metadata such as latest sequence, truncation state, and count to be internally coherent.
6. Reject malformed replay data instead of compacting or defaulting it.
7. On truncation or validation failure, rehydrate authoritative session history and surface an explicit failure state.
8. Gate live and replayed forwarding by session and sequence so watermarks advance monotonically.

## Consequences

Malformed, foreign-session, duplicate, or out-of-order replay data is rejected instead of being silently normalized.

Atomic hold/snapshot prevents the live-versus-replay interleaving that can otherwise produce duplicate rendering.

## Current implementation note

`GatewayWebSocketTransport.beginReplayHold()` now starts the hold and returns
the watermark snapshot in one actor operation. `GatewayReplayClient` strictly
validates the envelope and each event, and both reconnect replay and manual
resume use that one request path. Malformed batches trigger an authoritative
history refetch and a `.failed` outcome without injecting their events or
advancing their watermark. Cancellation removes the pending RPC and releases
the replay hold. `ReconnectReplayTests` covers the live/replay race, strict
validation, recovery, cancellation, truncation, and `open_requests` retention.
