#!/bin/bash
# Tests for the omp adapter beyond the shared contract (tests/adapter-contract.sh runs
# the contract against it too). What is pinned here is what only omp has: the linearizer
# and its rejection paths, nested-session provenance, and omp-shaped stats.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
A="$REPO/adapters/omp/adapter.sh"
LIN="$REPO/adapters/omp/linearize.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }
assert_rc(){ # $1=got $2=want $3=label
  [ "$1" = "$2" ] && ok "$3" || no "$3 (exit $1, want $2)"
}

[ -x "$A" ] && [ -x "$LIN" ] || { printf '  FAIL - adapters/omp adapter.sh or linearize.sh missing or not executable\n'
                                  printf '\npassed: 0   failed: 1\n'; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/adomp.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

HDR_TITLE='{"type":"title","title":"t","v":1}'
hdr_session(){ printf '{"type":"session","id":"01a00000-0000-7000-8000-0000000000%s","cwd":"%s","timestamp":"2026-01-02T12:00:00.000Z"}\n' "${1:-01}" "${2:-/tmp}"; }
umsg(){ # $1=id $2=parent|null $3=text
  local p; if [ "$2" = null ]; then p=null; else p="\"$2\""; fi
  printf '{"type":"message","id":"%s","parentId":%s,"timestamp":"2026-01-02T12:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"%s"}]}}\n' "$1" "$p" "$3"
}
amsg(){ # $1=id $2=parent $3=text
  printf '{"type":"message","id":"%s","parentId":"%s","timestamp":"2026-01-02T12:00:03.000Z","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$1" "$2" "$3"
}

echo "# linearize: the live branch only"
# Two branches off u1. a2 was appended after a1, so a2 is the live leaf and a1/u2 are
# the abandoned branch. The abandoned work must not reach triage.
S1="$tmp/branched.jsonl"
{ echo "$HDR_TITLE"; hdr_session 01 /tmp
  umsg u1 null "first"
  amsg a1 u1 "abandoned-reply"
  umsg u2 a1 "abandoned-followup"
  amsg a2 u1 "live-reply"
} > "$S1"
"$LIN" "$S1" "$tmp/b.out" 2>/dev/null; assert_rc "$?" 0 "a branched tree linearizes"
assert_eq "$(jq -r 'select(.type=="message") | .id' "$tmp/b.out" | tr '\n' ' ')" "u1 a2 " "only the chain from the live leaf is kept, root first"
if grep -q 'abandoned' "$tmp/b.out"; then no "abandoned branch text must not appear"; else ok "abandoned branch text does not appear"; fi
assert_eq "$(jq -r 'select(.type=="autodream_meta") | "\(.entries) \(.on_path) \(.dropped) \(.source)"' "$tmp/b.out")" "4 2 2 omp" "meta counts entries, kept and dropped"
assert_eq "$(head -1 "$tmp/b.out" | jq -r .type)" "autodream_meta" "the meta record comes first"

echo "# linearize: fails closed, writes nothing"
reject(){ # $1=label $2=file $3=want-rc
  rm -f "$tmp/r.out"
  "$LIN" "$2" "$tmp/r.out" >/dev/null 2>&1; local rc=$?
  assert_rc "$rc" "$3" "$1 is refused"
  if [ -e "$tmp/r.out" ]; then no "$1 left an output file"; else ok "$1 left no output"; fi
  set -- "$tmp"/r.out.tmp*
  if [ -e "$1" ]; then no "a rejected input left a temp"; else ok "a rejected input left no temp"; fi
}
M="$tmp/malformed.jsonl"
{ echo "$HDR_TITLE"; hdr_session 02 /tmp; umsg u1 null a; printf '{"type":"message","id":"x1","parentId":"u1",BROKEN\n'; amsg a1 u1 b; } > "$M"
reject "a malformed JSON line" "$M" 4
D="$tmp/dangling.jsonl"
{ echo "$HDR_TITLE"; hdr_session 03 /tmp; umsg u1 null a; amsg a1 ghost b; } > "$D"
reject "a dangling parentId" "$D" 4
C="$tmp/cycle.jsonl"
{ echo "$HDR_TITLE"; hdr_session 04 /tmp; umsg u1 a1 a; amsg a1 u1 b; } > "$C"
reject "a parentId cycle" "$C" 4
C3="$tmp/cycle3.jsonl"
{ echo "$HDR_TITLE"; hdr_session 05 /tmp; umsg u1 null a; amsg a1 u1 b; umsg u2 a1 c; umsg a3 u2 d; amsg a2 a3 e; } > "$C3"
# u1 is a real root here; make a loop that does not include the root: a1 -> u2 -> a3 -> a1
{ echo "$HDR_TITLE"; hdr_session 05 /tmp; umsg u1 null a; amsg a1 a3 b; umsg u2 a1 c; amsg a3 u2 d; } > "$C3"
reject "a cycle that excludes the root" "$C3" 4
DUP="$tmp/dupid.jsonl"
{ echo "$HDR_TITLE"; hdr_session 15 /tmp; umsg u1 null a; amsg a1 u1 b; umsg u1 a1 c; } > "$DUP"
reject "a duplicated entry id" "$DUP" 4
NOID="$tmp/noid.jsonl"
{ echo "$HDR_TITLE"; hdr_session 06 /tmp; umsg u1 null a; printf '{"type":"message","parentId":"u1","message":{"role":"assistant","content":"x"}}\n'; } > "$NOID"
reject "an entry without an id" "$NOID" 4
NOTOMP="$tmp/claude.jsonl"
printf '{"type":"user","cwd":"/tmp","message":{"content":"hi"}}\n' > "$NOTOMP"
reject "a Claude transcript" "$NOTOMP" 2
EMPTYF="$tmp/empty.jsonl"; : > "$EMPTYF"
reject "an empty file" "$EMPTYF" 2
"$LIN" "$tmp/nope.jsonl" "$tmp/r2.out" >/dev/null 2>&1; assert_rc "$?" 1 "an unreadable input exits 1"
mkdir -p "$tmp/adir"
"$LIN" "$S1" "$tmp/adir" >/dev/null 2>&1; assert_rc "$?" 1 "a directory destination exits 1"
if [ -z "$(ls -A "$tmp/adir")" ]; then ok "nothing planted in a directory destination"; else no "something was planted in the directory destination"; fi
"$LIN" "$S1" >/dev/null 2>&1; assert_rc "$?" 1 "a missing destination argument exits 1"

echo "# linearize: edge shapes that must work"
ONLY="$tmp/onlyhdr.jsonl"
{ echo "$HDR_TITLE"; hdr_session 07 /tmp; } > "$ONLY"
"$LIN" "$ONLY" "$tmp/o.out" >/dev/null 2>&1; assert_rc "$?" 0 "a session with a header and no entries linearizes"
assert_eq "$(wc -l < "$tmp/o.out" | tr -d ' ')" "1" "and carries only the meta record"
LEGACY="$tmp/legacy.jsonl"
{ hdr_session 08 /tmp; umsg u1 null a; amsg a1 u1 b; } > "$LEGACY"
"$LIN" "$LEGACY" "$tmp/l.out" >/dev/null 2>&1; assert_rc "$?" 0 "a legacy file that starts at the header linearizes"
BLANK="$tmp/blank.jsonl"
{ echo "$HDR_TITLE"; hdr_session 09 /tmp; echo; umsg u1 null a; echo "   "; amsg a1 u1 b; } > "$BLANK"
"$LIN" "$BLANK" "$tmp/bl.out" >/dev/null 2>&1; assert_rc "$?" 0 "blank lines are ignored, not parsed"
SPACEPATH="$tmp/dir with space"; mkdir -p "$SPACEPATH"; cp "$S1" "$SPACEPATH/a b.jsonl"
"$LIN" "$SPACEPATH/a b.jsonl" "$tmp/sp.out" >/dev/null 2>&1; assert_rc "$?" 0 "a path with spaces linearizes"

echo "# nested sessions: provenance comes from the path"
NB="$tmp/store/-bucket"; mkdir -p "$NB/2026-01-02T12-00-00-000Z_01a0"
cp "$S1" "$NB/2026-01-02T12-00-00-000Z_01a0.jsonl"
cp "$S1" "$NB/2026-01-02T12-00-00-000Z_01a0/__advisor.jsonl"
cp "$S1" "$NB/2026-01-02T12-00-00-000Z_01a0/Rebase1.jsonl"
"$LIN" "$NB/2026-01-02T12-00-00-000Z_01a0/__advisor.jsonl" "$tmp/adv.out" >/dev/null 2>&1
assert_eq "$(jq -r 'select(.type=="autodream_meta") | "\(.nested) \(.is_advisor)"' "$tmp/adv.out")" "true true" "an advisor child is nested and flagged advisor"
"$LIN" "$NB/2026-01-02T12-00-00-000Z_01a0/Rebase1.jsonl" "$tmp/sub.out" >/dev/null 2>&1
assert_eq "$(jq -r 'select(.type=="autodream_meta") | "\(.nested) \(.is_advisor)"' "$tmp/sub.out")" "true false" "a task subagent child is nested and not an advisor"
"$LIN" "$NB/2026-01-02T12-00-00-000Z_01a0.jsonl" "$tmp/par.out" >/dev/null 2>&1
assert_eq "$(jq -r 'select(.type=="autodream_meta") | "\(.nested) \(.is_advisor)"' "$tmp/par.out")" "false false" "the parent session is neither"
assert_eq "$(jq -r 'select(.type=="autodream_meta") | .parent_session_file | if . == null then "null" else (split("/")|last) end' "$tmp/sub.out")" "2026-01-02T12-00-00-000Z_01a0.jsonl" "a child names its parent file"
# A child whose parent file is gone is still nested: the stamped directory says so.
OB="$tmp/orphan/-bucket"; mkdir -p "$OB/2026-01-02T12-00-00-000Z_dead"
cp "$S1" "$OB/2026-01-02T12-00-00-000Z_dead/__advisor.jsonl"; cp "$S1" "$OB/2026-01-02T12-00-00-000Z_dead/Task1.jsonl"; cp "$S1" "$OB/2026-01-02T12-00-00-000Z_top.jsonl"
for f in 2026-01-02T12-00-00-000Z_dead/__advisor.jsonl 2026-01-02T12-00-00-000Z_dead/Task1.jsonl 2026-01-02T12-00-00-000Z_top.jsonl; do
  "$LIN" "$OB/$f" "$tmp/orph.out" >/dev/null 2>&1
  case "$f" in *_top.jsonl) want=false ;; *) want=true ;; esac
  assert_eq "$(jq -r 'select(.type=="autodream_meta") | .nested' "$tmp/orph.out")" "$want" "nested without a parent file: $f"
