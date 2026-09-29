#!/bin/bash
# Compatibility archive/export helper. Use release_preflight.sh for the full
# artifact inspection and optional Apple-validation path.
# Usage: scripts/archive_and_export.sh <approved-build-number> <expected-sha>
# Both entry points enforce clean source and committed integration ancestry.
set -euo pipefail

BUILD_NUM="${1:?usage: archive_and_export.sh <approved-build-number> <expected-sha>}"
EXPECTED_SHA="${2:?a full reviewed source SHA is required}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
fail() { echo "PROVENANCE-FAIL: $*" >&2; exit 2; }
[[ "$BUILD_NUM" =~ ^[1-9][0-9]*$ ]] || fail "build number must be a positive integer"
COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
case "$BRANCH" in
  main|release/*) : ;;
  *) fail "branch is not a release lane (expected main or release/*)" ;;
esac
HEAD_SHA="$(git rev-parse HEAD)"
[[ "$HEAD_SHA" == "$EXPECTED_SHA" ]] || fail "HEAD does not match the reviewed source SHA"
# Committed ancestry identifies the integration line without a machine-specific
# checkout path. Dirty overrides and build numbers cannot bypass this guard.
bash scripts/release_lineage_guard.sh "$HEAD_SHA"

VERSION="$(plutil -extract CFBundleShortVersionString raw "$REPO_ROOT/HermesFleetApp/Info.plist" 2>/dev/null || echo 0.2.0)"
OUT="build/rc-tf-${BUILD_NUM}"
mkdir -p "$OUT"

echo "=== provenance OK ==="
echo "repo:     $COMMON_DIR"
echo "branch:   $BRANCH"
echo "sha:      $HEAD_SHA"
echo "version:  $VERSION (${BUILD_NUM})"
echo "tree:     $([[ ${FLEET_RELEASE_ALLOW_DIRTY:-0} = 1 ]] && echo 'dirty-override' || echo clean)"

xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$OUT/HermesFleetApp.xcarchive" \
  -derivedDataPath "build/rc-tf${BUILD_NUM}-dd" \
  CURRENT_PROJECT_VERSION="$BUILD_NUM" -skipMacroValidation archive

test -f scripts/release_export_options.plist || fail "missing scripts/release_export_options.plist"
xcodebuild -exportArchive -archivePath "$OUT/HermesFleetApp.xcarchive" \
  -exportOptionsPlist scripts/release_export_options.plist \
  -exportPath "$OUT/export"

IPA="$OUT/export/HermesFleetApp.ipa"
[[ -f "$IPA" ]] || fail "export produced no IPA"
B="$(unzip -p "$IPA" 'Payload/HermesFleetApp.app/Info.plist' | plutil -extract CFBundleVersion raw -)"
V="$(unzip -p "$IPA" 'Payload/HermesFleetApp.app/Info.plist' | plutil -extract CFBundleShortVersionString raw -)"
[[ "$B" == "$BUILD_NUM" ]] || fail "IPA build $B != requested $BUILD_NUM"

echo "=== ARTIFACT ==="
echo "ipa:      $IPA"
echo "bundle:   $(unzip -p "$IPA" 'Payload/HermesFleetApp.app/Info.plist' | plutil -extract CFBundleIdentifier raw -)"
echo "version:  $V ($B)"
echo "sha256:   $(shasum -a 256 "$IPA" | awk '{print $1}')"
echo "source:   $BRANCH @ $HEAD_SHA"
