#!/bin/bash
# Local-day window over a session transcript. Contract: tests/session-window.sh.
#
#   session-window.sh bounds DATE NEXT_DATE         prints "START_EPOCH END_EPOCH"
#   session-window.sh in-window FILE START END      exit 0 yes, 1 no, 2 error
#   session-window.sh needs-slice FILE START END    exit 0 yes, 1 no, 2 error
#   session-window.sh slice FILE START END          in-window lines on stdout (unmodified, bar one parentId)
#   session-window.sh day-file FILE START END OUT   exit 0 wrote OUT, 1 no slice needed, 2 error
#
# Why. Enumeration selected a session by file mtime inside the report day, so a session
# that was written to again after the day closed (a resumed one, or one still running)
# vanished from every later rebuild of that day, and a transcript that spans several days
# was read whole for each of them. The in-transcript timestamp is what says which day a
# record belongs to. The window is [START, END): local midnight to the next local
# midnight, computed with BSD date so a 23h or 25h DST day comes out right.
#
# The timestamp is the TOP-LEVEL `.timestamp` string, which both harnesses write
# (`2026-10-01T16:12:38.483Z`). An OMP `.message.timestamp` is an epoch-millisecond number
# on a record that already carries the string, so it is deliberately not read. A record
# whose timestamp is missing, not a string, or not ISO-8601 UTC has no clock: it neither
# selects a file nor lands in a slice.
#
# in-window answers YES when it cannot tell (no parseable timestamp anywhere) and the file
# was last modified before the day ended, so a transcript without a clock is placed by its
# mtime exactly as the bounded find placed it. An unreadable file is an ERROR (2), never a
# no: the caller keeps the session on an error, so a broken helper costs extra work and
# never reads as a quiet night.
#
# Timestamps are compared as epoch seconds, not as strings: "00.5Z" sorts before "00Z"
# lexicographically, which would misplace the boundary second. The fraction is dropped, so
# 23:59:59.999 is still second 23:59:59 and 00:00:00.5 is second 0, which is exactly what
# a half-open window over whole-second bounds means.
set -u

_pp="$(dirname "${BASH_SOURCE[0]}")/portable.sh"
# Installed copies are symlinks: a merge updates them before install.sh links a new helper.
[ -r "$_pp" ] || _pp="$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/portable.sh"
# shellcheck source=/dev/null
. "$_pp"

# Shared by every jq program below. No apostrophes anywhere in these programs: they sit
# inside single-quoted shell strings, and one stray quote ends the string.
TS_DEF='def ts: (try .timestamp catch null)
  | select(type == "string")
  | try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch empty;'

usage() {
  echo "usage: $0 bounds DATE NEXT_DATE | in-window|needs-slice|slice FILE START END | day-file FILE START END OUT" >&2
  exit 2
}

is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

