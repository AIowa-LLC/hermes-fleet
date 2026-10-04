# Hermes Fleet Dev: isolated internal build lane

Status: **prepared, target integration blocked on shared-file coordination**.
This patch deliberately does not add a runnable target to `project.yml`, modify
its generated project, or wire shared runtime identities. It supplies dedicated
Dev configuration, fail-closed tooling and synthetic contract tests. The wrapper
rejects current main before Xcode runs. There is no Dev simulator, device,
archive, signing, export, TestFlight or processing acceptance evidence yet.

## Scope and ownership

The lane started from freshly fetched main
`2dd0e4a40961540f1f7506b221d173fcee8137e1`. The ownership audit found:

| Surface | Concurrent proposal | Coordination needed |
| --- | --- | --- |
| `project.yml`, generated Xcode project, production `Info.plist`, app groups/shared keychain | #169 extension kit | Integrator must combine Dev and extension identities before target edits. |
| Conversation shortcut/deep-link code | #168 local notifications | Agree on the Dev scheme and tap-routing isolation. |
| `FleetServiceGraph.swift` | #178 CI reuse qualification; #171 OAuth; #166 file protection; #168 notifications | Preserve each change and coordinate cache identity integration. |
| UI readiness and result parsing | #181 | No changes in this lane. |
| Production version, Build 97 archives, release ledger and ancestry floor | Release owner | No changes in this lane. |

No current lane is replaced, stopped, merged, rebased or duplicated. Do not
merge this preparatory work and describe it as a completed Dev app. Coordinate
and complete the integration below, regenerate once, then validate the exact
combined source. These tools do not change CI topology, required checks, test
parsers, package counts or UI registration.

## Identity contract

| Boundary | Production | Proposed Dev |
| --- | --- | --- |
| Target / scheme | `HermesFleetApp` | `HermesFleetDev` |
| Display name | Hermes Fleet | Hermes Fleet Dev |
| Bundle | `com.aiowa.hermesfleet` | `com.aiowa.hermesfleet.dev` |
| URL scheme | `hermes-fleet` | `hermes-fleet-dev` |
| Marketing/build source | Existing production settings | Independent `0.1.0` / `1` initial defaults |
| Files / standard defaults / notification center | Production app sandbox | Separate Dev app sandbox and defaults domain |
| Default keychain access group | Production bundle identity | Dev bundle identity, no sharing |
| Keychain service prefix | Existing production prefix | `com.aiowa.hermesfleet.dev` |
| Cache directory | `HermesFleetCache` | `HermesFleetDevCache` within the Dev sandbox |
| App groups / push / extensions | None on audited main | None in initial Dev lane; capability guard rejects additions |

No production data is imported or migrated into Dev. Identical local notification
request IDs cannot cross the two app notification centers. If #169 shared groups
or #168/#176 notifications land, re-audit actual capabilities and routing before
building Dev. Future Dev groups must have their own explicitly registered suffix,
shared-keychain access group and extension bundle identities. Do not attach
`SharedGroups.entitlements` or any production group to Dev. This initial guard
intentionally rejects all app-group/push/extension additions until a separately
reviewed capability change extends its tests.

The Dev build counter must be owner-approved and unused **for the Dev ASC app**.
The wrapper requires `--build N` (1..9999), records it, and never discovers,
auto-increments or changes production `CURRENT_PROJECT_VERSION`. Defaults in
`Config/FleetDev.xcconfig` are not evidence of an unused ASC number.

## Required integrator changes (pending)

1. Add an explicit `HermesFleetDev` application target and same-named scheme to
   authoritative `project.yml`. Use the same app sources, privacy resource,
   package dependencies, device family and deployment target as production.
   Attach `Config/FleetDev.xcconfig` via target `configFiles` for both Debug and
   Release. Set target-level `PRODUCT_BUNDLE_IDENTIFIER`, `PRODUCT_NAME`,
   `INFOPLIST_FILE`, `CODE_SIGN_ENTITLEMENTS`, display name, Dev version/build,
   `FLEET_DEV_BUILD`, `FLEET_URL_SCHEME` and `FLEET_DEV` condition as specified
   there. Preserve production target settings. Use `GENERATE_INFOPLIST_FILE: YES`
   and the existing `FleetWing` icon initially. Build only `HermesFleetDev` in
   this scheme; tests get separate explicit targets in a later coordinated
   integration. Do not include production app/test bundles in the Dev scheme.
2. Introduce a small `FleetAppIdentity` API in a suitable shared module.
   `keychainNamespace` must preserve the existing production prefix and return
   the Dev prefix only for the exact Dev app bundle. Do not use a Swift package
   compilation flag: app-target conditions do not propagate to package targets.
   Bundle-based identity must be injectable for synthetic tests. Reject an
   inconsistent Dev marker/bundle combination instead of silently using
   production. Expose `conversationURLScheme` and a cache directory component
   through the same validated identity.
3. Wire `KeychainCredentialStore`, `KeychainTokenStore`, `KeychainPinStore` to
   `FleetAppIdentity.keychainNamespace`, retaining their service suffixes.
   `KeychainInstallHygiene` already enumerates those store service names; verify
   first-launch cleanup can touch only the current app's services/access group.
   Reconcile any incoming OAuth/shared-keychain store with the same policy.
   Keychain accessibility, no-sync policy and credential handling stay intact.
