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

CORE="HermesFleetHappyPath P0_7SessionStateMachine"
ALL="$(bash scripts/c1_ui_matrix.sh --list-classes)"

check "docs/tooling-only changes select no UI suites" "" \
  "docs/README.md" "docs/adr/0001-per-gateway-session-ownership.md" ".github/workflows/ci.yml" "Makefile" "README.md" \
  "hosted/34426824450_s5.log" "local/repro_hosted.sh" "evidence.md"

check "a test-suite class file maps to its own suite" "RoomChat" \
  "HermesFleetAppUITests/RoomChatUITests.swift"

check "a test-support file falls back to CORE" "$CORE" \
  "HermesFleetAppUITests/UITabNavigation.swift"

check "a re-admitted canonical CI class file maps to its own suite" "H1AppLock" \
  "HermesFleetAppUITests/H1AppLockUITests.swift"

check "an environmental (non-CI) test class falls back to CORE" "$CORE" \
  "HermesFleetAppUITests/L1LiveGatewayUITests.swift"

check "bot-avatar area maps to the avatar suites" "BotAvatarAppearance BotPetAvatar" \
  "Packages/FleetUI/Sources/FleetUI/BotAvatarEditor.swift"

check "gateway form area maps to the gateway suites" \
  "S3CleartextWarning RT2RemovalAndEndpointSanitization RT4FormSaveFailure P2GatewayFormDraft U7GatewayQrLockSettings" \
  "Packages/FleetUI/Sources/FleetUI/GatewayFormSheet.swift"

check "shared package changes retain full deterministic coverage" "$ALL" \
  "Packages/FleetCore/Sources/FleetCore/Session.swift"

check "composition-root changes retain full deterministic coverage" "$ALL" \
  "HermesFleetApp/FleetServiceGraph.swift"

check "union across files, canonical order" "Splash RoomChat RoomLinkMentions" \
  "HermesFleetAppUITests/SplashUITests.swift" \
  "Packages/FleetUI/Sources/FleetUI/RoomChatView.swift"

check "oversized product diff retains every affected suite" "HermesFleetHappyPath HermesFleetReconnect P0_7SessionStateMachine S3CleartextWarning RT2RemovalAndEndpointSanitization RT4RosterEmptyState RT4FormSaveFailure RT4VoiceOver Splash P2GatewayFormDraft F2QRPairing U3TabNavigation SecondGeneration" \
  "HermesFleetAppUITests/HermesFleetHappyPathUITests.swift" \
  "HermesFleetAppUITests/HermesFleetReconnectUITests.swift" \
  "HermesFleetAppUITests/P0_7SessionStateMachineUITests.swift" \
  "HermesFleetAppUITests/S3CleartextWarningUITests.swift" \
  "HermesFleetAppUITests/RT2RemovalAndEndpointSanitizationUITests.swift" \
  "HermesFleetAppUITests/RT4RosterEmptyStateUITests.swift" \
  "HermesFleetAppUITests/RT4FormSaveFailureUITests.swift" \
  "HermesFleetAppUITests/RT4VoiceOverUITests.swift" \
  "HermesFleetAppUITests/SplashUITests.swift" \
  "HermesFleetAppUITests/P2GatewayFormDraftUITests.swift" \
  "HermesFleetAppUITests/F2QRPairingUITests.swift" \
  "HermesFleetAppUITests/U3TabNavigationUITests.swift" \
  "HermesFleetAppUITests/SecondGenerationUITests.swift"

check "interactive Kanban retains both release suites" "KanbanBoard KanbanInteractive" \
  "Packages/FleetUI/Sources/FleetUI/KanbanBoardView.swift"
check "image generation maps to its release regression" "ImageGenerationAnimation" \
  "Packages/FleetUI/Sources/FleetUI/ImageGenerationView.swift"
check "artifact destination maps to its release regression" "ArtifactsDestination" \
  "Packages/FleetUI/Sources/FleetUI/ArtifactsView.swift"
check "cron retains management and tab coverage" "R9ManagementPanes CronManagement CronTab" \
  "Packages/FleetUI/Sources/FleetUI/CronView.swift"
check "slash parity keeps the upstream compatibility regression" "Issue4SlashSkill SlashCommandParity" \
  "Packages/FleetUI/Sources/FleetUI/SlashCommandView.swift"
check "cached launch maps to its release regression" "FleetLaunchCache" \
  "Packages/FleetUI/Sources/FleetUI/LaunchCache.swift"
check "unread state maps to its release regression" "FleetUnreadBadge" \
  "Packages/FleetUI/Sources/FleetUI/UnreadState.swift"
check "reasoning slider maps to its release regression" "ReasoningSlider" \
  "Packages/FleetUI/Sources/FleetUI/ReasoningSlider.swift"
check "about screen maps to its release regression" "FleetAbout" \
  "Packages/FleetUI/Sources/FleetUI/FleetAboutView.swift"
check "compact chrome maps to its release regression" "ConversationCompactChrome" \
  "Packages/FleetUI/Sources/FleetUI/ConversationCompactChrome.swift"

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: UI preflight selector self-test — all cases green."
  exit 0
fi
echo "UI preflight selector self-test: FAIL=$FAIL"
exit 1
