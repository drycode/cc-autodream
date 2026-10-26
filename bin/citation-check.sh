#!/bin/bash
# Resolve every session citation in a finished report against the findings dir it was
# aggregated from. Deterministic, model-free: artifacts only, no network, no model calls.
#
# Why this exists. L2 cites sessions by their 12-hex findings hash. On 2026-08-18 the
# top-ranked pattern quoted `47eba605cf1e` at "line 439/456/471" with a detailed
# `kSecUseAuthenticationUISkip` diagnosis — but that session was noise-gated, so its
# findings record is a bare stub:
#     {"session_path":"...","skipped":"below_noise_gate","findings":[],"project":"-p"}
# The quote actually lives in 6f38f3cbed43, a different session in the same project. The
# analysis was sound and the content real; only the ID was wrong, and an open question
# inherited the bad ID. A gated stub still carries `project`, which is exactly what makes
# the wrong hash look plausible to the aggregator.
#
# 10 of 11 citations that night resolved correctly, so this is a per-citation defect
# rather than a broken report — the kind that survives review because spot-checking one
# or two citations passes. Counting it makes it visible from the artifact, which is how
# every other regression in this repo is caught. No verdict, no gating: the report still
# ships, the morning review just knows which citations not to trust.
#
# Usage:
#   citation-check.sh <report.md> <findings-dir>
#
# Prints KEY: VALUE lines on stdout (the caller decides where they land — run.sh appends
# them to run-stats.txt):
#   citations_total       distinct 12-hex hashes cited in the report
#   citations_unresolved  cited hashes with no findings record at all
#   citations_to_gated    cited hashes whose record is a noise-gate stub
#   citations_unresolved_list / citations_to_gated_list   the offending hashes, or empty
#
# Exit 0 whenever the check ran, whatever it found: a citation defect is a reported
# measurement, not a runner failure. Exit 2 only when it could not run at all (missing
# report, missing findings dir, no jq) so a silent 0/0/0 can never be mistaken for a
# clean report.
set -uo pipefail

report="${1:-}"
fdir="${2:-}"

if [ -z "$report" ] || [ -z "$fdir" ]; then
  echo "usage: $0 <report.md> <findings-dir>" >&2
  exit 2
fi
[ -s "$report" ] || { echo "citation-check: report not readable: $report" >&2; exit 2; }
[ -d "$fdir" ]   || { echo "citation-check: findings dir not readable: $fdir" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "citation-check: jq not available" >&2; exit 2; }

# Citations appear in two shapes, because L2 formatting varies run to run: backticked
# (`47eba605cf1e`) and bare in a comma list ((c7b79782412d, 98e07eeaad42, ...)). Matching
# only the backticked form scored the 2026-08-18 pre-fix report at citations_total: 0 —
# a false all-clear, the single output this check exists to prevent. So: any 12-hex run
# whose neighbours are not hex. A 40-char commit SHA is therefore not split into
# citations, and a 7-char short SHA is too short to match.
#
# The bias is deliberate and one-directional: a stray hex token surfaces as unresolved
# (a false alarm a human dismisses in seconds), never as a clean report. Same judgement
# as the substantive filter, which keeps an unparseable session rather than dropping it.
#
# Implementation: replace every non-hex character with a space, split to one token per
# line, keep tokens that are exactly 12 hex characters. That is the boundary rule without
# needing \K, which BSD grep lacks.
hashes=$(sed 's/[^0-9a-f]/ /g' "$report" 2>/dev/null \
         | tr ' ' '\n' \
         | grep -xE '[0-9a-f]{12}' \
         | sort -u)
total=0; unresolved=0; gated=0; by_path=0
unresolved_list=""; gated_list=""

# Second resolution route. A cited 12-hex token is not always a findings hash: session
# filenames are UUIDs, and their last group is 12 hex characters, so an aggregator that
# cites a session by filename tail produces a token that resolves to nothing under the
# hash rule. Observed on 2026-08-18 (`87b5b1392572`, the tail of a real, triaged session).
# Those are genuine citations to genuine sessions, so counting them as unresolved would
# train the reader to ignore this counter — the exact failure this check exists to avoid.
# Build the index once: every session_path any findings record claims.
session_paths="$(jq -r -s '[ .[] | select(type == "object") | .session_path // empty ] | .[]' \
                   "$fdir"/*.json 2>/dev/null || true)"

for h in $hashes; do
  total=$((total + 1))
  f="$fdir/$h.json"
  if [ ! -s "$f" ]; then
    # Not a findings hash. Before calling it unresolved, try the session-id route: a
    # substring match against the session paths this run actually triaged.
    if printf '%s\n' "$session_paths" | grep -qF "$h" 2>/dev/null; then
      by_path=$((by_path + 1))
    else
      unresolved=$((unresolved + 1))
      unresolved_list="${unresolved_list:+$unresolved_list,}$h"
    fi
    continue
  fi
  # A gated record is the specific failure worth naming: the aggregator cited a session
  # whose content it never received. Malformed JSON counts as unresolved rather than
  # clean — the point is to never report a false all-clear.
  verdict=$(jq -r 'if (.skipped // "") == "below_noise_gate" then "gated" else "ok" end' "$f" 2>/dev/null) || verdict="bad"
  case "$verdict" in
    gated)
      gated=$((gated + 1))
      gated_list="${gated_list:+$gated_list,}$h"
      ;;
    ok) ;;
    *)
      unresolved=$((unresolved + 1))
      unresolved_list="${unresolved_list:+$unresolved_list,}$h"
      ;;
  esac
done

printf 'citations_total: %s\n' "$total"
printf 'citations_unresolved: %s\n' "$unresolved"
printf 'citations_to_gated: %s\n' "$gated"
printf 'citations_resolved_by_path: %s\n' "$by_path"
printf 'citations_unresolved_list: %s\n' "$unresolved_list"
printf 'citations_to_gated_list: %s\n' "$gated_list"
exit 0
