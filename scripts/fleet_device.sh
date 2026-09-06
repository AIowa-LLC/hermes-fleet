#!/bin/bash
# fleet_device.sh — shared physical-device resolution for Hermes Fleet scripts.
#
# Resolves ONE eligible physical iPhone:
#   1. HERMES_FLEET_DEVICE_ID env var (explicit override, used verbatim);
#   2. auto-discovery, only when EXACTLY ONE eligible iPhone exists.
#
# Discovery is machine-readable (devicectl --json-output is the ONLY
# script-supported interface per Apple): we parse the JSON directly for
# hardwareProperties.deviceType == "iPhone", platform iOS, paired, AND
# currently available. Columnar `devicectl list` output is never parsed —
# device names may contain spaces, so the first whitespace field is not a
# reliable identifier.
#
# AVAILABILITY (Xcode 26.6 CoreDevice JSON, observed empirically): there is
# no literal "available" field. The machine-readable availability state is
# derived from connectionProperties:
#   - available device:  transportType present ("localNetwork" or "wired" —
#     both are valid development connections; no specific transport is
#     assumed) and tunnelState != "unavailable" (e.g. "disconnected");
#   - unavailable device: tunnelState == "unavailable" and NO transportType.
# Pairing alone is NOT availability — a paired-but-unreachable iPhone must
# never be selected and must never create a false MULTIPLE against a valid
# available iPhone.
#
# Fails clearly (exit 2) when no eligible device or multiple eligible
# devices exist and no explicit override is set.
#
# Usage (from another script):
#   source "$(dirname "$0")/fleet_device.sh"
#   DEVICE="$(resolve_fleet_device)"   # exits the caller on failure
#
# Prints only the identifier — no personal device metadata (name, model,
# serial, hostname) is echoed.

resolve_fleet_device() {
  local explicit="${HERMES_FLEET_DEVICE_ID:-}"
  if [ -n "$explicit" ]; then
    echo "$explicit"
    return 0
  fi

  local json_file
  json_file="$(mktemp -t fleet_devices)"
  if ! xcrun devicectl list devices --json-output "$json_file" >/dev/null 2>&1; then
    echo "FAIL: 'xcrun devicectl list devices' failed; cannot discover devices." >&2
    rm -f "$json_file"
    return 2
  fi

  # Python one-shot parse: eligible = physical iPhone + iOS platform +
  # paired + CURRENTLY AVAILABLE. Availability is derived from the
  # CoreDevice connection state (see header): tunnelState != "unavailable"
  # AND a transportType present (wired or localNetwork both count — no
  # specific transport is assumed).
  local result
  result=$(python3 - "$json_file" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception as e:
    print(f"ERROR:{e}")
    sys.exit(0)
devs = data.get("result", {}).get("devices", [])
eligible = []
for d in devs:
    hp = d.get("hardwareProperties", {})
    cp = d.get("connectionProperties", {})
    transport = cp.get("transportType")
    tunnel = cp.get("tunnelState")
    if (hp.get("deviceType") == "iPhone"
            and hp.get("platform") == "iOS"
            and cp.get("pairingState") == "paired"
            and tunnel is not None and tunnel != "unavailable"
            and transport):
        eligible.append(d.get("identifier", ""))
if len(eligible) == 1:
    print(eligible[0])
elif len(eligible) == 0:
    print("NONE")
else:
    print("MULTIPLE")
PYEOF
)
  rm -f "$json_file"

  case "$result" in
    NONE)
      echo "FAIL: no AVAILABLE paired physical iPhone found (paired-but-unreachable devices are excluded)." >&2
      echo "  Connect/pair a device, or set HERMES_FLEET_DEVICE_ID explicitly." >&2
      return 2
      ;;
    MULTIPLE)
      echo "FAIL: multiple eligible physical iPhones found; device selection is ambiguous." >&2
      echo "  Set HERMES_FLEET_DEVICE_ID to the intended device identifier." >&2
      return 2
      ;;
    ERROR:*)
      echo "FAIL: could not parse devicectl device list: ${result#ERROR:}" >&2
      return 2
      ;;
    "")
      echo "FAIL: devicectl returned no parseable result." >&2
      return 2
      ;;
    *)
      echo "$result"
      return 0
      ;;
  esac
}
