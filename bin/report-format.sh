#!/bin/bash
# Sourced, never executed. The contracts a report and L2's capture carry, read in one place.
#
#   The marker   `<!-- autodream:open-questions=N -->`, which says how many questions need a human
#                call and, by being the last thing PROMPT.md emits, that the write reached its end.
#   The block    `AUTODREAM_QUESTIONS_BEGIN` / `AUTODREAM_QUESTIONS_END`, which bracket the open
#                questions section. The section is read by four consumers (notify.sh, review.sh,
#                question-streaks.sh, triage-dream.sh) and used to be found by matching a markdown
#                heading, which each of them approximated differently. A heading can appear in a
#                code fence, in prose, or inside another heading, and every approximation meant a
#                consumer disagreed with the others about where the section ended. Two sentinel
#                lines cannot be anything else.
#   The sentinel `AUTODREAM_REPORT_END` on a line of its own, which L2 prints after the report. What
#                comes before the LAST one is the report; what follows is the pin block and the
#                summary. The runner and the triage worklist both split L2's stdout on it.
#
# run.sh, notify.sh, question-streaks.sh, triage-dream.sh, review.sh and pending-triage.sh all read
# these, so they read them here. Every function takes the report (or L2's captured stdout) as $1 and
# hands the status of its last command to the caller, so `report_body f > f.tmp && mv f.tmp f` stops
# when the read fails.

QUESTIONS_BEGIN='AUTODREAM_QUESTIONS_BEGIN'
QUESTIONS_END='AUTODREAM_QUESTIONS_END'
# Reports written before the block existed are read the old way: heading to the next `## ` or a
# horizontal rule. Newer reports must carry the block (run.sh checks report_has_questions_block
# against this epoch) so the fallback only ever serves legacy dates.
QUESTIONS_EPOCH_DEFAULT='2026-10-27'

# The question count inside the marker, as digits, or nothing. Strict: the comment has to be well
# formed, and the first one wins. question-streaks.sh and notify.sh trust this and nothing looser.
report_marker_count(){
  sed -n 's/.*<!-- *autodream:open-questions=\([0-9][0-9]*\) *-->.*/\1/p' "$1" 2>/dev/null | head -1
}

# Whether any line holds the marker key. Loose on purpose: run.sh asks only "did the write reach the
# end", and a truncated report that still carries the key counts. A report whose marker is malformed
# passes here and fails report_marker_count, which is how question-streaks.sh refuses to clear a
# streak on it.
report_has_marker(){ grep -q 'autodream:open-questions=' "$1" 2>/dev/null; }

# Whether L2 delivered its sentinel. The line must be exactly the sentinel: indented, CRLF or quoted
# in prose it is not one.
report_has_sentinel(){ grep -q '^AUTODREAM_REPORT_END$' "$1" 2>/dev/null; }

# Whether the report carries a closed questions block: a BEGIN line with an END line after it,
# both on lines of their own. The LAST END wins, so a question that quotes the sentinel inside a
# code example does not end the block early — the producer emits one block and its END is the one
# at the end.
report_has_questions_block(){
  awk -v b="$QUESTIONS_BEGIN" -v e="$QUESTIONS_END" '
    $0 == b { open = 1; next }
    $0 == e { if (open) { closed = 1 } }
    END { exit closed ? 0 : 1 }' "$1" 2>/dev/null
}

