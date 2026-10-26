#!/usr/bin/env bash
# prune-worktrees.sh - remove git worktrees and branches whose work has landed.
#
# Sessions leave worktrees under <repo>/.claude/worktrees/ and <repo>/.worktrees/, and
# branches on the remote, long after the PR merged. This runs in the nightly pipeline and
# clears the ones that are provably finished. It deletes branches on a remote, so the bar is
# proof, not a guess: when any check is unclear the item stays and the report says why. A
# wrong keep costs one more night. A wrong delete cannot be undone.
#
# WHAT COUNTS AS FINISHED
#
# A branch is finished when one of these holds, and no keep rule below applies:
#   * a PR from this repo into the default branch is MERGED and the PR's head commit is the
#     branch tip (a squash merge counts, and local commits made after the merge do not);
#   * a PR from this repo is CLOSED unmerged at least AUTODREAM_PRUNE_CLOSED_DAYS ago, its
#     head commit is the branch tip, and the tip is on the remote (GitHub keeps
#     refs/pull/N/head, so that commit stays recoverable);
#   * the repo has no remote at all and the tip is an ancestor of the default branch, is not
#     the default branch's own tip, and the branch has more than its creation in its reflog.
# A repo whose origin is not on GitHub is never pruned: there is no proof source for it.
#
# WHAT IS KEPT, WHATEVER ELSE IS TRUE
#
#   open-pr          a PR for the branch is open
#   base-of-open-pr  an open PR targets the branch
#   base-of-pr       a PR, open or not, has ever targeted the branch (a long-lived branch)
#   dirty            uncommitted or untracked files in the worktree
#   recent           a file in the worktree or its gitdir changed inside the grace window
#                    (default 12 hours), which also covers a session still running there
#   rebase-or-bisect a rebase or bisect is in progress in the worktree
#   locked           `git worktree lock`
#   protected        main, master, develop, dev, development, trunk, staging, stage,
#                    production, prod, next, canary, gh-pages, release*, v<digit>*, the
#                    default branch, and AUTODREAM_PRUNE_PROTECT (colon-separated globs)
#   submodules       the worktree has a .gitmodules
#   ignored-files    ignored files other than build output, and no Trash to put them in
#   trash-failed     `trash` exists and failed, so the directory is not deleted for good
#   unmanaged-path   a worktree outside .claude/worktrees and .worktrees
#   gh-unavailable   gh is missing, logged out, or failed for the repo, or the open-PR list
#                    hit its limit, so there is no proof
#   time-budget      AUTODREAM_PRUNE_BUDGET_SEC ran out
#   cap              AUTODREAM_PRUNE_MAX removals already happened this run
#
# THE LEDGER: NO REMOVAL WITHOUT A RECORD
#
# Every real run appends to one file that is never rewritten, AUTODREAM_PRUNE_LEDGER (default
# ~/.claude/autodream/prune-ledger.tsv). Per removal it writes an `intent` line BEFORE it touches
# anything, then one line per step, then `complete`. A run opens with `run-start` and closes with
# `run-end`. Columns: time (UTC), run id, event, repo, owner/repo, branch, local tip, remote tip
# before the delete, worktree path, detail (the proof: PR URL, state, head, base), recover.
# The `recover` column holds the exact commands that put the branch back, local and remote:
#     git -C <repo> branch <branch> <tip> ; git -C <repo> push origin <tip>:refs/heads/<branch>
# The commit objects stay in the repo until git gc, so the commands work after a deletion. A
# worktree directory is in the Trash under its own name. If the ledger cannot be written, nothing
# is removed ("no log, no delete"). A dry run writes nothing to it.
#
# NO CALL CAN HANG THE NIGHT
#
# Every network call and `trash` runs under a timeout (AUTODREAM_PRUNE_CALL_SEC), through
# timeout, gtimeout, or a built-in watchdog when neither exists. A hard cap covers the rest:
# AUTODREAM_PRUNE_BUDGET_SEC plus AUTODREAM_PRUNE_KILL_SLACK seconds after the start, the
# script stops its children, writes the report and exits 0.
#
# The remote branch is deleted by a push that names the proven commit as the lease
# (`--force-with-lease=refs/heads/<b>:<tip>`), so a push that landed after the fetch makes
# GitHub refuse the delete. No branch name is ever put in a URL.
#
# The worktree directory goes to the Trash (it may hold ignored files such as .env).
#
# Usage:
#   prune-worktrees.sh [--dry-run] <out-dir>
#     writes <out-dir>/worktree-prune.tsv (action, repo, branch, path, reason) and
#     worktree-prune.md, and prints one summary line. Always exits 0 once it has an
#     out-dir, because a pruning problem must not cost the night's report.
#
# Config (env; run.sh sources ~/.claude/autodream/config with `set -a` first):
#   AUTODREAM_PRUNE_ROOTS        colon-separated directories to search for repos (depth 3).
#                                Unset or empty: do nothing. This is the opt-in.
#   AUTODREAM_PRUNE_GRACE_MIN    recent-edit window in minutes                  default 720
#   AUTODREAM_PRUNE_MAX          most removals in one run                       default 25
#   AUTODREAM_PRUNE_CLOSED_DAYS  how long a closed PR must have been closed     default 7
#   AUTODREAM_PRUNE_BUDGET_SEC   wall-clock budget for the whole run            default 1200
#   AUTODREAM_PRUNE_KILL_SLACK   seconds after the budget before a hard stop     default 120
#   AUTODREAM_PRUNE_CALL_SEC     timeout for one network call or trash           default 60
#   AUTODREAM_PRUNE_PROTECT      extra protected branch globs, colon-separated  default none
#   AUTODREAM_PRUNE_OPEN_LIMIT   open PRs read per repo; at the limit the repo
#                                is kept whole                                  default 200
#   AUTODREAM_PRUNE_TRASH        0 to delete with git instead of trash          default 1
#   AUTODREAM_PRUNE_LEDGER       append-only record of every removal           default ~/.claude/autodream/prune-ledger.tsv
#   AUTODREAM_PRUNE_DRY_RUN      1 is the same as --dry-run
set -uo pipefail

