#!/bin/bash
# Tests for bin/cookie-cadence.sh, the #39 measurement pass.
#
# Drives the real script against fixture findings dirs. No network, no model calls, no
# credentials — the script only ever reads x-bookmarks.md headers and a file mtime.
#
# The whole script is one classification decision, and getting it wrong is not visible in
# the output: counting a network failure as an expiry makes a yearly chore read as a
# weekly one, and the number looks just as authoritative either way. So the fixtures pin
# each header shape the fetcher can actually write.
#
# Usage:  tests/cookie-cadence.sh
# Exit:   0 if every assertion passes, 1 otherwise.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$HERE/lib-tmp.sh"; suite_tmp ccad
SCRIPT="$REPO/bin/cookie-cadence.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_out(){    grep -q -- "$2" "$1" 2>/dev/null && ok "$3" || no "$3 (no /$2/ in output)"; }
assert_no_out(){ grep -q -- "$2" "$1" 2>/dev/null && no "$3 (found /$2/ in output)" || ok "$3"; }

setup_env(){
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$root/findings"
  printf '%s' "$root"
}

# The four header shapes bin/x-bookmarks.sh writes, plus the no-file case.
mk_day(){ # $1=root $2=date $3=ok|noneunread|auth|login|other|none|absent
  local dir="$1/findings/$2"
  mkdir -p "$dir"
  case "$3" in
    ok)         printf '# Unread X bookmarks\n\n## @someone\nbody\n' > "$dir/x-bookmarks.md" ;;
    noneunread) printf '# x-bookmarks: no unread bookmarks\n' > "$dir/x-bookmarks.md" ;;
    auth)       printf '# x-bookmarks: fetch failed — X rejected the credentials (HTTP 401) — the cookies are expired. Open x.com...\n' > "$dir/x-bookmarks.md" ;;
    login)      printf '# x-bookmarks: fetch failed — X returned its login page — the auth_token/ct0 cookies are expired or invalid. Open x.com...\n' > "$dir/x-bookmarks.md" ;;
    other)      printf '# x-bookmarks: fetch failed — jq is not installed or not on PATH, so bookmarks cannot be parsed\n' > "$dir/x-bookmarks.md" ;;
    none)       printf '# x-bookmarks: not configured (no credentials at /nowhere)\n' > "$dir/x-bookmarks.md" ;;
    absent)     : ;;   # the dir exists, the file does not
  esac
}

run_cadence(){ # $1=root ; rest = args
  local root="$1"; shift
  AUTODREAM_DIR="$root" bash "$SCRIPT" "$@" > "$root/out" 2>&1
}

test_measures_a_completed_lifetime(){
  echo "# a working stretch ending in a rejection is one measured lifetime"
  local root; root=$(setup_env)
  mk_day "$root" 2026-06-01 ok
  mk_day "$root" 2026-06-05 ok
  mk_day "$root" 2026-06-11 auth
  run_cadence "$root"
  assert_out "$root/out" "2026-06-01 -> 2026-06-11   10 day" "the span is counted from the first working night"
  assert_out "$root/out" "one expiry is an anecdote" "one event is called what it is"
  rm -rf "$root"
}

test_login_page_counts_as_expiry(){
  echo "# the login-page redirect means expired cookies too, not an unrelated failure"
  local root; root=$(setup_env)
  mk_day "$root" 2026-06-01 ok
  mk_day "$root" 2026-06-04 login
  run_cadence "$root"
  assert_out "$root/out" "2026-06-01 -> 2026-06-04   3 day" "it ends the lifetime"
  rm -rf "$root"
}

test_unrelated_failure_is_not_an_expiry(){
  echo "# regression: a broken jq or a dead network must not read as a cookie expiry"
  local root; root=$(setup_env)
  mk_day "$root" 2026-06-01 ok
  mk_day "$root" 2026-06-02 other
  mk_day "$root" 2026-06-03 none
  mk_day "$root" 2026-06-04 absent
  mk_day "$root" 2026-06-05 ok
  run_cadence "$root"
  assert_out "$root/out" "No expiry has been observed yet" "nothing was counted as an expiry"
  assert_out "$root/out" "since 2026-06-01, 4 day" "and the working stretch survived the gap intact"
  rm -rf "$root"
}

test_open_run_is_a_lower_bound(){
  echo "# credentials still alive give a lower bound, never a lifetime"
  local root; root=$(setup_env)
  mk_day "$root" 2026-06-01 ok
  mk_day "$root" 2026-06-21 noneunread
  run_cadence "$root"
  assert_out "$root/out" "a lower bound, not a lifetime" "the censoring is stated"
  assert_no_out "$root/out" "Observed credential lifetimes" "and it is not reported as a measured lifetime"
  rm -rf "$root"
}

test_second_lifetime_after_a_repaste(){
  echo "# a re-paste starts a new lifetime rather than extending the dead one"
  local root; root=$(setup_env)
  mk_day "$root" 2026-06-01 ok
  mk_day "$root" 2026-06-08 auth
  mk_day "$root" 2026-06-09 ok
  mk_day "$root" 2026-06-19 auth
  run_cadence "$root"
  assert_out "$root/out" "2026-06-01 -> 2026-06-08   7 day" "the first lifetime is measured"
  assert_out "$root/out" "2026-06-09 -> 2026-06-19   10 day" "the second starts at the re-paste, not at the first working night"
  assert_out "$root/out" "Mean over 2 expiry event(s): 8.5 day" "and the mean covers both"
  assert_out "$root/out" "enough expiries to act on" "two events is enough to say something"
  rm -rf "$root"
}

test_nothing_measurable_says_so(){
  echo "# regression: an unmeasured window must not read as a measured zero"
  local root; root=$(setup_env)
  mk_day "$root" 2026-06-01 none
  mk_day "$root" 2026-06-02 absent
  run_cadence "$root"
  assert_out "$root/out" "nothing to" "it refuses to report a cadence"
  assert_no_out "$root/out" "VERDICT" "and reaches no verdict at all"
  rm -rf "$root"
}

test_days_window_trims_the_oldest(){
  echo "# --days keeps the trailing window and drops what precedes it"
  local root; root=$(setup_env)
  mk_day "$root" 2026-06-01 ok
  mk_day "$root" 2026-06-02 auth
  mk_day "$root" 2026-06-03 ok
  run_cadence "$root" --days 1
  assert_no_out "$root/out" "2026-06-01" "the date outside the window is gone"
  assert_out "$root/out" "2026-06-03" "the one inside it stayed"
  rm -rf "$root"
}

test_bad_days_value_is_rejected(){
  echo "# a bare or non-numeric --days must fail loudly, not spin"
  local root; root=$(setup_env)
  mk_day "$root" 2026-06-01 ok
  AUTODREAM_DIR="$root" bash "$SCRIPT" --days > "$root/out" 2>&1
  [ "$?" -eq 2 ] && ok "a bare --days exits 2" || no "a bare --days did not exit 2"
  AUTODREAM_DIR="$root" bash "$SCRIPT" --days x > "$root/out" 2>&1
  [ "$?" -eq 2 ] && ok "a non-numeric --days exits 2" || no "a non-numeric --days did not exit 2"
  rm -rf "$root"
}

echo "cookie-cadence tests"
test_measures_a_completed_lifetime
test_login_page_counts_as_expiry
test_unrelated_failure_is_not_an_expiry
test_open_run_is_a_lower_bound
test_second_lifetime_after_a_repaste
test_nothing_measurable_says_so
test_days_window_trims_the_oldest
test_bad_days_value_is_rejected

echo
echo "----------------------------------------"
printf 'passed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
