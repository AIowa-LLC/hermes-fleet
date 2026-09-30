# U3 - Short-lived, single-use pairing tokens in the core gateway

| | |
| --- | --- |
| Status | DRAFT. Not filed anywhere. Filing is a maintainer decision (see [README](README.md)). |
| Fleet tracking | Hermes Fleet #152 (epic #76). Fleet's client-side protections ship regardless through #123 (S1 Phase A: client-enforced expiry, nonce replay guard, SPKI pin from the QR). Phase B of #123 (gateway-side single-use redemption) is attempted through the liveops plugin only if its feasibility spike allows. Related: U2 draft (device-key enrollment), #61 (OAuth sign-in), #129. |
| Upstream baseline | hermes-agent `30de041b01` (main as last fetched, 2026-09-19). All paths below were re-read at drafting time on 2026-09-30. See [README](README.md#verification-baseline). |
| Prior art found | No upstream issue or PR for app pairing tokens was found by read-only search on 2026-09-30. hermes-agent #126292 (open feature request for first-party mobile apps) mentions QR pairing "with per-device scopes" as a requirement, which this draft would serve. The maintainer should redo the duplicate search before filing. |
| Assumptions | Contribution norms unverified beyond `CONTRIBUTING.md`. Field names marked "(#123)" are the Fleet v2 pairing payload and are the source of truth for overlapping fields; differences are listed in section 11. Route and config names are suggestions. |
| Filing note | Sections 10 to 12 and the drafting notes are Fleet-internal context. Condense or drop them when filing. |

## 1. Summary

Hermes Fleet pairs an iPhone with a gateway by scanning a QR code. The v1 QR
carries a gateway URL, username and **password** with no expiry, no
single-use property and no certificate binding. Anyone who photographs it can use
it indefinitely, and the first connection to an HTTPS gateway relies on the user
accepting the first certificate (trust on first use).

Proposal: a core gateway feature that lets an authenticated operator mint a
**short-lived, single-use pairing token**, and adds one public **redemption**
route that exchanges the token for a normal session credential pair (reusing the
native token machinery) plus, optionally, enrollment of a device key (U2). The
token can carry the gateway's TLS SPKI fingerprint so the phone can pin the
certificate before it sends anything secret. A short authentication string (SAS)
lets the operator and the phone confirm they are talking to each other.

## 2. Problem statement and threat model

### 2.1 Mobile-client perspective

A phone has no credentials before the first connection, so the exchange that
gives it credentials has to be reachable before authentication. Today the only
choices are to put a reusable password in the QR or to have the user type it.
A plugin cannot fix this cleanly: plugin routes are mounted behind dashboard
auth, and the public-path allowlist is a fixed upstream set (section 3). A safe
single-use redemption needs core support.

### 2.2 In scope

- **Photographed QR or screen capture** (shoulder surfing, screenshots in chats, CCTV).
- **Replay** of a scanned code after the legitimate device has paired.
- **Relay or network attacker on first connect** who can present its own TLS certificate.
- **Guessing or brute force** against the public redemption route.
- **Stale codes** left in chat history or on a wiki page.

### 2.3 Non-goals

- A compromised gateway host or operator workstation that mints the token.
- A compromised phone.
- Long-term certificate pin management after pairing (client side; see #123 and Fleet S2).
- Replacing password login or OAuth sign-in; both keep working.

## 3. Current upstream behavior (verified)

| Claim | Evidence |
| --- | --- |
| Public routes are a small fixed allowlist with an explicit rule: `PUBLIC_API_PATHS` is shared by both auth middlewares and is to be kept minimal ("every entry must be safe for external uptime probes, the pre-login SPA, and anyone who curls the hostname; otherwise gate it and bootstrap after login"). Entries include health, status and cron-fire. | hermes-agent: `hermes_cli/dashboard_auth/public_paths.py` |
| The auth routes are public through a separate list in the gated middleware: `_GATE_PUBLIC_PREFIXES` contains `/auth/login`, `/auth/callback`, `/auth/native/authorize`, `/auth/native/token`, `/auth/native/refresh`, `/auth/password-login`, `/auth/logout`, `/login`, `/api/auth/providers`. Matching is `path == p or path.startswith(p)`, so an entry also exposes any deeper path. | hermes-agent: `hermes_cli/dashboard_auth/middleware.py` (`_GATE_PUBLIC_PREFIXES`, `_path_is_public`) |
| A route can opt into bearer-token auth with `register_token_route(path)` (exact path; "does NOT make the route public"). The token seam runs outermost, asks every provider with `supports_token`, and answers 401 (or 503 on outage) otherwise. A token provider returns a `TokenPrincipal(principal, provider, scopes)`. | hermes-agent: `hermes_cli/dashboard_auth/token_auth.py`; hermes-agent: `hermes_cli/dashboard_auth/base.py` (`TokenPrincipal`, `DashboardAuthProvider.verify_token`) |
| Plugins can register auth providers (`ctx.register_dashboard_auth_provider`) and the bundled drain plugin registers a token provider plus `register_token_route` for its single route. | hermes-agent: `hermes_cli/plugins.py` (`register_dashboard_auth_provider`); hermes-agent: `plugins/dashboard_auth/drain/__init__.py` |
| Password login and session minting: `POST /auth/password-login` is public, rate limited per IP (10 attempts per 60 s, in process), generic errors (no username oracle), `p.complete_password_login(...)`. The bundled basic-auth provider mints signed stateless session tokens through `BasicAuthProvider._mint_session(user_id)`. `Session` has `user_id`, `email`, `display_name`, `org_id`, `provider`, `expires_at`, `access_token`, `refresh_token` and **no scope field**. | hermes-agent: `hermes_cli/dashboard_auth/routes.py` (`auth_password_login`, `_password_rate_limited`); hermes-agent: `plugins/dashboard_auth/basic/__init__.py`; hermes-agent: `hermes_cli/dashboard_auth/base.py` |
| Native token machinery: `POST /auth/native/token` returns `_bearer_payload(session)` (`access_token`, `refresh_token`, `token_type`, `expires_at`, `provider`, `user_id`); `POST /auth/native/refresh` rotates. `POST /api/auth/ws-ticket` mints a 30 s single-use WebSocket ticket (`mint_ticket` / `consume_ticket`, in memory). | hermes-agent: `hermes_cli/dashboard_auth/routes.py`; hermes-agent: `hermes_cli/dashboard_auth/ws_tickets.py` |
| One-time code precedent in memory: `native_flow` stores 256-bit handles, TTL 120 s, caps, pop-before-verify, constant-time compare. It is process-local (dies on restart). | hermes-agent: `hermes_cli/dashboard_auth/native_flow.py` |
| Audit log: one JSON line per event under the Hermes home, `AuditEvent` enum, token-like fields (`access_token`, `refresh_token`, `code`, `code_verifier`, `state`, `ticket`, `cookie`, `authorization`) stripped before writing. | hermes-agent: `hermes_cli/dashboard_auth/audit.py` |
| Hardened one-time code precedent for chat-platform DM pairing (not app pairing): 8-character codes from an unambiguous 32-symbol alphabet via `secrets`, 1 hour expiry, max 3 pending, per-user rate limit, lockout after 5 failed approvals, 0600 data files, salted SHA-256 hash stored with constant-time compare, codes never logged, operator approval through the CLI. | hermes-agent: `gateway/pairing.py` |
| The dashboard server does not terminate TLS: the `uvicorn.Config` call has no certificate arguments and the comment says gated mode "runs behind a TLS terminator". The gateway therefore usually does not know the certificate a phone sees. Public URL is configurable (`dashboard.public_url`). | hermes-agent: `hermes_cli/web_server.py`; hermes-agent: `hermes_cli/config_defaults.py` (`dashboard.public_url`, `dashboard.trusted_proxies`) |
| The existing CLI name `pairing` is taken by chat-platform DM pairing. | hermes-agent: `hermes_cli/main.py`, `hermes_cli/console_engine.py` |

Fleet side (this repository): `Packages/FleetCore/Sources/FleetCore/PairingPayload.swift` (v1 payload, no expiry), Fleet #123 (v2 design: `exp`, `nonce`, `spki`, SAS), `docs/gateway-pairing.md`.

## 4. Proposed design

### 4.1 Creating a token (authenticated)

- HTTP: `POST /api/auth/pairing-tokens`, reachable only with a dashboard session or bearer token. Body: `{ttl_seconds?, label?, intent?: {enroll_device_key?: boolean}}`. The TTL defaults to 120 s and is clamped (for example 30 to 600 s).
- CLI equivalent for operators with host access (name to be chosen by the maintainers; `pairing` is already used, for example `hermes dashboard pair`). The CLI and the HTTP route call the same library function and the same store.
- The response is shown once and never retrievable again:

```json
{
  "code_id": "<128-bit random, base64url>",
  "secret": "<256-bit random, base64url>",
  "url": "https://gateway.example.com",
  "exp": 1790000120,
  "nonce": "<128-bit random, base64url>",
  "spki": "<SHA-256 of the TLS SPKI, encoded as in #123> or null",
  "spki_source": "config | gateway | none"
}
```

These field names deliberately equal the Fleet v2 pairing payload keys (#123) so one encoder renders the QR. `code_id` is the server-side lookup id, `secret` replaces the long-lived password, `exp` is the server-set expiry, `nonce` is per token and feeds the SAS.

Scope: the credential minted at redemption has the same permissions as the creator's normal session (a `Session` has no scope field today). A `scope` member is reserved with the single value `session` so that route-level scoping can be added later without changing the contract. Route-level scoping is a larger design (see open questions).

### 4.2 Redemption (the one public route)

`POST /auth/pairing/redeem`, JSON, exactly this shape:

```json
{ "code_id": "...", "secret": "...", "device": { "label": "Phone", "public_key": "<optional, base64url SPKI DER>" } }
```

Successful response: the existing native bearer payload, plus optional members:

```json
{ "access_token": "...", "refresh_token": "...", "token_type": "Bearer", "expires_at": 1790003600,
  "provider": "<provider>", "user_id": "<id>",
  "enrollment": { "key_id": "...", "state": "active" } }
```

The client then refreshes through `/auth/native/refresh` and opens the WebSocket through `/api/auth/ws-ticket` exactly as a native-flow client would. No password ever reaches the phone or the QR.

Behavior:

1. Look up by `code_id`. Unknown id, wrong secret, expired, already redeemed, revoked and malformed input all return the **same** generic 400 with the same body and equivalent timing (a dummy hash comparison runs for unknown ids). No state oracle.
2. Verify the secret with a constant-time comparison of a salted SHA-256 against the stored hash.
3. On success, in one critical section: mark the record redeemed (single use), mint the session through the provider, and (if intent and public key are present) create an **active** device-key enrollment for the session's principal. Possession of the one-time secret, created by an authenticated operator, is the out-of-band confirmation that U2 requires for enrollment.
4. On a wrong secret for an existing id, count the failure; invalidate the record after 3 failures. The secret has at least 128 bits, so this is about limiting noise, not about stopping guessing.
5. Token consumption is never undone. A network failure after the server consumed the token means the operator mints another (cheap at 2 minutes).
6. Providers must implement an optional new method, for example `mint_session_for_pairing(principal) -> Session` (default: not supported, like `complete_password_login`). The basic-auth provider can implement it with `_mint_session`. A provider without it makes the feature unavailable for that gateway (advertised accordingly).

### 4.3 Storage

A file-backed store, 0600, written atomically, following `gateway/pairing.py`: records hold `code_id`, random salt, salted SHA-256 of the secret, `created_at`, `expires_at`, state, principal, label, intent, failure count, and the SAS once redeemed. The raw secret exists only in the creation response. File backing is needed because the CLI creator and the dashboard process are different processes; the in-memory stores used by `native_flow` and `ws_tickets` would not work for CLI-created tokens. Expired records are pruned opportunistically. Maximum outstanding tokens are capped (for example 5).

### 4.4 Rate limiting, lockout, audit

- Per-IP sliding window on the redemption route, stricter than password login (for example 5 per minute) plus a global cap, reusing the pattern of `_password_rate_limited`. Behind a proxy the existing `client_ip` helper applies, with its existing caveat that the address is the proxy's unless `X-Forwarded-For` is trusted.
- No global lockout. The chat-pairing precedent locks out an entire platform after 5 failed approvals; on a public pre-auth route that would let anyone switch pairing off. Per-record invalidation and per-IP throttling replace it.
- New audit events (`AuditEvent`): token created, redeemed, failed (with a coarse reason, never the secret), revoked, expired. Add the secret field name to the redaction set. Log at most a truncated `code_id`.
- Revocation: authenticated `DELETE /api/auth/pairing-tokens/{code_id}` and the CLI.

### 4.5 Certificate fingerprint (`spki`)

The server often cannot know the certificate the phone will see (section 3). Specify an ordered fallback:

1. `dashboard.pairing.tls_spki` set by the operator, or a CLI option that performs a TLS handshake to the configured public URL and computes SHA-256 of the SubjectPublicKeyInfo on the operator's machine (the same computation Fleet's generator script performs with OpenSSL, #123).
2. If the gateway itself terminates TLS (not the case in this checkout), the gateway's own certificate.
3. Otherwise omit the field (`spki: null`, `spki_source: "none"`). The client must then treat pairing as trust on first use and say so; the SAS is computed without a fingerprint and does not protect against TLS interception in that case.

Pinning against an edge network or CDN is brittle because the edge certificate changes; operators in that setup should leave the value unset. Long-term pin handling after pairing is client behavior.

### 4.6 Short authentication string (SAS)

The phone and the gateway each compute six digits from **their own view** and the
operator confirms the digits match:

```text
sas = decimal6( HMAC-SHA256( key = nonce, msg = spki_bytes || device_key_thumbprint ) )
```

- The phone uses the SPKI it actually observed on the TLS connection and the thumbprint of its own device key.
- The gateway uses its configured or known SPKI and the thumbprint of the device public key it received at redemption, stores the result on the record, and shows it to the operator (CLI or authenticated API).
- `decimal6` is a fixed truncation (for example take 4 bytes big-endian, mask the top bit, modulo 1,000,000, zero-pad), specified in the proposal with test vectors.

The digits must **not** be supplied by the server to the phone: a relay could forward them and the comparison would prove nothing. The server's contribution is the per-token `nonce`, the stored record and the operator display; each side computes the digits independently. If the phone did not send a device key, the thumbprint term is empty on both sides.

Interception analysis: a TLS-terminating relay that the phone accepted (no pinned `spki`) presents its own SPKI to the phone and a different device key to the gateway, so the two computed values differ and the operator sees a mismatch, then revokes (revocation kills the sessions and the enrolled key). A photographed-QR attacker who redeems first gets a session the operator does not recognize, and the real phone gets the generic failure, which is itself a signal.

Policy: advisory by default (the operator sees "paired: label, SAS, time" and can revoke in one action). An optional strict mode (`pairing.require_sas_confirm`) activates the session only after the operator confirms. Strict mode is a larger change and is left as a follow-up.

### 4.7 Token format options

| Option | Pros | Cons |
| --- | --- | --- |
| **Opaque random `code_id` + `secret`, server-side state (recommended)** | Small QR; simple; single-use, revocation and per-id failure counts need state anyway; hashed at rest; no parsing or algorithm-confusion surface; no signing key to manage. | Needs a store (already required for single use). |
| Signed JWT-like blob (HMAC or ES256 by a gateway key) | Stateless verification of expiry. | Single use still needs a used-id store, so statelessness is lost; revocation needs state; larger QR; signing key lifecycle; classic algorithm and claim-validation pitfalls. |
| Human-typable short code (8 characters, as chat pairing) | Works without a camera. | About 40 bits is too little for an unauthenticated online route; acceptable only as a fallback paired with a selected `code_id` and strict per-id attempt limits. |
| URL with the secret in the fragment (`https://gateway/pair#...`) | Universal-link friendly; the fragment is not sent to the server on a normal GET. | Adds a web landing page and link-handling surface; not needed for v1. |

### 4.8 Public-path justification

`PUBLIC_API_PATHS` stays unchanged (its rule is about uptime probes, which the redemption route is not). The redemption route belongs with the credential-accepting auth routes, next to `/auth/password-login`, in `_GATE_PUBLIC_PREFIXES`. Constraints:

- Register the exact path and add no sub-routes (the `startswith` matching would expose any deeper path), or tighten the match for this entry.
- POST only, JSON only, small body limit, no cookies set, nothing returned on failure beyond the generic error.
- Mounted only when `dashboard.pairing.enabled` is true and the auth gate is engaged; the legacy loopback middleware does not need it.

## 5. Compatibility and rollout

- `dashboard.pairing.enabled` defaults to `false`; nothing changes for existing deployments.
- Capability advertisement: add `pairing_token` to `auth_flows` on the public status response when enabled and supported by a registered provider (`_auth_gate_status` in `hermes_cli/web_routers/status.py`). Absent means an older or disabled gateway.
- Coexistence: password login, native sign-in and cookie sessions are untouched. Clients choose a pairing token when the flag is present.
- Suggested phases: CLI-only creation first (host access is the most conservative authority), HTTP creation second, strict SAS mode third.

## 6. Security review notes

- **Entropy and storage.** 128-bit id and 256-bit secret from `secrets`; only a salted hash is stored; files are 0600 with atomic writes; the secret never appears in logs or later API responses.
- **Oracle resistance.** One generic failure body and status; unknown ids cost the same as wrong secrets; no distinction between expired, used and revoked.
- **Single use under concurrency.** Consumption is a compare-and-set under a lock (and a file lock across processes); two simultaneous redemptions produce exactly one session.
- **Expiry.** Server clock only; the 2 minute default keeps a leaked code nearly useless. The client's `exp` check (#123) is defense in depth.
- **Brute force.** Per-IP throttle, per-record invalidation, global cap; no global lockout.
- **First-connect MITM.** Closed by the pinned `spki` when it is present; detected after the fact by the SAS when it is absent or the operator supplied a wrong value.
- **Audit completeness.** Creation, redemption, failures and revocation are logged without secrets.
- **Replay of a redeemed token.** Fails generically; the audit log records the attempt.
- **Operator error.** The CLI prints the token once and warns about screenshots; expiry bounds the damage.
- **Provider support.** Only providers that implement the new method participate; everything else fails closed.

## 7. Minimal patch sketch

All files are hermes-agent paths.

- `hermes_cli/dashboard_auth/pairing.py` (new): token store, create and redeem functions, SAS helper, failure counters.
- `hermes_cli/dashboard_auth/routes.py`: `POST /auth/pairing/redeem` (public) and the authenticated create, list and revoke routes; reuse `_bearer_payload`.
- `hermes_cli/dashboard_auth/middleware.py`: add the exact redemption path to `_GATE_PUBLIC_PREFIXES`.
- `hermes_cli/dashboard_auth/base.py`: optional `mint_session_for_pairing` on `DashboardAuthProvider` (default raises like `complete_password_login`); `assert_protocol_compliance` unchanged.
- `plugins/dashboard_auth/basic/__init__.py`: implement it with `_mint_session`.
- `hermes_cli/dashboard_auth/audit.py`: new `AuditEvent` members; add the secret field name to `_REDACTED_FIELDS`.
- `hermes_cli/dashboard_auth/request_utils.py` or `routes.py`: a dedicated rate limiter for the redemption route.
- `hermes_cli/web_routers/status.py`: advertise `pairing_token`.
- `hermes_cli/config_defaults.py`: `dashboard.pairing.{enabled, default_ttl_s, max_ttl_s, tls_spki, max_outstanding}`.
- CLI module and registration in `hermes_cli/main.py`: create, list, revoke (plus rendering of the QR payload).
- Enrollment hook into the U2 store when present.
- Docs: a pairing guide under `website/docs/guides/` next to `desktop-native-signin.md`.
- Tests: new `tests/hermes_cli/test_dashboard_auth_pairing.py`, plus cases in `test_dashboard_auth_gate.py` and `test_dashboard_auth_native_flow.py`.

## 8. Test plan

Unit and route tests (new file, with the existing `StubAuthProvider` and `PasswordProvider` fixtures):

1. Create returns well-formed fields (lengths, encodings), sets `exp` from the clamped TTL, and stores only a hash (inspect the file: no raw secret, mode 0600, atomic replace).
2. Redeem success returns the bearer payload, which then works for `/api/auth/me` and `/api/auth/ws-ticket`; the record is marked redeemed.
3. Replay: second redeem fails with the generic error; a concurrent pair of redemptions yields exactly one success (threads and a second process against the same file).
4. Expiry: use the patchable clock pattern; expired tokens fail generically.
5. Oracle checks: unknown id, wrong secret, expired, used, revoked produce byte-identical status and body; timing roughly equal (dummy compare).
6. Brute force: wrong secrets invalidate the record after the threshold; per-IP throttle returns 429; the global cap holds; a flood on unknown ids does not grow state.
7. Public-path behavior: only the redemption path is reachable unauthenticated; `/auth/pairing/redeem/x` is not; create, list and revoke require auth.
8. Provider without the new method: create is refused or the flag is not advertised; redeem fails closed.
9. Intent plus device key: active enrollment is created for the session principal and only on success; a failed redemption enrolls nothing.
10. SAS: published vectors for `decimal6`; gateway-side value stored; a simulated relay with a different key produces a differing value.
11. Audit: events present, no secret, no full id, redaction set updated.
12. Status: `pairing_token` appears only when enabled and supported; default off changes nothing.
13. Wrong-fingerprint clients: the gateway cannot test client pin checks, so the test is that the advertised and CLI-computed `spki` equals SHA-256 of the SPKI of a synthetic certificate, and that clients in the Fleet suite fail closed on a mismatching server (Fleet #123 tests).
14. Regression: password login, native flow and cookie sessions unchanged.

## 9. Alternatives considered

- **Keep putting a scoped password in the QR.** Current behavior; no expiry, no single use.
- **Plugin-only implementation.** Plugin dashboard routes sit behind dashboard auth and the public allowlist is fixed. A plugin can register a token provider and an exact token route (the drain plugin shows the mechanics), which may let a one-time secret act as the bearer for a redemption route, but minting a full `Session` (needed for `/api/auth/ws-ticket` and the native refresh flow) from a plugin looks infeasible without a provider hook. This is the open question in the Fleet #123 spike.
- **OAuth native flow for pairing.** Needs a browser round trip and an identity provider; does not fit password-only gateways (U1 is the OAuth path).
- **Device-code grant (RFC 8628).** Good UX for TV-like devices; adds polling endpoints and an approval page; more surface than a scanned one-time token.
- **Mutual TLS client certificates.** Heavy provisioning per self-hosted gateway; solves authentication but not the first-contact problem.
- **Operator types a code into the phone.** Human-typable entropy is too low for a public route (section 4.7).

## 10. Fleet without this proposal

Fleet never blocks on this.

- **#123 Phase A ships with no gateway change:** pairing payload v2 (`v: 2`) adds `exp`, `nonce` and `spki` to the existing v1 fields; the client refuses expired or future-dated codes, refuses a code it already consumed (local nonce memory), seeds its TLS pin store from `spki` so the first connection must match the fingerprint (mismatch fails closed, no trust-on-first-use prompt for v2 HTTPS codes), and v1 codes keep decoding behind a clear "legacy, less safe" warning. The generator script computes `spki` with OpenSSL and defaults `exp` to 120 s.
- **What Phase A cannot do:** server-enforced single use and expiry. A photographed v2 QR stays usable until `exp` for anyone who has it, and the embedded password is still reusable by the gateway's normal rules after that. Operators should still use a dedicated low-privilege credential per pairing, as `docs/gateway-pairing.md` advises.
- **#123 Phase B (plugin) is only attempted if the spike finds a pre-auth or token-authenticated route.** The observation in section 9 is input to that spike, not a conclusion.
- **U2 dependency:** device-key enrollment during pairing is reserved in #123 (a device key thumbprint field) and works client-side without this proposal; gateway-side activation waits on U2 or the plugin.
- **Relay and push (#157, PR #160):** unaffected. Pairing tokens do not touch the push registration path, which already uses the authenticated gateway connection.

## 11. Field alignment with Fleet #123

| Topic | #123 | This draft |
| --- | --- | --- |
| Payload version | `v: 2` | Not defined by the gateway; the create response uses the same key names so a client can build the payload. |
| Expiry | `exp`, Unix seconds | `exp`, server-set, Unix seconds. |
| Replay nonce | `nonce`, 16 or more random bytes, base64url | `nonce`, 128-bit random, base64url; also the SAS key. |
| Fingerprint | `spki`, SHA-256 of the SPKI, base64, required for `https` | `spki`, same value and encoding as #123 defines; may be `null` when the gateway or operator cannot provide it (#123 marks it required for `https`, so a `null` forces the legacy trust-on-first-use path and a visible warning). |
| One-time secret | Phase B: `code_id` plus one-time secret | `code_id` and `secret`; Phase A keeps `username` and `password`. |
| SAS | `HMAC(nonce, gateway-spki \|\| device-key-thumbprint)`, six digits | Same inputs; adds a fixed truncation rule and each side computes independently. #123 should adopt the truncation and test vectors, or this draft follows #123's. |

## 12. Open questions for the maintainers

1. CLI naming and whether creation should be CLI-only at first.
2. Is route-level scoping of the resulting credential wanted in v1? Today a `Session` carries no scope.
3. Should strict SAS confirmation be part of the first version?
4. Should the store be shared with the U2 device-key store or separate?
5. Is a provider hook (`mint_session_for_pairing`) acceptable, or should pairing mint its own token type through the token seam (which would not satisfy `/api/auth/ws-ticket` today)?

## Drafting notes for Fleet maintainers (remove before filing)

- The planning issue (#152) describes the SAS as a "server-provided value". A server-supplied value proves nothing against a relay, so this draft has each side compute independently and the server supply the nonce and the operator display (section 4.6). #123 already words it as an HMAC over each side's inputs, so the two are consistent; only the issue summary differs.
- The planning issue says the redemption route is "added to the public-path allowlist". In the source there are two lists; the credential-accepting auth routes live in `_GATE_PUBLIC_PREFIXES`, not `PUBLIC_API_PATHS` (section 4.8).
- The planning issue does not mention that the gateway usually cannot know its TLS certificate (the server has no TLS configuration and runs behind a terminator); the fallback order in section 4.5 addresses it.
- Plugin feasibility for #123 Phase B: a plugin can register a token provider and an exact token route (hermes-agent: `plugins/dashboard_auth/drain/__init__.py` shows both), which is promising for receiving a pre-credential redemption. The likely blocker is minting a full `Session` afterwards. This is an input to the #123 spike, not a result.
- Not validated: nothing here was run against a live gateway; the design is derived from source reading only.
