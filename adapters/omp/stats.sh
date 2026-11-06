#!/bin/bash
# Deterministic, model-free session statistics sidecar for OMP sessions (adapters/omp).
#
# Reads either a raw OMP session or the linearized copy adapters/omp/linearize.sh writes;
# the autodream_meta record the linearizer prepends is ignored by every count below and
# supplies the advisor and nested flags, which the filename of a normalized temp copy
# could not.

set -u

_pp="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../bin" && pwd)/portable.sh"
# shellcheck source=/dev/null
. "$_pp"

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <transcript.jsonl> <out.stats.json>" >&2
  exit 2
fi

transcript="$1"
output="$2"

[ -r "$transcript" ] || {
  echo "session-stats: transcript is not readable: $transcript" >&2
  exit 1
}

bytes=$(wc -c < "$transcript" | tr -d ' ')
mtime=$(pstat_mtime "$transcript") || {
  echo "session-stats: could not read transcript mtime: $transcript" >&2
  exit 1
}

# The advisor flag. The linearizer records it in autodream_meta from the ORIGINAL file
# name. A raw session falls back to its own name. `__advisor.jsonl` and
# `__advisor-<name>.jsonl` are omp's reserved stems for a reviewer model that tails a
# primary session: an observability record, not an agent session, with a read-only
# toolset, so `Tool "bash" not available` is its normal shape. Its calls are toolCall content
# blocks, not tool_execution_start records, and are counted from those below.
case "$(basename "$transcript")" in
  __advisor.jsonl|__advisor-*.jsonl) is_advisor_name=true ;;
  *) is_advisor_name=false ;;
esac

# Provenance for a raw file: a child lives in a directory named after its parent's file, so
# "my directory plus .jsonl is a file" identifies it exactly (the rule linearize.sh applies, from
# the path and not the entries: an advisor child has no user turns and no session_init). A
# linearized copy lives in the runner's work directory, where this is false, and the meta record
# the linearizer wrote answers instead.
nested_name=false
if [ -f "$(dirname "$transcript").jsonl" ]; then nested_name=true; fi
# A child whose parent file is gone is still a child: its directory is named like a session file
# (<ISO stamp>_<id>) and a project bucket never is. The same rule as linearize.sh.
case "$(basename "$(dirname "$transcript")")" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*Z_*) nested_name=true ;;
esac

mkdir -p "$(dirname "$output")" || exit 1

