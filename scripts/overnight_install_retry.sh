#!/bin/bash
# Unattended WiFi install-retry loop for a local development build.
# Retries every 3 minutes until the phone becomes reachable (it may be
# asleep/offline), installs in place (data preserved), and captures the
# install receipt + a launch PID receipt when possible. Exits on success.
#
# Device selection follows the shared resolver: HERMES_FLEET_DEVICE_ID env
# override, else auto-discovery when exactly one eligible iPhone exists.
# No device identifier is hardcoded here (repo policy: no device IDs in
# tracked files).
#
# Usage:
#   APP=<path-to-HermesFleetApp.app> [HERMES_FLEET_DEVICE_ID=<udid>] \
#     bash scripts/overnight_install_retry.sh
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/fleet_device.sh
source "$REPO_ROOT/scripts/fleet_device.sh"

APP="${APP:?set APP=<path-to-HermesFleetApp.app>}"
LOG="${LOG:-$REPO_ROOT/build/overnight-install.log}"
mkdir -p "$(dirname "$LOG")"
ATTEMPTS="${ATTEMPTS:-40}"

DEVICE="$(resolve_fleet_device)" || exit $?

echo "=== retry loop start $(date) device=$DEVICE app=$APP ===" >> "$LOG"
for i in $(seq 1 "$ATTEMPTS"); do
  STATE=$(xcrun devicectl list devices 2>/dev/null | grep "$DEVICE" | grep -oE "unavailable|connected" | head -1)
  echo "[attempt $i $(date +%H:%M)] state=${STATE:-none}" >> "$LOG"
  if [ "$STATE" != "unavailable" ] && [ -n "$STATE" ]; then
    if xcrun devicectl device install app --device "$DEVICE" "$APP" >> "$LOG" 2>&1; then
      echo "=== INSTALLED $(date) ===" >> "$LOG"
      sleep 10
      xcrun devicectl device process launch --device "$DEVICE" --terminate-existing com.aiowa.hermesfleet >> "$LOG" 2>&1 || \
        echo "(launch deferred — expected if phone locked)" >> "$LOG"
      sleep 8
      xcrun devicectl device info processes --device "$DEVICE" 2>/dev/null | grep -i hermesfleet >> "$LOG" || true
      exit 0
    else
      echo "[attempt $i] install failed, retrying" >> "$LOG"
    fi
  fi
  sleep 180
done
echo "=== GAVE UP after $ATTEMPTS attempts $(date) ===" >> "$LOG"
exit 1
