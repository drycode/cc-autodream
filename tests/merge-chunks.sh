#!/bin/bash
# Unit tests for bin/merge-chunks.sh: judge a chunk answer, and merge the answers for one session
# into the one findings JSON that Layer 2 already reads.
#
# Why this exists. A worker's answer is untrusted input, and the merge is the place a session
# stops being "some chunks" and becomes "the session". The properties worth a test are the ones a
# smoke test cannot see: an error or malformed answer must never be merged around, the merge must
# be total over wrongly typed fields, and the fields must mean what the header says when the
# answers disagree.
#
# Contract:
#   merge-chunks.sh --check FILE                     exit 0 usable, 1 not
#   merge-chunks.sh --session PATH [--elided N] FILE...   merged object on stdout; 2 usage; 3 refused

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
MG="$REPO/bin/merge-chunks.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

[ -x "$MG" ] || {
  printf '  FAIL - bin/merge-chunks.sh missing or not executable\n'
  printf '\npassed: 0   failed: 1\n'; exit 1; }
command -v jq >/dev/null 2>&1 || {
  printf '  ok   - jq not installed; this suite is skipped\n'
  printf '\npassed: 1   failed: 0\n'; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/mgtest.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

rc_of(){ "$@" >/dev/null 2>&1; printf '%s' "$?"; }
w(){ printf '%s' "$2" > "$TMP/$1"; }   # w NAME CONTENT
J(){ jq -r "$1" "$TMP/out.json" 2>/dev/null; }

echo "# check: a usable answer is exactly one object, no error key, a findings array"
w ok.json '{"session_path":"x","findings":[]}'
w ok2.json '{"session_path":"x","findings":[{"category":"c","severity":"low","what":"w"}]}'
assert_eq "$(rc_of "$MG" --check "$TMP/ok.json")" "0" "an object with an empty findings array is usable"
assert_eq "$(rc_of "$MG" --check "$TMP/ok2.json")" "0" "and one with findings"
w err.json '{"session_path":"x","error":"could not read","findings":[]}'
assert_eq "$(rc_of "$MG" --check "$TMP/err.json")" "1" "the error object the prompt tells a worker to write is not usable"
w errnull.json '{"session_path":"x","error":null,"findings":[]}'
assert_eq "$(rc_of "$MG" --check "$TMP/errnull.json")" "1" "an error key holding null is still an error key (the runner says has(error))"
w errempty.json '{"session_path":"x","error":"","findings":[]}'
assert_eq "$(rc_of "$MG" --check "$TMP/errempty.json")" "1" "and so is an empty-string one"
w nofind.json '{"session_path":"x"}'
assert_eq "$(rc_of "$MG" --check "$TMP/nofind.json")" "1" "an object with no findings is not usable"
w bare.json '{}'
assert_eq "$(rc_of "$MG" --check "$TMP/bare.json")" "1" "a bare {} is not usable"
w strfind.json '{"findings":"oops"}'
assert_eq "$(rc_of "$MG" --check "$TMP/strfind.json")" "1" "findings a string is not usable (jq -e .findings alone would call it truthy)"
w nullfind.json '{"findings":null}'
assert_eq "$(rc_of "$MG" --check "$TMP/nullfind.json")" "1" "findings null is not usable"
w objfind.json '{"findings":{"a":1}}'
assert_eq "$(rc_of "$MG" --check "$TMP/objfind.json")" "1" "findings an object is not usable"
w arr.json '[{"findings":[]}]'
assert_eq "$(rc_of "$MG" --check "$TMP/arr.json")" "1" "a top-level array is not usable"
w str.json '"done"'
assert_eq "$(rc_of "$MG" --check "$TMP/str.json")" "1" "a bare string is not usable"
printf '{"error":"x","findings":[]}\n{"findings":[]}\n' > "$TMP/errfirst.json"
assert_eq "$(rc_of "$MG" --check "$TMP/errfirst.json")" "1" "an error object FOLLOWED by a good one is not usable (the last value alone would pass)"
printf '{"findings":[]}\n{"error":"x","findings":[]}\n' > "$TMP/errlast.json"
assert_eq "$(rc_of "$MG" --check "$TMP/errlast.json")" "1" "a good object followed by an error object is not usable"
printf '{"findings":[]}\n{"findings":[]}\n' > "$TMP/two.json"
assert_eq "$(rc_of "$MG" --check "$TMP/two.json")" "1" "two good objects in one file are not usable (a worker wrote twice)"
w trunc.json '{"session_path":"x","findings":[{"category":'
assert_eq "$(rc_of "$MG" --check "$TMP/trunc.json")" "1" "truncated JSON is not usable"
w garbage.json 'this is not json'
assert_eq "$(rc_of "$MG" --check "$TMP/garbage.json")" "1" "prose is not usable"
: > "$TMP/empty.json"
assert_eq "$(rc_of "$MG" --check "$TMP/empty.json")" "1" "an empty file is not usable"
assert_eq "$(rc_of "$MG" --check "$TMP/missing.json")" "1" "a missing file is not usable"
assert_eq "$(rc_of "$MG" --check)" "2" "--check with no file is a usage error"

echo "# merge: field semantics when the answers disagree"
w c1.json '{"session_path":"/tmp/c1","project":"p1","started_at":"2026-10-01T09:00:00Z","turn_count":42,"tools_used":["Bash"],"underlying_goal":"goal-1","outcome":"partially_achieved","notable_initiatives":["a","b"],"instructions_given":["i1"],"satisfaction_signals":{"happy":1,"satisfied":0,"dissatisfied":0,"frustrated":0},"findings":[{"category":"permission_prompt","severity":"low","what":"only-in-1","evidence_excerpt":"e"},{"category":"other","severity":"high","what":"shared","evidence_excerpt":"first copy"}]}'
w c2.json '{"session_path":"/tmp/c2","project":"p2","turn_count":42,"underlying_goal":"goal-2","outcome":"not_achieved","notable_initiatives":["b","c"],"instructions_given":["i1","i2","i3"],"satisfaction_signals":{"happy":0,"satisfied":2,"dissatisfied":0,"frustrated":0},"findings":[{"category":"other","severity":"high","what":"shared","evidence_excerpt":"second copy"},{"category":"tool_loop","severity":"medium","what":"only-in-2","evidence_excerpt":"e"}]}'
w c3.json '{"session_path":"/tmp/c3","underlying_goal":null,"outcome":"fully_achieved","notable_initiatives":["d"],"instructions_given":["i4"],"findings":[]}'
"$MG" --session /real/session.jsonl --elided 2 "$TMP/c1.json" "$TMP/c2.json" "$TMP/c3.json" > "$TMP/out.json"; rc=$?
assert_eq "$rc" "0" "three usable chunks merge"
assert_eq "$(jq -s length "$TMP/out.json")" "1" "to exactly one JSON value"
assert_eq "$(J .session_path)" "/real/session.jsonl" "session_path is the original transcript, never a chunk file"
assert_eq "$(J .underlying_goal)" "goal-1" "the goal is the first non-null one"
assert_eq "$(J .outcome)" "fully_achieved" "the outcome is the last chunk's"
assert_eq "$(J .project)" "p1" "stats and identity fields come from the first chunk"
assert_eq "$(J .started_at)" "2026-10-01T09:00:00Z" "including started_at"
assert_eq "$(J .turn_count)" "42" "and the copied sidecar counts are not summed"
assert_eq "$(J '.notable_initiatives | join(",")')" "a,b,c,d" "notable_initiatives is an order-preserving union"
assert_eq "$(J '.instructions_given | join(",")')" "i1,i2,i3" "instructions_given is a union capped at 3 (the schema cap)"
assert_eq "$(J .satisfaction_signals.happy)" "1" "satisfaction signals are summed (happy)"
assert_eq "$(J .satisfaction_signals.satisfied)" "2" "and (satisfied)"
assert_eq "$(J '.findings | length')" "3" "findings are the union with the exact duplicate dropped"
assert_eq "$(J '.findings | map(.severity) | join(",")')" "high,medium,low" "most severe first"
assert_eq "$(J '[.findings[] | select(.what == "shared")] | .[0].evidence_excerpt')" "first copy" "a duplicate keeps the earlier chunk's copy"
assert_eq "$(J '[.findings[] | select(.what == "only-in-2")] | .[0].chunk')" "2" "each finding is tagged with its chunk"
assert_eq "$(J '.meta.chunks')" "3" "meta records how many chunks answered"
assert_eq "$(J '.meta.chunks_elided')" "2" "and how many the chunker dropped"
assert_eq "$(J 'has("error")')" "false" "and the merged object carries no error"

echo "# merge: a duplicate needs the same category AND the same what"
w d1.json '{"findings":[{"category":"a","severity":"low","what":"x"}]}'
w d2.json '{"findings":[{"category":"b","severity":"low","what":"x"},{"category":"a","severity":"low","what":"y"}]}'
"$MG" --session /s "$TMP/d1.json" "$TMP/d2.json" > "$TMP/out.json"
assert_eq "$(J '.findings | length')" "3" "the same what under another category, or another what, is kept"

echo "# merge: findings with neither a category nor a what are never merged into one"
w m1.json '{"session_path":"x","findings":[{"severity":"high","evidence_excerpt":"A"}]}'
w m2.json '{"session_path":"x","findings":[{"severity":"low","evidence_excerpt":"B"}]}'
"$MG" --session /s "$TMP/m1.json" "$TMP/m2.json" > "$TMP/out.json" 2>/dev/null
assert_eq "$(J '.findings | length')" "2" "two different keyless findings both survive"

echo "# merge: a duplicate seen at two severities keeps the higher one"
w sv1.json '{"session_path":"x","findings":[{"category":"c","severity":"low","what":"same"}]}'
w sv2.json '{"session_path":"x","findings":[{"category":"c","severity":"high","what":"same"}]}'
"$MG" --session /s "$TMP/sv1.json" "$TMP/sv2.json" > "$TMP/out.json" 2>/dev/null
assert_eq "$(J '.findings | length')" "1" "the two are one finding"
assert_eq "$(J '.findings[0].severity')" "high" "and it is the high one, not the first chunk's low"
assert_eq "$(J '.findings[0].chunk')" "2" "tagged with the chunk that rated it high"

echo "# merge: an empty goal or outcome does not mask a real one"
w g1.json '{"session_path":"x","underlying_goal":"","outcome":"fully_achieved","findings":[]}'
w g2.json '{"session_path":"x","underlying_goal":"ship it","outcome":"","findings":[]}'
"$MG" --session /s "$TMP/g1.json" "$TMP/g2.json" > "$TMP/out.json" 2>/dev/null
assert_eq "$(J '.underlying_goal')" "ship it" "the goal is the first non-empty one"
assert_eq "$(J '.outcome')" "fully_achieved" "the outcome is the last non-empty one"

echo "# merge: findings are capped at 10, keeping the most severe"
{ printf '{"findings":['
  for i in 1 2 3 4 5 6 7 8; do printf '{"category":"c","severity":"low","what":"low-%d"},' "$i"; done
  printf '{"category":"c","severity":"high","what":"high-a"}]}'; } > "$TMP/many1.json"
{ printf '{"findings":['
  for i in 1 2 3 4 5; do printf '{"category":"c","severity":"medium","what":"med-%d"},' "$i"; done
  printf '{"category":"c","severity":"high","what":"high-b"}]}'; } > "$TMP/many2.json"
"$MG" --session /s "$TMP/many1.json" "$TMP/many2.json" > "$TMP/out.json"
assert_eq "$(J '.findings | length')" "10" "fifteen distinct findings come out as ten"
assert_eq "$(J '.findings | map(select(.severity == "high")) | length')" "2" "both high findings survive the cap"
assert_eq "$(J '.findings | map(select(.severity == "medium")) | length')" "5" "and all five medium ones"
assert_eq "$(J '.findings | map(select(.severity == "low")) | length')" "3" "so what was cut is five of the eight low ones"

echo "# merge: one chunk merges to itself, retagged to the real session"
"$MG" --session /real/one.jsonl "$TMP/c1.json" > "$TMP/out.json"
assert_eq "$(J .session_path)" "/real/one.jsonl" "session_path is rewritten"
assert_eq "$(J '.findings | length')" "2" "its findings are all there"
assert_eq "$(J '.meta.chunks')" "1" "and meta says one chunk"
assert_eq "$(J '.meta.chunks_elided')" "0" "and none elided by default"

echo "# merge: wrongly typed fields are ignored, not fatal"
w t1.json '{"underlying_goal":123,"outcome":["x"],"notable_initiatives":"not a list","instructions_given":{"a":1},"satisfaction_signals":"none","findings":[null,"str",7,{"category":"c","severity":5,"what":"typed"},{"category":"c","severity":"low","what":"fine"}]}'
w t2.json '{"underlying_goal":"real goal","outcome":"mostly_achieved","notable_initiatives":["ok",3,null],"instructions_given":["a",{"b":1}],"satisfaction_signals":{"happy":"lots","satisfied":4},"findings":[]}'
"$MG" --session /s "$TMP/t1.json" "$TMP/t2.json" > "$TMP/out.json"; rc=$?
assert_eq "$rc" "0" "a chunk full of wrongly typed fields still merges"
assert_eq "$(J .underlying_goal)" "real goal" "a non-string goal is skipped for the next chunk's"
assert_eq "$(J .outcome)" "mostly_achieved" "and a non-string outcome for the last real one"
assert_eq "$(J '.notable_initiatives | join(",")')" "ok" "only strings survive in a list"
assert_eq "$(J '.instructions_given | join(",")')" "a" "and in instructions_given"
assert_eq "$(J .satisfaction_signals.satisfied)" "4" "a numeric signal is summed"
assert_eq "$(J .satisfaction_signals.happy)" "0" "and a non-numeric one counts as zero"
assert_eq "$(J '.findings | length')" "2" "only object findings survive; a non-string severity sorts last"
assert_eq "$(J '.findings[-1].what')" "typed" "the one with severity 5 is after the one with a real severity"

echo "# merge: it refuses to merge around a bad chunk"
for bad in err.json errnull.json nofind.json bare.json strfind.json errfirst.json two.json garbage.json empty.json missing.json; do
  out=$("$MG" --session /s "$TMP/c1.json" "$TMP/$bad" "$TMP/c3.json" 2>/dev/null); rc=$?
  assert_eq "$rc/${#out}" "3/0" "chunk 2 = $bad -> exit 3 and nothing on stdout"
done
out=$("$MG" --session /s "$TMP/err.json" "$TMP/c1.json" 2>/dev/null); rc=$?
assert_eq "$rc/${#out}" "3/0" "the FIRST chunk being bad refuses too"
out=$("$MG" --session /s "$TMP/c1.json" "$TMP/err.json" 2>/dev/null); rc=$?
assert_eq "$rc/${#out}" "3/0" "so does the LAST"
out=$("$MG" --session /s "$TMP/err.json" 2>/dev/null); rc=$?
assert_eq "$rc/${#out}" "3/0" "and a lone error answer is not a merged session (no error object is manufactured)"

echo "# merge: usage"
assert_eq "$(rc_of "$MG")" "2" "no arguments exit 2"
assert_eq "$(rc_of "$MG" --session /s)" "2" "no chunk files exit 2"
assert_eq "$(rc_of "$MG" "$TMP/c1.json")" "2" "no --session exits 2"
assert_eq "$(rc_of "$MG" --session /s --elided abc "$TMP/c1.json")" "2" "a non-numeric --elided exits 2"
assert_eq "$(rc_of "$MG" --bogus --session /s "$TMP/c1.json")" "2" "an unknown option exits 2"
"$MG" --session /s --elided 08 "$TMP/c1.json" > "$TMP/out.json" 2>/dev/null
assert_eq "$(J '.meta.chunks_elided')" "8" "--elided 08 is decimal, not an invalid octal"

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
