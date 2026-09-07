#!/usr/bin/env bash
# x1_wire_launch_screen.sh — apple-dev wiring step for the X1 launch screen.
#
# Prereq: run this BETWEEN apple-dev lane cards (git tree clean of tracked edits),
# because it regenerates HermesFleetApp.xcodeproj and would clobber an in-flight
# project.pbxproj. The launch storyboard + LaunchArtwork.imageset are already in
# the repo (created by apple-design); this script only wires the config.
#
# Steps: guard clean tree -> edit project.yml (drop empty UILaunchScreen gen) ->
# add UILaunchStoryboardName to Info.plist -> xcodegen generate -> verify refs ->
# optional build.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== X1 launch-screen wiring =="

# --- 1. Guard: no modified TRACKED files (untracked assets/storyboard are expected). ---
dirty=$(git status --porcelain | grep -E '^ ?[MADRCU]' || true)
if [ -n "$dirty" ]; then
  echo "ABORT: tracked files are modified/staged — another worker may hold the repo:" >&2
  echo "$dirty" >&2
  echo "Re-run this script between lane cards (after the T2 worker commits)." >&2
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

# --- 5. Verify the generated project references the new resources. ---
echo "== verify project references =="
grep -q "LaunchScreen.storyboard" HermesFleetApp.xcodeproj/project.pbxproj \
  && echo "OK: LaunchScreen.storyboard referenced" \
  || { echo "FAIL: LaunchScreen.storyboard not referenced" >&2; exit 1; }
grep -q "LaunchArtwork" HermesFleetApp.xcodeproj/project.pbxproj \
  && echo "OK: LaunchArtwork imageset referenced" \
  || { echo "FAIL: LaunchArtwork not referenced" >&2; exit 1; }

echo "== X1 wiring complete. Next: build + cold-launch verification =="
