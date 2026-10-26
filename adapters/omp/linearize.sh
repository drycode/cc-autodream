#!/bin/bash
# Collapse an OMP session file into the conversation that actually happened.
#
# An OMP session is an append-only TREE. Every entry carries id and parentId, and
# backing out of a branch moves a leaf pointer instead of rewriting the file, so the
# file keeps every branch the user abandoned. Read line by line, it credits the user
# with work they threw away. This script keeps only the chain from the live leaf back
# to the root, root first, behind one autodream_meta record.
#
# The live leaf is the LAST entry in the file. OMP does not persist its in-memory leaf
# pointer, and the last appended entry is what it falls back to when it has none.
#
# FAIL CLOSED, and callers MUST skip the session on a nonzero exit instead of reading
# the raw file. A line that cannot be parsed can change which entry is last, which
# puts the walk on an abandoned branch, and a confident triage of rejected work is
# worse than one visibly skipped session. Nothing is written to <dst> on failure.
#
# Design credit: STRML/cc-autodream#47 worked out the tree semantics and the fail-closed
# rule. This is a rewrite with its own fixtures (tests/adapter-omp.sh), not that code.
#
# Usage: linearize.sh <src.jsonl> <dst>
# Exit:  0 wrote dst
#        1 usage, unreadable input, jq missing, or dst is a directory
#        2 not an OMP session (no session header with a string id in the first lines)
#        3 produced no output
#        4 unparseable line, entry without a string id, a duplicated id, or a broken
#          tree (cycle, or a parentId with no entry behind it)
set -u

[ "$#" -eq 2 ] || { echo "linearize: usage: linearize.sh <src> <dst>" >&2; exit 1; }
src="$1"
dst="$2"

[ -r "$src" ] || { echo "linearize: cannot read $src" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "linearize: jq not found" >&2; exit 1; }
# A directory at the destination would make `mv` move the temp inside it and report
# success with nothing written where the caller looks.
[ ! -d "$dst" ] || { echo "linearize: $dst is a directory" >&2; exit 1; }

# Format gate. An OMP file opens with a title slot and then a session header whose id is
# a string. A Claude transcript has no such record, so this is structural, not a guess.
if ! head -n 4 "$src" | jq -R -s -e '
      [ split("\n")[] | (try fromjson catch null) | select(type == "object") ]
      | any(.[]; .type == "session" and (.id | type) == "string")
    ' >/dev/null 2>&1; then
  echo "linearize: no omp session header in $src" >&2
  exit 2
fi

# Provenance. A child session lives in a directory named after its parent file:
#   <bucket>/<stamp>_<id>.jsonl            parent
#   <bucket>/<stamp>_<id>/__advisor.jsonl  child (advisor)
#   <bucket>/<stamp>_<id>/<Name>.jsonl     child (task subagent)
# so "my directory plus .jsonl is a file" identifies a child exactly. This comes from
# the path, not from the entries, because an advisor child has no user turns and no
# session_init to find.
parent_candidate="$(dirname "$src").jsonl"
nested=false
parent=""
if [ -f "$parent_candidate" ]; then nested=true; parent="$parent_candidate"; fi
# A child whose parent file is gone (deleted or archived) is still a child. Its directory is
# named like a session file (<ISO stamp>_<id>) and a project bucket never is, because a bucket
# is a dash-encoded path, so the shape of the directory name answers without the parent.
case "$(basename "$(dirname "$src")")" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*Z_*) nested=true ;;
esac
# omp reserves both stems for a reviewer model that tails a primary session. The same
# rule lives in stats.sh for a raw file, so a change to one must change the other
# (tests/adapter-omp.sh pins both against `__advisor-<name>.jsonl`).
case "$(basename "$src")" in
  __advisor.jsonl|__advisor-*.jsonl) is_advisor=true ;;
  *) is_advisor=false ;;
esac

t=$(mktemp "$dst.tmp.XXXXXX" 2>/dev/null) || { echo "linearize: cannot create a temp beside $dst" >&2; exit 1; }

# The program, in four steps: parse every line strictly; index entries by id; walk
# parentId from the last entry, bounded by the entry count so a cycle ends; then
# insist the chain reaches a root, because a chain that stops early cannot be shown
# to be the live conversation.
if ! jq -R -s -c \
      --arg src "$src" --argjson nested "$nested" --arg parent "$parent" \
      --argjson advisor "$is_advisor" '
  def bail($m): ($m + ": " + $src) | halt_error(4);

  [ split("\n")[] | select(test("^[[:space:]]*$") | not) | (try fromjson catch {"__autodream_bad": true}) ] as $rows
  | if any($rows[]; type == "object" and has("__autodream_bad")) then bail("unparseable line") else . end
  | if any($rows[]; type != "object") then bail("non-object line") else . end
  | ([ $rows[] | select(.type == "session") ] | first) as $head
  | [ $rows[] | select(.type != "session" and .type != "title") ] as $entries
  | if any($entries[]; (.id | type) != "string") then bail("entry without a string id") else . end
  | ($entries | length) as $n
  # Ids index the tree below, so a repeated id would let the later entry silently replace
  # the earlier one and put the walk on a chain the file does not show.
  | if ([ $entries[].id ] | length) != ([ $entries[].id ] | unique | length) then bail("duplicate entry id") else . end
  | ($entries | map({(.id): .}) | add // {}) as $by_id
  | (if $n == 0 then null else $entries[$n - 1].id end) as $leaf
  | ([ limit($n; $leaf | recurse(
           ($by_id[.].parentId // null) as $p
           | if $p == null then empty else $p end;
           true)) ]) as $ids
  # `recurse` follows a dangling parent id to a missing entry, which shows up below as
  # an id with no record. A cycle revisits an id, which the uniqueness check catches.
  | if ($ids | length) != ($ids | unique | length) then bail("parent cycle") else . end
  | if any($ids[]; $by_id[.] == null) then bail("dangling parentId") else . end
  | ([ $ids[] | $by_id[.] ] | reverse) as $chain
  | if ($chain | length) > 0 and (($chain[0].parentId // null) != null)
    then bail("chain does not reach a root (parent chain longer than the entries)") else . end
  | [{
      type: "autodream_meta",
      source: "omp",
      source_path: $src,
      nested: $nested,
      is_advisor: $advisor,
      parent_session_file: (if $parent == "" then null else $parent end),
      session_id: ($head.id // null),
      cwd: ($head.cwd // null),
      title: ($head.title // null),
      started_at: ($head.timestamp // null),
      entries: $n,
      on_path: ($chain | length),
      dropped: ($n - ($chain | length))
    }] + $chain
  | .[]
' "$src" > "$t" 2>/dev/null; then
  rm -f "$t"
  echo "linearize: refusing $src (unparseable line or broken entry tree)" >&2
  exit 4
fi

if [ ! -s "$t" ]; then
  rm -f "$t"
  echo "linearize: no output for $src" >&2
  exit 3
fi

mv -f "$t" "$dst" 2>/dev/null || { rm -f "$t"; exit 3; }
# Check-then-act post-condition, as in the claude adapter: a directory created at $dst
# between the guard and the mv would take the temp inside it and still return 0.
[ -f "$dst" ] || { rm -f "$dst/$(basename "$t")" 2>/dev/null; exit 3; }
