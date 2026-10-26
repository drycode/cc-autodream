#!/bin/bash
# Merge the per-chunk L1 answers for ONE session into the one findings JSON that L2 and every
# other consumer already reads. Contract: tests/merge-chunks.sh.
#
#   merge-chunks.sh --check FILE
#     exit 0 only when FILE is a usable chunk answer: exactly one JSON value, an object, with no
#     "error" key and a "findings" array. Anything else exits 1.
#   merge-chunks.sh --session PATH [--elided N] CHUNK.json [CHUNK.json ...]   > merged.json
#     exit 0 and the merged object on stdout; 2 usage; 3 when any chunk fails --check (stdout
#     stays empty); another nonzero if jq fails.
#
# A chunk answer is UNTRUSTED. A worker can write the error object the prompt tells it to emit on
# malformed input, a bare {}, a wrongly typed field, or two values in one file, and a transcript
# can nudge it to. Such an answer is retried, never cached and never merged around: a session
# built from some of its chunks would read as if it were all of them. So the merge enforces
# --check itself instead of trusting its caller to have, and --check is the one definition the
# runner uses before it keeps an answer for a retry. It judges EXACTLY one value because plain
# jq -e judges only the last value in a file while the merge slurps them all, so an error object
# followed by a good object used to pass.
#
# No model call: the merge is mechanical, so it has to say what each field means when the
# answers disagree.
#   session_path     the ORIGINAL transcript, never a chunk file
#   underlying_goal  the first non-empty one: the session says what it wants where it begins
#   outcome          the last chunk that states one: the end state is where the outcome is judged
#   stats fields     taken once from the first chunk. Every worker copies the same precomputed
#                    sidecar verbatim, so summing them would be nonsense.
#   findings         union, each tagged with its chunk, exact duplicates on (category, what)
#                    dropped, most severe first, capped at 10 (the schema cap)
#   other lists      order-preserving union, instructions_given capped at 3 (the schema cap)
#   meta             chunks (how many answered) and chunks_elided (how many the chunker dropped)
set -u

usage() { echo "usage: $0 --check FILE | --session PATH [--elided N] CHUNK.json ..." >&2; exit 2; }

# One definition of a usable answer. Run on a whole file so a second value cannot hide behind a
# good first one. has("error"), not a null test: the runner treats any error key as a failed triage.
CHUNK_OK='length == 1 and (.[0] | (type == "object") and (has("error") | not) and ((.findings | type) == "array"))'
chunk_ok() { [ -s "$1" ] && jq -s -e "$CHUNK_OK" "$1" >/dev/null 2>&1; }

if [ "${1:-}" = "--check" ]; then
  [ "$#" -eq 2 ] || usage
  chunk_ok "$2" && exit 0
  exit 1
fi

session=""; elided=0; files=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) [ "$#" -ge 2 ] || usage; session="$2"; shift 2 ;;
    --elided)  [ "$#" -ge 2 ] || usage; elided="$2"; shift 2 ;;
    --) shift; break ;;
    -*) usage ;;
    *) files+=("$1"); shift ;;
  esac
done
while [ "$#" -gt 0 ]; do files+=("$1"); shift; done
[ -n "$session" ] && [ "${#files[@]}" -gt 0 ] || usage
case "$elided" in ''|*[!0-9]*) usage ;; esac
elided=$((10#$elided))

for f in "${files[@]}"; do
  chunk_ok "$f" || { echo "merge-chunks: $f is not a usable chunk answer; refusing to merge around it" >&2; exit 3; }
done

jq -s --arg session "$session" --argjson elided "$elided" '
  def sev: if . == "high" then 0 elif . == "medium" then 1 elif . == "low" then 2 else 3 end;
  # Every read goes through these, so a wrongly typed field is ignored rather than aborting the
  # merge and with it the findings of every other chunk.
  def arr: if type == "array" then . else [] end;
  def objs: arr | map(select(type == "object"));
  def strs: arr | map(select(type == "string"));
  def num: if type == "number" then . else 0 end;
  def sig($all; $k): [$all[] | .satisfaction_signals | (if type == "object" then .[$k] else null end) | num] | add;
  def uniq_ordered: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
  # A finding with neither a category nor a what has no identity to merge on, so it is kept.
  def dedupe: reduce .[] as $f ({seen: {}, out: []};
      ((($f.category // "") | tostring) + "|" + (($f.what // "") | tostring)) as $k
      | if $k != "|" and .seen[$k] then . else (.seen[$k] = true | .out += [$f]) end) | .out;
  . as $all
  | ($all[0] + {
      session_path: $session,
      underlying_goal: ([$all[].underlying_goal | select(type == "string" and length > 0)] | .[0]),
      outcome: ([$all[].outcome | select(type == "string" and length > 0)] | .[-1]),
      notable_initiatives: ([$all[].notable_initiatives | strs | .[]] | uniq_ordered),
      instructions_given: ([$all[].instructions_given | strs | .[]] | uniq_ordered | .[0:3]),
      satisfaction_signals: {
        happy: sig($all; "happy"),
        satisfied: sig($all; "satisfied"),
        dissatisfied: sig($all; "dissatisfied"),
        frustrated: sig($all; "frustrated")
      },
      findings: ([$all | to_entries[] | .key as $i | (.value.findings | objs)[] | . + {chunk: ($i + 1)}]
                 | sort_by(.severity | sev) | dedupe | .[0:10]),
      meta: {chunks: ($all | length), chunks_elided: $elided}
    })' "${files[@]}"
