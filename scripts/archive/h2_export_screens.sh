#!/usr/bin/env bash
# h2_export_screens.sh — H2: export the H2 UI-test screenshots from the last
# .xcresult into build/h2_evidence/ so the reviewer can vision-verify the
# health dashboard (live stats + after-restart persistence). Prefers the
# -resultBundlePath xcresult (build/h2_uitest.xcresult), falls back to the
# derived-data Logs/Test xcresult.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

OUT="$REPO/build/h2_evidence"
mkdir -p "$OUT"

latest=""
if [ -d "$REPO/build/h2_uitest.xcresult" ]; then
  latest="$REPO/build/h2_uitest.xcresult"
  echo "xcresult: $latest (resultBundlePath)"
elif [ -d "$REPO/build/H2DerivedData/Logs/Test" ]; then
  latest=$(ls -t "$REPO/build/H2DerivedData/Logs/Test/"*.xcresult 2>/dev/null | head -1)
  echo "xcresult: $latest (derived-data)"
fi
if [ -z "$latest" ]; then
  echo "NO xcresult found (checked build/h2_uitest.xcresult and build/H2DerivedData/Logs/Test/)" >&2
  exit 1
fi

export_dir="$OUT/screenshots"
mkdir -p "$export_dir"
xcrun xcresulttool export attachments --path "$latest" --output-path "$export_dir" >/dev/null 2>&1 || {
  echo "xcresulttool export failed; falling back to bundle copy." >&2
  find "$latest" -name '*.png' -exec cp {} "$export_dir/" \; 2>/dev/null
}

count=$(ls -1 "$export_dir" 2>/dev/null | wc -l | tr -d ' ')
echo "exported $count attachment file(s):"
ls -1 "$export_dir" | head -40
