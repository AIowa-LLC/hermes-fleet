#!/bin/bash
# C1 pull-request UI preflight — focused, changed-area suite selection.
#
# Dev Loop v2: ordinary pull-request CI validates a focused subset of the
# deterministic UI inventory, selected from the pull request's changed files.
# The complete five-shard matrix (merge_group / main pushes) remains the
# authoritative integration gate; this preflight only catches obvious defects
# earlier and must never be treated as a substitute for the full matrix.
#
# Usage:
#   scripts/c1_ui_preflight.sh                     # diff vs merge-base with the main ref
#   scripts/c1_ui_preflight.sh --base <ref>        # diff <ref>...HEAD (CI passes the PR base SHA)
#   scripts/c1_ui_preflight.sh --files <list|->    # classify an explicit changed-file list (- = stdin)
#   scripts/c1_ui_preflight.sh --print             # print the selection and exit without running xcodebuild
#
# Selection is deterministic (first matching rule wins):
#   1. non-product changes (docs/, .github/, scripts/, repo meta) select nothing;
#   2. a HermesFleetAppUITests class file maps to its own suite when the class
#      is in the deterministic inventory; other test-support files and any
#      product file without a more specific mapping fall back to the
#      conservative CORE journey set;
#   3. product areas map to suites via the ordered RULES table below.
# Every class referenced here is validated against the canonical inventory in
# scripts/c1_ui_matrix.sh (--list-classes); a mapping that references an
# unknown suite fails loudly. The selector is self-tested by
# scripts/c1_ui_preflight_test.sh.

set -u
cd "$(dirname "$0")/.."

die() { printf 'UI-PREFLIGHT FAIL: %s\n' "$1" >&2; exit 1; }

BASE=""
FILES=""
PRINT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:?--base needs a value}"; shift ;;
    --files) FILES="${2:?--files needs a value}"; shift ;;
    --print) PRINT=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

