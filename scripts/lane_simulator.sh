#!/bin/bash
# Per-worktree named iOS simulators for parallel agent lanes.
#
# Every git worktree of this repository gets its own simulator, named from a
# short hash of the worktree path (HF-<repo>-<id>; the path is never printed or
# embedded in a name), so concurrent local validation runs never install and
# launch Fleet on the same device. Selection wiring lives in
# scripts/sim_destination.sh; see docs/DEVELOPMENT.md#parallel-agent-lanes.
#
# Usage:
#   bash scripts/lane_simulator.sh id                    print this worktree's id
#   bash scripts/lane_simulator.sh ensure [iphone|ipad] [--boot]
#                                                        create or reuse the simulator, print its UDID
#   bash scripts/lane_simulator.sh list                  list HF-* simulators and their owner status
#   bash scripts/lane_simulator.sh shutdown              shut down this worktree's simulators
#   bash scripts/lane_simulator.sh delete                delete this worktree's simulators
#   bash scripts/lane_simulator.sh gc [--dry-run]        delete HF-* simulators whose worktree is gone
#
# Names: iPhone HF-<repo>-<id>, iPad HF-<repo>-<id>-iPad. Only devices named exactly like
# that are ever touched; `delete` and `shutdown` act on this worktree's devices
# only, and `gc` only on HF-* devices whose id matches no live worktree.
#
# Overrides: HERMES_FLEET_LANE_SIM_IPHONE_TYPE (default "iPhone 17 Pro") and
# HERMES_FLEET_LANE_SIM_IPAD_TYPE (default "iPad Pro 11-inch (M5)") name the
# preferred device type. If simctl rejects a type/runtime pair, supported
# device types and older installed runtimes are tried in order.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd -P)"

die() { echo "lane_simulator: $*" >&2; exit 1; }
log() { echo "lane_simulator: $*" >&2; }

id_for_path() { printf '%s' "$1" | shasum -a 256 | cut -c1-8; }
LANE_ID="$(id_for_path "$ROOT")"
COMMON_DIR=$(git rev-parse --git-common-dir) || die "not a git worktree"
COMMON_DIR=$(cd "$COMMON_DIR" && pwd -P) || die "cannot resolve repository identity"
REPO_ID="$(id_for_path "$COMMON_DIR")"
# Serialize short simctl mutations, including same-lane concurrent ensure and
# garbage collection. The lock lives outside the checkout, shared by its lanes.
if [ "${HF_SIM_LOCK_HELD:-}" != "$REPO_ID" ]; then
  exec python3 scripts/lane_simulator_lock.py "$COMMON_DIR/fleet-lane-simulator.lock" "$REPO_ID" "$0" "$@"
fi

name_for() {
  case "$1" in
    iphone) printf 'HF-%s-%s' "$REPO_ID" "$LANE_ID" ;;
    ipad) printf 'HF-%s-%s-iPad' "$REPO_ID" "$LANE_ID" ;;
    *) die "unknown device family '$1' (expected iphone or ipad)" ;;
  esac
}

# Prints "NAME UDID STATE" for every available device named HF-*.
hf_devices() {
  xcrun simctl list devices available | sed -nE \
    "s/^[[:space:]]+(HF-${REPO_ID}-[0-9a-f]{8}(-iPad)?) \(([0-9A-Fa-f-]{36})\) \(([^)]*)\).*$/\1 \3 \4/p"
}

udid_for_name() { hf_devices | awk -v n="$1" '$1 == n { print $2; exit }'; }
state_for_udid() { hf_devices | awk -v u="$1" '$2 == u { print $3; exit }'; }

