#!/bin/bash
# archive_and_export.sh — provenance-verified archive + export lane.
#
# Prevents a repeat of the Build 46 wrong-tree incident: refuses to archive
# unless the working tree is the canonical repository checkout on the
# expected integration branch, with a clean tree at a known commit.
#
# Usage:
#   scripts/archive_and_export.sh <build-number> [expected-sha]
#
# Environment:
#   FLEET_RELEASE_ALLOW_DIRTY=1   skip the clean-tree check (NOT recommended)
set -euo pipefail

BUILD_NUM="${1:?usage: archive_and_export.sh <build-number> [expected-sha]}"
EXPECTED_SHA="${2:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() { echo "PROVENANCE-FAIL: $*" >&2; exit 2; }

# 1. Canonical repository identity: the git common dir must live under the
#    canonical repo, NOT under the stale public mirror.
CANONICAL_MARKER=".git"
COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir)"
case "$COMMON_DIR" in
  */code/hermes-fleet/.git) : ;;
  *) fail "git common dir '$COMMON_DIR' is not the canonical hermes-fleet repository (wrong checkout?)" ;;
esac

# 2. Branch guard: release builds come from the integration lane only.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
case "$BRANCH" in
  dogfood/build-41-integration|main|release/*) : ;;
  *) fail "branch '$BRANCH' is not a release lane (expected dogfood/build-41-integration, main, or release/*)" ;;
esac

# 3. Clean tree (uncommitted source in a release artifact = unreproducible).
if [[ "${FLEET_RELEASE_ALLOW_DIRTY:-0}" != "1" ]]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    fail "working tree has uncommitted tracked changes (commit first, or set FLEET_RELEASE_ALLOW_DIRTY=1 to override)"
  fi
fi

# 4. SHA pin.
HEAD_SHA="$(git rev-parse HEAD)"
if [[ -n "$EXPECTED_SHA" && "$HEAD_SHA" != "$EXPECTED_SHA" ]]; then
  fail "HEAD $HEAD_SHA != expected $EXPECTED_SHA"
fi

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
