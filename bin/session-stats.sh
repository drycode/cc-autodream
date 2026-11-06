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
      | if type == "string" then . elif type == "array" then ([.[]? | select(type == "object" and .type == "text") | .text | strings] | join("\n")) else empty end
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
  # Denies the sandbox-shape guard signs: a tool_result whose text OPENS with "sandbox-shape: ",
  # bare or inside <tool_use_error>, with is_error true. Each one is a turn spent on a
  # dangerouslyDisableSandbox the guard refused. L1 stopped scoring them as sandbox_friction
  # (#175), so this count is the only place a session that keeps hitting the guard shows up.
  # Anchored, because a Read or grep of a file that mentions the guard holds the same words
  # mid-text (measured 2026-11-03: 52 anchored denies and 1 such echo in one session).
  | ([
      $lines[]
      | select(.type == "user" and (.message.content | type) == "array")
      | .message.content[]
      | select(type == "object" and .type == "tool_result" and .is_error == true)
      | .content
      | if type == "string" then . elif type == "array" then ([.[]? | select(type == "object" and .type == "text") | .text | strings] | join("\n")) else "" end
      | select(test("\\A\\s*(<tool_use_error>)?\\s*sandbox-shape: "))
    ] | length) as $sandbox_shape_denies
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
      sandbox_shape_denies: $sandbox_shape_denies,
      # compliance_markers retired 2026-10-30 (omp: 2026-08-08): agents follow the retry
      # and delegation rules without typing the marker line, so the count measured silence.
      transcript_bytes: $transcript_bytes,
      transcript_mtime: $transcript_mtime,
      isSidechain: (any($lines[]?; .isSidechain == true)),
      user_turn_timestamps: $user_turn_timestamps
    }
  ' "$transcript" > "$output"
