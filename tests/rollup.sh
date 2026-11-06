#!/bin/bash
# Tests for bin/rollup.sh: the per-session roll-up (rollup.tsv) and the per-category tally
# (categories.tsv) that Layer 2 counts from instead of listing the findings directory.
#
# Why this exists. L2's Glob and directory reads stop at 200 entries. On 2026-10-31 the findings
# dir held 2683 (885 findings JSONs, 885 .served, 885 sidecars, ~28 side files), so L2 counted from
# a 90-file sample and never saw fanouts.tsv. The fixture here holds more than 200 sessions on
# purpose, plus every side file that shares the directory, and every expected number is a literal
# derived from how the fixture was built, never recomputed with the same jq the script uses.
#
# One block per row of the failure matrix in the PR.
#
# Usage:  tests/rollup.sh
# Exit:   0 if every assertion passes, 1 otherwise.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$HERE/lib-tmp.sh"; suite_tmp rollup
BIN="$REPO/bin/rollup.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

[ -x "$BIN" ] || {
  printf '  FAIL - bin/rollup.sh missing or not executable\n'
  printf '\npassed: 0   failed: 1\n'; exit 1; }
command -v jq >/dev/null 2>&1 || {
  printf '  ok   - jq not installed; this suite is skipped\n'
  printf '\npassed: 1   failed: 0\n'; exit 0; }

T=$SUITE_TMP
F="$T/findings"
mkdir -p "$F/outside-worklist"
h(){ printf '%012x' "$1"; }   # a session's 12-hex artifact key from its fixture number

# sidecar NUM SIDECHAIN NESTED ADVISOR [SANDBOX_SHAPE_DENIES as a raw JSON value; absent when omitted,
# as in an omp sidecar or one written before the field existed]
sidecar(){
  local extra=""; [ "$#" -ge 5 ] && extra=",\"sandbox_shape_denies\":$5"
  printf '{"user_message_count":%s,"turn_count":%s,"tool_call_count":%s,"duration_minutes":%s,"models_used":["m-a","m-b"],"isSidechain":%s,"nested":%s,"is_advisor":%s%s}\n' \
    3 7 4 2.5 "$2" "$3" "$4" "$extra" > "$F/$(h "$1").stats.json"
}
served(){ printf 'runner\t-\t-\trunner\n' > "$F/$(h "$1").json.served"; }
source_row(){ printf '%s\t%s\n' "$(h "$1")" "$2" >> "$F/sessions-source.txt"; }
triaged(){ # NUM FINDINGS-JSON-ARRAY [PROJECT]
  jq -cn --arg p "/s/$1.jsonl" --arg proj "${3:-proj-$(( $1 % 7 ))}" --argjson f "$2" \
    '{session_path:$p, project:$proj, outcome:"fully_achieved", findings:$f,
      skills_invoked_count:3, skills_invoked_counts:{"superpowers:brainstorming":2,"ship":1}}' > "$F/$(h "$1").json"
  served "$1"
}
gated(){ # NUM
  jq -cn --arg p "/s/$1.jsonl" '{session_path:$p, skipped:"below_noise_gate", findings:[], project:"proj-g",
    skills_invoked:[], skills_invoked_count:0, skills_authored:[], skills_invoked_counts:{}}' > "$F/$(h "$1").json"
  served "$1"
}
SF='[{"category":"sandbox_friction","severity":"low","what":"x"}]'

# 1-100: triaged top-level, one sandbox_friction:low each. 1-10 also missed_skill:high, and 1 has it twice.
for i in $(seq 1 100); do
  f=$SF
  [ "$i" -le 10 ] && f='[{"category":"sandbox_friction","severity":"low"},{"category":"missed_skill","severity":"high"}]'
  [ "$i" -eq 1 ] && f='[{"category":"sandbox_friction","severity":"low"},{"category":"missed_skill","severity":"high"},{"category":"missed_skill","severity":"high"}]'
  # 2 carries a finding with no severity at all.
  [ "$i" -eq 2 ] && f='[{"category":"sandbox_friction","severity":"low"},{"category":"missed_skill","severity":"high"},{"category":"memory_miss"}]'
  # 6 has the same category at two severities: one session in the category's "all" row.
  [ "$i" -eq 6 ] && f='[{"category":"sandbox_friction","severity":"low"},{"category":"missed_skill","severity":"high"},{"category":"missed_skill","severity":"low"}]'
  triaged "$i" "$f"; sidecar "$i" false false false 0; source_row "$i" claude
