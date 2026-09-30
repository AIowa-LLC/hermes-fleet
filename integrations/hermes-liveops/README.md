# Hermes Fleet live reporting

> **Security change in 0.3.0.** Earlier versions only read and reported
> runtime state. Version 0.3.0 adds an optional **push sender**: when you turn
> it on, hooks in the agent process (Desktop backend or gateway) send
> end-to-end encrypted notifications through a relay, and the plugin holds each
> paired device's relay send capability on disk. It is **off by default**, it
> never answers, blocks or modifies agent activity through hooks, and the one
> new control path is a single-use-token approval endpoint described below.
> Existing installs must download the 0.3.0 bundle and run setup again; push
> stays off until you enable it and pair a device. See
> [Push notifications](#push-notifications).

The stock `session.active_list` and `delegation.status` RPCs report one
process's memory. Hermes Desktop can launch a separate `hermes serve`
backend for each profile. A Fleet connection to a different backend cannot
observe those runs through the stock RPCs, even when the machine is connected.

This optional Hermes dashboard plugin publishes the live runtime registry
from each enabled Desktop backend. The Fleet app reads the combined snapshot
through `GET /api/plugins/fleet-liveops/snapshot`, using the gateway's existing
authentication and TLS pinning. It does not infer running work from recent
transcripts, open sessions, or database timestamps.

## Enable on the Hermes machine

### Guided setup (recommended)

In Fleet, open **Set up Live Operations** when reporting is missing, or
**Live Operations setup** on the Fleet or gateway detail screen. The guide
provides a download link, a share link for the computer, restart instructions,
and **Check reporting**. Authentication and connection failures do not claim
that the plugin is missing. A connected status requires a fresh authenticated
snapshot, not just a connected machine or completed installer.

Download `Fleet-Live-Reporting-0.3.0.zip` from the
[versioned companion release](https://github.com/AIowa-LLC/hermes-fleet/releases/tag/fleet-liveops-v0.3.0).
Extract the complete archive on the Hermes computer. On Mac open
`Setup.command`. For Linux or a custom runtime,
follow `README.txt` in the bundle and run `setup.py` with Hermes's Python.
Other platforms use the manual instructions below; the guided installer
requires POSIX file permissions for its private recovery copies.

Setup asks which existing profiles to observe and confirms the selection.
Include the profile hosting the Fleet gateway if it is not the default.
It also enables the default gateway configuration, scans the runtime plugin
with Hermes's security scanner, validates the bundled file hashes, and saves
private recovery copies before changing settings. It preserves comments,
literal environment references, other plugins, and configuration file modes.
Repeating the same installation is safe; newer installed versions are not
downgraded. A new profile created later needs setup again. Omitting a profile
does not disable reporting that was already enabled there.

Wait for running work to finish and restart Desktop and any separate Fleet
gateway service. Open each selected Desktop profile to start its backend,
then check reporting from the phone and run a delegation test. Setup never
stops processes, changes authentication, installs dependencies, or sends
provider requests. A connected status confirms that at least one backend
is publishing; it does not certify that every profile has been restarted.

### Manual setup (advanced)

Copy this directory to the Hermes root's `plugins/fleet-liveops` directory.
Enable `fleet-liveops` in `plugins.enabled` in the configuration of the
gateway backend and each Desktop profile to observe. Preserve the other enabled
plugins and remove `fleet-liveops` from `plugins.disabled` if present. The shared
root installation is discovered by Desktop's dashboard backends, but the current
`hermes plugins enable` command searches only the selected profile's plugin
directory. For a shared installation, edit each profile's configuration directly;
the CLI can otherwise report that the installed plugin was not found.

Restart the affected Desktop and dashboard backends after enabling the plugin;
wait for active work to finish first. Dashboard API plugins are loaded when
the backend starts. Installing the next Fleet app build alone does not enable
reporting in existing Hermes processes.

If the plugin is absent (HTTP 404), Fleet keeps the stock process-local RPC
view and explains its scope. Auth failures, incompatible responses, and zero
fresh publishers remain unavailable coverage instead of a quiet fleet.

## Scope and storage

- Covers TUI runtime sessions and delegated children in enabled Desktop/serve
  processes sharing the same Hermes root. Messaging gateway workers, separate
  containers, and CLI processes that do not load dashboard plugins are outside
  this integration's scope.
- Samples once per second. Fleet polls while its Fleet or operation screen is
  open. Runs shorter than the polling interval may complete between samples.
- Keeps one atomic, owner-only snapshot per backend in the Hermes root's
  `fleet-liveops` directory (directory mode 0700, file mode 0600). Snapshots
  include titles, previews, and delegation goals; treat them as private session
  data. A clean shutdown removes its file; reports older than eight seconds
  are ignored. An expired report from a still-running process marks coverage
  unavailable so Fleet retains the last known operations as stale. Crash
  leftovers can be removed after the processes stop.
- Push state (only when a device is paired) lives beside the snapshots as
  `push.json` (registered devices and their relay send capabilities) and
  `push-tokens.json` (hashes of unspent response tokens), both mode 0600. They
  contain no gateway credentials. Live reporting ignores these two files.
- Runtime IDs include a random process namespace. A Desktop observation does
  not authorize approval, steering, interruption, or session activation through
  Fleet's separate connection. Subagent controls remain unavailable for these
  observed sessions.
- Reports at most 64 fresh publishers, 200 sessions, and 500 children per
  publisher, prioritizing active sessions. Incompatible Hermes registry helpers
  cause reports to expire; they do not fabricate zero activity.

## Push notifications

Optional and off by default. Fleet can notify a paired iPhone when an approval
or a clarify question needs you, when an agent turn finishes, and when a cron
run finishes. Delivery uses the content-blind relay in
[`integrations/hermes-push-relay`](../hermes-push-relay/README.md) (the
maintainers' hosted relay or your own). The relay and Apple see only a generic
alert category and an opaque ciphertext sealed to the phone's key.

```text
agent process (hooks) -> queue -> seal to device key (HPKE) -> relay -> APNs -> phone
```

- **Hooks** are observers only. They return nothing, never raise and only
  enqueue: `pre_approval_request`, `post_approval_response`, `pre_tool_call`
  (only for `tool_name == "clarify"`) and `on_session_end` (`platform == "cron"`
  is a cron run; interrupted turns are skipped). Nothing can veto, answer or edit
  anything. `pre_tool_call` is a policy hook upstream (a timeout blocks the tool),
  so its callback compares one string and returns.
- **Delivery** runs on one daemon thread with a bounded queue (drop-oldest),
  jittered exponential retry with a cap, `Retry-After` honored, and a hard stop
  once a message's own expiry has passed. A relay `410` removes that
  registration.
- **Withdrawal.** When an approval is answered, times out or is cancelled, the
  sender sends a second `POST /v1/send` exactly as the relay's README documents
  a withdrawal: `push_type: background`, `priority: 5`, no `alert`, the same
  `collapse_id` as the alert, a future `expiry`, and a sealed `withdraw`
  instruction (the relay forwards it as `content-available: 1` with `hf.ct`). The
  device cannot see the `collapse_id` header, so the sealed instruction repeats
  it (the delivered notification's identifier) with the `command_digest` and any
  `request_id`. Background pushes are best effort; a notification is never
  authoritative state.
- **Visible text is generic** (`approval`, `clarify`, `done`, `cron`), chosen by
  the relay from a fixed table. Everything else is inside the sealed payload.

### Sealed payload (schema v1)

HPKE base mode (RFC 9180): DHKEM(X25519, HKDF-SHA256), HKDF-SHA256,
ChaCha20-Poly1305, using `cryptography.hazmat.primitives.hpke` from the
`cryptography` library that Hermes already pins (`cryptography==50.0.0`). The
`info` is `hermes-fleet-push-v1`, the AAD is empty, and the wire form is
`base64url(enc || ciphertext || tag)` without padding. This is CryptoKit's
`HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly`. If the installed
`cryptography` has no HPKE support, the sender disables itself; it never sends
unsealed content. Shared vectors for both ends are in
`tests/fixtures/push_hpke_vectors.json`.

| Field | Notes |
| --- | --- |
| `v` | `1` |
| `kind` | `approval`, `clarify`, `done`, `cron` (a withdrawal uses `withdraw`) |
| `gateway_label`, `bot` | Configured label (default: host name) and profile name |
| `session_id` | Hermes session id, for the app to resolve through the gateway |
| `request_ref` | Opaque session-level reference, stable across a session's events |
| `redacted_preview` | Approval command or clarify question, credential-redacted, at most 240 bytes. Omitted in generic-only mode and for `done`/`cron` |
| `command_digest` | Approvals: SHA-256 of the exact command text, so the app can match the concrete pending request without the command being shipped |
| `risk` | `high` for network-plus-exec (a download piped to a shell, for example), destructive or privileged commands; otherwise `normal` |
| `request_id` | Approvals, when exactly one pending request matches (below) |
| `response_token` | Approvals: single-use, expiring, bound to the request (below) |
| `outcome` | `done`/`cron`: `completed` or `failed`. `withdraw`: `approved`, `denied`, `timeout`, `cancelled` |
| `collapse_id` | `withdraw` only: the notification identifier to remove |
| `created_at`, `expires_at`, `nonce` | Unix seconds, and 16 random characters |

The upstream approval hook has no `request_id` (it is minted just before the hook
fires). The sender's worker reads the in-process pending queue with upstream's
`tools.approval.list_gateway_approvals` and includes `request_id` only when
exactly one pending request has that command text. Otherwise the app resolves the
request through `approval.pending` using `session_id` and `command_digest`.

### Response token and the approval endpoint

Each approval carries a 256-bit `response_token`. Only its SHA-256 is stored,
with the request binding, the gateway session key and an expiry (the payload's
`expires_at`). `POST /api/plugins/fleet-liveops/push/respond` accepts exactly
`{token, request_id, choice}` where `choice` is `once` or `deny` (never
`session`, `always` or bulk). It checks that the token exists, is unexpired and
is bound to that `request_id`, burns it, and then resolves that one request in the
same process if the pending request's command still matches the sealed digest. A
wrong `request_id` does not burn the token. A spent, expired or revoked token is
`401`; a request that is no longer pending, or lives in another process, is
`409 not_pending`. A withdrawal revokes the request's outstanding tokens. The
endpoint sits behind the dashboard's authentication like every plugin route.

Upstream's own `approval.respond` does not check tokens, so a client answering
through that RPC is not token-verified. Upstream also offers plugins no
interception point there (see the gaps below).

### Enable and pair

Settings live under the plugin entry in the Hermes configuration and are read
when the plugin loads (restart idle backends after changing them):

```yaml
plugins:
  entries:
    fleet-liveops:
      settings:
        push:
          enabled: true          # default false: no hooks are registered
          generic_only: false    # true omits every preview
          gateway_label: ""      # defaults to the host name
          kinds: {approval: true, clarify: true, done: true, cron: true}
          approval_ttl_seconds: 300
          clarify_ttl_seconds: 900
```

The app registers a device through the dashboard API (authenticated like the
snapshot endpoint) after it has registered with the relay and received a send
capability:

| Route | Purpose |
| --- | --- |
| `POST /api/plugins/fleet-liveops/push/register` | `{relay_url, relay_device_id, send_capability, device_public_key, key_id, label}`; `201` new, `200` refreshed. HTTPS relay URL only, with no credentials, IP literals or local names. `device_public_key` is a base64url X25519 key. Unknown fields are rejected and errors never echo input. |
| `GET .../push/registrations` | Local id, label, a fingerprint of the key id, and relay host. Never the capability, the public key or the key id itself. |
| `DELETE .../push/register/{id}` | Removes the registration locally (which stops pushes at once), then calls the relay's idempotent `DELETE /v1/register/{relay_device_id}` with the stored capability. Returns `{"removed": true, "relay_unregistered": bool}`; if the relay call failed the app can repeat it, since it holds the capability too. |
| `POST .../push/respond` | Spend a response token (above). |

`key_id` is the `relay_key_id` the app registered with at the relay: a random
value of at least 128 bits (22 or more base64url characters, at most 64), one per
gateway. Shorter values get `400 invalid_field`, and a `key_id` already held by a
different registration gets `409 key_id_in_use`. The relay treats it as a
possession check, so listings never show it.

At most 8 devices. Checks mirror the reporting directory: the directory is 0700
and owned by this user, files are 0600, and symlinks and foreign owners are
refused.

### Privacy and logging

The plugin never logs device tokens, capabilities, ciphertext, previews or
command text. Failures log a static message, the local registration id and an
HTTP status. Alerts are generic, previews are redacted and capped, `generic_only`
removes them, and each kind can be switched off. A relay operator can still see
timing, payload size and the alert category. The relay URL receives the bearer
send capability, so register only a relay you trust.

### Known gaps against upstream

Only hooks and APIs that exist upstream today are used. Issue #154 tracks the
proposal for better ones:

- Approval hook kwargs carry no `request_id`, runtime session id or expiry
  (worked around with the in-process pending-queue lookup above).
- There is no clarify observer. `pre_tool_call` fires before the question is
  shown, and it is a policy hook with a strict latency budget.
- There is no content-free turn-end observer for TUI sessions. `on_session_end` is
  used, so a delegated child agent's turn may also produce a finished alert.
- There is no interception point on `approval.respond`, hence the separate token
  endpoint.
- Hooks run in the process that runs the agent. The approval endpoint can resolve
  a request only when the dashboard shares that process (Desktop and
  `hermes serve` backends do). Workers in other processes answer `not_pending`.

### Maintainer-only steps

Deploying the relay, the Apple push key and the app's push entitlement need the
maintainer's Cloudflare and Apple accounts (see the relay README's checklist).
Nothing in this plugin needs either credential.

## Validate

Synthetic tests need only the pinned test libraries; no Hermes account or
running gateway is required. Scanner decisions and CLI discovery use explicit
synthetic SDK contracts. Before publishing, also run the extracted installer
with the supported Hermes Python environment and its real security scanner.

```sh
python -m pip install -r integrations/hermes-liveops/requirements-test.txt
python -m unittest discover -s integrations/hermes-liveops/tests -v
swift test --package-path Packages/FleetNetworking --filter DashboardLiveOpsClientTests
swift test --package-path Packages/FleetCore --filter LiveOpsDomainTests
```

Push tests (`tests/test_push.py`, `tests/test_push_hpke.py`) are fully offline: a
stub relay, per-run generated device keys, and a from-the-RFC reference
implementation that checks the HPKE vectors. Synthetic tests cover separate Desktop processes with colliding runtime IDs,
durable child ownership, private-field exclusion, expiry, malformed snapshots,
authentication failure, fallback scope, and observation-only control authority.
The UI regression covers an idle parent whose asynchronous child is running.
Installer tests also cover extracted release installation, profile selection,
preservation of configuration and credentials references, idempotence, private
backups, scan rejection, corruption, symlinks, concurrent settings edits,
rollback, and downgrade refusal. They use temporary synthetic Hermes roots.

## Build and publish the setup bundle

Build from an exact committed source revision:

```sh
python3 scripts/build_liveops_bundle.py --sha <commit> --output <artifact-directory>
```

The deterministic ZIP contains only the eight allowlisted runtime plugin files,
the setup tool and launchers, its user guide, and a `release.json` recording
source commit and runtime hashes. The app's versioned guide link, both plugin
manifests, and setup version must agree. Publish the ZIP and `SHA256SUMS.txt`
on the `fleet-liveops-v0.3.0` GitHub companion release after testing the
extracted artifact. This is a companion-plugin release, separate from iOS
TestFlight distribution. Never replace assets on an existing versioned release;
publish a new version for changes. The Python installer and Mac launcher are validated
with synthetic roots without touching a user's real settings.

### Removal

Remove `fleet-liveops` from enabled plugins in the intended profiles (or add
it to disabled plugins), then restart their idle backends. Once disabled
everywhere and those backends have stopped, the shared plugin and private
snapshot directories may be removed. Conversation history is unaffected.

## Live acceptance

Live acceptance: first confirm the authenticated snapshot endpoint returns
HTTP 200 with fresh publishers from the gateway and the intended Desktop
profile. Then start a long-running
delegation from a Desktop profile, and confirm its parent and child tree appear
on Fleet within the next poll. The device must have a Fleet build that includes
the dashboard reporting client; a newer app build cannot replace the Hermes
installation and backend reload steps above.
