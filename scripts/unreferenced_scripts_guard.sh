#!/bin/bash
# unreferenced_scripts_guard.sh — keeps the top-level scripts/ surface from
# growing back into a pile of one-off milestone scripts.
#
# Fails when a tracked file directly under scripts/ is referenced by nothing:
# no workflow, Makefile target, doc, source file, or other script mentions its
# basename, and it is not listed in scripts/unreferenced_allowlist.txt.
#
# A reference is the file's basename appearing in any other tracked file,
# except:
#   - scripts/archive/** and docs/archive/** (unsupported historical material
#     must not keep a live script "referenced");
#   - scripts/unreferenced_allowlist.txt (the allowlist itself);
#   - the generated HermesFleetApp.xcodeproj;
#   - the script itself.
#
# Fix a failure by (a) wiring the script into a workflow/Makefile/doc, (b)
# moving it to scripts/archive/, or (c) adding `<basename>  # reason` to
# scripts/unreferenced_allowlist.txt for maintained manual/live tools.
#
# Usage: bash scripts/unreferenced_scripts_guard.sh
# Self-test: bash scripts/unreferenced_scripts_guard_test.sh
set -u
cd "$(dirname "$0")/.." || exit 2

ALLOWLIST="scripts/unreferenced_allowlist.txt"
FAIL=0

# Basenames allowed to be unreferenced (strip comments and blanks).
allowed() {
  [ -f "$ALLOWLIST" ] || return 1
  sed -e 's/#.*$//' -e 's/[[:space:]]*$//' "$ALLOWLIST" | grep -Fxq -- "$1"
}

escape_ere() { printf '%s' "$1" | sed -e 's/[][\.*^$+?(){}|/]/\\&/g'; }

CHECKED=0
while IFS= read -r f; do
  case "$f" in
    scripts/*/*) continue ;;                       # subdirectories (archive, assets)
    scripts/README*|"$ALLOWLIST") continue ;;
  esac
  base="$(basename "$f")"
  CHECKED=$((CHECKED+1))
  if allowed "$base"; then continue; fi
  pat="(^|[^A-Za-z0-9_-])$(escape_ere "$base")([^A-Za-z0-9_-]|\$)"
  hits=$(git grep -lE "$pat" -- . \
    ":!$f" ":!$ALLOWLIST" ":!scripts/archive" ":!docs/archive" ":!HermesFleetApp.xcodeproj" 2>/dev/null || true)
  if [ -z "$hits" ]; then
    printf 'FAIL  %s is referenced by nothing\n' "$f"
    FAIL=$((FAIL+1))
  fi
done < <(git ls-files -- scripts)

if [ "$FAIL" -ne 0 ]; then
  cat <<EOF

$FAIL unreferenced script(s) under scripts/. Wire each into a workflow,
Makefile target, doc, or another script; move it to scripts/archive/; or list
it with a reason in $ALLOWLIST.
EOF
  exit 1
fi
printf 'PASS  all %d top-level scripts are referenced or allowlisted\n' "$CHECKED"
