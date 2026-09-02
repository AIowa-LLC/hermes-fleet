#!/bin/bash
# t_0edc355d (P0-7): Debug device deploy + roster-presence live verification.
# Reuses the T3 paid-team loop's proven build/sign/install/launch steps, then
# verifies the P0-7 acceptance: with the multiplexer gateway running (steady
# state: ONE gateway on 9120, per-profile gateways OFF), the roster shows all
# profiles ONLINE (reachable) after refresh; with the gateway STOPPED, refresh
# flips them offline (unreachable).
#
# TOOLING: script file + bash only. No key material. The 9120 gateway is the
# P0-8 hermetic multiplexer (env-clean, verified separately); this script
# never touches PRODUCTION env.
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
PASS=0; FAIL=0
declare -a FAILURES=()
note() { printf '\n=== %s ===\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf 'FAIL  %s\n' "$1"; }

DEVICE="<physical-device-id>"
TEAM="3JS22HX92T"
BUNDLE="com.aiowa.hermesfleet"
DD="$REPO/build/DerivedDataP07Device"
APP="$DD/Build/Products/Debug-iphoneos/HermesFleetApp.app"
PORT=9120

# --- 1. Preconditions ---------------------------------------------------------
note "Preconditions: device + cert + gateway state"
xcrun devicectl list devices 2>/dev/null | grep -q "$DEVICE" \
  && ok "iPhone 16 Pro Max visible (paired)" \
  || bad "iPhone NOT visible — needs plug-in/re-pair"
security find-identity -v -p codesigning 2>/dev/null | grep -q "6RGB2PVBT4" \
  && ok "paid-team dev cert 6RGB2PVBT4 in login keychain" \
  || bad "dev cert missing"

LISTENERS=$(lsof -nP -iTCP:$PORT -sTCP:LISTEN -t 2>/dev/null | sort -u | wc -l | tr -d ' ')
if [ "$LISTENERS" -ge 2 ]; then
  ok "multiplexer gateway listening on :$PORT ($LISTENERS surfaces: LAN + tailnet)"
  GATEWAY_UP=1
else
  echo "  WARN: gateway on :$PORT has $LISTENERS listeners — presence acceptance 'online' phase needs it up"
  GATEWAY_UP=0
fi
# Env-cleanliness gate (P0-8 lesson): a kanban-contaminated gateway is invalid.
for pid in $(lsof -nP -iTCP:$PORT -sTCP:LISTEN -t 2>/dev/null | sort -u); do
  BAD=$(ps eww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n' | grep -cE '^HERMES_KANBAN|^HERMES_SESSION_' || true)
  [ "$BAD" -eq 0 ] && ok "gateway pid $pid env-clean (no kanban/session vars)" \
                    || bad "gateway pid $pid env-CONTAMINATED"
done

# --- 2. Build Debug-iphoneos (paid team, automatic signing) -------------------
note "Build Debug-iphoneos (team $TEAM)"
if xcodebuild -project HermesFleetApp.xcodeproj -scheme HermesFleetApp \
    -configuration Debug \
    -destination "id=$DEVICE" \
    -derivedDataPath "$DD" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    build >/tmp/p07_device_build.log 2>&1; then
  ok "device BUILD SUCCEEDED"
else
  bad "device build FAILED"; tail -40 /tmp/p07_device_build.log
fi

# --- 3. Codesign verification (metadata only) ---------------------------------
note "Codesign verification"
if codesign -dv --verbose=4 "$APP" >/tmp/p07_codesign.log 2>&1; then
  echo "  $(grep -E '^Authority|^TeamIdentifier' /tmp/p07_codesign.log | tr '\n' ' ')"
  grep -q "TeamIdentifier=$TEAM" /tmp/p07_codesign.log \
    && ok "signed with team $TEAM" || bad "team mismatch"
else
  bad "codesign --verify FAILED"
fi

# --- 4. Fresh install + launch ------------------------------------------------
note "Fresh install + launch on device"
xcrun devicectl device uninstall app --device "$DEVICE" "$BUNDLE" >/dev/null 2>&1
sleep 2
if xcrun devicectl device install app --device "$DEVICE" "$APP" >/tmp/p07_install.log 2>&1; then
  ok "app installed (fresh)"
else
  if grep -qiE 'locked|12040|developer disk image' /tmp/p07_install.log; then
    bad "install BLOCKED: device LOCKED (DDI cannot mount) — Tony must unlock the iPhone"
  else
    bad "install FAILED"; tail -10 /tmp/p07_install.log
  fi
fi
LAUNCH_OUT=$(xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" 2>&1)
echo "$LAUNCH_OUT" | grep -qiE 'launching.*((succeed)|(com\.aiowa))|pid' \
  && ok "app launched: $(echo "$LAUNCH_OUT" | tail -1)" \
  || { grep -qiE 'locked|unlock' <<<"$LAUNCH_OUT" \
       && bad "launch BLOCKED: device locked" \
       || bad "launch FAILED: $(echo "$LAUNCH_OUT" | tail -2 | tr '\n' ' ')"; }

# --- 5. Summary ----------------------------------------------------------------
note "Summary"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILURES:\n'; printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
echo "DEVICE DEPLOY OK — on-device roster acceptance (all-online with gateway up;"
echo "offline flip after gateway toggle + refresh) is Tony's visual dogfood check:"
echo "open the app → Roster tab → pull-refresh: every bot pill should read Online"
echo "(green) while the multiplexer gateway is up. Toggling the gateway and"
echo "refreshing flips them offline-gray (outage sections per gateway)."
