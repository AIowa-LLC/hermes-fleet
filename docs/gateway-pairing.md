# Gateway setup and pairing

Hermes Fleet connects to gateways chosen by the user. No maintainer endpoint or shared credential is compiled into the default configuration.

## Current flow: ask Hermes for a link, approve the code

The default way to connect a server is described in [universal-login.md](universal-login.md) and [qr-first-onboarding.md](qr-first-onboarding.md). The first server and every additional server (Settings > Connect Another Server, or **+** on the Gateways tab) use the same **Connect to Hermes** screen:

1. Ask Hermes for a link: send `/fleet pair` in a private chat with Hermes on any platform, or run `hermes fleet pair` on the computer.
2. Open the link on the iPhone, scan its QR code, or tap **Paste link**.
3. Review the server and tap **Connect this phone**, then approve the code Fleet shows with `/fleet approve <code>` (or `y` in the waiting terminal).

Cancelling, retrying or rescanning never removes servers that are already saved. Failures are explained in plain words with **Try again** (see "Reachability diagnosis" in the contract). App behaviour and simulator testing: [universal-login-app.md](universal-login-app.md).

### Legacy: v1 QR invitation (first connector release)

Links with `v=1` still work: scan or open one, review, and **Connect this phone** redeems it directly with no approval step. For servers on the first connector release the setup message (a message to send to Hermes in the owner's private Telegram chat) is available under **Other ways to connect**. The v1 route is documented in [qr-first-onboarding.md](qr-first-onboarding.md).

The sections below describe the **advanced / legacy** routes. For additional servers they are reached from **Other ways to connect** in the add-server sheet and are not the default.

## Advanced: owner sign-in (address-first)

Fleet needs a running Hermes server, a reachable HTTPS address, and an owner account. Enter the address, review its TLS key on first use, sign in using the detected username/password provider, then choose **Connect this phone**. Fleet chooses the server display name automatically. This route has no nearby discovery or Telegram invitation step.

Enrollment grants `fleet:operator`: chat with agents, run and review their work, and manage them, with the same access as signing in. The phone creates a random device secret; only its digest is stored on the server. The phone keeps the device credential in Keychain and discards the owner sign-in material. Existing saved gateways open directly into Fleet.

The server must support authenticated `GET /api/fleet/connection` and owner-only `POST /api/fleet/devices/enroll`. Older servers and providers that require the desktop native OAuth callback need **Advanced gateway setup** during this transition. A changed TLS key blocks connection until it is verified through the existing gateway trust controls.

## Advanced manual setup

Choose **Other ways to connect** > **Enter gateway details manually** in the add-server sheet (or **Advanced gateway setup** inside owner sign-in) and provide:

- a display name
- the gateway endpoint
- the authentication strategy required by that gateway
- the corresponding credential material

Review the endpoint before saving. Prefer HTTPS for any network you do not fully trust.

After a successful save, supported credentials are persisted through the app's Keychain-backed security layer rather than ordinary application storage.

## QR-assisted pairing

Hermes Fleet supports a versioned QR pairing payload for username/password gateway setup.

The v1 payload contains:

```json
{"password":"<scoped-secret>","url":"https://<gateway-host>","username":"<gateway-user>","v":1}
```

The repository includes `scripts/f2_generate_pairing_qr.sh` and `scripts/f2_pairing_payload.swift` for generating a compatible code.

Example:

```sh
SECRET="$(openssl rand -hex 21)"
bash scripts/f2_generate_pairing_qr.sh \
  "https://<gateway-host>" \
  "fleet-operator" \
  "$SECRET"
```

On the iPhone:

1. Open **Add Gateway**, then **Other ways to connect** > **Enter gateway details manually**.
2. Choose **Scan Pairing Code**.
3. Scan the newly generated QR code.
4. Review the populated endpoint and credential fields.
5. Save the gateway.
6. Revoke or rotate the temporary pairing credential when your gateway policy requires it.

## QR security

The QR code contains credential material. Treat it like a password while it is visible.

- generate a fresh scoped secret for pairing
- do not post the QR in screenshots, issues, chats, or documentation
- avoid reusing a long-lived administrator credential
- clear or revoke temporary credentials after pairing when practical
- reject unexpected payload versions instead of guessing their shape

Invalid or unsupported pairing payloads should leave existing form state unchanged and surface a non-secret error.
