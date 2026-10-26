#!/bin/bash
# Tests for bin/prune-worktrees.sh - the nightly removal of finished worktrees and branches.
#
# Everything here is a real git repo in a temp dir. The remote is a local bare repo that a
# per-repo `url.insteadOf` makes answer to https://github.com/test/<name>.git, and `gh` is a
# shim earlier on PATH that serves PR state from files. `trash` is a shim that moves the
# directory aside. No network, no GitHub.
#
# The script deletes branches on a remote, so most of these cases pin a KEEP: a dirty tree, an
# unpushed commit, an open PR, a fresh file, a lock, a protected name, a PR that does not match
# the tip. A wrong delete cannot be undone and a wrong keep costs one more night.
#
# Usage:  tests/prune-worktrees.sh
# Exit:   0 if every assertion passes, 1 otherwise.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$HERE/lib-tmp.sh"; suite_tmp prune
BIN="$REPO_ROOT/bin/prune-worktrees.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_grep(){   grep -q "$2" "$1" 2>/dev/null && ok "$3" || no "$3 (no /$2/ in $1)"; }
assert_nogrep(){ grep -q "$2" "$1" 2>/dev/null && no "$3 (/$2/ unexpectedly in $1)" || ok "$3"; }

T=$SUITE_TMP
# Any call that forgets a ledger of its own must not write to the real one.
export AUTODREAM_PRUNE_LEDGER="$T/ledger-default.tsv"
export FAKE_GH_DIR="$T/gh"
export FAKE_GH_ROOT="$T"
mkdir -p "$FAKE_GH_DIR" "$T/bin"

# ---- the gh shim ----------------------------------------------------------------------------
# pr list --state open  -> $FAKE_GH_DIR/open-<name>.json   (default [])
# pr list --head B ...  -> $FAKE_GH_DIR/pr-<name>-B.json   (default [])
# RACE_BRANCH=B makes the remote branch B advance while the head lookup is answered, which is
# a push landing between the script's fetch and its delete.
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
[ -n "${FAKE_GH_FAIL:-}" ] && { echo "gh: simulated failure" >&2; exit 1; }
[ -z "${FAKE_GH_SLEEP:-}" ] || sleep "$FAKE_GH_SLEEP"
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr list")
    shift 2; repo=""; head=""; state=""; base=""
    while [ $# -gt 0 ]; do
      case "$1" in -R) repo=$2 ;; --head) head=$2 ;; --state) state=$2 ;; --base) base=$2 ;; esac
      shift
    done
    name=${repo#test/}
    if [ -n "$base" ]; then
      f="$FAKE_GH_DIR/base-$name-$base.json"
    elif [ "$state" = open ]; then
      f="$FAKE_GH_DIR/open-$name.json"
    else
      f="$FAKE_GH_DIR/pr-$name-$head.json"
      if [ -n "${RACE_BRANCH:-}" ] && [ "$head" = "$RACE_BRANCH" ]; then
        git -C "$FAKE_RACE_DIR" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m race
        git -C "$FAKE_RACE_DIR" push -q origin "$head"
      fi
    fi
    [ -f "$f" ] && cat "$f" || echo '[]' ;;
  *) echo "fake gh: unhandled: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$T/bin/gh"

# trash shim: moves the path under $T/trashed and fails when TRASH_FAIL is set.
cat > "$T/bin/trash" <<'SH'
#!/bin/bash
[ -n "${TRASH_FAIL:-}" ] && exit 1
mkdir -p "$FAKE_GH_ROOT/trashed" && mv "$1" "$FAKE_GH_ROOT/trashed/$(basename "$1")-$RANDOM"
SH
chmod +x "$T/bin/trash"
export PATH="$T/bin:$PATH"

# Every commit is from 2020, so a branch with no worktree clears the recent-commit gate.
export GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" GIT_COMMITTER_DATE="2020-01-01T00:00:00Z"

