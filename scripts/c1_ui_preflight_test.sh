#!/bin/bash
# Selector self-test for scripts/c1_ui_preflight.sh — deterministic fixtures,
# no git history or simulator required. Runs in CI (static-guards job) and
# locally. A failure here means the focused preflight selection changed shape;
# update the mapping deliberately, never silently.
set -u
cd "$(dirname "$0")/.."
PRE=scripts/c1_ui_preflight.sh
[ -f "$PRE" ] || { echo "FAIL: missing $PRE"; exit 1; }

FAIL=0
tmpd=$(mktemp -d /tmp/c1_ui_preflight_test.XXXXXX) || { echo "FAIL: mktemp"; exit 1; }

check() { # <name> <expected classes> <file...>
  name="$1"; expected="$2"; shift 2
  printf '%s\n' "$@" > "$tmpd/files.txt"
  out=$(bash "$PRE" --files "$tmpd/files.txt" --print 2>&1); rc=$?
  got=$(printf '%s\n' "$out" | sed -n 's/^SELECTED_CLASSES: *//p' | tail -1)
  if [ "$rc" -ne 0 ]; then
    echo "FAIL  $name (selector exited $rc)"; echo "$out" | tail -5; FAIL=$((FAIL+1)); return
  fi
  if [ "$got" = "$expected" ]; then
    echo "PASS  $name"
  else
    echo "FAIL  $name"
    echo "  expected: '$expected'"
    echo "  got:      '$got'"
    FAIL=$((FAIL+1))
  fi
}

CORE="HermesFleetHappyPath HermesFleetReconnect P0_7SessionStateMachine U3TabNavigation FOS3FourRootShell"

check "docs/tooling-only changes select no UI suites" "" \
  "docs/README.md" "docs/adr/0001-per-gateway-session-ownership.md" ".github/workflows/ci.yml" "Makefile" "README.md"

check "a test-suite class file maps to its own suite" "RoomChat" \
  "HermesFleetAppUITests/RoomChatUITests.swift"

check "a test-support file falls back to CORE" "$CORE" \
  "HermesFleetAppUITests/UITabNavigation.swift"

check "a quarantined/environmental test class falls back to CORE" "$CORE" \
  "HermesFleetAppUITests/H1AppLockUITests.swift"

check "bot-avatar area maps to the avatar suites" "BotAvatarAppearance BotPetAvatar" \
  "Packages/FleetUI/Sources/FleetUI/BotAvatarEditor.swift"

check "gateway form area maps to the gateway suites" \
  "S3CleartextWarning RT2RemovalAndEndpointSanitization RT4FormSaveFailure P2GatewayFormDraft U7GatewayQrLockSettings" \
  "Packages/FleetUI/Sources/FleetUI/GatewayFormSheet.swift"

check "shared package change is conservative (CORE)" "$CORE" \
  "Packages/FleetCore/Sources/FleetCore/Session.swift"

check "unmapped app file is conservative (CORE)" "$CORE" \
  "HermesFleetApp/FleetServiceGraph.swift"

check "union across files, canonical order" "Splash RoomChat RoomLinkMentions" \
  "HermesFleetAppUITests/SplashUITests.swift" \
  "Packages/FleetUI/Sources/FleetUI/RoomChatView.swift"

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: UI preflight selector self-test — all cases green."
  exit 0
fi
echo "UI preflight selector self-test: FAIL=$FAIL"
exit 1
