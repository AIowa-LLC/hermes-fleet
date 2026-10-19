#!/usr/bin/env bash
# Wire the X1 launch screen into project configuration.
#
# Run from a clean tracked tree because the script regenerates
# HermesFleetApp.xcodeproj. Launch-screen assets must already exist in the
# repository; this script only wires configuration and verifies references.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== X1 launch-screen wiring =="

# --- 1. Guard against modified tracked files. ---
dirty=$(git status --porcelain | grep -E '^ ?[MADRCU]' || true)
if [ -n "$dirty" ]; then
  echo "ABORT: tracked files are modified/staged:" >&2
  echo "$dirty" >&2
  echo "Commit, stash, or revert tracked changes before re-running this script." >&2
  exit 1
fi
echo "tracked tree clean — proceeding."

# --- 2. project.yml: remove the empty UILaunchScreen generation key. ---
python3 - <<'PY'
from pathlib import Path
p = Path("project.yml")
txt = p.read_text()
needle = "        INFOPLIST_KEY_UILaunchScreen_Generation: YES\n"
if needle not in txt:
    print("INFO: INFOPLIST_KEY_UILaunchScreen_Generation already absent — skipping edit.")
else:
    txt = txt.replace(needle, "")
    p.write_text(txt)
    print("project.yml: removed INFOPLIST_KEY_UILaunchScreen_Generation.")
PY

# --- 3. Info.plist: add UILaunchStoryboardName = LaunchScreen. ---
python3 - <<'PY'
from pathlib import Path
p = Path("HermesFleetApp/Info.plist")
txt = p.read_text()
if "UILaunchStoryboardName" in txt:
    print("INFO: UILaunchStoryboardName already present — skipping edit.")
else:
    marker = "<dict>\n"
    i = txt.index(marker) + len(marker)
    insert = "\t<key>UILaunchStoryboardName</key>\n\t<string>LaunchScreen</string>\n"
    txt = txt[:i] + insert + txt[i:]
    p.write_text(txt)
    print("Info.plist: added UILaunchStoryboardName = LaunchScreen.")
PY

# --- 4. Regenerate the project. ---
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "ABORT: xcodegen not found on PATH." >&2
  exit 1
fi
xcodegen generate

# --- 5. Verify the generated project references the resources. ---
echo "== verify project references =="
grep -q "LaunchScreen.storyboard" HermesFleetApp.xcodeproj/project.pbxproj \
  && echo "OK: LaunchScreen.storyboard referenced" \
  || { echo "FAIL: LaunchScreen.storyboard not referenced" >&2; exit 1; }
grep -q "LaunchArtwork" HermesFleetApp.xcodeproj/project.pbxproj \
  && echo "OK: LaunchArtwork imageset referenced" \
  || { echo "FAIL: LaunchArtwork not referenced" >&2; exit 1; }

echo "== X1 wiring complete. Next: build + cold-launch verification =="
