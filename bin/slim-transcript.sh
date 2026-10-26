#!/bin/bash
# Slim an oversized Claude Code session transcript so the L1 haiku worker can read it.
#
# Some sessions are enormous (4500+ lines, ~10MB, base64 images and giant tool
# outputs). The worker can't even read 20 such lines without blowing the 25k-token
# Read limit, so it gives up and returns an error finding instead of triaging — and
# those big sessions are often the most interesting ones. This caps the damage:
#   1. truncate every line to a max width (kills base64 blobs / huge tool outputs),
#   2. keep head + tail and elide the middle (which is usually repetitive churn),
#   3. hard-cap total bytes as a final safety net.
# Triage is fuzzy pattern-spotting, not strict JSON parsing, so a lossy but
# representative transcript still yields useful findings. run.sh only invokes this
# for sessions over AUTODREAM_SLIM_BYTES; smaller ones are read verbatim.
#
# Usage: slim-transcript.sh <src.jsonl> <dst>
# Tunables (env): AUTODREAM_SLIM_MAXLINE (400 chars), _HEAD (400 lines),
#                 _TAIL (200 lines), _CAP (262144 bytes),
#                 _TOOLRESULT (600 chars), _THINKING (800 chars).
# Modes (env, both off unless set to 1, so a plain call writes exactly what it always did):
#   AUTODREAM_SLIM_RESHAPE=1  drop Claude Code bookkeeping records by a TYPE DENYLIST and rebuild
#                             each kept Claude record with type and timestamp first and the
#                             message reduced to role and content. OMP records and any schema
#                             this script does not know pass through untouched by this step.
#   AUTODREAM_SLIM_FULL=1     keep every surviving line: no head/tail elision, no byte cap, no
#                             footer. For the chunker, which sizes the pieces itself at line
#                             boundaries; a footer would land in the last chunk as a line that is
#                             not JSON, which the worker would read as transcript.
# Nothing in this repo sets either yet: the chunked reader will, only while it is on, so turning
# that off restores the head/tail view byte for byte.
set -u

# Everything written here is derived from a session transcript, so none of it may be readable by
# another local account whatever umask the caller has.
umask 077

src="${1:?usage: slim-transcript.sh <src> <dst>}"
dst="${2:?usage: slim-transcript.sh <src> <dst>}"
maxline="${AUTODREAM_SLIM_MAXLINE:-400}"
headn="${AUTODREAM_SLIM_HEAD:-400}"
tailn="${AUTODREAM_SLIM_TAIL:-200}"
cap="${AUTODREAM_SLIM_CAP:-262144}"
trmax="${AUTODREAM_SLIM_TOOLRESULT:-600}"
tkmax="${AUTODREAM_SLIM_THINKING:-800}"
reshape="${AUTODREAM_SLIM_RESHAPE:-0}"
full="${AUTODREAM_SLIM_FULL:-0}"

[ -r "$src" ] || { echo "slim-transcript: cannot read $src" >&2; exit 1; }

# umask only governs a file this script creates. A destination the caller already made keeps its
# own mode through the redirects below, so truncate it here and set 0600 explicitly.
rm -f "$dst.pre.jsonl"
: > "$dst" && chmod 600 "$dst" || { echo "slim-transcript: cannot write $dst" >&2; exit 1; }

lines=$(wc -l < "$src" | tr -d ' ')
bytes=$(wc -c < "$src" | tr -d ' ')

