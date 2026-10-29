#!/bin/bash
# Tests for the sharding of tests/run-all.sh: RUNALL_SHARD=i/n runs every n-th test and unit
# suite, so n jobs together run the whole suite exactly once, and RUNALL_LIST=1 prints what a shard
# would run without running it.
#
# The property that matters is a partition. A test that lands in no shard is a test nobody runs,
# which is the failure the old duplicate "unit suites" CI step guarded against, and a test in two
# shards is time paid twice. Listing is cheap, so the partition is proven here for every shard
# count CI or a developer is likely to use; the run itself is proven by running the shards.
#
# Usage:  tests/shard.sh
# Exit:   0 if every assertion passes, 1 otherwise.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$HERE/lib-tmp.sh"; suite_tmp ccshard
# shellcheck source=/dev/null
. "$REPO/bin/portable.sh"   # tmo

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (got [$1] want [$2])"; fi; }

RUNALL="$HERE/run-all.sh"
D=$(mktemp -d "${TMPDIR:-/tmp}/ccshard.XXXXXX")

# what a shard would run, one entry per line; the outer environment must not leak in
# Bounded: a run-all.sh that ignores RUNALL_LIST would run the whole suite per call, so a missing
# feature has to fail in seconds, not in a quarter of an hour.
list(){ tmo 30 env -u RUNALL_SHARD -u RUNALL_LIST ${1:+RUNALL_SHARD="$1"} RUNALL_LIST=1 bash "$RUNALL" 2>/dev/null; }
sig(){ sort | cksum; }   # cksum, not md5sum: macOS has no md5sum

echo "# the whole suite, listed"
list > "$D/all"
total=$(wc -l < "$D/all" | tr -d ' ')
if [ "$total" -gt 250 ]; then ok "an unsharded listing names $total tests and suites"; else
  no "an unsharded listing names too few entries ($total): RUNALL_LIST is not supported, so nothing below can mean anything"
  printf '\npassed: %s   failed: %s\n' "$pass" "$fail"; exit 1
fi
assert_eq "$(sort "$D/all" | uniq -d | wc -l | tr -d ' ')" "0" "and no entry is listed twice"
grep -q '^test_happy$' "$D/all" && ok "it includes a known test" || no "it lacks test_happy"
grep -q '^suite:report-format$' "$D/all" && ok "and a known unit suite, marked as one" || no "it lacks suite:report-format"

echo "# every shard count partitions it exactly"
for n in 2 3 4 6 8; do
  : > "$D/union.$n"
  min=999999; max=0
  for ((i = 0; i < n; i++)); do
    list "$i/$n" > "$D/s.$n.$i"
    c=$(wc -l < "$D/s.$n.$i" | tr -d ' ')
    [ "$c" -lt "$min" ] && min=$c; [ "$c" -gt "$max" ] && max=$c
    cat "$D/s.$n.$i" >> "$D/union.$n"
  done
  assert_eq "$(sort "$D/union.$n" | uniq -d | wc -l | tr -d ' ')" "0" "n=$n: no entry runs in two shards"
  assert_eq "$(sig < "$D/union.$n")" "$(sig < "$D/all")" "n=$n: the shards together are exactly the whole suite"
  [ $((max - min)) -le 1 ] && ok "n=$n: shard sizes differ by at most one ($min to $max)" || no "n=$n: shard sizes are lopsided ($min to $max)"
done
assert_eq "$(list 0/1 | sig)" "$(sig < "$D/all")" "0/1 is the whole suite"

echo "# a bad shard spec is refused, not read as the whole suite"
for bad in 4/4 5/4 x 1/0 -1/4 1/x 1 0/-2 1/2/3 /4 4/; do
  tmo 30 env RUNALL_SHARD="$bad" bash "$RUNALL" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 2 ]; then ok "RUNALL_SHARD=$bad exits 2"; else no "RUNALL_SHARD=$bad exits $rc, not 2"; fi
done
out=$(tmo 30 env RUNALL_SHARD="" RUNALL_LIST=1 bash "$RUNALL" 2>/dev/null | wc -l | tr -d ' ')
if [ "$out" = "$total" ]; then ok "an empty RUNALL_SHARD means unsharded"; else no "an empty RUNALL_SHARD changed the listing ($out vs $total)"; fi

