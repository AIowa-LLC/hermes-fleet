# Add to Fleet: secure device pairing

Add to Fleet lets the owner of a Hermes gateway add it to their phone while away
from the computer, without ever putting a username, password or long-lived token
in a link. The phone ends up with its own **device credential**, stored in
Keychain, which the owner can revoke at any time.

The existing options are unchanged: **Add Gateway** still takes an address and
sign-in by hand, and **Scan Pairing Code** still reads the older username/password
QR (see [gateway-pairing.md](gateway-pairing.md)). Add to Fleet is a third, safer
way to do the same job when the owner can reach any authenticated Hermes surface.

## What the owner sees

1. On any signed-in Hermes surface, the owner asks for a pairing invitation. Today
   that is the authenticated dashboard API (`POST /api/fleet/pairing/invitations`)
   or the host command `python -m hermes_cli.fleet_pairing_cli invite`.
2. They receive a link such as `https://<gateway-host>/pair#v=1&i=<id>&s=<secret>`
   and open or paste it on the phone (or scan a QR code of it).
3. Hermes Fleet shows **which gateway** (its name and exact address) and **what
   access** is requested, in the app's own wording, and waits.
4. Only after the person taps **Add to Fleet** does the phone exchange the
   invitation for a device credential, pin the gateway's TLS key, and save the
   credential in Keychain.

Cancelling at step 3 changes nothing: the invitation is still unused until it
expires or the owner cancels it.

## What the link is

| Property | Value |
| --- | --- |
| Lifetime | 60 s to 15 min (default 10 min), enforced by the gateway |
| Use | Exactly once; redemption is one atomic database transaction |
| Scope | One origin (`https://host[:port]`); presented to any other host it is "invalid" and is not consumed |
| Secret | 256-bit random value in the URL **fragment** (never sent to a server by a browser), 128-bit id; the gateway stores only SHA-256 digests |
| Guessing | A wrong secret for a known id counts a failure; five lock the invitation; the response for an unknown id, a malformed id and a wrong secret is identical |
| State leakage | "expired", "already used" and "cancelled" are revealed only to someone who proves the secret |
| Rate limits | Per client address on preview, redeem and device login |

Opening, parsing or previewing a link never consumes it or approves anything: the
preview request mutates nothing (it only counts wrong-secret attempts).

## Destination and identity checks

On the phone, before any network access:

- the link must be `https`, on a real DNS name: no IP literals, `localhost`,
  single-label hosts, user-info, query strings, non-ASCII (look-alike) hosts or
  paths other than `/pair`;
- plain `http` links, other schemes and pairing-link versions the app does not
  know are refused with a specific message and **nothing is contacted**.

On the connection:

- TLS must validate against the system trust store for that exact host. There is
  no override and no trust-on-first-use for the secret-bearing requests.
- Redirects are refused (a redirect could carry the secret elsewhere), responses
  are size-capped, no cookies or caches are used, and each request uses a fresh
  connection.
- The gateway reports its stable **installation id**, name and origin. The origin
  must equal the link's. The key (SPKI) seen at preview is **required during the
  TLS handshake of the redemption**: if it changed, the handshake is cancelled
  before the request body, and therefore the secret, is sent.
- The access the invitation asks for must be one the app understands
  (`fleet:operator` today); unknown access is refused. The text shown to the
  person is the app's own, never server-supplied prose.

## What the phone keeps

The phone registers the gateway under an identity derived from the gateway's
installation id (`gw-<id>`), so reaching the same gateway through a new address
does not create a second entry. Before redeeming, the app also checks for an
existing gateway with the same id **or the same address** (for example one added
by hand) and, if found, reports "already in Fleet" without using the invitation.

The device credential is saved in Keychain with the gateway, and the TLS key that
was validated during pairing is the key approved for pinning. If saving fails
after the gateway accepted the redemption, the new device is revoked on the
gateway, nothing stays registered, and the person is told nothing was added.

A removed gateway never returns by itself (no refresh, reconnect, restart or
background restore re-adds it). Adding it again is a deliberate act: a new
invitation, confirmed on screen.

## Signing in afterwards