jq -R -s \
  --argjson transcript_bytes "${bytes:-0}" \
  --argjson transcript_mtime "${mtime:-0}" \
  --argjson is_advisor_name "$is_advisor_name" \
  --argjson nested_name "$nested_name" \
  --arg home "${HOME:-}" \
  '
  def skill_md_name: capture("(?:^|/)(?<name>[^/]+)/SKILL\\.md$").name;
  # A tool path as an absolute file name, or null when it cannot be resolved: relative to the
  # session cwd, `~` against $HOME, then `.`, `..` and repeated slashes folded away. Lexical
  # only, so a symlinked skill dir and its target are two names (see the authoring note below).
  def abs_path($cwd):
    (if test("^[A-Za-z][A-Za-z0-9+.-]*://") then null
     elif startswith("/") then .
     elif . == "~" or startswith("~/") then (if ($home | startswith("/")) then $home + .[1:] else null end)
     elif startswith("~") then null
     elif $cwd != null then $cwd + "/" + .
     else null
     end)
    | if . == null then null
      else reduce (split("/")[]) as $s ([];
          if $s == "" or $s == "." then . elif $s == ".." then .[:-1] else . + [$s] end)
        | "/" + join("/")
      end;
  [
    split("\n")[]
    | fromjson?
    | select(type == "object")
  ] as $lines
  # A user-role message the harness wrote is not a human turn. omp marks it "attribution":"agent":
  # a parent steering a child, hook output, the whole prompt stream of an advisor. In a 400-file
  # sample of this host (2026-10-04) every one of 14,427 advisor user messages and 457 of 485
  # task-child ones carried it, and 30 of 428 in main sessions; real human turns carry "user".
  # Only an explicit "agent" is excluded, so a file from before the field existed counts as it
  # always did (omp-autodream #114, item 3).
  | [
      $lines[]
      | select(.type == "message" and (.message.role? // "") == "user")
      | select((.message.attribution? // "") != "agent")
      | .message.content
      | select(
          type == "string"
          or (
            type == "array"
            and any(.[]?; .type == "text")
            and all(.[]?; .type != "tool_result")
          )
        )
    ] as $user_messages
  | (
      [
        $lines[]
        | select(.type == "message" and (.message.role? // "") == "user")
        | select((.message.attribution? // "") != "agent")
        | select(
            (.message.content) as $c
            | ($c | type) == "string"
            or (
              ($c | type) == "array"
              and any($c[]?; .type == "text")
              and all($c[]?; .type != "tool_result")
            )
          )
        | .timestamp
        | select(type == "string")
        | try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch empty
      ] | sort
    ) as $user_turn_timestamps
  | [
      $lines[]
      | select(
          .type == "message"
          and (((.message.role? // "") == "user") or ((.message.role? // "") == "assistant"))
        )
    ] as $turns
  | [
      $lines[]
      | select(.type == "custom" and .customType == "tool_execution_start")
    ] as $tool_starts
  # omp writes a tool call two ways. The main session loop emits a custom/tool_execution_start
  # record per call AND leaves the call as a toolCall block in the assistant message; counting
  # both double counts (measured on this host 2026-10-03: of 624 main transcripts with tool
  # activity, 614 hold exactly as many start records as toolCall blocks). An advisor transcript
  # carries only the blocks: 144 of 410 advisor files had toolCall blocks, none had a start
  # record, so they read tool_call_count 0 whatever they did (omp-autodream #114, item 1).
  # The start records stay the source whenever the file has any; the blocks count only when it
  # has none, so a main session reads exactly what it always did.
  # An advisor is offered read, grep and glob only; a call to any other tool comes back as a
  # toolResult whose text is `Tool "<name>" not available`. Those are attempts, not calls made, and
  # counting them would let an advisor that only ever hit the wall clear the noise gate
  # exemption for tool_call_count >= 5 (one stored advisor made eight bash attempts and got nothing).
  # They are matched to their block by call id and left out.
  | ([
      $lines[]
      | select(.type == "message" and (.message.role? // "") == "toolResult")
      | select(any(.message.content[]?; type == "object" and (((.text? // "") | type) == "string") and ((.text? // "") | test("^Tool \".*\" not available$"))))
      | .message.toolCallId
      | select(type == "string")
      | {key: ., value: true}
    ] | from_entries) as $rejected
  | [
      $lines[]
      | select(.type == "message")
      | .message.content
      | select(type == "array")
      | .[]
      | select(type == "object" and .type == "toolCall")
      | select(((.id? // "") as $i | $rejected[$i]) != true)
    ] as $tool_blocks
  # A call keeps its id and arguments so the skill reads below follow this same per-file source
  # rule. A start record can lack args (a hashline edit, manage_skill): its block, matched by call
  # id, supplies them.
  | ([
      $tool_blocks[]
      | select(((.id? // null) | type) == "string" and ((.arguments? // null) | type) == "object")
      | {key: .id, value: .arguments}
    ] | from_entries) as $block_args
  | (
      if ($tool_starts | length) > 0
      then [$tool_starts[] | {
          name: (.data.toolName? // null),
          id: (.data.toolCallId? // null),
          args: (
            if ((.data.args? // null) | type) == "object" then .data.args
            else ((.data.toolCallId? // null) as $i | if ($i | type) == "string" then $block_args[$i] else null end)
            end
          )
        }]
      else [$tool_blocks[] | {name: (.name? // .toolName? // null), id: (.id? // null), args: (.arguments? // null)}]
      end
    ) as $tool_uses
  | [
      $lines[]
      | select(.type == "model_change")
      | .model
      | select(type == "string" and length > 0 and . != "<synthetic>")
    ] as $models
  | [
      $lines[]
      | select(has("timestamp"))
      | .timestamp
      | select(type == "string")
      | try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch empty
    ] as $timestamps
  # Skill INVOCATION leaves two traces in omp.
  #
  # 1. The user ran /<skill>: a custom_message of customType "skill-prompt" whose content
  #    opens with the bracket line below and then inlines the whole skill.
  # 2. The model loaded a skill itself, with the read tool: `skill://<name>` (omp resolves
  #    it to the SKILL.md of that skill) or a `<dir>/<name>/SKILL.md` path. This is the common
  #    case. Measured 2026-11-03 over the 739 omp transcripts modified since 2026-10-27: 2
  #    held a skill-prompt record, 16 made a read call on skill://<name> and 18 on a SKILL.md
  #    path. Counting only (1), as this file did until then, totalled 2 invocations across
  #    them; counting both totals 50 across 29 transcripts, so a `missed_skill` finding from
  #    the old detector says nothing.
  #
  # A read counts when it loads the skill itself: `skill://<name>`, `skill://<name>/SKILL.md`
  # or `.../<name>/SKILL.md`, after dropping a trailing read selector (`:raw`, `:1-60`) and
  # splitting the `a; b` path list omp accepts. A reference file inside a skill, a directory listing,
  # a glob and a read whose result is an error (an unknown skill) do not. Reads follow the
  # per-file source rule of $tool_uses, so a call in a main session, written both as a start
  # record and as a block, counts once.
  #
  # A SKILL.md file the session also writes or edits is being authored, not used, so its
  # reads are left out. The match is by FILE (#179): two skills with one name in different
  # roots (a project `.claude/skills/x` and `~/.claude/skills/x`) do not mask each other. A
  # hashline edit names its path relative to the session cwd while a read usually names it
  # absolute, and an edit start record carries no args (its path is only in the `[path#HASH]`
  # header of the block, so both record shapes are read here), so every path goes through
  # abs_path against the cwd of the session header (or of autodream_meta in a linearized copy)
  # first. A path that cannot be resolved (no cwd, `~` with no HOME, `~user`, a URL such as the
  # raw.githubusercontent.com SKILL.md a session fetches before installing it) falls back to the
  # old rule, a match by skill name (the directory above SKILL.md): an unresolvable edit masks
  # every read of that name, an unresolvable read is masked by any edit of that name. The
  # resolution is lexical, so the sidecar depends on the transcript alone: a read through a
  # symlinked install (`~/.claude/skills/x -> ~/git/skills/x`) of the file the session edits
  # under its target name counts as use. A `skill://` read is never authoring.
  #
  # This field used to be filled in by haiku, and it was unmeasurable, not merely noisy —
  # the 2026-09-04 report read `skills_invoked: []` on a session that called manage_skill
  # ten times and concluded the ~200-skill inventory never fires. Those calls were skill
  # AUTHORING, which is why $skills_authored below is counted separately: "wrote five
  # skills, invoked none" and "ignored the inventory" are different findings.
  | ([
      $lines[]
      | select(.type == "message" and (.message.role? // "") == "toolResult" and (.message.isError? == true))
      | .message.toolCallId
      | select(type == "string")
      | {key: ., value: true}
    ] | from_entries) as $errored
  | [
      $tool_uses[]
      | select(.name == "read")
      | select(((.id // "") | tostring) as $i | $errored[$i] != true)
      | (.args | if type == "object" then .path else null end)
      | select(type == "string")
      | split(";")[]
      | gsub("^\\s+|\\s+$"; "")
      | sub(":[^/]*$"; "")
    ] as $read_paths
  | ([ $lines[] | select(.type == "autodream_meta") | .cwd ]
     + [ $lines[] | select(.type == "session") | .cwd ]
     | map(select(type == "string" and startswith("/"))) | first) as $cwd
  | [
      ($lines[] | select(.type == "custom" and .customType == "tool_execution_start") | .data
        | select(type == "object" and ((.toolName? // "") | IN("edit", "write"))) | .args),
      ($lines[] | select(.type == "message") | .message.content | select(type == "array") | .[]
        | select(type == "object" and .type == "toolCall" and ((.name? // "") | IN("edit", "write"))) | .arguments)
    ]
    | map(select(type == "object"))
    | [ .[] | (.path? | select(type == "string")),
              (.input? | select(type == "string") | scan("(?:^|\\n)\\[([^\\]#\\n]+)#") | .[0]) ]
    | [ .[] | select(test("(?:^|/)[^/]+/SKILL\\.md$")) | {name: skill_md_name, file: abs_path($cwd)} ]
    as $authored
  | ($authored | map(select(.file != null) | {key: .file, value: true}) | from_entries) as $authored_files
  | ($authored | map(select(.file == null) | {key: .name, value: true}) | from_entries) as $authored_names_unresolved
  | ($authored | map({key: .name, value: true}) | from_entries) as $authored_names
  | ([
      $lines[]
      | select(.type == "custom_message" and (.customType? // "") == "skill-prompt")
      | .content
      | select(type == "string")
      | (try (capture("^\\[IMPORTANT: User invoked the \"(?<name>[^\"]+)\" skill") | .name) catch empty)
    ] + [
      $read_paths[]
      | select(startswith("skill://"))
      | ltrimstr("skill://")
      | (try capture("^(?<name>[^/*?\\s]+)(?:/SKILL\\.md)?$") catch empty)
      | .name
    ] + [
      $read_paths[]
      | select(startswith("skill://") | not)
      | abs_path($cwd) as $file
      | (try capture("(?:^|/)(?<name>[^/*?]+)/SKILL\\.md$") catch empty)
      | .name
      | select(
          if $file == null then $authored_names[.] != true
          else $authored_files[$file] != true and $authored_names_unresolved[.] != true
          end
        )
    ]) as $skills_invoked
  # Both record shapes, unioned. PORT_CONTRACT.md documents tool usage as
  # custom/tool_execution_start records, and those DO carry a data.args payload —
  # measured across the OMP store on 2026-09-06: 20,185 of 26,308 such records have it.
  # For manage_skill specifically they carry data.intent and no args, so the skill NAME
  # is only present in the assistant toolCall block; a parse of the documented shape
  # alone returns nothing for this field. Reading both is the only version that is right
  # whichever shape a given provider emits, and it costs one extra pass over $lines.
  | ([
      $lines[]
      | select(.type == "message")
      | .message.content
      | select(type == "array")
      | .[]
      | select(type == "object" and .type == "toolCall" and ((.name? // .toolName? // "") == "manage_skill"))
      | .arguments
      | select(type == "object")
      | .name
      | select(type == "string" and length > 0)
    ] + [
      $lines[]
      | select(.type == "custom" and .customType == "tool_execution_start")
      | .data
      | select(type == "object" and (.toolName? == "manage_skill"))
      | .args
      | select(type == "object")
      | .name
      | select(type == "string" and length > 0)
    ]) as $skills_authored
  # `//` would turn a recorded false into the filename fallback, so test for the meta record
  # itself. A linearized copy has a temp filename and directory that say nothing.
  | ([ $lines[] | select(.type == "autodream_meta") ] | first) as $meta
  | (if $meta != null then ($meta.is_advisor == true) else $is_advisor_name end) as $is_advisor
  | (if $meta != null then ($meta.nested == true) else $nested_name end) as $nested
  | {
      user_message_count: ($user_messages | length),
      turn_count: ($turns | length),
      tool_call_count: ($tool_uses | length),
      tools_used: (
        $tool_uses
        | map(.name)
        | map(select(type == "string"))
        | unique
        | sort
      ),
      models_used: ($models | unique | sort),
      skills_invoked: ($skills_invoked | unique | sort),
      skills_invoked_count: ($skills_invoked | length),
      # PROMPT.md asks for "top 5 skills by count", which the unique list cannot answer
      # and the bare total answers for the wrong question: two runs of one skill and one
      # run each of two others both come out as 3. Name to count, so the ranking is real.
      skills_invoked_counts: ($skills_invoked | group_by(.) | map({key: .[0], value: length}) | from_entries),
      skills_authored: ($skills_authored | unique | sort),
      duration_minutes: (
        if ($timestamps | length) < 2 then 0
        else (((($timestamps | max) - ($timestamps | min)) / 60) * 10 | round) / 10
        end
      ),
      # compliance_markers retired 2026-08-08: the detector was correct
      # (line-start, non-sidechain, fence-aware) but no session in the entire
      # transcript archive ever emitted one. It measured only silence.
      transcript_bytes: $transcript_bytes,
      transcript_mtime: $transcript_mtime,
      # A child is a sidechain, as a claude subagent is: provenance, not a record. PORT_CONTRACT
      # expected a custom `agent`/`subagent` record and omp writes neither (its only custom types
      # are tool_execution_start and session_exit), so the old test could only read false and the
      # noise gate never exempted a child (omp-autodream #114, item 2).
      isSidechain: ($is_advisor or $nested),
      is_advisor: $is_advisor,
      nested: $nested,
      user_turn_timestamps: $user_turn_timestamps
    }
  ' "$transcript" > "$output"
