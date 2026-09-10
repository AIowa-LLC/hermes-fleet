#!/bin/bash
# Validate Fleet's app privacy manifest and, when requested, the copy inside
# a built .app. This deliberately rejects undeclared collection/tracking and
# unexpected required-reason categories instead of accepting a cargo-cult
# manifest that merely parses as XML.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE_MANIFEST="HermesFleetApp/PrivacyInfo.xcprivacy"
BUILT_APP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)
      [[ $# -ge 2 ]] || { echo "--manifest requires a path" >&2; exit 2; }
      SOURCE_MANIFEST="$2"
      shift 2
      ;;
    --built-app)
      [[ $# -ge 2 ]] || { echo "--built-app requires an .app path" >&2; exit 2; }
      BUILT_APP="$2"
      shift 2
      ;;
    *)
      echo "usage: $0 [--manifest PATH] [--built-app PATH_TO_APP]" >&2
      exit 2
      ;;
  esac
done

[[ -f "$SOURCE_MANIFEST" ]] || { echo "missing $SOURCE_MANIFEST" >&2; exit 1; }
plutil -lint "$SOURCE_MANIFEST" >/dev/null

if [[ -n "$BUILT_APP" ]]; then
  [[ -d "$BUILT_APP" ]] || { echo "built app not found: $BUILT_APP" >&2; exit 1; }
  [[ -f "$BUILT_APP/PrivacyInfo.xcprivacy" ]] || {
    echo "built app is missing PrivacyInfo.xcprivacy: $BUILT_APP" >&2
    exit 1
  }
  plutil -lint "$BUILT_APP/PrivacyInfo.xcprivacy" >/dev/null
fi

python3 - "$SOURCE_MANIFEST" "$BUILT_APP" <<'PY'
from pathlib import Path
import plistlib
import sys

source = Path(sys.argv[1])
built_app = Path(sys.argv[2]) if sys.argv[2] else None
expected = {"NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"}}
expected_root_keys = {
    "NSPrivacyTracking",
    "NSPrivacyCollectedDataTypes",
    "NSPrivacyAccessedAPITypes",
}

def read(path: Path):
    with path.open("rb") as stream:
        value = plistlib.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"{path} root must be a dictionary")
    if set(value) != expected_root_keys:
        raise ValueError(f"{path} root keys must be exactly {sorted(expected_root_keys)}")
    if value["NSPrivacyTracking"] is not False:
        raise ValueError(f"{path} must set NSPrivacyTracking to false")
    if value["NSPrivacyCollectedDataTypes"] != []:
        raise ValueError(f"{path} must declare no collected data types")

    actual = {}
    entries = value["NSPrivacyAccessedAPITypes"]
    if not isinstance(entries, list):
        raise ValueError(f"{path} NSPrivacyAccessedAPITypes must be an array")
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {
            "NSPrivacyAccessedAPIType",
            "NSPrivacyAccessedAPITypeReasons",
        }:
            raise ValueError(f"{path} has a malformed accessed-API entry")
        category = entry["NSPrivacyAccessedAPIType"]
        reasons = entry["NSPrivacyAccessedAPITypeReasons"]
        if not isinstance(category, str) or not isinstance(reasons, list) or not all(
            isinstance(reason, str) for reason in reasons
        ):
            raise ValueError(f"{path} has malformed category/reason values")
        if category in actual:
            raise ValueError(f"{path} repeats category {category}")
        actual[category] = set(reasons)
    if actual != expected:
        raise ValueError(f"{path} declarations {actual} do not match audited use {expected}")
    return value

source_value = read(source)
print("Privacy manifest source: PASS")
print("  NSPrivacyTracking=false; NSPrivacyCollectedDataTypes=[]")
print("  Required reason: UserDefaults / CA92.1 (app-owned settings only)")

if built_app:
    bundled = read(built_app / "PrivacyInfo.xcprivacy")
    if bundled != source_value:
        raise ValueError("bundled privacy manifest differs from the audited source manifest")
    print(f"Privacy manifest bundle proof: PASS ({built_app / 'PrivacyInfo.xcprivacy'})")
PY
