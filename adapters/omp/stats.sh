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
  '
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
  | (
      if ($tool_starts | length) > 0
      then [$tool_starts[] | {name: (.data.toolName? // null)}]
      else [$tool_blocks[] | {name: (.name? // .toolName? // null)}]
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
  # Skill INVOCATION. OMP records it exactly one way: a custom_message of customType
  # "skill-prompt" whose content opens with the bracket line below and then inlines the
  # whole skill. There is no skill tool call and no other customType, so this record is
  # the only mechanical trace a skill ever leaves. Verified against all 204 transcripts in
  # the OMP store on 2026-09-05: 7 such records, every one matching this pattern.
  #
  # This field used to be filled in by haiku, and it was unmeasurable, not merely noisy —
  # the 2026-09-04 report read `skills_invoked: []` on a session that called manage_skill
  # ten times and concluded the ~200-skill inventory never fires. Those calls were skill
  # AUTHORING, which is why $skills_authored below is counted separately: "wrote five
  # skills, invoked none" and "ignored the inventory" are different findings.
  | [
      $lines[]
      | select(.type == "custom_message" and (.customType? // "") == "skill-prompt")
      | .content
      | select(type == "string")
      | (try (capture("^\\[IMPORTANT: User invoked the \"(?<name>[^\"]+)\" skill") | .name) catch empty)
    ] as $skills_invoked
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