done
# sandbox_shape_denies: 4 hit the deny 124 times, 9 exactly 10 times, 11 once. 12's sidecar
# predates the field and 13's holds a string: both blank, never 0.
sidecar 4 false false false 124; sidecar 9 false false false 10; sidecar 11 false false false 1
sidecar 12 false false false; sidecar 13 false false false '"lots"'
# 7 authored a skill and was given two instructions.
jq -c '.skills_authored = ["new-skill"] | .instructions_given = ["do x", "do y"]' "$F/$(h 7).json" > "$T/7.json" && mv "$T/7.json" "$F/$(h 7).json"
# 3's project holds a tab, which must not split the row.
triaged 3 '[{"category":"sandbox_friction","severity":"low"},{"category":"missed_skill","severity":"high"}]' "$(printf 'tab\there')"
# 101-190: gated top-level.
for i in $(seq 101 190); do gated "$i"; sidecar "$i" false false false; source_row "$i" omp; done
# 201-220: triaged claude subagents under parent 1 (11-20) and parent 2 (the rest): one tool_loop:medium each.
for i in $(seq 201 220); do
  triaged "$i" '[{"category":"tool_loop","severity":"medium"}]'; sidecar "$i" true false false; source_row "$i" claude
  p=$(h 1); [ "$i" -gt 210 ] && p=$(h 2)
  printf '%s\t%s\n' "$(h "$i")" "$p" >> "$F/fanouts.tsv"
done
# 221-225: gated omp children (nested, not sidechain): nested, but no fanouts.tsv row, since that file holds ungated rows only.
for i in $(seq 221 225); do gated "$i"; sidecar "$i" false true false; source_row "$i" omp; done
# 231-233: omp advisor sidecars under parent 5. 231 and 232 carry sandbox_friction, a tool-behavior
# finding L1 suppresses for advisors: a triage failure, never a ranked pattern. 232 and 233 both
# carry memory_miss:medium, a content finding: one session, counted as the parent's.
for i in 231 232 233; do
  af='[{"category":"sandbox_friction","severity":"low"}]'
  [ "$i" -eq 232 ] && af='[{"category":"sandbox_friction","severity":"low"},{"category":"memory_miss","severity":"medium"}]'
  [ "$i" -eq 233 ] && af='[{"category":"memory_miss","severity":"medium"}]'
  triaged "$i" "$af"; sidecar "$i" true true true; source_row "$i" omp
  printf '%s\t%s\n' "$(h "$i")" "$(h 5)" >> "$F/fanouts.tsv"
done
# 240: an L1 error stub.
jq -cn '{session_path:"/s/240.jsonl", error:"worker produced no findings JSON", findings:[]}' > "$F/$(h 240).json"
sidecar 240 false false false; source_row 240 claude
# 241: triaged, sidecar missing.
triaged 241 '[]'; source_row 241 claude
# 242: a findings JSON that does not parse.
printf '{"session_path": "/s/242.jsonl", "findings": [' > "$F/$(h 242).json"
sidecar 242 false false false 3; source_row 242 claude
# 243: a sidecar that does not parse; the findings still count.
triaged 243 "$SF"; printf 'not json' > "$F/$(h 243).stats.json"; source_row 243 claude
# 244: parses, but findings is not an array (run.sh's L1_FINDINGS_OK refuses it too).
printf '{"session_path":"/s/244.jsonl","findings":"oops"}\n' > "$F/$(h 244).json"
sidecar 244 false false false; source_row 244 claude
# 245: a gated stub whose findings is not an array: the array check comes before the gate.
printf '{"session_path":"/s/245.jsonl","skipped":"below_noise_gate","findings":"oops"}\n' > "$F/$(h 245).json"
sidecar 245 false false false; source_row 245 claude
# Side files that share the directory and must not become rows.
printf '{"not":"a session"}\n' > "$F/pins-like.json"
printf '{"findings":[{"category":"sandbox_friction","severity":"low"}]}\n' > "$F/outside-worklist/$(h 999).json"
printf 'worker exit code: 1\n' > "$F/$(h 240).json.err"
: > "$F/run-stats.txt"; : > "$F/changelog-window.md"

# Totals by construction: 100 + 90 + 20 + 5 + 3 + 1 + 1 + 1 + 1 + 1 + 1 = 224 sessions.
# triaged 100 + 20 + 3 + 1 (241) + 1 (243) = 125; gated 90 + 5 = 95; error 1;
# unreadable 3 (242, 244, 245). Ungated, the set the report calls N: 125 + 1 + 3 = 129.

