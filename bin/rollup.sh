#!/bin/bash
# rollup.sh — one row per session and one tally per finding category, for Layer 2 to count from.
#
# Usage:  rollup.sh <findings-dir> [<out-dir>]      (out-dir defaults to the findings dir)
# Writes: <out-dir>/rollup.tsv      header, then one row per session, ungated and gated alike
#         <out-dir>/categories.tsv  header, then category, severity, sessions, findings, example hashes
#         <out-dir>/findings.tsv    header, then hash, category, severity, what: one row per finding,
#                                   so L2 can count a pattern narrower than a category
# Stdout: one line, "rollup: rows=N triaged=N gated=N error=N unreadable=N ungated=N categories=N
#         findings=N advisor_tool_findings=N"
# Exit:   0 written, 1 a file could not be written, 2 usage (no such dir, no jq)
#
# Why. L2 reads with Glob and Read, and both stop at 200 entries. A findings dir holds three files
# per session plus about 28 side files, so on 2026-10-31 (885 sessions, 2683 entries) L2 counted
# from a 90-file sample and never saw fanouts.tsv. The counting moved here, where nothing caps it,
# and L2 opens a single <hash>.json only to quote evidence.
#
# Read-only on the findings dir. Inputs, all by exact name: <hash>.json (12 hex), its
# <hash>.stats.json sidecar, sessions-source.txt (hash, harness) and fanouts.tsv (worker, parent).
# A malformed findings JSON or sidecar costs its own row's cells, never the table: each session is
# read by its own jq call, and a cell nothing measured is blank, never 0.
#
# Columns of rollup.tsv:
#   hash status project source nested is_advisor parent outcome user_message_count turn_count
#   tool_call_count duration_minutes models_used findings skills_invoked_count skills_invoked_counts
#   skills_authored instructions_given_count sandbox_shape_denies
# status is triaged, gated (the noise gate's "skipped": "below_noise_gate" stub), error (the record
# has an "error" key) or unreadable (the findings JSON does not parse, or its findings is not an
# array, checked before the gate). Every status but gated is the set compute_fanout_stats in run.sh
# calls the report's N; the one difference is a gated stub whose findings is not an array, which
# that function reads as gated by its text and this script calls unreadable. nested is the
# sidecar's isSidechain or nested, the same test fanout_rows applies. parent comes from
# fanouts.tsv, which holds ungated workers only, so a gated child reads nested with a blank
# parent. findings is a comma list of category:severity, and skills_invoked_counts a comma list
# of name=count (skill names carry ':').
# skills_authored is a comma list, and instructions_given_count the length of instructions_given,
# so L2 knows which sessions to open for the compliance check without opening every one.
# sandbox_shape_denies is the sidecar's count of denies signed by the sandbox-shape guard. It is
# blank, never 0, when the sidecar is missing, broken, predates the field, holds a non-number, or
# comes from a harness that does not measure it (omp).
# Text cells are escaped by jq's @tsv, so a tab or newline in a value never breaks a row.

set -u
# A failed stage anywhere in a pipeline (a sort with no temp space) fails the write, so a broken
# tally can never be published as a genuine zero.
set -o pipefail

DIR=${1:-}
OUT=${2:-$DIR}
[ -n "$DIR" ] && [ -d "$DIR" ] || { echo "rollup.sh: no findings dir: '${DIR}'" >&2; exit 2; }
[ -d "$OUT" ] || { echo "rollup.sh: no output dir: '${OUT}'" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "rollup.sh: jq not found" >&2; exit 2; }

ROLLUP_HEADER='hash	status	project	source	nested	is_advisor	parent	outcome	user_message_count	turn_count	tool_call_count	duration_minutes	models_used	findings	skills_invoked_count	skills_invoked_counts	skills_authored	instructions_given_count	sandbox_shape_denies'
CATEGORIES_HEADER='category	severity	sessions	findings	example_hashes'
FINDINGS_HEADER='hash	category	severity	what'

