#!/bin/bash
# i16-fix: rerun the 21 UI suites that failed in the first c1_ui_matrix --all
# pass when the shared destination sim was shut down mid-gate (xctrunner
# "Busy / failed preflight" — host load 173 from sibling lanes). Identical
# xcodebuild invocation to scripts/c1_ui_matrix.sh.
set -u
OUT=/tmp/hgoal/i16-fix/local/runs
mkdir -p "$OUT"
cd /tmp/hgoal/i16-fix
SIM_NAME=$(xcrun simctl list devices available | grep -E 'iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/ \(.*//')
DEST="platform=iOS Simulator,name=$SIM_NAME,OS=latest"
DD="/tmp/hgoal/i16-fix/build/C1Ui"
XC=(-project HermesFleetApp.xcodeproj -scheme HermesFleetApp -destination "$DEST" -derivedDataPath "$DD" -skipMacroValidation)
FAILED=(RT2RemovalAndEndpointSanitization RT4RosterEmptyState F2QRPairing
  U3TabNavigation SecondGeneration U6ConversationSkin U7GatewayQrLockSettings
  F3Onboarding C2SetupPrompt KanbanBoard R10ProjectsBrowser R10Voice
  R10MemoryGraphEdit Issue4SlashSkill Issue5StreamingRichText
  FleetSettingsAccent BotRoutines FOS6ComponentDensity FOS8Accessibility
  BotAvatarAppearance BotPetAvatar H1AppLock)
echo "rerun destination: $DEST"
N=0; F=0
for cls in "${FAILED[@]}"; do
  N=$((N+1))
  log="$OUT/rerun_${cls}.log"
  if ! xcodebuild "${XC[@]}" "-only-testing:HermesFleetAppUITests/${cls}UITests" build test >"$log" 2>&1; then
    F=$((F+1)); printf 'FAIL  %s\n' "$cls"
  else
    printf 'PASS  %s | %s\n' "$cls" "$(grep -E 'Executed .* tests' "$log" | tail -1 | tr -s ' ')"
  fi
done
printf 'RERUN: suites=%d FAIL=%d\n' "$N" "$F"
[ "$F" -eq 0 ] || exit 1