g(){ git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

# make_repo NAME [noremote] - seeds a repo with two commits on main and a tracked .gitignore.
make_repo(){
  NAME=$1
  BARE="$T/remotes/$NAME.git"
  R="$T/roots-$NAME/$NAME"
  mkdir -p "$T/roots-$NAME" "$T/seed-$NAME"
  g init -q "$T/seed-$NAME"
  echo one > "$T/seed-$NAME/a"; g -C "$T/seed-$NAME" add a; g -C "$T/seed-$NAME" commit -qm one
  FIRST=$(g -C "$T/seed-$NAME" rev-parse HEAD)
  printf 'ignored.out\n' > "$T/seed-$NAME/.gitignore"
  g -C "$T/seed-$NAME" add .gitignore; g -C "$T/seed-$NAME" commit -qm two
  if [ "${2:-}" = noremote ]; then
    g clone -q "$T/seed-$NAME" "$R"
    g -C "$R" remote remove origin
    return
  fi
  g init -q --bare "$BARE"
  g -C "$T/seed-$NAME" push -q "$BARE" main
  g -C "$BARE" symbolic-ref HEAD refs/heads/main
  g clone -q "$BARE" "$R"
  g -C "$R" config remote.origin.url "https://github.com/test/$NAME.git"
  g -C "$R" config "url.$BARE.insteadOf" "https://github.com/test/$NAME.git"
}

# worktree NAME - branch NAME at origin/main, checked out under <repo>/.claude/worktrees/NAME.
worktree(){ g -C "$R" worktree add -q -b "$1" "$R/.claude/worktrees/$1" origin/main; }
wt(){ echo "$R/.claude/worktrees/$1"; }
commit_in(){ echo "$RANDOM$1" > "$(wt "$1")/f-$1"; g -C "$(wt "$1")" add -A; g -C "$(wt "$1")" commit -qm "work $1"; }
tip(){ g -C "$R" rev-parse "refs/heads/$1"; }
push(){ g -C "$R" push -q origin "$1"; }
# pr NAME STATE HEAD [CLOSED_AT] [BASE] [CROSS] - what the shim answers for `gh pr list --head NAME`.
pr(){
  printf '[{"number":%s,"state":"%s","mergedAt":null,"closedAt":"%s","headRefOid":"%s","baseRefName":"%s","isCrossRepository":%s,"url":"https://github.com/test/%s/pull/%s"}]\n' \
    "$RANDOM" "$2" "${4:-2020-01-01T00:00:00Z}" "$3" "${5:-main}" "${6:-false}" "$NAME" "$RANDOM" > "$FAKE_GH_DIR/pr-$NAME-$1.json"
}
# open_prs HEAD:BASE... - the repo-wide open PR list the shim serves.
open_prs(){
  local out="[" sep="" pair
  for pair in "$@"; do out="$out$sep{\"headRefName\":\"${pair%%:*}\",\"baseRefName\":\"${pair#*:}\"}"; sep=","; done
  printf '%s]\n' "$out" > "$FAKE_GH_DIR/open-$NAME.json"
}
# age PATH - push every mtime under a worktree (and its gitdir) far into the past.
age(){
  find "$1" -path '*/.git' -prune -o -type f -exec touch -t 202001010000 {} + 2>/dev/null
  find "$R/.git/worktrees" -type f -exec touch -t 202001010000 {} + 2>/dev/null
}
# Ledger columns: 1 time, 2 run, 3 event, 4 repo, 5 slug, 6 branch, 7 tip, 8 remote tip, 9 worktree, 10 detail, 11 recover.
ledger_row(){ awk -F'\t' -v e="$2" -v b="$3" '$3==e && $6==b {print NR; exit}' "$1"; }   # LEDGER EVENT BRANCH -> line number
ledger_col(){ awk -F'\t' -v e="$2" -v b="$3" -v c="$4" '$3==e && $6==b {print $c; exit}' "$1"; }   # LEDGER EVENT BRANCH COLUMN
has_wt(){ [ -d "$(wt "$1")" ]; }
has_local(){ g -C "$R" rev-parse -q --verify "refs/heads/$1" >/dev/null; }
has_remote(){ g --git-dir="$BARE" rev-parse -q --verify "refs/heads/$1" >/dev/null; }
yn(){ "$@" && echo y || echo n; }
expect_removed(){ # NAME LABEL
  if ! has_wt "$1" && ! has_local "$1" && ! has_remote "$1"; then ok "$2: worktree, local and remote branch removed"
  else no "$2: expected full removal (wt=$(yn has_wt "$1") local=$(yn has_local "$1") remote=$(yn has_remote "$1"))"; fi
}
expect_kept(){ # NAME LABEL
  if has_wt "$1" && has_local "$1" && has_remote "$1"; then ok "$2: kept untouched"
  else no "$2: expected to keep everything (wt=$(yn has_wt "$1") local=$(yn has_local "$1") remote=$(yn has_remote "$1"))"; fi
}

run_prune(){
  # PRUNE_TEST_DEBUG=<repo name> traces the script for that repo and shows what it reported.
  local sh=""; [ "${PRUNE_TEST_DEBUG:-}" = "$NAME" ] && sh="bash -x"
  AUTODREAM_PRUNE_LEDGER="${LEDGER_OVERRIDE:-$OUT/ledger.tsv}" AUTODREAM_PRUNE_ROOTS="$T/roots-$NAME" AUTODREAM_PRUNE_GRACE_MIN=60 $sh "$BIN" "$@" "$OUT" >"$OUT.stdout" 2>&1
  PRUNE_RC=$?
  [ "${PRUNE_TEST_DEBUG:-}" != "$NAME" ] || { echo "--- $NAME"; cat "$OUT.stdout" "$OUT/worktree-prune.tsv"; }
  return 0
}

echo "== script exists"
[ -x "$BIN" ] && ok "bin/prune-worktrees.sh is executable" || { no "bin/prune-worktrees.sh is missing or not executable"; echo; echo "passed: $pass   failed: $fail"; exit 1; }

# ==== pass 1: one repo, every state =============================================================
make_repo main1
OUT="$T/out1"; mkdir -p "$OUT"
g -C "$R" config status.showUntrackedFiles no   # the dirty check must still see untracked files

worktree sq;        commit_in sq;        push sq;        pr sq MERGED "$(tip sq)"
echo junk > "$(wt sq)/ignored.out"
worktree dirty;     commit_in dirty;     push dirty;     pr dirty MERGED "$(tip dirty)"; echo x > "$(wt dirty)/untracked"
worktree unpushed;  commit_in unpushed
worktree openpr;    commit_in openpr;    push openpr;    pr openpr OPEN "$(tip openpr)"
worktree newer;     commit_in newer;     push newer;     pr newer MERGED "$(tip newer)"; echo y > "$(wt newer)/more"; g -C "$(wt newer)" add -A; g -C "$(wt newer)" commit -qm more
worktree fresh;     commit_in fresh;     push fresh;     pr fresh MERGED "$(tip fresh)"
worktree moved;     commit_in moved;     push moved;     pr moved MERGED "$(tip moved)"
worktree closedold; commit_in closedold; push closedold; pr closedold CLOSED "$(tip closedold)" 2020-01-01T00:00:00Z
worktree closednew; commit_in closednew; push closednew; pr closednew CLOSED "$(tip closednew)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
worktree develop;   commit_in develop;   push develop;   pr develop MERGED "$(tip develop)"
worktree staging;   commit_in staging;   push staging;   pr staging MERGED "$(tip staging)"
worktree locked;    commit_in locked;    push locked;    pr locked MERGED "$(tip locked)"; g -C "$R" worktree lock "$(wt locked)"
worktree stale;     commit_in stale;     push stale;     pr stale MERGED "$(tip stale)"; g -C "$R" worktree remove "$(wt stale)"
g -C "$R" worktree add -q --detach "$(wt detached)" "$FIRST"
worktree gone;      commit_in gone;      push gone;      pr gone MERGED "$(tip gone)"
# F1: a closed PR whose head is not the tip (commits pushed after it closed), and a fork PR.
worktree closedlater; commit_in closedlater; push closedlater; OLD=$(tip closedlater)
echo more > "$(wt closedlater)/more"; g -C "$(wt closedlater)" add -A; g -C "$(wt closedlater)" commit -qm later; push closedlater
pr closedlater CLOSED "$OLD" 2020-01-01T00:00:00Z
worktree fork;      commit_in fork;      push fork;      pr fork CLOSED "$(tip fork)" 2020-01-01T00:00:00Z main true
# F2: '#' in a branch name must not reach a sibling branch.
worktree 'fix#42';  commit_in 'fix#42';  push 'fix#42';  pr 'fix#42' MERGED "$(tip 'fix#42')"
g -C "$R" branch fix origin/main; push fix
# F3/F6: a merged PR into a non-default base, and a branch that is the base of an open PR.
worktree nonmain;   commit_in nonmain;   push nonmain;   pr nonmain MERGED "$(tip nonmain)" 2020-01-01T00:00:00Z release-x
worktree parent;    commit_in parent;    push parent;    pr parent MERGED "$(tip parent)"
open_prs openpr:main child:parent
# F8: submodules. F11: a rebase in progress.
worktree submod;    commit_in submod;    echo '[submodule "x"]' > "$(wt submod)/.gitmodules"; g -C "$(wt submod)" add -A; g -C "$(wt submod)" commit -qm gm; push submod; pr submod MERGED "$(tip submod)"
worktree rebasing;  commit_in rebasing;  push rebasing;  pr rebasing MERGED "$(tip rebasing)"
mkdir -p "$R/.git/worktrees/rebasing/rebase-merge"; echo refs/heads/rebasing > "$R/.git/worktrees/rebasing/rebase-merge/head-name"
# A long-lived branch under an unlisted name that an earlier PR targeted, and an OPEN row that
# only the head lookup shows.
worktree qa;        commit_in qa;        push qa;        pr qa MERGED "$(tip qa)"
printf '[{"number":1}]\n' > "$FAKE_GH_DIR/base-main1-qa.json"
worktree qa2;       commit_in qa2;       push qa2;       pr qa2 CLOSED "$(tip qa2)" 2020-01-01T00:00:00Z
printf '[{"number":1}]\n' > "$FAKE_GH_DIR/base-main1-qa2.json"
worktree hiddenopen; commit_in hiddenopen; push hiddenopen
printf '[{"number":1,"state":"MERGED","closedAt":"2020-01-01T00:00:00Z","headRefOid":"%s","baseRefName":"main","isCrossRepository":false},{"number":2,"state":"OPEN","closedAt":null,"headRefOid":"%s","baseRefName":"main","isCrossRepository":false}]\n' "$(tip hiddenopen)" "$(tip hiddenopen)" > "$FAKE_GH_DIR/pr-main1-hiddenopen.json"
# A quote in a branch name must survive the recover commands.
worktree "it's"; commit_in "it's"; push "it's"; pr "it's" MERGED "$(tip "it's")"
# F4: a push lands between the fetch and the delete.
worktree racy;      commit_in racy;      push racy;      pr racy MERGED "$(tip racy)"
g clone -q "$BARE" "$T/other-racy"; g -C "$T/other-racy" checkout -q racy
# Outside the managed directories.
mkdir -p "$T/elsewhere"; g -C "$R" worktree add -q -b outside "$T/elsewhere/outside" origin/main
echo o > "$T/elsewhere/outside/f"; g -C "$T/elsewhere/outside" add -A; g -C "$T/elsewhere/outside" commit -qm o
push outside; pr outside MERGED "$(g -C "$R" rev-parse refs/heads/outside)"

# A second clone advances the remote branch after the PR merged at the old tip.
g clone -q "$BARE" "$T/other-moved"; g -C "$T/other-moved" checkout -q moved; echo z > "$T/other-moved/z"
g -C "$T/other-moved" add -A; g -C "$T/other-moved" commit -qm later; g -C "$T/other-moved" push -q origin moved

# Everything gets old except `fresh`, which a session touched a minute ago.
for n in sq dirty unpushed openpr newer moved closedold closednew develop staging locked gone closedlater fork 'fix#42' nonmain parent submod rebasing racy qa qa2 hiddenopen "it's"; do age "$(wt "$n")"; done
age "$T/elsewhere/outside"; age "$(wt detached)"
rm -rf "$(wt gone)"

SQ_TIP=$(tip sq); MOVED_TIP=$(tip moved); SQ_PATH=$(cd -P "$(wt sq)" && pwd -P)
RACE_BRANCH=racy FAKE_RACE_DIR="$T/other-racy" run_prune
echo "== pass 1: every state"
expect_removed sq "squash-merged PR at the branch tip (with an ignored build file)"
expect_kept dirty "untracked file in the worktree"
has_wt unpushed && has_local unpushed && ok "unpushed commit with no PR: kept" || no "unpushed commit with no PR: kept"
expect_kept openpr "open PR"
expect_kept newer "local commits after the merged PR head"
expect_kept fresh "file modified inside the grace window"
{ ! has_wt moved && ! has_local moved && has_remote moved; } && ok "remote branch moved after merge: local removed, remote branch kept" || no "remote branch moved after merge: local removed, remote branch kept"
expect_removed closedold "PR closed unmerged long ago at this tip"
expect_kept closednew "PR closed unmerged today"
expect_kept closedlater "closed PR whose head is not the tip (commits pushed after it closed)"
expect_kept fork "closed fork PR with the same branch name"
expect_kept develop "protected branch name"
expect_kept staging "long-lived branch name (staging)"
expect_kept locked "locked worktree"
expect_kept nonmain "merged PR into a base that is not the default branch"
expect_kept parent "branch that is the base of an open PR"
expect_kept submod "worktree with submodules"
expect_kept rebasing "rebase in progress"
expect_kept qa "branch that an earlier PR targeted as its base"
expect_kept qa2 "closed-PR proof, but an earlier PR targeted the branch as its base"
expect_kept hiddenopen "OPEN row in the head lookup that the repo-wide list missed"
{ ! has_wt 'fix#42' && ! has_local 'fix#42' && ! has_remote 'fix#42'; } && ok "branch with # in its name: removed" || no "branch with # in its name: removed"
{ has_local fix && has_remote fix; } && ok "branch with # in its name: the sibling branch is untouched" || no "branch with # in its name: the sibling branch is untouched"
{ ! has_wt racy && ! has_local racy && has_remote racy; } && ok "push after the fetch: the lease refuses the remote delete" || no "push after the fetch: the lease refuses the remote delete"
{ ! has_local stale && ! has_remote stale; } && ok "merged branch with no worktree: local and remote deleted" || no "merged branch with no worktree: local and remote deleted"
[ ! -d "$(wt detached)" ] && ok "detached worktree at an old ancestor of main: removed" || no "detached worktree at an old ancestor of main: removed"
g -C "$R" worktree list --porcelain | grep -q "worktrees/gone" && no "manually deleted worktree: record pruned" || ok "manually deleted worktree: record pruned"
{ ! has_local gone && ! has_remote gone; } && ok "worktree deleted by hand: its merged branch goes with it" || no "worktree deleted by hand: its merged branch goes with it"
{ [ -d "$T/elsewhere/outside" ] && has_local outside && has_remote outside; } && ok "worktree outside .claude/worktrees: not touched" || no "worktree outside .claude/worktrees: not touched"
has_local main && ok "default branch survives" || no "default branch survives"
ls "$T/trashed" 2>/dev/null | grep -q '^sq-' && ok "removed worktree went to the Trash, not deleted" || no "removed worktree went to the Trash, not deleted"
assert_grep "$OUT/worktree-prune.tsv" "^kept.*dirty" "report names the dirty tree"
assert_grep "$OUT/worktree-prune.tsv" "^kept.*open-pr" "report names the open PR"
assert_grep "$OUT/worktree-prune.tsv" "^kept.*base-of-open-pr" "report names the open-PR base"
assert_grep "$OUT/worktree-prune.tsv" "^kept.*recent" "report names the recent edit"
assert_grep "$OUT/worktree-prune.tsv" "^kept.*submodules" "report names the submodules"
assert_grep "$OUT/worktree-prune.tsv" "^kept.*rebase-or-bisect" "report names the rebase"
assert_grep "$OUT/worktree-prune.tsv" "^kept.*base-of-pr" "report names the base-of-pr"
assert_grep "$OUT/worktree-prune.tsv" "^removed.*moved.*remote kept" "report says the remote branch was kept"
assert_grep "$OUT/worktree-prune.tsv" "^removed.*racy.*remote kept" "report says the lease refused"
assert_grep "$OUT/worktree-prune.md" "removed" "markdown summary written"

echo "== pass 1: the ledger"
L="$OUT/ledger.tsv"
[ "$(ledger_row "$L" run-start "")" = 1 ] && [ -n "$(ledger_row "$L" run-end "")" ] && ok "ledger opens with run-start and closes with run-end" || no "ledger opens with run-start and closes with run-end"
li=$(ledger_row "$L" intent sq); lw=$(ledger_row "$L" worktree-removed sq); ld=$(ledger_row "$L" local-deleted sq); lr=$(ledger_row "$L" remote-deleted sq); lc=$(ledger_row "$L" complete sq)
{ [ -n "$li" ] && [ "$li" -lt "$lw" ] && [ "$lw" -lt "$lr" ] && [ "$lr" -lt "$ld" ] && [ "$ld" -lt "$lc" ]; } && ok "ledger order for a removal: intent, worktree, remote, local, complete" || no "ledger order for a removal (li=$li lw=$lw lr=$lr ld=$ld lc=$lc)"
[ "$(ledger_col "$L" intent sq 7)" = "$SQ_TIP" ] && [ "$(ledger_col "$L" intent sq 8)" = "$SQ_TIP" ] && ok "intent records the local tip and the remote tip" || no "intent records the local tip and the remote tip"
[ "$(ledger_col "$L" intent sq 9)" = "$SQ_PATH" ] && ok "intent records the worktree path" || no "intent records the worktree path"
ledger_col "$L" intent sq 10 | grep -q "https://github.com/test/main1/pull/.* MERGED head=$SQ_TIP base=main" && ok "intent records the PR url, state, head and base as proof" || no "intent records the PR url, state, head and base as proof"
[ -z "$(ledger_row "$L" intent dirty)" ] && [ -z "$(ledger_row "$L" intent openpr)" ] && ok "kept items leave no intent line" || no "kept items leave no intent line"
[ "$(ledger_col "$L" remote-kept moved 10 | grep -c "differs from the proven tip")" = 1 ] && ok "a moved remote branch is recorded as kept, with both tips" || no "a moved remote branch is recorded as kept, with both tips"
ledger_col "$L" intent sq 10 | grep -q "commit held by refs/prune-ledger/" && ok "intent names the pin ref that holds the commit" || no "intent names the pin ref that holds the commit"
g -C "$R" for-each-ref --format='%(objectname)' refs/prune-ledger | grep -q "^$SQ_TIP$" && ok "a pin ref holds the removed tip" || no "a pin ref holds the removed tip"
g -C "$R" gc --prune=now -q 2>/dev/null   # without the pin this would delete the tip's commit
rec=$(ledger_col "$L" intent sq 11)
bash -c "$rec" >/dev/null 2>&1
{ has_local sq && has_remote sq && [ "$(tip sq)" = "$SQ_TIP" ]; } && ok "after git gc --prune=now, the recorded recover commands restore the local and the remote branch at the same tip" || no "after git gc --prune=now, the recorded recover commands restore the local and the remote branch at the same tip"
expect_removed "it's" "branch with a quote in its name"
rec=$(ledger_col "$L" intent "it's" 11)
bash -c "$rec" >/dev/null 2>&1
{ has_local "it's" && has_remote "it's"; } && ok "recover commands for a branch with a quote in its name restore both branches" || no "recover commands for a branch with a quote in its name restore both branches"
if command -v fish >/dev/null 2>&1; then
  g -C "$R" branch -D "it's" >/dev/null 2>&1; g --git-dir="$BARE" update-ref -d "refs/heads/it's"
  fish -c "$rec" >/dev/null 2>&1
  { has_local "it's" && has_remote "it's"; } && ok "the same recover commands also run under fish" || no "the same recover commands also run under fish"
fi

# ==== pass 2: dry run changes nothing ===========================================================
make_repo dry; OUT="$T/out2"; mkdir -p "$OUT"
worktree d1; commit_in d1; push d1; pr d1 MERGED "$(tip d1)"; age "$(wt d1)"
run_prune --dry-run
echo "== pass 2: dry run"
expect_kept d1 "dry run"
assert_grep "$OUT/worktree-prune.tsv" "^would-remove" "dry run lists what it would remove"
[ ! -e "$OUT/ledger.tsv" ] && ok "dry run writes no ledger" || no "dry run writes no ledger"

# ==== pass 3: gh down means no proof, so nothing goes ===========================================
make_repo ghdown; OUT="$T/out3"; mkdir -p "$OUT"
worktree g1; commit_in g1; push g1; pr g1 MERGED "$(tip g1)"; age "$(wt g1)"
FAKE_GH_FAIL=1 run_prune
echo "== pass 3: gh unavailable"
expect_kept g1 "gh failing"
assert_grep "$OUT/worktree-prune.tsv" "gh-unavailable" "report names the gh failure"

# ==== pass 4: the per-run cap bounds the blast radius ===========================================
make_repo cap; OUT="$T/out4"; mkdir -p "$OUT"
for n in c1 c2 c3; do worktree $n; commit_in $n; push $n; pr $n MERGED "$(tip $n)"; age "$(wt $n)"; done
AUTODREAM_PRUNE_MAX=2 run_prune
echo "== pass 4: cap"
removed=0; for n in c1 c2 c3; do has_local $n || removed=$((removed + 1)); done
[ "$removed" -eq 2 ] && ok "cap of 2 removes exactly two of three" || no "cap of 2 removes exactly two of three (removed $removed)"
assert_grep "$OUT/worktree-prune.tsv" "cap" "report names the cap"

# ==== pass 5: a repo with no remote uses local ancestry =========================================
make_repo local1 noremote; OUT="$T/out5"; mkdir -p "$OUT"
g -C "$R" worktree add -q -b done1 "$(wt done1)"; commit_in done1
g -C "$R" merge -q --no-ff -m merge done1
g -C "$R" worktree add -q -b todo1 "$(wt todo1)"; commit_in todo1
g -C "$R" worktree add -q -b empty1 "$(wt empty1)" HEAD~2
age "$(wt done1)"; age "$(wt todo1)"; age "$(wt empty1)"
AUTODREAM_PRUNE_TRASH=0 run_prune
echo "== pass 5: no remote"
{ ! has_wt done1 && ! has_local done1; } && ok "no remote: branch merged into main is removed" || no "no remote: branch merged into main is removed"
ledger_col "$OUT/ledger.tsv" intent done1 11 | grep -q push && no "no remote: the recover command must not push a remote branch" || ok "no remote: the recover command has no push half"
{ has_wt todo1 && has_local todo1; } && ok "no remote: unmerged branch kept" || no "no remote: unmerged branch kept"
{ has_wt empty1 && has_local empty1; } && ok "no remote: a branch with no commits of its own is kept" || no "no remote: a branch with no commits of its own is kept"

# ==== pass 6: the nightly entry point never fails the caller ====================================
OUT="$T/out6"; mkdir -p "$OUT"
AUTODREAM_PRUNE_ROOTS="$T/does-not-exist" "$BIN" "$OUT" >/dev/null 2>&1; rc=$?
echo "== pass 6: bad root"
[ "$rc" -eq 0 ] && ok "missing root exits 0" || no "missing root exits 0 (rc=$rc)"
AUTODREAM_PRUNE_ROOTS="" "$BIN" "$OUT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "unset roots exits 0 and does nothing" || no "unset roots exits 0 (rc=$rc)"

# ==== pass 7: a failing trash never falls back to deleting for good =============================
make_repo trashfail; OUT="$T/out7"; mkdir -p "$OUT"
worktree t1; commit_in t1; push t1; pr t1 MERGED "$(tip t1)"; age "$(wt t1)"
TRASH_FAIL=1 run_prune
echo "== pass 7: trash fails"
expect_kept t1 "trash failing"
assert_grep "$OUT/worktree-prune.tsv" "trash-failed" "report names the trash failure"
L="$OUT/ledger.tsv"
{ [ -n "$(ledger_row "$L" intent t1)" ] && [ -n "$(ledger_row "$L" worktree-failed t1)" ] && [ -z "$(ledger_row "$L" local-deleted t1)" ] && [ -z "$(ledger_row "$L" complete t1)" ]; } && ok "a failed trash is logged after the intent, and nothing else is logged as done" || no "a failed trash is logged after the intent, and nothing else is logged as done"

# ==== pass 8: ignored files with no Trash ======================================================
make_repo ign; OUT="$T/out8"; mkdir -p "$OUT"
worktree i1; commit_in i1; push i1; pr i1 MERGED "$(tip i1)"; echo secret > "$(wt i1)/ignored.out"; age "$(wt i1)"
AUTODREAM_PRUNE_TRASH=0 run_prune
echo "== pass 8: ignored files, no Trash"
expect_kept i1 "ignored file that git would delete for good"
assert_grep "$OUT/worktree-prune.tsv" "ignored-files" "report names the ignored files"

# ==== pass 9: an origin that is not on GitHub has no proof source ==============================
make_repo nongh; OUT="$T/out9"; mkdir -p "$OUT"
worktree n1; commit_in n1; push n1; pr n1 MERGED "$(tip n1)"; age "$(wt n1)"
g -C "$R" config remote.origin.url "$BARE"
run_prune
echo "== pass 9: non-GitHub origin"
expect_kept n1 "origin that is not github.com"
assert_grep "$OUT/worktree-prune.tsv" "non-github-remote" "report names the non-GitHub remote"

# ==== pass 10: the time budget and the open-PR limit ============================================
make_repo budget; OUT="$T/out10"; mkdir -p "$OUT"
worktree b1; commit_in b1; push b1; pr b1 MERGED "$(tip b1)"; age "$(wt b1)"
AUTODREAM_PRUNE_BUDGET_SEC=0 run_prune
echo "== pass 10: budget and limit"
expect_kept b1 "time budget spent"
assert_grep "$OUT/worktree-prune.tsv" "time-budget" "report names the time budget"
open_prs other:main
AUTODREAM_PRUNE_OPEN_LIMIT=1 run_prune
expect_kept b1 "open-PR list at its limit"
assert_grep "$OUT/worktree-prune.tsv" "gh-unavailable" "report treats a full open-PR list as no proof"

# ==== pass 11: a stale record on a missing volume is left alone =================================
make_repo vol; OUT="$T/out11"; mkdir -p "$OUT"
worktree vm1; commit_in vm1; push vm1
rm -rf "$R/.claude/worktrees"
run_prune
echo "== pass 11: missing volume"
g -C "$R" worktree list --porcelain | grep -q "worktrees/vm1" && ok "worktree record whose parent directory is missing: not pruned" || no "worktree record whose parent directory is missing: not pruned"
assert_grep "$OUT/worktree-prune.tsv" "volume-missing" "report names the missing volume"

# ==== pass 12: a rebase in the main checkout, and a detached worktree mid-rebase ===============
make_repo rb; OUT="$T/out12"; mkdir -p "$OUT"
worktree mainrb; commit_in mainrb; push mainrb; pr mainrb MERGED "$(tip mainrb)"; g -C "$R" worktree remove "$(wt mainrb)"
worktree detrb;  commit_in detrb;  push detrb;  pr detrb MERGED "$(tip detrb)"
g -C "$(wt detrb)" checkout -q --detach
mkdir -p "$R/.git/worktrees/detrb/rebase-merge"; echo refs/heads/detrb > "$R/.git/worktrees/detrb/rebase-merge/head-name"
age "$(wt detrb)"
mkdir -p "$R/.git/rebase-merge"; echo refs/heads/mainrb > "$R/.git/rebase-merge/head-name"
worktree bisb;   commit_in bisb;   push bisb;   pr bisb MERGED "$(tip bisb)"; g -C "$R" worktree remove "$(wt bisb)"
g -C "$R" worktree add -q --detach "$(wt bis)" "$FIRST"
echo "refs/heads/bisb" > "$R/.git/worktrees/bis/BISECT_START"; : > "$R/.git/worktrees/bis/BISECT_LOG"
age "$(wt bis)"
run_prune
echo "== pass 12: rebases and bisects"
{ has_local bisb && has_remote bisb; } && ok "branch a bisect started from: kept" || no "branch a bisect started from: kept"
has_wt bis && ok "worktree mid-bisect: kept" || no "worktree mid-bisect: kept"
{ has_local mainrb && has_remote mainrb; } && ok "branch being rebased in the main checkout: kept" || no "branch being rebased in the main checkout: kept"
{ has_wt detrb && has_local detrb && has_remote detrb; } && ok "detached worktree mid-rebase: its worktree and branch kept" || no "detached worktree mid-rebase: its worktree and branch kept"

# ==== pass 13: no timeout binary, and gh hangs ==================================================
mkdir -p "$T/minbin"
for tool in bash env git jq awk sed grep find sort cat mkdir mktemp dirname readlink date tr wc head rm mv touch sleep pkill basename cut cp ls uniq xargs chmod realpath; do
  tp=$(command -v "$tool") && [ -x "$tp" ] && ln -sf "$tp" "$T/minbin/$tool"
done
make_repo nt; OUT="$T/out13"; mkdir -p "$OUT"
worktree n1; commit_in n1; push n1; pr n1 MERGED "$(tip n1)"; age "$(wt n1)"
start=$SECONDS
PATH="$T/minbin:$T/bin" FAKE_GH_SLEEP=25 AUTODREAM_PRUNE_CALL_SEC=1 run_prune
echo "== pass 13: no timeout binary"
[ $((SECONDS - start)) -lt 15 ] && ok "a hanging gh is cut off by the built-in watchdog ($((SECONDS - start))s)" || no "a hanging gh is cut off by the built-in watchdog ($((SECONDS - start))s)"
expect_kept n1 "gh hung"
assert_grep "$OUT/worktree-prune.tsv" "gh-unavailable" "report names the gh failure after the cut-off"

# ==== pass 14: the hard cap stops a run and still writes the report =============================
make_repo wd; OUT="$T/out14"; mkdir -p "$OUT"
worktree w1; commit_in w1; push w1; pr w1 MERGED "$(tip w1)"; age "$(wt w1)"
start=$SECONDS
FAKE_GH_SLEEP=25 AUTODREAM_PRUNE_CALL_SEC=100 AUTODREAM_PRUNE_BUDGET_SEC=1 AUTODREAM_PRUNE_KILL_SLACK=0 run_prune
echo "== pass 14: hard cap"
[ "$PRUNE_RC" -eq 0 ] && ok "watchdog stop exits 0" || no "watchdog stop exits 0 (rc=$PRUNE_RC)"
[ $((SECONDS - start)) -lt 15 ] && ok "watchdog stops the run in time ($((SECONDS - start))s)" || no "watchdog stops the run in time ($((SECONDS - start))s)"
assert_grep "$OUT/worktree-prune.tsv" "watchdog" "report records the watchdog stop"
expect_kept w1 "run stopped by the watchdog"

# ==== pass 15: no log, no delete ===============================================================
make_repo lg; OUT="$T/out15"; mkdir -p "$OUT"
worktree l1; commit_in l1; push l1; pr l1 MERGED "$(tip l1)"; age "$(wt l1)"
LEDGER_OVERRIDE=/dev/null/nope/ledger.tsv run_prune
echo "== pass 15: unwritable ledger"
expect_kept l1 "ledger that cannot be written"
assert_grep "$OUT/worktree-prune.tsv" "ledger-unwritable" "report names the unwritable ledger"

# ==== pass 16: no pin, no delete ================================================================
make_repo pf; OUT="$T/out16"; mkdir -p "$OUT"
worktree p1; commit_in p1; push p1; pr p1 MERGED "$(tip p1)"; age "$(wt p1)"
mkdir -p "$R/.git/refs/prune-ledger"; chmod 555 "$R/.git/refs/prune-ledger"   # the pin namespace cannot be written
run_prune
echo "== pass 16: pin fails"
expect_kept p1 "pin ref that cannot be created"
assert_grep "$OUT/worktree-prune.tsv" "pin-failed" "report names the failed pin"
[ -n "$(ledger_row "$OUT/ledger.tsv" pin-failed p1)" ] && [ -z "$(ledger_row "$OUT/ledger.tsv" intent p1)" ] && ok "a failed pin is logged and no intent follows" || no "a failed pin is logged and no intent follows"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
