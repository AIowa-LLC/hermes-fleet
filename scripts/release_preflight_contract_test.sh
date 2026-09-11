#!/bin/bash
# Fail-closed contract tests for the release preflight and its artifact
# inspector. These tests avoid credentials and do not build or export an app.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP_ROOT="$(mktemp -d /tmp/hermes-release-contract.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_fails() {
  if "$@" >"$TMP_ROOT/command.out" 2>"$TMP_ROOT/command.err"; then
    fail "expected command to fail: $*"
  fi
}

bash -n scripts/release_preflight.sh
bash -n scripts/release_preflight_contract_test.sh
python3 -m py_compile scripts/release_artifact_inspect.py
plutil -lint scripts/release_export_options.plist >/dev/null
[[ "$(plutil -extract method raw -o - scripts/release_export_options.plist)" == "app-store-connect" ]] ||
  fail "export options do not use Xcode 26's app-store-connect method"

grep -q -- '--p8-file-path "$ASC_API_KEY_PATH"' scripts/release_preflight.sh ||
  fail "Apple validation does not consume ASC_API_KEY_PATH"
grep -q -- '-authenticationKeyPath' scripts/release_preflight.sh ||
  fail "xcodebuild authentication path is not represented"
if grep -q "signed archive did not expose\|signed-by-default" scripts/release_preflight.sh; then
  fail "archive stage still treats distribution signing as a required archive property"
fi

SHA="$(git rev-parse HEAD)"
assert_fails bash scripts/release_preflight.sh --sha "$SHA" --structure-only --validate --output-root "$TMP_ROOT/invalid-mode"
assert_fails bash scripts/release_preflight.sh --sha "0000000000000000000000000000000000000000" --structure-only --output-root "$TMP_ROOT/wrong-sha"

BAD_IPA="$TMP_ROOT/malformed.ipa"
python3 - "$BAD_IPA" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("Payload/Unexpected.app/Info.plist", b"not a plist")
PY
assert_fails python3 scripts/release_artifact_inspect.py \
  --ipa "$BAD_IPA" \
  --expected-bundle-id com.aiowa.hermesfleet \
  --expected-version 0.2.0 \
  --expected-build 32 \
  --expected-team 3JS22HX92T \
  --inspection-root "$TMP_ROOT/malformed-extracted"

echo "Release preflight contract tests: PASS"