_pp="$(dirname "${BASH_SOURCE[0]}")/portable.sh"
# Installed copies are symlinks: a merge updates them before install.sh links a new helper.
[ -r "$_pp" ] || _pp="$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/portable.sh"
# shellcheck source=/dev/null
. "$_pp"

DRY=${AUTODREAM_PRUNE_DRY_RUN:-0}
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi
OUT=${1:-}
[ -n "$OUT" ] || { echo "usage: prune-worktrees.sh [--dry-run] <out-dir>" >&2; exit 2; }
mkdir -p "$OUT" || exit 0

ROOTS=${AUTODREAM_PRUNE_ROOTS:-}
GRACE=${AUTODREAM_PRUNE_GRACE_MIN:-720}
MAXN=${AUTODREAM_PRUNE_MAX:-25}
CLOSED_DAYS=${AUTODREAM_PRUNE_CLOSED_DAYS:-7}
BUDGET=${AUTODREAM_PRUNE_BUDGET_SEC:-1200}
OPEN_LIMIT=${AUTODREAM_PRUNE_OPEN_LIMIT:-200}
CALL_SEC=${AUTODREAM_PRUNE_CALL_SEC:-60}
KILL_SLACK=${AUTODREAM_PRUNE_KILL_SLACK:-120}
for _v in GRACE MAXN CLOSED_DAYS BUDGET OPEN_LIMIT CALL_SEC KILL_SLACK; do _p_is_int "${!_v}" || { echo "prune: $_v must be a whole number" >&2; exit 0; }; done

# A network call that waits for a password or a dead host would stall the nightly run.
# Without a tty (launchd) ssh and git cannot prompt either. Slow transfers abort on their own.
export GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1
export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=$CALL_SEC

TSV="$OUT/worktree-prune.tsv"
MD="$OUT/worktree-prune.md"
LEDGER=${AUTODREAM_PRUNE_LEDGER:-${AUTODREAM_DIR:-$HOME/.claude/autodream}/prune-ledger.tsv}
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
LEDGER_OK=1
: > "$TSV"
N_REMOVED=0; N_KEPT=0; N_SKIPPED=0
CUR_REPO=""; CUR_SLUG=""; CUR_BR=""; CUR_TIP=""; CUR_PATH=""; LBAD=""
SECONDS=0
NOW=$(date +%s)
CUTOFF=$(TZ=UTC pdate_fmt_epoch $((NOW - CLOSED_DAYS * 86400)) +%Y-%m-%dT%H:%M:%SZ)

PROTECT_DEFAULT="main:master:develop:dev:development:trunk:staging:stage:production:prod:next:canary:gh-pages:release:release-*:release/*:v[0-9]*"
IFS=: read -r -a PROTECT <<< "$PROTECT_DEFAULT:${AUTODREAM_PRUNE_PROTECT:-}"

