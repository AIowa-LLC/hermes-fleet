# ADR-0004 — Transcript retention and windowing policy

- **Status:** Accepted + landed on `origin/main` @ `89c2c55` (RT4 `t_5cb8bb6e`).
- **Source:** Independent red-team report P2-8; reviewed @ `273c2ad`.
- **Related:** `docs/U3-conversation-screen.md`, `spec §9/§12`.

## Context

The conversation transcript was an ever-growing in-memory array
(`ConversationViewModel`). `LazyVStack` deferred view creation but not model /
storage / diff growth, so a long session with high-frequency tool/status events
increased memory, cache work, and SwiftUI diffing without any retention or
windowing policy.

## Decision

Authoritative history and display window are separated.

- `allRows` is the **authoritative, unbounded transcript history**, persisted to
  the SwiftData cache (`CacheStoring`).
- The public `transcript` is a **capped display window** over that history:
  `Array(allRows.suffix(maxDisplayRows))`, default `maxDisplayRows = 200`.
- Persistence always writes the **authoritative `allRows`**, never the capped
  window — so retention never loses history from the cache; a relaunch
  rehydrates the full record.

## Consequences

- Bounded in-memory display cost on long sessions (model + SwiftUI diffing),
  while authoritative history remains complete in the cache.
- Covered by `ConversationViewModelTests.testTranscriptWindowIsCappedAndPreservesAuthoritativeHistory`
  (CI: hosted unit bundle).
- Trade-off: the UI shows only the most recent 200 rows of a very long session;
  pagination/back-fill of older rows is not yet implemented (future work, not a
  data-loss risk since history is persisted).