# --- canonical inventory ------------------------------------------------------
KNOWN="$(bash scripts/c1_ui_matrix.sh --list-classes)" || die "could not read the UI suite inventory"
[ -n "$KNOWN" ] || die "empty UI suite inventory"
has_class() { case " $KNOWN " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Conservative broad journeys for ambiguous/broad product changes and for
# product files without a more specific mapping. Keep this set small and broad.
CORE="HermesFleetHappyPath HermesFleetReconnect P0_7SessionStateMachine FOS3FourRootShell U3TabNavigation"

# Ordered area map (first match wins; specific before general).
# Each line: ERE pattern => space-separated suites.
RULES_FILE=$(mktemp /tmp/c1_ui_preflight_rules.XXXXXX) || die "mktemp failed"
cat > "$RULES_FILE" <<'RULES'
BotAvatar|BotPet => BotAvatarAppearance BotPetAvatar
Bot => U5BotDetail BotRoutines FOS5BotsGroupsChats
Room => RoomChat RoomLinkMentions
Conversation|AssistantRichText|Mention|ContextMeter|SessionSteer|Slash|Skill => U6ConversationSkin R9ConversationTooling Issue5StreamingRichText Issue4SlashSkill RoomLinkMentions
Kanban => KanbanBoard
Approval => R9ApprovalBanner
MemoryGraph => R9MemoryGraph R10MemoryGraphEdit
Attachment => R10AttachmentTray
Reaction => R10MessageReactions
Projects => R10ProjectsBrowser
Voice => R10Voice
HealthDashboard|Cron|ManagementPane => R9ManagementPanes
SetupPrompt => C2SetupPrompt
Settings|Accent|Theme|Appearance|Density => FleetSettingsAccent FOS6ComponentDensity
Roster => RT4RosterEmptyState FOS4TruthfulHome
Dashboard|Activity => U4Dashboard FOS4TruthfulHome
Pairing|Scanner|Onboarding => F2QRPairing F3Onboarding
GatewayForm|GatewayAuth|GatewayFailure|GatewaysView => S3CleartextWarning RT2RemovalAndEndpointSanitization P2GatewayFormDraft RT4FormSaveFailure U7GatewayQrLockSettings
Gateway => FOS2GatewayDetail U7GatewayQrLockSettings
Splash|Launch => Splash
Tab|Screen|Navigation|Destination => U3TabNavigation FOS3FourRootShell
Accessib => FOS8Accessibility
RULES

# Validate CORE and every rule suite against the canonical inventory.
for cls in $CORE; do
  has_class "$cls" || die "CORE references a suite outside the deterministic inventory: $cls"
done
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  pattern="${line%% => *}"
  suites="${line#* => }"
  [ "$suites" != "$line" ] && [ -n "$suites" ] || die "malformed rule line: $line"
  for cls in $suites; do
    has_class "$cls" || die "rule '$pattern' references a suite outside the deterministic inventory: $cls"
  done
done < "$RULES_FILE"

# --- classify one changed path --------------------------------------------------
# Echoes a space-separated class list (possibly empty = no UI run needed).
classify_file() {
  f="$1"
  # Non-product changes never require UI validation.
  case "$f" in
    docs/*|.github/*|scripts/*|Design/*|Makefile|AGENTS.md|README.md|SECURITY.md|LICENSE|LICENSE.*|CODE_OF_CONDUCT.md|CONTRIBUTING.md|.gitignore|.gitleaksignore) return ;;
    */*) ;;
    *.md|.*) return ;;
  esac
  # Test-suite class files map to their own suite when deterministic.
  case "$f" in
    HermesFleetAppUITests/*UITests.swift)
      base="${f##*/}"; cls="${base%UITests.swift}"
      if has_class "$cls"; then echo "$cls"; return; fi
      echo "$CORE"; return ;;
    HermesFleetAppUITests/*)
      echo "$CORE"; return ;;
  esac
  # Product-area rules, first match wins.
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    pattern="${line%% => *}"
    suites="${line#* => }"
    if echo "$f" | grep -Eq "$pattern"; then echo "$suites"; return; fi
  done < "$RULES_FILE"
  # Product-shaped file without a specific rule (and anything else not
  # recognized as non-product): conservative fallback.
  echo "$CORE"
}

# --- resolve the changed-files list ----------------------------------------------
LIST=$(mktemp /tmp/c1_ui_preflight_files.XXXXXX) || die "mktemp failed"
SRC=""
if [ -n "$FILES" ]; then
  if [ "$FILES" = "-" ]; then
    cat > "$LIST"; SRC="stdin"
  else
    [ -f "$FILES" ] || die "changed-files list not found: $FILES"
    cp "$FILES" "$LIST"; SRC="$FILES"
  fi
else
  if [ -z "$BASE" ]; then
    try_base() {
      mb=$(git merge-base HEAD "$1" 2>/dev/null) || return 1
      [ -n "$mb" ] || return 1
      if [ "$mb" = "$(git rev-parse HEAD)" ]; then return 1; fi
      BASE="$mb"; return 0
    }
    CUR=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    UP=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo "")
    if [ -n "$UP" ]; then
      case "$UP" in
        */"$CUR") : ;;                      # the branch's own remote — not a base
        *) try_base "$UP" || : ;;
      esac
    fi
    [ -n "$BASE" ] || try_base origin/main || :
    [ -n "$BASE" ] || try_base main || :
    [ -n "$BASE" ] || try_base target/main || :
    [ -n "$BASE" ] || die "could not resolve a diff base; pass --base <ref> or --files <list>"
  fi
  git rev-parse --verify "$BASE^{commit}" >/dev/null 2>&1 || die "base is not a resolvable commit: $BASE"
  git diff --name-only "${BASE}...HEAD" > "$LIST" || die "git diff failed for base ${BASE} vs HEAD"
  SRC="git diff ${BASE}...HEAD"
fi

# --- select ----------------------------------------------------------------------
SELECTED=""
echo "UI PREFLIGHT (Dev Loop v2) — changed-file source: $SRC"
if [ -s "$LIST" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    cls=$(classify_file "$f")
    if [ -n "$cls" ]; then echo "  $f -> $cls"; else echo "  $f -> (non-product; no UI run required)"; fi
    SELECTED="$SELECTED $cls"
  done < "$LIST"
fi
# Canonical order (deterministic output regardless of file order).
ORDERED=""
for k in $KNOWN; do case " $SELECTED " in *" $k "*) ORDERED="$ORDERED $k" ;; esac; done
ORDERED="${ORDERED# }"
echo "SELECTED_CLASSES: $ORDERED"

if [ "$PRINT" -eq 1 ]; then exit 0; fi
if [ -z "$ORDERED" ]; then
  echo "UI-PREFLIGHT: no UI-relevant changes in this diff; skipping focused UI run (merge_group remains the full authoritative matrix)."
  exit 0
fi
echo "UI-PREFLIGHT: running focused suites via scripts/c1_ui_matrix.sh --classes"
if ! bash scripts/c1_ui_matrix.sh --classes "$ORDERED"; then
  die "focused UI suite(s) failed"
fi
echo "UI-PREFLIGHT: focused UI suites passed."
