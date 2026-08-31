# ADR-0002 — Replay validation and idempotence policy

- **Status:** Accepted (RT1 `t_c495dd5a`; apple-qa PASS @ `9502ac2`). Landing
  note: implementation approved but **not yet merged to origin/main as of
  RT5** — carried on branch `wt/t_c495dd5a`; current `main` still has the
  pre-RT1 tolerant decode (see Consequence below).
- **Source:** Independent red-team report P1-2, P1-3; reviewed @ `273c2ad`.
- **Related:** `docs/M6-reconnect-replay.md`, `spec §9/§10`.

## Context

Two replay defects. **(P1-2)** `GatewayReplayEngine.replayAfterReconnect`
read watermarks, then awaited `beginReplayHold` as a *separate* actor hop — a
live frame arriving between snapshot and hold could be forwarded live and then
replayed again (double render after reconnect). **(P1-3)**
`GatewayReplayClient.decode` was fail-open: it compact-mapped invalid entries,
defaulted missing `latest_seq`/`truncated`/`count`, and did not validate
session, ordering, or count — a gateway mismatch or malformed response could
drop entries silently, inject another session's event, duplicate/descend
sequences, or advance a watermark incoherently.

## Decision

Replay is fail-closed and idempotent by construction.

- **Atomic hold+snapshot:** the transport exposes
  `beginReplayHoldAndCaptureWatermarks()` — parking live frames and taking the
  watermark snapshot in **one actor operation**, so no live frame can slip
  between snapshot and hold.
- **Strict envelope validation** in `GatewayReplayClient.decode`: `events`
  must be a present array; every entry must decode and carry the **requested
  session ID**; every seq must be non-negative and **strictly increasing /
  unique**; `latest_seq` must be present, ≥ 0 and ≥ max event seq; `truncated`
  must be present (bool) and `count` must equal `events.count`. Any violation
  throws `ReplayError.malformedPayload` — nothing is compacted or defaulted.
- On violation (or truncation), the engine **rehydrates authoritative
  `session.history`** and surfaces `.failed`, never injecting unvalidated data.
- Live + replayed forwarding is **gated by session + sequence**: duplicate /
  descending events are dropped; the watermark advance is monotonic.

## Consequences

- Malformed, foreign-session, duplicate, or out-of-order replay data is
  rejected and replaced with authoritative history — never normalized away.
- Replayed events (seq > snapshot watermark) pass the gate and advance the
  watermark; parked live frames dedupe on flush — no double render, no loss.
- Covered by the deterministic regression matrix
  (`ReplayIntegrityRegressionTests`: wrong-session, duplicate, descending,
  missing/incoherent `latest_seq`, count mismatch, undecodable entry; the
  discriminating P1-2 interleave test is RED on the old two-hop shape,
  GREEN on the atomic shape).
- **Current `main` state (RT5):** this decision is approved but not yet merged —
  `main` still uses the tolerant decode and two-hop replay hold. Same
  merge-follow-up as ADR-0001.
