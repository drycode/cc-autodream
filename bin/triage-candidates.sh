#!/usr/bin/env bash
# triage-candidates.sh - list the repos a session touched that have a pile of untriaged issues.
#
# Sessions in the report window ran in some set of repos. For each GitHub repo among them this
# counts the open issues that no one has triaged and, when the pile is big enough, puts the repo
# in <out-dir>/triage-candidates.md so the nightly report can suggest running /triage there.
# It only reads: it never labels, comments on or closes an issue.
#
# WHAT COUNTS AS UNTRIAGED
#
# The triage skill gives every handled issue one state label: needs-info, ready-for-agent,
# ready-for-human or wontfix. An open issue is untriaged when it has none of those, or when it
# carries needs-triage. A repo that has never been triaged has no state labels at all, so every
# open issue in it counts: its first triage is exactly what this list is for. The threshold and
# the cooldown keep a long backlog from being suggested every night.
#
# WHEN A REPO IS SUGGESTED
#
#   * untriaged >= AUTODREAM_TRIAGE_MIN (default 3);
#   * the viewer can triage there (admin, maintain, write or triage permission) and the repo is
#     not archived, so an upstream project whose tracker is not yours is never suggested;
#   * and it was not suggested within AUTODREAM_TRIAGE_COOLDOWN_DAYS (default 7), unless the
#     count has grown by AUTODREAM_TRIAGE_GROW (default 3) since that suggestion.
# The last suggestion per repo is kept in AUTODREAM_TRIAGE_STATE (default
# ~/.claude/autodream/triage-suggested.tsv: slug, date, count). A rerun of the same report date
# is never held back by its own earlier suggestion, so a retried night still shows the list.
#
# Usage:
#   triage-candidates.sh <out-dir>      rows on stdin, one per session; the LAST tab-separated
#                                       column of each is the session's working directory
#     writes <out-dir>/triage-candidates.tsv (status, slug, repo, untriaged, open, oldest days,
#     detail) and triage-candidates.md, and prints one summary line. Always exits 0 once it has
#     an out-dir: a failure here must not cost the night's report.
#
# Config (env):
#   AUTODREAM_TRIAGE_SUGGEST       0 switches the whole step off                    default on
#   AUTODREAM_TRIAGE_MIN           untriaged issues needed to suggest                default 3
#   AUTODREAM_TRIAGE_COOLDOWN_DAYS days before the same repo is suggested again      default 7
#   AUTODREAM_TRIAGE_GROW          growth that overrides the cooldown                default 3
#   AUTODREAM_TRIAGE_LIMIT         open issues read per repo; at the limit the
#                                  counts are shown as N+                            default 200
#   AUTODREAM_TRIAGE_CALL_SEC      timeout for one gh call                           default 30
#   AUTODREAM_TRIAGE_STATE         cooldown record                                   default ~/.claude/autodream/triage-suggested.tsv
set -uo pipefail

_pp="$(dirname "${BASH_SOURCE[0]}")/portable.sh"
# Installed copies are symlinks: a merge updates them before install.sh links a new helper.
[ -r "$_pp" ] || _pp="$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/portable.sh"
# shellcheck source=/dev/null
. "$_pp"

OUT=${1:-}
[ -n "$OUT" ] || { echo "usage: triage-candidates.sh <out-dir>   (session rows on stdin)" >&2; exit 2; }

if ! mkdir -p "$OUT" 2>/dev/null || [ ! -w "$OUT" ]; then echo "triage: findings dir unusable"; exit 0; fi
# A rerun of the same night must never leave the earlier run's list for L2 to copy, whatever
# happens below, so the artifacts go before the first early exit.
{ rm -f "$OUT/triage-candidates.md" "$OUT/triage-candidates.tsv"; } 2>/dev/null
if [ "${AUTODREAM_TRIAGE_SUGGEST:-1}" = 0 ]; then echo "triage: disabled"; exit 0; fi

