# Offline Hermes Fleet host overlay

This bundle carries the reviewed Fleet pairing backend as an offline patch, a narrow
upgrade for a clean checkout that already has the ECD overlay, a namespaced owner-control
plugin, and read-only readiness/QR helpers. The manifest records the exact base and target
commits, the seven original commits followed by any reviewed safety supplement, the file
allowlist, and before/after SHA256 digests. `upgrade.patch` is limited to the safety changes
since the ECD overlay.

## Verify the bundle before running its Python

Get the aggregate SHA256 from an independent trusted release note or the task owner. Do not
trust a value copied only from the bundle being checked. From this directory, compare it to:

```sh
shasum -a 256 release/SHA256SUMS
```

Then verify every bundled file:

```sh
shasum -a 256 -c release/SHA256SUMS
```

The manifest has its own pin. Calculate it after the bundle check and pass that value to every
installer command as `--trusted-manifest-sha256`:

```sh
shasum -a 256 release/manifest.json
```

The installer refuses a manifest that does not match the supplied pin, a patch or helper whose
digest differs from the manifest, a path outside its allowlist, and any source whose changed
files do not match a recorded compatible preimage. The patch was built from local Git objects;
the installer performs no network or GitHub access.

## Install the owner-control plugin offline

The release includes `release/owner-control.bundle`, a deterministic standalone Git bundle for
the complete plugin package and its helper modules. The manifest binds its SHA256 and immutable
`plugin_commit`. Hermes supports local Git bundle installation through its normal plugin manager;
this does not publish the package or use a network URL. After the release pins have been checked,
clone the bundle to a separate approved local directory and compare its `main` commit with the
manifest's `plugin_commit`:

```sh
git clone /path/to/release/owner-control.bundle /path/to/approved/fleet-owner-control
git -C /path/to/approved/fleet-owner-control rev-parse refs/heads/main
hermes -p PROFILE plugins install \
  file:///path/to/approved/fleet-owner-control \
  --ref IMMUTABLE_PLUGIN_COMMIT --no-enable
```

Review and back up the selected profile's plugin configuration before installation. `--no-enable`
keeps installation separate from activation; enable the plugin only after reviewing its profile
scope, private Telegram owner IDs, readiness binding, and local QR behavior. This host installer
does not run Hermes CLI, modify plugin configuration, enable the plugin, or restart services.

## Plan and stage

Use an explicit Hermes source checkout. `plan` reads its Git status and changed-file digests;
it does not mutate it. Dirty or unsupported sources are reported as blocked.

```sh
python3 installer.py plan \
  --source /path/to/hermes-agent \
  --trusted-manifest-sha256 MANIFEST_SHA256

python3 installer.py candidate \
  --source /path/to/hermes-agent \
  --output /tmp/hermes-fleet-candidate \
  --trusted-manifest-sha256 MANIFEST_SHA256
```

Candidate staging makes a separate local Git clone outside the source checkout. Stock source
uses `overlay.patch`; an exact clean ECD preimage uses the two-file `upgrade.patch`. It records
the source commit and tree, candidate diff, selected patch, and manifest digest. A mismatch or
patch conflict stops staging without changing the source.

## Validate, then apply source files

Validate the candidate with the approved Hermes test interpreter that already has `pytest`.
The command runs a fixed set of pairing, Telegram owner-context, gateway prompt, and dashboard
auth tests through Hermes's `scripts/run_tests.sh`. It uses a temporary `HOME` (therefore a
temporary `~/.hermes`) and runtime directory, preserves the complete output at the requested
new `--log` path, and records a receipt only when the runner exits 0. Apply checks the log
against the receipt digest and fixed command. It will not provision or refresh a PM environment.

```sh
python3 installer.py validate \
  --candidate /tmp/hermes-fleet-candidate \
  --python /path/to/approved/hermes-test-python \
  --log /tmp/hermes-fleet-candidate-tests.log \
  --trusted-manifest-sha256 MANIFEST_SHA256

python3 installer.py apply \
  --source /path/to/hermes-agent \
  --candidate /tmp/hermes-fleet-candidate \
  --state /tmp/hermes-fleet-overlay-state \
  --trusted-manifest-sha256 MANIFEST_SHA256
```

Apply requires the same clean source path, commit, tree, capability preimages, release digest,
and candidate test receipt recorded during staging. It writes only allowlisted Hermes source
files and stores preimages plus a recovery journal under the external state directory. It never
changes `HERMES_HOME`, profiles, credentials, memory, skills, databases, launch settings, or
services. Hermes owns its runtime: use the supported Hermes PM procedure for the specific
installation to refresh it; do not use raw `pip`/`uv`. Review and approve service activation or a
restart separately. This tool does not perform either action.

## Roll back source files

Pass the journal path printed by `apply`:

```sh
python3 installer.py rollback \
  --journal /tmp/hermes-fleet-overlay-state/txn-ID/journal.json \
  --trusted-manifest-sha256 MANIFEST_SHA256
```

Rollback checks the exact source commit, release, backup hashes, and every changed file before
writing. It refuses if an allowlisted file has changed since apply. It restores only files in
that transaction; newer unrelated source changes and all user homes/runtime state are preserved.

## Compatibility boundary

The supported inputs are clean source trees whose allowlisted file digests exactly match the
stock baseline or the recorded ECD overlay. The candidate itself must pass the fixed tests.
An upstream update that changes any relevant file is a compatibility review gate: rebuild and
review a new offline release with explicit provenance, hashes, and test results before use.
Matching ancestry alone never grants compatibility. The readiness helper independently checks
source/runtime capabilities and reports external observations as pending; it never issues a
pairing credential. Owner QR display and actual private Telegram ownership remain separate,
explicitly approved operations.
