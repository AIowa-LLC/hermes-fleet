# U1 - Operator-approved app-scheme redirect for native OAuth sign-in

| | |
| --- | --- |
| Status | DRAFT. Not filed anywhere. Filing is a maintainer decision (see [README](README.md)). |
| Fleet tracking | Hermes Fleet #150 (epic #76). Unblocks, but is not required by, #61 (gateway-approved OAuth sign-in). |
| Upstream baseline | hermes-agent `30de041b01` (main as last fetched, 2026-09-19). All paths below were re-read at drafting time on 2026-09-30. See [README](README.md#verification-baseline). |
| Prior art found | An open upstream issue (hermes-agent #94733, "Dashboard native auth: allow configured private-use callbacks for iOS") already requests essentially this contract. **Recommendation: do not file a duplicate.** Use this text as a supporting comment on that issue, or as the body of a new issue only if the maintainer finds it closed or unanswered. |
| Assumptions | Upstream contribution norms were not verified beyond `CONTRIBUTING.md` (search first, widen generic surfaces rather than special-casing a client). Venue and format are left to the maintainer. Apple API details are stated from general platform knowledge and should be re-checked against Apple documentation at filing time. |
| Filing note | Sections 11 and 12 and the drafting notes are Fleet-internal context. Condense or drop them when filing. |

## 1. Summary

The gateway's RFC 8252 native sign-in (`/auth/native/*`) accepts only an
`http://127.0.0.1` or `http://[::1]` loopback `redirect_uri`. An iOS app using
`ASWebAuthenticationSession` cannot complete that flow, because the session
finishes only when the browser navigates to the callback it was started with (a
registered private-use URL scheme, or on recent iOS an https host and path).

Proposal: add an operator-configured, **exact-match allowlist** of additional
native redirect URIs (private-use scheme or claimed https URLs), consulted in
addition to the loopback rule. Default empty, so current behavior is unchanged.
Everything else in the flow (S256 PKCE, `state` echo, 120 s single-use code,
bearer and refresh tokens, audit events) is reused as is.

## 2. Problem statement (mobile-client perspective)

Hermes Fleet is an iPhone client for user-chosen Hermes gateways. Today it can
sign in only with username and password (`POST /auth/password-login`). A gateway
whose only interactive provider is an OAuth/OIDC provider cannot be used from
the phone at all: the app has no supported browser flow to call (Fleet #61).

The upstream native flow is the right shape for a phone: system browser,
PKCE, no cookies in the app, rotating refresh tokens, WebSocket upgrade by
single-use ticket. Only the final hop is wrong for iOS:

- iOS apps do not run a reliable long-lived loopback listener for a browser
  sheet to navigate to. More importantly, `ASWebAuthenticationSession` completes
  (dismisses itself and hands the app the URL) only when navigation matches the
  callback registered at session creation: a `customScheme` callback, or (iOS
  17.4 and later) an `https` callback with host and path. A navigation to
  `http://127.0.0.1:<port>/...` does not complete the session, so the sheet
  stays open until the user dismisses it.
- RFC 8252 describes both iOS-compatible options: a private-use URI scheme
  (section 7.1) and a claimed `https` redirect (section 7.2). Both need the
  authorization server to accept a non-loopback `redirect_uri`.
- A claimed https redirect bound to the gateway's own origin does not work for a
  multi-server client: the app cannot hold associated-domain entitlements for
  arbitrary self-hosted origins. A private-use scheme registered by the app (or
  a claimed https URL on the app publisher's own domain) is the practical path.

## 3. Current upstream behavior (verified)

All rows are `hermes-agent: <path>` references at the baseline above.

| Claim | Evidence |
| --- | --- |
| Only loopback redirects are accepted. `_validate_loopback_redirect_uri(raw)` requires scheme `http` and hostname `127.0.0.1` or `::1`; `localhost` is rejected per RFC 8252 section 8.3. The docstring states the security reason: the route is public, so a non-loopback host would be an open redirect that leaks a live code. The function returns `raw` unchanged. | hermes-agent: `hermes_cli/dashboard_auth/routes.py` (`_validate_loopback_redirect_uri`) |
| Validation runs before any broker state is allocated: `auth_native_authorize` checks `code_challenge_method` is `S256`, requires `code_challenge`, calls `_validate_loopback_redirect_uri(redirect_uri)`, and only then `native_flow.register_pending(...)`. | hermes-agent: `hermes_cli/dashboard_auth/routes.py` (`auth_native_authorize`) |
| The pending entry stores `redirect_uri` and the client `state`. The final redirect is built as `redirect_uri` + (`&` or `?`) + `urlencode({code, state})` and returned as a 302 (OAuth callback) or as the `next` field of the password-login JSON response (native broker handle in the PKCE cookie). | hermes-agent: `hermes_cli/dashboard_auth/routes.py` (`_finish_native_login`, `auth_callback`, `auth_password_login`); hermes-agent: `hermes_cli/dashboard_auth/native_flow.py` (`_Pending`) |
| Code lifecycle: 256-bit URL-safe code, TTL 120 s (`_CODE_TTL_SECONDS`), popped before the PKCE check so a wrong verifier cannot be retried, constant-time challenge compare, capacity and per-IP pending caps. The `_Pending.redirect_uri` comment describes it as the desktop's loopback redirect. | hermes-agent: `hermes_cli/dashboard_auth/native_flow.py` (`register_pending`, `complete_pending`, `redeem_code`) |
| Token exchange and rotation: `POST /auth/native/token` (code plus verifier to bearer tokens, no cookie), `POST /auth/native/refresh` (rotation), `POST /api/auth/ws-ticket` (30 s single-use WebSocket ticket, bearer-authenticated). | hermes-agent: `hermes_cli/dashboard_auth/routes.py` (`auth_native_token`, `auth_native_refresh`, `api_auth_ws_ticket`); hermes-agent: `hermes_cli/dashboard_auth/ws_tickets.py` |
| The routes are public: `/auth/native/authorize`, `/auth/native/token`, `/auth/native/refresh` are in `_GATE_PUBLIC_PREFIXES`. | hermes-agent: `hermes_cli/dashboard_auth/middleware.py` |
| Capability discovery exists: the public status endpoint returns `auth_flows`, containing `cookie` in gated mode and `native_pkce` when at least one interactive session provider is registered. An absent field means an older gateway. | hermes-agent: `hermes_cli/web_routers/status.py` (`_auth_gate_status`); hermes-agent: `website/docs/guides/desktop-native-signin.md` (capability table) |
| Password providers also work with the native flow: authorize redirects to `/login` with the broker handle in the PKCE cookie, and the login form's script navigates with `window.location.assign(data.next)`. | hermes-agent: `hermes_cli/dashboard_auth/routes.py`; hermes-agent: `hermes_cli/dashboard_auth/login_page.py` |
| The provider chooser page embeds the requested `redirect_uri` in links through `urlencode` plus `html.escape`. | hermes-agent: `hermes_cli/dashboard_auth/login_page.py` (`render_native_provider_choice_html`) |
| Audit events for the flow already exist: `NATIVE_AUTHORIZE_START`, `NATIVE_CODE_ISSUED`, `NATIVE_TOKEN_SUCCESS`, `NATIVE_TOKEN_FAILURE`; `code`, `state`, tokens and verifiers are in the redaction set. | hermes-agent: `hermes_cli/dashboard_auth/audit.py` |
| The documented flow is desktop-only (loopback listener, PKCE, bearer plus WebSocket ticket). | hermes-agent: `website/docs/guides/desktop-native-signin.md` |
| Existing tests: `test_native_authorize_rejects_non_loopback_redirect` (asserts a 400 for an https redirect), the `_walk_native_login` helper, `test_status_advertises_native_pkce_for_password_only_gateway`. | hermes-agent: `tests/hermes_cli/test_dashboard_auth_native_flow.py` |

Fleet side (this repository): `Packages/FleetNetworking/Sources/FleetNetworking/PasswordLogin.swift`
is the only login path; there is no `ASWebAuthenticationSession` use (Fleet #61).

Related upstream threads found by read-only search on 2026-09-30 (discovery
pointers only, not contract): hermes-agent #94733 (same request, open; also asks
that refresh be routed only to the provider named at token redemption and for a
same-origin native logout route) and hermes-agent #118055 (open; behind a
path-prefix reverse proxy the login page posts to the origin root, so the PKCE
cookie path never matches and native sign-in cannot complete, which would also
affect an iOS client on such deployments).

## 4. Proposed design

### 4.1 Configuration

A list of exact redirect URIs under the dashboard config, empty by default:

```yaml
dashboard:
  native_auth:
    redirect_uris: []          # exact-match allowlist, in addition to loopback
    # example entries (synthetic):
    #   - "com.example.app:/oauth/callback"        # private-use scheme, RFC 8252 7.1
    #   - "https://app.example.com/hermes/callback" # claimed https, RFC 8252 7.2
```

An environment override (for example `HERMES_DASHBOARD_NATIVE_REDIRECT_URIS`,
comma separated) follows the existing `HERMES_DASHBOARD_*` convention. Names are
suggestions; the maintainers own naming.

Entries are validated once at startup and invalid entries are dropped with a
warning (fail closed):

- Private-use entry: scheme contains at least one dot (reverse-domain, RFC 8252
  section 7.1), has a non-empty path, no authority (`scheme:/path` form), no
  query, no fragment, no userinfo.
- Claimed https entry: `https` scheme, host and path present, no query, no
  fragment, no userinfo, no wildcard characters.
- Never accepted: `javascript`, `data`, `file`, `blob`, `about`, `http` with a
  non-loopback host, and any entry that would also match the loopback rule.

### 4.2 Validation

Rename `_validate_loopback_redirect_uri` to a neutral `_validate_native_redirect_uri`
(keep the old name as an alias for plugin compatibility) and apply:

1. If the loopback rule accepts `raw`, return it (behavior byte-for-byte unchanged).
2. Else, if `raw` equals a configured entry by **exact string comparison**
   (no normalization, no prefix, no case folding of path, no wildcard), return it.
3. Else 400, with the existing message extended to say non-loopback redirects
   must be operator-approved (keep the word "loopback" in the detail: the
   existing test asserts on it).

This still happens before `native_flow.register_pending`, so a rejected request
allocates no state.

### 4.3 What does not change

- `code_challenge_method` must still be `S256` for every redirect type. (It is
  already mandatory for all native requests; the proposal keeps it explicit in
  the test plan so a future relaxation for loopback cannot leak to app URIs.)
- `state` is echoed unchanged in the final redirect.
- Code TTL (120 s), single use, popped-before-verify semantics, per-IP and global
  caps.
- The upstream identity provider keeps redirecting to the gateway's own https
  `/auth/callback`; only the gateway's final redirect targets the allowlisted URI.
- No token ever appears in the redirect URL. The URL carries only the one-time
  code and `state`.
- Audit events are reused. Optionally add a `redirect_kind` field
  (`loopback`, `private_use`, `https_claimed`) to `NATIVE_AUTHORIZE_START`; never
  log the URI query.

### 4.4 Capability discovery

Add `native_app_redirect` to `auth_flows` in `_auth_gate_status()` when the
allowlist is non-empty (and `native_pkce` is advertised). Advertise the flag
only, not the URIs. A client that does not see the flag must not start an
app-scheme flow and falls back to its existing login path. A client that sees
the flag but is rejected (its own URI is not listed) gets the 400 above, which
the app surfaces as "this gateway has not approved this app's redirect".

Older gateways: no flag and, if a client tries anyway, the existing 400 with no
state allocated. There is no downgrade risk.

## 5. Backward compatibility

- Default empty list: no behavior change for any existing deployment, test, or
  the desktop client.
- Loopback handling, response shapes, cookies and audit log lines are unchanged
  for loopback requests.
- `auth_flows` gains a value only when configured. Clients that match known
  strings ignore the new value; this was not verified against the Desktop client
  source and should be checked before filing.
- Plugins importing the old validator name keep working through the alias.

## 6. Security analysis

| Risk | Mitigation |
| --- | --- |
| Open redirect leaking a live code | Exact match against an operator-controlled list, checked before any state exists. No wildcards, no user-supplied hosts, no normalization. The public route never reflects an unlisted URI, including in the chooser page. |
| Private-use scheme hijack: another app on the device registers the same scheme and receives the callback | The callback carries only a one-time code and `state`. Redeeming needs the PKCE verifier that never left the app, so an intercepted code is useless. Code TTL is 120 s and single use. Require reverse-domain schemes (collision resistance) and document that operators should use an app-specific scheme. Prefer the claimed https option where the client platform supports it. |
| Claimed https option: a navigation that is not intercepted by the app lands on the publisher's web server | The URL contains only the one-time code and `state`, protected by PKCE as above. The publisher's landing page should be static and log nothing from the query. Operators only allowlist URLs on domains they trust. |
| Scheme confusion via dangerous schemes (`javascript:`, `data:`) | Startup validation drops them; exact match means they can never be requested. |
| Fragment or credentials smuggling | Rejected at config validation; the final redirect is built from the stored exact string plus `code` and `state`. |
| Code replay or verifier oracle | Unchanged: code popped before PKCE check, constant-time compare, generic 400. |
| Log leakage | `code`, `state`, tokens and verifiers are already stripped by `audit_log`. The new `redirect_kind` field carries no query. |
| Downgrade by a network attacker stripping the capability flag | A client that does not see the flag simply uses its existing path; nothing weaker is offered. |

## 7. Minimal patch sketch

All files are hermes-agent paths.

- `hermes_cli/dashboard_auth/routes.py`: generalize `_validate_loopback_redirect_uri` as described in 4.2; call sites unchanged (`auth_native_authorize`, chooser rendering).
- `hermes_cli/dashboard_auth/native_flow.py`: no functional change. Update the `_Pending.redirect_uri` comment to say loopback or allowlisted app redirect.
- `hermes_cli/config_defaults.py`: add the `dashboard.native_auth.redirect_uris` default (empty list) with a comment block, plus the env override read.
- `hermes_cli/web_routers/status.py`: `_auth_gate_status()` appends `native_app_redirect` when configured.
- `hermes_cli/dashboard_auth/audit.py` (optional): `redirect_kind` field on `NATIVE_AUTHORIZE_START`.
- `website/docs/guides/desktop-native-signin.md`: new "App redirects (mobile)" section, extend the capability table, and warn about scheme collisions.
- `tests/hermes_cli/test_dashboard_auth_native_flow.py`: new tests below.

Estimated size: about 60 lines of source, about 150 lines of tests and docs.

## 8. Test plan

Extend `tests/hermes_cli/test_dashboard_auth_native_flow.py` (existing fixtures `gated_client`, `pw_gated_client`, `_make_pkce`, `_walk_native_login`). The cases mirror the acceptance tests requested in hermes-agent #94733 so the two stay consistent.

1. Configured private-use URI: authorize starts the provider flow; the callback 302 `Location` starts with exactly the configured URI and carries `code` and `state`; no session cookie is set on the native callback.
2. Configured claimed-https URI behaves the same.
3. Rejected before `register_pending` (assert the pending store is unchanged): unlisted scheme, unlisted host, path variation, query variation, added fragment, lookalike prefix and suffix, different case of the scheme, trailing slash differences.
4. Config validation: entries with dangerous schemes, userinfo, fragments, wildcard characters, single-label private schemes, and entries overlapping the loopback rule are dropped with a warning and never match.
5. PKCE: `code_challenge_method=plain` or missing challenge is rejected for app URIs; an intercepted code cannot be redeemed with a wrong verifier; replay and expiry fail.
6. Password provider path (`pw_gated_client`): `POST /auth/password-login` returns the allowlisted URI in `next`; wrong password keeps the pending entry.
7. Provider denial or error issues no native code.
8. Chooser page (multiple providers) carries the allowlisted URI through each link, HTML-escaped, and never echoes an unlisted one.
9. `/api/status`: `native_app_redirect` present only when configured and `native_pkce` is advertised; absent in loopback mode; empty list changes nothing (extend `test_status_loopback_mode_has_no_auth_flows` style assertions).
10. Loopback IPv4 and IPv6 tests unchanged and green.
11. Audit: no `code`, `state`, verifier, token or query string in the log for the new paths.

## 9. Reference client sequence (mobile app)

Synthetic names throughout.

1. `GET https://gateway.example.com/api/status`. Require `native_pkce` and `native_app_redirect` in `auth_flows`; otherwise use the existing login path.
2. Generate a PKCE verifier (43 to 128 URL-safe characters), its S256 challenge, and a random `state`.
3. Start `ASWebAuthenticationSession` at
   `https://gateway.example.com/auth/native/authorize?code_challenge=<S256>&code_challenge_method=S256&redirect_uri=com.example.app:/oauth/callback&state=<state>` (add `provider=<name>` when several providers exist), with the matching `customScheme` callback (or an `https` host and path callback for a claimed-https entry).
4. The session returns `com.example.app:/oauth/callback?code=<code>&state=<state>`. Verify `state` equals the one sent; discard on mismatch.
5. `POST /auth/native/token` with `{code, code_verifier}` to receive `{access_token, refresh_token, token_type, expires_at, provider, user_id}`.
6. Store tokens in the Keychain as this-device-only items. Authenticate REST with `Authorization: Bearer`.
7. For the conversation WebSocket, `POST /api/auth/ws-ticket` with the bearer token, then upgrade with the returned single-use ticket (30 s).
8. Refresh with `POST /auth/native/refresh` using the refresh token and the provider name returned at step 5; on 401 `session_expired`, restart at step 1.

## 10. Alternatives considered

- **Claimed https redirect on the gateway's own origin (RFC 8252 7.2).** Needs the app to hold an associated-domain entitlement per gateway origin; impossible for arbitrary self-hosted gateways. Kept only as the allowlist variant on the app publisher's domain.
- **Keep loopback and run an in-app listener.** The browser sheet does not complete on an http navigation, the listener must outlive app backgrounding, and it is fragile. Rejected.
- **Wildcard or scheme-only allowlist.** Turns the public authorize route into a code-leaking open redirect. Rejected.
- **Accept any private-use scheme (no operator list).** Same open-redirect class; any local app could register the scheme and capture codes without operator consent. Rejected.
- **Device-code grant (RFC 8628).** Avoids redirects but needs a second device flow and new endpoints; larger than this change and unrelated to the existing broker.
- **Non-browser credential entry (paste a token).** Already possible through password login; does not solve OAuth-only gateways.

## 11. Fleet without this proposal

Fleet does not wait for this.

- Password login (`/auth/password-login`) and pairing (Fleet #123, S1) remain the supported ways to add a gateway.
- OAuth-only gateways stay unsupported in Fleet until a supported flow exists. The limitation is tracked in #61 and epic #73 (upstream capabilities) and is surfaced in-app as a fail-closed "unsupported provider" error rather than a silent failure.
- If upstream accepts this (or the equivalent in hermes-agent #94733), Fleet adds a client that gates on `native_app_redirect`, following the sequence in section 9, without changing the password path.

## 12. Open questions for the maintainers

1. Preferred config name and whether https (claimed) entries should ship in the first version or follow later.
2. Whether the refresh-provider binding and native logout route requested in hermes-agent #94733 belong in the same change.
3. Whether an iOS client on a path-prefixed reverse proxy is in scope given hermes-agent #118055.
4. Device validation of the `window.location.assign` navigation to a private-use URL inside `ASWebAuthenticationSession` has not been performed by Fleet; it should be tested on a device before relying on the password-provider path.

## Drafting notes for Fleet maintainers (remove before filing)

- **Existing upstream request.** hermes-agent #94733 already asks for the allowlist contract (found by read-only search on 2026-09-30; state may have changed). Prefer supporting it over a duplicate filing. This draft adds: the `auth_flows` capability value, the validation rules for claimed-https entries, the password-provider path, and a reference client sequence.
- **Capability discovery.** The planning issue (#150) suggested a field on `/api/auth/providers` or on the authorize response. The source already has a capability advertisement: `auth_flows` on the public status endpoint (`native_pkce`). This draft extends that instead of inventing a new surface.
- **Fleet code facts.** Fleet has no `ASWebAuthenticationSession` use in source today; PR and issue references for the client side are #61 and epic #73. Fleet work for #61 does not wait on upstream.
- Not validated: nothing here was run against a live gateway or a device.
