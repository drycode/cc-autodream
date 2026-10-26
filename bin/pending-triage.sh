#!/bin/bash
# The open questions earlier dreams raised that nobody has answered yet.
#
# Usage: pending-triage.sh --summary   one line: "now triaging N issues from dates A to B",
#                                      or "no issues to address!"
#        pending-triage.sh --list      one line per report, oldest first:
#                                      DATE<TAB>OPEN_QUESTIONS<TAB>REPORT_PATH
#                                      (OPEN_QUESTIONS is ? when the report does not say)
#
# A report is pending when its open-questions marker says more than zero and it has no
# "## Triage decisions" heading. That heading means the report is finished, so a session
# that is part way through one logs under "## Triage in progress" and renames the heading
# after the last question. A report whose count cannot be read ("unknown": no marker, a
# shape review.sh does not recognise) is listed with a "?" count and reported on its own,
# because review.sh opens a session for it too; calling it an empty queue would hide it.
# Only the last AUTODREAM_PENDING_DAYS days are looked at (default
# 14, and never a future date), so a report nobody ever triaged does not nag forever.
# Always exits 0; a missing reports directory is an empty queue.

set -u

_here="$(dirname "${BASH_SOURCE[0]}")"
# Installed copies are symlinks: a merge updates them before install.sh links a new helper.
_lib() { # $1=file name -> path of the sibling, following the symlink if needed
  [ -r "$_here/$1" ] && { printf '%s' "$_here/$1"; return; }
  printf '%s' "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/$1"
}
# shellcheck source=/dev/null
. "$(_lib portable.sh)"
# shellcheck source=/dev/null
. "$(_lib lib-install-dir.sh)"
# shellcheck source=/dev/null
. "$(_lib report-format.sh)"
resolve_install_dir "${BASH_SOURCE[0]}" pending-triage.sh

# The config is user-edited. A bare source under set -u kills this shell on one misspelled
# variable, before the summary prints, so source it with nounset off. The environment wins.
__env_dreams="${DREAMS_DIR:-}"; __env_days="${AUTODREAM_PENDING_DAYS:-}"
CONFIG_FILE="${AUTODREAM_CONFIG:-$AUTODREAM_DIR/config}"
set +u
# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
set -u
[ -n "$__env_dreams" ] && DREAMS_DIR="$__env_dreams"
[ -n "$__env_days" ] && AUTODREAM_PENDING_DAYS="$__env_days"
DREAMS_DIR="${DREAMS_DIR:-$(dirname "$AUTODREAM_DIR")/dreams}"

DAYS="${AUTODREAM_PENDING_DAYS:-14}"
case "$DAYS" in ''|*[!0-9]*) echo "pending-triage.sh: AUTODREAM_PENDING_DAYS must be a whole number (got '$DAYS')" >&2; exit 2 ;; esac

MODE=summary
case "${1:-}" in
  ''|--summary) MODE=summary ;;
  --list) MODE=list ;;
  -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
  *) echo "pending-triage.sh: unknown option: $1" >&2; exit 2 ;;
esac

TODAY=$(date +%Y-%m-%d)
CUTOFF=$(pdate_shift "$TODAY" "-$DAYS" d)

# DATE<TAB>COUNT<TAB>PATH for every pending report in the window, oldest first.
pending() {
  local f d n
  for f in "$DREAMS_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md; do
    [ -f "$f" ] || continue
    d=$(basename "$f" .md)
    [[ "$d" < "$CUTOFF" || "$d" > "$TODAY" ]] && continue
    report_is_triaged "$f" && continue
    n=$(report_open_questions "$f")
    case "$n" in
      ''|*[!0-9]*) printf '%s\t?\t%s\n' "$d" "$f"; continue ;;
    esac
    [ "$((10#$n))" -gt 0 ] || continue
    # A half-triaged report keeps its marker, so subtract what is already logged. One question
    # always stays: the heading is renamed only when the last one is resolved.
    n=$((10#$n - $(report_progress_count "$f")))
    [ "$n" -ge 1 ] || n=1
    printf '%s\t%s\t%s\n' "$d" "$n" "$f"
  done
}

ROWS=$(pending)

if [ "$MODE" = list ]; then
  [ -n "$ROWS" ] && printf '%s\n' "$ROWS"
  exit 0
fi

if [ -z "$ROWS" ]; then echo "no issues to address!"; exit 0; fi

TOTAL=$(printf '%s\n' "$ROWS" | awk -F'\t' '$2 ~ /^[0-9]+$/ {s += $2} END {print s + 0}')
UNKNOWN=$(printf '%s\n' "$ROWS" | awk -F'\t' '$2 == "?"' | wc -l | tr -d ' ')
FIRST=$(printf '%s\n' "$ROWS" | head -1 | cut -f1)
LAST=$(printf '%s\n' "$ROWS" | tail -1 | cut -f1)
if [ "$FIRST" = "$LAST" ]; then SPAN="from $FIRST"; else SPAN="from dates $FIRST to $LAST"; fi
NOUN=issues; [ "$TOTAL" -eq 1 ] && NOUN=issue
RNOUN=reports; [ "$UNKNOWN" -eq 1 ] && RNOUN=report
if [ "$UNKNOWN" -eq 0 ]; then echo "now triaging $TOTAL $NOUN $SPAN"
elif [ "$TOTAL" -eq 0 ]; then echo "now triaging $UNKNOWN $RNOUN with an unreadable question count $SPAN"
else echo "now triaging $TOTAL $NOUN $SPAN, plus $UNKNOWN $RNOUN with an unreadable question count"; fi
