#!/bin/bash
# Shared simulator destination selection for dev-check, the C1 runners, the
# iPad smoke and the Makefile. Source it (`. scripts/sim_destination.sh`) and
# call `resolve_sim_destination iphone|ipad [default-destination]`, or run it
# to print the destination: `bash scripts/sim_destination.sh iphone`.
#
# Precedence (first match wins):
#   1. HERMES_FLEET_SIM_UDID          explicit device (iPad: HERMES_FLEET_IPAD_SIM_UDID)
#      iPad only: HERMES_FLEET_IPAD_DESTINATION, an explicit device name
#   2. HERMES_FLEET_LANE_SIM=1        this worktree's HF-<id> simulator, created
#                                     on demand by scripts/lane_simulator.sh
#   3. current behavior               first available iPhone (iPad: a named
#                                     iPad Pro), which is what CI uses
#
# HERMES_FLEET_LANE_SIM defaults to 0 here, so CI and direct runner
# invocations keep their existing selection. scripts/dev_check.sh turns it on
# by default for local runs (and leaves it off when CI=true).
#
# Sets SIM_SELECTION (explicit-udid | explicit-name | lane | default),
# SIM_UDID (empty when a device is selected by name), SIM_NAME and SIM_DEST.
# Diagnostics go to stderr; a failed lane simulator fails closed.

_SIM_DESTINATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_sim_destination() {
  local family="${1:-iphone}" default_dest="${2:-}" explicit=""
  SIM_SELECTION=""; SIM_UDID=""; SIM_NAME=""; SIM_DEST=""
  case "$family" in
    iphone) explicit="${HERMES_FLEET_SIM_UDID:-}" ;;
    ipad) explicit="${HERMES_FLEET_IPAD_SIM_UDID:-}" ;;
    *) echo "sim_destination: unknown device family '$family'" >&2; return 2 ;;
  esac

  if [ -n "$explicit" ]; then
    SIM_SELECTION="explicit-udid"
    SIM_UDID="$explicit"
  elif [ "$family" = ipad ] && [ -n "${HERMES_FLEET_IPAD_DESTINATION:-}" ]; then
    SIM_SELECTION="explicit-name"
    SIM_NAME="$HERMES_FLEET_IPAD_DESTINATION"
  elif [ "${HERMES_FLEET_LANE_SIM:-0}" = 1 ]; then
    SIM_SELECTION="lane"
    if ! SIM_UDID="$(bash "$_SIM_DESTINATION_DIR/lane_simulator.sh" ensure "$family")" || [ -z "$SIM_UDID" ]; then
      echo "sim_destination: could not prepare the lane simulator; set HERMES_FLEET_LANE_SIM=0 to use the shared default instead" >&2
      return 1
    fi
  else
    SIM_SELECTION="default"
  fi

  if [ -n "$SIM_UDID" ]; then
    SIM_DEST="platform=iOS Simulator,id=$SIM_UDID"
  elif [ -n "$SIM_NAME" ]; then
    SIM_DEST="platform=iOS Simulator,name=$SIM_NAME"
  elif [ -n "$default_dest" ]; then
    SIM_DEST="$default_dest"
  elif [ "$family" = ipad ]; then
    SIM_NAME="iPad Pro 11-inch (M5)"
    SIM_DEST="platform=iOS Simulator,name=$SIM_NAME"
  else
    SIM_NAME=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/ \(.*//')
    [ -n "$SIM_NAME" ] || SIM_NAME="iPhone 16"
    SIM_DEST="platform=iOS Simulator,name=$SIM_NAME,OS=latest"
  fi
}

# Traceability lines for results metadata (no hostnames or paths).
sim_metadata_lines() {
  printf 'simulator_selection=%s\n' "$SIM_SELECTION"
  printf 'simulator_udid=%s\n' "${SIM_UDID:-unspecified}"
}

sim_announce() {
  case "$SIM_SELECTION" in
    explicit-udid|lane) echo "  using simulator: $SIM_SELECTION ($SIM_UDID)" ;;
    *) echo "  using simulator: ${SIM_NAME:-$SIM_DEST}" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  family="iphone"; default_dest=""
  while [ $# -gt 0 ]; do
    case "$1" in
      iphone|ipad) family="$1" ;;
      --default-dest) default_dest="${2:?--default-dest needs a value}"; shift ;;
      *) echo "usage: $0 [iphone|ipad] [--default-dest <destination>]" >&2; exit 2 ;;
    esac
    shift
  done
  resolve_sim_destination "$family" "$default_dest" || exit 1
  printf '%s\n' "$SIM_DEST"
fi