done
# enumerate returns children too: they are sessions to triage.
touch -t 202601021200 "$NB"/*.jsonl "$NB"/*/*.jsonl
enum=$("$A" enumerate "$tmp/store" 2026-01-02 2026-01-03 2>/dev/null | tr '\0' '\n' | sort | wc -l | tr -d ' ')
assert_eq "$enum" "3" "enumerate returns the parent and both children"

echo "# project: the header cwd, resolved"
real=$(cd /tmp && pwd -P)
assert_eq "$("$A" project "$S1")" "$real" "project resolves the header cwd (/tmp is a symlink on macOS)"
"$A" normalize "$S1" "$tmp/np.out" >/dev/null 2>&1
assert_eq "$("$A" project "$tmp/np.out")" "$real" "a normalized copy answers the same"
"$A" project "$ONLY" >/dev/null 2>&1; assert_rc "$?" 0 "a header with a cwd and no entries still has a project"
NOCWD="$tmp/nocwd.jsonl"
{ echo "$HDR_TITLE"; printf '{"type":"session","id":"01a00000-0000-7000-8000-000000000010","timestamp":"2026-01-02T12:00:00.000Z"}\n'; umsg u1 null a; } > "$NOCWD"
"$A" project "$NOCWD" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then ok "a header with no cwd has no project"; else no "a header with no cwd must not report a project"; fi
QCWD="$tmp/qcwd.jsonl"; mkdir -p "$tmp/we\"ird"
{ echo "$HDR_TITLE"; printf '{"type":"session","id":"01a00000-0000-7000-8000-000000000011","cwd":"%s","timestamp":"2026-01-02T12:00:00.000Z"}\n' "$tmp/we\\\"ird"; umsg u1 null a; } > "$QCWD"
assert_eq "$("$A" project "$QCWD")" "$(cd "$tmp/we\"ird" && pwd -P)" "a cwd containing a quote survives JSON escaping"

