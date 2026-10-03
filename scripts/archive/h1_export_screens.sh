#!/usr/bin/env bash
# h1_export_screens.sh — H1 (R4): export the H1 UI-test screenshots from the
# last .xcresult into build/h1-evidence/ so the reviewer can vision-verify the
# lock overlay (Signal-red minimal accent) and the unlocked roster.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

DD="$REPO/build/H1DerivedData"
OUT="$REPO/build/h1-evidence"
mkdir -p "$OUT"

# Find the most recent H1 xcresult.
latest=$(ls -t "$DD/Logs/Test/"*.xcresult 2>/dev/null | head -1)
if [ -z "$latest" ]; then
  echo "NO xcresult found under $DD/Logs/Test/" >&2
  exit 1
fi
echo "xcresult: $latest"

# Extract screenshot attachments.
export_dir="$OUT/attachments"
rm -rf "$export_dir"
mkdir -p "$export_dir"
xcrun xcresulttool export attachments --path "$latest" --output-path "$export_dir" >/dev/null 2>&1 || {
  echo "xcresulttool export failed; falling back to bundle copy." >&2
  find "$latest" -name '*.png' -exec cp {} "$export_dir/" \; 2>/dev/null
}

count=$(ls -1 "$export_dir" 2>/dev/null | wc -l | tr -d ' ')
echo "exported $count attachment file(s):"
ls -1 "$export_dir" | head -30