echo "# a findings dir with more than 200 sessions rolls up every one of them"
OUT="$T/out"; mkdir -p "$OUT"
summary=$("$BIN" "$F" "$OUT" 2>"$T/err"); rc=$?
assert_eq "$rc" "0" "exit 0"
R="$OUT/rollup.tsv"; C="$OUT/categories.tsv"
assert_eq "$(head -1 "$R")" "$(printf 'hash\tstatus\tproject\tsource\tnested\tis_advisor\tparent\toutcome\tuser_message_count\tturn_count\ttool_call_count\tduration_minutes\tmodels_used\tfindings\tskills_invoked_count\tskills_invoked_counts\tskills_authored\tinstructions_given_count\tsandbox_shape_denies')" "rollup.tsv opens with its header"
assert_eq "$(tail -n +2 "$R" | wc -l | tr -d ' ')" "224" "one row per session, 224 of them"
assert_eq "$(awk -F'\t' 'NF != 19' "$R" | wc -l | tr -d ' ')" "0" "every row has 19 columns, a tab inside a project included"
assert_eq "$(tail -n +2 "$R" | cut -f1 | sort -u | wc -l | tr -d ' ')" "224" "no session appears twice"
assert_eq "$(tail -n +2 "$R" | cut -f1 | LC_ALL=C sort -c 2>&1 && echo sorted)" "sorted" "rows are in hash order"
assert_eq "$(grep -c "$(h 999)" "$R")" "0" "a findings JSON moved to outside-worklist/ is not a row"
assert_eq "$(grep -c 'pins-like' "$R")" "0" "a non-hash .json side file is not a row"

echo "# status marks gated rows so the ungated N matches compute_fanout_stats"
st(){ tail -n +2 "$R" | awk -F'\t' -v s="$1" '$2 == s' | wc -l | tr -d ' '; }
assert_eq "$(st triaged)" "125" "125 triaged"
assert_eq "$(st gated)" "95" "95 gated"
assert_eq "$(st error)" "1" "1 error stub"
assert_eq "$(st unreadable)" "3" "3 unreadable: one does not parse, two have no findings array"
assert_eq "$(tail -n +2 "$R" | awk -F'\t' '$2 != "gated"' | wc -l | tr -d ' ')" "129" "129 ungated: every row but a valid gated stub"

echo "# nested, advisor and parent"
row(){ awk -F'\t' -v k="$1" '($1 "") == (k "")' "$R"; }  # string compare: 0000000000e7 is numeric to awk
col(){ row "$1" | cut -f"$2"; }
assert_eq "$(tail -n +2 "$R" | awk -F'\t' '$5 == "true"' | wc -l | tr -d ' ')" "28" "28 nested: 20 subagents, 5 gated children, 3 advisors"
assert_eq "$(tail -n +2 "$R" | awk -F'\t' '$2 != "gated" && $5 == "true"' | wc -l | tr -d ' ')" "23" "23 ungated nested, the fanouts.tsv row count"
assert_eq "$(tail -n +2 "$R" | awk -F'\t' '$6 == "true"' | wc -l | tr -d ' ')" "3" "3 advisors"
assert_eq "$(col "$(h 215)" 7)" "$(h 2)" "a subagent names its parent from fanouts.tsv"
assert_eq "$(col "$(h 231)" 7)" "$(h 5)" "and so does an advisor"
assert_eq "$(col "$(h 1)" 7)" "" "a top-level session has a blank parent"
assert_eq "$(col "$(h 222)" 5)/$(col "$(h 222)" 7)" "true/" "a gated child is nested with a blank parent"