4. Wire `FleetConversationDeepLink` to
   `FleetAppIdentity.conversationURLScheme`, importing its module. Validate both
   emitted and accepted URLs. Production rejects Dev links; Dev rejects
   production links. Reconcile notification and intent tap-routing against the
   same identity. Keep production `Info.plist` unchanged; Dev uses its dedicated
   `Config/FleetDevInfo.plist` with the same privacy/ATS policy.
5. Coordinate `FleetServiceGraph` to select the cache component through the
   validated identity without changing the production directory or recovery
   behavior. Other sandbox-local caches and `UserDefaults.standard` already
   separate naturally by app identity; audit future group/suite storage.
6. Add runtime isolation tests: synthetic credentials saved/deleted through one
   namespace do not affect the other; Dev install reconciliation cannot delete
   production secrets; cross-app URLs rejected; separate defaults/cache URLs;
   effective Info.plist and signed entitlements match the actual target.
   Register affected test counts/suites through the existing CI integrator.
7. Run `xcodegen generate`, review deterministic generated changes and the
   smallest relevant runtime tests, then the broader gate required for shared
   security/composition-root changes. Preserve original failures and retries.
   Commit the combined target/runtime changes before invoking these wrappers.

The source guard checks for the explicit Dev target/scheme and identity consumer
integration, then the resolved Xcode settings and actual app metadata. These
checks are rejection boundaries, not proof that runtime isolation is correct;
step 6 remains required. Never loosen the guard to force this preparation past
its intentionally missing target.

## Commands after integration

From the isolated, freshly fetched lane with all source committed:

```sh
python3 scripts/fleet_dev_contract_test.py
SHA="$(git rev-parse HEAD)"
bash scripts/fleet_dev_build.sh simulator --sha "$SHA" --build 1
bash scripts/fleet_dev_build.sh structure-only --sha "$SHA" --build 1
# Requires separately approved Apple setup and an unused Dev build number:
bash scripts/fleet_dev_build.sh export --sha "$SHA" --build 1
```

`simulator` uses Debug's existing synthetic simulator graph, the repository's
per-worktree `lane_simulator.sh` via `sim_destination.sh`, two build jobs and
separate derived data. It refuses an explicit/shared simulator override and
never installs or launches the production app. It builds/inspects only; after
acceptance, install and launch the inspected **Dev** bundle on that lane's device
using ordinary `simctl` commands. No personal endpoints or credentials belong
in fixtures. Release archives retain Release's security behavior; this patch
adds no device-only fixture or authentication override.

`structure-only` produces an unsigned device archive. `export` archives with
existing signing assets and exports locally using the committed plist, with
`destination=export`, `testFlightInternalTestingOnly=true` and automatic build
number management disabled. There is no upload, credential validation,
provisioning-update switch or argument passthrough. Xcode 27's local help confirms
that this export flag prevents external TestFlight/App Store distribution.
Keep that restriction even after a future authorized upload workflow is added.
The reference Hermex branch workflow uploads; this Fleet lane stops at local
export and preserves Fleet's existing release ancestry guard.

Every command requires clean tracked/untracked source, exact full SHA equal to
HEAD, the committed integration floor and `origin/main` ancestry. Fetch main
first. Ignored files under source/Config inputs are rejected too. Generation
runs only in this checkout; any drift is retained and fails. A per-checkout lock
rejects overlapping wrapper invocations. If interrupted with a retained lock,
confirm this lane has no active wrapper/Xcode process before removing only its
empty `build/FleetDev/run.lock` directory. Unique SHA/build/mode evidence folders
retain generation, resolved settings, commands' logs and provenance on failure.
No failed archive is accepted as distribution evidence. No other simulator,
Xcode process, checkout, lock, archive or evidence is removed.

## Apple setup and approval boundary

A read-only local profile audit found profiles for production Fleet and no local
profile matching the proposed Dev bundle. It did not query authenticated ASC app
records; absence of a local profile does not prove an Apple record is absent.
This repository patch does not create any Apple record or change permissions.
The release owner must separately inspect/approve:

1. An explicit Developer App ID for the Dev bundle and an App Store Connect app
   record for Hermes Fleet Dev, under the intended existing team. Confirm an
   existing record first; create only with separate authorization.
2. Dev-specific development and App Store provisioning profiles backed by
   existing authorized certificates. Do not share production access groups or
   register optional app-group/push/extension capabilities in this initial lane.
3. An unused Dev app build number and appropriate ASC user roles/internal tester
   membership. Internal TestFlight access follows Apple account roles; simulator
   success does not establish it.
4. Exact combined-source CI/ancestry evidence, inspected Dev archive and IPA,
   explicit upload approval, Apple's validation/upload and processing result,
   export compliance answers, internal tester assignment and installation beside
   production on a physical device. Verify production data remains intact and
   Dev keychain, links and notifications stay isolated there.

Creating records, registering identifiers/capabilities, changing signing/security
permissions, adding secrets, uploading to TestFlight, merging or publishing
source are outside this patch. Shipped Build 97 and its immutable artifact and
release number remain unchanged. Production upload automation, ASC build-number
lookup, hosted pins and workflow templates belong in subsequent phased work.

References: [Fleet development](DEVELOPMENT.md), [Dev Loop](dev-loop.md),
[release preflight](release-preflight.md),
[Hermex branch configuration](https://github.com/uzairansaruzi/hermex/blob/master/Config/BranchTestFlight.xcconfig),
[Hermex internal-only export](https://github.com/uzairansaruzi/hermex/blob/master/Config/BranchTestFlightExportOptions.plist).
