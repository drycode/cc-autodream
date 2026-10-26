#!/bin/bash
# Deterministic, model-free session statistics sidecar for cc-autodream L1 triage.

set -u

_pp="$(dirname "${BASH_SOURCE[0]}")/portable.sh"
# Installed copies are symlinks: a merge updates them before install.sh links a new helper.
[ -r "$_pp" ] || _pp="$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/portable.sh"
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

mkdir -p "$(dirname "$output")" || exit 1

jq -R -s \
  --argjson transcript_bytes "${bytes:-0}" \
  --argjson transcript_mtime "${mtime:-0}" \
  '
  [
    split("\n")[]
    | fromjson?
    | select(type == "object")
  ] as $lines
  | [
      $lines[]
      | select(.type == "user" and .isMeta != true)
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
        | select(.type == "user" and .isMeta != true)
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
      | select(.isMeta != true and (.type == "user" or .type == "assistant"))
    ] as $turns
  | [
      $lines[]
      | select(.type == "assistant" and (.message.content | type) == "array")
      | .message.content[]
      | select(.type == "tool_use")
    ] as $tool_uses
  | [
      $lines[]
      | select(.type == "assistant")
      | .message.model
      | select(type == "string" and length > 0 and . != "<synthetic>")
    ] as $models
  | [
      $lines[]
      | select(has("timestamp"))
      | .timestamp
      | select(type == "string")
      | try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch empty
    ] as $timestamps
  | [
      $lines[]
      # Marker counting is top-level-session-only (advisor-cabinet spec):
      # sidechain (subagent) assistant text never contributes markers.
      | select(.type == "assistant" and .isSidechain != true and (.message.content | type) == "array")
      | .message.content[]
      | select(.type == "text" and (.text | type) == "string")
      | .text
    ]
    | join("\n") as $assistant_text
  # Skill INVOCATION and AUTHORING, counted here and not by the model. A skill runs as a Skill
  # tool call (input.skill) or as a slash command, which Claude Code records as a user line
  # carrying <command-name>/name</command-name>. Authoring is a Write or Edit whose path is a
  # SKILL.md under a skills directory. The two are different findings ("wrote five skills,
  # invoked none" is not "ignored the inventory"), so they are separate fields. The model used
  # to fill these in, and a guess ranked as a count is what the run-time enforcement now removes.
  | ([
      $tool_uses[]
      | select(.name == "Skill")
      | .input.skill?
      | select(type == "string" and length > 0)
    ] + [
      $lines[]
      | select(.type == "user" and .isMeta != true)
      | .message.content
      | if type == "string" then . elif type == "array" then ([.[]? | select(.type == "text") | .text] | join("\n")) else empty end
      | (try (capture("<command-name>/?(?<name>[^<\\s]+)</command-name>") | .name) catch empty)
      # Claude Code records its own commands the same way as a skill. Without this list a session
      # that only ran /clear or /model would measure as having invoked a skill. Best effort: a
      # command added later shows up as a skill until it is named here.
      | select(IN("add-dir","agents","bug","clear","compact","config","context","cost","doctor","exit","export","fast","help","hooks","ide","init","login","logout","mcp","memory","model","permissions","plugin","pr-comments","quit","release-notes","resume","review","rewind","status","statusline","terminal-setup","theme","todos","usage","vim") | not)
    ]) as $skills_invoked
  | ([
      $tool_uses[]
      | select(.name == "Write" or .name == "Edit" or .name == "MultiEdit")
      | .input.file_path?
      | select(type == "string")
      | (try (capture("(^|/)skills/(?<name>[^/]+)/SKILL\\.md$") | .name) catch empty)
    ]) as $skills_authored
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
      duration_minutes: (
        if ($timestamps | length) < 2 then 0
        else (((($timestamps | max) - ($timestamps | min)) / 60) * 10 | round) / 10
        end
      ),
      skills_invoked: ($skills_invoked | unique | sort),
      skills_invoked_count: ($skills_invoked | length),
      skills_invoked_counts: ($skills_invoked | group_by(.) | map({key: .[0], value: length}) | from_entries),
      skills_authored: ($skills_authored | unique | sort),
      compliance_markers: (
        # Line-start counting (2026-07-20, advisor-cabinet spec): a marker counts
        # only when it BEGINS a line of assistant text and is outside a ``` fence,
        # so quoted reports and rule-file examples cannot inflate the counts.
        reduce ($assistant_text | split("\n"))[] as $l (
          {fence: false, rb: 0, fp: 0, dl: 0, dok: 0};
          if ($l | test("^\\s*```")) then .fence = (.fence | not)
          elif .fence then .
          elif ($l | startswith("RETRY-BUDGET:")) then .rb += 1
          elif ($l | startswith("FETCH-PIVOT:")) then .fp += 1
          elif ($l | startswith("DELEGATED:")) then .dl += 1
          elif ($l | startswith("DIRECT-OK:")) then .dok += 1
          else . end
        )
        | {"RETRY-BUDGET": .rb, "FETCH-PIVOT": .fp, "DELEGATED": .dl, "DIRECT-OK": .dok}
      ),
      transcript_bytes: $transcript_bytes,
      transcript_mtime: $transcript_mtime,
      isSidechain: (any($lines[]?; .isSidechain == true)),
      user_turn_timestamps: $user_turn_timestamps
    }
  ' "$transcript" > "$output"