# The open questions section: the text between the FIRST begin sentinel and the LAST end sentinel
# when the report carries them, otherwise the legacy markdown section. Prints nothing when the
# report has neither.
report_questions(){
  local report="$1"
  if report_has_questions_block "$report"; then
    awk -v b="$QUESTIONS_BEGIN" -v e="$QUESTIONS_END" '
      $0 == b { if (!open) { open = 1 }; next }
      open { line[++n] = $0; if ($0 == e) last = n }
      END { for (i = 1; i < last; i++) print line[i] }' "$report" 2>/dev/null
    return 0
  fi
  # Legacy reports predate the block, so this path only ever serves history. It keeps the fence
  # tracking the block made unnecessary: a heading quoted inside a code example is not the end of
  # the section, and dropping that was a review finding when the fallback was written.
  awk '
    {
      if ($0 ~ /^[ \t]*(```+|~~~+)/) {
        tmp = $0; sub(/^[ \t]*/, "", tmp); ch = substr(tmp, 1, 1); n = 0
        while (substr(tmp, n + 1, 1) == ch) n++
        blank = (substr(tmp, n + 1) ~ /^[ \t\r]*$/)
        if (fence == "") { fence = ch; flen = n }
        else if (ch == fence && n >= flen && blank) { fence = ""; flen = 0 }
      }
      if (!capture) { if (fence == "" && $0 ~ /^## Open questions/) { capture = 1 }; next }
      if (fence == "" && $0 ~ /^## /) exit
      if (fence == "" && $0 ~ /^---[[:space:]]*$/) exit
      print
    }' "$report" 2>/dev/null
}

# The completeness predicate for ONE report file and its date, in one place so the run's live gate,
# the abandoned-date sweep and the pin sweep cannot disagree about whether a date is finished.
# $1=report file $2=date label ("" skips the block check, for callers that have only a file).
report_finishes(){
  local report="$1" date_label="${2:-}" epoch
  [ -s "$report" ] || return 1
  report_has_marker "$report" || return 1
  [ -n "$date_label" ] || return 0
  epoch="${AUTODREAM_QUESTIONS_EPOCH:-$QUESTIONS_EPOCH_DEFAULT}"
  # ISO dates compare lexicographically, so this is chronological.
  if [[ ! "$date_label" < "$epoch" ]]; then
    report_has_questions_block "$report" || return 1
  fi
  return 0
}

# Everything before the LAST sentinel: the report itself. Prints nothing when there is none.
report_body(){
  awk '/^AUTODREAM_REPORT_END$/ { last=NR } { line[NR]=$0 } END { for (i=1; i<last; i++) print line[i] }' "$1"
}

# Everything after the first sentinel, with every sentinel line dropped: the pin block, the report
# path and the summary, for the run log.
report_after_sentinel(){ awk '/^AUTODREAM_REPORT_END$/ { f=1; next } f { print }' "$1" 2>/dev/null; }

# The proposed pins: JSON-object lines of a CLOSED pin block that follows the LAST sentinel. A block
# quoted in the report body cannot inject a pin, and a capture cut off before PINS_END proposes
# nothing rather than half a pin. apply-pins.sh still validates every line it gets.
report_pin_lines(){
  awk '
    /^AUTODREAM_REPORT_END$/ { last = NR }
    { line[NR] = $0 }
    END {
      for (i = last + 1; i <= NR; i++) {
        if (!inb && line[i] == "AUTODREAM_PINS_BEGIN") { inb = 1; continue }
        if (inb && line[i] == "AUTODREAM_PINS_END") { closed = 1; break }
        if (inb) buf[++n] = line[i]
      }
      if (closed) for (j = 1; j <= n; j++) if (buf[j] ~ /^\{/) print buf[j]
    }' "$1" 2>/dev/null
}

# How many open questions the report says need a human call. Prints an integer,
# or "unknown" when it cannot tell (the caller must then launch the session).
#
# The marker is the contract: PROMPT.md makes L2 emit
# `<!-- autodream:open-questions=N -->` in the Open questions section. Reports
# written before that contract existed have no marker, so we fall back to
# reading the prose L2 has used consistently ("None that clear the triviality
# gate this run."). The fallback only ever recognises a shape it is sure about;
# everything else is "unknown" rather than a guess.
report_open_questions(){
  local report="$1" marker section first

  marker=$(report_marker_count "$report")
  if [ -n "$marker" ]; then printf '%s\n' "$marker"; return 0; fi

  # Empty-day stub: run.sh writes this when no sessions were modified at all.
  if grep -q '^No Claude Code sessions were modified' "$report"; then echo 0; return 0; fi

  section=$(awk '/^## Open questions/{f=1;next} /^## /{f=0} f' "$report")
  first=$(printf '%s\n' "$section" | grep -v '^[[:space:]]*$' | head -1)
  # No section at all, or an empty one: not a shape we recognise. Launch.
  [ -n "$first" ] || { echo unknown; return 0; }

  case "$(printf '%s' "$first" | tr '[:upper:]' '[:lower:]')" in
    none*) echo 0; return 0 ;;
  esac
  echo unknown
}

report_is_triaged(){ grep -q '^## Triage decisions' "$1"; }

# How many decisions a session has logged so far under "## Triage in progress". Bullets or
# numbered lines, as review.sh counts "## Triage decisions".
report_progress_count(){
  awk '/^## Triage in progress/{f=1;next} /^## /{f=0} f' "$1" | grep -cE '^([-*]|[0-9]+\.) ' || true
}