echo "# fields come from the findings JSON and the sidecar"
assert_eq "$(col "$(h 4)" 3)" "proj-4" "project"
assert_eq "$(col "$(h 4)" 4)" "claude" "source from sessions-source.txt"
assert_eq "$(col "$(h 150)" 4)" "omp" "an omp source"
assert_eq "$(col "$(h 4)" 8)" "fully_achieved" "outcome"
assert_eq "$(row "$(h 4)" | cut -f9-13)" "$(printf '3\t7\t4\t2.5\tm-a,m-b')" "user turns, turns, tool calls, duration and models from the sidecar"
assert_eq "$(col "$(h 4)" 14)" "sandbox_friction:low,missed_skill:high" "findings as category:severity"
assert_eq "$(col "$(h 4)" 15)" "3" "skills_invoked_count"
assert_eq "$(col "$(h 4)" 16)" "superpowers:brainstorming=2,ship=1" "skill counts compacted as name=count, safe for a namespaced name"
assert_eq "$(col "$(h 2)" 14)" "sandbox_friction:low,missed_skill:high,memory_miss:unknown" "a finding with no severity reads unknown"
assert_eq "$(row "$(h 7)" | cut -f17,18)" "$(printf 'new-skill\t2')" "skills_authored and instructions_given_count"
assert_eq "$(row "$(h 8)" | cut -f17,18)" "$(printf '\t')" "blank when the record has neither field"
assert_eq "$(col "$(h 3)" 3)" 'tab\there' "a tab inside a field is escaped, not a column break"
assert_eq "$(col "$(h 150)" 8)/$(col "$(h 150)" 14)" "/" "a gated row has no outcome and no findings"

echo "# a missing or broken input costs one row its cells, never the table"
assert_eq "$(row "$(h 241)" | cut -f2,9-13)" "$(printf 'triaged\t\t\t\t\t')" "a missing sidecar leaves its count cells blank, not zero"
assert_eq "$(row "$(h 243)" | cut -f2,9,14)" "$(printf 'triaged\t\tsandbox_friction:low')" "an unparseable sidecar blanks the counts and keeps the findings"
assert_eq "$(col "$(h 242)" 2)" "unreadable" "an unparseable findings JSON is a row marked unreadable"
assert_eq "$(row "$(h 242)" | cut -f9)" "3" "and still carries its sidecar's counts"
assert_eq "$(col "$(h 240)" 2)/$(col "$(h 240)" 14)" "error/" "an error stub is marked error"
assert_eq "$(col "$(h 244)" 2)/$(col "$(h 244)" 9)" "unreadable/3" "findings that is not an array is unreadable, with its sidecar counts"
assert_eq "$(col "$(h 245)" 2)" "unreadable" "even on a gated stub, so a forged stub cannot drop out of N"

echo "# sandbox_shape_denies comes from the sidecar, and a blank means unmeasured"
assert_eq "$(col "$(h 4)" 19)" "124" "the sidecar's count"
assert_eq "$(col "$(h 9)" 19)/$(col "$(h 11)" 19)" "10/1" "every count, not only the high ones"
assert_eq "$(col "$(h 50)" 19)" "0" "a measured zero stays 0"
assert_eq "$(col "$(h 12)" 19)" "" "a sidecar without the field is blank, not 0"
assert_eq "$(col "$(h 13)" 19)" "" "a value that is not a number is blank"
assert_eq "$(col "$(h 150)" 19)" "" "an omp row, whose sidecar has no such field, is blank"
assert_eq "$(col "$(h 241)" 19)" "" "a missing sidecar is blank"
assert_eq "$(col "$(h 243)" 19)" "" "an unparseable sidecar is blank"
assert_eq "$(col "$(h 242)" 19)" "3" "an unparseable findings JSON still carries its sidecar's count"
assert_eq "$(tail -n +2 "$R" | awk -F'\t' '$19 != "" && $19 + 0 >= 10' | cut -f1 | tr '\n' ' ')" "$(h 4) $(h 9) " "two sessions at or over 10"

echo "# categories.tsv tallies every finding"
assert_eq "$(head -1 "$C")" "$(printf 'category\tseverity\tsessions\tfindings\texample_hashes')" "categories.tsv opens with its header"
assert_eq "$(tail -n +2 "$C" | cut -f1-4)" "$(printf 'sandbox_friction\tall\t101\t101\nsandbox_friction\tlow\t101\t101\ntool_loop\tall\t20\t20\ntool_loop\tmedium\t20\t20\nmissed_skill\tall\t10\t12\nmissed_skill\thigh\t10\t11\nmissed_skill\tlow\t1\t1\nmemory_miss\tall\t2\t3\nmemory_miss\tmedium\t1\t2\nmemory_miss\tunknown\t1\t1')" "exact counts: all counts a session once across severities, an advisor counts under its parent, and its tool-behavior findings not at all"
assert_eq "$(awk -F'\t' '$1 == "missed_skill" && $2 == "high" {print $5}' "$C")" "$(h 1),$(h 2),$(h 3),$(h 4),$(h 5)" "up to five example hashes, in hash order"
assert_eq "$(awk -F'\t' '$1 == "memory_miss" && $2 == "all" {print $5}' "$C")" "$(h 2),$(h 232),$(h 233)" "fewer when fewer sessions have it, and an advisor's example is its own hash"