device_type_candidates() {
  local family="$1" preferred fallback_re family_re types preferred_id
  if [ "$family" = iphone ]; then
    preferred="${HERMES_FLEET_LANE_SIM_IPHONE_TYPE:-iPhone 17 Pro}"
    fallback_re='^iPhone [0-9]+ Pro$'
    family_re='^iPhone '
  else
    preferred="${HERMES_FLEET_LANE_SIM_IPAD_TYPE:-iPad Pro 11-inch (M5)}"
    fallback_re='^iPad Pro 11-inch'
    family_re='^iPad '
  fi
  types=$(xcrun simctl list devicetypes | sed -nE \
    's/^(.+) \((com\.apple\.CoreSimulator\.SimDeviceType\.[^)]+)\)$/\1|\2/p') || true
  [ -n "$types" ] || return 0
  preferred_id=$(printf '%s\n' "$types" | awk -F'|' -v p="$preferred" '$1 == p { print $2; exit }')
  {
    [ -z "$preferred_id" ] || printf '%s\n' "$preferred_id"
    # simctl lists the newest installed device types first on supported
    # runners. Keep that order for fallback after trying the exact preference.
    printf '%s\n' "$types" | awk -F'|' -v re="$fallback_re" '$1 ~ re { print $2 }'
    printf '%s\n' "$types" | awk -F'|' -v re="$family_re" '$1 ~ re { print $2 }'
  } | awk 'NF && !seen[$0]++ && count < 8 { print; count++ }'
}

