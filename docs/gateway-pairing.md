# Gateway setup and pairing

Hermes Fleet connects to gateways chosen by the user. No maintainer endpoint or shared credential is compiled into the default configuration.

## Manual setup

Add a gateway from the Gateways screen and provide:

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

1. Open **Add Gateway**.
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

## Agent-assisted onboarding

The app also includes a copyable onboarding prompt intended for users who already have access to a Hermes agent but have not yet configured Fleet. The prompt helps the user establish a reachable gateway and return the connection details needed by the normal Add Gateway flow.

That onboarding path does not bypass gateway authentication and should not embed maintainer-specific endpoints or credentials.
