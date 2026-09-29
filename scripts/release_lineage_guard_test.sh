#!/usr/bin/env bash
# Synthetic source-provenance contracts; no signing, simulator, or live gateway.
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE_ROOT="$PWD"
TMP_ROOT="$(mktemp -d /tmp/hermes-lineage-contract.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT
FIXTURE="$TMP_ROOT/repo"
mkdir -p "$FIXTURE/scripts" "$TMP_ROOT/bin"
cp scripts/release_lineage_guard.sh scripts/release_preflight.sh scripts/archive_and_export.sh "$FIXTURE/scripts/"
git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.name 'Release Contract'
git -C "$FIXTURE" config user.email 'release-contract@example.invalid'
printf 'initial\n' > "$FIXTURE/README"
git -C "$FIXTURE" add .
git -C "$FIXTURE" commit -qm initial
STALE="$(git -C "$FIXTURE" rev-parse HEAD)"
printf 'approved\n' > "$FIXTURE/README"
git -C "$FIXTURE" commit -qam approved
BASELINE="$(git -C "$FIXTURE" rev-parse HEAD)"
mkdir -p "$FIXTURE/docs/release"
printf '%s\n' "$BASELINE" > "$FIXTURE/docs/release/integration-baseline.sha"
git -C "$FIXTURE" add .
git -C "$FIXTURE" commit -qm pin
CANDIDATE="$(git -C "$FIXTURE" rev-parse HEAD)"
expect_fail() {
  if "$@" >"$TMP_ROOT/out" 2>&1; then
    echo "FAIL: expected rejection: $*" >&2; exit 1
  fi
}
guard() { bash "$FIXTURE/scripts/release_lineage_guard.sh" "$@"; }
guard "$CANDIDATE" >/dev/null
# Wrong, abbreviated, uppercase, and missing candidates fail.
expect_fail guard "$BASELINE"
expect_fail guard "${CANDIDATE:0:12}"
expect_fail guard ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD
expect_fail guard
printf 'dirty\n' >> "$FIXTURE/README"
expect_fail env FLEET_RELEASE_ALLOW_DIRTY=1 bash "$FIXTURE/scripts/release_lineage_guard.sh" "$CANDIDATE"
git -C "$FIXTURE" restore README
printf 'untracked\n' > "$FIXTURE/Extra.swift"
expect_fail guard "$CANDIDATE"
rm "$FIXTURE/Extra.swift"
# A dirty baseline replacement cannot downgrade the committed pin.
printf '%s\n' "$STALE" > "$FIXTURE/docs/release/integration-baseline.sha"
expect_fail guard "$CANDIDATE"
git -C "$FIXTURE" restore docs/release/integration-baseline.sha
# Missing, malformed, multiple, and unavailable committed pins fail.
for value in missing malformed multiple unavailable; do
  git -C "$FIXTURE" checkout -q --detach "$CANDIDATE"
  case "$value" in
    missing) git -C "$FIXTURE" rm -q docs/release/integration-baseline.sha ;;
    malformed) printf 'not-a-sha\n' > "$FIXTURE/docs/release/integration-baseline.sha" ;;
    multiple) printf '%s\n%s\n' "$BASELINE" "$STALE" > "$FIXTURE/docs/release/integration-baseline.sha" ;;
    unavailable) printf '%040d\n' 0 > "$FIXTURE/docs/release/integration-baseline.sha" ;;
  esac
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -qm "$value"
  expect_fail guard "$(git -C "$FIXTURE" rev-parse HEAD)"
done
# An old side branch carrying the newer pin must fail before external tools.
git -C "$FIXTURE" switch -q -C main "$STALE"
mkdir -p "$FIXTURE/docs/release"
printf '%s\n' "$BASELINE" > "$FIXTURE/docs/release/integration-baseline.sha"
git -C "$FIXTURE" add .
git -C "$FIXTURE" commit -qm 'stale branch with newer pin'
STALE_CANDIDATE="$(git -C "$FIXTURE" rev-parse HEAD)"
expect_fail guard "$STALE_CANDIDATE"
# Fake tools record accidental build/generation before provenance validation.
for tool in xcodebuild xcodegen; do
  cat > "$TMP_ROOT/bin/$tool" <<'MOCK'
#!/bin/bash
printf 'unexpected tool invocation\n' >> "$LINEAGE_TOOL_CALLS"
exit 99
MOCK
  chmod +x "$TMP_ROOT/bin/$tool"
done
export LINEAGE_TOOL_CALLS="$TMP_ROOT/tool-calls"
export PATH="$TMP_ROOT/bin:$PATH"
expect_fail bash "$FIXTURE/scripts/release_preflight.sh" --sha "$STALE_CANDIDATE" --structure-only
grep -q 'RELEASE-LINEAGE-FAIL' "$TMP_ROOT/out"
expect_fail env FLEET_RELEASE_ALLOW_DIRTY=1 bash "$FIXTURE/scripts/archive_and_export.sh" 100 "$STALE_CANDIDATE"
grep -q 'RELEASE-LINEAGE-FAIL' "$TMP_ROOT/out"
[[ ! -e "$LINEAGE_TOOL_CALLS" ]] || { echo 'FAIL: tool ran before lineage check' >&2; exit 1; }
# Ancestry call sites cannot silently disappear from either entry point.
grep -Fq 'bash scripts/release_lineage_guard.sh "$EXPECTED_SHA"' "$SOURCE_ROOT/scripts/release_preflight.sh"
grep -Fq 'bash scripts/release_lineage_guard.sh "$HEAD_SHA"' "$SOURCE_ROOT/scripts/archive_and_export.sh"
echo 'Release lineage guard contracts: PASS'
