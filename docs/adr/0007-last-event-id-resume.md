# ADR-0007: Last-event-ID resume semantics

**Status:** Accepted

## Context

A reconnecting conversation stream must distinguish new events from duplicates and gaps. The gateway replay surface uses per-session sequence identifiers and can return missed events after a known cursor, but the conversation layer also needs to track what it has actually applied to the rendered transcript.

## Decision

Use one sequence space with explicit client-side continuity validation.

- thread event sequence identifiers into conversation events
- track the last event actually applied by the conversation layer
- classify incoming events as contiguous, duplicate, gap, or unstamped/unknown
- drop duplicates at the conversation layer
- recover a detected gap from the gateway replay surface using the applied-event cursor
- if the replay range has been truncated or cannot be trusted, surface an integrity notice and reload authoritative session history
- include the last-seen cursor on session resume where the gateway safely tolerates it

## Consequences

The rendered conversation can detect both reconnect gaps and live-stream discontinuities instead of silently accepting a jumping event sequence.

This cursor complements transport-level replay watermarks: the transport tracks what it observed, while the conversation layer tracks what it actually applied.

Unstamped events remain compatible with older or partial surfaces, but they cannot provide the same continuity guarantee.
