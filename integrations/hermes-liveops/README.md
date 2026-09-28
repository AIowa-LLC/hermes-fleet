# Hermes Fleet live reporting

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

Copy this directory to the Hermes root's `plugins/fleet-liveops` directory.
Enable `fleet-liveops` in `plugins.enabled` in the configuration of the
gateway backend and each Desktop profile to observe. Hermes Desktop's Plugins
settings or `hermes plugins enable fleet-liveops` in the intended profile's
scope can perform that configuration change.

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
- Runtime IDs include a random process namespace. A Desktop observation does
  not authorize approval, steering, interruption, or session activation through
  Fleet's separate connection. Subagent controls remain unavailable for these
  observed sessions.
- Reports at most 64 fresh publishers, 200 sessions, and 500 children per
  publisher, prioritizing active sessions. Incompatible Hermes registry helpers
  cause reports to expire; they do not fabricate zero activity.

## Validate

Use a Python environment with Hermes's FastAPI and HTTPX dependencies:

```sh
python -m unittest discover -s integrations/hermes-liveops/tests -v
swift test --package-path Packages/FleetNetworking --filter DashboardLiveOpsClientTests
swift test --package-path Packages/FleetCore --filter LiveOpsDomainTests
```

Synthetic tests cover separate Desktop processes with colliding runtime IDs,
durable child ownership, private-field exclusion, expiry, malformed snapshots,
authentication failure, fallback scope, and observation-only control authority.
The UI regression covers an idle parent whose asynchronous child is running.

Live acceptance: enable and restart the relevant backends, start a long-running
delegation from a Desktop profile, and confirm its parent and child tree appear
on Fleet within the next poll. This requires the next app build on the device.
