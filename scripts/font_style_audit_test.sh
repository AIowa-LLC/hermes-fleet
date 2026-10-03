#!/bin/bash
# Self-test for scripts/font_style_audit.sh: rejects fixed sizes (both
# spellings, multi-line), honours commented allowlist entries, flags stale or
# uncommented entries, and passes on the real tree.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d "${TMPDIR:-/tmp}/font_audit_test.XXXXXX")
TMP="${TMP//\/\//\/}"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/src"
run() { FONT_AUDIT_ROOTS="$TMP/src" FONT_AUDIT_ALLOWLIST="$TMP/allow.txt" bash scripts/font_style_audit.sh >"$TMP/out" 2>&1; }
expect_fail() { if run; then echo "FAIL: $1 should have failed"; cat "$TMP/out"; exit 1; fi; }
expect_pass() { run || { echo "FAIL: $1 should have passed"; cat "$TMP/out"; exit 1; }; }
: > "$TMP/allow.txt"

printf 'Text("x").font(.body)\n' > "$TMP/src/ok.swift"
expect_pass "clean file"
printf 'Text("x").font(.system(size: 12))\n' > "$TMP/src/bad.swift"
expect_fail ".font(.system(size:"
printf 'let f = Font.system(size: 12)\n' > "$TMP/src/bad.swift"
expect_fail "Font.system(size:"
printf 'Text("x").font(\n  .system(\n    size: 12))\n' > "$TMP/src/bad.swift"
expect_fail "multi-line"
printf '// .font(.system(size: 12)) in a comment\n' > "$TMP/src/bad.swift"
expect_pass "comment mention"

printf 'Text("x").font(.system(size: min(hero, 80)))\n' > "$TMP/src/bad.swift"
expect_fail "unallowlisted scaled size"
printf '%s/bad.swift :: size: min(hero,  # hero glyph\n' "$TMP/src" > "$TMP/allow.txt"
expect_pass "allowlisted entry"
printf '%s/bad.swift :: size: min(hero\n' "$TMP/src" > "$TMP/allow.txt"
expect_fail "entry without comment"
printf '%s/bad.swift :: size: min(nope,  # stale\n' "$TMP/src" > "$TMP/allow.txt"
expect_fail "stale entry"

bash scripts/font_style_audit.sh >/dev/null || { echo "FAIL: real tree"; exit 1; }
echo "font_style_audit self-test passed"