echo "# stats: omp shapes"
"$A" stats "$S1" "$tmp/st.json" >/dev/null 2>&1; assert_rc "$?" 0 "stats on a raw session"
assert_eq "$(jq -r '"\(.user_message_count) \(.is_advisor) \(.nested)"' "$tmp/st.json")" "2 false false" "a raw session counts both user turns and is not an advisor (raw keeps abandoned work)"
"$A" normalize "$S1" "$tmp/sn.out" >/dev/null 2>&1; "$A" stats "$tmp/sn.out" "$tmp/stn.json" >/dev/null 2>&1
assert_eq "$(jq -r '"\(.user_message_count) \(.turn_count)"' "$tmp/stn.json")" "1 2" "a linearized session counts only the live branch"
"$A" normalize "$NB/2026-01-02T12-00-00-000Z_01a0/__advisor.jsonl" "$tmp/an.out" >/dev/null 2>&1; "$A" stats "$tmp/an.out" "$tmp/stadv.json" >/dev/null 2>&1
assert_eq "$(jq -r '"\(.is_advisor) \(.nested)"' "$tmp/stadv.json")" "true true" "an advisor's flags survive the normalized copy, whose filename is a temp"
"$A" stats "$NB/2026-01-02T12-00-00-000Z_01a0/__advisor.jsonl" "$tmp/stadv2.json" >/dev/null 2>&1
assert_eq "$(jq -r .is_advisor "$tmp/stadv2.json")" "true" "a raw advisor is flagged from its own filename"
cp "$S1" "$tmp/__advisor-review.jsonl"; "$A" stats "$tmp/__advisor-review.jsonl" "$tmp/stadv3.json" >/dev/null 2>&1
assert_eq "$(jq -r .is_advisor "$tmp/stadv3.json")" "true" "__advisor-<name>.jsonl is flagged too"
# The path through normalize, which is the one the runner takes: the linearizer and stats
# are two files holding one rule, and a recorded false must not fall back to the temp name.
cp "$S1" "$NB/2026-01-02T12-00-00-000Z_01a0/__advisor-review.jsonl"
"$A" normalize "$NB/2026-01-02T12-00-00-000Z_01a0/__advisor-review.jsonl" "$tmp/advn.out" >/dev/null 2>&1
assert_eq "$(jq -r 'select(.type=="autodream_meta") | .is_advisor' "$tmp/advn.out")" "true" "the linearizer flags __advisor-<name>.jsonl"
"$A" stats "$tmp/advn.out" "$tmp/stadvn.json" >/dev/null 2>&1
assert_eq "$(jq -r .is_advisor "$tmp/stadvn.json")" "true" "and stats keeps it on the normalized copy"
cp "$S1" "$NB/2026-01-02T12-00-00-000Z_01a0/Plain.jsonl"
"$A" normalize "$NB/2026-01-02T12-00-00-000Z_01a0/Plain.jsonl" "$tmp/plainn.out" >/dev/null 2>&1
"$A" stats "$tmp/plainn.out" "$tmp/stplain.json" >/dev/null 2>&1
assert_eq "$(jq -r .is_advisor "$tmp/stplain.json")" "false" "a recorded false stays false even though the temp name is no advisor either"
cp "$S1" "$tmp/my__advisor.jsonl"; "$A" stats "$tmp/my__advisor.jsonl" "$tmp/stadv4.json" >/dev/null 2>&1
assert_eq "$(jq -r .is_advisor "$tmp/stadv4.json")" "false" "the stem is anchored: my__advisor.jsonl is a real session"
SK="$tmp/skills.jsonl"
{ echo "$HDR_TITLE"; hdr_session 12 /tmp; umsg u1 null a
  printf '{"type":"custom_message","id":"c1","parentId":"u1","customType":"skill-prompt","content":"[IMPORTANT: User invoked the \\"review\\" skill; follow it]"}\n'
  printf '{"type":"message","id":"a1","parentId":"c1","message":{"role":"assistant","content":[{"type":"toolCall","name":"manage_skill","arguments":{"name":"new-skill","action":"create"}}]}}\n'
} > "$SK"
"$A" stats "$SK" "$tmp/stsk.json" >/dev/null 2>&1
assert_eq "$(jq -r '"\(.skills_invoked|join(",")) \(.skills_authored|join(","))"' "$tmp/stsk.json")" "review new-skill" "skill invocation and authoring are counted separately"

