# Hermes Fleet Dev

`HermesFleetDev` is an explicit side-by-side internal development app generated
from authoritative `project.yml`. Production's bundle, display name, URL scheme,
version/build settings and capabilities remain unchanged. No production data is
imported into Dev; shipped Build 97 and its retained artifact are not rebuilt.

## Identities and storage

| Boundary | Production | Dev |
| --- | --- | --- |
| App target / build scheme | `HermesFleetApp` | `HermesFleetDev` |
| Display name | Hermes Fleet | Hermes Fleet Dev |
| Bundle | `com.aiowa.hermesfleet` | `com.aiowa.hermesfleet.dev` |
| Conversation scheme | `hermes-fleet` | `hermes-fleet-dev` |
| Keychain service prefix | `com.aiowa.hermesfleet` | `com.aiowa.hermesfleet.dev` |
| Cache component | `HermesFleetCache` | `HermesFleetDevCache` |
| Version/build settings | Existing production settings | Independent `0.1.0` / `1` defaults |
| Test bundle / scheme | Existing hosted suites | `HermesFleetDevTests` |

`FleetAppIdentity` derives package namespaces from the actual host bundle and
Dev Info.plist marker; app compiler flags do not propagate to Swift packages.
A mismatched Dev bundle/marker fails closed. Production service names/cache
component stay stable. Keychain install reconciliation enumerates the selected
store namespaces, so Dev cleanup cannot purge production services. The default
keychain access group, sandbox, `UserDefaults.standard`, Shortcuts registry and
notification center belong to each app's bundle. Deep-link generation and
acceptance use that app's scheme, rejecting cross-app URLs.

There are no Dev app groups, push entitlements, shared keychain groups or
extensions. The capability/artifact guard rejects their introduction until a
separately reviewed Dev capability change extends its tests. Adding production
shared entitlements to Dev is forbidden.

## Ownership and future proposals

This lane started from freshly fetched main
`2dd0e4a40961540f1f7506b221d173fcee8137e1`. The initial preparation paused target
integration for ownership assessment. Read-only follow-up found #169/#168's
original worktrees clean, September 30 source/commit timestamps, and the local
extension reconciliation explicitly retained pending CI qualification. No active
build or uncommitted edits existed in those worktrees. The Dev lane therefore
adds its own target against present main without landing either older proposal.
Existing workers, branches and release artifacts remain untouched.

- #169 proposes production-only, default-OFF `FLEET_SHARED_GROUPS`, shared app
  group/keychain settings and FleetClientKit. Its additions occur in production
  target settings; Dev is added after the existing test targets. When that work
  is integrated, propagate package dependencies deliberately and keep Dev groups
  OFF. Enabling groups later requires Dev-specific groups/profiles/extension IDs
  and a new guard audit. Regenerate the combined project; do not merge generated
  project conflicts by hand.
- #168 adds an overload to the deep-link builder for notification taps. This lane
  only changes its scheme source and import; preserve that overload when combined.
  Notifications must continue using the app-qualified builder and notification
  center. Re-audit capabilities/tap routing if #168/#176 land.
- #178 owns service-graph comment/CI reuse qualification, #181 owns UI readiness
  and result parsing. This lane changes only the graph cache-component expression;
  no CI topology, parsers, required checks, package counts or existing test suite
  registration change. Reconcile other graph/OAuth proposals before landing.

Production project settings remain unchanged. Generated source adds the Dev app
and its dedicated test bundle/schemes. A throwaway generated overlay is not the
supported acceptance path: committed project/source and exact-SHA guards remain
mandatory. CI/protected integration acceptance is still required before landing.

## Build and test locally

Commit source first and fetch main. Use only this lane's simulator:

