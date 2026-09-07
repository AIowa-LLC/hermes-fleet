#!/usr/bin/env bash
# h2_name_screens.sh — H2: copy the UI-test screenshots out of the exported
# attachment dir using the names recorded in the xcresult activities JSON
# (h2-stepN-*), so the reviewer can vision-verify them without UUID mapping.
# Regenerates the activity export first (the -resultBundlePath xcresult is
# authoritative for the last run).
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

XCRESULT="$REPO/build/h2_uitest.xcresult"
SRC="$REPO/build/h2_evidence/screenshots"
OUT="$SRC/named"
mkdir -p "$OUT"

if [ ! -d "$XCRESULT" ]; then
  echo "NO xcresult at $XCRESULT (run h2_uitest.sh first)" >&2
  exit 1
fi

TEST_ID="H2HealthDashboardUITests/testHealthDashboardLiveAndSurvivesRestart()"
ACTIVITIES_FILE=/tmp/h2_activities.json
if ! xcrun xcresulttool get test-results activities --path "$XCRESULT" --test-id "$TEST_ID" > "$ACTIVITIES_FILE" 2>/dev/null; then
  echo "NO activities exported from $XCRESULT" >&2
  exit 1
fi

python3 - "$SRC" "$OUT" "$ACTIVITIES_FILE" <<'PYEOF'
import json, os, shutil, sys

src, out, activities_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(activities_path) as f:
    activities = json.load(f)

count = 0
def walk(node):
    global count
    for att in node.get("attachments", []):
        name = att.get("name", "")
        if name.startswith("h2-step") and name.endswith(".png"):
            uuid = att.get("uuid", "")
            # The exporter may store the payload under the UUID with or
            # without a suffix; pick the largest matching file if both exist.
            candidates = []
            for fn in os.listdir(src):
                if fn.split(" ")[0] == uuid or fn == uuid:
                    candidates.append(os.path.join(src, fn))
            if candidates:
                best = max(candidates, key=os.path.getsize)
                dest = os.path.join(out, name.split("_")[0] + ".png")
                shutil.copy(best, dest)
                count += 1
                print(f"  {dest}")
    for child in node.get("childActivities", []):
        walk(child)

for run in activities.get("testRuns", []):
    for act in run.get("activities", []):
        walk(act)

print(f"copied {count} named screenshot(s)")
PYEOF