A paired phone exchanges its credential at `POST /auth/device-login` for a
short-lived session cookie, then uses the normal WebSocket ticket and REST paths.
The gateway registers a hidden `fleet-device` session provider, so no other API
needed to change. A paired device **cannot** create invitations or list, revoke or
manage other devices; only a signed-in owner can.

## Revocation

- **From the owner:** `DELETE /api/fleet/devices/<id>` or
  `python -m hermes_cli.fleet_pairing_cli revoke <id>`. Live sessions stop on their
  next request.
- **From the phone:** removing the gateway asks the gateway to revoke this
  device (`POST /auth/device-revoke`) after the local removal. If the gateway
  cannot be reached the person is told the revocation was **not confirmed** and
  that the device should be revoked from the gateway's device list.

## Logging and secrets

The invitation secret, the link, device credentials and session tokens are never
logged, never put in an error message, and never persisted outside Keychain (the
link lives in memory only while the flow is open). The gateway's audit log records
short identifiers and outcomes only. Printable forms of the link, secret, grant and
credential are redacted on the phone.

## Failure handling

| Situation | What the person sees |
| --- | --- |
| Not a pairing link | "That isn't a pairing link", with what a link looks like |
| `http`, IP or look-alike host | "This link can't be trusted"; nothing contacted |
| Newer link version | "Update Hermes Fleet" |
| Expired / used / cancelled / unknown | A separate title and explanation each |
| Phone offline or gateway unreachable | "Can't reach the gateway", saying a link does not create a network path, with **Try Again** on the same link |
| Certificate not trusted | "Gateway certificate not trusted"; nothing sent |
| Gateway identity changed mid-way | "The gateway changed"; nothing sent |
| Older gateway without pairing | "Pairing isn't available here", pointing to manual setup |
| Canceled before confirming | Nothing changes; the link still works |
| Connection lost during redemption | "Pairing was interrupted"; ask for a new link |

## Prerequisites to use it for real (not done by this change)

1. **Deploy the gateway side.** The server work is a separate, locally committed
   branch of hermes-agent (`feature/fleet-device-pairing`). It has not been pushed,
   merged or deployed anywhere. Until a gateway runs that code, pairing links
   report "Pairing isn't available here". It needs the dashboard auth gate
   engaged and `dashboard.public_url` set to the gateway's `https` origin on a real
   hostname with a publicly trusted certificate.
2. **Network reachability.** A link does not create a path to the gateway. The
   phone must reach it (internet, VPN or same network).
3. **Universal Links (optional, makes tapping a link open the app).** This needs
   three things that touch the Apple developer account and the gateway's domain
   and were deliberately **not** done:
   - the *Associated Domains* capability enabled on the Dev App ID, and a
     regenerated provisioning profile;
   - the entitlement `com.apple.developer.associated-domains` =
     `applinks:<gateway-host>` added to the Dev entitlements (the host is a build
     input, not committed);
   - the gateway serving `/.well-known/apple-app-site-association` for the app id
     (`HERMES_FLEET_PAIRING_APP_IDS=<TeamID>.<bundle id>` enables it).
   Without these, opening a link in a browser shows a short page with a
   **Copy link** button, and the person pastes it into **Add with Pairing Link**
   (or scans its QR). The in-app flow is identical.
4. **Trusted remote issuance** (asking for an invitation from chat on another
   surface, such as a messaging channel or the agent) is deferred. It needs an
   owner-identity and approval decision for each channel and is not part of the
   smallest secure version.

A custom URL scheme is deliberately **not** accepted for pairing links: another
app can register the same scheme and read the link, and the secret is the whole
capability. The simulator-only test seam that injects a link for UI tests is
compiled out of device builds.

## Evidence

See the verification record in the build 6 receipt. In short: server security
properties and a real TLS integration run (including 16 simultaneous
redemptions); the phone client against genuine TLS servers (untrusted
certificate, key change, redirects, oversized and hostile responses); the Swift
client end to end against the real gateway code; coordinator and host behavior;
and UI flows for cold launch and an already-running app. Real-device and
Universal Link behavior are **not** covered by those and are listed as untested.
