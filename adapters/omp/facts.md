Sessions from this source ran under Oh My Pi (omp). When you propose a remedy for a
finding whose evidence is an `omp` session, these are the surfaces that exist:

- `sandbox_friction` - omp has no `settings.json`. A tool refusal comes from omp's
  bash approval layer (`bash.patterns` and `allowCompoundCommands` in
  `~/.omp/agent/config.yml`) or from a plugin's classifier, so read the block message
  in the transcript before proposing anything. `omp -p` workers run headless and have
  no approval UI.
- `missed_skill` - omp skill roots plus `skills.ignoredSkills` in
  `~/.omp/agent/config.yml`. Skills compiled into the omp binary have no file on disk,
  so absence from `skills-inventory.txt` is not absence of the skill: reconcile
  against the session's own skill surface.
- `memory_miss` - omp's mnemopi autolearn owns memory. Propose a rule
  (`~/.omp/agent/RULES.md`, which reaches task subagents; `AGENTS.md` does not), a
  hook, or a doc note. A pin for an omp-only finding is allowed when it sets
  `"harness":"omp"`: omp reads the same Mnemopi store, and the tag keeps the pin out
  of Claude Code's startup context. The runner holds a tagged pin (`pins_unsupported_harness`
  in `pins-result.txt`) until the installed `shared-memory` filters on the tag. Durable
  behavior still belongs in a rule, because a pin can be crowded out of the startup budget.
- `compliance_failure` - cite `~/.omp/agent/RULES.md`, `AGENTS.md`, or the project's
  rule surface.

Some omp transcripts are not agent sessions. `__advisor.jsonl` and
`__advisor-<name>.jsonl` record a reviewer model watching a primary session: its
toolset is read, grep and glob only, so `Tool "bash" not available` is its normal
shape and is never `sandbox_friction`. Its `tool_call_count` counts the calls the
toolset accepted, not rejected attempts. The sidecar's
`is_advisor` field says which transcripts these are. Task subagent transcripts
(`<session>/<Name>.jsonl`) are real sessions, flagged `nested`.
