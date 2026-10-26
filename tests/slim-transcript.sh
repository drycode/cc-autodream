#!/bin/bash
# Unit tests for bin/slim-transcript.sh's jq pre-pass.
#
# The pre-pass handles two transcript schemas that store tool output in
# completely different places, and it fails SILENTLY when it gets one wrong: jq
# exits 0 and writes a valid file, so the shell fallback never fires and the
# line-based pass downstream happily truncates an OMP envelope at '"content":['.
# The worker then receives ID soup and returns no findings, which looks exactly
# like a quiet day.
#
# So these assertions are about what SURVIVES the strip, not about whether the
# script exits 0. Every one of them passed a smoke test before it was written.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$REPO/bin/portable.sh"
SLIM="$REPO/bin/slim-transcript.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }
has(){ case "$2" in *"$1"*) ok "$3" ;; *) no "$3 (got: [$2])" ;; esac; }
# An EMPTY haystack is a failure, not a pass. Every `hasnt` in this file was
# vacuous whenever the slimmer produced no output at all — the strongest possible
# regression, a slimmer that emits nothing, satisfied all of them. The guard lives
# in the helper because the defect is the helper's, not any one call site's.
# `has` and `jq_is` already fail on empty input by construction.
hasnt(){
  [ -n "$2" ] || { no "$3 (nothing to check: the slimmer produced no output)"; return; }
  case "$2" in *"$1"*) no "$3 (found [$1] in: [$2])" ;; *) ok "$3" ;; esac
}
# Type and presence claims go through jq, never through a substring match.
# The first version asserted `hasnt '\\"file\\"'` to mean "not stringified" —
# jq emits ONE backslash there, so the pattern could never match and the
# assertion passed whatever the code did. It survived the red-then-green check
# for the same reason. An assertion that cannot fail is decoration.
jq_is(){ # $1=slimmer output (may be several lines) $2=jq expr $3=want $4=msg
  local rec g rc
  rec=$(printf '%s\n' "$1" | grep -m1 '^{')
  # jq's exit status is checked. Ignoring it meant a record that produced the
  # expected value and THEN hit malformed bytes still passed.
  g=$(printf '%s' "$rec" | jq -r "$2" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || { no "$4 (jq exit $rc on: [$rec])"; return; }
  assert_eq "$g" "$3" "$4"
}

[ -x "$SLIM" ] || {
  printf '  FAIL - bin/slim-transcript.sh missing or not executable\n'
  printf '\npassed: 0   failed: 1\n'; exit 1; }
command -v jq >/dev/null 2>&1 || {
  printf '  ok   - jq not installed; the pre-pass is skipped and so is this suite\n'
  printf '\npassed: 1   failed: 0\n'; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/slimtest.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Run the slimmer over one JSONL record and print the result. head/tail/cap are
# raised well clear so ONLY the jq pre-pass is under test; the line-based pass is
# a separate mechanism and would otherwise mask what the pre-pass did.
slim_one() { # $1=json record -> slimmed record on stdout, or nothing on failure
  printf '%s\n' "$1" > "$TMP/in.jsonl"
  # Remove the destination FIRST and check the exit status. Without both, a
  # failed invocation left the previous case's output sitting at $TMP/out.txt
  # and the grep below returned THAT — so a broken slimmer would be asserted
  # against a stale record from an earlier assertion and pass.
  rm -f "$TMP/out.txt"
  AUTODREAM_SLIM_MAXLINE=100000 AUTODREAM_SLIM_HEAD=9000 AUTODREAM_SLIM_TAIL=9000 \
  AUTODREAM_SLIM_CAP=100000000 \
    "$SLIM" "$TMP/in.jsonl" "$TMP/out.txt" >/dev/null 2>&1 || return 1
  # The WHOLE output, not `grep -m1 '^{'`. Returning only the first record meant
  # every negative assertion inspected one line, so a slimmer emitting a clean
  # record followed by the original payload on line two passed them all. jq_is
  # picks the first record out for itself.
  cat "$TMP/out.txt" 2>/dev/null
}

echo "# slim: the script parses at all"
# Cheap, and it would have caught the bug that produced this line. The jq program
# is a single-quoted shell string, so ONE apostrophe anywhere inside it — in a
# comment, in the word "commit's" — terminates the quote and the whole file stops
# parsing. CLAUDE.md documents this trap for run.sh's L1 worker body; it applies
# to every single-quoted program in this repo.
if bash -n "$SLIM" 2>/dev/null; then ok "bin/slim-transcript.sh parses"
else no "bin/slim-transcript.sh has a shell syntax error (stray apostrophe in the jq program?)"; fi

echo "# slim: a null or absent value is not turned into the string \"null\""
# The bug this suite was written for. `trunc` ran `tostring` unconditionally, so
# a toolResult carrying no content came out asserting the literal text "null" —
# a value the worker reads as real tool output.
got=$(slim_one '{"message":{"role":"toolResult","content":null,"toolName":"Read"}}')
# BOTH assertions, because `type` alone reports "null" for an absent key too, so
# a regression that simply deleted .content would satisfy the type check.
jq_is "$got" '.message | has("content")' 'true' "an explicit null .content is KEPT, not deleted"
jq_is "$got" '.message.content | type' 'null' "and stays JSON null, not the string \"null\""
has '"toolName":"Read"' "$got" "and the rest of the record survives"

got=$(slim_one '{"message":{"role":"toolResult","toolName":"Read"}}')
jq_is "$got" '.message | has("content")' 'false' "an ABSENT .content is not invented as a key"
jq_is "$got" '.message.toolName' 'Read' "and the surrounding record is not simply dropped"

echo "# slim: a small structured value keeps its structure"
# tostring flattened `arguments` to an escaped JSON string even 40x under the
# cap, so triage lost the field names it reads. Structure is the payload here.
got=$(slim_one '{"message":{"content":[{"type":"toolCall","arguments":{"file":"a.txt","n":3}}]}}')
jq_is "$got" '.message.content[0].arguments | type' 'object' \
  "short arguments stay an OBJECT, not an escaped string"
jq_is "$got" '.message.content[0].arguments.file' 'a.txt' "and the field names triage reads survive"

# The false branch of the second has() guard. Without a fixture that OMITS
# arguments, a regression reintroducing a bare `.arguments = (...)` assignment
# would invent the key and every assertion above would still pass.
got=$(slim_one '{"message":{"content":[{"type":"toolCall","toolName":"Read"}]}}')
jq_is "$got" '.message.content[0] | has("arguments")' 'false' \
  "an ABSENT .arguments is not invented either"
jq_is "$got" '.message.content[0].type' 'toolCall' "and that block is not simply dropped"

echo "# slim: thinking blocks are capped without being fabricated"
got=$(slim_one '{"message":{"content":[{"type":"thinking","signature":"sig1"}]}}')
jq_is "$got" '.message.content[0] | has("thinking")' 'false' \
  "an ABSENT .thinking is not invented as an empty string"
jq_is "$got" '.message.content[0].signature' 'sig1' "and the block survives"
got=$(slim_one '{"message":{"content":[{"type":"thinking","thinking":null}]}}')
jq_is "$got" '.message.content[0].thinking | type' 'null' \
  "an explicit null .thinking stays null, not \"\""
bigt=$(printf 'y%.0s' $(seq 1 900))
got=$(slim_one "{\"message\":{\"content\":[{\"type\":\"thinking\",\"thinking\":\"$bigt\"}]}}")
has 'autodream: truncated' "$got" "a 900-char thinking block is capped at 800"

echo "# slim: an oversized value IS truncated"
# The cap has to still work, or the fix above traded one silent failure for a
# different one. 700 chars against a 600-char cap.
big=$(printf 'x%.0s' $(seq 1 700))
got=$(slim_one "{\"message\":{\"role\":\"toolResult\",\"content\":\"$big\"}}")
has 'autodream: truncated' "$got" "a 700-char content is truncated at the 600 cap"
[ "${#got}" -lt 900 ] && ok "and the record shrank" || no "and the record shrank (len ${#got})"

echo "# slim: Claude Code tool_result blocks are stripped, provenance kept"
got=$(slim_one '{"message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","is_error":true,"content":[{"type":"text","text":"HUGE"}]}]}}')
has 'payload stripped' "$got" "the marker is inserted"
hasnt 'HUGE' "$got" "and the original payload is actually GONE, not just annotated"
has '"tool_use_id":"tu_1"' "$got" "tool_use_id is kept so triage can name the call"
has '"is_error":true' "$got" "is_error is kept so triage can tell a failure"

echo "# slim: image payloads leave, in BOTH shapes"
# This branch claimed to strip base64 image data from the day it was written and
# did not, for image_url. It set .source (Claude's field) on a block whose payload
# lives at .image_url.url, so the base64 stayed and the record gained a marker
# saying it had gone. A receipt for a deletion that never happened.
got=$(slim_one '{"message":{"content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,SECRETPAYLOAD"}}]}}')
hasnt 'SECRETPAYLOAD' "$got" "an image_url base64 payload is actually removed"
has 'image stripped' "$got" "and the block says so"
got=$(slim_one '{"message":{"content":[{"type":"image","source":{"data":"BASE64HERE"}}]}}')
hasnt 'BASE64HERE' "$got" "a Claude image .source payload is actually removed"
got=$(slim_one '{"message":{"content":[{"type":"image_url","alt":"a chart"}]}}')
jq_is "$got" '.message.content[0] | has("image_url")' 'false' \
  "an image_url block with no payload does not have one invented"

echo "# slim: OMP image .data is stripped only when it IS a payload"
# Grounded in the corpus, not the schema. All 289 image blocks across 400 real OMP
# transcripts on the author's host carry `blob:sha256:<hash>` — a 76-char
# content-addressed reference, 22KB in total against a 262144-byte cap. Marking
# those "stripped" would delete an identifier and reclaim nothing, so only an
# inline data: URI counts as a payload here.
got=$(slim_one '{"message":{"content":[{"type":"image","data":"blob:sha256:ea5b55c53f28e07af31be6686b1281d9e4cd7bab9fbf9c4f65dc432affd2a010","mimeType":"image/webp"}]}}')
has 'blob:sha256:ea5b55c5' "$got" "a blob reference SURVIVES; it is an id, not a payload"
jq_is "$got" '.message.content[0].mimeType' 'image/webp' "and the block keeps its metadata"
got=$(slim_one '{"message":{"content":[{"type":"image","data":"data:image/png;base64,SECRETPAYLOAD","mimeType":"image/png"}]}}')
hasnt 'SECRETPAYLOAD' "$got" "an inline data: URI payload is removed"
jq_is "$got" '.message.content[0].mimeType' 'image/png' "while its metadata is kept"

echo "# slim: a tool_result with no content does not claim one was stripped"
got=$(slim_one '{"message":{"content":[{"type":"tool_result","tool_use_id":"u1"}]}}')
jq_is "$got" '.message.content[0] | has("content")' 'false' \
  "no content key is invented on a payload-free tool_result"
jq_is "$got" '.message.content[0].tool_use_id' 'u1' "and the block survives"

echo "# slim: a null or empty field is not marked as a stripped payload"
# Presence is not a payload. `has("details")` is true when details is null, so
# every marker site announced a removal that never happened when the field was
# there but empty. One level in from the bug the markers exist to prevent.
jq_is "$(slim_one '{"message":{"role":"toolResult","details":null,"content":"x"}}')" \
  '.message.details | type' 'null' "a null .details is left alone, not marked stripped"
jq_is "$(slim_one '{"message":{"content":[{"type":"image","source":null}]}}')" \
  '.message.content[0].source | type' 'null' "a null image .source is left alone"
jq_is "$(slim_one '{"message":{"content":[{"type":"image_url","image_url":{}}]}}')" \
  '.message.content[0].image_url | length' '0' "an EMPTY image_url carries no url, so nothing is claimed"
jq_is "$(slim_one '{"message":{"content":[{"type":"tool_result","tool_use_id":"u1","content":null}]}}')" \
  '.message.content[0].content | type' 'null' "a null tool_result .content is left alone"

echo "# slim: OMP toolResult details are stripped"
got=$(slim_one '{"message":{"role":"toolResult","details":{"big":"payload"},"content":"short"}}')
has 'details stripped' "$got" "OMP .details gets the marker"
hasnt '"big":"payload"' "$got" "and the original details payload is actually gone"
has '"content":"short"' "$got" "a short OMP content survives intact"

echo "# slim: providerPayload never survives"
got=$(slim_one '{"message":{"role":"assistant","providerPayload":{"raw":"secretish"},"content":"hi"}}')
jq_is "$got" '.message.content' 'hi' "the assistant record itself survives"
hasnt 'providerPayload' "$got" "the raw provider round-trip is dropped"
hasnt 'secretish' "$got" "and its contents go with it"

echo "# slim: a record the pre-pass does not understand passes through"
# The fallback is the whole reason this is safe to run on an unknown schema.
got=$(slim_one '{"type":"queue-operation","payload":{"a":1}}')
has 'queue-operation' "$got" "an unknown record shape is not dropped"

echo "# slim: non-JSONL input falls back instead of producing nothing"
printf 'this is not json\nnor is this\n' > "$TMP/plain.txt"
AUTODREAM_SLIM_MAXLINE=100000 "$SLIM" "$TMP/plain.txt" "$TMP/plain.out" >/dev/null 2>&1
rc=$?
assert_eq "$rc" "0" "a non-JSONL transcript still exits 0"
[ -s "$TMP/plain.out" ] && ok "and still writes output" || no "and still writes output"
has 'this is not json' "$(cat "$TMP/plain.out" 2>/dev/null)" "the original text survives the fallback"

echo "# slim: no .pre.jsonl temp is left behind"
ls "$TMP"/*.pre.jsonl >/dev/null 2>&1 && no "the pre-pass temp is cleaned up" \
  || ok "the pre-pass temp is cleaned up"

# ---- Reshape mode (AUTODREAM_SLIM_RESHAPE=1): the denylist and the rebuilt record ----------
# Off unless asked for. Nothing sets it yet; the chunked reader will, only while it is on, so every assertion
# above runs in the default mode and still means what it did, and the ones below are about the
# mode alone.
slim_re() { # $1=jsonl text, extra env as KEY=VAL args after -> slimmed output
  local text="$1"; shift
  printf '%s\n' "$text" > "$TMP/re-in.jsonl"
  rm -f "$TMP/re-out.txt"
  env AUTODREAM_SLIM_RESHAPE=1 AUTODREAM_SLIM_MAXLINE=100000 AUTODREAM_SLIM_HEAD=9000 \
      AUTODREAM_SLIM_TAIL=9000 AUTODREAM_SLIM_CAP=100000000 "$@" \
      "$SLIM" "$TMP/re-in.jsonl" "$TMP/re-out.txt" >/dev/null 2>&1 || return 1
  cat "$TMP/re-out.txt" 2>/dev/null
}
# Every fixture is paired with a sentinel conversation record. If the pre-pass emits NOTHING (every
# record dropped) the script treats that as a jq failure and falls back to the raw line pass, which
# would hand the dropped record straight back and fail an assertion that the drop worked.
SENT='{"type":"user","timestamp":"2026-10-01T09:00:00.000Z","message":{"role":"user","content":"sentinel"}}'
re_with() { slim_re "$(printf '%s\n%s' "$SENT" "$1")"; }

echo "# slim reshape: Claude Code bookkeeping and hook noise is dropped"
for t in bridge-session last-prompt permission-mode mode atis-latch ai-title queue-operation file-history-snapshot file-history-delta dev-mods; do
  got=$(re_with "{\"type\":\"$t\",\"timestamp\":\"2026-10-01T10:00:00.000Z\",\"x\":1}")
  has 'sentinel' "$got" "($t) the sentinel conversation record survives"
  hasnt "\"type\":\"$t\"" "$got" "a $t record is dropped"
done
for st in hook_success total_tokens_reminder deferred_tools_record deferred_tools_delta silent_turn_reminder prompt_snapshot environment date model instructions session_context credential_org advisor_tool sandbox_instructions mcp_instructions_delta agent_listing_delta remote_session_change command_permissions; do
  got=$(re_with "{\"type\":\"attachment\",\"timestamp\":\"2026-10-01T10:00:00.000Z\",\"attachment\":{\"type\":\"$st\",\"text\":\"NOISE-$st\"}}")
  hasnt "NOISE-$st" "$got" "an attachment/$st record is dropped"
done
for st in stop_hook_summary turn_duration; do
  got=$(re_with "{\"type\":\"system\",\"subtype\":\"$st\",\"timestamp\":\"2026-10-01T10:00:00.000Z\",\"content\":\"SYSNOISE\"}")
  hasnt 'SYSNOISE' "$got" "a system/$st record is dropped"
done

echo "# slim reshape: records that carry conversation signal, or that this script has never seen, are KEPT"
got=$(re_with '{"type":"attachment","timestamp":"2026-10-01T10:00:00.000Z","attachment":{"type":"queued_command","prompt":"also fix the footer"}}')
has 'also fix the footer' "$got" "a queued_command attachment (the user typing mid-turn) is kept"
got=$(re_with '{"type":"attachment","timestamp":"2026-10-01T10:00:00.000Z","attachment":{"type":"skill_listing","content":"- python-env-management: sets up venvs"}}')
has 'python-env-management' "$got" "a skill_listing attachment is kept (the triage prompt names it)"
got=$(re_with '{"type":"system","subtype":"compact_boundary","timestamp":"2026-10-01T10:00:00.000Z","content":"Conversation compacted"}')
has 'Conversation compacted' "$got" "a system/compact_boundary record is kept"
got=$(re_with '{"type":"system","subtype":"away_summary","timestamp":"2026-10-01T10:00:00.000Z","content":"AWAYRECAP"}')
has 'AWAYRECAP' "$got" "a system/away_summary record is kept"
got=$(re_with '{"type":"system","timestamp":"2026-10-01T10:00:00.000Z","content":"NOSUBTYPE"}')
has 'NOSUBTYPE' "$got" "a system record with no subtype is kept"
got=$(re_with '{"type":"pr-link","prNumber":42,"prUrl":"https://example.test/pr/42"}')
has 'pr/42' "$got" "a pr-link record is kept"
got=$(re_with '{"type":"summary","summary":"COMPACTED EARLIER WORK","leafUuid":"l1"}')
has 'COMPACTED EARLIER WORK' "$got" "a compaction summary record is kept"
got=$(re_with '{"type":"attachment","timestamp":"2026-10-01T10:00:00.000Z","attachment":{"type":"edited_text_file","filename":"a.txt","snippet":"EDITED"}}')
has 'EDITED' "$got" "an attachment subtype that is not on the denylist (edited_text_file) is kept"
got=$(re_with '{"type":"attachment","timestamp":"2026-10-01T10:00:00.000Z","attachment":{"type":"a_subtype_from_next_year","x":"FUTURE"}}')
has 'FUTURE' "$got" "an attachment subtype nobody has seen is kept, not guessed to be noise"
got=$(re_with '{"type":"some-future-type","payload":{"a":1}}')
has 'some-future-type' "$got" "an unknown record type is kept"
got=$(re_with '{"type":"attachment","timestamp":"2026-10-01T10:00:00.000Z"}')
has '"type":"attachment"' "$got" "an attachment with no subtype at all is kept"

echo "# slim reshape: a kept Claude Code line puts type and timestamp first and only the fields triage reads"
UREC='{"parentUuid":"p1","isSidechain":false,"userType":"external","cwd":"/x/y","sessionId":"s1","version":"2.1.0","gitBranch":"main","type":"user","message":{"role":"user","content":"hello world"},"uuid":"u1","timestamp":"2026-10-01T14:21:52.155Z","toolUseResult":{"big":"payload"}}'
got=$(slim_re "$UREC")
jq_is "$got" 'keys_unsorted[0]' 'type' "type is the first key"
jq_is "$got" 'keys_unsorted[1]' 'timestamp' "timestamp is the second key, ahead of the payload"
jq_is "$got" '.message | keys_unsorted | join(",")' 'role,content' "message is reduced to role and content"
jq_is "$got" '.message.content' 'hello world' "and the user text survives"
jq_is "$got" '.isSidechain' 'false' "isSidechain is kept"
for k in parentUuid uuid cwd sessionId version gitBranch userType toolUseResult; do
  hasnt "\"$k\"" "$got" "envelope field $k is dropped"
done
first=$(printf '%s\n' "$got" | grep -m1 '^{' | cut -c1-80)
has '"timestamp":"2026-10-01T14:21:52.155Z"' "$first" "the timestamp sits inside the first 80 chars, so the line cut cannot take it"
AREC='{"parentUuid":"p2","type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"hmm","signature":"AAAASIGNATUREBLOB"},{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":9}},"uuid":"a1","timestamp":"2026-10-01T14:21:53.000Z"}'
got=$(slim_re "$AREC")
hasnt 'SIGNATUREBLOB' "$got" "a thinking signature blob is dropped"
jq_is "$got" '.message.content[0].thinking' 'hmm' "while the thinking text stays"
jq_is "$got" '.message.content[1].input.command' 'ls' "and a tool_use command survives"
jq_is "$got" '.message | keys_unsorted | join(",")' 'role,content' "an assistant message loses model, id, type and usage"
got=$(slim_re '{"type":"user","message":{"role":"user","content":"no clock"}}')
jq_is "$got" 'has("timestamp")' 'false' "a record with no timestamp does not gain a null one"
got=$(slim_re '{"type":"user","timestamp":"2026-10-01T14:21:52.155Z","message":{"content":"no role"}}')
jq_is "$got" '.message | has("role")' 'false' "a message with no role does not gain a null role"
got=$(slim_re "$(printf '%s\n%s\n%s' "$SENT" '{"type":"assistant","timestamp":"2026-10-01T14:21:52.155Z","message":{"role":"assistant","content":["a bare string block",{"type":"thinking","thinking":"t","signature":"S"}]}}' '{"type":"mode","mode":"auto"}')")
has 'sentinel' "$got" "a content array holding a bare string does not abort the reshape (the sentinel survives)"
hasnt '"type":"mode"' "$got" "and bookkeeping is still dropped, so the raw fallback did not run"
got=$(slim_re "$(printf '%s\n%s\n%s' "$SENT" '{"type":"user","message":"strmsg"}' '{"type":"mode","mode":"auto"}')")
has 'strmsg' "$got" "a Claude record whose message is a string is kept, not deleted by the reshape"
hasnt '"type":"mode"' "$got" "and bookkeeping is still dropped around it"

echo "# slim reshape: OMP and unknown-schema records come out exactly as they do with the reshape off"
# Not "raw": the pre-pass has always re-serialised every record with jq -c and stripped OMP toolResult
# payloads, so an OMP line is already not byte-identical to the file. What this protects is that the
# DENYLIST never touches a record it does not name. An allowlist bug here deletes every OMP record.
{ printf '%s\n' '{"type":"title","v":1,"title":"T"}'
  printf '%s\n' '{"type":"session","version":3,"id":"01a0","timestamp":"2026-08-25T00:43:50.000Z","cwd":"/x"}'
  printf '%s\n' '{"type":"message","id":"a1","parentId":"p0","timestamp":"2026-08-25T00:43:56.469Z","message":{"role":"toolResult","toolName":"Read","content":"short","details":{"d":1},"usage":{"input":1}}}'
  printf '%s\n' '{"type":"message","id":"a2","parentId":"a1","timestamp":"2026-08-25T00:43:57.000Z","message":{"role":"assistant","content":[{"type":"text","text":"hi"},{"type":"toolCall","name":"Bash","arguments":{"command":"ls"}}],"providerPayload":{"raw":1}}}'
  printf '%s\n' '{"type":"custom","customType":"tool_execution_start","data":{"toolName":"bash"}}'
  printf '%s\n' '{"type":"custom_message","customType":"x","content":"hi"}'
  printf '%s\n' '{"type":"model_change","id":"m1","model":"x/y"}'
  printf '%s\n' '{"type":"thinking_level_change","thinkingLevel":"high"}'
  printf '%s\n' '{"type":"compaction","id":"c1","summary":"S"}'
  printf '%s\n' '{"type":"autodream_meta","source":"omp","cwd":"/x","is_advisor":false}'
  printf '%s\n' '{"type":"some-schema-nobody-knows","payload":{"a":[1,2,3]}}'
  printf '%s\n' '{"no_type_key":true}'; } > "$TMP/omp-all.jsonl"
rm -f "$TMP/omp-off.out" "$TMP/omp-on.out"
AUTODREAM_SLIM_MAXLINE=100000 AUTODREAM_SLIM_HEAD=9000 AUTODREAM_SLIM_TAIL=9000 AUTODREAM_SLIM_CAP=100000000 \
  "$SLIM" "$TMP/omp-all.jsonl" "$TMP/omp-off.out" >/dev/null 2>&1
AUTODREAM_SLIM_RESHAPE=1 AUTODREAM_SLIM_MAXLINE=100000 AUTODREAM_SLIM_HEAD=9000 AUTODREAM_SLIM_TAIL=9000 AUTODREAM_SLIM_CAP=100000000 \
  "$SLIM" "$TMP/omp-all.jsonl" "$TMP/omp-on.out" >/dev/null 2>&1
assert_eq "$(wc -l < "$TMP/omp-on.out" | tr -d ' ')" "$(( $(wc -l < "$TMP/omp-all.jsonl" | tr -d ' ') + 2 ))" "an OMP-shaped file keeps every record (plus the footer) with the reshape on"
if cmp -s "$TMP/omp-off.out" "$TMP/omp-on.out"; then ok "the output with the reshape on is byte for byte the output with it off"; else no "the output with the reshape on is byte for byte the output with it off"; fi
has 'details stripped' "$(cat "$TMP/omp-on.out")" "and the OMP toolResult details are still stripped by the pre-pass, as before"
hasnt 'providerPayload' "$(cat "$TMP/omp-on.out")" "and so is the provider round-trip"

echo "# slim reshape: head and tail are counted over the surviving conversation lines"
: > "$TMP/budget.jsonl"
for i in 1 2 3 4 5 6; do
  printf '{"type":"user","timestamp":"2026-10-01T10:00:0%d.000Z","message":{"role":"user","content":"turn%d"}}\n' "$i" "$i" >> "$TMP/budget.jsonl"
  printf '{"type":"mode","mode":"auto"}\n{"type":"attachment","attachment":{"type":"hook_success"}}\n' >> "$TMP/budget.jsonl"
done
rm -f "$TMP/budget.out"
AUTODREAM_SLIM_RESHAPE=1 AUTODREAM_SLIM_HEAD=2 AUTODREAM_SLIM_TAIL=2 "$SLIM" "$TMP/budget.jsonl" "$TMP/budget.out" >/dev/null 2>&1
out=$(cat "$TMP/budget.out" 2>/dev/null)
has '[2 of 6 lines elided' "$out" "elision is measured against the 6 conversation lines, not the 18 raw ones"
for t in turn1 turn2 turn5 turn6; do has "$t" "$out" "$t is inside the kept head or tail"; done
for t in turn3 turn4; do hasnt "$t" "$out" "$t is in the elided middle"; done
rm -f "$TMP/budget-off.out"
AUTODREAM_SLIM_HEAD=2 AUTODREAM_SLIM_TAIL=2 "$SLIM" "$TMP/budget.jsonl" "$TMP/budget-off.out" >/dev/null 2>&1
has '[14 of 18 lines elided' "$(cat "$TMP/budget-off.out" 2>/dev/null)" "control: with the reshape off the same file is elided over all 18 raw lines"

echo "# slim reshape: a file holding ONLY noise still writes something, never nothing"
printf '%s\n' '{"type":"mode","mode":"auto"}' '{"type":"permission-mode","permissionMode":"x"}' > "$TMP/onlynoise.jsonl"
rm -f "$TMP/onlynoise.out"
AUTODREAM_SLIM_RESHAPE=1 "$SLIM" "$TMP/onlynoise.jsonl" "$TMP/onlynoise.out" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "it exits 0"
[ -s "$TMP/onlynoise.out" ] && ok "and the output is not empty (a worker handed an empty file would write a clean report)" || no "and the output is not empty"

# ---- Full mode (AUTODREAM_SLIM_FULL=1): every surviving line, no cap, no footer -------------
echo "# slim full: keeps every conversation line, with head, tail and cap set tiny"
: > "$TMP/full.jsonl"
for i in $(seq 1 50); do
  printf '{"type":"user","timestamp":"2026-10-01T10:00:00.000Z","message":{"role":"user","content":"turn%d"}}\n' "$i" >> "$TMP/full.jsonl"
done
rm -f "$TMP/full.out" "$TMP/notfull.out"
AUTODREAM_SLIM_FULL=1 AUTODREAM_SLIM_HEAD=2 AUTODREAM_SLIM_TAIL=2 AUTODREAM_SLIM_CAP=100 \
  "$SLIM" "$TMP/full.jsonl" "$TMP/full.out" >/dev/null 2>&1
assert_eq "$(grep -c '"type":"user"' "$TMP/full.out" 2>/dev/null)" "50" "FULL keeps all 50 lines even with head, tail and cap set tiny"
hasnt 'elided' "$(cat "$TMP/full.out" 2>/dev/null)" "and does not announce an elision"
AUTODREAM_SLIM_HEAD=2 AUTODREAM_SLIM_TAIL=2 "$SLIM" "$TMP/full.jsonl" "$TMP/notfull.out" >/dev/null 2>&1
has 'elided' "$(cat "$TMP/notfull.out" 2>/dev/null)" "control: without FULL the same input IS elided"
echo "# slim full: ends on a transcript line, not on the footer"
printf '%s\n' "$SENT" > "$TMP/foot.jsonl"
rm -f "$TMP/foot-full.out" "$TMP/foot-def.out"
AUTODREAM_SLIM_FULL=1 "$SLIM" "$TMP/foot.jsonl" "$TMP/foot-full.out" >/dev/null 2>&1
hasnt 'autodream slimmed this transcript' "$(cat "$TMP/foot-full.out" 2>/dev/null)" "full mode appends no footer"
assert_eq "$(tail -1 "$TMP/foot-full.out" 2>/dev/null | jq -r .type 2>/dev/null)" "user" "and its last line is a transcript record"
"$SLIM" "$TMP/foot.jsonl" "$TMP/foot-def.out" >/dev/null 2>&1
has 'autodream slimmed this transcript' "$(cat "$TMP/foot-def.out" 2>/dev/null)" "control: the default mode still appends the footer"
echo "# slim full: lines are still cut to the line width"
printf '{"type":"user","timestamp":"2026-10-01T10:00:00.000Z","message":{"role":"user","content":"%s"}}\n' "$(printf 'z%.0s' $(seq 1 500))" > "$TMP/wide.jsonl"
rm -f "$TMP/wide.out"
AUTODREAM_SLIM_FULL=1 AUTODREAM_SLIM_MAXLINE=120 "$SLIM" "$TMP/wide.jsonl" "$TMP/wide.out" >/dev/null 2>&1
assert_eq "$(head -1 "$TMP/wide.out" | tr -d '\n' | wc -c | tr -d ' ')" "120" "a wide line is cut to AUTODREAM_SLIM_MAXLINE (the line, not the file, is what is bounded)"

echo "# slim: the modes are off by default, and an explicit 0 is the default"
printf '%s\n%s\n%s\n' "$SENT" '{"type":"mode","mode":"auto"}' '{"type":"attachment","attachment":{"type":"hook_success","stdout":"HOOK"}}' > "$TMP/mm.jsonl"
rm -f "$TMP/mm-a.out" "$TMP/mm-b.out" "$TMP/mm-c.out"
"$SLIM" "$TMP/mm.jsonl" "$TMP/mm-a.out" >/dev/null 2>&1
AUTODREAM_SLIM_RESHAPE=0 AUTODREAM_SLIM_FULL=0 "$SLIM" "$TMP/mm.jsonl" "$TMP/mm-b.out" >/dev/null 2>&1
if cmp -s "$TMP/mm-a.out" "$TMP/mm-b.out"; then ok "RESHAPE=0 FULL=0 writes exactly what no variable writes"; else no "RESHAPE=0 FULL=0 writes exactly what no variable writes"; fi
has '"type":"mode"' "$(cat "$TMP/mm-a.out")" "and the default mode keeps the bookkeeping record, as it always did"
has 'HOOK' "$(cat "$TMP/mm-a.out")" "and the hook attachment"

echo "# slim: with both modes unset the output is byte for byte what the slimmer wrote before the modes existed"
# A golden digest, taken with bin/slim-transcript.sh as it stood on origin/main before the reshape
# landed, over a 2,800-line Claude-shaped fixture (envelope fields, bookkeeping, hook attachments,
# thinking signatures) big enough to hit the head/tail elision and the footer. It pins the default
# path itself, not "reshape off equals reshape off", so a change that leaks into a plain call fails.
i=1; : > "$TMP/golden.jsonl"
while [ "$i" -le 700 ]; do
  printf '{"parentUuid":"p%d","type":"user","message":{"role":"user","content":"turn %d with some text"},"uuid":"u%d","timestamp":"2026-10-01T10:00:00.000Z","cwd":"/x"}\n' "$i" "$i" "$i"
  printf '{"type":"mode","mode":"auto"}\n{"type":"attachment","attachment":{"type":"hook_success","content":"HOOK %d"}}\n' "$i"
  printf '{"type":"assistant","message":{"model":"m","id":"i%d","role":"assistant","content":[{"type":"thinking","thinking":"t","signature":"SIG"},{"type":"text","text":"reply %d"}],"usage":{"input_tokens":1}},"timestamp":"2026-10-01T10:00:01.000Z"}\n' "$i" "$i"
  i=$((i + 1))
done >> "$TMP/golden.jsonl"
rm -f "$TMP/golden.out"
env -u AUTODREAM_SLIM_RESHAPE -u AUTODREAM_SLIM_FULL "$SLIM" "$TMP/golden.jsonl" "$TMP/golden.out" >/dev/null 2>&1
if command -v shasum >/dev/null 2>&1; then digest=$(shasum -a 256 "$TMP/golden.out" | cut -d' ' -f1); else digest=$(sha256sum "$TMP/golden.out" | cut -d' ' -f1); fi
assert_eq "$digest" "6ef17cb7b05ccef8de93a9a181f6a79c5628db404f8664da1f64991813d6ea80" "a plain call writes the pre-reshape bytes (2,800-line fixture, elision and footer included)"

echo "# slim: nothing it writes is readable by another local account"
printf '%s\n' "$SENT" > "$TMP/mode.jsonl"
rm -f "$TMP/mode.out"
( umask 022; AUTODREAM_SLIM_RESHAPE=1 AUTODREAM_SLIM_FULL=1 "$SLIM" "$TMP/mode.jsonl" "$TMP/mode.out" >/dev/null 2>&1 )
assert_eq "$(pstat_mode "$TMP/mode.out")" "600" "the slimmed output is mode 600 even when the caller umask is 022"
rm -f "$TMP/mode2.out"
( umask 022; "$SLIM" "$TMP/mode.jsonl" "$TMP/mode2.out" >/dev/null 2>&1 )
assert_eq "$(pstat_mode "$TMP/mode2.out")" "600" "and so is the default mode's"
printf 'old\n' > "$TMP/mode3.out"; chmod 644 "$TMP/mode3.out"
"$SLIM" "$TMP/mode.jsonl" "$TMP/mode3.out" >/dev/null 2>&1
assert_eq "$(pstat_mode "$TMP/mode3.out")" "600" "and a destination the caller already made with mode 644 is tightened to 600"
hasnt 'old' "$(head -c 3 "$TMP/mode3.out")" "and its old contents are replaced"

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