# leading zeros are numbers, not octal: "08" is a valid count
assert_eq "$(list 07/08 | wc -l | tr -d ' ')" "$(list 7/8 | wc -l | tr -d ' ')" "07/08 is shard 7 of 8, not a bad octal"

echo "# every test invocation is gated, and listing runs nothing"
# A direct call to a test_ function, in any form: a bare line, an indented one, or one after && || ; or
# then/do. Every such call must go through _run, or that test runs in EVERY shard. The function
# definitions (`test_x(){`) and the `_run test_x` lines are not calls.
direct_calls(){ grep -nE '(^|[;&|][[:space:]]*|(then|do)[[:space:]]+)[[:space:]]*test_[a-z_0-9]+([[:space:]]|;|\|\||&&|$)' "$1" | grep -v '_run test_' | grep -vE '^[0-9]+:[[:space:]]*#'; }
printf '%s\n' 'test_bare' '  test_indented' 'test_or || true' '[ -n x ] && test_after_and' 'for t in a; do test_in_loop; done' > "$D/gate-bad.txt"
printf '%s\n' 'test_def(){' '_run test_gated' '# test_commented' 'echo "see test_in_a_string"' 'assert_eq "$x" "y" "test_named"' > "$D/gate-ok.txt"
assert_eq "$(direct_calls "$D/gate-bad.txt" | wc -l | tr -d ' ')" "5" "the detector flags a bare, indented, ||, && and loop call"
assert_eq "$(direct_calls "$D/gate-ok.txt" | wc -l | tr -d ' ')" "0" "and ignores a definition, a gated call, a comment and a mention in a string"
found=$(direct_calls "$RUNALL" || true)
if [ -z "$found" ]; then ok "run-all.sh makes no direct test_ call; each goes through _run"
else no "ungated test_ calls remain: $(printf '%s' "$found" | head -3 | tr '\n' ' ')"; fi
t0=$(date +%s); list 1/4 >/dev/null; t1=$(date +%s)
[ $((t1 - t0)) -lt 20 ] && ok "listing a shard is quick ($((t1 - t0))s), so it ran no test" || no "listing a shard took $((t1 - t0))s"
before=$(ls "${TMPDIR:-/tmp}" | grep -c '^ccad\.' || true)
list 2/4 >/dev/null
after=$(ls "${TMPDIR:-/tmp}" | grep -c '^ccad\.' || true)
assert_eq "$after" "$before" "and left no test sandbox behind"

echo "# the CI matrix runs every shard"
# The matrix lists the shard indexes and the run line, the job name and the step name each carry
# the count. If they disagree, a shard no job runs is a part of the suite nobody runs, and CI stays
# green. This is the one thing the sharding cannot check from inside run-all.sh.
WF="$REPO/.github/workflows/tests.yml"
matrix=$(sed -n 's/^ *shard: *\[\(.*\)\].*/\1/p' "$WF" | head -1 | tr -d ' ')
n_cmd=$(grep -o 'RUNALL_SHARD=\${{ matrix.shard }}/[0-9]*' "$WF" | head -1 | sed 's#.*/##')
n_name=$(grep -o 'name: test (\${{ matrix.shard }}/[0-9]*)' "$WF" | head -1 | sed 's#.*/##; s#)##')
n_step=$(grep -o 'shard \${{ matrix.shard }} of [0-9]*' "$WF" | head -1 | sed 's#.* of ##')
want=""; for ((k = 0; k < ${n_cmd:-0}; k++)); do want="${want:+$want,}$k"; done   # not seq -s,: BSD seq leaves a trailing comma
assert_eq "$matrix" "$want" "the matrix lists shards 0 to ${n_cmd:-?}-1, each once, with none missing"
assert_eq "$n_name" "$n_cmd" "the job name carries the same count as the run line"
assert_eq "$n_step" "$n_cmd" "and so does the step name"
if grep -qE '^  test:' "$WF" && grep -qE '^    needs: shards' "$WF"; then ok "the \`test\` check still exists and waits on every shard"; else no "the aggregating \`test\` job is missing or does not need the shards"; fi

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
