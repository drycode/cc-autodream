#!/bin/bash
# Detect the user's Claude config dirs and decide which ones autodream indexes.
#
# Claude Code supports many config dirs at once: each profile that runs under a
# different $CLAUDE_CONFIG_DIR (~/.claude-nous, ~/.claude-ds4, ~/.claude-sigint, ...)
# gets its own projects/ bucket holding that profile's session transcripts. autodream
# used to scan exactly one ($HOME/.claude/projects), so any session recorded in a
# different profile's bucket was invisible to the nightly report. This script closes
# that gap: it lists every $HOME/.claude*/projects it can find, applies the choices the
# user has already recorded, and reports the rest.
#
# Choices are remembered in $AUTODREAM_DIR/root-choices.conf, a plain KEY=VALUE file
# with `# claude-folder-indexing` as a header comment so a human can tell the managed
# lines from their own edits:
#
#   # claude-folder-indexing  (managed by bin/root-probe.sh)
#   ~/.claude/projects=index      # always indexed
#   ~/.claude-ds4/projects=index
#   ~/.claude-kimi/projects=ignore
#
# Values: index | ignore. The primary $HOME/.claude/projects is always index and is
# always scanned. Editing or deleting a line in this file is how a choice is changed.
# AUTODREAM_INDEX_ALL=1 flips everything to index without asking.
#
# Usage:
#   root-probe.sh --list            # every detected root + its state (index/ignore/unasked)
#   root-probe.sh --consolidated    # colon-joined root list autodream should scan
#   root-probe.sh --unindexed       # only the found-but-not-indexed roots (or empty)
#   root-probe.sh --write-config    # the managed SESSION_ROOTS section (used by install.sh)
#   root-probe.sh --ask             # prompt per unasked root, remember the answer (install TTY)
#   root-probe.sh --default-index   # never prompt; unasked roots -> index (install non-TTY)
#
# Env:
#   AUTODREAM_DIR    where root-choices.conf lives   default: $HOME/.claude/autodream
#   AUTODREAM_INDEX_ALL  set 1 to index every detected root without asking
#
# With neither --ask nor --default-index (the nightly run), choices are never written:
# unasked roots stay unasked, are excluded from --consolidated, and are reported by
# --unindexed so the morning report can flag folders that appeared after setup.
#
# Artifacts only, no model calls. Safe to re-run.

set -u

AUTODREAM_DIR="${AUTODREAM_DIR:-$HOME/.claude/autodream}"
CHOICES="$AUTODREAM_DIR/root-choices.conf"

PRIMARY="$HOME/.claude/projects"
# shellcheck disable=SC2125  # the glob must stay literal so it expands in the `for` loop below
PROBE_GLOB="$HOME"/.claude*/projects

MODE=""
WRITE=0
# ---- command dispatch ----
for a in "$@"; do
  case "$a" in
    --list|--consolidated|--unindexed|--write-config) MODE="${MODE:-$a}" ;;
    --ask|--default-index) MODE="${MODE:-$a}" ;;
    -h|--help) sed -n '1,44p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { echo "usage: $0 --list|--consolidated|--unindexed|--write-config [--ask|--default-index]" >&2; exit 2; }
case "$MODE" in
  --ask|--default-index) WRITE=1 ;;
esac

# ---- load remembered choices ----
# Small file, so a linear scan per lookup beats carrying a map. This stays bash-3.2
# compatible (macOS ships bash 3.2 with no associative arrays).
ck=(); cv=()
if [ -f "$CHOICES" ]; then
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    ck+=("${line%%=*}")
    cv+=("${line#*=}")
  done < "$CHOICES"
fi
choice() { # $1 = root path → echoes index | ignore | unasked
  local r="$1" i
  [ "$r" = "$PRIMARY" ] && { echo "index"; return; }
  for i in "${!ck[@]}"; do
    [ "${ck[$i]}" = "$r" ] && { echo "${cv[$i]}"; return; }
  done
  echo "unasked"
}

# ---- discover roots ----
roots=()
for d in $PROBE_GLOB; do
  [ -d "$d" ] || continue
  roots+=("$d")
done
# Primary first if it's present.
if [ -d "$PRIMARY" ]; then
  sorted=("$PRIMARY")
  for r in "${roots[@]}"; do
    [ "$r" = "$PRIMARY" ] || sorted+=("$r")
  done
  roots=("${sorted[@]}")
fi

# With no $HOME/.claude*/projects at all, `"${roots[@]}"` is an unbound-array reference
# under set -u. Keep a sentinel so every expansion below is safe.
[ "${#roots[@]}" -gt 0 ] || roots=("")

unasked=()
for r in "${roots[@]}"; do
  [ -n "$r" ] || continue
  [ "$(choice "$r")" = "unasked" ] && unasked+=("$r")
done

# ---- resolve unasked roots (only when the caller asked us to write choices) ----
if [ "$WRITE" = "1" ] && [ "${#unasked[@]}" -gt 0 ]; then
  mkdir -p "$AUTODREAM_DIR"
  if [ "$MODE" = "--ask" ] && [ -t 0 ]; then
    # Interactive install: prompt per root. The primary never appears here.
    for r in "${unasked[@]}"; do
      n=$(find "$r" -type f -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
      printf 'Autodream: index sessions under %s (%s transcripts)? [Y/n] ' "$r" "$n"
      IFS= read -r ans
      case "${ans:-y}" in
        y|Y|"") echo "$r=index" >> "$CHOICES" ;;
        *)      echo "$r=ignore" >> "$CHOICES" ;;
      esac
    done
  else
    # Non-TTY or --default-index: index unasked roots, silently, and say so.
    for r in "${unasked[@]}"; do
      echo "$r=index" >> "$CHOICES"
      echo "indexing $r (no TTY to ask)" >&2
    done
  fi
fi

consolidated_roots() { # colon-joined index list; primary first when it exists
  local first=1 r
  for r in "${roots[@]}"; do
    [ -n "$r" ] || continue
    [ "$r" = "$PRIMARY" ] || [ "$(choice "$r")" = "index" ] || continue
    case "$r" in *:*)   # a ':' in the path would be re-split on read
      echo "root-probe: refusing to index path containing ':' ($r); SESSION_ROOTS is colon-separated" >&2
      continue ;;
    esac
    [ "$first" = "1" ] || printf ':'
    printf '%s' "$r"
    first=0
  done
}

case "$MODE" in
  --list)
    for r in "${roots[@]}"; do
      [ -n "$r" ] || continue
      printf '%s\t%s\n' "$(choice "$r")" "$r"
    done
    ;;
  --consolidated)
    # Primary first when it exists; index-order otherwise.
    consolidated_roots
    printf '\n'
    ;;
  --unindexed)
    for r in "${roots[@]}"; do
      [ -n "$r" ] || continue
      [ "$(choice "$r")" = "index" ] && continue
      printf '%s\n' "$r"
    done
    ;;
  --write-config)
    # The managed SESSION_ROOTS section for $AUTODREAM_DIR/config. The config is
    # sourced by bash, so a root with spaces or shell metacharacters must be quoted.
    # The scan-side read (scan_roots) splits on ':' AFTER this quote is removed, so a
    # path with a literal ':' remains unsupported and is refused by consolidated_roots.
    consolidated=$(consolidated_roots)
    printf '# claude-folder-indexing  (managed by bin/root-probe.sh)\n'
    printf 'SESSION_ROOTS=%s\n' "$(printf '%q' "$consolidated")"
    ;;
esac
