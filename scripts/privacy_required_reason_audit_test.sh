#!/bin/bash
# Deterministic positive/negative coverage for the required-reason scanner.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP_DIR="$(mktemp -d /tmp/hermes_privacy_reason_test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

python3 scripts/privacy_required_reason_audit.py \
  --scan-only --format json --source scripts/testdata/privacy_required_reason/positive.swift \
  >"$TMP_DIR/positive.json"
python3 scripts/privacy_required_reason_audit.py \
  --scan-only --format json --source scripts/testdata/privacy_required_reason/clean.swift \
  >"$TMP_DIR/clean.json"

python3 - "$TMP_DIR/positive.json" "$TMP_DIR/clean.json" <<'PY'
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd() / "scripts"))
import privacy_required_reason_audit as audit

positive = json.loads(Path(sys.argv[1]).read_text())
clean = json.loads(Path(sys.argv[2]).read_text())
expected = {
    api for apis in audit.API_FAMILIES.values() for api in apis
}
observed = {
    hit["api"]
    for hits in positive["categories"].values()
    for hit in hits
}
if observed != expected:
    raise SystemExit(f"positive fixture coverage mismatch: {sorted(observed ^ expected)}")
if any(clean["categories"].values()):
    raise SystemExit("clean fixture produced a required-reason hit")
print(f"Required-reason scanner positive coverage: PASS ({len(expected)} APIs)")
print("Required-reason scanner clean-source negative coverage: PASS")
PY