echo "# findings.tsv has one row per finding, for patterns narrower than a category"
FT="$OUT/findings.tsv"
assert_eq "$(head -1 "$FT")" "$(printf 'hash\tcategory\tseverity\twhat')" "findings.tsv opens with its header"
assert_eq "$(tail -n +2 "$FT" | wc -l | tr -d ' ')" "138" "138 findings, advisors' included"
assert_eq "$(awk -F'\t' -v k="$(h 50)" '($1 "") == (k "")' "$FT")" "$(printf '%s\tsandbox_friction\tlow\tx' "$(h 50)")" "hash, category, severity and what"
assert_eq "$(awk -F'\t' 'NF != 4' "$FT" | wc -l | tr -d ' ')" "0" "every row has four columns"
assert_eq "$summary" "rollup: rows=224 triaged=125 gated=95 error=1 unreadable=3 ungated=129 categories=4 findings=138 advisor_tool_findings=2" "a one-line summary on stdout"

echo "# the runner's in-memory source map wins over sessions-source.txt, which an L1 worker can rewrite"
OUT2="$T/out2"; mkdir -p "$OUT2"
AUTODREAM_SOURCE_MAP=$(printf '%s\tpinned\n' "$(h 4)") "$BIN" "$F" "$OUT2" >/dev/null 2>&1
assert_eq "$(awk -F'\t' -v k="$(h 4)" '($1 "") == (k "") {print $4}' "$OUT2/rollup.tsv")" "pinned" "the map's source is used"
assert_eq "$(awk -F'\t' -v k="$(h 5)" '($1 "") == (k "") {print $4}' "$OUT2/rollup.tsv")" "" "and a hash missing from the map has no source, not the file's"

echo "# the output dir defaults to the findings dir, and a rerun replaces the files whole"
F2="$T/f2"; mkdir -p "$F2"
cp "$F/$(h 1).json" "$F/$(h 1).stats.json" "$F2/"
printf 'stale\n' > "$F2/rollup.tsv"
"$BIN" "$F2" >/dev/null 2>&1
assert_eq "$(wc -l < "$F2/rollup.tsv" | tr -d ' ')" "2" "header plus the one session; the stale file is gone"
assert_eq "$(find "$F2" -name '*.tmp*' | wc -l | tr -d ' ')" "0" "no temp file is left behind"

echo "# an empty findings dir writes header-only files"
E="$T/empty"; mkdir -p "$E"
summary=$("$BIN" "$E" 2>/dev/null); rc=$?
assert_eq "$rc/$(wc -l < "$E/rollup.tsv" | tr -d ' ')/$(wc -l < "$E/categories.tsv" | tr -d ' ')/$(wc -l < "$E/findings.tsv" | tr -d ' ')" "0/1/1/1" "exit 0, one header line each"
assert_eq "$summary" "rollup: rows=0 triaged=0 gated=0 error=0 unreadable=0 ungated=0 categories=0 findings=0 advisor_tool_findings=0" "and a zero summary"

echo "# a findings dir that is not there, or an output dir that cannot be written, fails loudly"
"$BIN" "$T/nope" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "a missing findings dir exits 2"
FB="$T/failbin"; mkdir -p "$FB"; printf '#!/bin/sh\nexit 1\n' > "$FB/sort"; chmod +x "$FB/sort"
FO="$T/failout"; mkdir -p "$FO"
PATH="$FB:$PATH" "$BIN" "$F" "$FO" >/dev/null 2>&1; rc=$?
assert_eq "$rc/$(ls "$FO" | wc -l | tr -d ' ')" "1/0" "a failed sort exits 1 and publishes nothing, never an empty tally"
RO="$T/ro"; mkdir -p "$RO"; chmod 555 "$RO"
"$BIN" "$F2" "$RO" >/dev/null 2>&1; rc=$?
chmod 755 "$RO"
if [ "$(id -u)" = 0 ]; then ok "root writes anywhere; the unwritable case is skipped"; else
  assert_eq "$rc" "1" "an unwritable output dir exits 1"
  assert_eq "$(ls "$RO" | wc -l | tr -d ' ')" "0" "and leaves nothing behind"
fi

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