echo "# stats: isSidechain follows provenance, not a custom record omp never writes (#114, item 2)"
# The old rule keyed off custom/agent and custom/subagent records. omp writes neither, so the flag
# read false for every file and the noise gate's sidechain exemption never applied to a child.
NP="$NB/2026-01-02T12-00-00-000Z_01a0"
"$A" stats "$NP/__advisor.jsonl" "$tmp/sc-adv.json" >/dev/null 2>&1
assert_eq "$(jq -r .isSidechain "$tmp/sc-adv.json")" "true" "a raw advisor child is a sidechain"
"$A" stats "$NP/Rebase1.jsonl" "$tmp/sc-sub.json" >/dev/null 2>&1
assert_eq "$(jq -r '"\(.isSidechain) \(.nested) \(.is_advisor)"' "$tmp/sc-sub.json")" "true true false" "a raw task child is a sidechain and nested, not an advisor"
"$A" normalize "$NP/Rebase1.jsonl" "$tmp/sc-subn.out" >/dev/null 2>&1; "$A" stats "$tmp/sc-subn.out" "$tmp/sc-subn.json" >/dev/null 2>&1
assert_eq "$(jq -r .isSidechain "$tmp/sc-subn.json")" "true" "and so is its linearized copy, whose temp name says nothing"
"$A" stats "$NB/2026-01-02T12-00-00-000Z_01a0.jsonl" "$tmp/sc-par.json" >/dev/null 2>&1
assert_eq "$(jq -r '"\(.isSidechain) \(.nested)"' "$tmp/sc-par.json")" "false false" "the parent session is not a sidechain"
OSD="$tmp/orph-stats/-bucket/2026-01-02T12-00-00-000Z_dead"; mkdir -p "$OSD"; cp "$S1" "$OSD/Task1.jsonl"
"$A" stats "$OSD/Task1.jsonl" "$tmp/sc-orph.json" >/dev/null 2>&1
assert_eq "$(jq -r '"\(.isSidechain) \(.nested)"' "$tmp/sc-orph.json")" "true true" "a raw child whose parent file is gone is still a sidechain"
PH="$tmp/phantom.jsonl"
{ echo "$HDR_TITLE"; hdr_session 30 /tmp; umsg u1 null a; printf '{"type":"custom","id":"x1","parentId":"u1","customType":"agent","data":{}}\n'; } > "$PH"
"$A" stats "$PH" "$tmp/sc-ph.json" >/dev/null 2>&1
assert_eq "$(jq -r .isSidechain "$tmp/sc-ph.json")" "false" "a custom record named agent does not make a main session a sidechain"

