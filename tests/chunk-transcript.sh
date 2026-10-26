#!/bin/bash
# Unit tests for bin/chunk-transcript.sh: split a transcript into chunks an L1 worker can read,
# cutting only at line boundaries.
#
# Why this exists. A day of a long session slims to far more than one worker can read, and eliding
# the middle is how L1 came to see 2% of a conversation. The chunker keeps every line and the merge
# step turns the per-chunk answers back into the one findings JSON per session that L2 reads. The
# properties that matter are the ones a smoke test cannot see: no line is ever split, nothing is
# lost or reordered when the cap is not hit, an over-the-cap session reports what it dropped, and a
# cap or a size that cannot be honoured never turns into a read of the whole transcript.
#
# Contract: chunk-transcript.sh SRC OUTDIR CHUNK_BYTES MAX_CHUNKS
#   stdout "COUNT ELIDED"   OUTDIR/chunk-01.jsonl ... COUNT files
#   exit 0 ok, 1 empty source, 2 usage, unreadable source or a failure writing chunks

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$REPO/bin/portable.sh"
CH="$REPO/bin/chunk-transcript.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

[ -x "$CH" ] || {
  printf '  FAIL - bin/chunk-transcript.sh missing or not executable\n'
  printf '\npassed: 0   failed: 1\n'; exit 1; }
command -v jq >/dev/null 2>&1 || {
  printf '  ok   - jq not installed; this suite is skipped\n'
  printf '\npassed: 1   failed: 0\n'; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/chtest.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# A line of exactly 100 bytes including its newline, tagged with its number.
line(){ printf '{"n":%d,"pad":"%s"}\n' "$1" "$(printf 'x%.0s' $(seq 1 $((84 - ${#1}))))"; }
mk(){ : > "$1"; local i; for i in $(seq 1 "$2"); do line "$i" >> "$1"; done; }
count_files(){ ls "$1"/chunk-*.jsonl 2>/dev/null | wc -l | tr -d ' '; }
first_n(){ jq -r .n "$1" | head -1; }
last_n(){ jq -r .n "$1" | tail -1; }

echo "# chunk: a source under the limit is one chunk, unchanged"
mk "$TMP/small.jsonl" 3
OUT="$TMP/o1"; mkdir -p "$OUT"
read -r n e <<< "$("$CH" "$TMP/small.jsonl" "$OUT" 1000 8 2>/dev/null)"
assert_eq "$n $e" "1 0" "prints '1 0'"
assert_eq "$(cat "$OUT/chunk-01.jsonl")" "$(cat "$TMP/small.jsonl")" "and chunk-01 is the source, byte for byte"

echo "# chunk: cut only at line boundaries, nothing lost, nothing reordered"
mk "$TMP/ten.jsonl" 10
OUT="$TMP/o2"; mkdir -p "$OUT"
read -r n e <<< "$("$CH" "$TMP/ten.jsonl" "$OUT" 350 20 2>/dev/null)"
assert_eq "$n $e" "4 0" "ten 100-byte lines at a 350-byte limit -> 4 chunks (3,3,3,1), none elided"
assert_eq "$(count_files "$OUT")" "4" "four chunk files exist"
assert_eq "$(cat "$OUT"/chunk-01.jsonl "$OUT"/chunk-02.jsonl "$OUT"/chunk-03.jsonl "$OUT"/chunk-04.jsonl | shasum | cut -c1-40)" \
          "$(shasum < "$TMP/ten.jsonl" | cut -c1-40)" "the chunks concatenate back to the source exactly"
big=0; for f in "$OUT"/chunk-*.jsonl; do [ "$(wc -c < "$f" | tr -d ' ')" -gt 350 ] && big=1; done
assert_eq "$big" "0" "no chunk exceeds the limit"
bad=0; for f in "$OUT"/chunk-*.jsonl; do jq -e . "$f" >/dev/null 2>&1 || bad=1; done
assert_eq "$bad" "0" "every chunk of a valid JSONL source parses as JSONL (no line was cut in half)"
empty=0; for f in "$OUT"/chunk-*.jsonl; do [ -s "$f" ] || empty=1; done
assert_eq "$empty" "0" "and no chunk is empty"

echo "# chunk: a tool call and its result are never torn, only separated across a cut"
# Two lines that belong together, forced across the boundary by the limit. Both stay whole, in
# order, the call ending one chunk and the result opening the next.
{ line 1; printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_X","name":"Bash","input":{"command":"ls"}}]},"pad":"%s"}\n' "$(printf 'p%.0s' $(seq 1 40))"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_X","content":"out"}]},"pad":"%s"}\n' "$(printf 'q%.0s' $(seq 1 40))"; line 4; } > "$TMP/pair.jsonl"
OUT="$TMP/op"; mkdir -p "$OUT"
read -r n e <<< "$("$CH" "$TMP/pair.jsonl" "$OUT" 250 8 2>/dev/null)"
assert_eq "$(cat "$OUT"/chunk-*.jsonl | shasum | cut -c1-40)" "$(shasum < "$TMP/pair.jsonl" | cut -c1-40)" "every line of the pair is present, in order"
assert_eq "$(grep -l '"tool_use"' "$OUT"/chunk-*.jsonl | wc -l | tr -d ' ')" "1" "the call is in exactly one chunk"
assert_eq "$(grep -c 'toolu_X' "$OUT"/chunk-*.jsonl | awk -F: '{s += $2} END {print s}')" "2" "and its result is in exactly one chunk, both lines whole"
bad=0; for f in "$OUT"/chunk-*.jsonl; do jq -e . "$f" >/dev/null 2>&1 || bad=1; done
assert_eq "$bad" "0" "and every chunk still parses"

