# Connection recovery and history refetch

Current behavior of gateway reconnect and conversation history recovery.
Source of truth: `ReconnectBackoff`, `ConnectionRecoveryTiming`, `AppEnvironment`
(connection watch), `GapRecoveryGovernor`, `ConversationViewModel`.

## Reconnect backoff
- A failed or dropped connection is retried with exponential backoff
  (`baseDelay` doubling up to `maxDelay`) for at most `maxAttempts` retries.
- Being sampled online once does **not** restore the budget. It is restored
  only after `healthyDuration` (60 s) of continuous uptime; any failure restarts
  that clock. A peer that accepts a connection and drops it again (for example
  after a rejected oversized frame) therefore stays on its backoff.
- Deliberate actions restore the budget: the Connect button, manual reconnect,
  foreground restore, an endpoint or auth change, and gateway removal. The
  automatic retry path never resets its own budget.

### Known limitation (accepted for this release)
Once the budget is spent the gateway stays failed until a foreground restore or
a manual Connect. There is **no slow automatic probe**: a gateway that was down
for longer than the retry window (about 150 s with default timings) is not
reconnected on its own after it comes back. Uptime is sampled once per second,
so flaps that fall between two samples do not restart the stability clock.

## History refetch
A history response replaces the transcript only if, since its request began:
no live event or local mutation touched the transcript; no newer refetch
started (out-of-order responses are discarded); the opened session is
unchanged; the task was not cancelled; and no turn is streaming (the
unrecoverable-gap repair is exempt: its stream is already broken). Stale
responses retry at most 3 times, then the transcript is flagged incomplete,
a banner shows even mid-turn, and one refresh is armed for turn completion,
governed by `GapRecoveryGovernor`. An empty snapshot never erases live rows.
The incomplete flag clears only after an applied, uncontended snapshot.

A targeted gap replay (`recoverGap`) that was in flight when a snapshot was
applied is discarded: the snapshot already contains those events.

### Duplicate-content window (analysis)
After a snapshot is applied the continuity cursor is reset, so an event that the
gateway had already included in the snapshot but delivers afterwards would
render again. History and events share one WebSocket and the gateway writes
frames in one order; the only way to invert them is the gateway emitting an
event concurrently with capturing the snapshot (it persists a message, then
emits its event, while the history read runs on another thread).

Why this does not produce duplicate assistant text in practice:
- The streaming events of a turn (`message.start`, deltas) are written before the
  message is persisted, so they reach the client before any response that
  includes the message. A turn that is open when the response arrives makes
  the response stale (no snapshot is applied) and one refresh runs when the turn
  completes.
- A late `message.complete` only rewrites the existing assistant row, so it is
  idempotent against a snapshot that already holds that message (unit-tested).

Residual, theoretical: a tool row whose start/complete events are delivered
after a snapshot that already contains it could appear twice. It was not
reproduced against a real gateway and is not release-blocking. The next
refetch (or reopening the conversation) repairs it.