budget_ok() { [ "$SECONDS" -lt "$BUDGET" ]; }

# ledger EVENT REPO SLUG BRANCH TIP REMOTE_TIP WORKTREE DETAIL RECOVER - one append, a failure returns 1.
# A tab or newline inside a field would shift the columns, so both become spaces.
ledger() {
  [ "$DRY" = 1 ] && return 0
  local f out="" sep=""
  for f in "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUN_ID" "$@"; do
    f=${f//$'\t'/ }; f=${f//$'\n'/ }
    out="$out$sep$f"; sep=$'\t'
  done
  printf '%s\n' "$out" >> "$LEDGER" 2>/dev/null
}

# shq STRING -> STRING in single quotes. Unlike printf %q this never prints $'..', which fish cannot read.
shq() { printf "'%s'" "$(printf '%s' "$1" | LC_ALL=C sed "s/'/'\\\\''/g")"; }

# recover_cmds REPO BRANCH TIP REMOTE_TIP -> the commands that restore the local branch, and the
# remote branch when it existed. They work in bash, zsh and fish.
recover_cmds() {
  local r b; r=$(shq "$1"); b=$(shq "$2")
  printf 'git -C %s branch %s %s' "$r" "$b" "$3"
  [ -z "$4" ] || printf ' ; git -C %s push origin %s:refs/heads/%s' "$r" "$3" "$b"
}

# lstep ... -> ledger, remembering a failed append so the report can say the record is incomplete
lstep() { ledger "$@" || LBAD=1; }

if [ "$DRY" != 1 ]; then
  mkdir -p "$(dirname "$LEDGER")" 2>/dev/null
  ledger run-start "" "" "" "" "" "" "script=$0 dry=0 max=$MAXN grace_min=$GRACE call_sec=$CALL_SEC budget_sec=$BUDGET host=$(hostname -s 2>/dev/null)" "" || LEDGER_OK=0
fi

row() { # action repo branch path reason
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$TSV"
  case "$1" in
    removed|would-remove) N_REMOVED=$((N_REMOVED + 1)) ;;
    kept) N_KEPT=$((N_KEPT + 1)) ;;
    *) N_SKIPPED=$((N_SKIPPED + 1)) ;;
  esac
}

finish() {
  [ -z "${FINISHED:-}" ] || return 0
  FINISHED=1
  kill "${WD:-}" 2>/dev/null
  {
  printf '# Worktree prune %s%s\n\n' "$(date +%F)" "$([ "$DRY" = 1 ] && echo ' (dry run)')"
  printf 'removed: %s, kept: %s, skipped: %s\n' "$N_REMOVED" "$N_KEPT" "$N_SKIPPED"
  for a in removed would-remove kept skipped; do
    grep -q "^$a	" "$TSV" || continue
    printf '\n## %s\n\n' "$a"
    awk -F'\t' -v a="$a" '$1 == a { printf "- %s `%s`: %s\n", ($4 != "" ? $4 : $2), $3, $5 }' "$TSV"
  done
  } > "$MD"
  [ "$LEDGER_OK" = 1 ] && ledger run-end "" "" "" "" "" "" "removed=$N_REMOVED kept=$N_KEPT skipped=$N_SKIPPED" ""
  printf 'prune: removed=%s kept=%s skipped=%s%s\n' "$N_REMOVED" "$N_KEPT" "$N_SKIPPED" "$([ "$DRY" = 1 ] && echo ' (dry run)')"
}

# The whole run has a hard cap no hung child can outlast: the budget plus a slack. The watchdog
# sends TERM to this shell, the trap kills the children, writes the report and exits 0.
on_term() {
  pkill -P $$ 2>/dev/null
  if [ -n "$CUR_REPO" ] && [ "$LEDGER_OK" = 1 ]; then
    ledger interrupted "$CUR_REPO" "$CUR_SLUG" "$CUR_BR" "$CUR_TIP" "" "$CUR_PATH" "the watchdog stopped the run after the intent and before complete: check whether the worktree, the remote branch and the local branch are gone" ""
  fi
  row skipped "" "" "" "watchdog: the run outlasted its time cap"
  finish
  exit 0
}
trap on_term TERM
# bash runs a trap only after its foreground child exits, so the children are killed right after the TERM.
( sleep $((BUDGET + KILL_SLACK)); kill -TERM $$; pkill -P $$ ) >/dev/null 2>&1 &
WD=$!
trap 'kill "$WD" 2>/dev/null' EXIT

