#!/bin/bash
# An interrupted test suite must not leave its temp directory behind (issue #63).
#
# Each suite below is started under a private TMPDIR, SIGTERMed (to its whole
# process group, as a harness timeout or Ctrl-C does) as soon as it has made its
# first temp dir, and the private TMPDIR is then checked for leftovers. The
# suite has to still be running when the signal lands, or the check proves
# nothing: it would be an uninterrupted run that cleaned up on its last line, so
# that case FAILS instead of passing.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# shellcheck source=/dev/null
. "$HERE/lib-tmp.sh"; suite_tmp tmpclean

# Every suite that makes temp dirs and is not already covered by its own trap.
SUITES="adapter-contract lib-project adapters cookie-cadence preflight review-skip x-bookmarks run-all"

interrupt_suite() { # $1=suite -> sets $leftover, $alive
  local s="$1" root pid waited=0
  root=$(mktemp -d "$SUITE_TMP/$s.XXXXXX")
  set -m
  TMPDIR="$root" bash "$HERE/$s.sh" >/dev/null 2>&1 &
  pid=$!
  set +m
  # Wait for the suite to make a temp dir of its own, polling on a real interval.
  while [ "$waited" -lt 2000 ]; do
    # Two levels deep: the suite's own temp root exists once suite_tmp has made
    # it, and an entry INSIDE it means suite_tmp has returned, so the signal never
    # lands in the gap between mktemp and the assignment of SUITE_TMP.
    [ -n "$(ls -A "$root"/*/ 2>/dev/null)" ] && break
    sleep 0.005
    waited=$((waited + 1))
  done
  alive=0
  kill -TERM -- "-$pid" 2>/dev/null && alive=1
  wait "$pid" 2>/dev/null
  leftover=$(ls -A "$root" 2>/dev/null)
}

for s in $SUITES; do
  [ -f "$HERE/$s.sh" ] || { no "$s.sh exists"; continue; }
  # A very fast suite (preflight takes tens of ms) can finish between the poll
  # and the signal on a loaded machine; try again before calling it unprovable.
  tries=0
  while [ "$tries" -lt 5 ]; do
    interrupt_suite "$s"
    [ "$alive" = "1" ] && break
    tries=$((tries + 1))
  done
  if [ "$alive" != "1" ]; then
    no "$s was already gone when interrupted, so the check proves nothing"
  elif [ -n "$leftover" ]; then
    no "$s leaks its temp dir when interrupted (left: $leftover)"
  else
    ok "$s removes its temp dir when interrupted"
  fi
done

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