MIN=${AUTODREAM_TRIAGE_MIN:-3}
COOLDOWN=${AUTODREAM_TRIAGE_COOLDOWN_DAYS:-7}
GROW=${AUTODREAM_TRIAGE_GROW:-3}
LIMIT=${AUTODREAM_TRIAGE_LIMIT:-200}
CALL_SEC=${AUTODREAM_TRIAGE_CALL_SEC:-30}
for _v in MIN COOLDOWN GROW LIMIT CALL_SEC; do
  _p_is_int "${!_v}" || { echo "triage: $_v must be a whole number"; exit 0; }
done
STATE=${AUTODREAM_TRIAGE_STATE:-${AUTODREAM_DIR:-$HOME/.claude/autodream}/triage-suggested.tsv}

# A gh call that waits for a login prompt would stall the nightly run.
export GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1

TSV="$OUT/triage-candidates.tsv"
MD="$OUT/triage-candidates.md"
# The findings dir is named for the report date; anything else falls back to today.
DATE=$(basename "$OUT")
_p_is_date "$DATE" || DATE=$(date +%Y-%m-%d)
: > "$TSV" 2>/dev/null || { echo "triage: findings dir unusable"; exit 0; }

# tsvrow STATUS SLUG REPO UNTRIAGED OPEN OLDEST DETAIL - a tab or newline in a field becomes a space.
tsvrow() {
  local f out="" sep=""
  for f in "$@"; do f=${f//$'\t'/ }; f=${f//$'\n'/ }; out="$out$sep$f"; sep=$'\t'; done
  printf '%s\n' "$out" >> "$TSV"
}

N_CAND=0; N_SKIP=0; N_BELOW=0; N_COOL=0; N_CHECKED=0
CAND_LINES=""
UNSAVED=""

# The last column of every stdin row, in order, once each. "?" and empty mean no usable cwd.
CWDS=""
while IFS= read -r line || [ -n "$line" ]; do
  c=${line##*$'\t'}
  case $c in ''|'?') continue ;; esac
  case $'\n'"$CWDS"$'\n' in *$'\n'"$c"$'\n'*) continue ;; esac
  CWDS="$CWDS$c"$'\n'
done

finish() { # finish SUMMARY-SUFFIX
  printf 'triage: candidates=%s checked=%s below=%s cooldown=%s skipped=%s%s\n' \
    "$N_CAND" "$N_CHECKED" "$N_BELOW" "$N_COOL" "$N_SKIP" "${1:+ $1}"
  exit 0
}

if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! tmo "$CALL_SEC" gh auth status >/dev/null 2>&1; then
  tsvrow skipped - - "" "" "" gh-unavailable
  printf '# triage-candidates: 0 (gh unavailable)\n\nThe runner could not use gh (missing, logged out, or jq missing), so no repo was checked.\n' > "$MD" 2>/dev/null
  N_SKIP=1
  finish gh-unavailable
fi

NOW=$(date +%s)
# The cooldown counts from the report date, so a late rerun of an old night judges it as that night did.
DATE_EPOCH=$(pdate_epoch "$DATE") || DATE_EPOCH=$NOW
SEEN_SLUGS=""

# last_suggestion SLUG -> "DATE<TAB>COUNT" of its most recent state row, empty when none
last_suggestion() {
  [ -r "$STATE" ] || return 0
  # The latest valid row for the slug (any case): a garbage row must not hide a good one.
  awk -F'\t' -v s="$1" '
    BEGIN { s = tolower(s) }
    tolower($1) == s && $2 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && $3 ~ /^[0-9][0-9]*$/ && $2 >= d { d = $2; c = $3 }
    END { if (d != "") printf "%s\t%s", d, c }' "$STATE" 2>/dev/null
}

