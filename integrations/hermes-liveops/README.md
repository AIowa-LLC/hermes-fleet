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

### Guided setup (recommended)

In Fleet, open **Set up Live Operations** when reporting is missing, or
**Live Operations setup** on the Fleet or gateway detail screen. The guide
provides a download link, a share link for the computer, restart instructions,
and **Check reporting**. Authentication and connection failures do not claim
that the plugin is missing. A connected status requires a fresh authenticated
snapshot, not just a connected machine or completed installer.

Download `Fleet-Live-Reporting-0.2.0.zip` from the
[versioned companion release](https://github.com/AIowa-LLC/hermes-fleet/releases/tag/fleet-liveops-v0.2.0).
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
- Runtime IDs include a random process namespace. A Desktop observation does
  not authorize approval, steering, interruption, or session activation through
  Fleet's separate connection. Subagent controls remain unavailable for these
  observed sessions.
- Reports at most 64 fresh publishers, 200 sessions, and 500 children per
  publisher, prioritizing active sessions. Incompatible Hermes registry helpers
  cause reports to expire; they do not fabricate zero activity.

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

Synthetic tests cover separate Desktop processes with colliding runtime IDs,
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

The deterministic ZIP contains only the five allowlisted runtime plugin files,
the setup tool and launchers, its user guide, and a `release.json` recording
source commit and runtime hashes. The app's versioned guide link, both plugin
manifests, and setup version must agree. Publish the ZIP and `SHA256SUMS.txt`
on the `fleet-liveops-v0.2.0` GitHub companion release after testing the
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
