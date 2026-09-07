#!/bin/bash
# Map exported xcresult attachments to their suggested names and show sizes.
set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT/build/l1/attachments"
python3 <<'PYEOF'
import json, os
m = json.load(open("manifest.json"))
for item in m:
    fn = item.get("exportedFileName")
    size = os.path.getsize(fn) if fn and os.path.exists(fn) else "?"
    print(f"{item.get('suggestedName'):60s} {fn}  ({size} bytes)")
PYEOF
