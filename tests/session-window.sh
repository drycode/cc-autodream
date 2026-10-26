#!/bin/bash
# Unit tests for bin/session-window.sh: the local-day window over a transcript.
#
# Why this exists. A session used to belong to a report day because of its FILE MTIME
# (`-newermt DAY ! -newermt NEXT`), so a session written to again after its day closed
# dropped out of every later rebuild of that day (issue #113), and a transcript spanning
# several days was read whole for each of them. The timestamp INSIDE the transcript is now
# what places it, so this helper has to be right about edges: the boundary second, fractional
# seconds, 23h and 25h DST days in more than one country, records with no clock, a clock in
# a shape it does not read, lines that are not JSON, and a file that is not in order.
#
# Exit codes of `in-window`, `needs-slice` and `day-file` are a three-way contract
# (0 yes, 1 no, 2 error). The caller keeps a session on an error rather than dropping it, so
# a broken helper reads as extra work and never as a quiet night.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$REPO/bin/portable.sh"
WIN="$REPO/bin/session-window.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

[ -x "$WIN" ] || {
  printf '  FAIL - bin/session-window.sh missing or not executable\n'
  printf '\npassed: 0   failed: 1\n'; exit 1; }
command -v jq >/dev/null 2>&1 || {
  printf '  ok   - jq not installed; this suite is skipped\n'
  printf '\npassed: 1   failed: 0\n'; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/swtest.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# 2026-10-01 00:00:00Z and 2026-10-02 00:00:00Z, written as literals on purpose: a
# test that derives its expected bounds with the same `date` call as the code under
# test cannot disagree with it.
START=1790812800
END=1790899200

rec(){ printf '{"type":"user","timestamp":"%s","message":{"content":"%s"}}\n' "$1" "$2"; }
rc_of(){ "$@" >/dev/null 2>&1; printf '%s' "$?"; }

echo "# window: bounds are local midnight to local midnight, and DST-correct"
assert_eq "$(TZ=UTC "$WIN" bounds 2026-10-01 2026-10-02)" "$START $END" "a UTC day is 1790812800..1790899200"
# Every expected number below is a literal worked out separately (zoneinfo), not by the
# `date` call the helper uses.
assert_eq "$(TZ=America/New_York "$WIN" bounds 2026-10-01 2026-10-02)" "1790827200 1790913600" "New York: an ordinary day starts at 04:00Z, ends 24h later"
assert_eq "$(TZ=America/New_York "$WIN" bounds 2026-03-08 2026-03-09)" "1772946000 1773028800" "New York spring-forward 2026-03-08: 23 hours, exact bounds"
assert_eq "$(TZ=America/New_York "$WIN" bounds 2026-11-01 2026-11-02)" "1793505600 1793595600" "New York fall-back 2026-11-01: 25 hours, exact bounds"
assert_eq "$(TZ=Europe/London "$WIN" bounds 2026-03-29 2026-03-30)" "1774742400 1774825200" "London spring-forward 2026-03-29: 23 hours, exact bounds"
assert_eq "$(TZ=Europe/London "$WIN" bounds 2026-10-25 2026-10-26)" "1792882800 1792972800" "London fall-back 2026-10-25: 25 hours, exact bounds"
assert_eq "$(TZ=Australia/Sydney "$WIN" bounds 2026-10-04 2026-10-05)" "1791036000 1791118800" "Sydney spring-forward 2026-10-04: 23 hours, exact bounds (southern hemisphere)"
assert_eq "$(TZ=Australia/Sydney "$WIN" bounds 2026-04-05 2026-04-06)" "1775307600 1775397600" "Sydney fall-back 2026-04-05: 25 hours, exact bounds"
assert_eq "$(TZ=Asia/Kolkata "$WIN" bounds 2026-10-01 2026-10-02)" "1790793000 1790879400" "a half-hour offset zone (Kolkata) starts at 18:30Z the day before"
[ "$(rc_of "$WIN" bounds not-a-date 2026-10-02)" != "0" ] && ok "an invalid date is refused" || no "an invalid date is refused"
[ "$(rc_of "$WIN" bounds 2026-10-02 2026-10-01)" != "0" ] && ok "an end before the start is refused" || no "an end before the start is refused"
assert_eq "$(rc_of "$WIN" bounds 2026-10-01)" "2" "missing arguments exit 2 (usage)"
assert_eq "$(rc_of "$WIN" in-window "$TMP/x.jsonl" notanumber $END)" "2" "a non-numeric bound exits 2 (usage)"

echo "# window: in-window is yes / no / error, and a file with no clock is placed by its mtime"
{ rec "2026-10-01T05:00:00.500Z" a; } > "$TMP/in.jsonl"
{ rec "2026-09-30T23:59:59.999Z" a; } > "$TMP/before.jsonl"
{ rec "2026-10-02T00:00:00.000Z" a; } > "$TMP/after.jsonl"
{ rec "2026-10-01T00:00:00.500Z" a; } > "$TMP/startedge.jsonl"
{ rec "2026-10-01T00:00:00Z" a; } > "$TMP/startexact.jsonl"
{ rec "2026-10-01T23:59:59.999Z" a; } > "$TMP/endlast.jsonl"
{ rec "2026-09-30T10:00:00Z" a; rec "2026-10-01T10:00:00Z" b; rec "2026-10-03T10:00:00Z" c; } > "$TMP/mixed.jsonl"
{ printf '{"type":"summary","summary":"x"}\n'; printf 'not json at all\n'; } > "$TMP/nots.jsonl"
: > "$TMP/empty.jsonl"
{ printf 'garbage line\n'; rec "2026-09-30T10:00:00Z" a; printf '{broken\n'; } > "$TMP/malformed-out.jsonl"
{ printf 'garbage line\n'; rec "2026-10-01T10:00:00Z" a; printf '{broken\n'; } > "$TMP/malformed-in.jsonl"
assert_eq "$(rc_of "$WIN" in-window "$TMP/in.jsonl" $START $END)" "0" "a record inside the day -> yes"
assert_eq "$(rc_of "$WIN" in-window "$TMP/before.jsonl" $START $END)" "1" "only records before the day -> no"
assert_eq "$(rc_of "$WIN" in-window "$TMP/after.jsonl" $START $END)" "1" "a record at exactly the end (exclusive) -> no"
assert_eq "$(rc_of "$WIN" in-window "$TMP/startedge.jsonl" $START $END)" "0" "a fractional second just past the start -> yes"
assert_eq "$(rc_of "$WIN" in-window "$TMP/startexact.jsonl" $START $END)" "0" "a record at exactly the start (inclusive) -> yes"
assert_eq "$(rc_of "$WIN" in-window "$TMP/endlast.jsonl" $START $END)" "0" "23:59:59.999 is still inside the day -> yes"
assert_eq "$(rc_of "$WIN" in-window "$TMP/mixed.jsonl" $START $END)" "0" "before, inside and after -> yes"
assert_eq "$(rc_of "$WIN" in-window "$TMP/malformed-in.jsonl" $START $END)" "0" "malformed lines are skipped; the valid in-window record decides -> yes"
assert_eq "$(rc_of "$WIN" in-window "$TMP/malformed-out.jsonl" $START $END)" "1" "malformed lines are skipped; the valid out-of-window record decides -> no (not placed in the wrong day)"
# A file with no clock cannot be placed by its records, so its mtime decides, exactly as the
# bounded find used to: modified by the end of the day -> yes (bias to triage); modified AFTER
# the day -> no. Without that, dropping the find upper bound would enumerate a no-clock file on
# every later date too and triage it twice, filed under the wrong day.
touch -t 202610011200 "$TMP/nots.jsonl" "$TMP/empty.jsonl"
assert_eq "$(rc_of "$WIN" in-window "$TMP/nots.jsonl" $START $END)" "0" "no parseable timestamp, modified inside the day -> yes (the old mtime rule)"
assert_eq "$(rc_of "$WIN" in-window "$TMP/empty.jsonl" $START $END)" "0" "an empty file modified inside the day -> yes"
{ printf '{"type":"summary","summary":"x"}\n'; } > "$TMP/nots-late.jsonl"; : > "$TMP/empty-late.jsonl"
touch -t 202610031200 "$TMP/nots-late.jsonl" "$TMP/empty-late.jsonl"
assert_eq "$(rc_of "$WIN" in-window "$TMP/nots-late.jsonl" $START $END)" "1" "no parseable timestamp, modified AFTER the day -> no (the old mtime rule)"
assert_eq "$(rc_of "$WIN" in-window "$TMP/empty-late.jsonl" $START $END)" "1" "an empty file modified after the day -> no"
# A file whose records have clocks is placed by them even when it was touched later: this is
# the whole point of the window (#113).
cp "$TMP/in.jsonl" "$TMP/in-late.jsonl"; touch -t 202610051200 "$TMP/in-late.jsonl"
assert_eq "$(rc_of "$WIN" in-window "$TMP/in-late.jsonl" $START $END)" "0" "a file touched days after the day, with a record inside it -> yes"
cp "$TMP/before.jsonl" "$TMP/before-fresh.jsonl"; touch -t 202610011200 "$TMP/before-fresh.jsonl"
assert_eq "$(rc_of "$WIN" in-window "$TMP/before-fresh.jsonl" $START $END)" "1" "a file touched inside the day whose records are all older -> no (records outrank mtime)"
# The clock must be the shape the harnesses write. A numeric or offset timestamp is not read,
# so it neither selects a file nor misplaces it in a day.
printf '{"type":"x","timestamp":1790850000}\n{"type":"x","timestamp":"2026-10-01T10:00:00+00:00"}\n{"type":"x","timestamp":null}\n{"type":"x"}\n' > "$TMP/oddclock.jsonl"
touch -t 202610031200 "$TMP/oddclock.jsonl"
assert_eq "$(rc_of "$WIN" in-window "$TMP/oddclock.jsonl" $START $END)" "1" "numeric, offset, null and missing timestamps are no clock: placed by mtime (after the day -> no)"
# OMP puts an epoch-millisecond number on message.timestamp. Only the top-level string counts.
printf '{"type":"message","message":{"role":"user","timestamp":1790850000000}}\n' > "$TMP/omp-msgts.jsonl"
touch -t 202610031200 "$TMP/omp-msgts.jsonl"
assert_eq "$(rc_of "$WIN" in-window "$TMP/omp-msgts.jsonl" $START $END)" "1" "an OMP message.timestamp number is not a clock"
assert_eq "$(rc_of "$WIN" in-window "$TMP/missing.jsonl" $START $END)" "2" "an unreadable file is an ERROR (2), distinct from no (1)"

echo "# window: needs-slice says whether a file spills outside the day"
{ rec "2026-10-01T01:00:00Z" a; rec "2026-10-01T23:00:00Z" b; } > "$TMP/inside.jsonl"
{ rec "2026-09-30T23:00:00Z" a; rec "2026-10-01T10:00:00Z" b; } > "$TMP/starts-early.jsonl"
{ rec "2026-10-01T10:00:00Z" a; rec "2026-10-02T03:00:00Z" b; } > "$TMP/ends-late.jsonl"
{ for i in $(seq 1 100); do rec "2026-10-01T10:00:00Z" "t$i"; done; rec "2026-10-02T05:00:00Z" last; } > "$TMP/long-ends-late.jsonl"
assert_eq "$(rc_of "$WIN" needs-slice "$TMP/inside.jsonl" $START $END)" "1" "wholly inside the day -> no slice needed"
assert_eq "$(rc_of "$WIN" needs-slice "$TMP/starts-early.jsonl" $START $END)" "0" "first record before the day -> slice"
assert_eq "$(rc_of "$WIN" needs-slice "$TMP/ends-late.jsonl" $START $END)" "0" "last record after the day -> slice"
assert_eq "$(rc_of "$WIN" needs-slice "$TMP/long-ends-late.jsonl" $START $END)" "0" "a 101-line file whose LAST line is late -> slice"
assert_eq "$(rc_of "$WIN" needs-slice "$TMP/nots.jsonl" $START $END)" "1" "no timestamps -> nothing to slice by -> no"
{ for i in $(seq 1 250); do printf '{"type":"summary","summary":"s%d"}\n' "$i"; done
  rec "2026-09-30T10:00:00Z" before; rec "2026-10-01T10:00:00Z" inside; } > "$TMP/lead-clockless.jsonl"
assert_eq "$(rc_of "$WIN" needs-slice "$TMP/lead-clockless.jsonl" $START $END)" "0" "250 clockless lines before an earlier-day record -> still slice"
{ rec "2026-10-01T10:00:00Z" inside; rec "2026-10-02T09:00:00Z" late
  for i in $(seq 1 300); do printf '{"type":"summary","summary":"s%d"}\n' "$i"; done; } > "$TMP/trail-clockless.jsonl"
assert_eq "$(rc_of "$WIN" needs-slice "$TMP/trail-clockless.jsonl" $START $END)" "0" "a later-day record followed by 300 clockless lines -> still slice"
# A file that is not in order. The first and last records are inside the day, so a check of
# just those two would read it whole and leak another day's records into this one.
{ rec "2026-10-01T10:00:00Z" a; rec "2026-09-29T10:00:00Z" stray; rec "2026-10-01T20:00:00Z" b; } > "$TMP/out-of-order.jsonl"
assert_eq "$(rc_of "$WIN" needs-slice "$TMP/out-of-order.jsonl" $START $END)" "0" "an out-of-order record in the middle of an otherwise in-day file -> slice"
assert_eq "$(rc_of "$WIN" needs-slice "$TMP/missing.jsonl" $START $END)" "2" "an unreadable file is an ERROR (2)"

echo "# window: slice keeps exactly the in-window records, byte for byte"
{ rec "2026-09-30T10:00:00Z" before1; rec "2026-10-01T02:00:00Z" keep1
  printf 'torn line {"type":\n'
  printf '{"type":"summary","summary":"no clock"}\n'
  rec "2026-10-01T03:00:00.250Z" keep2; rec "2026-10-02T00:00:00Z" after1; rec "2026-10-01T23:59:59.999Z" keep3
  rec "2026-09-29T10:00:00Z" before2; } > "$TMP/slice-in.jsonl"
{ rec "2026-10-01T02:00:00Z" keep1; rec "2026-10-01T03:00:00.250Z" keep2; rec "2026-10-01T23:59:59.999Z" keep3; } > "$TMP/slice-want.jsonl"
"$WIN" slice "$TMP/slice-in.jsonl" $START $END > "$TMP/slice-got.jsonl" 2>/dev/null; src=$?
assert_eq "$src" "0" "slice exits 0 despite a torn line and a record with no clock"
assert_eq "$(cat "$TMP/slice-got.jsonl")" "$(cat "$TMP/slice-want.jsonl")" "only the three in-window records survive, in order, unmodified"
"$WIN" slice "$TMP/before.jsonl" $START $END > "$TMP/slice-none.jsonl" 2>/dev/null; src=$?
assert_eq "$src" "0" "a slice with nothing in window still exits 0"
assert_eq "$(wc -c < "$TMP/slice-none.jsonl" | tr -d ' ')" "0" "and writes nothing"
assert_eq "$(rc_of "$WIN" slice "$TMP/missing.jsonl" $START $END)" "2" "slice of an unreadable file is an ERROR (2)"
# The header the OMP linearizer writes carries no clock and no event. It names the session
# (cwd, advisor, nested), the stats and the project lookup read it, and every slice of that
# session keeps it.
{ printf '{"type":"autodream_meta","source":"omp","cwd":"/work/x","is_advisor":true,"nested":true}\n'
  rec "2026-09-30T10:00:00Z" early; rec "2026-10-01T10:00:00Z" keep; } > "$TMP/meta.jsonl"
"$WIN" slice "$TMP/meta.jsonl" $START $END > "$TMP/meta-got.jsonl"
assert_eq "$(jq -r .type "$TMP/meta-got.jsonl" | paste -sd, -)" "autodream_meta,user" "autodream_meta is kept ahead of the in-window records, the early record is not"
assert_eq "$(jq -r 'select(.type == "autodream_meta") | .is_advisor' "$TMP/meta-got.jsonl")" "true" "and it is the original header, byte for byte"

# A linearized OMP chain: entry N points at entry N-1. Cut to a day, the first kept entry
# points at an entry that is gone, which would make the slice an unreadable tree. It is
# written as a root; every other record keeps its bytes.
omp(){ printf '{"type":"message","id":"%s","parentId":%s,"timestamp":"%s","message":{"role":"user","timestamp":1790850000000}}\n' "$1" "$2" "$3"; }
{ printf '{"type":"autodream_meta","source":"omp","cwd":"/work/x"}\n'
  omp u1 null "2026-09-30T10:00:00.000Z"; omp a1 '"u1"' "2026-09-30T23:59:59.999Z"
  omp u2 '"a1"' "2026-10-01T00:00:00.000Z"; omp a2 '"u2"' "2026-10-01T10:00:00.000Z"
  omp u3 '"a2"' "2026-10-02T00:00:00.000Z"; } > "$TMP/omp-chain.jsonl"
"$WIN" slice "$TMP/omp-chain.jsonl" $START $END > "$TMP/omp-slice.jsonl"
assert_eq "$(jq -r 'select(.type == "message") | .id' "$TMP/omp-slice.jsonl" | paste -sd, -)" "u2,a2" "an OMP chain is cut to the entries inside the day"
assert_eq "$(jq -c 'select(.id == "u2") | .parentId' "$TMP/omp-slice.jsonl")" "null" "the first kept entry, whose parent was cut away, becomes a root"
assert_eq "$(grep '"id":"a2"' "$TMP/omp-slice.jsonl")" "$(grep '"id":"a2"' "$TMP/omp-chain.jsonl")" "every other entry keeps its bytes"
assert_eq "$(jq -s '[.[] | select(.type == "message")] as $m | ($m | map(.id)) as $ids | [$m[] | select(.parentId != null and (.parentId | IN($ids[]) | not))] | length' "$TMP/omp-slice.jsonl")" "0" "no parentId in the slice names an entry the slice dropped"
assert_eq "$(jq -c 'select(.id == "u2") | .message.timestamp' "$TMP/omp-slice.jsonl")" "1790850000000" "re-writing that one entry leaves the rest of it as it was"
# A chain that starts inside the day is not touched at all.
{ printf '{"type":"autodream_meta","source":"omp"}\n'; omp u1 null "2026-10-01T10:00:00.000Z"; omp a1 '"u1"' "2026-10-01T11:00:00.000Z"; } > "$TMP/omp-whole.jsonl"
"$WIN" slice "$TMP/omp-whole.jsonl" $START $END > "$TMP/omp-whole-got.jsonl"
assert_eq "$(cat "$TMP/omp-whole-got.jsonl")" "$(cat "$TMP/omp-whole.jsonl")" "a chain wholly inside the day is returned byte for byte"
# Claude records link by parentUuid, a different key, and are never rewritten.
{ printf '{"type":"user","uuid":"c1","parentUuid":"c0","timestamp":"2026-10-01T10:00:00Z"}\n'; } > "$TMP/claude-link.jsonl"
"$WIN" slice "$TMP/claude-link.jsonl" $START $END > "$TMP/claude-link-got.jsonl"
assert_eq "$(cat "$TMP/claude-link-got.jsonl")" "$(cat "$TMP/claude-link.jsonl")" "a Claude record linking by parentUuid is not rewritten"

echo "# window: day-file writes the slice for a file that spills, and says when it did not"
out="$TMP/day.jsonl"
touch -t 202610051200 "$TMP/slice-in.jsonl"
rm -f "$out"; "$WIN" day-file "$TMP/slice-in.jsonl" $START $END "$out" >/dev/null 2>&1; src=$?
assert_eq "$src" "0" "a file that spills outside the day -> 0 and the slice is written"
assert_eq "$(cat "$out")" "$(cat "$TMP/slice-want.jsonl")" "the slice holds exactly the in-window records"
assert_eq "$(pstat_mtime "$out")" "$(pstat_mtime "$TMP/slice-in.jsonl")" "the slice carries the original mtime (the stats transcript_mtime stays the session's)"
assert_eq "$(ls "$TMP" | grep -c '^day\.jsonl\.tmp\.')" "0" "no temp file is left beside the slice"
rm -f "$out"; "$WIN" day-file "$TMP/inside.jsonl" $START $END "$out" >/dev/null 2>&1; src=$?
assert_eq "$src" "1" "a file wholly inside the day -> 1, nothing to cut"
[ ! -e "$out" ] && ok "and no output file is created for it" || no "and no output file is created for it"
# A file whose records the window cannot place leaves nothing to read, which must not stand in
# for the session: an error, so the caller reads the whole transcript instead.
{ rec "2026-09-30T10:00:00Z" only-before; } > "$TMP/spill-empty.jsonl"
rm -f "$out"; "$WIN" day-file "$TMP/spill-empty.jsonl" $START $END "$out" >/dev/null 2>&1; src=$?
assert_eq "$src" "2" "a file with no in-window record at all -> 2 (an empty slice is not a verdict)"
[ ! -e "$out" ] && ok "and no empty slice is left behind" || no "and no empty slice is left behind"
assert_eq "$(ls "$TMP" | grep -c '^day\.jsonl\.tmp\.')" "0" "and no temp file either"
assert_eq "$(rc_of "$WIN" day-file "$TMP/missing.jsonl" $START $END "$out")" "2" "an unreadable file -> 2"
mkdir "$TMP/adir"
assert_eq "$(rc_of "$WIN" day-file "$TMP/slice-in.jsonl" $START $END "$TMP/adir")" "2" "a directory at the destination is refused"
assert_eq "$(ls -A "$TMP/adir" | wc -l | tr -d ' ')" "0" "and nothing is written inside it"
assert_eq "$(rc_of "$WIN" day-file "$TMP/slice-in.jsonl" $START $END)" "2" "a missing output argument exits 2 (usage)"

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
