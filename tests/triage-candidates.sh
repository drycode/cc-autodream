#!/bin/bash
# Tests for bin/triage-candidates.sh - the nightly list of touched repos that need issue triage.
#
# Every repo is a real git repo in a temp dir whose origin URL points at github.com/test/<name>.
# `gh` is a shim earlier on PATH that serves issue lists from files. No network, no GitHub.
# One scenario per row of the failure matrix in the PR. The script never fails its caller, so
# most rows assert the exit status (0) and the row it wrote.
#
# Usage:  tests/triage-candidates.sh
# Exit:   0 if every assertion passes, 1 otherwise.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$HERE/lib-tmp.sh"; suite_tmp triage
BIN="$REPO_ROOT/bin/triage-candidates.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_grep(){   grep -q -- "$2" "$1" 2>/dev/null && ok "$3" || no "$3 (no /$2/ in $1)"; }
assert_nogrep(){ grep -q -- "$2" "$1" 2>/dev/null && no "$3 (/$2/ unexpectedly in $1)" || ok "$3"; }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got '$1', want '$2')"; }

T=$SUITE_TMP
export FAKE_GH_DIR="$T/gh"
mkdir -p "$FAKE_GH_DIR" "$T/bin"
# A test that forgets its own state file must not write to the real one.
export AUTODREAM_TRIAGE_STATE="$T/state-default.tsv"

