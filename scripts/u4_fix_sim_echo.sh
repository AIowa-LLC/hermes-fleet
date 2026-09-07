#!/bin/bash
# U4 fix (robust): ensure the scripted message.complete echoes the sent task by
# collapsing whatever backslash run precedes "(text)" in the canned answer to a
# single backslash (Swift interpolation \(text)). Verified with repr after.
# TOOLING: script file only, run `bash scripts/u4_fix_sim_echo.sh`
set -u
cd "$(dirname "$0")/.."
FILE="HermesFleetApp/FleetSimulator.swift"
python3 - "$FILE" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
pat = re.compile(r'You said: \\+\(text\)')
new = 'You said: \\(text)'  # exactly one backslash in source = Swift interpolation
assert pat.search(s), "pattern not found"
s2, n = pat.subn(new, s)
assert n >= 1, "no substitution made"
open(p, 'w', encoding='utf-8').write(s2)
print("substituted occurrences:", n)
PY
echo "--- verify ---"
python3 - <<'PY'
s = open('HermesFleetApp/FleetSimulator.swift', encoding='utf-8').read()
import re
m = re.search(r'You said: (\\+)(\(text\))', s)
print("backslashes before (text):", len(m.group(1)) if m else "NONE")
PY