available_ios_runtimes() {
  local sdk_version runtimes
  sdk_version=$(xcrun --sdk iphonesimulator --show-sdk-version) || die "cannot read the active iOS Simulator SDK version"
  runtimes=$(xcrun simctl list runtimes available | sed -nE \
    's/^iOS ([0-9.]+) .* - (com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+)$/\1|\2/p' \
    | awk -F'|' -v sdk="$sdk_version" '
      function version_cmp(a, b, left, right, left_count, right_count, part_count, i, left_value, right_value) {
        left_count = split(a, left, ".")
        right_count = split(b, right, ".")
        part_count = left_count > right_count ? left_count : right_count
        for (i = 1; i <= part_count; i++) {
          left_value = i <= left_count ? left[i] + 0 : 0
          right_value = i <= right_count ? right[i] + 0 : 0
          if (left_value < right_value) return -1
          if (left_value > right_value) return 1
        }
        return 0
      }
      version_cmp($1, sdk) <= 0 {
        split($1, parts, ".")
        printf "%d %d %d %s\n", parts[1], parts[2], parts[3], $2
      }
    ' \
    | sort -k1,1nr -k2,2nr -k3,3nr | awk '{ print $4 }')
  [ -n "$runtimes" ] || die "no iOS simulator runtime at or below SDK $sdk_version is installed"
  printf '%s\n' "$runtimes"
}

cmd_ensure() {
  local family=iphone boot=0 name udid type runtime state candidates create_output create_error last_error candidate
  local device_types=() runtimes=()
  while [ $# -gt 0 ]; do
    case "$1" in
      iphone|ipad) family="$1" ;;
      --boot) boot=1 ;;
      *) die "ensure: unknown argument '$1'" ;;
    esac
    shift
  done
  name="$(name_for "$family")"
  udid="$(udid_for_name "$name")"
  if [ -z "$udid" ]; then
    candidates="$(device_type_candidates "$family")"
    [ -n "$candidates" ] || die "no $family device type is installed"
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      device_types[${#device_types[@]}]="$candidate"
    done <<< "$candidates"
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      runtimes[${#runtimes[@]}]="$candidate"
    done < <(available_ios_runtimes)
    [ "${#runtimes[@]}" -gt 0 ] || die "no supported iOS simulator runtime is installed"

    last_error=""
    for runtime in "${runtimes[@]}"; do
      for type in "${device_types[@]}"; do
        log "creating $name with $type on $runtime"
        if create_output="$(xcrun simctl create "$name" "$type" "$runtime" 2>&1)"; then
          udid="$(printf '%s\n' "$create_output" | tail -n 1 | tr -d '\r')"
          break 2
        fi
        create_error="${create_output//$'\n'/; }"
        case "$create_output" in
          *"Incompatible device"*)
            last_error="$create_error"
            log "simctl create rejected $type on $runtime ($create_error); trying the next compatible pair"
            ;;
          *)
            printf '%s\n' "$create_output" >&2
            die "simctl create failed for $name"
            ;;
        esac
      done
    done
    if [ -z "$udid" ]; then
      [ -z "$last_error" ] || printf '%s\n' "$last_error" >&2
      die "no compatible iOS device type/runtime pair is installed for $name"
    fi
    [ -n "$udid" ] || die "simctl create returned no UDID for $name"
  fi
  if [ "$boot" -eq 1 ]; then
    state="$(state_for_udid "$udid")"
    if [ "$state" != Booted ]; then
      log "booting $name"
      xcrun simctl boot "$udid" >&2 || die "simctl boot failed for $name"
    fi
  fi
  printf '%s\n' "$udid"
}

# Live worktree ids of this repository: only existing directories count.
live_ids() {
  local listing path
  listing="$(git worktree list --porcelain)" || return 1
  printf '%s\n' "$listing" | sed -n 's/^worktree //p' | while IFS= read -r path; do
    [ -d "$path" ] || continue
    id_for_path "$(cd "$path" && pwd -P)"
  done
  echo "$LANE_ID"
}

delete_udid() {
  local udid="$1" name="$2"
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  log "deleting $name"
  xcrun simctl delete "$udid" >&2 || die "simctl delete failed for $name"
}

cmd_list() {
  local live name udid state id owner
  live="$(live_ids)"
  hf_devices | while read -r name udid state; do
    id="${name#HF-"$REPO_ID"-}"; id="${id%-iPad}"
    if [ "$id" = "$LANE_ID" ]; then owner="this-worktree"
    elif printf '%s\n' "$live" | grep -qx "$id"; then owner="other-worktree"
    else owner="orphaned"; fi
    printf '%s\t%s\t%s\t%s\n' "$name" "$udid" "$state" "$owner"
  done
}

cmd_shutdown() {
  local family name udid state
  for family in iphone ipad; do
    name="$(name_for "$family")"
    udid="$(udid_for_name "$name")"
    [ -n "$udid" ] || continue
    state="$(state_for_udid "$udid")"
    if [ "$state" = Booted ]; then
      log "shutting down $name"
      xcrun simctl shutdown "$udid" >&2 || die "simctl shutdown failed for $name"
    fi
  done
}

cmd_delete() {
  local family name udid
  for family in iphone ipad; do
    name="$(name_for "$family")"
    udid="$(udid_for_name "$name")"
    [ -n "$udid" ] || continue
    delete_udid "$udid" "$name"
  done
}

cmd_gc() {
  local dry=0 live name udid state id
  case "${1:-}" in
    "") ;;
    --dry-run) dry=1 ;;
    *) die "gc: unknown argument '$1'" ;;
  esac
  # Fail closed: never collect when the set of live worktrees is unknown.
  live="$(live_ids)" || die "gc: cannot list git worktrees"
  hf_devices | while read -r name udid state; do
    id="${name#HF-"$REPO_ID"-}"; id="${id%-iPad}"
    if printf '%s\n' "$live" | grep -qx "$id"; then continue; fi
    if [ "$dry" -eq 1 ]; then
      log "would delete $name (no live worktree)"
    else
      delete_udid "$udid" "$name"
    fi
  done
}

case "${1:-}" in
  id) printf '%s\n' "$LANE_ID" ;;
  ensure) shift; cmd_ensure "$@" ;;
  list) cmd_list ;;
  shutdown) cmd_shutdown ;;
  delete) cmd_delete ;;
  gc) shift; cmd_gc "$@" ;;
  -h|--help|"") sed -n "2,25p" "$0"; [ -n "${1:-}" ] || exit 2 ;;
  *) die "unknown subcommand '$1'" ;;
esac
