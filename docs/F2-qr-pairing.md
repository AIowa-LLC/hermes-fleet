# F2 — QR-Code Gateway Pairing

One scan of a QR shown on the Mac replaces manual URL/username/password entry
in the Add-Gateway form.

## Scope and shape

- **Payload (v1)** — `PairingPayload` (FleetCore): compact JSON
  `{"password":…,"url":…,"username":…,"v":1}` with sorted keys. Strict
  version check: future versions decode to `.unsupportedVersion`, wrong
  shapes to `.notAPairingPayload`, never a best-effort guess.
- **Gateway side (Mac)** — `scripts/f2_generate_pairing_qr.sh <url> <user>
  <pass>` renders the QR (terminal via `qrencode` when installed, else a
  CoreImage PNG opened in Preview, deleted on exit). The payload builder is
  `scripts/f2_pairing_payload.swift` — the same shape and escaping rules as
  `PairingPayload.encoded()`, so Mac and app agree byte-for-byte.
- **App side** — "Scan Pairing Code" button in the Add/Edit-Gateway form
  opens `GatewayPairingScannerView`: VisionKit live camera scanner on real
  devices; a fallback body (with a DEBUG-only simulated-scan hook) on
  simulators. Every recognized string — camera or simulated — flows through
  ONE path: `PairingPayload.decode` → `GatewayFormDraftStore.applyPairing`,
  which fills display name (endpoint host), endpoint (validated through
  `GatewayEndpoint.normalizedOrigin`), strategy `.usernamePassword`, and the
  credential fields exactly as if typed. Save stays explicit.

## Security model (enforced)

- The QR IS credential material on screen. The Mac script is the explicit
  user action that shows it; usage doc says: generate a FRESH scoped secret
  per pairing (`openssl rand -hex 21`), never reuse, revoke after pairing.
- The app never logs the payload or password; the decoded secret lands only
  in the in-memory `GatewayFormDraftStore` (same as typing), cleared on
  Cancel/Save, persisted to Keychain only via the existing save seam.
- Endpoint hygiene is preserved through pairing: user-info in the URL is
  rejected, query/fragment stripped (P1-6 invariants; unit-tested).
- A rejected scan (bad shape / future version / hostile endpoint) never
  clobbers typed fields — the scanner surfaces a non-secret error and the
  draft is untouched.

## Evidence

- `FleetCoreTests/PairingPayloadTests` — 9 tests: round-trips (compact +
  JSONEncoder), exact encoded shape, escaping, decode hardening, size bound.
- `HermesFleetAppTests/F2PairingApplyTests` — 7 hosted tests: full-form fill,
  overwrite semantics, user-info rejection, query/fragment strip, decode
  failures leave the draft untouched, clear() wipes secrets.
- `HermesFleetAppUITests/F2QRPairingUITests` — 2 deterministic UI tests
  (CI-safe: simulator fallback + simulated scan drives the production
  decode+apply path): scan → form filled → Save → row appears; and rejected
  scan keeps typed state.
- Mac-side round-trip verified headlessly: payload builder JSON == exact v1
  shape; CoreImage QR (516×516) decoded via `VNDetectBarcodesRequest` back
  to the exact payload string.
- Camera scanning on a real device is exercised by on-device dogfooding
  (VisionKit reports unsupported on simulators, which CI relies on).

## Pairing flow

1. Mac: `SECRET=$(openssl rand -hex 21)` then
   `bash scripts/f2_generate_pairing_qr.sh http://<lan-ip>:8642 fleet-operator "$SECRET"`
2. iPhone: Add Gateway → Scan Pairing Code → point at the QR.
3. Form fills itself → review → Add.
4. Mac: revoke the pairing credential once the phone is connected.
