#!/usr/bin/env bash
# M14 Visual Identity — download GPT-generated supporting assets into the repo.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root
DEST="assets/m14-generated"
mkdir -p "$DEST"

download() {
  local url="$1" out="$2"
  echo "fetch $out"
  curl -fsSL "$url" -o "$DEST/$out"
}

download "https://v3b.fal.media/files/b/0aa858c2/ZOKMgYfn3ixmtaoH7UwT1_XD3O6qjg.png" "icon-1024.png"
download "https://v3b.fal.media/files/b/0aa858c2/cbzNtvrw3XeKQgdvcP3dE_0Xkdt5OE.png" "empty-first-run-dark.png"
download "https://v3b.fal.media/files/b/0aa858d8/b4JoNjfkp7dhFTWZtRx1U_nKJRivOf.png" "empty-first-run-light.png"
download "https://v3b.fal.media/files/b/0aa858c2/ybzqNAY71Elcc6lbcOCzu_XlXHgYYG.png" "live-activity-glyph.png"

echo "--- downloaded ---"
for f in "$DEST"/*.png; do
  echo "$(basename "$f")  $(sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null | awk '/pixel/{printf "%s ", $2}')"
done
