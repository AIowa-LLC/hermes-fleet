#!/bin/bash
# U2 Roster + Bot detail + Gateway management screens — full validation.
# Evidence: FleetUI module-boundary (0 FleetNetworking imports), package suites
# (Core/Networking/Security/Persistence), xcodegen + xcodebuild build/test on
# the iOS Simulator, new AppEnvironment U2 tests + ModuleBoundary seam test,
# simulator install/launch/screenshots (gateways, roster with partial outage,
# bot detail sessions, Dynamic Type sanity), secrets scan, git state.
# Run with: bash scripts/u2_validate.sh
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
PASS=0
FAIL=0
declare -a FAILURES=()

note() { printf '\n=== %s ===\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf 'FAIL  %s\n' "$1"; }

# --- 1. MODULE BOUNDARY: FleetUI must have ZERO FleetNetworking imports -----
note "Module boundary: no 'import FleetNetworking' in FleetUI sources"
UI_SOURCES=$(find Packages/FleetUI/Sources -name '*.swift')
HITS=$(grep -nE '^\s*import\s+FleetNetworking\b' $UI_SOURCES 2>/dev/null || true)
if [ -z "$HITS" ]; then
  ok "FleetUI has 0 'import FleetNetworking' (M0 hard guard preserved)"
else
  bad "FleetUI imports FleetNetworking:"
  echo "$HITS" | head -20
fi

# --- 2. FleetCore build + tests ---------------------------------------------
note "FleetCore build + tests"
if (cd Packages/FleetCore && swift build) >/tmp/u2_core_build.log 2>&1; then
  ok "FleetCore builds"
else
  bad "FleetCore build failed"; tail -5 /tmp/u2_core_build.log
fi
CORE_OUT=$(cd Packages/FleetCore && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $CORE_OUT"
if echo "$CORE_OUT" | grep -q ', with 0 failures'; then
  ok "FleetCore tests green: $CORE_OUT"
else
  bad "FleetCore tests NOT green: $CORE_OUT"
fi

# --- 3. FleetNetworking build + tests ---------------------------------------
note "FleetNetworking build + tests"
if (cd Packages/FleetNetworking && swift build) >/tmp/u2_net_build.log 2>&1; then
  ok "FleetNetworking builds"
else
  bad "FleetNetworking build failed"; tail -8 /tmp/u2_net_build.log
fi
NET_OUT=$(cd Packages/FleetNetworking && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $NET_OUT"
if echo "$NET_OUT" | grep -q ', with 0 failures'; then
  ok "FleetNetworking tests green: $NET_OUT"
else
  bad "FleetNetworking tests NOT green: $NET_OUT"
fi

# --- 4. FleetSecurity + FleetPersistence build/tests -------------------------
note "FleetSecurity build + tests"
if (cd Packages/FleetSecurity && swift build) >/tmp/u2_sec_build.log 2>&1; then
  ok "FleetSecurity builds"
else
  bad "FleetSecurity build failed"; tail -5 /tmp/u2_sec_build.log
fi
SEC_OUT=$(cd Packages/FleetSecurity && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $SEC_OUT"
if echo "$SEC_OUT" | grep -q ', with 0 failures'; then
  ok "FleetSecurity tests green: $SEC_OUT"
else
  bad "FleetSecurity tests NOT green: $SEC_OUT"
fi

note "FleetPersistence build + tests"
if (cd Packages/FleetPersistence && swift build) >/tmp/u2_pers_build.log 2>&1; then
  ok "FleetPersistence builds"
else
  bad "FleetPersistence build failed"; tail -5 /tmp/u2_pers_build.log
fi
PERS_OUT=$(cd Packages/FleetPersistence && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1)
echo "  $PERS_OUT"
if echo "$PERS_OUT" | grep -q ', with 0 failures'; then
  ok "FleetPersistence tests green: $PERS_OUT"
else
  bad "FleetPersistence tests NOT green: $PERS_OUT"
fi

# --- 5. xcodegen + xcodebuild build/test (iOS Simulator, app-level) ----------
note "xcodegen + xcodebuild build/test (iOS Simulator)"
if xcodegen generate >/tmp/u2_xcodegen.log 2>&1 && grep -q '3JS22HX92T' HermesFleetApp.xcodeproj/project.pbxproj; then
  ok "xcodegen regenerated; team 3JS22HX92T present"
else
  bad "xcodegen / team missing"; tail -5 /tmp/u2_xcodegen.log
fi
DEST="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
DD="$REPO/build/DerivedDataU2"
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" build >/tmp/u2_xcbuild.log 2>&1; then
  ok "xcodebuild BUILD SUCCEEDED (iOS Simulator)"
else
  bad "xcodebuild build FAILED"; tail -25 /tmp/u2_xcbuild.log
fi
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -destination "$DEST" -derivedDataPath "$DD" test >/tmp/u2_xctest.log 2>&1; then
  TESTLINE=$(grep -E 'Test Suite.*(passed|failed)' /tmp/u2_xctest.log | tail -1)
  ok "xcodebuild TEST SUCCEEDED — $TESTLINE"
else
  bad "xcodebuild test FAILED"; grep -E 'error:|failed|Test Suite' /tmp/u2_xctest.log | tail -20
fi

# --- 6. Simulator evidence: install, launch, screenshots ---------------------
note "Simulator evidence (install + launch + screenshots)"
SIM_UDID=$(xcrun simctl list devices available | grep -E 'iPhone 17 Pro \(' | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
if [ -z "$SIM_UDID" ]; then
  bad "no iPhone 17 Pro simulator available"
else
  ok "simulator resolved: $SIM_UDID"
  APP_BUNDLE="$DD/Build/Products/Debug-iphonesimulator/HermesFleetApp.app"
  if [ -d "$APP_BUNDLE" ]; then
    xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
    xcrun simctl bootstatus "$SIM_UDID" -b >/tmp/u2_sim_boot.log 2>&1 && ok "simulator booted" || bad "simulator boot failed"
    if xcrun simctl install "$SIM_UDID" "$APP_BUNDLE" >/tmp/u2_sim_install.log 2>&1; then
      ok "app installed to simulator"
    else
      bad "app install failed"; tail -5 /tmp/u2_sim_install.log
    fi
    LAUNCH_OUT=$(xcrun simctl launch "$SIM_UDID" com.aiowa.hermesfleet 2>&1)
    if ! echo "$LAUNCH_OUT" | grep -qE 'com.aiowa.hermesfleet: [0-9]+'; then
      # Stale process / first-boot race: terminate and retry once.
      xcrun simctl terminate "$SIM_UDID" com.aiowa.hermesfleet 2>/dev/null || true
      sleep 2
      LAUNCH_OUT=$(xcrun simctl launch "$SIM_UDID" com.aiowa.hermesfleet 2>&1)
    fi
    if echo "$LAUNCH_OUT" | grep -qE 'com.aiowa.hermesfleet: [0-9]+'; then
      ok "app launched (PID returned)"
      sleep 3
      xcrun simctl io "$SIM_UDID" screenshot "$REPO/build/u2-simulator-gateways.png" >/tmp/u2_sim_shot.log 2>&1 && ok "screenshot: build/u2-simulator-gateways.png" || bad "gateways screenshot failed"
      # Roster (union, partial outage) via the DEBUG auto-nav hook.
      xcrun simctl terminate "$SIM_UDID" com.aiowa.hermesfleet 2>/dev/null || true
      SIMCTL_CHILD_HERMES_FLEET_AUTO_NAV=roster xcrun simctl launch "$SIM_UDID" com.aiowa.hermesfleet >/dev/null 2>&1
      sleep 4
      xcrun simctl io "$SIM_UDID" screenshot "$REPO/build/u2-simulator-roster.png" >/tmp/u2_sim_shot3.log 2>&1 && ok "screenshot: build/u2-simulator-roster.png" || bad "roster screenshot failed"
      # Bot detail (identity + sessions via session.list) via the DEBUG hook.
      xcrun simctl terminate "$SIM_UDID" com.aiowa.hermesfleet 2>/dev/null || true
      SIMCTL_CHILD_HERMES_FLEET_AUTO_NAV=bot-detail xcrun simctl launch "$SIM_UDID" com.aiowa.hermesfleet >/dev/null 2>&1
      sleep 4
      xcrun simctl io "$SIM_UDID" screenshot "$REPO/build/u2-simulator-bot-detail.png" >/tmp/u2_sim_shot4.log 2>&1 && ok "screenshot: build/u2-simulator-bot-detail.png" || bad "bot-detail screenshot failed"
      # Dynamic Type sanity: relaunch at a large accessibility content size and
      # capture the gateways/roster state, then restore the default size.
      # (simctl ui content-size is not available on this Xcode; the app-level
      # override rides on the preferred content-size category user default.)
      xcrun simctl spawn "$SIM_UDID" defaults write com.aiowa.hermesfleet UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL >/tmp/u2_sim_ui.log 2>&1 && ok "content size set to accessibility XXXL" || bad "content-size set failed"
      xcrun simctl terminate "$SIM_UDID" com.aiowa.hermesfleet 2>/dev/null || true
      xcrun simctl launch "$SIM_UDID" com.aiowa.hermesfleet >/dev/null 2>&1
      sleep 3
      xcrun simctl io "$SIM_UDID" screenshot "$REPO/build/u2-simulator-dynamic-type.png" >/tmp/u2_sim_shot2.log 2>&1 && ok "screenshot: build/u2-simulator-dynamic-type.png (AX size)" || bad "dynamic-type screenshot failed"
      xcrun simctl spawn "$SIM_UDID" defaults delete com.aiowa.hermesfleet UIPreferredContentSizeCategoryName >/dev/null 2>&1
    else
      bad "app launch failed: $LAUNCH_OUT"
    fi
  else
    bad "app bundle missing: $APP_BUNDLE"
  fi
fi

# --- 7. Secrets scan (U2 sources) --------------------------------------------
note "Secrets scan (U2 sources)"
SCAN_FILES=$(find Packages/FleetUI/Sources HermesFleetApp HermesFleetAppTests Packages/FleetCore/Sources/FleetCore Packages/FleetNetworking/Sources/FleetNetworking -name '*.swift' 2>/dev/null)
# Test fixtures (boundary-fixture, top-secret-in-app, etc.) are literal test
# values, not real secrets — exclude fixture-looking lines the same way U1 did.
HITS=$(grep -nE '"(sk-|ghp_|gho_|[A-Za-z0-9_-]{20,}token|secret-value|boundary-fixture|top-secret|loop-secret|super-secret)' $SCAN_FILES 2>/dev/null | grep -viE '// |rawValue|placeholder|localizedDescription|sessionToken: nil|boundary-fixture|top-secret-in-app|app-secret-ticket-value|app-loop-secret|secret-ticket-xyz|loop-token-abc|fixture-token|fixture-ticket' || true)
if [ -n "$HITS" ]; then
  bad "possible secret-like literal found in U2 sources:"
  echo "$HITS" | head -10
else
  ok "no hardcoded secret-like literals in U2 sources"
fi

# --- 8. Git state ------------------------------------------------------------
note "Git state"
echo "  branch: $(git rev-parse --abbrev-ref HEAD)"
echo "  changed files:"
git diff --name-status

# --- Summary -----------------------------------------------------------------
printf '\n=====================================\n'
printf 'U2 validate: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