echo "# chunk: a single line longer than the limit is its own chunk, not split"
{ line 1; printf '{"n":2,"pad":"%s"}\n' "$(printf 'y%.0s' $(seq 1 900))"; line 3; } > "$TMP/long.jsonl"
OUT="$TMP/o3"; mkdir -p "$OUT"
read -r n e <<< "$("$CH" "$TMP/long.jsonl" "$OUT" 350 8 2>/dev/null)"
assert_eq "$n" "3" "short, oversize, short -> 3 chunks"
assert_eq "$(jq -r .n "$OUT/chunk-02.jsonl")" "2" "the oversize line sits alone in the middle chunk"
assert_eq "$(wc -l < "$OUT/chunk-02.jsonl" | tr -d ' ')" "1" "and is intact (one whole line)"

echo "# chunk: the limit counts bytes, not characters"
# 60 two-byte characters is 120 bytes. At a 130-byte limit two such lines (2 x 123) do not fit
# together, so a character count (2 x 63) would have put both in one chunk.
mb(){ printf '{"n":%d,"t":"%s"}\n' "$1" "$(printf 'é%.0s' $(seq 1 60))"; }
{ mb 1; mb 2; mb 3; } > "$TMP/mb.jsonl"
OUT="$TMP/omb"; mkdir -p "$OUT"
read -r n e <<< "$("$CH" "$TMP/mb.jsonl" "$OUT" 130 8 2>/dev/null)"
assert_eq "$n" "3" "three multibyte lines at 130 bytes -> 3 chunks (bytes, not characters)"

echo "# chunk: a last line with no newline is kept, and ends a line"
printf '{"n":1}\n{"n":2}' > "$TMP/nonl.jsonl"
OUT="$TMP/onl"; mkdir -p "$OUT"
read -r n e <<< "$("$CH" "$TMP/nonl.jsonl" "$OUT" 1000 8 2>/dev/null)"
assert_eq "$(jq -r .n "$OUT/chunk-01.jsonl" | tr '\n' ',')" "1,2," "both lines are there"
assert_eq "$(tail -c 1 "$OUT/chunk-01.jsonl" | od -An -c | tr -d ' ')" '\n' "and the chunk ends on a newline"

echo "# chunk: over MAX_CHUNKS keeps the head and tail chunks and says what it dropped"
mk "$TMP/hundred.jsonl" 40      # 4,000 bytes at 400/chunk = 10 chunks
OUT="$TMP/o4"; mkdir -p "$OUT"
read -r n e <<< "$("$CH" "$TMP/hundred.jsonl" "$OUT" 400 4 2>/dev/null)"
assert_eq "$n $e" "4 6" "10 chunks capped at 4 -> prints '4 6'"
assert_eq "$(count_files "$OUT")" "4" "four chunk files remain"
assert_eq "$(first_n "$OUT/chunk-01.jsonl")" "1" "chunk 1 is the start of the session"
assert_eq "$(first_n "$OUT/chunk-02.jsonl")" "5" "chunk 2 is the second original chunk"
assert_eq "$(first_n "$OUT/chunk-03.jsonl")" "33" "chunk 3 is the ninth original chunk"
assert_eq "$(last_n "$OUT/chunk-04.jsonl")" "40" "chunk 4 ends with the last line of the session"
OUT="$TMP/o4b"; mkdir -p "$OUT"
read -r n e <<< "$("$CH" "$TMP/hundred.jsonl" "$OUT" 400 5 2>/dev/null)"
assert_eq "$n $e" "5 5" "an odd cap of 5 keeps 3 head and 2 tail chunks"
assert_eq "$(first_n "$OUT/chunk-03.jsonl")" "9" "the third kept chunk is the third original (the head side gets the extra)"
assert_eq "$(first_n "$OUT/chunk-04.jsonl")" "33" "the fourth kept chunk is the ninth original (the tail side resumes there)"
assert_eq "$(( $(count_files "$OUT") + 5 ))" "10" "kept plus elided is every chunk there was"

