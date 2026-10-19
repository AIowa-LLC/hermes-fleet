# Reproducing the completed DEV19 releases locally

| App / scheme | Version | Build | Bundle ID | Release source |
|---|---|---|---|---|
| HermesFleetDev | 0.1.0 | 19 | com.aiowa.hermesfleet.dev | `38867cb3e96220f97202ecf7e64dc872e0e05f12` |
| HermesFleetApp | 0.2.0 | 98 | com.aiowa.hermesfleet | `250e3ec232cc0187bb55019a769bb6ed69158d9e` |

The reconciled branch contains both release sources and the later artifact records.
Its shared app/package source is unchanged from DEV19. The only source difference
between the shipped commits is the Dev-only Watch bridge handling of
`sessionTooLongToReload`. Dev storage, credentials, pairing and URL schemes stay
separate from production. No new release is allocated by this reconciliation.

## Toolchain and dependency graph

Use Xcode 27.0 (27A266a), Swift 6 language mode, XcodeGen and the installed iOS/watchOS
simulator runtimes. The deployment floor remains 26.0. `project.yml` is authoritative;
always run `xcodegen generate` and commit its generated project when changing it.
CI selects the `xcode-27` image and Xcode 27.0 explicitly; hosted simulator jobs
create their own lane device. UI lanes boot it and wait for CoreSimulator boot
completion before running XCTest. The older floating `macos-latest` default built with
Xcode 26.6/iOS 26.5, where the unchanged long-chat newest-page assertions failed.
Those results remain separate compatibility evidence; no assertion is relaxed
by matching the toolchain used for the distributed build.

The committed workspace `Package.resolved` is copied from the retained DEV19
checkout; it preserves that graph without upgrading any dependency. Pass
`-onlyUsePackageVersionsFromResolvedFile` to Xcode when verifying it.

## Current reconciled checkout

Run these commands from a clean reconciliation checkout, with no other build
using that checkout. The default Dev phone and Watch build is 19; production is 98.
The Dev wrapper records the current source SHA, so a reconciliation build is not
misrepresented as an original distributed binary.

```sh
xcodegen generate
bash scripts/c1_static.sh
bash scripts/c1_packages.sh
export HERMES_FLEET_LANE_SIM=1
bash scripts/c1_units.sh
bash scripts/c1_ui_matrix.sh --all
bash scripts/fleet_dev_build.sh simulator --sha "$(git rev-parse HEAD)" --build 19
bash scripts/fleet_dev_build.sh test --sha "$(git rev-parse HEAD)" --build 19
```

`make dev-check` is the focused development loop. The complete UI matrix is the
broader regression gate; a focused subset does not replace it. Build and test
outputs stay under this worktree's ignored `build/` and per-run diagnostic paths.
No live gateway, credentials or paired phone are needed for deterministic tests.

## Exact original release source

Keep the original release branches immutable. Create a separate detached worktree
for the desired full SHA from the table above. From the reconciled checkout:

```sh
LOCK_SOURCE="$PWD/HermesFleetApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
REPRO_ROOT="$(mktemp -d)"
# Set SOURCE_SHA to one full release SHA from the table.
git worktree add --detach "$REPRO_ROOT/source" "$SOURCE_SHA"
cd "$REPRO_ROOT/source"
xcodegen generate
mkdir -p HermesFleetApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp "$LOCK_SOURCE" HermesFleetApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

For the original Dev source, use an explicit unsigned simulator build with build
19 and its source SHA; its historical project defaults are 1. The guarded Dev
wrapper requires the source to descend from current `origin/main`, so it can
reject a historical release checkout after main advances. This compilation-only
command keeps the original source and independent identity without changing that
release guard:

```sh
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetDev \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DEV19Reproduction -skipMacroValidation \
  -onlyUsePackageVersionsFromResolvedFile CURRENT_PROJECT_VERSION=19 \
  FLEET_DEV_SOURCE_SHA="$SOURCE_SHA" CODE_SIGNING_ALLOWED=NO build
```

For the production source, an unsigned simulator build with the retained dependency
graph is sufficient to reproduce compilation locally:

```sh
xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DEV19Reproduction -skipMacroValidation \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build
```

The existing local archive/export entry points are `scripts/fleet_dev_build.sh`
(`structure-only` / `export`, explicit Dev build and SHA) and
`scripts/archive_and_export.sh` (production build and SHA). Signing requires the
existing private local setup. Do not upload either already-distributed build again.
Recompilation is not a claim of byte-identical signing/export; retain the original
archives and IPAs for binary provenance. Their digests are recorded in `RELEASES.md`.

## Cleanup boundaries

`make clean` removes only `build/DerivedData` and package `.build` caches in the
current checkout. It keeps the tracked Xcode project, archives, IPAs, release
preflight evidence, test receipts and screenshots. Run it only while this checkout
is idle. Never use a blanket `git clean -xfd` or delete all of `build/`.

Local release archives, unique source, private operator evidence, ambiguous files,
and worktrees remain retained. Historical milestone docs and scripts stay in their
archive directories as references; they do not define current release status.
