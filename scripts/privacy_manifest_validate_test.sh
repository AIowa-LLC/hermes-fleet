#!/bin/bash
# Fail-closed tests for privacy_manifest_validate.sh. The temporary copies
# prove that a missing or malformed manifest cannot pass the release guard.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP_DIR="$(mktemp -d /tmp/hermes_privacy_manifest_test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

valid="$TMP_DIR/valid.xcprivacy"
cp HermesFleetApp/PrivacyInfo.xcprivacy "$valid"
bash scripts/privacy_manifest_validate.sh --manifest "$valid" >/dev/null

if bash scripts/privacy_manifest_validate.sh --manifest "$TMP_DIR/missing.xcprivacy" >/dev/null 2>&1; then
  echo "FAIL: missing privacy manifest was accepted" >&2
  exit 1
fi

malformed="$TMP_DIR/malformed.xcprivacy"
cp "$valid" "$malformed"
plutil -replace NSPrivacyTracking -bool YES "$malformed"
if bash scripts/privacy_manifest_validate.sh --manifest "$malformed" >/dev/null 2>&1; then
  echo "FAIL: malformed privacy declaration was accepted" >&2
  exit 1
fi

echo "Privacy manifest fail-closed validation: PASS"
