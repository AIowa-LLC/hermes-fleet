# U4 - Push-oriented observer hook points for approvals, server requests and turn end

| | |
| --- | --- |
| Status | DRAFT. Not filed anywhere. Filing is a maintainer decision (see [README](README.md)). |
| Fleet tracking | Hermes Fleet #154 (epic #76). Fleet's sender ships without this: #88 (R2), implemented in PR #160, and #95 (R8, interim local notifications). Related: PR #157 (content-blind relay, R1). |
| Upstream baseline | hermes-agent `30de041b01` (main as last fetched, 2026-09-19). All paths below were re-read at drafting time on 2026-09-30. See [README](README.md#verification-baseline). |
| Prior art found | hermes-agent #92245 (closed as not planned by its author) asked for a pending-interaction observer and resolver seam with lifecycle events; its author withdrew it after finding the approval-transport seam and outbound webhooks. hermes-agent #67798 (open) asks for lifecycle hooks as a shared runtime contract across execution surfaces. hermes-agent #126292 (open) requests first-party mobile apps. This draft is narrower than #92245 (observe only, content-free, no resolver) and should be reconciled with #67798 by the maintainers. |
| Assumptions | Contribution norms unverified beyond `CONTRIBUTING.md`, which asks that a missing plugin capability be requested as a generic widening of the plugin surface (a new hook or context method), never a special case for one plugin. The draft is written that way: nothing in it names a client. |
| Filing note | Sections 11 to 13 and the drafting notes are Fleet-internal context. Condense or drop them when filing. |

## 1. Summary

A push sender running as a plugin needs three content-free signals in real
time: a human-answerable request opened or closed (approval, clarify, sudo,
secret), and an agent turn finished. Upstream already has most of the raw
material. The gaps are narrow:

1. The approval observer hooks fire with a payload that omits the approval's own `request_id`, which exists at that moment, plus an expiry and gate kind.
2. There is no observer for server-to-client requests other than approvals, and none that reports closure with a reason.
3. The existing per-turn `on_session_end` hook is content-free and close to what is needed, but it lacks a duration and parent or runtime identifiers, runs synchronously on the agent thread, and also fires for delegated child agents.
4. The approval hooks run inline and unbounded on the agent thread before the prompt is published.

The proposal adds these as additive, backward-compatible fields and a pair of
asynchronous observers that reuse the existing per-consumer dispatcher.

## 2. Problem statement (mobile-client perspective)

A phone is not always connected. To tell the user "approval needed" or "your
agent finished" without a live WebSocket, something on the gateway side must see
those events and hand a tiny, content-free message to a push path. The sender
must:

- correlate the push with the live request so that tapping it opens the right card, and withdraw the notification when the request closes from any surface (another device, timeout, interrupt);
- know the request's expiry so stale notifications are not delivered late;
- never include reply text, commands, questions or secrets, because the push path is an untrusted transport (Fleet seals payloads end to end, but the less the gateway emits the less can leak through a bug);
- never slow down an approval prompt or a turn.

### 2.1 Exact information a content-blind sender needs

| Information | Why |
| --- | --- |
| Event kind: approval, clarify, sudo, secret, or turn end | Choose notification category and copy. |
| Runtime session id (the id a client uses for `session_id` in RPC) | Attach the notification to the open conversation. |
| Stored session key and the agent session id | Survive reconnects and compression; the app can already answer by `request_id` with a stored id as a fallback. |
| Request id (approval queue id) and server request id (`srq-...`) | Correlate a push with `approval.pending`, `open_requests` and `request.cancel`. |
| Method or kind and gate (command, code, action) | Notification category. |
| Tool name when known | Optional label (not content). |
| Opened time and expiry | Drop late pushes; drive withdrawal. |
| Close reason: answered, resolved elsewhere, timeout, interrupted, session closed, shutdown | Withdraw or replace the notification. |
| Turn end: status (completed, error, interrupted), duration, model | "Finished" versus "failed", and coalescing. |

It must never receive reply text, commands, descriptions, questions, answers,
environment variable names, file paths, or tool arguments.

## 3. Current upstream behavior (verified)

| Claim | Evidence |
| --- | --- |
| `pre_approval_request` and `post_approval_response` are observer hooks ("returns ignored - plugins cannot veto or pre-answer"). The documented kwargs are `command`, `description`, `pattern_key`, `pattern_keys`, `session_key`, `surface` (`"cli"`, `"gateway"`, `"smart"`), and for the post hook `choice` and `decided_by`. | hermes-agent: `hermes_cli/plugins.py` (`VALID_HOOKS` comment); hermes-agent: `website/docs/user-guide/features/hooks.md` (`pre_approval_request`, `post_approval_response`) |
| The gateway-queue path (used by the TUI and dashboard backend) builds the payload `{command, description, pattern_key, pattern_keys, session_key, surface}` and fires both hooks through `_fire_approval_hook`, which adds `turn_id` and `tool_call_id` and, when the tool-dispatch observability context is bound, `session_id` (the agent session id). These three are not in the hooks documentation table. `request_id`, runtime session id, expiry and gate kind are not passed. | hermes-agent: `tools/approval_gateway_wait.py` (`_await_gateway_decision`, `_finish`); hermes-agent: `tools/approval_context.py` (`_fire_approval_hook`, `set_current_observability_context`); hermes-agent: `model_tools.py` (`_approval_observability`) |
| `request_id` exists **before** the pre hook fires. `_ApprovalEntry.__init__` does `data.setdefault("request_id", uuid.uuid4().hex)`; the entry is appended to the queue; then the hook fires; then `notify_cb(dict(entry.data))` publishes it. The hook payload simply does not include it. | hermes-agent: `tools/approval_gateway_wait.py` (`_ApprovalEntry`, `_await_gateway_decision`) |
| The approval hooks are **not** in the timeout-bounded set: `_HOOK_TIMEOUT_BOUNDED_HOOKS` excludes `pre_approval_request` and `post_approval_response` ("approval UX has its own timeout"). A slow callback therefore runs to completion on the agent thread **before** `notify_cb` publishes the prompt. | hermes-agent: `hermes_cli/plugins_dispatch.py` (`_HOOK_TIMEOUT_BOUNDED_HOOKS` and its comment block); hermes-agent: `tools/approval_gateway_wait.py` |
| Smart mode fires the same hooks with `surface="smart"` for automatic decisions made without a human, and a post hook only when the verdict is approve or deny (none on escalate). Identical concurrent prompts are coalesced: followers fire the pre hook with `coalesced=True` and have no queue entry of their own. The default `approvals.mode` is `smart`. | hermes-agent: `tools/approval_smart.py` (`_smart_verdict`); hermes-agent: `tools/approval_gateway_wait.py` (`_await_coalesced_leader`); hermes-agent: `hermes_cli/config_defaults.py` (`approvals`) |
| When a transport plugin is selected, the hook kwargs include `request_id` and `request_digest` with `surface="transport:<name>"`; the gateway-queue path does not. | hermes-agent: `tools/approval_prompt.py` (`_present_with_selected_transport`) |
| Server-to-client requests are minted in one module: ids `srq-<12 hex>`, `_register` validates against the contract and writes the frame, `send` (blocking) and `send_async` (queue-backed, used for approvals) are the two entry points. Non-answered endings emit `request.cancel {id, method, reason}` with reason one of `timeout`, `interrupted`, `shutdown`, `resolved`, `session_closed`; an answered request emits nothing. | hermes-agent: `tui_gateway/server_requests.py`; hermes-agent: `tui_gateway/contracts/server_requests.py` (`RequestCancelReason`, `RequestCancelPayload`) |
| Clarify, sudo and secret all go through `server_requests.send` (`_clarify_block`, `_ask`); approvals go through `send_async` in `_emit_approval_request`, which also passes the queue `request_id` in the frame and registers a settle callback so any ending of the queue wait withdraws the request. | hermes-agent: `tui_gateway/server.py` (`_clarify_block`, `_ask`, `_emit_approval_request`) |
| There is no clarify, sudo or secret observer hook. `VALID_HOOKS` has no entry for them. The only clarify signal is `pre_tool_call` with `tool_name == "clarify"`, which fires **before** the question is shown and is a policy hook: it is timeout-bounded and **fails closed** (a timed-out callback blocks the tool), and its kwargs include the raw `args`, which contain the question text. | hermes-agent: `hermes_cli/plugins.py` (`VALID_HOOKS`, `_get_pre_tool_call_directive_details`); hermes-agent: `hermes_cli/plugins_dispatch.py` (`_HOOK_TIMEOUT_FAIL_CLOSED_HOOKS`) |
| `on_session_end` fires once per turn from the turn finalizer (skipped when persistence is disabled) with `session_id`, `task_id`, `turn_id`, `completed`, `failed`, `interrupted`, `turn_exit_reason`, `model`, `platform`; the documentation states the canonical payload has no message body and that the hook is turn scoped. It is timeout-bounded (default 30 s, fail-open) but still synchronous on the agent thread, and runs before the TUI emits `message.complete`. A session teardown fires it again with `completed=False, interrupted=True` and no `turn_id`. | hermes-agent: `agent/turn_finalizer.py`; hermes-agent: `hermes_cli/plugins_dispatch.py`; hermes-agent: `tui_gateway/session_lifecycle.py`; hermes-agent: `website/docs/developer-guide/observer-hooks.md`, `website/docs/user-guide/features/hooks.md` |
| Delegated child agents are ordinary agents with their own turns, so `on_session_end` fires for them too; `subagent_start` (parent and child session ids, before the child runs) and `subagent_stop` (with `duration_ms`) exist. Background review forks set `_persist_disabled`, so they do not fire `on_session_end`. | hermes-agent: `tools/delegate_tool.py`, `tools/delegate_tool_results.py`; hermes-agent: `agent/background_review.py`; hermes-agent: `website/docs/developer-guide/observer-hooks.md` |
| Cron runs fire `on_session_end` with `platform="cron"`. | hermes-agent: `agent/turn_finalizer.py` (`platform=_platform`); hermes-agent: `cron/scheduler.py` |
| **Answer to the open `agent:end` question.** `agent:end` belongs to the messaging-gateway event registry. It is emitted in exactly one place, the messaging turn runner's post-turn step, with a context that includes platform user and chat ids, `message` and `response` (first 500 characters), `model` and `provider`. The TUI and dashboard WebSocket backend has no emit site and does not use the registry. It is unsuitable as a content-free turn-end signal. | hermes-agent: `gateway/run_turn.py` (`_hmwa_post_turn_hooks`); hermes-agent: `gateway/hooks.py` (module docstring and `HookRegistry`); absence verified by searching `tui_gateway/` |
| `on_stream_end` carries `final_text, finished, error` (reply content), so it is unsuitable as a content-blind turn-end signal. | hermes-agent: `agent/stream_delivery.py`; hermes-agent: `agent/plugin_stream_hooks.py`; hermes-agent: `website/docs/user-guide/features/hooks.md` |
| The accepted pattern for non-blocking observers: per-consumer bounded queue (1024) with a daemon worker, drop-oldest on overflow, failures reported once per callback, `telemetry_schema_version` injected. `on_room_member_activity` already projects server-request frames (`approval` as `request.opened`) for hosted-room sessions through it. | hermes-agent: `agent/plugin_stream_hooks.py` (`enqueue_plugin_stream_hook`); hermes-agent: `tui_gateway/hosted_room_member_activity.py` |
| Hook payloads evolve additively: callbacks with `**kwargs` receive everything, narrow signatures receive only what they declare. Registering an unknown hook name logs a warning and never fires, so `VALID_HOOKS` membership is a usable capability probe. | hermes-agent: `hermes_cli/plugins_dispatch.py` (`_invoke_hook_callback`); hermes-agent: `hermes_cli/plugins.py` (`_track_callback`, `VALID_HOOKS`) |
| Capability consent exists for plugins (`plugin_capability_granted`, `ctx.has_capability`), with the stated rule that a capability id is minted only together with an enforcing gate. | hermes-agent: `hermes_cli/plugin_capabilities.py`; hermes-agent: `hermes_cli/plugins.py` (`PluginContext.has_capability`) |
| `write_json` is the single chokepoint for outgoing frames (events and server requests); `project_room_member_activity` is already called there. The TUI turn thread emits `message.complete` and already measures turn duration for its "tui turn finished" log line. `TurnStatus` is `complete`, `error`, `interrupted`. | hermes-agent: `tui_gateway/server.py` (`write_json`); hermes-agent: `tui_gateway/prompt_turn.py`; hermes-agent: `tui_gateway/contracts/events.py` |
| Three session identities exist: the runtime id (`sid`, what clients send as `session_id`), the stored `session_key` (the approval queue key), and the agent `session_id` (durable Hermes session id; after compression the key can be a stale parent). `approval.respond` accepts any of them through a durable fallback that finds the live session by `request_id`. | hermes-agent: `tui_gateway/methods_prompt.py` (`_approval_respond_session_fallback`); hermes-agent: `tui_gateway/session_lifecycle.py` |

## 4. Proposed design

### 4.1 Additive kwargs on the existing approval hooks

For both `pre_approval_request` and `post_approval_response` on the gateway-queue
path, add:

| Kwarg | Value |
| --- | --- |
| `request_id` | The queue entry's id. For a coalesced follower, the **leader's** `request_id` together with the existing `coalesced=True`. |
| `gate` | `"command"`, `"code"` or `"action"` (from `_GateSpec.noun`); content-free. |
| `tool_name` | When known (a further contextvar next to the existing tool-call id), else empty. |
| `opened_at`, `expires_at` | Wall-clock seconds; expiry is `opened_at` plus `approvals.timeout`. |
| `allowed_choices` | The offered choices (`once`, `session`, `always`, `deny`). |
| `request_digest` | Only when U2 lands. |

`server_request_id` and the runtime session id are **not** available at this
point: the `srq-` id is minted later, inside `_emit_approval_request`, after
`notify_cb`, and the runtime id is known to the TUI layer, not to
`_await_gateway_decision`, which sees only the session key. They belong to the
server-request observer below. Because `approval.respond` already falls back to
`request_id` (then stored id), carrying `request_id` is enough for a client to
answer the right request even without the runtime id.

This is purely additive. Narrow callbacks keep working.

### 4.2 Server-request observers

A generic asynchronous pair, fired from `tui_gateway/server_requests.py`:

- `on_server_request_opened`, fired from `_register` after the frame is written (never for requests that were not sent because no client can answer them).
- `on_server_request_closed`, fired exactly once per opened request from the single settlement point of each ending: answer (`resolve_response`, `lock_answer` final lock), wait ended (`send` on timeout or interrupt), queue settle (`send_async.settle`), and `cancel`.

Common kwargs, all content-free:

| Kwarg | Notes |
| --- | --- |
| `server_request_id` | `srq-...` |
| `kind` | The request method: `approval`, `clarify`, `sudo`, `secret`, and any other `server_request` method. |
| `runtime_session_id`, `session_key`, `session_id` | The three identities; the last two when resolvable. |
| `request_id` | The approval queue id when `kind == "approval"`, else empty. |
| `opened_at`, `expires_at` | Expiry is `None` for unbounded waits. |
| `question_count` | For batch clarify only; a count, never text. |
| (closed only) `reason` | `answered`, `resolved`, `timeout`, `interrupted`, `shutdown`, `session_closed`: the existing `RequestCancelReason` values plus `answered`. |
| (closed only) `choice` | Only for `kind == "approval"` and only one of the four offered choices. |

Never included: params, `command`, `description`, question or choice text,
answers, `env_var`, `prompt`, `metadata`, secrets, sudo commands.

Optional, deferred: redacted previews behind an explicit opt-in (section 6).

### 4.3 Turn end

Two options, cheapest first; the maintainers choose.

**Option A (recommended first step): extend `on_session_end` additively.** Add `duration_ms`, `parent_session_id` (present for delegated children, absent otherwise; the agent already carries `parent_session_id`), and, for TUI and dashboard sessions, `runtime_session_id`. Consumers distinguish a real turn end from a teardown by the presence of `turn_id`. Cost: a few lines; but it stays synchronous on the agent thread (bounded at 30 s).

**Option B: a new asynchronous `on_turn_end` observer** dispatched through `enqueue_plugin_stream_hook` from the turn finalizer for all surfaces (TUI, dashboard, cron, messaging), so it never delays the turn. Kwargs: `session_id`, `parent_session_id`, `runtime_session_id` (TUI), `session_key` when known, `turn_id`, `status` (`completed`, `error`, `interrupted`), `duration_ms`, `model`, `platform`, `origin` (`user`, `cron`, `subagent`, `other`). No text, no error message. Option B also removes the need to keep a synchronous hook on the turn-completion path.

Whichever is chosen, `agent:end` is out of scope (section 3).

### 4.4 Dispatch and isolation rules

- The new hooks are dispatched only through `enqueue_plugin_stream_hook`: the fire site assembles a small dict after a `has_hook`-style check and does a bounded `put_nowait`. No plugin code runs on the agent thread, the request thread or the WebSocket write path.
- Per-consumer queue, drop-oldest, warn-once failure reporting, and `telemetry_schema_version` come from the existing dispatcher unchanged.
- Fire sites must never raise into the caller; wrap in the same never-raise helper pattern as `_fire_approval_hook`.
- The existing synchronous approval hooks keep their behavior for compatibility (some consumers may depend on seeing the request before the client does). Whether to move them into the timeout-bounded set or the asynchronous dispatcher is an open question (section 12); until then, consumers should only enqueue work, as the Fleet sender does.

## 5. Privacy and security

- **Payload minimization.** An allowlist per hook (the tables above) enforced in one place; a test asserts that no other key can be emitted (mirrors how `write_json` checks payloads against contracts).
- **No secrets.** `secret` and `sudo` kinds carry no field other than kind, ids, timing and close reason. The `env_var` name is excluded by default because it reveals configuration.
- **Plugin authority.** Hooks are in-process and only loaded plugins receive them; the new hooks add no new ability to act (return values ignored). If a later version adds redacted previews, gate them behind a new capability id with an enforcing check at dispatch time, following `plugin_capability_granted` and the registry's rule that an id is minted only with its gate. Hook callbacks are not owner-tagged today (only the event bus tags owners), so per-consumer payload shaping would need owner-tagged registration first; this is why v1 is content-free for everyone.
- **Rate limits and back pressure.** Bounded per-consumer queues; the approval queue and request caps already bound the number of opens.
- **Failure isolation.** A slow or failing plugin loses only its own oldest events. It cannot delay a prompt, a turn or a WebSocket write.
- **Ordering.** `opened` precedes `closed` for a request; consumers should treat events as hints and confirm state through `approval.pending` and `open_requests`, which stay authoritative.

## 6. Redacted previews (optional, deferred)

If maintainers want previews for notification text, add them in a follow-up as
`preview` on the opened hook, produced by the existing client-safe redaction
(`_approval_request_payload` and `redact_sensitive_text`), size-capped, absent by
default, and delivered only to consumers whose plugin was granted a dedicated
capability. The approval hooks already expose the redacted command to every
plugin today, so this adds surface only for clarify, sudo and secret, where it
is most sensitive. v1 leaves it out.

## 7. Compatibility and discovery

- New kwargs on existing hooks: additive; narrow callbacks are unaffected.
- New hook names: an older gateway logs a warning if a plugin registers one and never fires it. Plugins probe first with `"on_server_request_opened" in hermes_cli.plugins.VALID_HOOKS` (and likewise for `on_turn_end`) and use their fallback when absent. A version field is not needed; the hook name set is the capability.
- `telemetry_schema_version` is injected by the dispatcher for the new hooks, following the observer contract.
- Documentation: add rows to the hook table in `hooks.md` and `observer-hooks.md`, and add `session_id`, `turn_id`, `tool_call_id`, `coalesced` and `surface="transport:<name>"` to the existing approval hook documentation, which today lists only six kwargs.

## 8. Minimal patch sketch

All files are hermes-agent paths.

- `tools/approval_gateway_wait.py`: add `opened_at` and `expires_at` to `_ApprovalEntry`; build `payload` with `request_id`, `gate`, `allowed_choices`, expiry; use the leader's `request_id` for followers.
- `tools/approval_context.py`: extend `set_current_observability_context` with an optional tool name; pass through `_fire_approval_hook`.
- `tools/approval.py`: pass `gate` from the `_GateSpec` into the approval data.
- `hermes_cli/plugins.py`: add `on_server_request_opened`, `on_server_request_closed` (and `on_turn_end` for option B) to `VALID_HOOKS`, with a comment block of the kwargs.
- `tui_gateway/server_requests.py`: a small `_notify_observers(event, req, reason=None)` helper called from `_register`, `send`, `send_async.settle`, `resolve_response`, `lock_answer`, `cancel`; it builds the allowlisted dict and calls `enqueue_plugin_stream_hook`. A single `_close(req, reason)` guard ensures one close per request.
- `tui_gateway/server.py`: the runtime session id is already the `sid` in `req.sid`; session key lookup through `_sessions`.
- `agent/turn_finalizer.py` and/or `tui_gateway/prompt_turn.py`: option A extra kwargs, or option B `enqueue_plugin_stream_hook("on_turn_end", ...)` (the TUI turn thread already computes the duration it logs).
- `website/docs/user-guide/features/hooks.md`, `website/docs/developer-guide/observer-hooks.md`: documentation.
- `tests/tools/test_approval_plugin_hooks.py`, `tests/tools/test_approval_hook_session_id.py`, `tests/tui_gateway/test_protocol.py` and a new `tests/tui_gateway/test_server_request_observers.py`: tests below.

## 9. Test plan

Approval hooks (extend the existing approval hook tests):

1. The pre and post payloads on the gateway-queue path include `request_id` equal to the entry's id, `gate`, `allowed_choices`, `opened_at`, `expires_at`; `surface="smart"` payloads do not claim a `request_id`.
2. Coalesced follower: `request_id` equals the leader's and `coalesced` is true.
3. Existing narrow-signature callbacks and `**kwargs` callbacks both still work; hook docs table matches emitted keys.
4. `request_id` in the hook equals the id in `approval.pending` and in the `approval` frame.

Server-request observers (new test file, using the existing server fixtures and `reset_for_tests`):

5. `opened` fires after the frame is written with the allowlisted keys only; it does not fire when the request was not sent (no answering client).
6. `closed` fires exactly once for each ending: answered by response frame, answered via `request.answer`, final `clarify.lock`, timeout, interrupt, `cancel(sid)`, shutdown, approval settled from another surface (`resolved`), session closed. A simultaneous answer and timeout yields one close.
7. No forbidden key can appear: property test over all request kinds asserting the key set and that no value equals any param text (command, question, prompt, env var name).
8. Isolation: a blocking consumer callback does not delay `send`, `resolve_response` or the approval prompt (measure with a blocked callback and a short deadline); queue overflow drops only that consumer's oldest events; an exception is reported once.
9. Ordering: for each request, `opened` precedes `closed`.

Turn end:

10. Option A: `duration_ms` present and non-negative; `parent_session_id` present only for delegated children; teardown firing lacks `turn_id`.
11. Option B: one event per turn across TUI, cron and messaging; interrupted, error and completed statuses; no text fields; not delayed by a blocked consumer.

Contract and docs:

12. The hook documentation test (if any) and `VALID_HOOKS` stay in sync; `telemetry_schema_version` is present.

## 10. Reference plugin snippet (synthetic)

```python
# A content-blind push sender using the proposed hooks, with fallbacks for older gateways.
import queue
import threading

from hermes_cli.plugins import VALID_HOOKS

_jobs: "queue.Queue[dict]" = queue.Queue(maxsize=256)


def _enqueue(job: dict) -> None:
    try:
        _jobs.put_nowait(job)          # never block, never raise
    except queue.Full:
        pass


def on_server_request_opened(**kw):
    if kw.get("kind") not in {"approval", "clarify"}:
        return
    _enqueue({"t": "open", "kind": kw["kind"], "request_id": kw.get("request_id", ""),
              "session_id": kw.get("runtime_session_id", ""), "expires_at": kw.get("expires_at")})


def on_server_request_closed(**kw):
    _enqueue({"t": "close", "request_id": kw.get("request_id", ""),
              "server_request_id": kw.get("server_request_id", ""), "reason": kw.get("reason", "")})


def on_turn_end(**kw):
    if kw.get("parent_session_id") or kw.get("status") == "interrupted":
        return
    _enqueue({"t": "done", "status": kw.get("status", ""), "duration_ms": kw.get("duration_ms", 0)})


def register(ctx):
    if "on_server_request_opened" in VALID_HOOKS:      # new gateways
        ctx.register_hook("on_server_request_opened", on_server_request_opened)
        ctx.register_hook("on_server_request_closed", on_server_request_closed)
    else:                                               # older gateways: existing observers, degraded
        ctx.register_hook("pre_approval_request", lambda **kw: None if kw.get("surface") != "gateway"
                          else _enqueue({"t": "open", "kind": "approval", "session_key": kw.get("session_key", "")}))
    if "on_turn_end" in VALID_HOOKS:
        ctx.register_hook("on_turn_end", on_turn_end)
    threading.Thread(target=_sender_loop, daemon=True).start()


def _sender_loop():
    while True:
        job = _jobs.get()
        # seal(job) and hand only ciphertext to the relay here (stub)
        del job
```

The worker loop stands in for the sealing and relay call; the point is that
the hooks only enqueue. The snippet is illustrative and was not executed.

## 11. Alternatives considered

- **Use the plugin event bus (`ctx.emit` / `ctx.subscribe`).** Core currently emits no events on it, it has one shared worker for all subscribers (a blocking subscriber costs the worker and later emits drop), and it is namespaced for plugin-to-plugin use. A per-consumer dispatcher isolates consumers better.
- **Reuse `hooks.outbound` (HMAC-signed outbound webhooks).** The allow-listed events are existing hooks, so it inherits the gaps above (no `request_id`, no clarify event) and posts payloads that include command text for approval hooks; it is not content-free.
- **Observe over a second WebSocket.** Not a passive observer: sessions route frames to one transport slot, and attaching can displace the desktop client (hermes-agent #80723 describes the single-slot routing). Also requires a live connection, which is the thing push replaces.
- **A full pending-interaction service with a resolver (hermes-agent #92245).** Larger surface, includes resolution; this draft only observes and leaves answering to the existing authenticated RPC.
- **Put everything in `on_session_end`.** Fine for turn end (option A) but does not help requests.
- **Emit previews by default.** Rejected: the push path is untrusted and previews for clarify, sudo and secret are the most sensitive content in the system.

## 12. Open questions for the maintainers

1. Option A or B for turn end, and should B cover cron and messaging surfaces or only TUI and dashboard?
2. Should the existing approval hooks stay synchronous and unbounded, move into the timeout-bounded set, or also be dispatched asynchronously? Changing them affects plugins that rely on seeing the request before the client does.
3. Should `on_server_request_*` cover every `server_request` method or only human-answerable ones (approval, clarify, sudo, secret, vault prompts)? Desktop bridges (preview, tour) are not human decisions.
4. Reconcile with hermes-agent #67798 (shared hook contract across surfaces): is the messaging gateway expected to fire the same hooks with the same kwargs?
5. Is a version or capability indicator preferable to `VALID_HOOKS` membership as the probe?

## 13. Fleet without this proposal (how the sender works today)

Fleet never blocks on this. The sender lives in the `hermes-liveops` plugin and
ships as R2 (#88), implemented in PR #160 (open at drafting time, head `e9ecf0dd8e`,
stacked on the relay PR #157, head `43f543076d`). Alerts reach a phone through the
content-blind relay of PR #157 (R1, #87) as end-to-end sealed payloads; the relay
and APNs see only ciphertext and a generic title key. A foreground WebSocket path
(#95, R8) covers the interim and the app-open case.

What PR #160 does with hooks that exist today, and the degraded behaviors the sender
must advertise honestly on each gateway version:

| Need | Today (PR #160 and stock gateway) | Degradation without U4 |
| --- | --- | --- |
| Approval opened | `pre_approval_request` (observer). `coalesced` followers are ignored. | The hook has no `request_id`; the worker reads the in-process pending queue (`tools.approval.list_gateway_approvals`) and includes `request_id` only when exactly one pending request has that command text; otherwise the app resolves the request through `approval.pending` using `session_id` and `command_digest`. Works only in the process that owns the queue (Desktop and dashboard backends; a separate messaging-gateway process cannot be read this way). |
| Approval closed | `post_approval_response`, sending a sealed `withdraw` with the same collapse id. | Covered, including `timeout` and `cancelled` choices. |
| Clarify | `pre_tool_call` with `tool_name == "clarify"`. | Fires before the question is shown, so the push can arrive first (the app retries its resume and `open_requests` read); it is a fail-closed policy hook, so the callback must stay O(1). No close signal, so a clarify notification cannot be withdrawn on answer. |
| Agent finished | `on_session_end`, skipping interrupted turns; cron by `platform == "cron"`. | No duration; delegated child agents also fire it (extra "done" alerts); synchronous on the agent thread. |
| Correlation with a live client request | `session_id` (agent session id) and `command_digest` inside the sealed payload; the app answers through `approval.respond`, whose durable fallback accepts `request_id` or a stored session id. | No runtime session id in hooks, so the app cannot attach the push to an open conversation without a lookup. |
| Answering from the notification | PR #160's single-use response token and plugin endpoint (works only when the dashboard shares the agent process). | Upstream offers no interception point on `approval.respond`; see the U2 draft. |

Sealed payload consistency with PR #160 (v1 fields: `v`, `kind`, `gateway_label`,
`bot`, `session_id`, `request_ref`, `redacted_preview`, `command_digest`, `risk`,
`created_at`, `expires_at`, `nonce`, plus `request_id`, `response_token`,
`outcome`):

| PR #160 payload field | Source today | Source if U4 lands |
| --- | --- | --- |
| `kind` (`approval`, `clarify`, `done`, `cron`, plus `withdraw`) | Which hook fired | `kind` plus turn-end `origin` (`cron`); `withdraw` from `closed` |
| `session_id`, `request_ref` | Hook `session_id`, `session_key` | Adds `runtime_session_id`; `request_ref` stays a plugin-derived opaque value |
| `request_id` | Pending-queue lookup, exactly-one heuristic | Hook kwarg, authoritative, no heuristic |
| `command_digest` | SHA-256 of the exact command text from the hook's `command` | Unchanged while the approval hooks carry `command`; a future `request_digest` (U2) can be sealed alongside it |
| `redacted_preview` | Plugin redaction of `command` or the clarify question (from `pre_tool_call` args) | Unchanged in v1; previews from the observer are deferred (section 6) |
| `expires_at` | Plugin-side estimate | `expires_at` from the hook |
| `outcome` (done, cron, withdraw) | `completed` and `failed` flags of `on_session_end` | `status` from the turn-end observer, `reason` and `choice` from `closed` |
| `risk`, `gateway_label`, `bot`, `response_token`, `nonce` | Plugin-side | Unchanged; never emitted by hooks |

Differences to call out: U4 is content-free by default, while the sealed payload
carries a redacted preview that the plugin derives itself from existing hooks; the
proposal does not change that. PR #160 labels `request_id` "omitted from hook"
(#88 evidence says it is minted after the hook), but in source the id exists before
the hook and is simply not passed.

## Drafting notes for Fleet maintainers (remove before filing)

- **Corrections to the planning issue (#154).** (1) The issue says the approval hooks carry no runtime session id. The hooks do carry `session_id` (agent session id), `turn_id` and `tool_call_id` through `_fire_approval_hook`; what is missing is `request_id`, the runtime session id, expiry and gate. (2) The issue says the only turn-end events found are messaging-only or carry reply text. `on_session_end` already fires per turn and is content-free (documented), which is how PR #160 implements "done" and cron; the gaps are duration, parent linkage, thread and latency. (3) The issue asks for `server_request_id` on the approval hooks; it is not available there without reordering the emit sequence, so it is proposed on the new observer (section 4.1). (4) `agent:end` is answered in section 3.
- **Corrections to #88 and PR #160 text.** #88 says `request_id` is minted "afterwards"; it exists before the hook and is omitted (PR #160 already notes this). #88 lists `session_id` among hook kwargs, which is correct.
- **Findings for PR #160 (not changed here, reported for the R2 lane).** At head `e9ecf0dd8e`: (a) `on_pre_approval_request` does not filter `surface`; in smart mode (the default `approvals.mode`) every automatic decision fires the hook with `surface="smart"` and, on an escalate verdict, never fires a matching post hook, so the sender can raise "approval needed" for decisions that no human will answer. Filtering to `surface == "gateway"` (and deciding deliberately about `"cli"` and `transport:*`) avoids it. (b) Delegated child agents fire `on_session_end`; the sender can suppress them today by recording `child_session_id` from `subagent_start` (documented) before the child runs, without waiting for this proposal. (c) The `pre_tool_call` clarify callback reads the raw question text from `args` in the hook thread; the content stays inside the plugin, but it is the one place a policy hook handles user-visible text.
- **Cross-check with PR #157 (relay).** Nothing in this proposal touches the relay contract. The relay only sees ciphertext plus a fixed title key, so U4's hook fields affect the plugin, never the relay.
- Not validated: nothing here was run against a live gateway; the hook behaviors are derived from source reading only, and the reference snippet was not executed.
