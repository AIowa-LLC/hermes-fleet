#!/bin/bash
# Deterministic repository-side release preflight for Issue #14.
#
# Archive inspection and distribution export are intentionally separate
# stages. An archive may be unsigned or Apple-Development-signed; Xcode's
# export step is where App Store distribution signing and provisioning are
# selected. This script never uploads to App Store Connect.
set -euo pipefail
cd "$(dirname "$0")/.."

EXPECTED_SHA=""
EXPECTED_BUILD=""
EXPECTED_VERSION=""
OUTPUT_ROOT=""
ARCHIVE_PATH=""
STRUCTURE_ONLY=0
APPLE_VALIDATE=0
ALLOW_PROVISIONING_UPDATES=0

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
  --structure-only                  Inspect an unsigned archive; do not export.
  --validate                        Export an IPA and run credentialed Apple validation.
  --allow-provisioning-updates      Let xcodebuild contact Apple during archive/export.
  -h, --help                        Show this help.

--validate requires ASC_API_KEY_ID, ASC_API_ISSUER_ID, and ASC_API_KEY_PATH.
The key path is passed directly to both xcodebuild authentication and
xcrun altool --p8-file-path; no private-key material is echoed or copied.
Without --validate, export still runs and inspects the actual IPA, but Apple
validation is reported as not run. --structure-only stops after archive
structure/provenance inspection and is never TestFlight-ready evidence.
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
      ALLOW_PROVISIONING_UPDATES=1
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
  echo "ERROR: --validate cannot be combined with --structure-only" >&2
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

ASC_API_KEY_ID="${ASC_API_KEY_ID:-}"
ASC_API_ISSUER_ID="${ASC_API_ISSUER_ID:-}"
ASC_API_KEY_PATH="${ASC_API_KEY_PATH:-}"
if [[ "$APPLE_VALIDATE" -eq 1 || "$ALLOW_PROVISIONING_UPDATES" -eq 1 ]]; then
  [[ -n "$ASC_API_KEY_ID" ]] || { echo "ERROR: ASC_API_KEY_ID is required for credentialed xcodebuild/validation" >&2; exit 1; }
  [[ -n "$ASC_API_ISSUER_ID" ]] || { echo "ERROR: ASC_API_ISSUER_ID is required for credentialed xcodebuild/validation" >&2; exit 1; }
  [[ -f "$ASC_API_KEY_PATH" ]] || { echo "ERROR: ASC_API_KEY_PATH must name an existing private key file" >&2; exit 1; }
fi
if [[ "$APPLE_VALIDATE" -eq 1 ]]; then
  [[ -r "$ASC_API_KEY_PATH" ]] || { echo "ERROR: ASC_API_KEY_PATH is not readable" >&2; exit 1; }
fi

XCODE_VERSION="$(xcodebuild -version)"
echo "=== Xcode ==="
echo "$XCODE_VERSION"
XCODE_MAJOR="$(awk '/^Xcode / { split($2, v, "."); print v[1]; exit }' <<<"$XCODE_VERSION")"
if [[ "$XCODE_MAJOR" != "26" ]]; then
  echo "ERROR: this repository release policy expects Xcode 26.x (found Xcode $XCODE_MAJOR)" >&2
  exit 1
fi

XCODE_AUTH_ARGS=()
if [[ -n "$ASC_API_KEY_PATH" && -n "$ASC_API_KEY_ID" && -n "$ASC_API_ISSUER_ID" ]]; then
  XCODE_AUTH_ARGS+=("-authenticationKeyPath" "$ASC_API_KEY_PATH")
  XCODE_AUTH_ARGS+=("-authenticationKeyID" "$ASC_API_KEY_ID")
  XCODE_AUTH_ARGS+=("-authenticationKeyIssuerID" "$ASC_API_ISSUER_ID")
fi
PROVISIONING_ARGS=()
if [[ "$ALLOW_PROVISIONING_UPDATES" -eq 1 ]]; then
  PROVISIONING_ARGS+=("-allowProvisioningUpdates")
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
BUILD_ARGS=(
  xcodebuild -project HermesFleetApp.xcodeproj
  -scheme HermesFleetApp
  -configuration Release
  -destination 'generic/platform=iOS'
  -derivedDataPath "$BUILD_DERIVED"
  -skipMacroValidation
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
)
BUILD_ARGS+=("${PROVISIONING_ARGS[@]}")
BUILD_ARGS+=("${XCODE_AUTH_ARGS[@]}")
if "${BUILD_ARGS[@]}" build >"$BUILD_LOG" 2>&1; then
  echo "Release build: PASS"
