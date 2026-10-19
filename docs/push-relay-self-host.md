# Self-hosting the push relay

Hermes Fleet's push notifications travel gateway → relay → Apple Push
Notification service (APNs) → device. The relay is a small, content-blind
Cloudflare Worker in [`integrations/hermes-push-relay`](../integrations/hermes-push-relay/README.md).
AIowa may operate a hosted instance for the App Store build; you can instead run
your own so that no third party's relay ever sees your device token or
notification timing.

Status: this document describes the relay side, which exists in this
repository. The plugin registration fields and the app setting that select a
custom relay URL are delivered with the sender and device-registration work;
until they ship, the relay can be deployed and exercised directly through its
[OpenAPI](../integrations/hermes-push-relay/openapi.yaml) contract.

## What you need

- A Cloudflare account. The free plan is enough for personal and small-team use
  (see the budget in the relay README).
- An Apple Developer Program membership, because APNs authenticates with a
  key tied to a team. There is no way to send APNs notifications to an app
  without one.
- Node.js 20 or newer and this repository.

## Why a self-built app needs its own key

APNs only delivers to the bundle ID that the signing key's team owns. The
App Store build's bundle ID and key belong to AIowa, so they cannot be used for
a copy you build and sign yourself. For your own build:

1. Choose your own bundle ID in your fork (generated Xcode settings come from
   `project.yml`; regenerate with `xcodegen generate`).
2. In your Apple Developer account, enable Push Notifications on that App ID.
3. Create an APNs Auth Key and note the Key ID and Team ID. Keep the `.p8`
   file private; never commit it.
4. Give the relay that bundle ID as `APNS_TOPIC`. The relay refuses to
   register any other bundle ID.

Use `environment: "sandbox"` for debug builds and `"production"` for
TestFlight and App Store builds; the app sends the right value at registration.

## Deploy on your own Cloudflare account

```sh
cd integrations/hermes-push-relay
npm ci
npm test
npx wrangler login
npx wrangler kv namespace create REGISTRY   # keep the id in an uncommitted local config
npx wrangler secret put APNS_KEY_P8         # paste the .p8 contents
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_TOPIC          # your bundle ID
openssl rand -base64 32 | npx wrangler secret put RELAY_STORAGE_KEY
npx wrangler deploy
```

Then check `https://<your-worker-host>/healthz` returns `{"status":"ok"}`.
The full checklist, including rotation and logging notes, is in the
[relay README](../integrations/hermes-push-relay/README.md#maintainer-only-deployment-checklist);
the same steps apply to you as the operator. Do not commit the KV namespace
ID, your worker hostname, or any secret to a public fork.

## Point the gateway and the app at your relay

The relay URL is a **per-registration** value, not a plugin-wide setting:

- **App.** The app chooses the relay (its default, or a custom URL you set in
  the app's notification settings, defined with the device-registration work).
  For each gateway it generates a fresh random `relay_key_id`, registers the
  device token with that relay (`POST /v1/register`), and receives a
  `relay_device_id` and a send capability.
- **Gateway sender plugin.** The app hands the plugin, at registration, the
  relay base URL (HTTPS only), `relay_device_id`, and capability together with
  the device's public key. The plugin stores them per registration and sends
  to exactly that relay. It never needs your APNs key, and two devices (or two
  gateways) can use different relays side by side.
- **De-registration.** When a gateway is removed or the plugin de-registers a
  device, the plugin should call `DELETE /v1/register/{relay_device_id}` on
  that registration's relay with its capability. The call is idempotent. The
  app can also issue it, for example when the user removes a gateway or uses a
  panic switch.

Never paste your relay URL together with a capability into a public issue.

## Alternatives that need no relay

- The foreground connection to your gateway is always authoritative and needs
  no push service.
- Self-hosters can additionally deliver alerts through upstream Hermes's ntfy
  platform, independent of this relay.

## Operating notes

- The relay stores a sealed device token, a token hash index, and a capability
  hash, all with a TTL, and logs only route names and status codes. See the
  relay README's threat model.
- To stop pushes to a registration, delete it
  (`DELETE /v1/register/{relay_device_id}`, issued by the gateway plugin on
  de-registration or by the app). Registrations are per gateway, so removing
  one gateway leaves the others working.
- To rotate the APNs key, `wrangler secret put` the new key and key ID and
  redeploy. Rotating `RELAY_STORAGE_KEY` invalidates all registrations; devices
  re-register on next launch.