# ---- the gh shim ----------------------------------------------------------------------------
# auth status        -> exit 0 (FAKE_GH_AUTH_FAIL=1 makes it exit 1)
# issue list -R X    -> $FAKE_GH_DIR/issues-<name>.json (default [])
#                       $FAKE_GH_DIR/disabled-<name> present: "has disabled issues" on stderr, exit 1
# repo view X        -> $FAKE_GH_DIR/perm-<name> ("PERMISSION<TAB>isArchived"), default ADMIN/false
# FAKE_GH_FAIL=1 fails every issue list; FAKE_GH_SLEEP=N delays it; FAKE_GH_REPO_FAIL=1 fails repo view.
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "auth status") [ -n "${FAKE_GH_AUTH_FAIL:-}" ] && exit 1; exit 0 ;;
  "repo view")
    [ -n "${FAKE_GH_REPO_FAIL:-}" ] && { echo "gh: repo view failed" >&2; exit 1; }
    name=${3#test/}; name=${name#Test/}
    f="$FAKE_GH_DIR/perm-$name"
    [ -f "$f" ] && cat "$f" || printf 'ADMIN\tfalse\n' ;;
  "issue list")
    [ -n "${FAKE_GH_FAIL:-}" ] && { echo "gh: simulated failure" >&2; exit 1; }
    [ -z "${FAKE_GH_SLEEP:-}" ] || sleep "$FAKE_GH_SLEEP"
    shift 2; repo=""
    while [ $# -gt 0 ]; do case "$1" in -R) repo=$2 ;; esac; shift; done
    name=${repo#test/}
    if [ -e "$FAKE_GH_DIR/disabled-$name" ]; then
      echo "the '$repo' repository has disabled issues" >&2; exit 1
    fi
    f="$FAKE_GH_DIR/issues-$name.json"
    [ -f "$f" ] && cat "$f" || echo '[]' ;;
  *) echo "fake gh: unhandled: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

g(){ git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

# make_repo NAME [URL] - a repo under $T/roots/NAME with origin URL (default github.com/test/NAME).
make_repo(){
  NAME=$1; R="$T/roots/$NAME"
  mkdir -p "$R"; g init -q "$R"
  echo x > "$R/a"; g -C "$R" add a; g -C "$R" commit -qm one
  g -C "$R" remote add origin "${2:-https://github.com/test/$NAME.git}"
}

# issues NAME UNTRIAGED LABELED [BUGONLY] - writes the issue list the shim serves.
# UNTRIAGED issues carry no state label, LABELED ones carry ready-for-agent. With BUGONLY the
# repo has no state labels at all: every issue is just `bug`.
issues(){
  local name=$1 u=$2 l=$3 only=${4:-} i out="[" sep=""
  for ((i = 1; i <= u; i++)); do
    if [ -n "$only" ]; then lab='[{"name":"bug"}]'; else lab='[{"name":"enhancement"}]'; fi
    out="$out$sep{\"number\":$i,\"createdAt\":\"2020-01-0${i}T00:00:00Z\",\"labels\":$lab}"; sep=","
  done
  for ((i = 1; i <= l; i++)); do
    out="$out$sep{\"number\":$((100 + i)),\"createdAt\":\"2021-01-01T00:00:00Z\",\"labels\":[{\"name\":\"ready-for-agent\"},{\"name\":\"bug\"}]}"; sep=","
  done
  printf '%s]\n' "$out" > "$FAKE_GH_DIR/issues-$name.json"
}

# run_t DATE ROWS... - runs the script for findings date DATE with the given stdin rows (one
# argument per row; a bare path becomes a 3-column session row). Sets OUT, RC, F.
run_t(){
  local date=$1; shift
  F="$T/findings/$date"; mkdir -p "$F"
  local rows="" p
  for p in "$@"; do rows="$rows$(printf 'h\tproj\t%s' "$p")"$'\n'; done
  OUT=$(printf '%s' "$rows" | "$BIN" "$F" 2>"$T/stderr"); RC=$?
}
tsv(){ echo "$F/triage-candidates.tsv"; }
md(){ echo "$F/triage-candidates.md"; }
row(){ awk -F'\t' -v s="$1" '$2 == s' "$(tsv)"; }

echo "== counting =="
make_repo alpha; issues alpha 4 2
run_t 2026-10-01 "$R"
assert_eq "$RC" 0 "exit 0"
row test/alpha | grep -q '^candidate	' && ok "4 untriaged of 6 open is a candidate" || no "alpha not a candidate: $(cat "$(tsv)")"
assert_eq "$(row test/alpha | cut -f4)" 4 "untriaged count is 4"
assert_eq "$(row test/alpha | cut -f5)" 6 "open total is 6"
assert_grep "$(md)" 'test/alpha' "markdown names the repo"
assert_grep "$(md)" '/triage' "markdown says what to run"
assert_grep "$(md)" "$R" "markdown names the checkout path"
assert_grep <(printf '%s\n' "$OUT") 'candidates=1' "summary line counts one candidate"

echo "== below threshold =="
make_repo beta; issues beta 2 3
run_t 2026-10-01 "$R"
row test/beta | grep -q '^below	' && ok "2 untriaged is below the threshold of 3" || no "beta: $(cat "$(tsv)")"
assert_nogrep "$(md)" 'test/beta' "below-threshold repo is not in the suggestion"

echo "== needs-triage label counts as untriaged =="
make_repo gamma
printf '[{"number":1,"createdAt":"2020-01-01T00:00:00Z","labels":[{"name":"needs-triage"}]},{"number":2,"createdAt":"2020-01-01T00:00:00Z","labels":[{"name":"needs-triage"},{"name":"bug"}]},{"number":3,"createdAt":"2020-01-01T00:00:00Z","labels":[]},{"number":4,"createdAt":"2020-01-01T00:00:00Z","labels":[{"name":"wontfix"}]}]\n' > "$FAKE_GH_DIR/issues-gamma.json"
run_t 2026-10-01 "$R"
assert_eq "$(row test/gamma | cut -f4)" 3 "needs-triage and unlabeled count, wontfix does not"

echo "== a repo that was never triaged =="
make_repo delta; issues delta 5 0 bugonly
run_t 2026-10-01 "$R"
row test/delta | grep -q '^candidate	' && ok "no state label anywhere: every open issue counts and the repo is suggested" || no "delta: $(cat "$(tsv)")"
assert_eq "$(row test/delta | cut -f4)" 5 "all 5 open issues are untriaged"

echo "== no open issues =="
make_repo eps; issues eps 0 0
run_t 2026-10-01 "$R"
row test/eps | grep -q 'none-open' && ok "zero open issues is skipped as none-open" || no "eps: $(cat "$(tsv)")"

echo "== the limit =="
make_repo zeta
jq -n '[range(1;201) | {number: ., createdAt: "2020-01-01T00:00:00Z", labels: []}] + [{number: 999, createdAt: "2020-01-01T00:00:00Z", labels: [{name: "needs-triage"}]}]' > "$FAKE_GH_DIR/issues-zeta.json"
AUTODREAM_TRIAGE_LIMIT=200 run_t 2026-10-01 "$R"
row test/zeta | grep -q '200+' && ok "a list that hits the limit is shown as 200+" || no "zeta: $(cat "$(tsv)")"

echo "== repo resolution =="
make_repo eta; issues eta 3 1
g -C "$R" worktree add -q -b wt "$R/.claude/worktrees/wt"
WT="$R/.claude/worktrees/wt"
run_t 2026-10-01 "$WT" "$R" "$R"
assert_eq "$(grep -c 'test/eta' "$(tsv)")" 1 "a worktree, its main checkout and a repeat are one row"
assert_grep "$(tsv)" "$R" "the row names the main checkout, not the worktree"

make_repo theta; issues theta 3 1
mkdir -p "$T/roots2"; g clone -q "$R" "$T/roots2/theta-copy"; g -C "$T/roots2/theta-copy" remote set-url origin "https://github.com/test/theta.git"
run_t 2026-10-01 "$R" "$T/roots2/theta-copy"
assert_eq "$(grep -c 'test/theta' "$(tsv)")" 1 "two clones of one slug are one row"

make_repo "iota repo"; issues "iota repo" 3 1
run_t 2026-10-01 "$R"
row "test/iota repo" | grep -q '^candidate' && ok "a path with a space works" || no "iota: $(cat "$(tsv)")"

echo "== cwd problems =="
mkdir -p "$T/plain"
run_t 2026-10-01 "$T/does-not-exist" "$T/plain" "?" ""
assert_eq "$RC" 0 "exit 0 with unusable cwds"
assert_grep "$(tsv)" 'cwd-gone' "a removed cwd is skipped as cwd-gone"
assert_grep "$(tsv)" 'not-git' "a non-git directory is skipped as not-git"
assert_nogrep "$(tsv)" '	?	' "a ? cwd is dropped, not listed"

echo "== remotes =="
make_repo gl "https://gitlab.com/test/gl.git"
run_t 2026-10-01 "$R"
assert_grep "$(tsv)" 'non-github' "a gitlab origin is skipped as non-github"
make_repo noremote; g -C "$R" remote remove origin
run_t 2026-10-01 "$R"
assert_grep "$(tsv)" 'non-github' "a repo with no origin is skipped as non-github"

echo "== gh failures =="
make_repo kappa; issues kappa 5 1
FAKE_GH_FAIL=1 run_t 2026-10-01 "$R"
assert_eq "$RC" 0 "exit 0 when gh fails"
row test/kappa | grep -q 'gh-failed' && ok "a failing issue list is skipped as gh-failed" || no "kappa: $(cat "$(tsv)")"
assert_nogrep "$(md)" 'test/kappa' "a failed repo is not suggested"
FAKE_GH_AUTH_FAIL=1 run_t 2026-10-01 "$R"
assert_eq "$RC" 0 "exit 0 when gh is logged out"
assert_grep "$(md)" 'gh unavailable' "logged out: the markdown says gh is unavailable"
assert_grep <(printf '%s\n' "$OUT") 'gh-unavailable' "logged out: the summary says gh-unavailable"
touch "$FAKE_GH_DIR/disabled-kappa"
run_t 2026-10-01 "$R"
row test/kappa | grep -q 'issues-disabled' && ok "a repo with issues disabled is skipped as issues-disabled" || no "kappa disabled: $(cat "$(tsv)")"
mv "$FAKE_GH_DIR/disabled-kappa" "$T/disabled-kappa.off"
# gh missing: a PATH with only the tools the script needs.
mkdir -p "$T/nogh"
for c in bash env git jq awk sed grep sort date cut tr mkdir mv cat dirname basename head tail wc printf sleep rm mktemp; do
  p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$T/nogh/$c"
done
F="$T/findings/2026-10-01"; mkdir -p "$F"
OUT=$(printf 'h\tp\t%s\n' "$R" | PATH="$T/nogh" "$BIN" "$F" 2>/dev/null); RC=$?
assert_eq "$RC" 0 "exit 0 when gh is not installed"
assert_grep <(printf '%s\n' "$OUT") 'gh-unavailable' "no gh: the summary says gh-unavailable"

echo "== a hung gh is bounded =="
FAKE_GH_SLEEP=20 AUTODREAM_TRIAGE_CALL_SEC=1 run_t 2026-10-01 "$R"
row test/kappa | grep -q 'gh-failed' && ok "a gh call past the timeout is gh-failed" || no "kappa hung: $(cat "$(tsv)")"

echo "== cooldown =="
S="$T/state-cool.tsv"; export AUTODREAM_TRIAGE_STATE="$S"
make_repo lam; issues lam 4 1; LAM=$R
run_t 2026-10-01 "$LAM"
row test/lam | grep -q '^candidate' && ok "night 1: suggested" || no "lam n1: $(cat "$(tsv)")"
assert_grep "$S" 'test/lam' "the suggestion is recorded in the state file"
run_t 2026-10-01 "$LAM"
row test/lam | grep -q '^candidate' && ok "a rerun of the same date is still suggested (a retried night)" || no "lam rerun: $(cat "$(tsv)")"
run_t 2026-10-03 "$LAM"
row test/lam | grep -q '^cooldown' && ok "two days later: held back by the cooldown" || no "lam n3: $(cat "$(tsv)")"
assert_nogrep "$(md)" 'test/lam' "a cooled-down repo is not in the suggestion"
issues lam 7 1
run_t 2026-10-04 "$LAM"
row test/lam | grep -q '^candidate' && ok "the count grew by 3: suggested again inside the cooldown" || no "lam grow: $(cat "$(tsv)")"
issues lam 7 1
run_t 2026-10-12 "$LAM"
row test/lam | grep -q '^candidate' && ok "8 days after the last suggestion: suggested again" || no "lam n12: $(cat "$(tsv)")"
chmod 444 "$S"
issues lam 20 1
run_t 2026-11-20 "$LAM"
chmod 644 "$S"
row test/lam | grep -q '^candidate' && ok "an unwritable state file still lets the suggestion through" || no "lam ro: $(cat "$(tsv)")"
export AUTODREAM_TRIAGE_STATE="$T/state-default.tsv"

echo "== the artifact is always rewritten =="
make_repo mu; issues mu 4 1; MU=$R
run_t 2026-10-20 "$MU"
assert_grep "$(md)" 'test/mu' "first run lists mu"
OUT=$(printf '' | "$BIN" "$F" 2>/dev/null); RC=$?
assert_eq "$RC" 0 "empty stdin exits 0"
assert_nogrep "$(md)" 'test/mu' "a rerun with no sessions removes the stale suggestion"
assert_grep <(printf '%s\n' "$OUT") 'candidates=0' "empty input: candidates=0"

echo "== off switch =="
make_repo nu; issues nu 4 0
F="$T/findings/2026-10-21"; mkdir -p "$F"
OUT=$(printf 'h\tp\t%s\n' "$R" | AUTODREAM_TRIAGE_SUGGEST=0 "$BIN" "$F" 2>/dev/null); RC=$?
assert_eq "$RC" 0 "exit 0 when switched off"
[ ! -e "$F/triage-candidates.md" ] && ok "switched off: no artifact" || no "switched off wrote an artifact"
assert_grep <(printf '%s\n' "$OUT") 'disabled' "switched off: summary says disabled"

echo "== a stale list never survives a rerun =="
make_repo xi; issues xi 4 1; XI=$R
run_t 2026-10-22 "$XI"
assert_grep "$(md)" 'test/xi' "setup: the list names xi"
OUT=$(printf 'h\tp\t%s\n' "$XI" | AUTODREAM_TRIAGE_SUGGEST=0 "$BIN" "$F" 2>/dev/null)
[ ! -e "$F/triage-candidates.md" ] && [ ! -e "$F/triage-candidates.tsv" ] && ok "switched off: the earlier list is removed" || no "switched off left a stale list"
run_t 2026-10-22 "$XI"
OUT=$(printf 'h\tp\t%s\n' "$XI" | AUTODREAM_TRIAGE_MIN=x "$BIN" "$F" 2>/dev/null); RC=$?
assert_eq "$RC" 0 "a bad integer config exits 0"
[ ! -e "$F/triage-candidates.md" ] && ok "bad config: the earlier list is removed" || no "bad config left a stale list"

echo "== cooldown edge cases =="
S2="$T/state-edge.tsv"; export AUTODREAM_TRIAGE_STATE="$S2"
make_repo omi; issues omi 4 1; OMI=$R
printf 'test/omi\t2026-10-14\t4\n' > "$S2"
run_t 2026-10-12 "$OMI"
row test/omi | grep -q '^candidate' && ok "a retry of an older night than the record is not held back" || no "omi older: $(cat "$(tsv)")"
printf 'test/omi\t2026-10-10\t4\ngarbage line\ntest/omi\tnot-a-date\tx\ntest/omi\t2026-10-11\t\n' > "$S2"
run_t 2026-10-12 "$OMI"
row test/omi | grep -q '^cooldown' && ok "garbage rows do not cancel the valid 10-10 row" || no "omi garbage: $(cat "$(tsv)")"
printf 'TEST/OMI\t2026-10-11\t4\n' > "$S2"
run_t 2026-10-12 "$OMI"
row test/omi | grep -q '^cooldown' && ok "the record matches a slug in any case" || no "omi case: $(cat "$(tsv)")"
export AUTODREAM_TRIAGE_STATE="$T/state-default.tsv"

echo "== label edge cases =="
make_repo pi
printf '[{"number":1,"createdAt":"2020-01-01T00:00:00Z","labels":[{"name":"needs-triage"},{"name":"ready-for-agent"}]},{"number":2,"createdAt":"2020-01-01T00:00:00Z","labels":null},{"number":3,"createdAt":"2020-01-01T00:00:00Z","labels":[]},{"number":4,"createdAt":"2020-01-01T00:00:00Z","labels":[{"name":"ready-for-human"}]}]\n' > "$FAKE_GH_DIR/issues-pi.json"
run_t 2026-10-01 "$R"
assert_eq "$(row test/pi | cut -f4)" 3 "needs-triage beside a state label, null labels and empty labels all count"

echo "== slug case and a pipe in the path =="
make_repo rho "https://github.com/Test/rho.git"; issues rho 4 1; RHO=$R
make_repo "rho|pipe" "https://github.com/test/rho.git"
run_t 2026-10-01 "$RHO" "$R"
assert_eq "$(grep -ci 'test/rho' "$(tsv)")" 1 "owner/repo in different case is one repo"
make_repo "sig|ma"; issues "sig|ma" 4 1
run_t 2026-10-01 "$R"
assert_grep "$(md)" 'sig\\|ma' "a pipe in the checkout path is escaped in the table"

echo "== only repos you can triage =="
make_repo sigma2; issues sigma2 4 1; SG=$R
printf 'READ\tfalse\n' > "$FAKE_GH_DIR/perm-sigma2"
run_t 2026-10-01 "$SG"
row test/sigma2 | grep -q 'not-maintainer' && ok "READ permission is skipped as not-maintainer" || no "sigma2 read: $(cat "$(tsv)")"
assert_nogrep "$(md)" 'test/sigma2' "an upstream repo is not suggested"
printf 'TRIAGE\tfalse\n' > "$FAKE_GH_DIR/perm-sigma2"
run_t 2026-10-01 "$SG"
row test/sigma2 | grep -q '^candidate' && ok "TRIAGE permission is enough" || no "sigma2 triage: $(cat "$(tsv)")"
printf 'ADMIN\ttrue\n' > "$FAKE_GH_DIR/perm-sigma2"
run_t 2026-10-01 "$SG"
row test/sigma2 | grep -q 'archived' && ok "an archived repo is skipped" || no "sigma2 archived: $(cat "$(tsv)")"
FAKE_GH_REPO_FAIL=1 run_t 2026-10-01 "$SG"
row test/sigma2 | grep -q 'gh-failed' && ok "a failing repo view is gh-failed" || no "sigma2 failing: $(cat "$(tsv)")"
assert_eq "$RC" 0 "and still exits 0"

echo "== no findings dir =="
OUT=$(printf 'h\tp\t%s\n' "$R" | "$BIN" "$T/not/a/dir" 2>/dev/null); RC=$?
assert_eq "$RC" 0 "an unusable findings dir still exits 0"
assert_grep <(printf '%s\n' "$OUT") 'triage:' "and still prints a summary line"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