else
  echo "Release build: FAIL" >&2
  tail -40 "$BUILD_LOG" >&2
  exit 1
fi

echo "=== Archive ==="
if [[ "$STRUCTURE_ONLY" -eq 1 ]]; then
  echo "Archive mode: structure-only (unsigned fallback; not release-ready)"
  ARCHIVE_ARGS=(
    xcodebuild -project HermesFleetApp.xcodeproj
    -scheme HermesFleetApp
    -configuration Release
    -destination 'generic/platform=iOS'
    -archivePath "$ARCHIVE_PATH"
    -derivedDataPath "$ARCHIVE_DERIVED"
    -skipMacroValidation
    DEVELOPMENT_TEAM=3JS22HX92T
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
  )
else
  echo "Archive mode: normal archive; archive signing is recorded, not used as the distribution verdict"
  ARCHIVE_ARGS=(
    xcodebuild -project HermesFleetApp.xcodeproj
    -scheme HermesFleetApp
    -configuration Release
    -destination 'generic/platform=iOS'
    -archivePath "$ARCHIVE_PATH"
    -derivedDataPath "$ARCHIVE_DERIVED"
    -skipMacroValidation
    DEVELOPMENT_TEAM=3JS22HX92T
  )
fi
ARCHIVE_ARGS+=("${PROVISIONING_ARGS[@]}")
ARCHIVE_ARGS+=("${XCODE_AUTH_ARGS[@]}")
if "${ARCHIVE_ARGS[@]}" archive >"$ARCHIVE_LOG" 2>&1; then
  echo "Archive: PASS"
else
  echo "Archive: FAIL" >&2
  tail -60 "$ARCHIVE_LOG" >&2
  if [[ "$STRUCTURE_ONLY" -eq 0 ]]; then
    echo "The archive stage failed before distribution export; no archive-stage Distribution identity was required by this preflight." >&2
  fi
  exit 1
fi

APP="$ARCHIVE_PATH/Products/Applications/HermesFleetApp.app"
[[ -d "$APP" ]] || { echo "ERROR: archive has no HermesFleetApp.app" >&2; exit 1; }
INFO="$APP/Info.plist"
[[ -f "$INFO" ]] || { echo "ERROR: archived app has no Info.plist" >&2; exit 1; }
ARCHIVE_INFO="$ARCHIVE_PATH/Info.plist"
[[ -f "$ARCHIVE_INFO" ]] || { echo "ERROR: archive has no root Info.plist" >&2; exit 1; }

echo "=== Archive provenance/content inspection ==="
python3 - "$ARCHIVE_INFO" "$INFO" "$BUNDLE_ID" "$MARKETING_VERSION" "$BUILD_NUMBER" <<'PY'
from pathlib import Path
import plistlib
import sys

archive_path = Path(sys.argv[1])
app_path = Path(sys.argv[2])
expected = {
    "CFBundleIdentifier": sys.argv[3],
    "CFBundleShortVersionString": sys.argv[4],
    "CFBundleVersion": sys.argv[5],
    "MinimumOSVersion": "26.0",
}
with archive_path.open("rb") as stream:
    archive = plistlib.load(stream)
with app_path.open("rb") as stream:
    info = plistlib.load(stream)
if not isinstance(archive.get("ApplicationProperties"), dict):
    raise SystemExit("archive has no ApplicationProperties provenance dictionary")
for key, value in expected.items():
    if str(info.get(key)) != value:
        raise SystemExit(f"archive app {key}={info.get(key)!r}, expected {value!r}")
app_properties = archive["ApplicationProperties"]
for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
    if str(app_properties.get(key)) != str(info.get(key)):
        raise SystemExit(f"archive provenance {key} does not match the archived app")
if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
    raise SystemExit(f"archive platform metadata is {info.get('CFBundleSupportedPlatforms')!r}")
if info.get("UIDeviceFamily") != [1, 2]:
    raise SystemExit(f"archive UIDeviceFamily={info.get('UIDeviceFamily')!r}, expected [1, 2]")
if not info.get("DTXcode") or not info.get("DTXcodeBuild"):
    raise SystemExit("archive is missing DTXcode/DTXcodeBuild metadata")
if info.get("DTPlatformName") != "iphoneos":
    raise SystemExit(f"archive DTPlatformName={info.get('DTPlatformName')!r}")
if info.get("ITSAppUsesNonExemptEncryption") is not False:
    raise SystemExit("ITSAppUsesNonExemptEncryption must be false for this app")