```sh
python3 scripts/fleet_dev_contract_test.py
SHA="$(git rev-parse HEAD)"
bash scripts/fleet_dev_build.sh simulator --sha "$SHA" --build 1
bash scripts/fleet_dev_build.sh test --sha "$SHA" --build 1
bash scripts/fleet_dev_build.sh structure-only --sha "$SHA" --build 1
# Requires separately approved Apple setup and unused Dev build number:
bash scripts/fleet_dev_build.sh export --sha "$SHA" --build 1
```

The wrapper uses the existing local runners’ per-invocation `-skipMacroValidation`
option; it does not change persistent Xcode trust settings.

Debug uses the existing synthetic simulator graph; no private endpoint or
credential is built in. Release retains existing authentication and app-lock
policy. The wrapper builds with two jobs and disables parallel test workers.
It selects `lane_simulator.sh` through `sim_destination.sh`, refuses explicit or
shared simulator overrides, and writes unique SHA/build/mode evidence folders
under `build/FleetDev/`. It never cancels another Xcode job or manages another
lane's device. Simulator mode builds/inspects only; install the inspected Dev app
and launch the Dev bundle on that lane's device after build acceptance.

The dedicated hosted suite tests the actual Dev bundle, stable production
identity, invalid metadata rejection, keychain save/delete/purge isolation,
private keychain policy, shortcut scheme rejection and synthetic defaults/cache
separation. All credentials and Keychain operations in these tests are fake.
Its eight cases must each pass once with zero skips or recovered attempts.
This scheme is independent of the existing hosted/UI CI inventory; the CI owner
may add its required coverage in a separate coordinated change.

Every mode requires a clean tracked/untracked checkout, full SHA equal to HEAD,
Fleet's unmodified committed ancestry floor and `origin/main` ancestry. Ignored
source/Config injection is rejected. XcodeGen runs only in this isolated lane;
drift is retained and fails. Resolved settings reject production/mixed app
targets; hosted settings reject production test hosts. Actual app metadata must
match Dev identities, platform, toolchain, explicit build and embedded source SHA.
A per-checkout lock rejects concurrent wrapper invocations. After interruption,
confirm this lane has no active wrapper/Xcode job before removing only its empty
`build/FleetDev/run.lock`. Retain failure logs and partial result bundles.

## Internal archive/export and Apple setup

`structure-only` creates an unsigned Dev device archive and provides structural
evidence only. `export` uses existing signing assets and exports locally with
`destination=export`, `testFlightInternalTestingOnly=true`, and automatic build
number management disabled. Xcode 27's local help states that the internal-only
flag prevents external TestFlight/App Store distribution. There is no upload,
provisioning update, credential validation or Xcode argument passthrough. Keep
this restriction in any future authorized upload workflow. The reference
[Hermex branch workflow](https://github.com/uzairansaruzi/hermex/blob/master/scripts/branch-testflight)
uploads; Fleet's wrapper deliberately stops at local export.

The initial local profile inventory found production Fleet profiles and none
matching the Dev bundle. ASC records were not queried; absence of a local profile
does not prove an Apple record is absent. Separately verify/approve:

1. The Dev Developer App ID and ASC app record under the intended existing team.
   Inspect existing records first; creating records requires separate approval.
2. Dev development and distribution provisioning profiles backed by existing
   authorized certificates. No optional app-group/push capability is needed.
3. An owner-approved unused Dev build number (the wrapper accepts 1..9999) and
   appropriate ASC user roles/internal tester membership. The initial default
   does not prove that number is unused. Production build metadata stays intact.
4. Exact-source integration evidence, inspected archive/IPA, explicit upload
   approval, Apple's validation/processing, compliance answers and internal tester
   assignment, followed by physical side-by-side installation/data isolation.

A simulator build or hosted test pass is not TestFlight readiness. Apple setup,
identifier registration, signing/security permission changes, secrets, upload,
push/PR publication and merge are outside this local implementation scope.
Future production upload automation, ASC build-number lookup and hosted pinning
remain separate phased work. See [DEVELOPMENT.md](DEVELOPMENT.md),
[dev-loop.md](dev-loop.md) and [release-preflight.md](release-preflight.md).
