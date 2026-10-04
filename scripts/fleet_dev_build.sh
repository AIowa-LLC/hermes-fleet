#!/usr/bin/env bash
# Repository-only Dev build/archive/local export. No upload or account mutation.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "FLEET-DEV-FAIL: $*" >&2; exit 1; }
MODE="${1:-}"; [ "$#" -gt 0 ] && shift
SHA=""; BUILD=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sha) SHA="${2:?--sha needs a full SHA}"; shift ;;
    --build) BUILD="${2:?--build needs an approved unused Dev build}"; shift ;;
    *) fail "unknown option $1 (no Xcode argument passthrough)" ;;
  esac
  shift
done
case "$MODE" in simulator|structure-only|export) ;; *) fail "usage: $0 simulator|structure-only|export --sha FULL_SHA --build N" ;; esac
[ -n "$SHA" ] && [ -n "$BUILD" ] || fail "explicit SHA and Dev build required"
[ -z "${XCODE_XCCONFIG_FILE:-}" ] || fail "global xcconfig override forbidden"
python3 scripts/fleet_dev_guard.py --sha "$SHA" --build "$BUILD"
# An atomic per-checkout lock rejects concurrent generation/build in this lane.
mkdir -p build/FleetDev
LOCK=build/FleetDev/run.lock
mkdir "$LOCK" 2>/dev/null || fail "this lane is busy; preserve evidence and wait"
trap 'rmdir "$LOCK"' EXIT
OUT="$(mktemp -d "build/FleetDev/${SHA}-${BUILD}-${MODE}.XXXXXX")"
echo "Fleet Dev evidence: $OUT"
printf 'sha=%s\nbuild=%s\nmode=%s\n' "$SHA" "$BUILD" "$MODE" >"$OUT/provenance.txt"
xcodebuild -version >>"$OUT/provenance.txt"
# Run generation in this isolated checkout only. Dirty drift is preserved and
# fails; never reset or restore source to make this pass.
xcodegen generate >"$OUT/generation.log" 2>&1
python3 scripts/fleet_dev_guard.py --sha "$SHA" --build "$BUILD"
DEST='generic/platform=iOS'
CONFIG=Release
if [ "$MODE" = simulator ]; then
  [ -z "${HERMES_FLEET_SIM_UDID:-}" ] || fail "explicit/shared simulator override forbidden in Dev wrapper"
  export HERMES_FLEET_LANE_SIM=1
  source scripts/sim_destination.sh
  resolve_sim_destination iphone
  [ "$SIM_SELECTION" = lane ] || fail "lane simulator required"
  DEST="$SIM_DEST"; CONFIG=Debug
  sim_metadata_lines >>"$OUT/provenance.txt"
fi
ARGS=(-project HermesFleetApp.xcodeproj -scheme HermesFleetDev -configuration "$CONFIG"
      -destination "$DEST" -derivedDataPath "$OUT/DerivedData" -jobs 2
      CURRENT_PROJECT_VERSION="$BUILD" FLEET_DEV_SOURCE_SHA="$SHA")
[ "$MODE" = export ] || ARGS+=(CODE_SIGNING_ALLOWED=NO)
xcodebuild "${ARGS[@]}" -showBuildSettings -json >"$OUT/settings.json" 2>"$OUT/settings.log"
python3 scripts/fleet_dev_guard.py --settings "$OUT/settings.json" --build "$BUILD" --artifact-sha "$SHA"
if [ "$MODE" = simulator ]; then
  xcodebuild "${ARGS[@]}" build >"$OUT/build.log" 2>&1
  python3 scripts/fleet_dev_guard.py --app "$OUT/DerivedData/Build/Products/Debug-iphonesimulator/HermesFleetDev.app" --build "$BUILD" --artifact-sha "$SHA" --platform iPhoneSimulator
else
  ARCHIVE="$OUT/HermesFleetDev.xcarchive"
  xcodebuild "${ARGS[@]}" -archivePath "$ARCHIVE" archive >"$OUT/archive.log" 2>&1
  APP="$ARCHIVE/Products/Applications/HermesFleetDev.app"
  python3 scripts/fleet_dev_guard.py --app "$APP" --build "$BUILD" --artifact-sha "$SHA" --platform iPhoneOS
  if [ "$MODE" = export ]; then
    # No -allowProvisioningUpdates: missing setup fails without registering IDs.
    python3 scripts/fleet_dev_guard.py --sha "$SHA" --build "$BUILD"
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
      -exportOptionsPlist Config/FleetDevExportOptions.plist >"$OUT/export.log" 2>&1
    # Reuse existing distribution signature/profile/privacy inspection. It does
    # not replace Xcode's internal-only export restriction.
    python3 scripts/fleet_dev_export_inspect.py "$OUT" "$BUILD"
  fi
fi
python3 scripts/fleet_dev_guard.py --sha "$SHA" --build "$BUILD"
[ "$MODE" != export ] || echo 'Local internal-only export complete; upload, processing and device acceptance NOT RUN.'
[ "$MODE" != structure-only ] || echo 'Unsigned Dev archive structure only; TestFlight readiness NOT PROVEN.'