echo "# stats: attribution separates harness-injected turns from human ones (#114, item 3)"
UM(){ # $1=id $2=parent $3=attribution $4=epoch-ish seconds suffix
  printf '{"type":"message","id":"%s","parentId":"%s","timestamp":"2026-01-02T12:00:%s.000Z","message":{"role":"user","attribution":"%s","content":[{"type":"text","text":"t"}]}}\n' "$1" "$2" "$4" "$3"
}
ATT="$tmp/attrib.jsonl"
{ echo "$HDR_TITLE"; hdr_session 31 /tmp; UM u1 null user 10; UM u2 u1 agent 20; UM u3 u2 agent 30; UM u4 u3 user 40; } > "$ATT"
"$A" stats "$ATT" "$tmp/att.json" >/dev/null 2>&1
assert_eq "$(jq -r .user_message_count "$tmp/att.json")" "2" "agent-attributed user messages are not human turns"
assert_eq "$(jq -r '.user_turn_timestamps | length' "$tmp/att.json")" "2" "and carry no overlap timestamps"
assert_eq "$(jq -r .turn_count "$tmp/att.json")" "4" "turn_count still counts every user and assistant message"
UNATT="$tmp/unattrib.jsonl"
{ echo "$HDR_TITLE"; hdr_session 32 /tmp; umsg u1 null a; umsg u2 u1 b; } > "$UNATT"
"$A" stats "$UNATT" "$tmp/unatt.json" >/dev/null 2>&1
assert_eq "$(jq -r .user_message_count "$tmp/unatt.json")" "2" "a message with no attribution field is human, as in every file before the field existed"
AADV="$tmp/attr-adv/__advisor.jsonl"; mkdir -p "$tmp/attr-adv"
{ echo "$HDR_TITLE"; hdr_session 33 /tmp; UM u1 null agent 10; UM u2 u1 agent 20; } > "$AADV"
"$A" stats "$AADV" "$tmp/attadv.json" >/dev/null 2>&1
assert_eq "$(jq -r '"\(.user_message_count) \(.isSidechain)"' "$tmp/attadv.json")" "0 true" "an advisor reads zero human turns and is exempt from the gate by provenance"