cmd="${1:-}"
case "$cmd" in
  bounds)
    [ "$#" -eq 3 ] || usage
    a=$(pdate_epoch "$2 00:00:00") || exit 1
    b=$(pdate_epoch "$3 00:00:00") || exit 1
    is_int "$a" && is_int "$b" && [ "$b" -gt "$a" ] || exit 1
    printf '%s %s\n' "$a" "$b"
    ;;
  in-window|needs-slice|slice|day-file)
    if [ "$cmd" = day-file ]; then [ "$#" -eq 5 ] || usage; else [ "$#" -eq 4 ] || usage; fi
    f="$2"; s="$3"; e="$4"
    is_int "$s" && is_int "$e" || usage
    [ -r "$f" ] || exit 2
    case "$cmd" in
      in-window)
        # One pass that stops at the first in-window record, so a large file that is in
        # window costs one short read. State 0 = no record had a clock, 1 = clocks but
        # none in the window, 2 = a record inside it.
        state=$(jq -R -n --argjson s "$s" --argjson e "$e" "$TS_DEF"'
          last(label $done | foreach (inputs | fromjson? | select(type == "object") | ts) as $t
            (0; if . == 2 then 2 elif ($t >= $s and $t < $e) then 2 else 1 end;
             ., (select(. == 2) | break $done))) // 0' "$f" 2>/dev/null) || exit 2
        case "$state" in
          2) exit 0 ;;
          1) exit 1 ;;
          0) ;;
          *) exit 2 ;;
        esac
        # No parseable timestamp anywhere, so the records cannot place this file in a day
        # and its mtime decides, exactly as the bounded find used to: modified by the end
        # of the day -> yes (bias to triage), modified after it -> no. Without this, the
        # find that no longer has an upper bound would enumerate a no-clock file on every
        # later date as well and triage it twice, filed under the wrong day.
        mt=$(pstat_mtime "$f") || exit 0
        case "$mt" in ''|*[!0-9]*) exit 0 ;; esac
        [ "$mt" -lt "$e" ] && exit 0
        exit 1
        ;;
      needs-slice)
        # Yes when ANY timestamped record lies outside the window, found with an early
        # exit. The first-and-last-record shortcut was not used: it assumes the file is
        # chronological, and a file that violates that would then be read whole and
        # leak other days into this one. A file wholly inside the day costs one full
        # read here, which is the same order as the stats pass over it.
        hit=$(jq -R -n --argjson s "$s" --argjson e "$e" "$TS_DEF"'
          first(inputs | fromjson? | select(type == "object") | ts | select(. < $s or . >= $e))' "$f" 2>/dev/null) || exit 2
        [ -n "$hit" ] && exit 0
        exit 1
        ;;
      slice)
        # Raw lines out, not re-serialised, so the slimmer and the stats see exactly the
        # bytes that were written. A torn line or a record with no clock is dropped: when
        # a window is set, a record that cannot be placed in it is not evidence for this
        # day. The one exception is autodream_meta, the header the OMP linearizer writes
        # in front of the live chain. It names the session (cwd, advisor, nested) rather
        # than recording anything that happened, and the stats and the project lookup
        # read it, so it stays with every slice of that session.
        #
        # One record is not byte for byte. A linearized OMP chain links each entry to the one
        # before by parentId, so cutting it to a day leaves the first kept entry pointing at
        # an entry that is no longer there. That entry is written with parentId null (the
        # slice then starts at a root, and every parentId left in it resolves inside it),
        # which is the shape linearize.sh itself refuses to read past: a parent with no entry
        # behind it. Nothing reads parentId after linearizing, but a slice that is a closed
        # chain cannot be turned into a refusal by a later reader that does.
        jq -R -n -r --argjson s "$s" --argjson e "$e" "$TS_DEF"'
          foreach inputs as $l ({kept: {}, out: null};
            (try ($l | fromjson) catch null) as $o
            | if ($o | type) != "object" then .out = null
              elif $o.type == "autodream_meta" then .out = $l
              else
                ([$o | ts][0]) as $t
                | if $t == null or $t < $s or $t >= $e then .out = null
                  else
                    (if ($o.parentId | type) == "string" and (.kept[$o.parentId] | not)
                       then ($o | .parentId = null | tojson) else $l end) as $line
                    | .out = $line
                    | (if ($o.id | type) == "string" then .kept[$o.id] = true else . end)
                  end
              end;
            .out | select(. != null))' "$f" 2>/dev/null || exit 2
        ;;
      day-file)
        # The one call the runner makes: write the day slice of FILE to OUT when FILE
        # spills outside the day, and say so. 1 leaves OUT alone, so a transcript wholly
        # inside the day is read exactly as it always was. The slice is a unique temp
        # beside OUT renamed into place, so a killed run never leaves a half slice that a
        # later step reads as a whole one, and it carries FILE's mtime so a transcript_mtime
        # in the stats sidecar still describes the session and not the moment of slicing.
        out="$5"
        [ ! -d "$out" ] || exit 2
        bash "$0" needs-slice "$f" "$s" "$e"; rc=$?
        [ "$rc" -eq 0 ] || exit "$rc"
        t=$(mktemp "$out.tmp.XXXXXX" 2>/dev/null) || exit 2
        # An empty slice is a file whose records the window cannot place (it changed since
        # enumeration, or its in-window records were all on an abandoned branch it no
        # longer lists). That is not a verdict on the session, so it is an error and the
        # caller reads the whole transcript instead of nothing.
        if bash "$0" slice "$f" "$s" "$e" > "$t" && [ -s "$t" ]; then
          touch -r "$f" "$t" 2>/dev/null
          mv -f "$t" "$out" 2>/dev/null || { rm -f "$t"; exit 2; }
          [ -f "$out" ] || { rm -f "$out/$(basename "$t")" 2>/dev/null; exit 2; }
          exit 0
        fi
        rm -f "$t"
        exit 2
        ;;
    esac
    ;;
  *) usage ;;
esac
