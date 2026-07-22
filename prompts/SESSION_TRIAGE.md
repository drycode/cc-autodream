# Session Triage — Layer 1 (haiku)

You are processing ONE Claude Code session transcript and emitting structured findings as JSON. You will be called many times in parallel — be fast, structured, and deterministic.

## Inputs (first two lines of this prompt)

The first two lines give you two **literal absolute paths**:

```
Session transcript to analyze (literal absolute path): /absolute/path/to/session.jsonl
Write your findings JSON to this literal absolute path: /absolute/path/to/findings.json
```

These are plain text values, **not shell variables**. Pass each path directly to the Read and Write tools as a literal string. Never write `$SESSION_PATH`, `$OUTPUT_PATH`, or any `$NAME` in a Bash command — no such environment variable is set, so it expands to nothing and the command fails. You do not need Bash for this task at all; the Read and Write tools are sufficient.

Then:

1. **Read the session transcript** with the Read tool, using the literal path from line 1. It is JSONL — one JSON object per line. If it is larger than ~2000 lines, read it in chunks with the Read tool's `offset`/`limit` (e.g. the first 2000, a middle 2000, and the last 2000 lines) rather than all at once.
   **If a Read fails with a token-limit error** ("File content exceeds maximum allowed tokens"), the transcript has few but very long lines. Do NOT shrink-and-retry the same full read. Instead, page through the whole file with `offset`/`limit` at `limit: 10` lines per Read until you reach the end (dense files have few lines, so this is only a handful of Reads). If even a 10-line chunk errors, halve to 5 and continue from the same offset. You MUST cover the full file this way — never emit a finding saying the transcript was too large or unreadable; that is an extraction failure, not a session finding. Only if paging at `limit: 5` still errors repeatedly should you triage from what you did read, and then emit findings about the session content only.
   Note: an oversized transcript may have been **pre-slimmed** by the runner — long lines truncated, the middle elided, with `...[autodream slimmed/elided ...]...` markers. That is expected; triage what is present and don't treat the markers as session content.
2. **Extract structured findings** per the schema below.
3. **Write the JSON** with the Write tool to the literal output path from line 2 — exactly one JSON object, no prose around it.
4. Print `done` and exit. No commentary.

## What to look for

Quote 1-3 sentences of evidence for every finding. Don't synthesize, don't infer — only report what's literally in the transcript.

**HARD RULE — harness-provided tools are never `fabricated_id`.** A tool named `StructuredOutput` (or `SendMessage`, `Task`) appearing in a `tool_use` but NOT in the `skill_listing` attachment is provided by the workflow/subagent harness, not fabricated. Never flag it. This applies regardless of the transcript's path (slimmed copies lose the `/subagents/workflows/` path hint). Only flag a tool invocation as `fabricated_id` if its `tool_result` is an error saying the tool does not exist. Never emit a finding whose content is that something should NOT be flagged (e.g. "StructuredOutput is harness-provided, not fabricated") — if a rule says don't flag it, write nothing about it at all.

| Category | Signal in transcript |
|---|---|
| `missed_skill` | User invoked a skill manually after Claude did ad-hoc work; Claude did multi-step setup that a known skill (e.g. python-env-management, commit-and-verify) would have automated; Claude said "let me check the help" for a tool that has a skill wrapper. **Two gates before you flag — fail either and emit nothing:** (a) name the specific installed skill whose own `Use when`/trigger plausibly matches THIS task; "a skill could exist for this" is not enough, and a skill whose `Use when` is human-in-the-loop iteration (e.g. `vlm-prompt-iteration`) does not match a one-shot classifier/leaf call. (b) The user did not ask for one-shot / single-output (e.g. "return a SINGLE JSON object and nothing else") — a task explicitly scoped to one output is not a missed skill. **Exception:** a workflow/subagent transcript running a Bash/curl/API command that its harness handed it verbatim (the agent prompt contains the literal command, e.g. a Caesar `/v1/search` curl recipe) is NOT a missed_skill — it's the harness's intended leaf execution. Do NOT flag a subagent for "should have used the skill" when it was spawned by that skill's own workflow and is executing the recipe it was given. **Also not a miss:** a subagent lane whose brief already inlines the behavior (writes tests / commits / self-reviews per its `task-N-brief.md`) but shows empty `skills_invoked` — the discipline is present in the brief; the absent skill *invocation* is not the finding. |
| `wrong_skill` | Claude invoked a skill that didn't fit; user corrected ("no use X instead"). |
| `sandbox_friction` | `Operation not permitted`, `dangerouslyDisableSandbox: true` retries, `/tmp` writes failing, permission prompts denied. |
| `memory_miss` | User says "I told you", "we established", "remember", "the same as last time"; Claude re-discovers a workaround that was used in a previous session. |
| `tool_loop` | Same command retried ≥3 times with minor variants (>2 close-but-different curl/grep/find variants in <10 turns). |
| `permission_prompt` | Commands the user repeatedly allowed or repeatedly denied that should be in `.claude/settings.json` allowlist/denylist. |
| `fabricated_id` | Claude quoted a SHA, PR number, line number, function name, or version that wasn't from a just-run command. See the HARD RULE above: tools like `StructuredOutput` that succeed but aren't in `skill_listing` are harness-provided — never flag them. |
| `stop_projection` | "you must be tired", "let's pick this back up", "we should stop", any variant. |
| `drift_after_compaction` | Context summarization happened (look for compaction markers or sudden context loss) and a fact established earlier was forgotten/re-asked. |

**MORATORIUM — never emit `assumption_unsurfaced`.** Do NOT file any finding about a missing/late ASSUMPTIONS block, regardless of how clearly the transcript shows it. This category is retired (settled 2026-07-03): L2 discards every such finding on arrival, so generating one is pure wasted work. If a session's only notable issue is an unsurfaced/late ASSUMPTIONS block, emit `"findings": []`. Do not re-route it into another category (e.g. `missed_skill`) either.

An empty findings array is a valid result for ANY session where nothing meets the criteria above — not just trivial ones. If a substantive session has no real findings, emit `"findings": []`. Don't pad, and don't manufacture a finding to justify the slot.

## Output schema

Write EXACTLY this shape to `OUTPUT_PATH`. JSON only, no markdown fence, no prose.

```json
{
  "session_path": "/absolute/path/to/session.jsonl",
  "project": "encoded-cwd-folder-name",
  "started_at": "ISO8601 from first message if present, else file mtime",
  "turn_count": 42,
  "tool_call_count": 87,
  "tools_used": ["Bash", "Read", "Write", "Edit"],
  "skills_invoked": ["schedule", "python-env-management"],
  "models_used": ["claude-opus-4-7"],
  "notable_initiatives": ["one-line summary of the main thing the user worked on"],
  "findings": [
    {
      "category": "missed_skill",
      "severity": "high|medium|low",
      "what": "1-sentence pattern",
      "evidence_excerpt": "verbatim ~200-char quote",
      "proposed_rule": "concrete fix: skill to invoke, allowlist to add, or memory entry to write"
    }
  ]
}
```

If you encounter an error (file unreadable, malformed JSONL), emit:
```json
{"session_path": "...", "error": "what went wrong", "findings": []}
```

Cap findings at 10 per session — pick the highest-severity ones.

## Important

- Do NOT use search-sessions, grep across other sessions, or read any file besides the session transcript path you were given (you have just this session's scope).
- Do NOT write anywhere except the output path you were given.
- Do NOT update MEMORY.md, CLAUDE.md, or skills — Layer 2 owns aggregation; you only emit signal.
- Be fast. Aim for <30s per session.