print("Archive bundle/version/build/platform/device-family/Xcode/export-compliance: PASS")
print(f"  DTXcode={info['DTXcode']} DTXcodeBuild={info['DTXcodeBuild']}")
print(f"  archive signing identity (informational): {app_properties.get('SigningIdentity', '<none>')}")
print(f"  archive team (informational): {app_properties.get('Team', '<none>')}")
PY

bash scripts/privacy_manifest_validate.sh --built-app "$APP"

if [[ "$STRUCTURE_ONLY" -eq 1 ]]; then
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
structure_only=1
archive_content=pass
distribution_export=not_run
exported_artifact=not_run
apple_validation=not_run
EOF
  echo "=== Release preflight complete ==="
  cat "$REPORT"
  echo "RESULT: repository/archive structure verified; distribution signing, Apple validation, and upload remain external."
  exit 0
fi

EXPORT_PATH="$OUTPUT_ROOT/export"
EXPORT_OPTIONS="scripts/release_export_options.plist"
[[ -f "$EXPORT_OPTIONS" ]] || { echo "ERROR: missing $EXPORT_OPTIONS" >&2; exit 1; }
mkdir -p "$EXPORT_PATH"
echo "=== Distribution export ==="
echo "Export method: app-store-connect (Xcode 26 current value)"
EXPORT_ARGS=(
  xcodebuild -exportArchive
  -archivePath "$ARCHIVE_PATH"
  -exportPath "$EXPORT_PATH"
  -exportOptionsPlist "$EXPORT_OPTIONS"
)
EXPORT_ARGS+=("${PROVISIONING_ARGS[@]}")
EXPORT_ARGS+=("${XCODE_AUTH_ARGS[@]}")
if "${EXPORT_ARGS[@]}" >"$OUTPUT_ROOT/export.log" 2>&1; then
  echo "Distribution export: PASS"
else
  echo "Distribution export: BLOCKED (xcodebuild could not produce a distributable artifact)" >&2
  tail -80 "$OUTPUT_ROOT/export.log" >&2
  echo "Archive inspection passed; this is a distribution certificate/profile/account gate, not an archive-stage signing verdict." >&2
  exit 3
fi

IPA_COUNT="$(find "$EXPORT_PATH" -maxdepth 1 -type f -name '*.ipa' -print | wc -l | tr -d ' ')"
[[ "$IPA_COUNT" == "1" ]] || { echo "ERROR: expected exactly one exported IPA, found $IPA_COUNT" >&2; exit 1; }
IPA="$(find "$EXPORT_PATH" -maxdepth 1 -type f -name '*.ipa' -print -quit)"

python3 scripts/release_artifact_inspect.py \
  --ipa "$IPA" \
  --expected-bundle-id "$BUNDLE_ID" \
  --expected-version "$MARKETING_VERSION" \
  --expected-build "$BUILD_NUMBER" \
  --expected-team "$TEAM" \
  --inspection-root "$OUTPUT_ROOT/exported-artifact"
bash scripts/privacy_manifest_validate.sh --built-app "$OUTPUT_ROOT/exported-artifact/Payload/HermesFleetApp.app"

APPLE_VALIDATION="not_run"
if [[ "$APPLE_VALIDATE" -eq 1 ]]; then
  echo "=== Apple validation ==="
  echo "Credentialed validation requested; secrets are not echoed."
  if xcrun altool --validate-app "$IPA" \
      --api-key "$ASC_API_KEY_ID" \
      --api-issuer "$ASC_API_ISSUER_ID" \
      --p8-file-path "$ASC_API_KEY_PATH" \
      >"$OUTPUT_ROOT/apple-validation.log" 2>&1; then
    echo "Apple validation: PASS"
    APPLE_VALIDATION="pass"
  else
    echo "Apple validation: FAIL" >&2
    tail -80 "$OUTPUT_ROOT/apple-validation.log" >&2
    exit 1
  fi
else
  echo "Apple validation: NOT RUN (use --validate with ASC credentials; no upload attempted)"
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
structure_only=0
archive_content=pass
distribution_export=pass
exported_ipa=$IPA
exported_artifact=pass
apple_validation=$APPLE_VALIDATION
upload=not_run
EOF

echo "=== Release preflight complete ==="
cat "$REPORT"
if [[ "$APPLE_VALIDATE" -eq 1 ]]; then
  echo "RESULT: distribution artifact and Apple validation verified; App Store Connect upload/processing remain explicit external steps."
else
  echo "RESULT: distribution artifact verified; Apple validation and App Store Connect upload/processing remain explicit credentialed external steps."
fi
