#!/bin/bash
# Deterministic repository-side release preflight for Issue #14.
#
# The signed path is the default. --structure-only is an explicit local
# fallback for a machine without distribution signing/provisioning; it proves
# the archive contents but is never reported as a signed release. This script
# never uploads to App Store Connect.
set -euo pipefail
cd "$(dirname "$0")/.."

EXPECTED_SHA=""
EXPECTED_BUILD=""
EXPECTED_VERSION=""
OUTPUT_ROOT=""
ARCHIVE_PATH=""
STRUCTURE_ONLY=0
APPLE_VALIDATE=0
PROVISIONING_FLAG=""

usage() {
  cat <<'EOF'
usage: scripts/release_preflight.sh --sha FULL_GIT_SHA [options]

Required:
  --sha SHA                         Exact HEAD SHA to release.

Options:
  --expected-build N                Require CURRENT_PROJECT_VERSION to be N.
  --expected-version VERSION        Require MARKETING_VERSION to be VERSION.
  --output-root PATH                Build/report root (default: build/release-preflight/SHA).
  --archive-path PATH               Archive path (default: OUTPUT_ROOT/HermesFleetApp.xcarchive).
  --structure-only                  Skip distribution signing; inspect an unsigned archive.
  --validate                        Export an IPA and run credentialed Apple validation.
  --allow-provisioning-updates      Allow xcodebuild to contact Apple during archive/export.
  -h, --help                        Show this help.

Credentialed validation requires ASC_API_KEY_ID, ASC_API_ISSUER_ID, and
ASC_API_KEY_PATH. The private key must already be installed in the App Store
Connect toolchain's secure key location; no password or private-key material
is accepted on the command line or written by this script.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha)
      [[ $# -ge 2 ]] || { echo "--sha requires a full Git SHA" >&2; exit 2; }
      EXPECTED_SHA="$2"
      shift 2
      ;;
    --expected-build)
      [[ $# -ge 2 ]] || { echo "--expected-build requires a value" >&2; exit 2; }
      EXPECTED_BUILD="$2"
      shift 2
      ;;
    --expected-version)
      [[ $# -ge 2 ]] || { echo "--expected-version requires a value" >&2; exit 2; }
      EXPECTED_VERSION="$2"
      shift 2
      ;;
    --output-root)
      [[ $# -ge 2 ]] || { echo "--output-root requires a path" >&2; exit 2; }
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    --archive-path)
      [[ $# -ge 2 ]] || { echo "--archive-path requires a path" >&2; exit 2; }
      ARCHIVE_PATH="$2"
      shift 2
      ;;
    --structure-only)
      STRUCTURE_ONLY=1
      shift
      ;;
    --validate)
      APPLE_VALIDATE=1
      shift
      ;;
    --allow-provisioning-updates)
      PROVISIONING_FLAG="-allowProvisioningUpdates"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$EXPECTED_SHA" ]] || { echo "ERROR: --sha is required" >&2; exit 2; }
ACTUAL_SHA="$(git rev-parse --verify HEAD)"
if [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
  echo "ERROR: HEAD is not the requested release SHA" >&2
  echo "  requested: $EXPECTED_SHA" >&2
  echo "  actual:    $ACTUAL_SHA" >&2
  exit 1
fi
if [[ "$APPLE_VALIDATE" -eq 1 && "$STRUCTURE_ONLY" -eq 1 ]]; then
  echo "ERROR: --validate requires a signed archive; remove --structure-only" >&2
  exit 2
fi

if [[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "Clean checkout: PASS"
else
  echo "ERROR: release preflight requires a clean checkout" >&2
  git status --short >&2
  exit 1
fi

echo "Release SHA: $EXPECTED_SHA"
echo "Commit: $(git show -s --format='%s' HEAD)"

echo "=== XcodeGen drift ==="
bash scripts/xcodegen_drift_gate.sh

if [[ -z "$OUTPUT_ROOT" ]]; then
  OUTPUT_ROOT="build/release-preflight/$EXPECTED_SHA"
fi
if [[ -z "$ARCHIVE_PATH" ]]; then
  ARCHIVE_PATH="$OUTPUT_ROOT/HermesFleetApp.xcarchive"
fi
mkdir -p "$OUTPUT_ROOT"
if [[ -e "$ARCHIVE_PATH" ]]; then
  echo "ERROR: archive path already exists; choose a new disposable output root: $ARCHIVE_PATH" >&2
  exit 1
fi

REPORT="$OUTPUT_ROOT/preflight-report.txt"
SETTINGS_LOG="$OUTPUT_ROOT/show-build-settings.log"
BUILD_LOG="$OUTPUT_ROOT/release-build.log"
ARCHIVE_LOG="$OUTPUT_ROOT/archive.log"
ARCHIVE_DERIVED="$OUTPUT_ROOT/archive-derived"
BUILD_DERIVED="$OUTPUT_ROOT/build-derived"

XCODE_VERSION="$(xcodebuild -version)"
echo "=== Xcode ==="
echo "$XCODE_VERSION"
XCODE_MAJOR="$(awk '/^Xcode / { split($2, v, "."); print v[1]; exit }' <<<"$XCODE_VERSION")"
if [[ "$XCODE_MAJOR" != "26" ]]; then
  echo "ERROR: this repository release policy expects Xcode 26.x (found Xcode $XCODE_MAJOR)" >&2
  exit 1
fi

echo "=== Release build settings ==="
xcodebuild -project HermesFleetApp.xcodeproj \
  -scheme HermesFleetApp \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -showBuildSettings >"$SETTINGS_LOG"

setting() {
  awk -F ' = ' -v key="$1" '$1 ~ "^[[:space:]]*" key "[[:space:]]*$" { print $2; exit }' "$SETTINGS_LOG"
}

BUNDLE_ID="$(setting PRODUCT_BUNDLE_IDENTIFIER)"
MARKETING_VERSION="$(setting MARKETING_VERSION)"
BUILD_NUMBER="$(setting CURRENT_PROJECT_VERSION)"
TARGETED_DEVICE_FAMILY="$(setting TARGETED_DEVICE_FAMILY)"
DEPLOYMENT_TARGET="$(setting IPHONEOS_DEPLOYMENT_TARGET)"
TEAM="$(setting DEVELOPMENT_TEAM)"
SIGNING_STYLE="$(setting CODE_SIGN_STYLE)"
echo "Bundle identifier: $BUNDLE_ID"
echo "Marketing version: $MARKETING_VERSION"
echo "Build number: $BUILD_NUMBER"
echo "Targeted device family: $TARGETED_DEVICE_FAMILY"
echo "Deployment target: $DEPLOYMENT_TARGET"
echo "Development team: $TEAM"
echo "Signing style: $SIGNING_STYLE"

[[ "$BUNDLE_ID" == "com.aiowa.hermesfleet" ]] || { echo "ERROR: unexpected bundle identifier" >&2; exit 1; }
[[ "$TARGETED_DEVICE_FAMILY" == "1,2" || "$TARGETED_DEVICE_FAMILY" == "1 2" ]] || {
  echo "ERROR: expected iPhone and iPad device family (1,2), found '$TARGETED_DEVICE_FAMILY'" >&2
  exit 1
}
[[ "$DEPLOYMENT_TARGET" == "26.0" ]] || { echo "ERROR: unexpected deployment target '$DEPLOYMENT_TARGET'" >&2; exit 1; }
[[ "$TEAM" == "3JS22HX92T" ]] || { echo "ERROR: unexpected development team '$TEAM'" >&2; exit 1; }
if [[ -n "$EXPECTED_BUILD" && "$BUILD_NUMBER" != "$EXPECTED_BUILD" ]]; then
  echo "ERROR: expected build $EXPECTED_BUILD, settings report $BUILD_NUMBER" >&2
  exit 1
fi
if [[ -n "$EXPECTED_VERSION" && "$MARKETING_VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "ERROR: expected version $EXPECTED_VERSION, settings report $MARKETING_VERSION" >&2
  exit 1
fi

echo "=== Release build ==="
if xcodebuild -project HermesFleetApp.xcodeproj \
    -scheme HermesFleetApp \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$BUILD_DERIVED" \
    -skipMacroValidation \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    $PROVISIONING_FLAG \
    build >"$BUILD_LOG" 2>&1; then
  echo "Release build: PASS"
else
  echo "Release build: FAIL" >&2
  tail -40 "$BUILD_LOG" >&2
  exit 1
fi

echo "=== Archive ==="
if [[ "$STRUCTURE_ONLY" -eq 1 ]]; then
  echo "Archive mode: structure-only (unsigned fallback; not release-ready)"
  if xcodebuild -project HermesFleetApp.xcodeproj \
      -scheme HermesFleetApp \
      -configuration Release \
      -destination 'generic/platform=iOS' \
      -archivePath "$ARCHIVE_PATH" \
      -derivedDataPath "$ARCHIVE_DERIVED" \
      -skipMacroValidation \
      DEVELOPMENT_TEAM=3JS22HX92T CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
      $PROVISIONING_FLAG \
      archive >"$ARCHIVE_LOG" 2>&1; then
    echo "Archive: PASS"
  else
    echo "Archive: FAIL" >&2
    tail -60 "$ARCHIVE_LOG" >&2
    exit 1
  fi
else
  echo "Archive mode: signed-by-default"
  if xcodebuild -project HermesFleetApp.xcodeproj \
      -scheme HermesFleetApp \
      -configuration Release \
      -destination 'generic/platform=iOS' \
      -archivePath "$ARCHIVE_PATH" \
      -derivedDataPath "$ARCHIVE_DERIVED" \
      -skipMacroValidation \
      DEVELOPMENT_TEAM=3JS22HX92T \
      $PROVISIONING_FLAG \
      archive >"$ARCHIVE_LOG" 2>&1; then
    echo "Archive: PASS"
  else
    echo "Archive: FAIL" >&2
    tail -60 "$ARCHIVE_LOG" >&2
    echo "If this machine lacks distribution signing/provisioning, rerun explicitly with --structure-only for structural evidence; do not call that release-ready." >&2
    exit 1
  fi
fi

APP="$ARCHIVE_PATH/Products/Applications/HermesFleetApp.app"
[[ -d "$APP" ]] || { echo "ERROR: archive has no HermesFleetApp.app" >&2; exit 1; }
INFO="$APP/Info.plist"
[[ -f "$INFO" ]] || { echo "ERROR: archived app has no Info.plist" >&2; exit 1; }

echo "=== Archive inspection ==="
python3 - "$INFO" "$BUNDLE_ID" "$MARKETING_VERSION" "$BUILD_NUMBER" "$TARGETED_DEVICE_FAMILY" "$DEPLOYMENT_TARGET" <<'PY'
from pathlib import Path
import plistlib
import sys

path = Path(sys.argv[1])
expected = {
    "CFBundleIdentifier": sys.argv[2],
    "CFBundleShortVersionString": sys.argv[3],
    "CFBundleVersion": sys.argv[4],
    "MinimumOSVersion": sys.argv[6],
}
with path.open("rb") as stream:
    info = plistlib.load(stream)
for key, value in expected.items():
    if str(info.get(key)) != value:
        raise SystemExit(f"archive {key}={info.get(key)!r}, expected {value!r}")
if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
    raise SystemExit(f"archive platform metadata is {info.get('CFBundleSupportedPlatforms')!r}")
families = info.get("UIDeviceFamily")
if families != [1, 2]:
    raise SystemExit(f"archive UIDeviceFamily={families!r}, expected [1, 2]")
if not info.get("DTXcode") or not info.get("DTXcodeBuild"):
    raise SystemExit("archive is missing DTXcode/DTXcodeBuild metadata")
if info.get("DTPlatformName") != "iphoneos":
    raise SystemExit(f"archive DTPlatformName={info.get('DTPlatformName')!r}")
if info.get("ITSAppUsesNonExemptEncryption") is not False:
    raise SystemExit("ITSAppUsesNonExemptEncryption must be false for this app")
print("Bundle identifier/version/build/platform/device-family/Xcode/export-compliance: PASS")
print(f"  DTXcode={info['DTXcode']} DTXcodeBuild={info['DTXcodeBuild']}")
PY

bash scripts/privacy_manifest_validate.sh --built-app "$APP"

echo "=== Signing and provisioning inspection ==="
SIGNING_LOG="$OUTPUT_ROOT/codesign-display.log"
if codesign -dvv "$APP" >"$SIGNING_LOG" 2>&1; then
  codesign --verify --deep --strict "$APP"
  SIGNING_IDENTITY="$(awk -F= '/^Authority=/ { print $2; exit }' "$SIGNING_LOG")"
  TEAM_IDENTIFIER="$(awk -F= '/^TeamIdentifier=/ { print $2; exit }' "$SIGNING_LOG")"
  DISTRIBUTION_AUTHORITY="$(awk -F= '/^Authority=(Apple Distribution|iPhone Distribution):/ { print $2; exit }' "$SIGNING_LOG")"
  echo "Code-sign verification: PASS"
  echo "  authority: $SIGNING_IDENTITY"
  echo "  team identifier: $TEAM_IDENTIFIER"
  if [[ "$STRUCTURE_ONLY" -eq 0 && -z "$DISTRIBUTION_AUTHORITY" ]]; then
    echo "ERROR: signed archive did not expose an Apple Distribution signing authority" >&2
    echo "  found: ${SIGNING_IDENTITY:-none}" >&2
    exit 1
  fi
else
  if [[ "$STRUCTURE_ONLY" -eq 0 ]]; then
    echo "ERROR: codesign metadata inspection failed" >&2
    cat "$SIGNING_LOG" >&2
    exit 1
  fi
  echo "Code-sign verification: NOT PRESENT (expected in structure-only mode)"
  cat "$SIGNING_LOG" >&2
fi

PROFILE="$APP/embedded.mobileprovision"
if [[ -f "$PROFILE" ]]; then
  PROFILE_PLIST="$OUTPUT_ROOT/embedded-profile.plist"
  security cms -D -i "$PROFILE" >"$PROFILE_PLIST"
  PROFILE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_EXPIRY="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_DEVICES="$(/usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$PROFILE_PLIST" 2>/dev/null || true)"
  echo "Provisioning profile: PASS"
  echo "  name: $PROFILE_NAME"
  echo "  expiration: $PROFILE_EXPIRY"
  echo "  application identifier: $PROFILE_APP_ID"
  if [[ "$STRUCTURE_ONLY" -eq 0 && -n "$PROFILE_DEVICES" ]]; then
    echo "ERROR: signed archive embeds a device-limited profile; TestFlight requires an App Store profile" >&2
    exit 1
  fi
else
  if [[ "$STRUCTURE_ONLY" -eq 0 ]]; then
    echo "ERROR: signed archive has no embedded provisioning profile" >&2
    exit 1
  fi
  echo "Provisioning profile: NOT PRESENT (expected in structure-only mode)"
fi

cat >"$REPORT" <<EOF
Hermes Fleet release preflight
source_sha=$EXPECTED_SHA
commit=$(git show -s --format='%s' HEAD)
xcode=$XCODE_VERSION
bundle_id=$BUNDLE_ID
marketing_version=$MARKETING_VERSION
build_number=$BUILD_NUMBER
targeted_device_family=$TARGETED_DEVICE_FAMILY
archive=$ARCHIVE_PATH
structure_only=$STRUCTURE_ONLY
apple_validation=not_run
EOF

if [[ "$APPLE_VALIDATE" -eq 1 ]]; then
  ASC_API_KEY_ID="$(printenv ASC_API_KEY_ID || true)"
  ASC_API_ISSUER_ID="$(printenv ASC_API_ISSUER_ID || true)"
  ASC_API_KEY_PATH="$(printenv ASC_API_KEY_PATH || true)"
  [[ -n "$ASC_API_KEY_ID" ]] || { echo "ERROR: ASC_API_KEY_ID is required for --validate" >&2; exit 1; }
  [[ -n "$ASC_API_ISSUER_ID" ]] || { echo "ERROR: ASC_API_ISSUER_ID is required for --validate" >&2; exit 1; }
  [[ -f "$ASC_API_KEY_PATH" ]] || { echo "ERROR: ASC_API_KEY_PATH does not exist" >&2; exit 1; }
  EXPORT_PATH="$OUTPUT_ROOT/export"
  EXPORT_OPTIONS="scripts/release_export_options.plist"
  [[ -f "$EXPORT_OPTIONS" ]] || { echo "ERROR: missing $EXPORT_OPTIONS" >&2; exit 1; }
  mkdir -p "$EXPORT_PATH"
  echo "=== Export for Apple validation ==="
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    $PROVISIONING_FLAG \
    >"$OUTPUT_ROOT/export.log" 2>&1
  IPA="$(find "$EXPORT_PATH" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
  [[ -n "$IPA" ]] || { echo "ERROR: export produced no IPA" >&2; exit 1; }
  echo "=== Apple validation ==="
  echo "Credentialed validation requested; secrets are not echoed."
  xcrun altool --validate-app -f "$IPA" -t ios \
    --apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_API_ISSUER_ID"
  echo "Apple validation: PASS"
  sed -i '' 's/^apple_validation=.*/apple_validation=pass/' "$REPORT"
else
  echo "Apple validation: NOT RUN (credential-gated; no upload attempted)"
fi

echo "=== Release preflight complete ==="
cat "$REPORT"
if [[ "$STRUCTURE_ONLY" -eq 1 ]]; then
  echo "RESULT: repository/archive structure verified; signed release acceptance remains external."
else
  echo "RESULT: signed archive preflight verified; Apple validation/upload remain explicit credentialed steps."
fi