echo "# stats: tool calls, from start records when the file has them and from toolCall blocks when it does not"
TC() { printf '{"type":"message","id":"%s","parentId":"%s","message":{"role":"assistant","content":[{"type":"toolCall","id":"c%s","name":"%s","arguments":{}}]}}\n' "$1" "$2" "$1" "$3"; }
TS() { printf '{"type":"custom","id":"s%s","parentId":"%s","customType":"tool_execution_start","data":{"toolName":"%s"}}\n' "$1" "$2" "$3"; }
# An advisor transcript: toolCall blocks, no start records (measured: 144 of 410 advisor files).
ADV="$tmp/adv-calls/__advisor.jsonl"; mkdir -p "$tmp/adv-calls"
{ echo "$HDR_TITLE"; hdr_session 20 /tmp; umsg u1 null a; TC t1 u1 read; TC t2 t1 grep; TC t3 t2 read; TC t4 t3 glob; } > "$ADV"
"$A" stats "$ADV" "$tmp/stcalls-adv.json" >/dev/null 2>&1
assert_eq "$(jq -r .tool_call_count "$tmp/stcalls-adv.json")" "4" "an advisor's toolCall blocks are counted"
assert_eq "$(jq -r '.tools_used | join(",")' "$tmp/stcalls-adv.json")" "glob,grep,read" "and named, once each"
"$A" normalize "$ADV" "$tmp/advcalls.out" >/dev/null 2>&1; "$A" stats "$tmp/advcalls.out" "$tmp/stcalls-advn.json" >/dev/null 2>&1
assert_eq "$(jq -r .tool_call_count "$tmp/stcalls-advn.json")" "4" "the count survives the linearized copy the runner reads"
# A main session records each call both ways; it must read the start records only, not twice.
MAIN="$tmp/main-calls.jsonl"
{ echo "$HDR_TITLE"; hdr_session 21 /tmp; umsg u1 null a; TS 1 u1 bash; TC t1 s1 bash; TS 2 t1 read; TC t2 s2 read; } > "$MAIN"
"$A" stats "$MAIN" "$tmp/stcalls-main.json" >/dev/null 2>&1
assert_eq "$(jq -r .tool_call_count "$tmp/stcalls-main.json")" "2" "a main session with both shapes counts each call once"
assert_eq "$(jq -r '.tools_used | join(",")' "$tmp/stcalls-main.json")" "bash,read" "and names come from the start records"
# Start records alone (the documented shape) still count, and a session with neither reads zero.
STARTS="$tmp/starts-only.jsonl"
{ echo "$HDR_TITLE"; hdr_session 22 /tmp; umsg u1 null a; TS 1 u1 bash; TS 2 s1 read; TS 3 s2 read; } > "$STARTS"
"$A" stats "$STARTS" "$tmp/stcalls-starts.json" >/dev/null 2>&1
assert_eq "$(jq -r .tool_call_count "$tmp/stcalls-starts.json")" "3" "start records alone are still counted"
# The rule is per file, not per call: one start record means the blocks are not counted. A
# transcript with a start record and an unmatched block (not seen in the wild as a partial
# write, but 8 of 577 main transcripts hold blocks with no start record) reads the start
# records only, exactly as it did before the fallback existed.
MIXED="$tmp/mixed-calls.jsonl"
{ echo "$HDR_TITLE"; hdr_session 25 /tmp; umsg u1 null a; TS 1 u1 bash; TC t1 s1 bash; TC t2 t1 grep; } > "$MIXED"
"$A" stats "$MIXED" "$tmp/stcalls-mixed.json" >/dev/null 2>&1
assert_eq "$(jq -r '"\(.tool_call_count) \(.tools_used|join(","))"' "$tmp/stcalls-mixed.json")" "1 bash" "a start record plus an unmatched block reads the start records only"
# An advisor that only hit the wall: every call is answered with `Tool "bash" not available`.
# Those are attempts, not calls made, and must not clear the noise gate's tool_call_count >= 5.
TR() { printf '{"type":"message","id":"r%s","parentId":"%s","message":{"role":"toolResult","toolCallId":"c%s","toolName":"%s","isError":true,"content":[{"type":"text","text":"Tool \\"%s\\" not available"}]}}\n' "$1" "$2" "$1" "$3" "$3"; }
REJ="$tmp/rejected-calls/__advisor.jsonl"; mkdir -p "$tmp/rejected-calls"
{ echo "$HDR_TITLE"; hdr_session 26 /tmp; umsg u1 null a
  TC t1 u1 bash; TR t1 t1 bash; TC t2 r1 bash; TR t2 t2 bash; TC t3 r2 bash; TR t3 t3 bash
  TC t4 r3 bash; TR t4 t4 bash; TC t5 r4 bash; TR t5 t5 bash; } > "$REJ"
"$A" stats "$REJ" "$tmp/stcalls-rej.json" >/dev/null 2>&1
assert_eq "$(jq -r '"\(.tool_call_count) \(.tools_used|length)"' "$tmp/stcalls-rej.json")" "0 0" "five rejected bash attempts are not five tool calls"
# Two accepted read calls and three rejected ones: only the accepted calls count.
HALF="$tmp/half-rejected/__advisor.jsonl"; mkdir -p "$tmp/half-rejected"
{ echo "$HDR_TITLE"; hdr_session 27 /tmp; umsg u1 null a
  TC t1 u1 read; TC t2 t1 read; TC t3 t2 bash; TR t3 t3 bash; TC t4 r3 write; TR t4 t4 write; TC t5 r4 bash; TR t5 t5 bash; } > "$HALF"