# One findings JSON (stdin: the record; $st: the sidecar, [] when missing or unreadable) -> an
# "R" line holding the row without its source and parent columns, which awk joins in afterwards,
# then one "F" line per finding for findings.tsv.
# shellcheck disable=SC2016 # jq program, not shell
ROW_JQ='
  def cell: if . == null then "" else tostring end;
  def word: tostring | gsub("[,:\t\n\r]"; "_");
  def skill: tostring | gsub("[,=\t\n\r]"; "_");
  if length == 1 and (.[0] | type) == "object" then .[0] else error("not one object") end
  | ($st[0] // null) as $s
  | if $s != null and ($s | type) != "object" then error("sidecar not an object") else . end
  | (if (.findings | type) == "array" then .findings else [] end) as $f
  | ([ "R", $h,
      (if (.findings | type) != "array" then "unreadable"
       elif .skipped == "below_noise_gate" then "gated" elif has("error") then "error" else "triaged" end),
      (.project | cell),
      (if $s then ($s.isSidechain == true or $s.nested == true) else null end | cell),
      (if $s then ($s.is_advisor == true) elif has("is_advisor") then (.is_advisor == true) else null end | cell),
      (.outcome | cell),
      ($s.user_message_count | cell), ($s.turn_count | cell), ($s.tool_call_count | cell),
      ($s.duration_minutes | cell),
      (if ($s.models_used | type) == "array" then ($s.models_used | map(tostring) | join(",")) else "" end),
      ($f | map(select(type == "object")
                | "\(.category // "unknown" | word):\(.severity // "unknown" | word)") | join(",")),
      (.skills_invoked_count | cell),
      (if (.skills_invoked_counts | type) == "object"
       then (.skills_invoked_counts | to_entries | map("\(.key | skill)=\(.value)") | join(","))
       else "" end),
      (if (.skills_authored | type) == "array" then (.skills_authored | map(skill) | join(",")) else "" end),
      (if (.instructions_given | type) == "array" then (.instructions_given | length) else null end | cell),
      (if ($s.sandbox_shape_denies | type) == "number" then $s.sandbox_shape_denies else null end | cell)
    ] | @tsv),
    ($f[] | select(type == "object")
     | ["F", $h, (.category // "unknown" | word), (.severity // "unknown" | word), (.what // "" | tostring)]
     | @tsv)'

# The sidecar's counts for a findings JSON that does not parse, so the row still says how big
# the session was.
# shellcheck disable=SC2016
UNREADABLE_JQ='
  def cell: if . == null then "" else tostring end;
  ($st[0] // null) as $s
  | if $s != null and ($s | type) != "object" then error("sidecar not an object") else . end
  | [ "R", $h, "unreadable", "",
      (if $s then ($s.isSidechain == true or $s.nested == true) else null end | cell),
      (if $s then ($s.is_advisor == true) else null end | cell),
      "",
      ($s.user_message_count | cell), ($s.turn_count | cell), ($s.tool_call_count | cell),
      ($s.duration_minutes | cell),
      (if ($s.models_used | type) == "array" then ($s.models_used | map(tostring) | join(",")) else "" end),
      "", "", "", "", "",
      (if ($s.sandbox_shape_denies | type) == "number" then $s.sandbox_shape_denies else null end | cell) ] | @tsv'

# $1=hash -> one row (17 columns) on stdout. The first program that succeeds wins: the record
# with its sidecar, the record alone (a sidecar that does not parse or is not an object), the
# sidecar alone (a record that does not parse), then the bare hash.
session_row() {
  local h=$1 rec="$DIR/$1.json" st="$DIR/$1.stats.json"
  [ -s "$st" ] || st=/dev/null
  jq -s -r --arg h "$h" --slurpfile st "$st" "$ROW_JQ" "$rec" 2>/dev/null && return 0
  jq -s -r --arg h "$h" --slurpfile st /dev/null "$ROW_JQ" "$rec" 2>/dev/null && return 0
  jq -n -r --arg h "$h" --slurpfile st "$st" "$UNREADABLE_JQ" 2>/dev/null && return 0
  jq -n -r --arg h "$h" --slurpfile st /dev/null "$UNREADABLE_JQ"
}

# Every 12-hex findings JSON directly in the dir, in hash order. Sidecars, .served/.err files,
# side files and anything under outside-worklist/ never match.
session_hashes() {
  local f b
  for f in "$DIR"/*.json; do
    [ -f "$f" ] || continue
    b=${f##*/}; b=${b%.json}
    case "$b" in *[!0-9a-f]*) continue ;; esac
    [ "${#b}" -eq 12 ] || continue
    printf '%s\n' "$b"
  done | LC_ALL=C sort
}

# stdin: 17-column rows -> 19 columns, source after project and parent after is_advisor.
# The source comes from AUTODREAM_SOURCE_MAP when the runner passes it: that map was built before
# any model ran, and an L1 worker holds the Write tool and can rewrite sessions-source.txt. The
# file is the fallback for a standalone run.
join_source_parent() {
  awk -F'\t' -v OFS='\t' -v src="$DIR/sessions-source.txt" -v fan="$DIR/fanouts.tsv" '
    BEGIN {
      if (ENVIRON["AUTODREAM_SOURCE_MAP"] != "") {
        n = split(ENVIRON["AUTODREAM_SOURCE_MAP"], lines, "\n")
        for (i = 1; i <= n; i++) { split(lines[i], a, "\t"); if (a[1] != "" && !(a[1] in s)) s[a[1]] = a[2] }
      } else {
        while ((getline line < src) > 0) { split(line, a, "\t"); if (!(a[1] in s)) s[a[1]] = a[2] }
      }
      while ((getline line < fan) > 0) { split(line, a, "\t"); if (!(a[1] in p)) p[a[1]] = a[2] }
    }
    { print $1, $2, $3, s[$1], $4, $5, p[$1], $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17 }'
}

# stdin: rollup.tsv body -> categories.tsv body. One row per category and severity, plus one
# row per category with severity "all", whose sessions column is the category's count across
# severities (a session with a high and a low finding counts once there). An advisor's findings
# are counted under its parent session, so a parent and its advisor with the same finding are one
# session, as PROMPT.md asks; the example hashes stay the real ones. An advisor's tool-behavior
# findings (sandbox_friction, tool_loop, missed_skill) are not counted at all: L1 suppresses them
# for advisors, so one that arrives is a triage failure, which L2 reads from rollup.tsv. Ordered
# by the category's total findings, then category, then all, high, medium, low.
tally_categories() {
  awk -F'\t' -v OFS='\t' '
    BEGIN { advisor_tool["sandbox_friction"]; advisor_tool["tool_loop"]; advisor_tool["missed_skill"] }
    $14 != "" {
      owner = ($6 == "true" && $7 != "") ? $7 : $1
      n = split($14, f, ",")
      for (i = 1; i <= n; i++) {
        c = f[i]; sub(/:[^:]*$/, "", c)
        if ($6 == "true" && (c in advisor_tool)) continue
        count(f[i], owner, $1); count(c ":all", owner, $1)
      }
    }
    function count(k, owner, h) {
      findings[k]++
      if (!((k, owner) in owned)) { owned[k, owner] = 1; sessions[k]++ }
      if (!((k, h) in shown) && examples[k] < 5) {
        shown[k, h] = 1; examples[k]++
        ex[k] = (ex[k] == "" ? h : ex[k] "," h)
      }
    }
    END {
      rank["all"] = 0; rank["high"] = 1; rank["medium"] = 2; rank["low"] = 3
      for (k in findings) {
        c = k; sub(/:[^:]*$/, "", c); v = k; sub(/^.*:/, "", v)
        r = (v in rank) ? rank[v] : 4
        print findings[c ":all"], c, r, v, sessions[k], findings[k], ex[k]
      }
    }' | LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2,2 -k3,3n | cut -f2,4-
}

# $1=header $2=final path; stdin = body. A temp beside the target and one rename, so a reader
# never sees half a file and a failed write leaves no temp behind.
write_atomic() {
  local tmp
  tmp=$(mktemp "$2.tmp.XXXXXX" 2>/dev/null) || return 1
  if { printf '%s\n' "$1"; cat; } > "$tmp" && mv -f "$tmp" "$2"; then return 0; fi
  rm -f "$tmp"; return 1
}

# Each stage is checked: under pipefail a failed jq, awk or sort fails the run instead of
# publishing a short table.
RAW=$(session_hashes | while IFS= read -r h; do session_row "$h" || exit 1; done) \
  || { echo "rollup.sh: reading the findings failed" >&2; exit 1; }
BODY=$(printf '%s\n' "$RAW" | awk '/^R\t/ { print substr($0, 3) }' | join_source_parent) \
  || { echo "rollup.sh: building rollup rows failed" >&2; exit 1; }
FINDS=$(printf '%s\n' "$RAW" | awk '/^F\t/ { print substr($0, 3) }') \
  || { echo "rollup.sh: building finding rows failed" >&2; exit 1; }
CATS=$(printf '%s\n' "$BODY" | sed '/^$/d' | tally_categories) \
  || { echo "rollup.sh: tallying categories failed" >&2; exit 1; }

# $1=body $2=header $3=file name
publish() {
  printf '%s\n' "$1" | sed '/^$/d' | write_atomic "$2" "$OUT/$3" \
    || { echo "rollup.sh: could not write $OUT/$3" >&2; exit 1; }
}
publish "$BODY" "$ROLLUP_HEADER" rollup.tsv
publish "$CATS" "$CATEGORIES_HEADER" categories.tsv
publish "$FINDS" "$FINDINGS_HEADER" findings.tsv

printf '%s\n' "$BODY" | awk -F'\t' \
  -v cats="$(printf '%s\n' "$CATS" | awk -F'\t' '$2 == "all"' | wc -l | tr -d ' ')" \
  -v finds="$(printf '%s\n' "$FINDS" | sed '/^$/d' | wc -l | tr -d ' ')" '
  NF {
    rows++; n[$2]++
    if ($6 == "true") {
      k = split($14, f, ",")
      for (i = 1; i <= k; i++) if (f[i] ~ /^(sandbox_friction|tool_loop|missed_skill):/) adv++
    }
  }
  END {
    printf "rollup: rows=%d triaged=%d gated=%d error=%d unreadable=%d ungated=%d categories=%d findings=%d advisor_tool_findings=%d\n",
      rows, n["triaged"], n["gated"], n["error"], n["unreadable"], rows - n["gated"], cats, finds, adv
  }'