GH_OK=0
if command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && tmo "$CALL_SEC" gh auth status >/dev/null 2>&1; then GH_OK=1; fi

USE_TRASH=0
if [ "${AUTODREAM_PRUNE_TRASH:-1}" = 1 ] && command -v trash >/dev/null 2>&1; then USE_TRASH=1; fi


# ---- per-repo facts ------------------------------------------------------------------------

default_facts() { # sets DEF_NAME DEF_REF DEF_TIP for repo $1; DEF_NAME is empty when unknown
  local repo=$1 b
  DEF_NAME=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || DEF_NAME=""
  # Ask the remote every night: a renamed default branch leaves origin/HEAD pointing at the old name.
  if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    tmo "$CALL_SEC" git -C "$repo" remote set-head origin -a >/dev/null 2>&1
    DEF_NAME=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || DEF_NAME=""
  fi
  DEF_NAME=${DEF_NAME#origin/}
  if [ -z "$DEF_NAME" ] && [ -z "$(git -C "$repo" remote 2>/dev/null)" ]; then
    for b in main master; do
      if git -C "$repo" show-ref --verify -q "refs/heads/$b"; then DEF_NAME=$b; break; fi
    done
    [ -n "$DEF_NAME" ] || DEF_NAME=$(git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null) || DEF_NAME=""
  fi
  DEF_REF=""; DEF_TIP=""
  [ -n "$DEF_NAME" ] || return 0
  if git -C "$repo" show-ref --verify -q "refs/remotes/origin/$DEF_NAME"; then DEF_REF="refs/remotes/origin/$DEF_NAME"
  else DEF_REF="refs/heads/$DEF_NAME"; fi
  DEF_TIP=$(git -C "$repo" rev-parse -q --verify "$DEF_REF" 2>/dev/null) || DEF_TIP=""
}

is_protected() {
  local pat
  [ "$1" = "$DEF_NAME" ] && return 0
  for pat in "${PROTECT[@]}"; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254
    case "$1" in $pat) return 0 ;; esac
  done
  return 1
}

load_open_prs() { # slug -> OPEN_HEADS OPEN_BASES REPO_GH_OK
  local json
  REPO_GH_OK=0; OPEN_HEADS=""; OPEN_BASES=""
  { [ "$GH_OK" = 1 ] && [ -n "$1" ]; } || return 0
  json=$(tmo "$CALL_SEC" gh pr list -R "$1" --state open --limit "$OPEN_LIMIT" --json headRefName,baseRefName 2>/dev/null) || return 0
  [ "$(printf '%s' "$json" | jq -r 'if type == "array" then length else -1 end' 2>/dev/null)" -ge 0 ] 2>/dev/null || return 0
  [ "$(printf '%s' "$json" | jq length)" -lt "$OPEN_LIMIT" ] || return 0
  OPEN_HEADS=$(printf '%s' "$json" | jq -r '.[].headRefName')
  OPEN_BASES=$(printf '%s' "$json" | jq -r '.[].baseRefName')
  REPO_GH_OK=1
}

in_list() { printf '%s\n' "$2" | grep -qxF -- "$1"; }

# ---- the proof -------------------------------------------------------------------------------