"$A" stats "$HALF" "$tmp/stcalls-half.json" >/dev/null 2>&1
assert_eq "$(jq -r '"\(.tool_call_count) \(.tools_used|join(","))"' "$tmp/stcalls-half.json")" "2 read" "only the calls the toolset accepted count, and only those are named"
# A real error from an available tool is still a call.
ERRC="$tmp/err-call/__advisor.jsonl"; mkdir -p "$tmp/err-call"
{ echo "$HDR_TITLE"; hdr_session 28 /tmp; umsg u1 null a; TC t1 u1 read
  printf '{"type":"message","id":"rt1","parentId":"t1","message":{"role":"toolResult","toolCallId":"ct1","toolName":"read","isError":true,"content":[{"type":"text","text":"ENOENT: no such file"}]}}\n'; } > "$ERRC"
"$A" stats "$ERRC" "$tmp/stcalls-err.json" >/dev/null 2>&1
assert_eq "$(jq -r .tool_call_count "$tmp/stcalls-err.json")" "1" "a failed read is still a call"
NOCALLS="$tmp/no-calls.jsonl"
{ echo "$HDR_TITLE"; hdr_session 23 /tmp; umsg u1 null a; } > "$NOCALLS"
"$A" stats "$NOCALLS" "$tmp/stcalls-none.json" >/dev/null 2>&1
assert_eq "$(jq -r '"\(.tool_call_count) \(.tools_used|length)"' "$tmp/stcalls-none.json")" "0 0" "a session that called nothing reads zero"
# A message whose content is a plain string, or a toolCall with no name, must not break the count.
ODD="$tmp/odd-calls.jsonl"
{ echo "$HDR_TITLE"; hdr_session 24 /tmp; umsg u1 null a
  printf '{"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","content":"plain text"}}\n'
  printf '{"type":"message","id":"a2","parentId":"a1","message":{"role":"assistant","content":[{"type":"toolCall","id":"c9"}]}}\n'
} > "$ODD"
"$A" stats "$ODD" "$tmp/stcalls-odd.json" >/dev/null 2>&1; assert_rc "$?" 0 "string content and a nameless toolCall do not break stats"
assert_eq "$(jq -r '"\(.tool_call_count) \(.tools_used|length)"' "$tmp/stcalls-odd.json")" "1 0" "the nameless call counts but names nothing"

echo "# is-self: omp's own worker transcripts"
SELF="$tmp/self.jsonl"
{ echo "$HDR_TITLE"; hdr_session 13 /tmp; umsg u1 null "Session transcript to analyze (literal absolute path): /x"; } > "$SELF"
"$A" is-self "$SELF" >/dev/null 2>&1; assert_rc "$?" 0 "a session whose first turn is autodream's prompt is ours"
"$A" is-self "$S1" >/dev/null 2>&1; assert_rc "$?" 1 "an ordinary omp session is not"
DISC="$tmp/discuss.jsonl"
{ echo "$HDR_TITLE"; hdr_session 14 /tmp; umsg u1 null "hello"; umsg u2 u1 "Session transcript to analyze (literal absolute path): /x"; } > "$DISC"
"$A" is-self "$DISC" >/dev/null 2>&1; assert_rc "$?" 1 "a session that only mentions the prompt later is not (anchored to the first turn)"

echo "# slim: reuses the shared slimmer on a linearized copy"
"$A" slim "$tmp/sn.out" "$tmp/slim.out" >/dev/null 2>&1; assert_rc "$?" 0 "slim accepts a linearized transcript"
if [ -s "$tmp/slim.out" ]; then ok "slim wrote output"; else no "slim wrote output"; fi

echo "# skills-inventory"
HOME_FAKE="$tmp/home"; mkdir -p "$HOME_FAKE/.agents/skills/alpha" "$HOME_FAKE/.agents/skills/off"
printf -- '---\nname: alpha\ndescription: does alpha things\n---\nbody\n' > "$HOME_FAKE/.agents/skills/alpha/SKILL.md"
printf -- '---\nname: off\ndescription: disabled one\nenabled: false\n---\nbody\n' > "$HOME_FAKE/.agents/skills/off/SKILL.md"
inv=$(HOME="$HOME_FAKE" "$A" skills-inventory 2>/dev/null); rc=$?
assert_rc "$rc" 0 "skills-inventory exits 0"
assert_eq "$(printf '%s\n' "$inv" | cut -f1 | tr '\n' ' ')" "alpha " "an enabled skill is listed and a disabled one is not"
assert_eq "$(printf '%s\n' "$inv" | cut -f2)" "does alpha things" "the description follows a TAB"
emptyinv=$(HOME="$tmp/nohome" "$A" skills-inventory 2>/dev/null); rc=$?
assert_rc "$rc" 0 "an empty skill surface is a valid empty inventory"
assert_eq "$emptyinv" "" "and prints nothing"