# Pre-pass: when jq is available, strip the bulky payloads that tool calls leave
# behind, before the line-based head/tail/truncate pass. Two transcript schemas
# show up here and they store tool output in completely different places:
#
#   Claude Code  content blocks of .type == "tool_result" inside .message.content
#   OMP          whole records with .message.role == "toolResult", carrying the
#                payload in .message.details + .message.content, plus a
#                .message.providerPayload blob on assistant turns
#
# Handling only the first schema is worse than doing nothing: jq still exits 0 and
# writes a valid file, so the fallback never fires, and the line pass below then
# spends its 400-char budget on ~190 chars of OMP envelope (id/parentId/timestamp/
# toolCallId/toolName) and cuts off at '"content":[' — the worker gets ID soup with
# no payload and no goal, and returns no findings. Both schemas are stripped here.
# The line-based pass still runs as a safety net for stragglers. Falls back
# transparently if jq isn't installed or the stream isn't parseable JSONL.
# CLAUDE CODE BOOKKEEPING AND REPLAY NOISE (AUTODREAM_SLIM_RESHAPE=1). Measured 2026-10-02 on a
# 3,479-line session: 36% of the lines were conversation, 24% hook and reminder attachments and
# 21% mode, permission-mode, last-prompt and bridge-session records. The head/tail pass below is
# positional, so on the raw stream it spent its whole budget on those and the worker saw about 2%
# of the conversation. Measured again on this host's store (24 hours of Claude transcripts):
# hook_success and total_tokens_reminder alone are 12,000 and 8,000 of about 33,000 attachments.
#
# A DENYLIST, never an allowlist of user and assistant. OMP transcripts come through this script
# too, and an allowlist would delete every one of their records, leaving a worker with an empty
# transcript and a findings list that reads exactly like a quiet night. It is a denylist of
# attachment subtypes as well, so a subtype this script has never seen is KEPT: keeping one costs
# bytes, dropping one silently costs signal. Kept on purpose: attachment/queued_command (the user
# typing mid-turn, the only place that text lives), attachment/skill_listing (SESSION_TRIAGE.md
# names it for the StructuredOutput rule and the missed_skill category), every system record but
# stop_hook_summary and turn_duration (compact_boundary is the compaction marker), pr-link and
# summary records.
#
# RESHAPE. Claude Code writes message before timestamp, so the 400-char line cut dropped the
# timestamp from a third of the lines, and the envelope (parentUuid, uuid, cwd, sessionId,
# version, gitBranch, userType, toolUseResult, message id/model/usage) used about 185 chars
# before the content began. The record is rebuilt with type then timestamp FIRST and only the
# fields triage reads. A key is added only when the source has it, because inventing a null is
# the bug the guards in the main program exist to stop. The thinking signature is a base64 blob
# that filled whole lines on its own.
reshape_defs=""
reshape_pipe=""
if [ "$reshape" = "1" ]; then
  reshape_defs='
    def noise_attachment: (.attachment.type | IN("hook_success", "total_tokens_reminder",
        "deferred_tools_record", "deferred_tools_delta", "silent_turn_reminder",
        "prompt_snapshot", "environment", "date", "model", "instructions", "session_context",
        "credential_org", "advisor_tool", "sandbox_instructions", "mcp_instructions_delta",
        "agent_listing_delta", "remote_session_change", "command_permissions"));
    def noise:
      (.type | IN("bridge-session", "last-prompt", "permission-mode", "mode", "atis-latch",
                  "ai-title", "queue-operation", "file-history-snapshot",
                  "file-history-delta", "dev-mods"))
      or (.type == "attachment" and noise_attachment)
      or (.type == "system" and (.subtype | IN("stop_hook_summary", "turn_duration")));
    def claude_type: .type | IN("user", "assistant", "attachment", "system");
    def reshape:
      if claude_type then
        ({type: .type}
         + (if has("timestamp") then {timestamp: .timestamp} else {} end)
         + with_entries(select(.key | IN("isSidechain", "isMeta", "isCompactSummary",
                                         "subtype", "level", "content", "message", "attachment"))))
        | (if (.message | type) == "object"
             then .message |= with_entries(select(.key | IN("role", "content")))
             else . end)
        | (if (.message | type) == "object" and (.message.content | type) == "array"
             then .message.content |= map(if type == "object" and .type == "thinking" then del(.signature) else . end)
             else . end)
      else . end;
  '
  reshape_pipe='select(noise | not) | reshape |'
