# U2 - Gateway-verifiable, request-bound approval signatures

| | |
| --- | --- |
| Status | DRAFT. Not filed anywhere. Filing is a maintainer decision (see [README](README.md)). |
| Fleet tracking | Hermes Fleet #151 (epic #76). Fleet's own version ships without this through #129 (S3: device key plus plugin-side verifier). Related: #123 (pairing v2), PR #160 (plugin endpoint that resolves an approval in-process). |
| Upstream baseline | hermes-agent `30de041b01` (main as last fetched, 2026-09-19). All paths below were re-read at drafting time on 2026-09-30. See [README](README.md#verification-baseline). |
| Prior art found | hermes-agent #89853 (open) asks for the inverse direction: a host-signed, durable approval receipt that a separate broker can verify. The two share vocabulary (canonical request digest, nonce, freshness, key id) and should be reconciled by the maintainers, not duplicated. hermes-agent #104960 (open PR) binds Discord approval cards to their own `request_id`; it is the same binding principle this draft builds on. |
| Assumptions | Contribution norms unverified beyond `CONTRIBUTING.md`. The Fleet canonical message lives in #129 and is the single source of truth for its field list; this draft follows it and records every difference (section 11). The domain tag and encodings here are proposals, not agreed constants. |
| Filing note | Sections 10 to 12 and the drafting notes are Fleet-internal context. Condense or drop them when filing. |

## 1. Summary

Today an approval decision is authenticated only as "a connected client sent
it". Add an optional, per-request **device signature**: an enrolled,
hardware-backed P-256 key signs a canonical message that includes the gateway's
own request id and request digest, so the gateway can verify that a specific
enrolled device (with whatever user-presence gate the device applied) made a
specific decision about a specific request, even if a bearer credential or a
relay path leaks. The feature is off by default and additive on the wire.

## 2. Problem statement and threat model

### 2.1 Mobile-client perspective

A phone is where approvals naturally get answered, often from a notification.
The phone can produce something stronger than a bearer-authenticated RPC: a
signature from a non-exportable Secure Enclave key, released only after Face ID
or Touch ID. The gateway currently cannot consume that proof, so the strongest
thing the phone does (biometric gate, then `approval.respond`) is invisible to
the party that actually enforces the approval.

### 2.2 In scope

- **Stolen or leaked bearer credential** (access token, password, WebSocket ticket): an attacker can connect and answer approvals as the user.
- **Hostile or compromised relay or notification path** that can trigger or replay an answer.
- **Injected or modified client** on a legitimately authenticated connection that submits a different choice than the human selected.
- **Replay** of a captured decision to a later request.

### 2.3 Non-goals

- A compromised phone whose key is usable (unlocked device, biometrics coerced or bypassed, malicious app with the user's session).
- A compromised gateway host (it holds the verifier and the policy).
- Proving *what the human saw*. The signature binds the request digest, not the rendering; an attacker who controls what the UI displays can still mislead the user.
- Multi-user team key management.

## 3. Current upstream behavior (verified)

| Claim | Evidence |
| --- | --- |
| `approval.respond` accepts exactly `session_id`, `profile`, `choice`, `all`, `request_id`. The generated params schema has `additionalProperties: false`, and the dispatcher rejects unknown param keys (error 4000). The result is `{resolved: integer}`. A signature cannot ride the current RPC. | hermes-agent: `apps/shared/src/gateway-contract.openrpc.json` (`ApprovalRespondParams`, `ApprovalRespondResult`); hermes-agent: `tui_gateway/AGENTS.md` ("Transport" and contract sections); hermes-agent: `tui_gateway/contracts/` |
| The handler resolves the session (with a durable-identity fallback that finds the owning live session by `request_id`, then by stored session id) and calls `resolve_gateway_approval(session_key, choice, resolve_all, request_id)`. The code is `5004` on failure. | hermes-agent: `tui_gateway/methods_prompt.py` (`approval.respond`, `_approval_respond_session_fallback`) |
| There is a **second** answer path: the `approval` server-to-client request. `_emit_approval_request` sends it with `send_async`; the client's response frame `{choice, all}` reaches `on_result`, which calls the same `resolve_gateway_approval`. `ApprovalResult` has `additionalProperties: false` with only `choice` and `all`. A third path, `request.answer`, proxies a response frame for an open request (its `result` is an open object). | hermes-agent: `tui_gateway/server.py` (`_emit_approval_request`); hermes-agent: `tui_gateway/server_requests.py` (`send_async`, `resolve_response`); hermes-agent: `tui_gateway/methods_prompt.py` (`request.answer`); hermes-agent: `apps/shared/src/gateway-contract.openrpc.json` (`ApprovalResult`, `RequestAnswerParams`) |
| `resolve_gateway_approval` is the single commit point: under a lock it pops the targeted entries (by `request_id`, oldest, or all), sets `entry.result`, and wakes the waiting agent thread. It performs no authentication of the caller. `withdraw_gateway_approval` ends a wait with a stamped `cancelled` cause; a withdrawal is not a denial. | hermes-agent: `tools/approval.py` (`resolve_gateway_approval`, `withdraw_gateway_approval`, `list_gateway_approvals`) |
| Queue entries carry a random `request_id` (`uuid4().hex`) created in `_ApprovalEntry.__init__`. The queue path has **no digest**. The entry data holds redacted `command`, `description`, `pattern_key(s)`, `allow_session`, `allow_permanent`. | hermes-agent: `tools/approval_gateway_wait.py` (`_ApprovalEntry`, `_await_gateway_decision`); hermes-agent: `tools/approval.py` (`_human_decision`) |
| A host-created binding already exists for plugin transports: `ApprovalRequest` has `request_id` (fresh `uuid4().hex`) and `digest`, SHA-256 over canonical sorted-key JSON of `schema_version`, `request_id`, `command`, `description`, `pattern_key`, `pattern_keys`, `surface`, `timeout_seconds`, `allowed_choices` and `session_key`. `ApprovalDecision(request_id, request_digest, choice)` is validated by `_validate_decision`: a mismatched id or digest becomes a denial (`stale`), a choice outside `allowed_choices` is `invalid`, a late answer is `timeout`. | hermes-agent: `hermes_cli/approval_transport.py` (`ApprovalRequest.create`, `ApprovalDecision`, `_validate_decision`) |
| A selected transport is not limited to the CLI prompt path. `_human_decision` (used by the dangerous-command gate and the `execute_code` gate, `transport=True`) calls `_present_with_selected_transport` **before** the gateway-queue branch, with `surface="gateway"` when the session is a gateway or ask-mode session. When a transport is selected it **replaces every built-in prompt surface**, including the TUI or dashboard `approval` card. `tools/approval_gateway_wait.py` itself has no transport logic, and the plugin-escalation gate (`_ACTION_GATE`, `transport=False`) never offers one. Selection is process-wide config (`security.approval.transport`, optional `transport_fallback: builtin`). | hermes-agent: `tools/approval.py` (`_GateSpec`, `_COMMAND_GATE`, `_EXECUTE_CODE_GATE`, `_ACTION_GATE`, `_human_decision`); hermes-agent: `tools/approval_prompt.py` (`_present_with_selected_transport`, `_transport_choice`); hermes-agent: `hermes_cli/approval_transport.py` |
| Capability advertisement exists: `client.capabilities` (params: `server_requests` only, `additionalProperties: false`) and `gateway.capabilities` ("what THIS build enforces", sourced from the enforcing module, never from config; result: `per_session_exclusive_submit`). | hermes-agent: `tui_gateway/methods_voice.py`; hermes-agent: `tui_gateway/contracts/liveness.py` |
| The `approval` request frame and `approval.pending` entries are open objects (`ApprovalRequestParams` is `extra=allow`; `PendingApproval` has `additionalProperties: true`) and already carry `request_id`, `choices`, `allow_session`, `allow_permanent`. Additive fields are therefore safe on those shapes. | hermes-agent: `tui_gateway/contracts/server_requests.py`; hermes-agent: `apps/shared/src/gateway-contract.openrpc.json` |
| A server-minted connection identity exists: `WSTransport.auth_identity` (`{user_id, provider}`), stamped at WebSocket upgrade, "never populated from RPC params". This is the natural principal to bind an enrolled key to. | hermes-agent: `tui_gateway/ws.py`; hermes-agent: `hermes_cli/web_server_chat.py` |
| Durable grants are created by `session` and `always` choices (`_persist_choice`); `once` authorizes a single execution. A policy keyed on choice class therefore maps onto real blast radius. | hermes-agent: `tools/approval.py` (`_persist_choice`, `_human_decision`) |
| Precedents for operator-confirmed pairing and hardened storage: `gateway/pairing.py` (salted hashes, constant-time compare, lockout, 0600 files, `approve_code` by the operator). | hermes-agent: `gateway/pairing.py` |

## 4. Proposed design

### 4.1 Device key enrollment

Enrollment must not be satisfiable by the very credential the feature defends
against. A key enrolled over an authenticated session is only trustworthy if the
operator (or an out-of-band pairing secret) confirms it.

New RPC methods, declared in `tui_gateway/contracts/` (so the generated OpenRPC
and TypeScript contracts update with them):

- `device_key.enroll` params: `{alg: "ES256", public_key: <base64url SPKI DER>, label: string, attestation?: {format: string, statement: string}}`. Result: `{enrollment_id, state: "pending", confirm: "operator" | "pairing_token", expires_at}`. Creates a **pending** record bound to the connection's `auth_identity` principal. Pending records expire (for example 10 minutes), are capped per principal, and are rate limited.
- Confirmation, one of: (a) the operator approves on the gateway host (CLI, following the `hermes pairing approve` precedent) after comparing a short code shown on both sides; (b) redemption of a pairing token that carries an `enroll_device_key` intent (see the U3 draft), which is how a fresh device gets a key in one gesture.
- `device_key.list` (principal's keys: `key_id`, label, created, last used, state) and `device_key.revoke {key_id}`. `key_id` is base64url(SHA-256(SPKI DER)). Revocation is immediate.

Storage: a 0600 file under the Hermes home, atomic writes (the repository already has `utils.atomic_json_write(path, data, mode=0o600)`), keyed by principal (`provider` plus `user_id`). Only public keys are stored. `attestation` is stored opaquely in v1 and never relied on for a security decision (verification of platform attestation is a possible later policy).

Loopback and stdio clients have no `auth_identity`; enrollment and signature policy do not apply to them (policy effectively off), which preserves local workflows.

### 4.2 Signed decision

An optional `signature` object on both answer paths:

```json
{
  "key_id": "<base64url SHA-256 of SPKI DER>",
  "nonce": "<base64url, at least 128 bits>",
  "issued_at": 1790000000,
  "expires_at": 1790000120,
  "alg": "ES256",
  "sig": "<base64url raw r||s, 64 bytes>"
}
```

- `approval.respond` gains an optional `signature` param.
- The `approval` server-request result (`ApprovalResult`) gains an optional `signature`.
- `request.answer` needs no schema change (open `result`), but verification applies to it too.
- Signature encoding: raw 64-byte `r||s` in base64url (as in JWS ES256, RFC 7518 section 3.4). Fleet #129 must pick the same encoding (open item in section 11).

Canonical message: a JSON object with sorted keys and no insignificant whitespace, UTF-8, with these members (the Fleet #129 field list):

| Member | Meaning |
| --- | --- |
| `v` | Domain-separation tag. Initial value `hermes-fleet/approval/v1` to match the Fleet client; upstream may choose a vendor-neutral tag, in which case #129 follows. The verifier accepts a fixed allowlist of tags. |
| `gateway_id` | Audience. An opaque gateway-instance identifier the gateway reports at enrollment, so a signature for one gateway is worthless at another. |
| `session_id` | Exactly the `session_id` parameter of the carrying call (or the session id of the `approval` frame for a response frame). Signing the parameter as sent prevents post-hoc substitution; authorization binding uses `request_id` and `request_digest`, not this field. |
| `request_id` | The gateway's queue `request_id`. |
| `request_digest` | The gateway-computed digest for that entry (section 4.3). Required when the gateway advertises digests; omitted only against a gateway that does not (Fleet #129 calls this "if known"). |
| `choice` | One of the entry's offered choices. |
| `all` | Boolean from the call. |
| `nonce`, `issued_at`, `expires_at` | From the signature object; Unix seconds. |

Illustrative vector (synthetic, verify-only; Fleet #129's shared fixtures are authoritative and this must be regenerated if #129 changes the encoding):

```text
canonical message (UTF-8, one line):
{"all":false,"choice":"once","expires_at":1790000120,"gateway_id":"gateway-example-01","issued_at":1790000000,"nonce":"AAECAwQFBgcICQoLDA0ODw","request_digest":"a8249a3c722018f7e4af853f0657cbd687953816310730646ff34843abb6f8fe","request_id":"0123456789abcdef0123456789abcdef","session_id":"sid-example","v":"hermes-fleet/approval/v1"}

request_digest input (as computed by the existing transport recipe, with session_key "session-key-example"):
{"allowed_choices":["once","session","always","deny"],"command":"example-tool --flag value","description":"example flagged action","pattern_key":"example_pattern","pattern_keys":["example_pattern"],"request_id":"0123456789abcdef0123456789abcdef","schema_version":1,"session_key":"session-key-example","surface":"gateway","timeout_seconds":300}
  -> SHA-256 = a8249a3c722018f7e4af853f0657cbd687953816310730646ff34843abb6f8fe

throwaway P-256 public key, SPKI DER, base64url:
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEZG8-kwH9d-LPKxftsfzKRQp3pKhdKqHY-GzjzbLaiacBb3TMgVVAXN2vtFv5V03qeamqSinKZW8Le0uL2QwPEA
key_id: qEtsFh-0AVlv6tBC2hVOFjDml7FcSJj9T32Pkv6FUxM
sig (raw r||s, base64url, valid over the canonical message above):
HxCWZEnUvvlE8vJSaZOWkdOGEptiZeVbykgTBOrcTF2aFwx95BBB2rJgAy5c8AfC5ltV31x4YFsEerxv41iVnA
```

The key was generated for this vector only and discarded. The signature was verified with OpenSSL over the exact message bytes before publication. Negative vectors (altered choice, request id, session, nonce, expired window, replayed nonce, unknown key) belong to the fixture set shared with #129.

### 4.3 Request digest on the queue path

The transport recipe is the natural binding, but the gateway queue path has no
digest today. Define one shared function, used by both paths:

- Move the digest computation out of `ApprovalRequest.create` into a function in `hermes_cli/approval_transport.py` (for example `compute_request_digest(fields)`), keeping the existing recipe byte-for-byte so transports do not change.
- In `_await_gateway_decision`, compute the digest over the same kind of fields as the client will see in the `approval` frame: `request_id`, redacted `command` as actually sent, `description`, `pattern_key(s)`, `surface`, `timeout`, the choices offered, and `session_key`. Store it in `entry.data["request_digest"]` so that `approval.pending`, reconnect replay (`open_requests`) and the live frame all carry it.
- Clients recompute the digest from what they received and refuse to sign if it differs from the advertised one (defends against a relay that edits display fields).

One subtlety to settle in review: the wire `command` passes through redaction twice (display redaction in `_human_decision`, then `_redact_approval_command` in `tui_gateway/server.py::_approval_request_payload`). The digest must be computed over the final redacted value that is sent, which is why it is computed at emit time rather than at queue time, or the second redaction must be folded into the queue-time value.

### 4.4 Verification rules (gateway)

Performed at a single chokepoint in front of `resolve_gateway_approval`, for all
three answer paths, before anything resolves:

1. Determine the target entry (by `request_id` through the existing lookup). If the policy requires a signature for this entry and none is present, fail with `signature_required`.
2. If a signature is present (required or not), verify it. An invalid signature is an error and is never downgraded to an unsigned success.
3. `key_id` must be an active key of the connection's principal (`auth_identity`). Otherwise `unknown_key`.
4. Freshness: `issued_at` not more than a configured skew in the future (default 60 s), `expires_at` in the future, and `expires_at - issued_at` at most a configured window (default 120 s). The entry's own expiry caps the window. Otherwise `signature_expired`.
5. Nonce unseen for this key within its window (check-and-set under a lock, persisted until `expires_at` plus skew). Otherwise `signature_replayed`.
6. `request_id` and `request_digest` match the entry's stored values; `choice` is one of the entry's offered choices; `all` must be false when a signature is required (signed decisions are per request). Otherwise `request_mismatch` or `disallowed_choice`.
7. ECDSA P-256 over SHA-256 of the canonical message rebuilt by the **verifier** from its own view of the call and entry. Never verify against a client-supplied digest alone.
8. Only then call `resolve_gateway_approval`. The nonce is consumed on the first successful verification even if the request has meanwhile vanished.
9. Audit: one event with `key_id`, `request_id`, `choice`, outcome or typed failure. Never log signature bytes.

Failure resolves nothing (fail closed). The agent keeps waiting until the
request's own timeout, so a failed signature cannot be used to cancel a pending
request. Typed errors use new codes in the existing client-error block (values
left to the maintainers): `signature_required`, `signature_invalid`,
`signature_expired`, `signature_replayed`, `unknown_key`, `request_mismatch`,
`disallowed_choice`. `resolved: 0` keeps meaning "nothing was pending".

### 4.5 Policy

```yaml
security:
  approval:
    require_device_signature: []      # default off. Example: [session, always]
    device_signature_max_window_s: 120
    device_signature_skew_s: 60
```

Default empty: behavior is identical to today. With `[session, always]`, `once`
and `deny` keep working unsigned, while durable grants need a verified device
signature. The class list (not a global on/off) exists because `once` is a
single execution, `session` and `always` create durable allowlist entries
(`_persist_choice`), and a deny is always safe to accept unsigned.

The entry records `signature_required` at creation, so clients know before they
ask. Other answer surfaces (for example text `/approve` on a chat platform) can
never sign: when policy requires a signature for a choice, those surfaces are
refused that choice and may still grant `once`, which fails closed and is easy
to explain. This interaction is a maintainer decision (section 12).

### 4.6 Compatibility and capability advertisement

- `gateway.capabilities` gains `device_signed_approvals: bool` (this build can verify), sourced from the enforcing module as the existing field is.
- The `approval` frame and `approval.pending` entries gain optional fields: `request_digest`, `signature: {required: bool, key_ids?: [string]}`, `server_time` (so a phone with a skewed clock can align `issued_at`).
- `client.capabilities` gains optional `device_signatures: bool` so the gateway knows whether the attached client can sign. If policy requires a signature and no attached client advertised signing, the entry is withdrawn promptly with a clear cause, following the precedent for clients that cannot answer server requests (`server_requests` fail-fast, hermes-agent #112548 referenced in source), instead of idling until the timeout.
- Because `client.capabilities` params are closed (`additionalProperties: false`), a client must read `gateway.capabilities` first and send the new field only when advertised. Older gateways would reject an unknown key with 4000.
- Unsigned clients keep working whenever policy is off (the default).

### 4.7 Plugin transports

The same digest binding applies to transports: extend `ApprovalDecision` with an
optional `signature` field (default `None`, so existing plugins are unchanged)
and verify with the same function inside `_validate_decision`'s caller. Note the
difference in identity: the transport's `request_id` is its own
`uuid4().hex`, not the queue entry's, so a signature is always for exactly one of
the two paths. Because a selected transport replaces all built-in prompts
(section 3), it is an all-or-nothing deployment choice and not a substitute for
verification on the TUI and dashboard path, which is why the proposal extends the
verification to the gateway queue path and does not rely on transports.

## 5. Security review notes

- **Replay.** Single-use nonce per key within the freshness window, plus `request_id` and digest binding (a signature for one request is invalid for any other) and `expires_at` capped by the entry's own expiry. A replay to a *later* identical command fails because the new entry has a fresh `request_id`.
- **Clock skew.** Gateway time is authoritative. Bounded future skew, `server_time` hint in the request frame, and a maximum window that is short relative to the approval timeout (default 300 s). A phone with a badly wrong clock fails closed with `signature_expired`.
- **Choice downgrade or substitution.** `choice` is signed and must be among the offered choices. The verifier rebuilds the message from the actual call, so any edit breaks the signature.
- **Relay or proxy editing display fields.** The digest covers the displayed command and description; the client recomputes before signing.
- **Stolen enrolled key.** Keys are non-exportable on iOS (Secure Enclave, `ThisDeviceOnly`, biometric-current-set). Revocation is immediate. Invalidation on biometric change surfaces re-enrollment on the device.
- **Enrollment takeover.** Enrollment is pending until operator-confirmed or redeemed through a pairing token; a stolen bearer token alone cannot activate a key. Pending records expire and are capped.
- **Key rotation.** Enroll the new key, confirm, revoke the old. Multiple active keys per principal are allowed (multi-device); any active key of the principal may sign.
- **Multi-device races.** Two devices answering the same request: the first verified decision wins under the existing lock; the loser gets `resolved: 0`.
- **Denial of service.** Failed verification resolves nothing and cannot cancel a request; rate limit verification failures per principal.
- **Partial deployments.** Clients on older builds cannot sign: handled by the capability fail-fast above.
- **Privacy.** Stored data is public keys, labels and timestamps; audit events contain no command text beyond what hooks already expose.

## 6. Minimal patch sketch

All files are hermes-agent paths.

- `hermes_cli/approval_transport.py`: extract `compute_request_digest`; optional `signature` on `ApprovalDecision`.
- `tools/approval_gateway_wait.py`: compute and store `request_digest` and `signature_required` on the entry; include them in the entry data.
- `tools/approval.py`: new verification seam called by `resolve_gateway_approval` callers (or an optional `proof` argument on `resolve_gateway_approval` itself); `_persist_choice` unchanged; policy reader next to `_get_approval_transport_config`.
- `tools/approval_context.py`: config readers for the three policy keys.
- New module, for example `hermes_cli/device_keys.py`: key store (0600, atomic), nonce cache, canonical message builder, ES256 verify (uses the `cryptography` package Hermes already pins).
- `tui_gateway/methods_prompt.py`: `approval.respond` passes `signature` through; `request.answer` likewise.
- `tui_gateway/server.py` (`_emit_approval_request`): pass the response frame's `signature` to the verification seam; add `request_digest`, `signature`, `server_time` to the frame.
- `tui_gateway/contracts/` (`prompt_voice.py` for the approval methods, `server_requests.py`, `liveness.py`, plus a new `device_keys` contract module): new fields and methods; regenerate `apps/shared/src/gateway-contract.openrpc.json` and `gateway-contract.generated.ts` with `scripts/gen_gateway_contracts.py`.
- `tui_gateway/methods_voice.py`: `gateway.capabilities` and `client.capabilities` additions.
- `hermes_cli/config_defaults.py`: policy defaults under `security.approval`.
- `hermes_cli/dashboard_auth/audit.py` or the approval log: signed-decision audit events.
- CLI: a `device-keys` command (list, approve, revoke), following the existing `pairing` CLI precedent.
- Docs: `website/docs/user-guide/features/hooks.md` mentions for the digest; a new security page for device signatures.

## 7. Test plan

Unit (new `tests/hermes_cli/test_device_keys.py`): canonical message byte-exactness against the published vector, sorted-key JSON, unknown-member rejection; verify accepts the vector and rejects every single-field mutation; raw r||s length checks; nonce check-and-set is atomic under threads; key store permissions 0600, atomic replace, revoke.

Gateway (extend `tests/tools/test_approval_*` and add `tests/tui_gateway/`): policy off leaves all existing tests unchanged; policy `[session, always]` accepts unsigned `once` and `deny`, rejects unsigned `session`; signed `session` resolves exactly one entry; failure modes (`signature_required`, invalid, expired, future-dated beyond skew, replayed, unknown key, digest mismatch, disallowed choice, `all` with signature required) each resolve nothing and leave the entry pending; concurrent answers (two devices, server-request response plus `approval.respond`) resolve exactly once; `withdraw_gateway_approval` is unaffected; the same checks through `request.answer`; transports: a transport decision with a bad signature becomes a denial.

Contract: regenerate artifacts; `tests/tui_gateway/contracts/test_generated.py` passes; `gateway.capabilities` and `client.capabilities` round-trip; an older-shaped client (no new fields) behaves exactly as before.

Security: enrollment pending expiry and caps; enrollment cannot be activated by the enrolling connection alone; revocation takes effect on the next verification; audit log never contains signature bytes or command text beyond existing exposure.

Interop: the Fleet client (#129) and the gateway verify each other's vectors from one shared fixture file.

## 8. Rollout

1. Land the digest on the queue path and the additive frame fields (no policy, no verification): clients can begin recomputing digests.
2. Land enrollment plus verification behind the default-off policy and the capability flags.
3. Document operator guidance: start with `[always]`, then `[session, always]`.
4. Fleet enables signing only against gateways that advertise `device_signed_approvals`.

## 9. Alternatives considered

- **Plugin transport as the verifier.** Available today for the command and `execute_code` gates, but a selected transport replaces all built-in prompt surfaces on the process, does not cover plugin-escalated tool calls, and is configured per process. Useful as a Fleet-side stopgap (section 10), not as the general answer.
- **Mutual TLS or client certificates.** Authenticates the device but not the decision; a stolen session on the device, or a relay terminating TLS, is out of reach, and certificate provisioning per self-hosted gateway is heavy.
- **Bearer token with shorter lifetime or scopes.** Reduces exposure but still cannot prove presence or bind a specific request.
- **Host-signed receipts (hermes-agent #89853).** Solves broker verification, not device presence. Complementary; the digest and nonce vocabulary should be shared.
- **WebAuthn or passkeys.** A strong fit for browsers; awkward to embed in a native client talking JSON-RPC, and platform authenticators on iOS already reduce to the same P-256 signature this proposal uses directly.
- **Server-side confirmation over a second channel** (code in chat). Adds friction per decision; a signature costs one biometric prompt.

## 10. Fleet without this proposal

Fleet never blocks on this and never sends unsanctioned parameters to stock gateways (the current client sends exactly four documented `approval.respond` params; #129 keeps a regression test for that).

- **#129 Phase A (ships now):** a per-device Secure Enclave P-256 key, canonical message and test vectors, enrollment UX, the signing API, and honest labeling of approvals as "not device-verified" against stock gateways.
- **#129 Phase B (plugin-side verifier, spike first):** a liveops plugin endpoint verifies the signature and resolves the approval in-process with `tools.approval.resolve_gateway_approval`, the same pattern PR #160 uses for its single-use response token (`POST .../push/respond`, which resolves only in the dashboard's own process; a client that answers through `approval.respond` is not token-verified, which is exactly the gap this proposal closes). The spike should also weigh the approval-transport option described in section 3: it is feasible for command and `execute_code` gates, but it replaces prompts on every surface of that process and needs operator config.
- **#123 (pairing v2)** reserves a device key thumbprint field; a pairing token that can carry an enrollment intent is part of the U3 draft.
- **PR #160 / #88** binds its response token to `request_id` and the exact command text through `command_digest` (SHA-256 of the command). U2's `request_digest` is a different, broader value. During the transition the app matches on `command_digest`; once a gateway advertises `request_digest` the push sender (via the U4 hook fields) can seal it too.

## 11. Synchronization with Fleet #129 (single source of truth)

Differences and open items, to be resolved in #129 and noted there if either side changes:

| Topic | #129 today | This draft |
| --- | --- | --- |
| Field list | `hermes-fleet/approval/v1 \|\| gateway_id \|\| session_id \|\| request_id \|\| request_digest_if_known \|\| choice \|\| all \|\| nonce \|\| issued_at \|\| expires_at` | Same members, expressed as the sorted-key JSON object in 4.2. |
| Byte encoding | "JSON canonicalized (sorted keys, no whitespace)" | Adopted as written. If #129's ADR fixes a different framing, this draft follows it. |
| Signature encoding | "DER/raw documented" | Proposes raw `r||s`, base64url. #129 should confirm. |
| `gateway_id` | Fleet-assigned per gateway record | Must be a gateway-reported audience value at enrollment, so a Fleet-local id is not sufficient against a real verifier. |
| Domain tag | `hermes-fleet/approval/v1` | Kept for compatibility; upstream may prefer a neutral tag. |
| `request_digest` | "if known" (stock gateway has none) | Always present once the gateway advertises digests. |

## 12. Open questions for the maintainers

1. Is an operator-confirmed enrollment over CLI acceptable, or should it be dashboard-only?
2. Should the `all` flag be refused entirely when a signature is required (this draft), or allowed with one signature per pending entry?
3. How should text `/approve` and other chat surfaces behave when policy requires a signature (refuse durable choices, as drafted)?
4. Should the single chokepoint live inside `resolve_gateway_approval` (covers every caller, including `/approve`) or only in the TUI and dashboard handlers?
5. Does the maintainer want this reconciled with hermes-agent #89853 into one receipt and digest vocabulary?

## Drafting notes for Fleet maintainers (remove before filing)

- **Correction to the planning issue (#151) and to #129.** Both say the approval transport is consumed by the CLI prompt path but not by the gateway queue path. In the source, the transport is selected in `tools/approval.py::_human_decision` ahead of the gateway-queue branch, for the dangerous-command and `execute_code` gates, and a selected transport replaces every built-in prompt surface (including the TUI and dashboard `approval` card). It is not used by `tools/approval_gateway_wait.py` itself and never by the plugin-escalation gate. The #129 Phase B spike option (b) ("act as an approval transport in the gateway path") is therefore technically available for those two gates, with the all-or-nothing caveat, and should be evaluated on that basis.
- **Correction to the planning issue's digest description.** The issue lists the digest inputs as command, description, pattern keys, surface, timeout, allowed choices and session key. The source also includes `schema_version` and `request_id` (so a digest is unique per request).
- **The queue path has no digest, and there are three answer paths.** The issue mentions `request.answer` but not the `approval` server-request response frame. All three commit decisions through `resolve_gateway_approval` (section 3); a verifier at `approval.respond` alone would be bypassable.
- **`ApprovalRespondParams` also has a `profile` field** that the planning issue's field list omits.
- **Vector provenance.** The published signature was produced with a throwaway key through OpenSSL and verified there; it is illustrative and not a substitute for #129's shared fixtures.
- Not validated: nothing here was run against a live gateway or a device.
