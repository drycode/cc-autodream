#!/bin/bash
# Split a transcript into chunks an L1 worker can read. Contract: tests/chunk-transcript.sh.
#
#   chunk-transcript.sh SRC OUTDIR CHUNK_BYTES MAX_CHUNKS
#     stdout  "COUNT ELIDED"        OUTDIR/chunk-01.jsonl ... COUNT files
#     exit    0 ok, 1 empty source, 2 usage, unreadable source or a failure writing the chunks
#
# Why. A day of a long session slims to far more than one worker can read, and eliding its middle
# is how Layer 1 came to see about 2% of a conversation. Every line is kept. Chunks are cut only
# at line boundaries (a line longer than CHUNK_BYTES becomes a chunk of its own rather than being
# split), so no line is ever torn in half, and a tool call and its result are never torn in half
# either: they are separate lines, in order, and when they fall on either side of a cut the one
# ends a chunk and the other opens the next. The caller says so in the chunk note.
#
# Over MAX_CHUNKS the middle is dropped, deliberately and loudly: ELIDED is how many chunks, the
# first ceil(MAX/2) and last floor(MAX/2) are kept, and the caller tells the worker and records it.
# The start holds the goal and the end holds the outcome, so those are the two parts worth keeping.
# A cap of 1 keeps the first chunk only: it is still a bounded read, never the whole transcript.
#
# On a failure (exit 2) no chunk or scratch file is left in OUTDIR, so the caller cannot mistake a
# partial split for a whole one.
set -u

# Chunks are transcript text: private to the user whatever umask the caller has.
umask 077

usage() { echo "usage: $0 SRC OUTDIR CHUNK_BYTES MAX_CHUNKS" >&2; exit 2; }
is_pos() { case "$1" in ''|*[!0-9]*) return 1 ;; *) [ "$((10#$1))" -gt 0 ] ;; esac; }

[ "$#" -eq 4 ] || usage
src="$1"; outdir="$2"; limit="$3"; maxc="$4"
is_pos "$limit" && is_pos "$maxc" || usage
# Decimal, whatever the caller wrote: bash arithmetic reads 08 as an invalid octal number.
limit=$((10#$limit)); maxc=$((10#$maxc))
[ -r "$src" ] || { echo "chunk-transcript: cannot read $src" >&2; exit 2; }
[ -s "$src" ] || exit 1
mkdir -p "$outdir" || exit 2

# A leftover chunk from an earlier run must not survive into this one: the caller globs this
# directory.
rm -f "$outdir"/chunk-*.jsonl "$outdir"/raw-*.jsonl
fail() { rm -f "$outdir"/chunk-*.jsonl "$outdir"/raw-*.jsonl; exit 2; }

# Bytes, not characters: LC_ALL=C makes awk length() count bytes. A source whose last line has no
# newline gets one, so every chunk ends on a line.
total=$(LC_ALL=C awk -v dir="$outdir" -v limit="$limit" '
  {
    b = length($0) + 1
    if (n == 0 || (cur > 0 && cur + b > limit)) {
      if (f != "") close(f)
      n++
      f = sprintf("%s/raw-%05d.jsonl", dir, n)
      cur = 0
    }
    print $0 > f
    cur += b
  }
  END { print n + 0 }' "$src") || fail
case "$total" in ''|*[!0-9]*) fail ;; esac
[ "$total" -gt 0 ] || { rm -f "$outdir"/raw-*.jsonl; exit 1; }

if [ "$total" -le "$maxc" ]; then
  head_n="$total"; tail_n=0; elided=0
else
  head_n=$(( (maxc + 1) / 2 )); tail_n=$(( maxc / 2 )); elided=$(( total - maxc ))
fi

out=0
take() {
  out=$((out + 1))
  mv "$outdir/$(printf 'raw-%05d.jsonl' "$1")" "$outdir/$(printf 'chunk-%02d.jsonl' "$out")" || fail
}
k=1
while [ "$k" -le "$head_n" ]; do take "$k"; k=$((k + 1)); done
if [ "$tail_n" -gt 0 ]; then
  k=$(( total - tail_n + 1 ))
  while [ "$k" -le "$total" ]; do take "$k"; k=$((k + 1)); done
fi
rm -f "$outdir"/raw-*.jsonl
printf '%s %s\n' "$out" "$elided"
