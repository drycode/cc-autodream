#!/bin/bash
# Tests for bin/review.sh's "nothing to triage" skip.
#
# Drives the real review.sh against fixture reports with a mock claude on PATH,
# and asserts on whether a session would have been launched. No network, no
# model calls. Companion to run-all.sh, which covers bin/run.sh.
#
# The mock claude writes a marker file and exits; if the marker exists after a
# run, review.sh reached `exec claude`, i.e. it decided to launch a session.
#
# Usage:  tests/review-skip.sh
# Exit:   0 if every assertion passes, 1 otherwise.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$HERE/lib-tmp.sh"; suite_tmp ccrev
REVIEW="$REPO/bin/review.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_grep(){   grep -q -- "$2" "$1" 2>/dev/null && ok "$3" || no "$3 (no /$2/ in $1)"; }
assert_eq(){     [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

# Sandbox: a dreams/ dir plus a mock claude that records that it was invoked.
setup_env(){
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccrev.XXXXXX")
  mkdir -p "$root/dreams" "$root/bin"
  cat > "$root/bin/claude" <<'MOCK'
#!/bin/bash
touch "$LAUNCH_MARKER"
exit 0
MOCK
  chmod +x "$root/bin/claude"
  printf '%s' "$root"
}

mk_report(){ # $1=root $2=date $3=body
  printf '%s\n' "$3" > "$1/dreams/$2.md"
}

# Runs review.sh and echoes "launched" or "skipped".
# Config file is forced to a nonexistent path so the host's own
# ~/.claude/autodream/config (AUTODREAM_TRIAGE_SURFACE=cmux) cannot leak in and
# spawn a real workspace mid-test.
run_review(){ # $1=root ; rest = args
  local root="$1"; shift
  rm -f "$root/launched"
  LAUNCH_MARKER="$root/launched" \
  AUTODREAM_CONFIG="$root/nonexistent-config" \
  AUTODREAM_TRIAGE_SURFACE=inline \
  DREAMS_DIR="$root/dreams" \
  CLAUDE_BIN="$root/bin/claude" \
  bash "$REVIEW" "$@" > "$root/out" 2>&1
  [ -f "$root/launched" ] && printf 'launched' || printf 'skipped'
}

# Same invocation, but returns review.sh's own exit code instead of a verdict.
# run_review cannot be used for this: its exit status is the verdict printf's.
run_review_rc(){ # $1=root ; rest = args
  local root="$1"; shift
  LAUNCH_MARKER="$root/launched" \
  AUTODREAM_CONFIG="$root/nonexistent-config" \
  AUTODREAM_TRIAGE_SURFACE=inline \
  DREAMS_DIR="$root/dreams" \
  CLAUDE_BIN="$root/bin/claude" \
  bash "$REVIEW" "$@" > "$root/out" 2>&1
}

# --- fixture bodies --------------------------------------------------------

REPORT_MARKER_ZERO='# Autodream — 2020-01-02

## Open questions for the user
None that clear the triviality gate this run.

- Some context bullet that is not a question.

<!-- autodream:open-questions=0 -->'

REPORT_MARKER_THREE='# Autodream — 2020-01-02

## Open questions for the user
1. **Thing** — decide X?
2. **Other** — decide Y?
3. **Third** — decide Z?

<!-- autodream:open-questions=3 -->'

REPORT_PROSE_NONE='# Autodream — 2020-01-02

## Open questions for the user
None that clear the triviality gate this run.

- Just a context bullet.'

REPORT_PROSE_QUESTIONS='# Autodream — 2020-01-02

## Open questions for the user
- **Hook tightening**: should nudge-assumptions.sh block at edit #1?'

REPORT_STUB='# Autodream — 2020-01-02

No Claude Code sessions were modified on this date.

(Generated 2020-01-03T07:00:06Z)'

# An empty day that someone already closed out (see the real 2026-06-27). Both
# skip reasons apply; "already triaged" is the one worth printing.
REPORT_STUB_TRIAGED='# Autodream — 2020-01-02

No Claude Code sessions were modified on this date.

## Triage decisions

- 2020-01-03: No sessions modified. Nothing to triage; session closed.'

REPORT_NO_SECTION='# Autodream — 2020-01-02

## Top patterns (ranked)
Nothing much happened but there is no open-questions section at all.'

REPORT_TRIAGED='# Autodream — 2020-01-02

## Open questions for the user
1. **Thing** — decide X?

<!-- autodream:open-questions=1 -->

## Triage decisions
- [2020-01-03] thing: **applied.** Did the thing.
- [2020-01-03] other: **watch, no change.**'

# Real reports have used a dated heading and a numbered list (see 2026-07-09).
REPORT_TRIAGED_NUMBERED='# Autodream — 2020-01-02

## Open questions for the user
1. **Thing** — decide X?

<!-- autodream:open-questions=1 -->

## Triage decisions (2020-01-03)

1. **Q1 (thing) — APPLIED.** Did the thing.
2. **Q2 (other) — APPLIED, modified.** Did the other thing.
3. **Q3 (third) — APPLIED.** And the third.'

# --- tests -----------------------------------------------------------------

test_marker_zero_skips(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_MARKER_ZERO"
  assert_eq "$(run_review "$root" 2020-01-02)" skipped "marker=0 skips the session"
  assert_grep "$root/out" 'no open questions' "marker=0 explains why it skipped"
  assert_grep "$root/out" '--force 2020-01-02' "skip notice offers the --force escape hatch"
}

test_marker_nonzero_launches(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_MARKER_THREE"
  assert_eq "$(run_review "$root" 2020-01-02)" launched "marker=3 launches the session"
}

test_prose_none_skips(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_PROSE_NONE"
  assert_eq "$(run_review "$root" 2020-01-02)" skipped "markerless 'None...' prose skips (fallback)"
}

test_prose_questions_launches(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_PROSE_QUESTIONS"
  assert_eq "$(run_review "$root" 2020-01-02)" launched "markerless real questions launch"
}

test_stub_skips(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_STUB"
  assert_eq "$(run_review "$root" 2020-01-02)" skipped "empty-day stub skips"
}

# The conservative default: a shape we cannot classify must launch, because a
# false skip silently swallows real questions.
test_unknown_launches(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_NO_SECTION"
  assert_eq "$(run_review "$root" 2020-01-02)" launched "unclassifiable report launches (fail-safe)"
}

test_triaged_skips(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_TRIAGED"
  assert_eq "$(run_review "$root" 2020-01-02)" skipped "already-triaged report skips despite open questions"
  assert_grep "$root/out" 'already triaged (2 decisions logged)' "triaged notice counts the decisions"
}

test_triaged_numbered_skips(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_TRIAGED_NUMBERED"
  assert_eq "$(run_review "$root" 2020-01-02)" skipped "dated-heading triaged report skips"
  assert_grep "$root/out" 'already triaged (3 decisions logged)' "numbered decisions are counted too"
}

test_force_overrides(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_MARKER_ZERO"
  assert_eq "$(run_review "$root" --force 2020-01-02)" launched "--force launches a zero-question report"
  mk_report "$root" 2020-01-03 "$REPORT_TRIAGED"
  assert_eq "$(run_review "$root" --force 2020-01-03)" launched "--force launches an already-triaged report"
}

test_latest_report_default(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-01 "$REPORT_MARKER_THREE"
  mk_report "$root" 2020-01-02 "$REPORT_MARKER_ZERO"
  # Stamp both explicitly. Writing them in order is not enough: review.sh picks
  # the latest with `ls -t`, and two files written in the same instant tie —
  # BSD ls then breaks the tie by name, which would pick the wrong report.
  touch -t 202001011200 "$root/dreams/2020-01-01.md"
  touch -t 202001021200 "$root/dreams/2020-01-02.md"
  assert_eq "$(run_review "$root")" skipped "no-arg run resolves the latest report and skips it"
}

test_stub_triaged_prefers_triaged_reason(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-02 "$REPORT_STUB_TRIAGED"
  assert_eq "$(run_review "$root" 2020-01-02)" skipped "stub that was already triaged skips"
  assert_grep "$root/out" 'already triaged (1 decision logged)' "prefers the triaged reason, and says decision not decisions"
}

test_two_dates_error(){
  local root; root=$(setup_env)
  mk_report "$root" 2020-01-01 "$REPORT_MARKER_THREE"
  mk_report "$root" 2020-01-02 "$REPORT_MARKER_THREE"
  local rc=0
  run_review_rc "$root" 2020-01-01 2020-01-02 || rc=$?
  assert_grep "$root/out" 'expected one date' "two dates is an error, not a silent pick"
  assert_eq "$rc" 2 "two dates exits 2"
}

# --help is built from the header comment block, so it must not stop mid-thought.
test_help_is_complete(){
  local root; root=$(setup_env)
  run_review_rc "$root" --help
  assert_grep "$root/out" 'Usage: review.sh' "help includes the usage block"
  assert_grep "$root/out" 'force bypasses it' "help includes the end of the skip rationale"
  assert_grep "$root/out" 'config overrides defaults' "help runs to the end of the header"
}

test_missing_report_errors(){
  local root; root=$(setup_env)
  run_review "$root" 2020-01-09 >/dev/null
  assert_grep "$root/out" 'no autodream report found' "a missing report still errors, not skips"
}

# ---------------------------------------------------------------------------

[ -x "$REVIEW" ] || { echo "FATAL: $REVIEW not executable"; exit 1; }

echo "cc-autodream review.sh skip tests (mock claude)"
echo
test_marker_zero_skips
test_marker_nonzero_launches
test_prose_none_skips
test_prose_questions_launches
test_stub_skips
test_unknown_launches
test_triaged_skips
test_triaged_numbered_skips
test_stub_triaged_prefers_triaged_reason
test_two_dates_error
test_help_is_complete
test_force_overrides
test_latest_report_default
test_missing_report_errors
echo
echo "----------------------------------------"
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