echo "# unknown subcommand and arity"
"$A" bogus >/dev/null 2>&1; assert_rc "$?" 2 "an unknown subcommand exits 2"
"$A" normalize "$S1" >/dev/null 2>&1; assert_rc "$?" 2 "normalize with one argument is a usage error, not a skip"
"$A" stats "$S1" >/dev/null 2>&1; assert_rc "$?" 2 "stats with one argument is a usage error"

echo "# l1-argv reproduces omp-autodream's worker invocation"
OLD_SYS="Headless triage worker. Read the session transcript and write exactly one findings JSON object, via the Write tool, to the literal output path given on line 2 of the prompt. Those paths are literal strings, not shell variables — never \$-expand them. Print only the literal word done and exit."
printf '%s\0' /opt/test/omp --allow-home -p --approval-mode yolo --no-session --config /opt/test/overlay.yml \
  --model deepseek/deepseek-flash --tools=Read,Write --append-system-prompt "$OLD_SYS" > "$tmp/old-argv"
OMP_BIN=/opt/test/omp NO_ADVISOR_CFG=/opt/test/overlay.yml "$A" l1-argv deepseek/deepseek-flash > "$tmp/new-argv"
if cmp -s "$tmp/old-argv" "$tmp/new-argv"; then ok "the omp L1 argv is byte for byte omp-autodream's"
else no "the omp L1 argv is byte for byte omp-autodream's"; fi
# The overlay defaults to the one beside the adapter, and it is the file that turns recall off.
ov=$(OMP_BIN=/opt/test/omp "$A" l1-argv m | tr '\0' '\n' | sed -n '/^--config$/{n;p;}')
assert_eq "$(basename "$ov")" "l1-no-advisor.yml" "the overlay defaults to the adapter's own"
if grep -q 'autoRecall: false' "$ov" && grep -q 'enabled: false' "$ov"; then ok "the overlay turns off recall and the advisor"
else no "the overlay turns off recall and the advisor"; fi
assert_eq "$(OMP_BIN=/opt/pinned/omp "$A" engine-bin)" "/opt/pinned/omp" "an explicit OMP_BIN wins"
mkdir -p "$tmp/fakehome/.bun/bin"; printf '#!/bin/sh\n' > "$tmp/fakehome/.bun/bin/omp"; chmod +x "$tmp/fakehome/.bun/bin/omp"
assert_eq "$(env -u OMP_BIN HOME="$tmp/fakehome" PATH=/usr/bin:/bin "$A" engine-bin)" "$tmp/fakehome/.bun/bin/omp" "with no PATH omp, a known install location is found"
# The absolute candidates are real paths on a developer machine, so the bare-name fallback is
# only observable on a host that has none of them. Asserting it unconditionally made the suite
# depend on where omp happens to be installed.
if [ ! -x /opt/homebrew/bin/omp ] && [ ! -x /usr/local/bin/omp ]; then
  assert_eq "$(env -u OMP_BIN HOME="$tmp/nohome" PATH=/usr/bin:/bin "$A" engine-bin)" "omp" "with nothing found it falls back to the bare name"
else
  ok "the bare-name fallback is not observable here: omp is installed at a candidate path"
fi
assert_eq "$("$A" l1-env | wc -c | tr -d ' ')" "0" "omp needs no environment for its L1 worker"

echo "# warmup-argv reproduces omp-autodream's warmup invocation"
printf '%s\0' /opt/test/omp --allow-home -p --approval-mode yolo --no-session --config /opt/test/overlay.yml \
  --model deepseek/deepseek-flash --append-system-prompt "Reply with the single word ok and exit." > "$tmp/old-w"
OMP_BIN=/opt/test/omp NO_ADVISOR_CFG=/opt/test/overlay.yml "$A" warmup-argv deepseek/deepseek-flash > "$tmp/new-w"
if cmp -s "$tmp/old-w" "$tmp/new-w"; then ok "the omp warmup argv is byte for byte omp-autodream's"
else no "the omp warmup argv is byte for byte omp-autodream's"; fi

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
