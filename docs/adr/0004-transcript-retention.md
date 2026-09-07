# ADR-0004: Transcript retention and display windowing

**Status:** Accepted

## Context

An indefinitely growing transcript array increases model memory, cache work, and SwiftUI diffing cost during long sessions.

## Decision

Authoritative transcript history and the rendered display window are separate concerns.

- authoritative rows are retained in the conversation model and persisted through the non-secret cache
- the public display transcript is a bounded suffix of the authoritative rows
- persistence writes authoritative history rather than the bounded display window
- current UI behavior defaults to the most recent 200 rows

## Consequences

The UI cost of a long-running session is bounded while cached history remains complete.

The current limitation is that older rows beyond the display window do not yet have an interactive pagination/backfill surface. That is a presentation limitation, not intentional history loss.
