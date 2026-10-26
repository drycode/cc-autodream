## Harness addendum: OMP transcripts

This session came from Oh My Pi (omp), not Claude Code. Where this section disagrees with the text above, this section wins. The transcript you were given is the **live conversation branch only**: omp keeps an append-only tree, and the runner linearized it before you saw it.

**Record shapes.** A turn is a `message` record whose `message.role` is `user` or `assistant`; a tool result is a separate record. A tool call is a `custom` record with `customType: "tool_execution_start"`, named by its `data.toolName`; its result is the matching `customType: "tool_result"` record. A skill that ran leaves one `custom_message` record of `customType: "skill-prompt"`.

**Harness-provided tools are never `fabricated_id`.** A tool named `StructuredOutput` (or `SendMessage`, `Task`) appearing as a `tool_execution_start` record but NOT in the transcript's skill listing is provided by the workflow or subagent harness, not fabricated. Never flag it. Only flag a tool invocation as `fabricated_id` if the matching `tool_result` record is an error saying the tool does not exist. The same applies to any finding whose content would be that something should NOT be flagged: write nothing.

**`tool_loop` has no marker check here.** Judge severity on the transcript alone: a loop the agent breaks out of on its own is `low`; one that keeps going or ends the session is the real finding.

**Do NOT emit `compliance_markers`.** The field was retired for omp on 2026-08-08 after an archive-wide scan found zero real emissions of `RETRY-BUDGET:`, `FETCH-PIVOT:`, `DELEGATED:` or `DIRECT-OK:` in any omp session. Leave it out of the JSON and do not copy it from the stats block.

**Extra schema fields.** Add `"is_advisor": false` (or `true`, see below) and `"skills_authored": []` to the output object. `skills_authored` and the other skill fields come from the stats block verbatim, like `turn_count`. In omp a `manage_skill` call creates, updates or deletes a skill and never runs one.

**RESTRICTED SCHEMA: advisor sidecars.** If the Precomputed session stats block has `"is_advisor": true`, this transcript is an omp *advisor sidecar*: a reviewer model tailing a primary session, not an agent session. Its toolset is `read`, `grep` and `glob` only, by design. For these transcripts:

- NEVER emit `sandbox_friction`, `tool_loop` or `missed_skill`. `Tool "bash" not available` and `Tool "write" not available` are this transcript type's normal shape, not defects (and its `tool_call_count` counts the calls its toolset accepted, not the rejected attempts), and repeated attempts against those unavailable tools are not `tool_loop` either. On 2026-08-19 and 2026-08-20 these three categories produced seven false findings, five rated high, and nothing else.
- Do emit content findings. `buggy_code_shipped`, `fabricated_id`, `memory_miss`, `stop_projection` and `drift_after_compaction` remain in scope, because advisor narrative is sometimes the only place a piece of work is visible at all.
- Set `"is_advisor": true` in the output JSON and copy `turn_count` verbatim as always. L2 excludes advisor turns from session totals; do not zero or adjust them yourself.