# held_back SLUG UNTRIAGED -> 0 when the cooldown applies
held_back() {
  local last d c ep days
  last=$(last_suggestion "$1"); [ -n "$last" ] || return 1
  d=${last%%$'\t'*}; c=${last#*$'\t'}
  _p_is_int "$c" || return 1
  [ "$d" != "$DATE" ] || return 1                       # a retried night
  ep=$(pdate_epoch "$d") || return 1
  days=$(( (DATE_EPOCH - ep) / 86400 ))
  # A negative gap is a retry of an older night or a skewed clock: no cooldown applies.
  [ "$days" -lt 0 ] && return 1
  [ "$days" -ge "$COOLDOWN" ] && return 1
  [ "$2" -ge $((c + GROW)) ] && return 1                # the pile grew
  return 0
}

record_suggestion() { # SLUG UNTRIAGED - appends unless the last row already says the same
  local last
  last=$(last_suggestion "$1")
  [ "$last" = "$DATE"$'\t'"$2" ] && return 0
  mkdir -p "$(dirname "$STATE")" 2>/dev/null
  printf '%s\t%s\t%s\n' "$1" "$DATE" "$2" >> "$STATE" 2>/dev/null
}

# Reads one repo's issues. Sets I_TOTAL I_UNTRIAGED I_OLDEST (created date of the oldest
# untriaged issue). Returns 1 when gh or the JSON failed, with I_ERR set.
read_issues() {
  local slug=$1 errf json
  errf=$(mktemp "${TMPDIR:-/tmp}/triage-err.XXXXXX") || { I_ERR="no temp file"; return 1; }
  json=$(tmo "$CALL_SEC" gh issue list -R "$slug" --state open --limit "$LIMIT" --json number,labels,createdAt 2>"$errf" </dev/null)
  local rc=$?
  I_ERR=$(head -c 300 "$errf" 2>/dev/null | tr '\n\t' '  ')
  { rm -f "$errf"; } 2>/dev/null
  [ "$rc" -eq 0 ] || return 1
  local fields
  fields=$(printf '%s' "$json" | jq -r '
    ["needs-info","ready-for-agent","ready-for-human","wontfix","needs-triage"] as $S
    | map(. + {n: ((.labels // []) | map(.name))})
    | map(. + {st: (.n | map(select(. as $x | $S | index($x))) | length)})
    | map(. + {u: ((.n | index("needs-triage") != null) or .st == 0)})
    | [ length,
        (map(select(.u)) | length),
        ([.[] | select(.u) | .createdAt] | min // "") ]
    | @tsv' 2>/dev/null) || { I_ERR="unreadable JSON"; return 1; }
  [ -n "$fields" ] || { I_ERR="unreadable JSON"; return 1; }
  IFS=$'\t' read -r I_TOTAL I_UNTRIAGED I_OLDEST <<< "$fields"
  if _p_is_int "$I_TOTAL" && _p_is_int "$I_UNTRIAGED"; then return 0; fi
  I_ERR="unreadable JSON"; return 1
}

# can_triage SLUG -> 0 when the viewer may label issues there and the repo is not archived.
# Sets A_WHY to not-maintainer, archived or gh-failed: <error> otherwise. Only repos that already
# cleared the threshold get here, so the extra call is spent where it matters.
can_triage() {
  local out rc perm arch
  out=$(tmo "$CALL_SEC" gh repo view "$1" --json viewerPermission,isArchived --jq '[.viewerPermission, (.isArchived|tostring)] | @tsv' 2>&1 </dev/null); rc=$?
  if [ "$rc" -ne 0 ]; then A_WHY="gh-failed: $(printf '%s' "$out" | head -c 300 | tr '\n\t' '  ')"; return 1; fi
  perm=${out%%$'\t'*}; arch=${out#*$'\t'}
  case $perm in ADMIN|MAINTAIN|WRITE|TRIAGE) ;; *) A_WHY=not-maintainer; return 1 ;; esac
  if [ "$arch" = true ]; then A_WHY=archived; return 1; fi
  return 0
}

age_days() { # ISO timestamp -> whole days since, empty when it does not parse
  local ts=${1:-} ep
  [ -n "$ts" ] || return 0
  ep=$(pdate_epoch "$(printf '%s' "$ts" | sed 's/T/ /; s/Z$//')" 2>/dev/null) || return 0
  [ -n "$ep" ] && printf '%s' $(( (NOW - ep) / 86400 ))
}

while IFS= read -r cwd; do
  [ -n "$cwd" ] || continue
  if [ ! -d "$cwd" ]; then tsvrow skipped - "$cwd" "" "" "" cwd-gone; N_SKIP=$((N_SKIP + 1)); continue; fi
  common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
  if [ -z "$common" ] || [ "$(basename "$common")" != ".git" ]; then
    tsvrow skipped - "$cwd" "" "" "" not-git; N_SKIP=$((N_SKIP + 1)); continue
  fi
  repo=$(dirname "$common")
  slug=$(repo_slug "$repo")
  if [ -z "$slug" ]; then tsvrow skipped - "$repo" "" "" "" non-github; N_SKIP=$((N_SKIP + 1)); continue; fi
  key=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
  case $'\n'"$SEEN_SLUGS"$'\n' in *$'\n'"$key"$'\n'*) continue ;; esac
  SEEN_SLUGS="$SEEN_SLUGS$key"$'\n'
  N_CHECKED=$((N_CHECKED + 1))

  if ! read_issues "$slug"; then
    case $I_ERR in
      *"disabled issues"*) tsvrow skipped "$slug" "$repo" "" "" "" issues-disabled ;;
      *) tsvrow skipped "$slug" "$repo" "" "" "" "gh-failed: ${I_ERR:-no output}" ;;
    esac
    N_SKIP=$((N_SKIP + 1)); continue
  fi
  if [ "$I_TOTAL" -eq 0 ]; then tsvrow skipped "$slug" "$repo" 0 0 "" none-open; N_SKIP=$((N_SKIP + 1)); continue; fi

  u=$I_UNTRIAGED; t=$I_TOTAL; mark=""
  if [ "$I_TOTAL" -ge "$LIMIT" ]; then
    mark="+"; t=$LIMIT; [ "$u" -le "$LIMIT" ] || u=$LIMIT
  fi
  age=$(age_days "$I_OLDEST")
  if [ "$I_UNTRIAGED" -lt "$MIN" ]; then
    tsvrow below "$slug" "$repo" "$u$mark" "$t$mark" "$age" "fewer than $MIN untriaged"; N_BELOW=$((N_BELOW + 1)); continue
  fi
  if ! can_triage "$slug"; then
    tsvrow skipped "$slug" "$repo" "$u$mark" "$t$mark" "$age" "$A_WHY"; N_SKIP=$((N_SKIP + 1)); continue
  fi
  if held_back "$slug" "$I_UNTRIAGED"; then
    tsvrow cooldown "$slug" "$repo" "$u$mark" "$t$mark" "$age" "suggested on $(last_suggestion "$slug" | cut -f1)"; N_COOL=$((N_COOL + 1)); continue
  fi
  tsvrow candidate "$slug" "$repo" "$u$mark" "$t$mark" "$age" ""
  N_CAND=$((N_CAND + 1))
  CAND_LINES="$CAND_LINES$(printf '| `%s` | %s | %s | %s | `%s` |' "$slug" "$u$mark" "$t$mark" "${age:+$age days}" "${repo//|/\\|}")"$'\n'
  record_suggestion "$slug" "$I_UNTRIAGED" || UNSAVED=1
done <<< "$CWDS"

{
  printf '# triage-candidates: %s\n\n' "$N_CAND"
  if [ "$N_CAND" -eq 0 ]; then
    printf 'No repo touched in this window needs triage.\n'
  else
    printf 'Repos a session touched with open issues no one has triaged. To work through one, start a session in the checkout and run `/triage`.\n\n'
    printf '| repo | untriaged | open | oldest untriaged | checkout |\n|---|---|---|---|---|\n%s' "$CAND_LINES"
  fi
  if [ -n "$UNSAVED" ]; then
    printf '\n> Note: the cooldown record could not be saved (%s), so these repos will be suggested again tomorrow.\n' "$STATE"
  fi
} > "$MD" 2>/dev/null

finish
