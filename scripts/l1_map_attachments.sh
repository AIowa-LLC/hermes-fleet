#!/bin/bash
# Map exported xcresult attachments to their suggested names and show sizes.
set -u
cd ~/code/hermes-fleet-ios/build/l1/attachments
python3 <<'PYEOF'
import json, os
m = json.load(open("manifest.json"))
for item in m:
    fn = item.get("exportedFileName")
    size = os.path.getsize(fn) if fn and os.path.exists(fn) else "?"
    print(f"{item.get('suggestedName'):60s} {fn}  ({size} bytes)")
PYEOF
