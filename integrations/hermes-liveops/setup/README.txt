Fleet Live Reporting 0.3.0

Install this on the computer running Hermes, not on your phone.
Download the ZIP from the official release:
https://github.com/AIowa-LLC/hermes-fleet/releases/tag/fleet-liveops-v0.3.0

1. Extract the complete ZIP. Keep setup.py, release.json, and plugin together.
2. On Mac, open Setup.command.
   Select profiles by entering their names separated by commas, or enter all.
   Include the profile hosting the Fleet gateway if it is not the default.
   Review the selection and answer y to install.
3. Wait for active work to finish, then quit and reopen Hermes Desktop.
   If Fleet connects to a separate gateway/dashboard service, restart that
   service too, using the same service manager you used to start it.
4. Open each selected Desktop profile so its backend starts.
5. On the phone: Fleet > Live Operations setup > Check reporting.
   Expect Live reporting connected. Start a Desktop delegation and confirm
   that its parent and subagents appear in Fleet.

Linux, custom Hermes paths, or a launcher that cannot find Hermes Python:
Run setup.py with the Python executable from your Hermes environment.
For the standard Linux/macOS installation, from the extracted directory:

  ~/.hermes/hermes-agent/venv/bin/python setup.py

Specify a custom Hermes root if necessary:

  <Hermes-Python> setup.py --hermes-root <Hermes-root>

For an explicit non-interactive selection:

  <Hermes-Python> setup.py --profiles default development --yes

Only use profile names that exist on your computer. The default gateway
configuration is always enabled too, so Fleet can read the combined reports.
Unselected profiles retain their settings. New profiles created later need
setup again. The tool never disables previously enabled reporting profiles.

New in 0.3.0 (security-relevant): the plugin can also send push notifications.
This is OFF by default. Installing or updating does not enable it. When you turn
it on and pair a phone, hooks in the agent process send end-to-end encrypted
alerts through a relay, and the plugin stores the phone's relay send capability
(file mode 0600) in Hermes's private fleet-liveops directory. The hooks only
observe; they never answer or block anything. Existing 0.2.x installs must run
this setup again to get 0.3.0; profiles keep working without push until then.
Setup still installs no dependencies: push uses the cryptography library that
Hermes already includes, and disables itself if that library lacks HPKE support.
Details: the plugin README ("Push notifications").

What setup changes:
- Installs the bundled fleet-liveops plugin in the shared Hermes plugin directory.
- Runs Hermes's security scanner and refuses an unapproved or unavailable scan.
- Adds fleet-liveops to the selected profiles' enabled plugins and removes its
  disabled entry, preserving other settings, comments, and literal environment
  references. It saves private recovery copies in Hermes's backups directory.
- Does not restart processes, stop runs, install Python dependencies, change
  authentication, or send model requests.

Updates: download the next versioned bundle and run setup again. Repeating
the same version is safe. Setup refuses to replace a newer installed version.
Profiles omitted from an update may still have reporting enabled from before.

Other platforms (manual setup): the guided installer currently supports Mac
and Linux. Copy the bundled plugin directory to <Hermes-root>/plugins/fleet-liveops.
In the default gateway configuration and each profile to observe, add
fleet-liveops to plugins.enabled and remove it from plugins.disabled if present.
Preserve other settings. Restart idle backends and check reporting from Fleet.

Remove reporting: remove fleet-liveops from plugins.enabled in the intended
profiles (or add it to plugins.disabled), then restart their idle backends.
When disabled everywhere and those processes have stopped, remove the shared
plugins/fleet-liveops directory and its private fleet-liveops snapshot directory.
Existing conversation history is unaffected.

Reporting covers enabled Desktop/serve backends sharing one Hermes root.
Messaging bots, standalone CLI runs, and separate containers are not covered.
Connected means a backend is publishing, not that every profile is running.
Very short runs can finish between Fleet's polls.

Integrity: SHA256SUMS.txt on the release page lists the ZIP checksum. The bundle
also validates its runtime file hashes before changing anything. Download only
from the official release; local hashes alone do not authenticate the publisher.