echo "# chunk: a cap of 1 keeps the first chunk only, never the whole transcript"
OUT="$TMP/o1c"; mkdir -p "$OUT"
read -r n e <<< "$("$CH" "$TMP/hundred.jsonl" "$OUT" 400 1 2>/dev/null)"
assert_eq "$n $e" "1 9" "ten chunks capped at 1 -> prints '1 9'"
assert_eq "$(wc -c < "$OUT/chunk-01.jsonl" | tr -d ' ')" "400" "and the one chunk is 400 bytes, not the 4,000 of the source"

echo "# chunk: the count is capped at MAX_CHUNKS however big the source"
mk "$TMP/big.jsonl" 400         # 40,000 bytes at 400/chunk = 100 chunks
OUT="$TMP/obig"; mkdir -p "$OUT"
read -r n e <<< "$("$CH" "$TMP/big.jsonl" "$OUT" 400 8 2>/dev/null)"
assert_eq "$n $e" "8 92" "100 chunks capped at 8 -> '8 92'"
assert_eq "$(count_files "$OUT")" "8" "and 8 files exist, none of the 92 dropped ones"
assert_eq "$(ls "$OUT" | grep -vc '^chunk-[0-9][0-9]\.jsonl$')" "0" "and nothing else is left in the directory (no scratch file)"

echo "# chunk: chunk files are private to the user"
OUT="$TMP/o5m"; mkdir -p "$OUT"
( umask 022; "$CH" "$TMP/ten.jsonl" "$OUT" 350 20 >/dev/null 2>&1 )
modes=$(for f in "$OUT"/chunk-*.jsonl; do pstat_mode "$f"; done | sort -u | tr '\n' ' ')
assert_eq "$modes" "600 " "every chunk is mode 600 even when the caller umask is 022 (they hold transcript text)"

echo "# chunk: numbers with leading zeros are decimal, not an invalid octal"
OUT="$TMP/o4z"; mkdir -p "$OUT"
read -r n e <<< "$("$CH" "$TMP/hundred.jsonl" "$OUT" 0400 08 2>/dev/null)"
assert_eq "$n $e" "8 2" "a cap of 08 and a size of 0400 are read as 8 and 400 (10 chunks capped at 8 -> '8 2')"
OUT="$TMP/o4zz"; mkdir -p "$OUT"
"$CH" "$TMP/hundred.jsonl" "$OUT" 400 00 >/dev/null 2>&1; assert_eq "$?" "2" "a cap of 00 is still refused as zero"

echo "# chunk: stale chunk files from an earlier run are removed"
OUT="$TMP/o5"; mkdir -p "$OUT"; echo stale > "$OUT/chunk-09.jsonl"; echo stale > "$OUT/raw-00003.jsonl"
"$CH" "$TMP/small.jsonl" "$OUT" 1000 8 >/dev/null 2>&1
[ ! -e "$OUT/chunk-09.jsonl" ] && ok "a leftover chunk-09.jsonl is gone" || no "a leftover chunk-09.jsonl is gone"
[ ! -e "$OUT/raw-00003.jsonl" ] && ok "and a leftover scratch file" || no "and a leftover scratch file"

echo "# chunk: failure modes"
: > "$TMP/empty.jsonl"
"$CH" "$TMP/empty.jsonl" "$TMP/o6" 1000 8 >/dev/null 2>&1; assert_eq "$?" "1" "an empty source exits 1"
"$CH" "$TMP/nope.jsonl" "$TMP/o6" 1000 8 >/dev/null 2>&1; assert_eq "$?" "2" "an unreadable source exits 2"
"$CH" "$TMP/small.jsonl" "$TMP/o6" 0 8 >/dev/null 2>&1; assert_eq "$?" "2" "a zero chunk size exits 2 (usage)"
"$CH" "$TMP/small.jsonl" "$TMP/o6" abc 8 >/dev/null 2>&1; assert_eq "$?" "2" "a non-numeric chunk size exits 2 (usage)"
"$CH" "$TMP/small.jsonl" "$TMP/o6" 1000 abc >/dev/null 2>&1; assert_eq "$?" "2" "a non-numeric cap exits 2 (usage)"
"$CH" "$TMP/small.jsonl" >/dev/null 2>&1; assert_eq "$?" "2" "missing arguments exit 2 (usage)"
# A directory that cannot be written: the failure must leave no half split behind for a caller
# that ignores the status, and the status must say so.
mkdir -p "$TMP/ro"; chmod 500 "$TMP/ro"
"$CH" "$TMP/ten.jsonl" "$TMP/ro/out" 350 8 >/dev/null 2>&1; assert_eq "$?" "2" "an output directory that cannot be created exits 2"
chmod 700 "$TMP/ro"
OUT="$TMP/o7"; mkdir -p "$OUT"; chmod 500 "$OUT"
"$CH" "$TMP/ten.jsonl" "$OUT" 350 8 >/dev/null 2>&1; rc=$?
chmod 700 "$OUT"
assert_eq "$rc" "2" "an output directory that cannot be written into exits 2"
assert_eq "$(ls "$OUT" | wc -l | tr -d ' ')" "0" "and leaves no chunk or scratch file in it"

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