# judge REPO SLUG BRANCH TIP -> VERDICT=finished|keep, WHY
judge() {
  local repo=$1 slug=$2 br=$3 tip=$4 json rsha closed based
  VERDICT=keep; WHY="no proof the work landed"; PROOF=""
  if [ -z "$slug" ]; then
    if [ -n "$(git -C "$repo" remote 2>/dev/null)" ]; then WHY="non-github-remote: no proof source"; return 0; fi
    if [ -n "$DEF_TIP" ] && [ "$tip" != "$DEF_TIP" ] \
       && git -C "$repo" merge-base --is-ancestor "$tip" "$DEF_REF" 2>/dev/null \
       && [ "$(git -C "$repo" reflog show --format=%H "refs/heads/$br" 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ]; then
      VERDICT=finished; WHY="merged into $DEF_NAME (no remote)"
      PROOF="tip $tip is an ancestor of $DEF_REF $DEF_TIP; the repo has no remote"
    fi
    return 0
  fi
  [ "$REPO_GH_OK" = 1 ] || { WHY="gh-unavailable"; return 0; }
  if in_list "$br" "$OPEN_HEADS"; then WHY="open-pr"; return 0; fi
  if in_list "$br" "$OPEN_BASES"; then WHY="base-of-open-pr"; return 0; fi
  json=$(tmo "$CALL_SEC" gh pr list -R "$slug" --head "$br" --state all --limit 20 \
         --json number,state,closedAt,headRefOid,baseRefName,isCrossRepository,url 2>/dev/null) \
    && printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1 || { WHY="gh-unavailable: PR lookup failed"; return 0; }
  if [ "$(printf '%s' "$json" | jq 'any(.[]; .state == "OPEN")')" = true ]; then WHY="open-pr"; return 0; fi
  if [ "$(printf '%s' "$json" | jq --arg t "$tip" --arg d "$DEF_NAME" \
        'any(.[]; .state == "MERGED" and .headRefOid == $t and .baseRefName == $d and .isCrossRepository == false)')" = true ]; then
    VERDICT=finished; WHY="PR merged into $DEF_NAME at this tip"
    PROOF=$(printf '%s' "$json" | jq -r --arg t "$tip" '[.[] | select(.state == "MERGED" and .headRefOid == $t)][0] | "PR \(.url) MERGED head=\(.headRefOid) base=\(.baseRefName)"')
  fi
  rsha=$(git -C "$repo" rev-parse -q --verify "refs/remotes/origin/$br" 2>/dev/null) || rsha=""
  closed=$(printf '%s' "$json" | jq -r --arg t "$tip" \
        '[.[] | select(.state == "CLOSED" and .headRefOid == $t and .isCrossRepository == false) | .closedAt] | max // empty')
  if [ "$VERDICT" != finished ] && [ -n "$closed" ] && [ "$rsha" = "$tip" ] && [[ "$closed" < "$CUTOFF" ]]; then
    VERDICT=finished; WHY="PR closed unmerged on $closed at this tip, branch fully on the remote"
    PROOF=$(printf '%s' "$json" | jq -r --arg t "$tip" '[.[] | select(.state == "CLOSED" and .headRefOid == $t)][0] | "PR \(.url) CLOSED head=\(.headRefOid) base=\(.baseRefName) closedAt=\(.closedAt); remote tip equals the local tip"')
  fi
  [ "$VERDICT" = finished ] || return 0
  # Either proof: a branch that other PRs have targeted is a long-lived branch, and deleting it
  # on the remote would close those PRs. An error in the lookup keeps the branch.
  based=$(tmo "$CALL_SEC" gh pr list -R "$slug" --base "$br" --state all --limit 1 --json number 2>/dev/null) \
    && [ "$(printf '%s' "$based" | jq length 2>/dev/null)" = 0 ] || { VERDICT=keep; WHY="base-of-pr: a PR has targeted this branch"; }
  return 0
}

# ---- removal ---------------------------------------------------------------------------------

delete_remote() { # repo slug branch tip -> REMOTE_NOTE
  local repo=$1 slug=$2 br=$3 tip=$4 rsha
  REMOTE_NOTE=""; REMOTE_EVENT="remote-none"; REMOTE_DETAIL="no GitHub remote or no remote branch"
  [ -n "$slug" ] || return 0
  rsha=$(git -C "$repo" rev-parse -q --verify "refs/remotes/origin/$br" 2>/dev/null) || rsha=""
  [ -n "$rsha" ] || return 0
  if [ "$rsha" != "$tip" ]; then
    REMOTE_NOTE="; remote kept: moved since the proof"; REMOTE_EVENT="remote-kept"; REMOTE_DETAIL="remote tip $rsha differs from the proven tip $tip"
    return 0
  fi
  if tmo $((CALL_SEC * 2)) git -C "$repo" push --no-verify --force-with-lease="refs/heads/$br:$tip" origin ":refs/heads/$br" >/dev/null 2>&1; then
    REMOTE_NOTE="; remote deleted"; REMOTE_EVENT="remote-deleted"; REMOTE_DETAIL="deleted refs/heads/$br on origin at $tip"
    git -C "$repo" update-ref -d "refs/remotes/origin/$br" 2>/dev/null
  else
    REMOTE_NOTE="; remote kept: delete refused or failed"; REMOTE_EVENT="remote-kept"; REMOTE_DETAIL="push refused or failed; remote branch is still at $rsha"
  fi
}

drop_worktree() { # repo path -> 0 when the directory is gone and git forgot it
  local repo=$1 path=$2 err
  DROP_ERR=""
  if [ "$USE_TRASH" = 1 ]; then
    if tmo "$CALL_SEC" trash "$path" >/dev/null 2>&1 && [ ! -e "$path" ]; then prune_stale_worktrees "$repo"; return 0; fi
    DROP_ERR="trash-failed"; return 1
  fi
  if err=$(git -C "$repo" worktree remove "$path" 2>&1); then return 0; fi
  DROP_ERR=${err%%$'\n'*}
  return 1
}

# remove_item REPO SLUG BRANCH TIP PATH WHY - PATH or BRANCH may be empty. PROOF holds the evidence.
remove_item() {
  local repo=$1 slug=$2 br=$3 tip=$4 path=$5 why=$6 note="" rsha="" rec="" detail pin dd
  LBAD=""
  if ! budget_ok; then row skipped "$repo" "$br" "$path" "time-budget"; return 0; fi
  if [ "$N_REMOVED" -ge "$MAXN" ]; then row kept "$repo" "$br" "$path" "cap: $MAXN removals per run reached"; return 0; fi
  if [ "$DRY" = 1 ]; then row would-remove "$repo" "$br" "$path" "$why"; return 0; fi
  if [ "$LEDGER_OK" != 1 ]; then row kept "$repo" "$br" "$path" "ledger-unwritable: no log, no delete"; return 0; fi
  [ -z "$br" ] || rsha=$(git -C "$repo" rev-parse -q --verify "refs/remotes/origin/$br" 2>/dev/null) || rsha=""
  if [ -n "$br" ]; then rec=$(recover_cmds "$repo" "$br" "$tip" "$rsha"); pin="refs/prune-ledger/$RUN_ID/$br"
  else rec="detached worktree: no branch; the commit is $tip"; pin="refs/prune-ledger/$RUN_ID/detached-$(basename "$path")"; fi
  # Pin first. After the branch and the worktree are gone, nothing else keeps a squash-merged tip
  # reachable, and git gc would prune it and break the recover commands. The pin is never removed.
  # The empty old value makes the pin create-only: an existing pin of the same name is never overwritten.
  if ! git -C "$repo" update-ref "$pin" "$tip" "" 2>/dev/null; then
    ledger pin-failed "$repo" "$slug" "$br" "$tip" "$rsha" "$path" "could not create $pin; nothing was changed" ""
    row kept "$repo" "$br" "$path" "pin-failed: no safe undo, no delete"; return 0
  fi
  # Write-ahead: the intent is on disk before the first change.
  if ! ledger intent "$repo" "$slug" "$br" "$tip" "$rsha" "$path" "$why | proof: $PROOF | commit held by $pin" "$rec"; then
    git -C "$repo" update-ref -d "$pin" 2>/dev/null   # nothing was changed, so the pin is not needed
    row kept "$repo" "$br" "$path" "ledger-write-failed: no log, no delete"; return 0
  fi
  CUR_REPO=$repo; CUR_SLUG=$slug; CUR_BR=$br; CUR_TIP=$tip; CUR_PATH=$path
  if [ -n "$path" ]; then
    if drop_worktree "$repo" "$path"; then
      if [ "$USE_TRASH" = 1 ]; then detail="moved to the Trash: look for '$(basename "$path")' in ~/.Trash"
      else detail="deleted with git worktree remove (a clean tree; tracked files come back from $tip)"; fi
      lstep worktree-removed "$repo" "$slug" "$br" "$tip" "$rsha" "$path" "$detail" ""
    else
      if [ -e "$path" ]; then dd="the directory is still at the path"; else dd="the directory is NOT at the path: look in ~/.Trash"; fi
      lstep worktree-failed "$repo" "$slug" "$br" "$tip" "$rsha" "$path" "${DROP_ERR:-remove-failed}; $dd" ""
      CUR_REPO=""
      row kept "$repo" "$br" "$path" "${DROP_ERR:-remove-failed}"; return 0
    fi
  fi
  if [ -n "$br" ]; then
    delete_remote "$repo" "$slug" "$br" "$tip"
    lstep "$REMOTE_EVENT" "$repo" "$slug" "$br" "$tip" "$rsha" "$path" "$REMOTE_DETAIL" ""
    if git -C "$repo" branch -D "$br" >/dev/null 2>&1; then
      lstep local-deleted "$repo" "$slug" "$br" "$tip" "$rsha" "$path" "deleted refs/heads/$br at $tip" ""
    else
      note="; local branch delete failed"
      lstep local-failed "$repo" "$slug" "$br" "$tip" "$rsha" "$path" "git branch -D failed; the local branch is still there" ""
    fi
    note="$note$REMOTE_NOTE"
  fi
  [ -z "$LBAD" ] || note="$note; ledger-incomplete: a step line could not be written, the intent line still holds the undo"
  lstep complete "$repo" "$slug" "$br" "$tip" "$rsha" "$path" "$why$note" ""
  CUR_REPO=""
  row removed "$repo" "$br" "$path" "$why$note"
}

# ---- the sweep -------------------------------------------------------------------------------

recent_edit() { # worktree path -> 0 when anything in it or its gitdir changed inside the window
  local path=$1 gd hit
  hit=$(find "$path" \( -path "$path/.git" -o -path "$path/node_modules" -o -path "$path/target" \) -prune -o -type f -mmin "-$GRACE" -print -quit 2>/dev/null)
  [ -n "$hit" ] && return 0
  gd=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null) || return 0
  hit=$(find "$gd" -type f -mmin "-$GRACE" -print -quit 2>/dev/null)
  [ -n "$hit" ]
}

