# Hermes push relay

A small, content-blind Apple Push Notification (APNs) relay for Hermes Fleet,
written as a Cloudflare Worker that fits the free tier.

Upstream Hermes has no mobile push transport, and APNs delivery for an App
Store bundle ID needs the app publisher's `.p8` signing key, which a gateway
cannot hold. The relay is the one component that holds that key. Everything it
forwards is opaque to it.

```text
 Hermes gateway            push relay (this Worker)             Apple
 (sender plugin)     ┌────────────────────────────────┐
   sealed payload ──▶│ authenticate capability        │
   + title_key       │ rate limit, size cap, expiry   │──▶ APNs ──▶ device
                     │ fixed alert copy + ciphertext  │             │
                     │ stores: sealed token, cap hash │             ▼
                     └────────────────────────────────┘   Notification Service
                                                          Extension opens the
                                                          sealed payload
```

Status: this directory contains the relay service, its tests, an OpenAPI spec
and the deployment documentation. The gateway sender, device registration and
the Notification Service Extension are separate work that consume this API.
Deploying the Worker and holding the APNs key are maintainer-only steps (see
the [checklist](#maintainer-only-deployment-checklist)).

## What the relay does and does not see

| Sees | Cannot see |
| --- | --- |
| APNs device token (sealed at rest, plaintext in memory while forwarding) | Message, approval, or session content |
| Send timing and payload size | Which gateway sent a notification |
| Coarse alert category (`approval`, `clarify`, `done`, `cron`) | Gateway addresses or credentials |
| Client IP address (Cloudflare edge; used for rate limiting only) | Anything inside `ciphertext` (sealed to the device's key) |

Persisted per registration: a keyed hash of the device token (for idempotent
upsert), the device token sealed with AES-256-GCM, a keyed hash of the send
capability, environment, bundle id, the registration's key id (sealed together
with the token), and an expiry. All
entries carry a TTL and can be deleted by the device.

## API

The full contract is in [`openapi.yaml`](openapi.yaml). Summary:

| Endpoint | Auth | Purpose |
| --- | --- | --- |
| `POST /v1/register` | none (rate limited); optional `Bearer` capability to refresh | Idempotent upsert. Returns `relay_device_id`, `expires_at`, and on first registration a `send_capability`. |
| `POST /v1/send` | `Bearer` send capability | Forward one sealed notification. |
| `POST /v1/liveactivity/register` | `Bearer` send capability | Store a push-to-start or update token. |
| `DELETE /v1/register/{relay_device_id}` | `Bearer` send capability | Unregister (gateway removal, panic switch). |
| `GET /healthz` | none | Configuration/liveness check. |

Design points that matter to integrators:

- **Fixed copy.** `alert` accepts only `title_key`. Visible text comes from the
  table in `src/config.ts`. Unknown fields are rejected, so free text cannot be
  smuggled through.
- **Payload shape.** The APNs payload carries `aps` plus `{"hf": {"v": 1, "ct": "<ciphertext>"}}`
  (alerts use `mutable-content: 1` so the Notification Service Extension can
  rewrite the body). Payloads over 3.5 KB are refused with `413`.
- **Capability.** 256 random bits, base64url, returned once and stored only as
  an HMAC. The app keeps it in the Keychain and gives it to the sender.
- **Replay bound.** `expiry` (unix seconds) must be in the future and at most
  24 hours ahead. It is forwarded as `apns-expiration`.
- **Typed cleanup.** APNs `410` deletes the registration and returns
  `410 unregistered` so the sender stops. A live-activity `410` drops only that
  token (`activity_unregistered`).
- **Idempotent register.** A registration's identity is (environment, bundle
  id, device token, `relay_key_id`). Presenting the current capability with the
  same identity performs no KV write until half the TTL has elapsed. The same
  identity *without* the capability rotates it (lost-capability recovery).
- **One registration per gateway.** `relay_key_id` must be a random value of at
  least 128 bits (22+ base64url characters) chosen by the device, one per
  gateway (or a hash of the per-gateway push public key). Each gateway
  therefore gets its own `relay_device_id` and capability, and removing one
  gateway never affects another. A short or guessable key id is rejected.
- **Relay URL is per registration.** The app chooses which relay to register
  with and passes the relay base URL, `relay_device_id`, and capability to that
  gateway's plugin at registration. The plugin has no global relay setting; one
  device can use different relays for different gateways.
- **De-registration.** When a gateway is removed or de-registered, the gateway
  plugin should call `DELETE /v1/register/{relay_device_id}` with the
  capability it holds. The call is idempotent (`204` even if already gone), so
  the app may also issue it (for example from a panic switch) without
  coordination.
- **A push is never authoritative.** The foreground gateway connection remains
  the source of truth; the relay is best effort delivery.
- Live-activity `start`/`update`/`end` forwarding is provisional until its
  consumer lands; the sealed `content-state` is `{"ct": ...}` and no visible
  copy other than `title_key` is ever added.

## Withdrawing a notification answered elsewhere

When an approval or question is answered on another device (or at the
gateway), the gateway can retract the notification that is already on this
device:

1. The original alert was sent with `collapse_id: "<opaque id>"`.
2. The gateway sends a second `POST /v1/send` with `push_type: "background"`,
   `priority: 5`, **no** `alert`, the **same** `collapse_id`, a future
   `expiry`, and a `ciphertext` that seals a withdraw instruction (for example
   the request id) for the device.
3. The relay forwards it as a silent push (`content-available: 1`, APNs
   `apns-push-type: background`, `apns-priority: 5`, same `apns-collapse-id`).
   It cannot tell a withdrawal from any other background push, so the feature
   adds no metadata beyond what a background push already reveals.
4. The app wakes, opens the sealed payload, and removes the delivered
   notification whose identifier equals the collapse id. APNs may also
   coalesce a still-pending alert that shares the collapse id, but that is an
   optimisation, not a guarantee.

APNs requires background pushes to use priority 5; the relay rejects priority
10 for them. Delivery is best effort: iOS throttles background pushes and does
not wake an app the user force-quit, so the notification may remain. That is
safe by design: the gateway stays authoritative, and a stale approval is
refused when the app opens or when its sealed single-use token is presented.

## Free-tier budget

- Workers requests: 100k/day. Register is a no-write upsert on relaunch.
- Workers KV writes: 1,000/day. A new registration costs 2 writes (record +
  hash index); a live-activity token costs 1. Roughly 400 fresh installs/day
  fit alongside token churn. Reads are 100k/day; each send is 1 read plus 1
  read for the record. If you outgrow this, move `Registry` to D1 (a single
  file, `src/registry.ts`) or the paid plan.
- Rate limiting uses the Workers Rate Limiting binding, which does not write
  to KV. Limits: 120 requests/min per IP, 10 registrations/min per IP, 30
  sends/min per registration (per Cloudflare location; see the threat model).
- KV is eventually consistent (up to ~60 s across locations), so a send issued
  from another region immediately after register can briefly return
  `unknown_device`. Senders should retry with backoff.

## Develop and test

```sh
cd integrations/hermes-push-relay
npm ci
npm test            # vitest, fully offline: stubbed APNs, in-memory KV
npm run typecheck   # tsc --noEmit
```

Tests generate a throwaway P-256 key and storage key at runtime and never make
network calls; no fixture contains real key material. To try the Worker
locally, put your own *sandbox* values in an uncommitted `.dev.vars` (ignored
by `.gitignore`) and run `npx wrangler dev`.

`npm run bundle:dry-run` runs `wrangler deploy --dry-run`, which bundles and
validates `wrangler.toml` without contacting Cloudflare or deploying.

## Configuration

`wrangler.toml` deliberately contains no secrets, account IDs, KV namespace
IDs, routes, or hostnames. Runtime secrets:

| Secret | Value |
| --- | --- |
| `APNS_KEY_P8` | Full contents of the APNs auth key `.p8` file |
| `APNS_KEY_ID` | 10-character key ID of that key |
| `APNS_TEAM_ID` | 10-character Apple Developer Team ID |
| `APNS_TOPIC` | The app bundle ID (the only bundle the relay will register) |
| `RELAY_STORAGE_KEY` | 32 random bytes, base64: seals tokens at rest and keys the hashes |

Optional `[vars]`: `REGISTRATION_TTL_SECONDS` (default 60 days).

## Maintainer-only deployment checklist

These steps need the maintainer's Cloudflare and Apple accounts. They are not
performed by CI or by the automated lanes, and nothing here should be run with
credentials on a shared machine.

1. Cloudflare: use (or create) the account that will host the relay and run
   `npx wrangler login`.
2. Apple Developer: create an APNs Auth Key (Certificates, Identifiers &
   Profiles, Keys), download the `.p8` once, and note the Key ID and Team ID.
   Enable Push Notifications on the App ID and register the entitlement for
   the app (tracked with the device-registration work). Store the `.p8` in a
   password manager, never in the repository.
3. KV namespace: `npx wrangler kv namespace create REGISTRY`. Put the returned
   `id` in an uncommitted `wrangler.local.toml` (a copy of `wrangler.toml` with
   `id = "..."` under `[[kv_namespaces]]`) and deploy with `-c`, or let
   Wrangler auto-provision on first deploy. Do not commit the ID.
4. Set secrets (each command prompts for the value; nothing goes in shell
   history or a file):

   ```sh
   npx wrangler secret put APNS_KEY_P8
   npx wrangler secret put APNS_KEY_ID
   npx wrangler secret put APNS_TEAM_ID
   npx wrangler secret put APNS_TOPIC
   openssl rand -base64 32 | npx wrangler secret put RELAY_STORAGE_KEY
   ```

5. Deploy: `npx wrangler deploy`. Confirm `GET /healthz` returns `{"status":"ok"}`.
6. Verify in sandbox first: register a debug build's token with
   `environment: "sandbox"`, send an `alert`, and confirm the generic alert
   arrives. Then repeat with a TestFlight/App Store token and
   `environment: "production"`.
7. Confirm invocation logs are off (`wrangler.toml` sets
   `observability` and `invocation_logs` to false) and do not enable Logpush
   or tail-to-third-party for this Worker.
8. Record the public relay URL where the app and gateway plugin defaults are
   configured (never in this repository's fixtures).
9. Rotation: to rotate the APNs key, `wrangler secret put` the new
   `APNS_KEY_P8`/`APNS_KEY_ID` and redeploy; registrations are unaffected. To
   rotate `RELAY_STORAGE_KEY`, expect every registration to become
   unreadable: devices re-register on next launch.

Self-hosters follow the same steps with their own Apple account and bundle ID;
see [`docs/push-relay-self-host.md`](../../docs/push-relay-self-host.md).

## Threat model

Assets: message and approval content (must stay confidential), the ability to
approve actions (must not be forgeable), users' devices (should not be spammed),
the APNs key.

Trust: the gateway and the device trust each other through the existing
authenticated gateway connection and an end-to-end sealed payload. The relay is
treated as an untrusted courier that is allowed to break availability but not
confidentiality or integrity of content.

### Relay compromise

An attacker who controls the Worker code, its secrets, or its storage learns
device tokens, timing, payload sizes, alert categories and IP addresses. They
cannot read content: it is sealed to a key that only the device holds, and the
relay never receives plaintext or gateway credentials. They cannot forge an
approval: an approval is sealed by the gateway, carries its own expiry and a
single-use response token, and is honored only over the device's authenticated
gateway connection, never because a notification arrived. What they can do:

- Drop or delay notifications. The foreground connection remains authoritative,
  so this is an availability loss only.
- Send generic alerts (any `title_key`) with arbitrary bytes as `ct` to every
  registered device, using the APNs key. The Notification Service Extension
  cannot open bytes that were not sealed for it, so the visible text stays the
  generic copy. This is the spam case below.
- With `RELAY_STORAGE_KEY`, decrypt stored device tokens. Tokens alone do not
  permit sending without the APNs key.

Mitigations: rotate the APNs key and storage key (checklist step 9), and users
can self-host so the relay operator is themselves. A device compromise or a
gateway compromise is out of scope for the relay.

### Replay

- *Captured `/v1/send`*: TLS protects requests in transit. A request captured
  anyway can be replayed only until its `expiry`, which is capped at 24 hours
  ahead and enforced on every request, and each replay is rate limited. The
  result is a duplicate notification, not a duplicate action: the sealed
  payload carries its own expiry and single-use response token, and the
  receiver should de-duplicate by request id inside the sealed payload. The
  relay deliberately keeps no nonce store (it would spend KV writes and
  persist request-derived data).
- *Stolen capability*: it authorizes pushing generic alerts to one device.
  It does not expose content. The device rotates it by re-registering without
  presenting the old one, or revokes it with `DELETE /v1/register/{id}`.
- *Stolen device token*: not sufficient to send, and not sufficient to touch an
  existing registration. The registration identity includes the unguessable,
  sealed `relay_key_id`, so a party that knows only the token cannot rotate or
  hijack a registration (this closes the earlier rotate-by-re-register denial
  of service). It can, however, create a *separate* registration of its own and
  then push generic alerts to that device. Open registration is the residual
  spam exposure: the relay has no account or device attestation, so anyone who
  learns a device token can do this. Mitigations are the per-IP registration
  limit, fixed copy, and sealed payloads the device will not open; App Attest
  or a device-signed registration proof is a possible future hardening.
- *Leaked `relay_key_id`*: the holder of a token and key id can rotate that one
  registration's capability. Treat the key id like a secret shared only with the
  intended gateway.

### Spam and abuse

- Senders need the per-registration capability (256 random bits, compared in
  constant time against a keyed hash). There are no accounts to phish.
- Visible copy comes only from a fixed table; unknown fields are rejected.
  A compromised gateway cannot use the relay to display attacker-chosen text.
- Limits: 30 sends/min per registration, 10 registrations/min per IP, 120
  requests/min per IP, 8 KB request body, 3.5 KB APNs payload, 8 live-activity
  tokens per device. Bindings are enforced per Cloudflare location and are
  approximate; a distributed attacker can exceed them. Failing closed on a
  broken limiter binding avoids silently dropping protection.
- Exhausting the free-tier daily request or KV-write budget by flooding
  `register` is possible; the outcome is denial of service for new
  registrations, not data exposure. Cloudflare's platform DDoS protection and
  the per-IP limits bound the impact.

### Metadata and privacy

The relay, Cloudflare and Apple can observe that a device receives a
notification at a certain time with a certain size and category. A
`collapse_id` lets these parties link notifications that share it, so senders
should use opaque values. Content, gateway identity and credentials are never
sent. Invocation logs are disabled, and the code logs only route names and
status codes. Users who need to hide this metadata from AIowa can self-host.

### Explicit non-goals

Message-level authentication (done by the sealed payload), delivery guarantees,
protection against a malicious device or gateway, and account management.
