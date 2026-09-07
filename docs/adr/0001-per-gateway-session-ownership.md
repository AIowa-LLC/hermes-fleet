# ADR-0001: Per-gateway session ownership

**Status:** Accepted, implementation pending

## Context

Connectivity and conversation behavior have historically been created through separate runtime ownership paths. Separate transports for lifecycle/health and conversation/replay can diverge during reconnects, endpoint edits, authentication changes, or gateway removal.

## Decision

A gateway should have one runtime session/coordinator that owns connectivity, conversation streaming, replay, and subscriptions over one transport.

- lifecycle actions resolve the same per-gateway owner used by conversations
- endpoint/auth edits retire the existing owner before rebuilding it
- gateway removal disconnects and retires the owner atomically
- sequence watermarks and replay state live with the same transport that receives live events

## Consequences

A single owner makes reconnect, replay, and authentication state coherent by construction and removes stale-transport ambiguity.

The trade-off is that more per-gateway behavior is coordinated through one object and one correlation domain.

## Current implementation note

The current public source still contains separate connectivity and conversation ownership paths. This ADR must not be described as landed until those paths are unified in source and covered by the relevant regression tests.
