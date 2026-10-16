#!/bin/bash
# D1 (#104) static guard: no fixed point sizes for text or glyphs in FleetUI
# or HermesFleetApp. Use text styles (.body, .callout, ...) or @ScaledMetric.
# Flags `.system(size:` (covers `.font(.system(size:` and `Font.system(size:`,
# including multi-line forms). Justified exceptions live in
# scripts/font_style_audit_allowlist.txt, one commented entry each.
# Env overrides (used by font_style_audit_test.sh): FONT_AUDIT_ROOTS
# (colon-separated), FONT_AUDIT_ALLOWLIST.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import os, re, sys
from pathlib import Path

roots = os.environ.get("FONT_AUDIT_ROOTS", "Packages/FleetUI/Sources:HermesFleetApp").split(":")
allow_path = Path(os.environ.get("FONT_AUDIT_ALLOWLIST", "scripts/font_style_audit_allowlist.txt"))
pattern = re.compile(r"\.system\(\s*size\s*:")

allow, failures = [], []
if allow_path.exists():
    for n, raw in enumerate(allow_path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        entry, sep, why = line.partition("  # ")
        path, sep2, needle = entry.partition(" :: ")
        if not sep or not why.strip() or not sep2 or not needle.strip():
            failures.append(f"{allow_path}:{n}: malformed entry (need '<path> :: <needle>  # why')")
            continue
        allow.append([path.strip(), needle.strip(), False])

count = 0
for root in roots:
    for path in sorted(Path(root).rglob("*.swift")):
        count += 1
        rel = str(path)
        text = path.read_text()
        lines = text.splitlines()
        for m in pattern.finditer(text):
            ln = text.count("\n", 0, m.start()) + 1
            line = lines[ln - 1]
            if line.lstrip().startswith("//"):
                continue
            hit = next((a for a in allow if a[0] == rel and a[1] in line), None)
            if hit:
                hit[2] = True
                continue
            failures.append(f"{rel}:{ln}: fixed font size: {line.strip()}")
for path, needle, used in allow:
    if not used:
        failures.append(f"{allow_path}: stale allowlist entry matches nothing: {path} :: {needle}")

if failures:
    print("Font style audit FAILED (use a text style or @ScaledMetric; see docs/dev-loop.md):")
    print("\n".join(f"  {f}" for f in failures))
    sys.exit(1)
print(f"Font style audit passed ({count} Swift files inspected, {len(allow)} allowlisted).")
PY