fi
pre_src="$src"
pre_tmp=""
if command -v jq >/dev/null 2>&1; then
  pre_tmp="$dst.pre.jsonl"
  if jq -c --argjson tr "$trmax" --argjson tk "$tkmax" "$reshape_defs"'
    # tostring is applied ONLY when the value is over the cap, and never to null.
    # The first version ran it unconditionally, which did three wrong things: a
    # toolResult with .content null came out carrying the literal string "null",
    # a record with NO .content had the key invented and set to "null", and a
    # structured .arguments object was flattened to an escaped JSON string even
    # when it was 40x under the cap — destroying the very structure triage reads.
    # Verified against this exact program with jq before and after.
    # PRESENCE IS NOT A PAYLOAD. A presence check is true when the field is
    # null, so every guard below turned a null into a marker announcing that a
    # payload had been stripped -- the same false claim these guards exist to
    # stop, one level in. An absent key reads as null in jq, so this subsumes
    # the presence check. An empty object counts as no payload, since an
    # image_url of {} carries no url.
    def payload: . != null and (type != "object" or length > 0);

    def trunc($n):
      if . == null then null
      elif type == "string" then
        (if length > $n then .[0:$n] + "…[autodream: truncated]" else . end)
      else
        (tostring as $s
         | if ($s | length) > $n then $s[0:$n] + "…[autodream: truncated]" else . end)
      end;
    '"$reshape_pipe"'
    if (.message | type) == "object" then
      .message |= (
        # Raw provider round-trip, never useful for triage.
        del(.providerPayload)
        # OMP: a whole record is one tool result.
        | (if .role == "toolResult" then
             (if (.details | payload) then .details = "[autodream: details stripped]" else . end)
             # has() guard, not a bare assignment: `.content = (...)` CREATES the
             # key on a record that never had one.
             | (if has("content") then .content = (.content | trunc($tr)) else . end)
           else . end)
        # Claude Code: tool results are blocks. Also caps oversized thinking and
        # tool-call arguments in either schema.
        | (if (.content | type) == "array" then
             .content |= map(
               if .type == "tool_result" then
                 # Preserve tool_use_id + is_error so triage can still tell which
                 # call failed; only the heavy content array goes. has() guard for
                 # the same reason as everywhere else in this program: without it a
                 # block carrying no content came out ASSERTING that content was
                 # stripped, which is a claim about a payload that never existed.
                 (if (.content | payload)
                    then .content = "[autodream: tool_result payload stripped]"
                    else . end)
               elif .type == "thinking" then
                 # has() guard and NO `// ""`. The first version wrote
                 # `.thinking = ((.thinking // "") | trunc($tk))`, which invented
                 # `thinking: ""` on a block that never carried the key and turned
                 # an explicit null into an empty string — the same fabrication
                 # the parent commit fixed for .content and .arguments, at the
                 # third site of the same class three lines away. trunc handles
                 # null on its own now, so the `//` was doing nothing but harm.
                 (if has("thinking") then .thinking = (.thinking | trunc($tk)) else . end)
               elif .type == "toolCall" then
                 del(.partialArgs)
                 | (if has("arguments") then .arguments = (.arguments | trunc($tr)) else . end)
               # The two image shapes keep their payload in DIFFERENT places, and
               # collapsing them cost this branch its entire purpose. Claude puts
               # the base64 in .source; an OpenAI-style image_url block puts it in
               # .image_url.url. Setting .source on BOTH left the image_url payload
               # completely intact and added a marker claiming it had been removed
               # — a file whose header promises to strip base64 image data, shipping
               # the base64 and a receipt for its deletion. Each shape is stripped
               # where its data actually lives, and only if it is there.
               elif .type == "image" then
                 (if (.source | payload) then .source = "[autodream: image stripped]" else . end)
                 # OMP keeps its image payload in .data, which this branch did not
                 # touch at all. But .data is NOT always a payload: measured across
                 # 400 real OMP transcripts on this host, all 289 image blocks carry
                 # `blob:sha256:<hash>`, a 76-char content-addressed reference
                 # totalling 22KB against a 262144-byte cap. Replacing those with a
                 # marker would delete an identifier triage can use and save
                 # nothing. Only an inline data: URI is a payload, so only that is
                 # stripped; anything else goes through trunc as a backstop for a
                 # shape neither of us has seen.
                 | (if (.data | payload) then
                      .data = (if (.data | type) == "string" and (.data | startswith("data:"))
                                 then "[autodream: image stripped]"
                                 else (.data | trunc($tr)) end)
                    else . end)
               elif .type == "image_url" then
                 (if (.image_url | payload) then .image_url = "[autodream: image stripped]" else . end)
               else . end)
           else . end)
      )
    else . end
  ' "$src" > "$pre_tmp" 2>/dev/null && [ -s "$pre_tmp" ]; then
    pre_src="$pre_tmp"
    # Re-measure: head/tail/cap math below should reflect post-strip size.
    lines=$(wc -l < "$pre_src" | tr -d ' ')
  else
    rm -f "$pre_tmp"; pre_tmp=""
  fi
fi

# AUTODREAM_SLIM_FULL=1 keeps every surviving line and applies no byte cap, because the chunker
# does its own sizing at line boundaries. Lines are still cut to the line width.
{
  if [ "$full" = "1" ] || [ "$lines" -le $((headn + tailn)) ]; then
    cut -c1-"$maxline" "$pre_src"
  else
    head -n "$headn" "$pre_src" | cut -c1-"$maxline"
    printf '...[%d of %d lines elided by autodream for size]...\n' $((lines - headn - tailn)) "$lines"
    tail -n "$tailn" "$pre_src" | cut -c1-"$maxline"
  fi
} | { if [ "$full" = "1" ]; then cat; else head -c "$cap"; fi; } > "$dst"

[ -n "$pre_tmp" ] && rm -f "$pre_tmp"

# The footer is plain text. In full mode the output is cut into chunks, so it would land in the
# last chunk as a line that is not JSON, which the worker would read as transcript. The chunk note
# and the triage prompt already say that long lines are cut, so full mode appends none.
[ "$full" = "1" ] || printf '\n...[autodream slimmed this transcript: original %s bytes / %s lines; lines truncated to %s chars]...\n' \
  "$bytes" "$lines" "$maxline" >> "$dst"
