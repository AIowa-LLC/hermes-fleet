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
# Readiness is read from devicectl's MACHINE-READABLE output
# (`devicectl list devices --json-output`), never from the human-formatted
# columnar listing: device names contain spaces and the pretty state strings
# ("unavailable", "connected", ...) are not a stable contract — scraping them
# left the loop unable to tell "not reachable yet" from "state string I don't
# recognise", burning every attempt (~2 h) before a generic failure. The JSON
# rule mirrors scripts/fleet_device.sh (see its header for the observed Xcode
# CoreDevice fields): available = physical ECID + paired + tunnelState ==
# "connected" + localNetwork/wired transport.
#
# Exit codes: 0 installed+launched, 1 attempts exhausted, 2 bad precondition
# (missing APP / unresolved device), 3 device state unknown UNKNOWN_LIMIT
# times in a row (wrong identifier, unpaired device, or broken devicectl —
# retrying that for hours is pointless).
#
# Usage:
#   APP=<path-to-HermesFleetApp.app> [HERMES_FLEET_DEVICE_ID=<udid>] \
#     bash scripts/overnight_install_retry.sh
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/fleet_device.sh
source "$REPO_ROOT/scripts/fleet_device.sh"

APP="${APP:?set APP=<path-to-HermesFleetApp.app>}"
if [ ! -d "$APP" ]; then
  echo "FAIL: APP is not a directory (expected a built .app bundle): $APP" >&2
  exit 2
fi
LOG="${LOG:-$REPO_ROOT/build/overnight-install.log}"
mkdir -p "$(dirname "$LOG")"
ATTEMPTS="${ATTEMPTS:-40}"
UNKNOWN_LIMIT="${UNKNOWN_LIMIT:-3}"

DEVICE="$(resolve_fleet_device)" || exit $?

# probe_device_state <identifier>
# Prints one of: ready:<detail> | not-ready:<detail> | unknown:<detail>
probe_device_state() {
  local want="$1" json_file
  json_file="$(mktemp -t fleet_install_probe)"
  if ! xcrun devicectl list devices --json-output "$json_file" >/dev/null 2>&1; then
    rm -f "$json_file"
    echo "unknown:devicectl list devices failed"
    return 0
  fi
  python3 - "$json_file" "$want" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception as e:
    print(f"unknown:unparseable device list ({e})")
    sys.exit(0)
want = sys.argv[2]
for d in data.get("result", {}).get("devices", []):
    if d.get("identifier") != want:
        continue
    hp = d.get("hardwareProperties", {})
    cp = d.get("connectionProperties", {})
    tunnel = cp.get("tunnelState")
    transport = cp.get("transportType")
    if hp.get("deviceType") != "iPhone" or hp.get("platform") != "iOS" or hp.get("ecid") is None:
        print("unknown:identifier is not an iOS iPhone (check HERMES_FLEET_DEVICE_ID)")
    elif cp.get("pairingState") != "paired":
        print("not-ready:pairingState=%s" % cp.get("pairingState"))
    elif tunnel != "connected" or transport not in ("localNetwork", "wired"):
        print("not-ready:tunnelState=%s transport=%s" % (tunnel, transport))
    else:
        print("ready:tunnelState=%s transport=%s" % (tunnel, transport))
    sys.exit(0)
print("unknown:identifier not present in the device list")
PYEOF
  rm -f "$json_file"
}

echo "=== retry loop start $(date) device=$DEVICE app=$APP ===" >> "$LOG"
UNKNOWN_STREAK=0
for i in $(seq 1 "$ATTEMPTS"); do
  STATE="$(probe_device_state "$DEVICE")"
  echo "[attempt $i $(date +%H:%M)] state=$STATE" >> "$LOG"
  case "${STATE%%:*}" in
    ready)
      UNKNOWN_STREAK=0
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
      ;;
    not-ready)
      UNKNOWN_STREAK=0
      ;;
    *)
      UNKNOWN_STREAK=$((UNKNOWN_STREAK+1))
      if [ "$UNKNOWN_STREAK" -ge "$UNKNOWN_LIMIT" ]; then
        echo "=== BAILING OUT: device state unknown on $UNKNOWN_STREAK consecutive probes ($STATE) $(date) ===" >> "$LOG"
        echo "FAIL: device state unknown on $UNKNOWN_STREAK consecutive probes ($STATE) — see $LOG" >&2
        exit 3
      fi
      ;;
  esac
  sleep 180
done
echo "=== GAVE UP after $ATTEMPTS attempts $(date) ===" >> "$LOG"
exit 1
