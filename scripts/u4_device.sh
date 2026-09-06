#!/bin/bash
# U4 own-device dogfood — fresh free-team sideload on the connected iPhone.
#
# Builds the app for iphoneos (Debug, free personal team 3JS22HX92T),
# verifies codesigning metadata by reference (no key material), FRESH-installs
# on the physical device (uninstall any prior copy), launches it, verifies the
# process is running, and records checksums.
#
# Distribution-readiness stays honest: free team = own-device sideload only,
# ~7-day profile rotation; no paid-tier claims are made.
#
# TOOLING: script file only, run with `bash scripts/u4_device.sh`
#   HERMES_FLEET_DEVICE_ID=<UDID> bash scripts/u4_device.sh
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
# shellcheck source=scripts/fleet_device.sh
source "$(dirname "$0")/fleet_device.sh"
PASS=0
FAIL=0
declare -a FAILURES=()

note() { printf '\n=== %s ===\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf 'FAIL  %s\n' "$1"; }

# Physical device: HERMES_FLEET_DEVICE_ID override, or unambiguous single
# eligible paired iPhone via machine-readable devicectl discovery.
DEVICE="$(resolve_fleet_device)" || exit $?
DD="$REPO/build/DerivedDataU4Device"
APP="$DD/Build/Products/Debug-iphoneos/HermesFleetApp.app"

# --- 1. Build for device (free-team automatic signing) -----------------------
note "Build Debug-iphoneos (free team 3JS22HX92T, automatic signing)"
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$DD" \
    -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=3JS22HX92T \
    build >/tmp/u4_device_build.log 2>&1; then
  ok "device BUILD SUCCEEDED"
else
  bad "device build FAILED"; tail -30 /tmp/u4_device_build.log
fi

# --- 2. Codesign verification (metadata only, no key material) ---------------
note "Codesign + embedded profile verification"
if codesign -dv --verbose=4 "$APP" >/tmp/u4_device_codesign.log 2>&1; then
  echo "  $(grep -E '^Authority|^TeamIdentifier|^Identifier' /tmp/u4_device_codesign.log | tr '\n' ' ')"
  AUTHORITY=$(grep -c '^Authority=Apple Development' /tmp/u4_device_codesign.log)
  TEAM=$(grep '^TeamIdentifier' /tmp/u4_device_codesign.log | head -1)
  if [ "$AUTHORITY" -ge 1 ] && echo "$TEAM" | grep -q '3JS22HX92T'; then
    ok "codesign identity = Apple Development (team 3JS22HX92T), by reference"
  else
    bad "codesign identity mismatch"; cat /tmp/u4_device_codesign.log
  fi
else
  bad "codesign --verify FAILED"; tail -10 /tmp/u4_device_codesign.log
fi

if [ -f "$APP/embedded.mobileprovision" ]; then
  ok "embedded provisioning profile present (free-team development)"
else
  bad "no embedded.mobileprovision"
fi

ENT=$(codesign -d --entitlements :- "$APP" 2>/dev/null)
if echo "$ENT" | grep -q 'get-task-allow'; then
  ok "entitlements include get-task-allow=true (development build)"
else
  bad "get-task-allow missing (not a development build?)"
fi
echo "  application-identifier: $(echo "$ENT" | grep -A1 'application-identifier' | tail -1 | tr -d ' \t')"

# --- 3. FRESH install (uninstall any prior copy first) -----------------------
note "Fresh install (uninstall then install) on the device"
xcrun devicectl device uninstall app --device "$DEVICE" com.aiowa.hermesfleet >/tmp/u4_device_uninstall.log 2>&1 && \
  ok "prior install removed (fresh state)" || ok "no prior install to remove (fresh state)"
sleep 2
if xcrun devicectl device install app --device "$DEVICE" "$APP" >/tmp/u4_device_install.log 2>&1; then
  ok "app installed to device"
else
  bad "device install FAILED"; tail -15 /tmp/u4_device_install.log
fi

# --- 4. Launch + verify process ---------------------------------------------
note "Launch + verify process on device"
LAUNCH_OUT=$(xcrun devicectl device process launch --device "$DEVICE" com.aiowa.hermesfleet 2>&1)
if echo "$LAUNCH_OUT" | grep -qiE 'launch.*(succeeded|success|bundle|pid)|process.*launch' ; then
  ok "app launched: $(echo "$LAUNCH_OUT" | tail -2 | tr '\n' ' ')"
else
  # A locked device (passcode/Face ID required) denies launch at the OS level.
  # This is a HARDWARE state on the physical device, not a build/sign/install
  # problem — record it honestly and retry once after a short settle.
  if echo "$LAUNCH_OUT" | grep -qiE 'unlock|locked'; then
    echo "  WARN: device reports locked — cannot launch without physical unlock."
    echo "  This is a device-state dependency, not an artifact defect."
    sleep 15
    LAUNCH_OUT=$(xcrun devicectl device process launch --device "$DEVICE" com.aiowa.hermesfleet 2>&1)
    if echo "$LAUNCH_OUT" | grep -qE '^.*launch.*[0-9]{2,}:' ; then
      ok "app launched on retry: $(echo "$LAUNCH_OUT" | tail -2 | tr '\n' ' ')"
    elif echo "$LAUNCH_OUT" | grep -qiE 'unlock|locked'; then
      bad "device locked — launch blocked pending physical unlock (install/build/sign all PASS)"
      echo "  $LAUNCH_OUT" | grep -iE 'unlock|locked' | head -3
    else
      bad "launch retry unexpected: $LAUNCH_OUT"
    fi
  else
    bad "launch returned unexpected output: $LAUNCH_OUT"
  fi
fi
sleep 5
PROC=$(xcrun devicectl device info processes --device "$DEVICE" 2>/dev/null | grep -i hermesfleet | head -3)
if [ -n "$PROC" ]; then
  ok "HermesFleetApp process running on device:"
  echo "  $PROC"
else
  bad "HermesFleetApp process NOT found in device process list"
fi

# --- 5. Checksums ------------------------------------------------------------
note "Checksums (recorded locally, no secrets)"
DEV_BIN="$APP/HermesFleetApp"
if [ -f "$DEV_BIN" ]; then
  echo "device binary sha256: $(shasum -a 256 "$DEV_BIN" | awk '{print $1}')"
else
  bad "device binary missing"
fi
echo "device .app content sha256 (recursive sorted):"
find "$APP" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}'

# --- Summary -----------------------------------------------------------------
printf '\n=====================================\n'
printf 'U4 device dogfood: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
