#!/bin/bash
# RC preflight: verify repository-side readiness without signing, uploading,
# or claiming physical-device/live-gateway acceptance.
set -u
cd "$(dirname "$0")/.."
REPO=$(pwd)
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

printf 'Hermes Fleet RC preflight (repository checks only)\n'
printf 'repository: %s\n' "$REPO"

for doc in docs/release/RC-ACCEPTANCE-v1.md docs/release/RC-EVIDENCE-TEMPLATE.md; do
  if [ -s "$doc" ]; then pass "required document present: $doc"; else fail "missing or empty document: $doc"; fi
done

# Keep the source-of-truth version/build check deliberately simple and safe:
# values are read, never changed, and are also required in generated output.
version=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*([^[:space:]]+).*$/\1/p' project.yml | head -1)
build=$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*([^[:space:]]+).*$/\1/p' project.yml | head -1)
if printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'; then
  pass "version stamped: $version"
else
  fail "MARKETING_VERSION is missing or invalid"
fi
if printf '%s\n' "$build" | grep -Eq '^[1-9][0-9]*$'; then
  pass "build stamped: $build"
else
  fail "CURRENT_PROJECT_VERSION is missing or invalid"
fi
if [ -f HermesFleetApp.xcodeproj/project.pbxproj ] \
  && grep -Fq "MARKETING_VERSION = $version;" HermesFleetApp.xcodeproj/project.pbxproj \
  && grep -Fq "CURRENT_PROJECT_VERSION = $build;" HermesFleetApp.xcodeproj/project.pbxproj; then
  pass "generated Xcode project carries version/build $version ($build)"
else
  fail "generated Xcode project version/build does not match project.yml"
fi

# This is the canonical inventory audit and also exercises deterministic shard
# selection data without running simulator tests.
audit=$(bash scripts/c1_ui_matrix.sh --audit 2>&1)
audit_status=$?
printf '%s\n' "$audit"
if [ "$audit_status" -eq 0 ] && printf '%s\n' "$audit" | grep -Eq '^audit: [0-9]+ CI suites \+ [0-9]+ environmental suites = [0-9]+ bundle classes'; then
  pass "deterministic UI inventory and shard mapping audited"
else
  fail "deterministic UI inventory audit failed"
fi

if bash scripts/public_safety_guard.sh >/tmp/rc_public_safety.log 2>&1; then
  pass "public-safety guard"
else
  fail "public-safety guard"; sed -n '1,80p' /tmp/rc_public_safety.log
fi

printf '\nRC-TIME ACTIONS (not executable by this preflight):\n'
printf '  1. Archive the exact Release/RC candidate SHA and verify its version/build.\n'
printf '  2. Sign/export with the approved Apple identity; inspect entitlements and embedded profile.\n'
printf '  3. Install that exact build on a supported physical iPhone (device identifiers stay private).\n'
printf '  4. Exercise every journey in docs/release/RC-ACCEPTANCE-v1.md.\n'
printf '  5. Run every applicable environmental/live-Hermes suite; record concrete N/A reasons.\n'
printf '  6. Capture public-safe evidence and complete docs/release/RC-EVIDENCE-TEMPLATE.md.\n'
printf '  7. Obtain explicit authorization before any TestFlight upload, submission, or distribution.\n'

printf '\nRC PREFLIGHT: FAIL=%d\n' "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
