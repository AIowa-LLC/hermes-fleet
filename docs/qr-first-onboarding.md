# First-server QR onboarding

A fresh Fleet installation shows the existing Fleet wing mark and one connection action: **Scan QR code**. It includes a copyable message for Hermes in a private Telegram conversation while the owner is at the host computer. The phone does not discover a host or create a network path.

The host must already provide a reachable public HTTPS origin, a compatible Fleet invitation issuer, explicit Telegram owner binding, and local QR display. Hermes must verify the actual incoming private owner event; an allowlist or home channel alone is insufficient authority. Verify these prerequisites before creating an invitation. The active host launcher command is:

```sh
hermes --run-module hermes_cli.fleet_pairing_cli invite --label iPhone --ttl 600
```

Capture its genuine output privately. Render the exact issued link locally, with its bearer secret passed to the QR tool through standard input rather than command arguments. Keep any image private and remove it after use or expiry. A host without this installed issuer or a usable display cannot complete the one-message setup. A synthetic QR round trip does not prove a live Telegram request or a physical-phone scan.

The supported invitation format is the existing HTTPS `/pair` link with version, invitation ID and secret in its fragment. An invitation is scoped to its origin, short-lived and single-use. Scanning fetches a non-consuming preview. Fleet presents the host and its broad `fleet:operator` access, then requires **Connect this phone**. Back before confirmation leaves the invitation usable. Expired, used, cancelled, rate-limited, unreachable and untrusted responses show recovery instructions without exposing the link.

Redemption requires the same system-trusted public key as preview and refuses redirects. Ongoing authentication uses the existing `hfd1` device credential and DeviceLogin flow. The credential and confirmed TLS pin are securely saved before the fully configured gateway record is committed. Failed local saves trigger pinned remote revocation and local cleanup; unconfirmed cleanup is disclosed and retryable when the grant is still available. If a response is lost or the process terminates after redemption but before secure saving, the invitation may be consumed and the owner must check/revoke the orphaned device before issuing another invitation. The legacy server protocol does not offer client-generated-secret idempotency for this flow.

A saved gateway keeps its stable ID, credentials, pin and existing data; a configured user enters Fleet. Existing owner sign-in and manual authentication strategies remain in Advanced/additional-server setup, including the old JSON scanner decoder. First-server setup does not expose them. Production and Dev namespaces remain separate. Conversation deep links are unchanged.

Camera denial offers the app Settings action and Cancel. Simulator scan/denial fixtures are compiled only for DEBUG simulators. Fixture UI and temporary TLS gateway tests must be reported separately from live owner authorization, host display, phone camera, delivery and enrollment acceptance.
