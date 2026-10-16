# Universal login in the app

How the iOS app implements [`universal-login.md`](universal-login.md), the shared contract with the
Hermes Fleet connector. This page covers what the app does and how to exercise it; the wire formats,
security invariants and connector behaviour are in the contract.

## What the owner sees

1. **Connect to Hermes** (first server, and Settings > Connect Another Server / **+** on Gateways)
   shows three steps: ask Hermes for a link (`/fleet pair` in any chat, or `hermes fleet pair` on the
   computer), open the link on the iPhone or scan its QR code, approve the code Fleet shows. The
   actions are **Scan QR code** and **Paste link**. The pasteboard is read only when **Paste link** is
   tapped.
2. A link opened from outside the app (tap, Camera) starts the same flow. The app accepts its own URL
   scheme in the form `<scheme>://pair#...&o=<origin>` (Dev: `hermes-fleet-dev`); other links on that
   scheme (conversations) are unaffected.
3. **Other ways to connect** holds owner sign-in, manual gateway setup and, for servers still on the
   first connector release, the Telegram setup message. Nothing on the default path mentions Telegram.

## States

`PairingCoordinator` (FleetUI) drives one flow at a time:

```text
previewing -> confirming -> requesting -> awaitingApproval(code, expiresAt) -> redeeming (saving) -> completed
                                                  |-> denied
                                                  |-> expired
 any step -> failed(reason)   (Try again when retrying can help)
```

- **v1 links** (`v=1`) skip `requesting`/`awaitingApproval` and redeem directly, as before.
- **Confirming** shows the server, host and access, and **Connect this phone**. Nothing is created
  before it is tapped.
- **requesting** posts the request with a fresh random 32-byte client secret. The secret lives only in
  memory for the pairing session; losing it (app killed) just lets the request expire. A request whose
  response was lost is retried with the same secret, which the gateway answers idempotently.
- **awaitingApproval** shows the code large and spaced (`482 913`, monospaced digits, read digit by
  digit by VoiceOver), `Send this to Hermes:` with `/fleet approve 482913` and a Copy button, the
  terminal alternative, an expiry countdown and Cancel. Polling runs every `poll_interval` (at least
  1 s, 5 s after a transient error) only while the app is active; backgrounding pauses it and
  returning to the foreground resumes it with the same client secret. Cancel stops polling; the request
  expires on the gateway.
- **approved** hands the grant to the same save path as v1 (Keychain credential, TLS pin, gateway
  record). If saving fails the device is revoked on the gateway and nothing is added.
- **denied** / **expired** explain that nothing was added and how to get a new link.

## First contact and trust

A v2 link carries `k`, the SHA-256 of the server's TLS public key. The exchange accepts the server when
that key matches, whether or not iOS trusts the certificate; a different key is refused (identity
mismatch when iOS trusted the certificate, untrusted otherwise) before any secret is sent. The
confirmed key becomes the gateway's saved TLS pin. v1 links keep requiring system trust.

## Reachability diagnosis

`PairingDiagnosis` (FleetCore, pure and unit-tested) maps a failure to one sentence plus **Try again**:
DNS failure on `*.ts.net` (Tailscale), other DNS failure, timeout or refused connection, untrusted
certificate without a matching pin, pin mismatch, offline. The host named is the one in the link.

## Testing in the simulator

- Package tests: `cd Packages/FleetCore && swift test` and the same for `FleetNetworking` (real
  loopback TLS server with throwaway certificates; needs `python3` and `openssl`).
- App unit tests: `PairingApprovalFlowTests` (state machine), `PairingFlowTests` (v1 and shared),
  `FleetAboutCompositionTests` (source guards for the screens).
- UI tests: `UniversalLoginUITests`, plus the updated `F3OnboardingUITests`, `C2SetupPromptUITests`,
  `F4FirstRunGateUITests`. Run with the lane simulator:
  `HERMES_FLEET_LANE_SIM=1 bash scripts/c1_ui_matrix.sh --classes "UniversalLoginUITests"`.

DEBUG simulator builds use `ScriptedPairingService` (no network). Launch environment:

| Variable | Effect |
|---|---|
| `HERMES_FLEET_PAIRING_SIMULATED_PASTE` | Text **Paste link** reads instead of the pasteboard |
| `HERMES_FLEET_PAIRING_SIMULATED_SCAN` | Text the simulated scanner delivers |
| `HERMES_FLEET_PAIRING_APPROVE_AFTER` | Seconds until the scripted owner decides (default 4, `never` = stays pending) |

A v2 link (`v=2`, 43-character `k`) uses the approval path with the fixed code `482913`. The invitation
id prefix selects the decision: `denied...` denies, `lapsed...` expires, `pending...` never decides,
anything else approves; the existing v1 prefixes (`expired...`, `used...`, `offline...`, `slow...`)
still apply to the preview. Use synthetic hosts such as `pairing.fixture.test` only.
