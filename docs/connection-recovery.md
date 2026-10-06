# Connection recovery and history refetch

Current behavior of gateway reconnect and conversation history recovery.
Source of truth: `ReconnectBackoff`, `ConnectionRecoveryTiming`, `AppEnvironment`
(connection watch), `GapRecoveryGovernor`, `ConversationViewModel`.

## Reconnect backoff
- A failed or dropped connection is retried with exponential backoff
  (`baseDelay` doubling up to `maxDelay`) for at most `maxAttempts` (8) retries.
- Being sampled online once does **not** restore the budget. It is restored
  only after `healthyDuration` (60 s) of continuous uptime; any failure restarts
  that clock. A peer that accepts a connection and drops it again (for example
  after a rejected oversized frame) therefore stays on its backoff.
- Deliberate actions restore the budget: the Connect button and foreground
  restore (when the gateway is not already connecting or connected), manual
  reconnect and disconnect, an endpoint or auth change, and gateway removal. The
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
unchanged; the task was not cancelled; no turn is streaming (the
unrecoverable-gap repair is exempt: its stream is already broken); and no
targeted gap replay (`recoverGap`) is suspended (the replay may be the only
source of events the snapshot lacks). A stale response is tried up to 3 times in
total, then the transcript is flagged incomplete (the conversation banner stays
visible even mid-turn) and one refresh is armed for turn completion, governed by
`GapRecoveryGovernor`. An empty snapshot does not erase rows that arrived while
the call was running (it is authoritative only for the moment the call began).
The incomplete flag clears only after an applied, uncontended snapshot.

A gap replay that started before a snapshot was applied (the snapshot cannot
be applied meanwhile, but a snapshot from a path that does not take this check,
such as opening a session) is discarded, because the snapshot is newer.

### Duplicate-content window (analysis)
After a snapshot is applied the continuity cursor is reset, so an event that the
gateway had already included in the snapshot but delivers afterwards would
render again. History and events share one WebSocket and the gateway writes
frames through one locked writer, so frames keep one order. The window needs
the gateway to emit an event concurrently with capturing the snapshot.

What the client does about it:
- A turn that is open when the response arrives makes the response stale (no
  snapshot is applied) and one refresh runs when the turn completes.
- A late `message.complete` only rewrites the existing assistant row, so it is
  idempotent against a snapshot that already holds that message (unit-tested).
- A late `message.start` would add a new assistant row, and a late
  `message.delta` would append to the snapshot's last assistant row. We expect
  the gateway to write a turn's start and deltas before it persists the message
  at completion, so they arrive before any response containing the message; this
  ordering was read in the gateway's writer but NOT verified for every event
  type, and there is no unit test for the late start/delta case.

Residual, unreproduced against a real gateway: late start/delta/tool events for
a message already in an applied snapshot could duplicate content until the next
refetch or until the conversation is reopened. Not release-blocking on current
evidence; it is the first thing to check if duplicated replies are ever seen.