rebase_branch() { # worktree path -> prints the branch being rebased, returns 0 when a rebase or bisect is running
  local gd head
  gd=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  if [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; then
    head=$(cat "$gd/rebase-merge/head-name" "$gd/rebase-apply/head-name" 2>/dev/null | head -1)
    printf '%s' "${head#refs/heads/}"; return 0
  fi
  if [ -e "$gd/BISECT_LOG" ]; then
    head=$(head -1 "$gd/BISECT_START" 2>/dev/null)
    printf '%s' "${head#refs/heads/}"; return 0
  fi
  return 1
}

ignored_beyond_build() { # worktree path -> 0 when it holds ignored files other than build output
  git -C "$1" status --porcelain --ignored 2>/dev/null | grep '^!!' \
    | grep -vE '^!! (node_modules|target|dist|build|\.next|__pycache__|\.venv)/$' | grep -q .
}

sweep_worktree() { # repo slug path head branch flags
  local repo=$1 slug=$2 path=$3 head=$4 br=${5#refs/heads/} flags=$6 st
  case "$path" in
    "$repo"/.claude/worktrees/*|"$repo"/.worktrees/*) ;;
    *) row skipped "$repo" "$br" "$path" "unmanaged-path"; return 0 ;;
  esac
  case "$flags" in *locked*) row kept "$repo" "$br" "$path" "locked"; return 0 ;; esac
  if [ -n "$br" ] && is_protected "$br"; then row kept "$repo" "$br" "$path" "protected"; return 0; fi
  if recent_edit "$path"; then row kept "$repo" "$br" "$path" "recent: edited within ${GRACE} minutes"; return 0; fi
  if rebase_branch "$path" >/dev/null; then row kept "$repo" "$br" "$path" "rebase-or-bisect in progress"; return 0; fi
  if [ -e "$path/.gitmodules" ]; then row kept "$repo" "$br" "$path" "submodules: their git data lives in the worktree gitdir"; return 0; fi
  st=$(git -C "$path" status --porcelain --untracked-files=all 2>&1) || { row kept "$repo" "$br" "$path" "status-failed"; return 0; }
  [ -z "$st" ] || { row kept "$repo" "$br" "$path" "dirty: uncommitted or untracked files"; return 0; }
  if [ "$USE_TRASH" != 1 ] && ignored_beyond_build "$path"; then
    row kept "$repo" "$br" "$path" "ignored-files: no Trash, git would delete them for good"; return 0
  fi
  if ! budget_ok; then row skipped "$repo" "$br" "$path" "time-budget"; return 0; fi
  if [ -z "$br" ]; then # detached HEAD
    if [ -n "$DEF_TIP" ] && [ "$head" != "$DEF_TIP" ] && git -C "$repo" merge-base --is-ancestor "$head" "$DEF_REF" 2>/dev/null; then
      PROOF="detached HEAD $head is an ancestor of $DEF_REF $DEF_TIP"
      remove_item "$repo" "$slug" "" "$head" "$path" "detached at a commit already in $DEF_NAME"
    else
      row kept "$repo" "(detached)" "$path" "no proof the work landed"
    fi
    return 0
  fi
  judge "$repo" "$slug" "$br" "$head"
  if [ "$VERDICT" = finished ]; then remove_item "$repo" "$slug" "$br" "$head" "$path" "$WHY"
  else row kept "$repo" "$br" "$path" "$WHY"; fi
}

sweep_branches() { # repo slug checked-out-branches
  local repo=$1 slug=$2 checked=$3 br tip ct list
  list=$(mktemp "${TMPDIR:-/tmp}/prune-br.XXXXXX") || return 0
  git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads > "$list"
  while IFS= read -r br; do
    [ -n "$br" ] || continue
    budget_ok || break
    in_list "$br" "$checked" && continue
    is_protected "$br" && continue
    tip=$(git -C "$repo" rev-parse -q --verify "refs/heads/$br" 2>/dev/null) || continue
    ct=$(git -C "$repo" log -1 --format=%ct "$tip" 2>/dev/null) || continue
    [ $((NOW - ct)) -ge $((GRACE * 60)) ] || continue
    judge "$repo" "$slug" "$br" "$tip"
    [ "$VERDICT" = finished ] && remove_item "$repo" "$slug" "$br" "$tip" "" "$WHY (no worktree)"
  done < "$list"
  rm -f "$list"
}

prune_stale_worktrees() { # repo - forget worktrees whose directory is gone, unless a volume looks unmounted
  local repo=$1 p any=0 bad=0 list
  list=$(git -C "$repo" worktree list --porcelain | awk '/^worktree /{p=substr($0,10)} /^prunable/{print p}')
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    any=1
    [ -d "$(dirname "$p")" ] || bad=1
  done <<< "$list"
  [ "$any" = 1 ] || return 0
  if [ "$bad" = 1 ]; then row skipped "$repo" "" "" "volume-missing: stale worktree records left alone"; return 0; fi
  [ "$DRY" = 1 ] || git -C "$repo" worktree prune 2>/dev/null
}

sweep_repo() { # repo
  local repo=$1 slug list path head br flags checked="" first=1 rb
  if ! budget_ok; then row skipped "$repo" "" "" "time-budget"; return 0; fi
  slug=$(repo_slug "$repo")
  if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    tmo $((CALL_SEC * 2)) git -C "$repo" fetch -q --prune origin >/dev/null 2>&1 || { row skipped "$repo" "" "" "fetch-failed"; return 0; }
  fi
  default_facts "$repo"
  [ -n "$DEF_NAME" ] || { row skipped "$repo" "" "" "default-branch-unknown"; return 0; }
  load_open_prs "$slug"
  prune_stale_worktrees "$repo"
  list=$(mktemp "${TMPDIR:-/tmp}/prune-wt.XXXXXX") || return 0
  git -C "$repo" worktree list --porcelain | awk -v RS= -F'\n' '{
    path=""; head=""; br=""; fl=""
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^worktree /) path = substr($i, 10)
      else if ($i ~ /^HEAD /) head = substr($i, 6)
      else if ($i ~ /^branch /) br = substr($i, 8)
      else if ($i ~ /^locked/) fl = fl "locked,"
      else if ($i ~ /^prunable/) fl = fl "prunable,"
    }
    print path "\037" head "\037" br "\037" fl
  }' > "$list"
  while IFS=$'\037' read -r path head br flags; do
    [ -n "$path" ] || continue
    checked="$checked
${br#refs/heads/}"
    rb=$(rebase_branch "$path") && checked="$checked
$rb"
    if [ "$first" = 1 ]; then first=0; continue; fi # the main checkout
    sweep_worktree "$repo" "$slug" "$path" "$head" "$br" "$flags"
  done < "$list"
  rm -f "$list"
  sweep_branches "$repo" "$slug" "$checked"
}


if [ -n "$ROOTS" ]; then
  repos=$(mktemp "${TMPDIR:-/tmp}/prune-repos.XXXXXX") || exit 0
  IFS=: read -r -a _roots <<< "$ROOTS"
  for root in "${_roots[@]}"; do
    [ -d "$root" ] || continue
    find "$root" -maxdepth 3 -name .git -type d 2>/dev/null
  done | while IFS= read -r g; do dirname "$g"; done | sort -u > "$repos"
  while IFS= read -r repo; do
    # git prints physical worktree paths, so the repo path must be physical too or the
    # managed-path check rejects every worktree under a symlinked parent (/tmp, iCloud).
    [ -n "$repo" ] && repo=$(cd -P "$repo" 2>/dev/null && pwd -P) && sweep_repo "$repo"
  done < "$repos"
  rm -f "$repos"
fi

finish
exit 0
