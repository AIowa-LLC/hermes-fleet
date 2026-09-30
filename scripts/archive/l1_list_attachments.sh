#!/bin/bash
# List L1 xcresult attachments, including nested manifest structures.
set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"
OUT=${1:-build/l1/attachments_1788073234}
python3 - "$OUT" <<'PYEOF'
import json, os, sys
out = sys.argv[1]
m = json.load(open(os.path.join(out, "manifest.json")))
entries = []
if isinstance(m, dict):
    entries = m.get("attachments", [])
elif isinstance(m, list):
    for top in m:
        entries.extend(top.get("attachments", []) or [])
for it in entries:
    fn = it.get("exportedFileName")
    size = os.path.getsize(os.path.join(out, fn)) if fn and os.path.exists(os.path.join(out, fn)) else "?"
    print(f"{it.get('suggestedHumanReadableName',''):55s} {fn} ({size} bytes)")
PYEOF
