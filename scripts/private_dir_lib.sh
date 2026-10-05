#!/bin/bash
# Sourced helper: create-or-validate a private working directory.
#
# Some supported workflows (live-gateway dogfood, reviewer environment) must
# keep state across several script invocations, so a one-shot `mktemp -d` is
# not enough. A fixed name inside a shared temp directory is only safe if the
# directory is verified to be ours: a local user could otherwise pre-create it
# (read tokens, pre-seed files) or replace it with a symlink (redirect writes).
#
#   hf_private_dir <path>   prints <path>; returns non-zero (message on stderr)
#                           unless <path> is a real directory, owned by the
#                           current user, with mode exactly 0700.
#   hf_private_name <base>  prints "${TMPDIR:-/tmp}/<base>-<uid>" so two users
#                           on one host never contend for the same name.

hf__stat_field() { # <owner|mode> <path>
  local what="$1" p="$2" out
  # GNU first: on BSD `stat -c` fails, whereas GNU `stat -f` succeeds with
  # unrelated filesystem output.
  if [ "$what" = owner ]; then
    out=$(stat -c %u "$p" 2>/dev/null) || out=$(stat -f %u "$p" 2>/dev/null) || return 1
  else
    out=$(stat -c %a "$p" 2>/dev/null) || out=$(stat -f %Lp "$p" 2>/dev/null) || return 1
  fi
  printf '%s' "$out"
}

hf_private_name() {
  printf '%s/%s-%s' "${TMPDIR:-/tmp}" "$1" "$(id -u)"
}

hf_private_dir() {
  local d="${1:-}" owner mode
  if [ -z "$d" ]; then echo "FAIL: empty private directory path" >&2; return 1; fi
  if [ -L "$d" ]; then echo "FAIL: $d is a symlink; refusing to use it" >&2; return 1; fi
  if [ ! -e "$d" ]; then
    # Missing parents are created as before (mkdir -p), but only the leaf is
    # the private, validated directory.
    mkdir -p "$(dirname "$d")" 2>/dev/null || true
    # Non-recursive and mode-atomic. Losing a creation race is fine: the
    # validation below then rejects anything that is not ours and private.
    (umask 077; mkdir -m 700 "$d") 2>/dev/null || true
  fi
  if [ ! -d "$d" ] || [ -L "$d" ]; then echo "FAIL: $d is not a real directory" >&2; return 1; fi
  owner=$(hf__stat_field owner "$d") || { echo "FAIL: cannot stat $d" >&2; return 1; }
  mode=$(hf__stat_field mode "$d") || { echo "FAIL: cannot stat $d" >&2; return 1; }
  if [ "$owner" != "$(id -u)" ]; then
    echo "FAIL: $d is not owned by the current user; refusing to use it" >&2; return 1
  fi
  if [ "$mode" != "700" ]; then
    echo "FAIL: $d has mode $mode, expected 700 (chmod 700 it, or remove it)" >&2; return 1
  fi
  printf '%s\n' "$d"
}

# The pre-rename default reviewer state directory (no uid suffix). It may still
# hold old reviewer credentials; they must never silently enter a validation run.
hf_legacy_reviewer_dir() {
  printf '%s/hermes-fleet-reviewer' "${TMPDIR:-/tmp}"
}

# Physical (symlink-free) absolute form of <path>. The longest existing prefix
# is resolved with `cd -P`; any not-yet-existing tail is appended unchanged.
hf_canonical_path() {
  local p="$1" d b
  [ -n "$p" ] || return 1
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  if [ -d "$p" ]; then ( cd -P "$p" 2>/dev/null && pwd -P ); return; fi
  d="$(dirname "$p")"; b="$(basename "$p")"
  [ "$d" = "$p" ] && { printf '%s' "$p"; return; }
  d="$(hf_canonical_path "$d")" || return 1
  [ "$d" = "/" ] && printf '/%s' "$b" || printf '%s/%s' "$d" "$b"
}

# True when <path> is the legacy directory or inside it, after resolving
# symlinks, `.`/`..`, trailing or doubled slashes and (on macOS) case.
hf_is_legacy_reviewer_path() {
  local p legacy
  p="$(hf_canonical_path "${1:-}")" || return 1
  legacy="$(hf_canonical_path "$(hf_legacy_reviewer_dir)")" || return 1
  if [ "$(uname)" = "Darwin" ]; then
    p="$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')"
    legacy="$(printf '%s' "$legacy" | tr '[:upper:]' '[:lower:]')"
  fi
  [ "$p" = "$legacy" ] && return 0
  case "$p" in "$legacy"/*) return 0 ;; esac
  return 1
}
