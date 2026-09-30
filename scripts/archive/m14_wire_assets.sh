#!/usr/bin/env bash
# M14 Visual Identity — place generated PNGs into the Xcode asset catalog.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

SRC="assets/m14-generated"
AC="HermesFleetApp/Assets.xcassets"

# App icon (single-size 1024)
cp "$SRC/icon-1024.png" "$AC/AppIcon.appiconset/icon-1024.png"

# Empty-state illustration (light + dark appearance variants)
cp "$SRC/empty-first-run-light.png" "$AC/FleetEmptyState.imageset/empty-first-run-light.png"
cp "$SRC/empty-first-run-dark.png"  "$AC/FleetEmptyState.imageset/empty-first-run-dark.png"

echo "asset catalog wiring complete:"
ls -1 "$AC/AppIcon.appiconset" "$AC/FleetEmptyState.imageset"
