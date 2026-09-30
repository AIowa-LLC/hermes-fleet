#!/bin/bash
# Self-test for scripts/extension_boundary_guard.py: one passing fixture and a
# set of failing fixtures built in a temp directory (synthetic trees only).
set -u
cd "$(dirname "$0")/.."
GUARD=scripts/extension_boundary_guard.py
FAIL=0
TMP=$(mktemp -d /tmp/extension_boundary_guard_test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

# new_tree <name>: a minimal compliant repo tree; echoes its root.
new_tree() {
  local root="$TMP/$1"
  mkdir -p "$root/Packages/FleetClientKit/Sources/FleetClientKit" \
           "$root/Extensions/NSE"
  cat > "$root/Packages/FleetClientKit/Package.swift" <<'EOF'
let package = Package(
    dependencies: [
        .package(path: "../FleetCore"),
        .package(path: "../FleetSecurity")
    ]
)
EOF
  cat > "$root/Packages/FleetClientKit/Sources/FleetClientKit/A.swift" <<'EOF'
import Foundation
import Security
import CryptoKit
import FleetCore
@testable import FleetSecurity
EOF
  cat > "$root/project.yml" <<'EOF'
name: Synthetic
targets:
  App:
    type: application
    dependencies:
      - package: FleetNetworking
      - package: FleetUI
  NSE:
    type: app-extension
    sources:
      - Extensions/NSE
    dependencies:
      - package: FleetCore
      - package: FleetSecurity
      - package: FleetClientKit
EOF
  cat > "$root/Extensions/NSE/Service.swift" <<'EOF'
import UserNotifications
import FleetCore
import FleetClientKit
EOF
  echo "$root"
}

expect_pass() {
  local root; root=$(new_tree "$1")
  if python3 "$GUARD" "$root" >"$TMP/$1.log" 2>&1; then pass "$2"; else fail "$2"; cat "$TMP/$1.log"; fi
}

# expect_violation <name> <description> <substring>; the caller mutates the tree first.
expect_violation() {
  local root="$TMP/$1"
  if python3 "$GUARD" "$root" >"$TMP/$1.log" 2>&1; then
    fail "$2 (guard passed but must fail)"; cat "$TMP/$1.log"
  elif grep -q "$3" "$TMP/$1.log"; then
    pass "$2"
  else
    fail "$2 (failed, but without the expected message '$3')"; cat "$TMP/$1.log"
  fi
}

# --- passing fixture ----------------------------------------------------------
expect_pass ok "compliant kit + compliant extension target passes"

# The app target may link everything; only extension targets are restricted.
# (covered by the compliant fixture above: App depends on FleetNetworking/FleetUI)

# --- failing fixtures ---------------------------------------------------------
new_tree kit_networking >/dev/null
echo "import FleetNetworking" >> "$TMP/kit_networking/Packages/FleetClientKit/Sources/FleetClientKit/A.swift"
expect_violation kit_networking "kit importing FleetNetworking fails" "imports 'FleetNetworking'"

new_tree kit_ui >/dev/null
echo "import FleetUI" >> "$TMP/kit_ui/Packages/FleetClientKit/Sources/FleetClientKit/A.swift"
expect_violation kit_ui "kit importing FleetUI fails" "imports 'FleetUI'"

new_tree kit_persistence >/dev/null
echo "import FleetPersistence" >> "$TMP/kit_persistence/Packages/FleetClientKit/Sources/FleetClientKit/A.swift"
expect_violation kit_persistence "kit importing FleetPersistence fails" "imports 'FleetPersistence'"

new_tree kit_uikit >/dev/null
echo "import UIKit" >> "$TMP/kit_uikit/Packages/FleetClientKit/Sources/FleetClientKit/A.swift"
expect_violation kit_uikit "kit importing UIKit fails" "imports 'UIKit'"

new_tree kit_swiftdata >/dev/null
echo "import SwiftData" >> "$TMP/kit_swiftdata/Packages/FleetClientKit/Sources/FleetClientKit/A.swift"
expect_violation kit_swiftdata "kit importing SwiftData fails" "imports 'SwiftData'"

new_tree kit_attributed_import >/dev/null
echo "@_exported import FleetNetworking" >> "$TMP/kit_attributed_import/Packages/FleetClientKit/Sources/FleetClientKit/A.swift"
expect_violation kit_attributed_import "attributed import of a forbidden module fails" "imports 'FleetNetworking'"

new_tree kit_manifest >/dev/null
sed -i '' 's#\.package(path: "../FleetSecurity")#.package(path: "../FleetSecurity"), .package(path: "../FleetNetworking")#' "$TMP/kit_manifest/Packages/FleetClientKit/Package.swift"
expect_violation kit_manifest "kit Package.swift depending on FleetNetworking fails" "depends on '../FleetNetworking'"

new_tree ext_package >/dev/null
sed -i '' 's#      - package: FleetClientKit#      - package: FleetClientKit\n      - package: FleetUI#' "$TMP/ext_package/project.yml"
expect_violation ext_package "extension target linking FleetUI fails" "extension target NSE links package 'FleetUI'"

new_tree ext_persistence >/dev/null
sed -i '' 's#      - package: FleetClientKit#      - package: FleetClientKit\n      - package: FleetPersistence#' "$TMP/ext_persistence/project.yml"
expect_violation ext_persistence "extension target linking FleetPersistence fails" "links package 'FleetPersistence'"

new_tree ext_app_target >/dev/null
sed -i '' 's#      - package: FleetClientKit#      - package: FleetClientKit\n      - target: App#' "$TMP/ext_app_target/project.yml"
expect_violation ext_app_target "extension target depending on the app target fails" "depends on target 'App'"

new_tree ext_source >/dev/null
echo "import FleetNetworking" >> "$TMP/ext_source/Extensions/NSE/Service.swift"
expect_violation ext_source "extension source importing FleetNetworking fails" "imports 'FleetNetworking'"

new_tree ext_source_ui >/dev/null
echo "@testable import FleetUI" >> "$TMP/ext_source_ui/Extensions/NSE/Service.swift"
expect_violation ext_source_ui "extension source importing FleetUI fails" "imports 'FleetUI'"

new_tree ext_widget >/dev/null
sed -i '' 's#type: app-extension#type: extensionkit-extension#' "$TMP/ext_widget/project.yml"
echo "import FleetPersistence" >> "$TMP/ext_widget/Extensions/NSE/Service.swift"
expect_violation ext_widget "extensionkit-extension targets are covered too" "imports 'FleetPersistence'"

# --- the real repository must pass --------------------------------------------
if python3 "$GUARD" . >"$TMP/real.log" 2>&1; then pass "repository tree passes the guard"; else fail "repository tree violates the guard"; cat "$TMP/real.log"; fi

printf '\nextension boundary guard self-test: FAIL=%d\n' "$FAIL"
[ "$FAIL" -eq 0 ]
