# Design: one autodream, many harnesses

Date: 2026-08-23
Status: APPROVED by panel (executor, auditor, antigravity)
Baselines read for this document: `cc-autodream` at `0dffef5` (branch `retire-compliance-markers`), `omp-autodream` at `387e7bc` (branch `main`), `seanperkins/autodream-merge` at `c4ebdfc`.

**Revised 2026-09-15.** The pin and memory-GC design below (Decision 3, "Pin protocol", "Memory GC") assumed a per-adapter memory store. Every harness on this host now reads one shared Mnemopi store instead, so the per-`(source, memory_root, project)` triple expansion, the `apply-pin` exit-code routing, and adapter-owned GC described in this document are retired. See `docs/plans/2026-09-15-mnemopi-pins.md` for the current design.

## Problem

Three repos do one job.

- `STRML/cc-autodream` — the nightly for Claude Code.
- `STRML/omp-autodream` — the nightly for Oh My Pi, ported 2026-08-17.
- `seanperkins/autodream-merge` — a consumer that merges the two repos' findings dirs into one report.

The port was a copy. Measured divergence between the two runners, counting changed lines against combined line count:

| File | Divergence |
| --- | --- |
| `bin/vault-notes.sh` | 0% |
| `bin/x-bookmarks.sh` | 0% |
| `bin/oversized-gate.sh` | 0% |
| `bin/cookie-cadence.sh` | 0% |
| `bin/slim-transcript.sh` | 0% |
| `bin/overlap-stats.sh` | 0% |
| `bin/autodream-now.sh` | 0% (4 lines) |
| `prompts/SESSION_TRIAGE.md` | 1% (4 lines) |
| `bin/notify.sh` | 4% |
| `bin/session-stats.sh` | 9% |
| `bin/run.sh` | 10% |
| `bin/root-probe.sh` | 11% |
| `prompts/PROMPT.md` | 15% |
| `bin/prune-self-sessions.sh` | 19% |
| `install.sh` | 32% |
| `bin/review.sh` | 32% |

Six files are byte-identical. Every fix now has to be ported by hand, and a fix that lands in one repo and not the other is invisible until a night goes wrong.

The split also costs the reader. A pattern with evidence in both harnesses lands in two reports, and neither can rank it. `autodream-merge` exists to recover that signal, and it works, but it recovers the signal by re-deriving facts that were available at triage time and are cheaper to get right there.

## Goals

1. One repo, one nightly, one report.
2. Harness support is a directory, not a fork. Adding `codex` or `pi` later means writing one directory and touching no shared code.
3. Findings carry which harness produced them, because the remedy differs per harness.
4. No regression against today's cc-autodream behavior on a single-harness host.

## Non-goals

- Running one engine against another harness's sessions. Each harness's sessions are triaged by that harness's engine.
- Preserving per-harness reports. One report covers the union.
- Migrating historical findings dirs. Old dirs stay readable by `oversized-gate.sh` and `cookie-cadence.sh`, which recompute from artifacts. This constrains the session-list format and the hash formula, both of which those tools recompute; see "Session list".

## Decisions

Five decisions were settled before this document was written.

1. **Repo identity.** Rename `STRML/cc-autodream` to `STRML/autodream`. GitHub redirects the old URL, so existing clones and the live `~/.claude/autodream` symlinks keep working. Archive `omp-autodream` and `autodream-merge` with pointers.
2. **Aggregation shape.** L1 fans out across every enabled adapter into one findings dir. One L2 pass over the union, always. A single-harness day is the degenerate case where N is 1. There is no conditional merge path and no merge phase.
3. **Memory writes.** L2 becomes a pure function: findings in, report and proposed pins out, no filesystem writes. Each adapter owns its own memory store and applies the pins routed to it. Revised 2026-09-15: one shared Mnemopi store serves every harness on this host, so there is no adapter-owned store to route to. L2 still writes proposed pins to a file rather than stdout, and `run.sh` applies them directly against Mnemopi; see `docs/plans/2026-09-15-mnemopi-pins.md`.
4. **Adapter shape.** A directory holding declarative facts, code, and prompt text.
5. **Rollout.** One branch, one cutover. A replay harness against an archived corpus stands in for phased verification.

Decision 5 was taken against the recommendation in this document's discussion, and the review panel independently recommended against it as well (the Architect seat asked for a three-day side-by-side into a parallel `dreams-v2/`). The recorded objection: the first real integration test runs unattended at 03:15, which is the shape of both failures the repo's `CLAUDE.md` documents at length — the 2026-08-02 `tee` SIGPIPE and the four nights of `run-stats.txt` written by a stale runner. The decision stands as the author's call. The replay harness in the test section is the agreed mitigation, and it is explicitly not a substitute for operational verification.

## Architecture

### Layout

```
autodream/
  bin/
    run.sh              orchestrator, harness-agnostic
    adapters.sh         loader and dispatcher                    [new]
    lib-project.sh      canonical project encoding               [new]
    preflight.sh        shared-dependency and engine checks      [new]
    session-stats.sh    dispatches parsing to the adapter
    prune-self-sessions.sh, root-probe.sh, slim-transcript.sh
    vault-notes.sh, x-bookmarks.sh, notify.sh, autodream-now.sh,
    oversized-gate.sh, cookie-cadence.sh, overlap-stats.sh, review.sh
  adapters/
    claude/   manifest.json  adapter.sh  facts.md  install.sh
    omp/      manifest.json  adapter.sh  facts.md  linearize.sh  install.sh
    _fixture/ manifest.json  adapter.sh  facts.md                [test-only]
  prompts/
    SESSION_TRIAGE.md   one file
    PROMPT.md           one file, source-aware, stdout-only
  tests/
```

Nine `bin/` scripts move across unchanged. Six of those are already byte-identical between the repos, so there is no merge to perform on them.

### The adapter contract

Each adapter is a directory with three required files and one optional one.

**`manifest.json`** — declarative, read with `jq`. It is JSON rather than sourced shell because a sourced manifest executes arbitrary code as the user, and a plugin format whose parser is `bash` is an injection surface the moment a third-party adapter is a reasonable idea. `jq` is already a hard dependency.

```json
{
  "name": "omp",
  "session_roots_default": ["$HOME/.omp/agent/sessions"],
  "session_glob": "*.jsonl",
  "engine_bin": "omp",
  "engine_flags_l1": ["--allow-home", "-p", "--permission-mode", "bypassPermissions"],
  "l1_model": "runinfra/deepseek-v4-flash"
}
```

`$HOME` is the only interpolation performed, by explicit substitution rather than by evaluation.

**Adapter identity is the directory basename, not the manifest.** Dispatch builds `adapters/<name>/adapter.sh` from the directory it enumerated, never from a manifest field, so a malformed or hostile manifest cannot reintroduce the command-path construction that JSON parsing was adopted to remove. A directory whose basename is not a safe identifier — matching `[a-z][a-z0-9_-]*`, with no separators and no leading dot — is refused at load with a named counter. The basename check alone is not containment: `adapters/evil` may be a symlink pointing anywhere. Each adapter directory is therefore resolved with `realpath` and refused unless it is still under the adapters root, which closes the escape a name-only check leaves open. `name` inside the manifest must equal the basename; a mismatch is a load-time error rather than a silently preferred value, because two disagreeing identities is exactly the state where a later reader picks the wrong one.

**L2 engine configuration is orchestrator-level, not adapter-level.** An earlier draft put an `l2_eligible` flag in the manifest; that conflates a harness's ingest capability with the orchestrator's choice of reasoning engine, and it is a regression against today's behavior, where `run.sh` already resolves `AUTODREAM_L2_MODEL` as a global knob (`bin/run.sh:1085-1092`). The unified runner keeps `AUTODREAM_L2_BIN` and `AUTODREAM_L2_MODEL` global. L2 may therefore run on an engine that is not an enabled adapter at all.

**`adapter.sh`** — one subcommand per place the two runners diverge today. The list was derived from the diff above, not from anticipated need.

| Subcommand | Contract | Absorbs |
| --- | --- | --- |
| `enumerate <root> <target-date> <next-date>` | prints absolute session paths **NUL-delimited** (`find -print0`), for modification times in `[target-date, next-date)`; the runner reads them with `read -r -d ''` | `root-probe.sh` 11% |
| `normalize <in> <out>` | writes a triage-ready transcript to `<out>`; nonzero exit means skip this session | new |
| `project <session>` | prints the session's real working directory, absolute and symlink-resolved | new |
| `stats <session>` | prints the stats sidecar JSON | `session-stats.sh` 9% |
| `slim <in> <out>` | writes a size-reduced transcript to `<out>` | `slim-transcript.sh` |

**`enumerate` is NUL-delimited, and the delimiter is load-bearing.** An earlier
draft of this table said "one per line" and named two arguments, which is neither
what ships nor what the runner can consume. An adapter written to that row emits
newline-separated paths; `read -r -d ''` then takes the entire listing as one
path, the reject filter drops it for containing newlines, and the whole root's
corpus disappears with `sessions_rejected_path: 1` as the only trace. The
line-based artifact is `sessions.txt`, which is a different thing from the
transport — see the note on that split below.
| `is-self <session>` | exit 0 if this is one of autodream's own worker transcripts | `prune-self-sessions.sh` 19% |
| `skills-inventory` | prints the active skill list, one per line | `omp-autodream/bin/skills-inventory.sh` |

`apply-pin` and `gc` were dropped from this table on 2026-09-15, and `memory-root` is retired with them: one shared Mnemopi store has no per-adapter root to resolve. The subcommand and the manifest's `writes_memory` field were removed from every adapter on 2026-10-04 (https://github.com/STRML/autodream/issues/74). `bin/apply-pins.sh` applies pins for every adapter (see Pin protocol).

**Every subcommand has a named skip path and atomic output.** A subcommand that writes a file writes to `<out>.tmp` in the destination directory and renames on success; a nonzero exit leaves no `<out>` and removes any partial `<out>.tmp`. A nonzero exit from `project`, `stats`, or `slim` skips that session with its own counter, exactly as `normalize` does — the earlier draft specified failure handling only for `normalize`, which left three subcommands with undefined behavior on a partial write.

The runner also re-checks readability immediately before each read rather than once at the top. `bin/run.sh:553` checks a session is readable and `bin/run.sh:588` sizes it later; a file deleted between those two produces an empty `wc` result and still reaches the worker.

`normalize` fails closed. An OMP session file is an append-only tree where branching moves a leaf pointer rather than rewriting the file, so the file physically retains work the user backed out of. Reading it raw attributes discarded work to the user. A non-OMP file, an unparseable line, a `parentId` cycle, or a dangling parent each exit nonzero with no output, and the caller skips that session with a named error. For the claude adapter, `normalize` is a copy.

**`linearize.sh` is new work, not a port.** An earlier draft said it could be brought across from `omp-autodream`. It cannot: that repo has no such file, tracked or untracked, and its runner feeds L1 the raw session (`omp-autodream/bin/run.sh:623`, `readpath="$session"`). The implementation exists only in closed PR `STRML/cc-autodream#47` and must be rewritten here with its own fixtures. This has a second consequence worth stating plainly: **`omp-autodream` is triaging OMP session trees whole today**, abandoned branches included. That is a live defect in shipped code and is filed separately.

**`facts.md`** — the remedy vocabulary for this harness, concatenated into the L2 prompt under a `## source: <name>` heading. This exists because the same finding category needs a different remedy per harness:

| Finding | Claude Code remedy | OMP remedy |
| --- | --- | --- |
| `sandbox_friction` | a `permissions.allow` line in `settings.json` | OMP has no `settings.json`; a different mechanism |
| `missed_skill` | a trigger phrase in a `SKILL.md` | OMP skill roots plus `config.yml` `ignoredSkills`; built-ins are compiled into the binary and are not on disk |
| `memory_miss` | a Mnemopi pin, written to `pins.jsonl` and applied by `bin/apply-pins.sh` | a rule, a hook, or a doc note; mnemopi autolearn owns memory |
| `compliance_failure` | cite `~/.claude/CLAUDE.md` | cite OMP's rule surface |

Without this, L2 proposes editing a `settings.json` that does not exist for the session it is talking about. Roughly half of today's 15% `PROMPT.md` divergence is exactly this text.

**`install.sh`** — optional. The core installer handles the orchestrator: symlinks, base directories, the launchd job. Anything harness-specific is an `adapters/<name>/install.sh` hook the core script invokes when present. This is why the two `install.sh` files sit at 32% divergence; a monolithic installer that understands every harness's dependencies would re-create the fork inside one file.

### Session list

**`sessions.txt` keeps its existing shape: one bare absolute path per line.** An earlier draft proposed `<source>\t<path>`, which is wrong. Four separate consumers derive an artifact key or a filesystem path from the whole line:

- `bin/run.sh:468` — `h=$(printf "%s" "$s" | shasum -a 1 | cut -c1-12)`
- `bin/run.sh:540` — the same hash inside the `xargs -P … -I {}` worker
- `bin/oversized-gate.sh:73` — recomputes that hash from `sessions.txt`
- `bin/oversized-gate.sh:81` — `size=$(wc -c < "$session")` when the sidecar is degraded

A tab in the line corrupts the hash in all four and makes the size read fail, which the gate then counts as unmeasurable even though the transcript exists. It would also silently invalidate every archived findings dir, since the gate recomputes hashes from artifacts that survive independently of the runner.

Source is carried in a sidecar instead: `findings/<date>/sessions-source.txt`, one `<hash>\t<source>` line per session. The hash stays `sha1(bare path)`, so every existing consumer and every archived dir keeps working untouched.

**Transport and the line-based artifact are two different things, and an earlier draft conflated them.** Enumeration hands paths to the runner NUL-delimited (`find -print0`, `read -r -d ''`), which fixes the split where a newline in a path became two sessions. But `sessions.txt` stays line-based, because `oversized-gate.sh` and every archived findings dir depend on that shape, and the L1 fan-out reads it with `xargs -I {}` rather than `xargs -0`. A line-based file cannot represent a path containing a newline, so NUL transport alone does not save it.

**Newline, tab, backslash and quote are all rejected.** A path containing any of them is dropped at enumeration with `sessions_rejected_path`.

An earlier draft of this document accepted tabs, on the reasoning that `IFS= read -r` preserves them and the artifact hash covers them. Both of those are true, and both were the wrong consumers to check. The one that matters is the L1 fan-out, which is `xargs -I {}` over a line-based list — measured on this host: a tab becomes a space, a backslash is deleted, and a quote kills `xargs` outright with `unterminated quote`, taking the whole night's dispatch rather than one session.

So this is a refusal, not a fix: a legal filename is declined because the transport cannot carry it. Making the fan-out NUL-safe would let them be accepted again and is tracked as `STRML/cc-autodream#54`. The fan-out is **not** `xargs -0` today; NUL delimiting applies only to the in-memory enumeration hand-off.

The rejected path is logged with control characters escaped. A newline written raw into the log would forge additional log lines, which is a small thing until the forged line is the one someone reads.

NUL transport still earns its place — it removes the whole class of word-splitting bugs on the paths that *are* accepted, spaces and glob characters among them.

**Cross-adapter collision.** Two adapters enumerating the same absolute path produce the same `<hash>.json`, and the second worker overwrites the first source's findings. Changing the hash formula to include the source would fix it and break every archived dir, so instead the union step detects a path claimed by more than one adapter, logs both adapter names, keeps the first, and counts `sessions_duplicate_path`. In practice this means two adapters are pointed at one store, which is a misconfiguration worth seeing rather than resolving silently.

**Hash collision between distinct paths.** The artifact key is a 12-character truncation of SHA-1, so two different paths can in principle land on one filename, and the failure is a silent overwrite of one session's findings by another. At 48 bits the birthday bound sits far above any real corpus, so this is not expected to fire; the check is included because it costs one associative lookup during the union and the failure it prevents is invisible. The union records hash to path, and a hash arriving with a different path than the one already recorded is rejected with `sessions_hash_collision`, both paths logged. Unlike the duplicate-path case there is no sensible resolution, so both sessions are skipped rather than one being chosen arbitrarily.

### Project identity

`autodream-merge` reconciles project identity after merging, by re-encoding an OMP session's header `cwd` into Claude's bucket name (`bin/merge-reports.sh:162`). That pass is best-effort by construction, and its encoder is wrong: it maps `/` only, while Claude also maps `.` and `_`. Verified against real buckets on the target host:

```
/Users/samuelreed/.claude
  merge-reports -> -Users-samuelreed-.claude    bucket exists? no
  correct       -> -Users-samuelreed--claude    bucket exists? yes

/private/var/folders/c2/29g2958n6t92169z_4tvmsb80000gn/T/tmp-2wxKWV0A91
  merge-reports -> ...29g2958n6t92169z_4tvmsb80000gn...   bucket exists? no
  correct       -> ...29g2958n6t92169z-4tvmsb80000gn...   bucket exists? yes
```

A wrong encoding splits a project silently: the record has a `cwd`, so it is never counted as unreconciled.

This design removes the failure rather than fixing the encoder. `adapter project <session>` returns the session's real working directory, absolute and symlink-resolved. One shared `lib-project.sh` encodes it once, mapping `/`, `.`, and `_` to `-`. Every harness produces the same key for the same directory at L1 time. There is no reconciliation phase, so there is no `records_unreconciled_project` counter, because there is nothing to fail.

Symlink resolution matters on macOS: Claude records the physical path, so a session in `/tmp/foo` becomes `-private-tmp-foo`, while OMP's header `cwd` is unresolved.

## Nightly flow

0. **Preflight.** `bin/preflight.sh` verifies the shared dependencies the runner assumes today — `jq` (`bin/run.sh:360`), `shasum` (`bin/run.sh:468`), `python3` (`bin/run.sh:924`) — plus `realpath`, and the configured L2 engine binary. `realpath` is new and it is security-critical rather than convenient: it resolves adapter directories for containment and canonicalizes `cwd` for project identity. A host that reaches adapter loading without it would fall back to weaker containment, which is the failure the check exists to prevent, so its absence is a hard stop and never a degraded path. A missing `shasum` is the dangerous one: the hash assignment silently yields an empty string and every session targets the same findings filename.

`python3` is a **warning, not a hard failure**, because `run.sh` already degrades gracefully without it — it skips project-field normalisation and says so. Making preflight fatal on it contradicted that, and would have been a nightly-killer on this host specifically: `run.sh` hard-overrides `PATH` to a fixed list, so a `python3` that exists only as a pyenv shim is genuinely unreachable from the nightly, and every run would have stopped rather than producing a slightly-worse report.
1. `run.sh` resolves enabled adapters from `AUTODREAM_ADAPTERS` (default: every `adapters/*/manifest.json` except `_fixture`), then verifies each adapter's `engine_bin`. An adapter whose engine is absent is disabled with a counter; this is not fatal. The L2 engine check at step 0 is separate and *is* fatal, because without it no report is possible.
2. Per adapter, `enumerate` produces a session list. The union is written to `sessions.txt` (bare paths) plus `sessions-source.txt` (hash to source), with `sessions.txt.raw` kept pre-filter as today.
3. Per session: `is-self` filter, then `normalize`, then `stats` sidecar, then the noise gate, then `slim`, then the L1 worker on that adapter's engine and model.
4. The L1 model emits **triage payload only**. `run.sh` validates that JSON and then envelopes it, atomically, with provenance the runner already resolved: the session path, the adapter `source`, the raw `cwd` from `adapter project`, and `encode(cwd)` as `project`. The result is one `<hash>.json` per session in one findings dir.

   **The model never supplies its own provenance.** Those four fields later authorize pins and scope each memory to a project, so a model that could write them could name a source and project it never touched — and L1 reads a transcript, which is attacker-adjacent input on any day someone pastes something interesting into a session. Runner-stamped provenance makes the authorization set a property of what the runner enumerated rather than of what a transcript talked the model into. Any provenance field present in the model's own output is discarded, not merged. A fixture emits forged `source` and `project` from L1 and asserts they cannot affect pin eligibility.

   Raw `cwd` and canonical `project` are both retained: with only the canonical value, `tests/replay.sh --artifacts` could assert nothing about the encoder except that it agrees with itself. Keeping the input alongside the output makes `encode(cwd) == project` a real assertion.
5. Shared collectors run once for the date: changelog window, operator notes, X bookmarks, skills inventory (the union across adapters), `run-stats.txt`.
6. L2 runs once, on the globally configured engine, with `--tools Glob Read`. Its prompt is `PROMPT.md` followed by each enabled adapter's `facts.md`.
7. L2 prints the report to stdout, terminated by `AUTODREAM_REPORT_END`, followed by a pin block. `run.sh` slices from the last sentinel, validates, and writes `dreams/<date>.md` through a temp file and rename.
8. L2's proposed pins, if any, land in `<findings-dir>/pins.jsonl`. Revised 2026-09-15: once the report is confirmed complete, and before `notify.sh` or any consume step (either can hold or end the run first), `run.sh` writes `pin-projects.tsv` and runs `bin/apply-pins.sh` to apply each pin against the one shared Mnemopi store every harness reads; see "Pin protocol" below.
9. Consume gates run: vault note archive, bookmark mark-read. Project memory GC is retired along with the per-adapter store; see "Memory GC" below.

Steps 7 and 8 are ordered deliberately. The report reaches disk before any pin is applied, so a pin failure cannot cost a report.

### Report delivery

L2 has no `Write` tool, so it cannot write the report itself. It prints, and `run.sh` captures.

The parser contract, stated exactly, because an earlier draft said "slices from the last sentinel" and that reads as though the report were the text *after* it:

- **A sentinel is an exact standalone line, never a substring.** A line matches only if, after stripping a trailing `\r`, it equals the sentinel with no leading or trailing whitespace and nothing else on the line. Substring matching would let the pin fixture below — a JSON value containing the literal string `AUTODREAM_REPORT_END` — be selected as the delimiter and truncate the report at that point. Input is normalized to LF before scanning so a CRLF capture behaves identically.
- The report is everything **before** the selected `AUTODREAM_REPORT_END` line. Pins are the lines **between** an `AUTODREAM_PINS` line and an `AUTODREAM_PINS_END` line, both of which follow it.
- When more than one line matches `AUTODREAM_REPORT_END`, the **last** matching line is selected and the report is the text preceding it. This is what protects against a model that narrates a draft, corrects itself, and emits the real report second.
- A capture is a validated delivery when **at least one** matching line exists, the text preceding the **last** one is non-empty, and that text carries the `autodream:open-questions=` marker. Anything else is a truncated capture and goes to the retry loop. An earlier draft said "exactly one was selected", which contradicts last-wins: every two-sentinel capture would have retried, defeating the draft-then-corrected case the rule exists to rescue. The two-sentinel fixture asserts the second report is accepted, not that the capture is rejected.
- The pin block is optional. Its absence is a report with no proposed pins, not a failure.

A fixture covers each branch: no sentinel, two sentinels, sentinel with no marker, sentinel with no pin block, and a pin block containing the literal sentinel string inside a JSON value.

**`PROMPT.md` is rewritten, not reused.** Today's prompt instructs the model to write the report to a path (`prompts/PROMPT.md:183`), to edit `MEMORY.md` (`prompts/PROMPT.md:152`), to append to `touched-projects.txt` (`prompts/PROMPT.md:168`), and states it holds `Glob Read Write Edit` (`prompts/PROMPT.md:73`). Invoked with `Glob Read`, that prompt makes the model attempt impossible writes or omit required output. Migration step 4 produces a pure stdout prompt with every write instruction removed, and a test asserts the prompt text contains no write directive.

This is the same defect `autodream-merge` ships: it reuses cc-autodream's `PROMPT.md` verbatim under `--tools Glob Read`, with a header telling the model to print instead. None of that prompt's write instructions are satisfiable under its own invocation.

### Pin protocol

**Revised 2026-09-15.** This section originally routed pins per `(source, memory_root, project)` triple, one adapter store per harness. Every harness on this host now reads one shared Mnemopi store, so there is nothing left to route between. The design below is `docs/plans/2026-09-15-mnemopi-pins.md`, restated here so this document stays the single reference for the pin path.

L2 writes proposed pins to `<findings-dir>/pins.jsonl`, one JSON object per line:

```
{"project":"-Users-x-repo","title":"one line, at most 150 chars","body":"the full memory","kind":"correction"}
```

`project` is the canonical `project` value already stamped onto a findings record for this run. `kind` is one of `correction`, `preference`, `fact`, or `decision`. `body` is at most 4000 characters. No file means no pins.

Before each L2 attempt, `run.sh` moves an existing `pins.jsonl` aside to a unique `pins.jsonl.stale-XXXXXX` made by `mktemp`: it came from an earlier run or a dead attempt, and no complete report from this attempt stands behind it. A failed move clears `PINS_SAFE`, and the run stores no pins.

After a complete report, and only when `CONSUME_SAFE=1` and `PINS_SAFE=1`, `run.sh` writes `<findings-dir>/pin-projects.tsv`: one `project<TAB>cwd` row per distinct project in this run's worklist (`sessions.txt`). The rows are computed before the first L1 call and held in the runner's memory until the pins are applied, because L1 and L2 both run with the Write tool and could otherwise rewrite the worklist files before they are read. The project is the directory directly under the session root that holds the session, so a subagent transcript (`<bucket>/<session>/subagents/agent-*.jsonl`) or a workflow agent one level deeper counts toward its bucket, and a bucket literally named `subagents` stays itself. The findings normalization takes its project from the same rows, looked up by findings file hash. `cwd` comes from the `project` subcommand of that session's own adapter (looked up in `sessions-source.txt`); a session whose cwd the adapter cannot resolve counts as one more distinct, unusable cwd. Neither is read from a findings JSON: outside the slim case its `session_path` is whatever the L1 model wrote, and a forged one would otherwise authorize memory for a project the run never triaged. Two more checks keep a pin in its own project's bank. For a dash bucket, the cwd must encode (`encode_project`) to the bucket its session is stored in; a `CLAUDE_CODE_PROJECT_DIR_NAME` slug bucket skips this, since no cwd encodes to a slug. And a bucket whose sessions report more than one distinct cwd, such as `/tmp/a_b` and `/tmp/a-b`, gets no cwd at all, counting any cwd that failed the first check as one of them. It then runs `bin/apply-pins.sh <findings-dir> <date>`. Pins do not depend on the date gate the report does: an old-date rebuild is still a real lesson, and the ledger below stops a rerun from writing it twice.

**Project validation replaces source validation.** There is no adapter to name, so a pin is checked against `pin-projects.tsv` instead of against an enabled-adapter set: a project absent from that file is rejected with `pins_rejected_project`, and a project present but with an empty or missing `cwd` is rejected with `pins_no_cwd`. Both are read from the file the runner itself wrote for this run, the same authorization principle the old triple check served: a pin can only name what this run actually observed.

`bin/apply-pins.sh` validates each line's schema (`kind` one of the four values, `title` non-empty, at most 150 characters, no newline, `body` non-empty, at most 4000 characters), then calls `shared-memory call mnemopi_remember '<json>' --cwd <cwd>` with content `title\n\nbody`, `source: cc-autodream`, `importance: 0.7`, metadata `{kind, project, autodream_date, origin: "cc-autodream"}`, and `bank` set to the `retainBank` that `shared-memory context --cwd <cwd>` reports. `mnemopi_remember` resolves its bank from the payload, then `MNEMOPI_MCP_BANK`, then `default`, never from `--cwd`, so leaving it out would put every project's pin in the global store. A call succeeds only on exit `0` with `status: "stored"` and a string `memory_id`.

**Each success is ledgered so a rerun cannot double-write.** A successful call appends `<sha1 of the resolved bank and the canonical pin>\t<memory_id>` to `pins-applied.tsv`; a pin whose hash is already ledgered is skipped rather than resent. Counters (`pins_total`, `pins_applied`, `pins_invalid`, `pins_rejected_project`, `pins_no_cwd`, `pins_duplicate`, `pins_cli_missing`, `pins_failed`, `pins_unledgered`, `pins_unreadable`, `pins_unsupported_harness`) go to `pins-result.txt`. A pin that was stored but whose ledger row could not be written counts as `pins_unledgered`, never as applied, and its memory id goes to the run log. The script exits `0` after its arguments parse whatever happened to the pins, except `3` when `pins-result.txt` cannot be cleared or written (then the caller must not read the old counters, and nothing is stored when it cannot be cleared), on the same principle the old `apply-pin` exit-code contract served: a pin must never cost a report.

`SHARED_MEMORY_BIN` overrides the CLI path. The test suite pins it to `tests/mock-shared-memory.sh`, so no test can write real memory.

Deleted along with the triple-based design: the `sources` array and its path-separator and unknown-adapter checks, the `(source, memory_root, project)` expansion, `apply-pin`'s exit-code routing (`0`/`10`/other), and the `writes_memory` manifest flag's role in pin dispatch. `apply-pin` never shipped in any adapter.

Known limit: the ledger stops the same pin text landing twice. Reworded pins from a forced rebuild do land twice. Mnemopi's own review pass owns consolidation, as `claude-memory gc` did before.

### Memory GC

**Retired 2026-09-15.** GC was an adapter operation: `run.sh` called `adapter gc <memory-root> <project>` once per triple whose `apply-pin` returned `0`, so each harness's own consolidator could resettle around newly written pins. That whole mechanism depended on a per-adapter memory store to resettle, and no such store exists once every harness reads one shared Mnemopi store. There is no `gc` subcommand, no `AUTODREAM_GC` knob, and no `touched-projects.txt` sidecar to drive it; `bin/run.sh`'s consume-gate step no longer calls out to any consolidator.

This also retires the defect this section used to track: `bin/run.sh:294` scanned every configured Claude root while GC resolved projects only under `$PROJECTS_DIR`, so a pin written for a session in a secondary profile was recorded and then silently skipped. That was filed as `STRML/cc-autodream#52`. Pins now route by `cwd`, read fresh from `pin-projects.tsv` for the project this run actually observed, not reconstructed from a primary-root assumption, so the failure mode #52 tracked cannot occur. `STRML/cc-autodream#52` should be closed as obsolete with a pointer to `docs/plans/2026-09-15-mnemopi-pins.md`.

## Failure handling

| Failure | Behavior |
| --- | --- |
| a hard dependency is missing (`jq`, `shasum`, `realpath`) | hard failure at preflight with a named key; never a degraded run |
| `python3` is missing | a DEGRADED warning; project-field normalisation is skipped and the run continues |
| the configured L2 engine binary is absent | hard failure at preflight, before L1 runs |
| adapter manifest missing or unparseable JSON | skip that adapter, log, continue |
| adapter `engine_bin` absent | disable that adapter, count, report; not fatal |
| every adapter disabled | hard failure; there is nothing to triage |
| `normalize`, `project`, `stats`, or `slim` exits nonzero | skip the session with that subcommand's own counter; partial output removed |
| a session path contains a newline, tab, backslash or quote | rejected at enumeration with `sessions_rejected_path`, logged with control characters escaped. The newline because a line-based `sessions.txt` cannot represent it; the other three because the `xargs -I` fan-out corrupts them, and a quote aborts the whole dispatch (issue #54) |
| one path enumerated by two adapters | keep the first, log both, count `sessions_duplicate_path` |
| two distinct paths truncate to one hash | skip both, log both, count `sessions_hash_collision` |
| adapter directory basename is unsafe, disagrees with manifest `name`, or resolves outside the adapters root | refuse to load that adapter, count `adapters_rejected_identity` |
| L2 capture missing sentinel or marker | treated as truncated, retried per `AUTODREAM_L2_ATTEMPTS`, same as today |
| a pin line fails validation, or names a project this run never triaged | counted (`pins_invalid`, `pins_rejected_project`) and logged; the report is already on disk |
| a pin's project has no resolvable working directory | counted `pins_no_cwd`; nothing stored |
| `pins.jsonl` exists but cannot be read | counted `pins_unreadable`; nothing stored, the file stays |
| `shared-memory` is missing, exits nonzero, or returns no `memory_id` | counted (`pins_cli_missing`, `pins_failed`); no ledger row, so a rerun of that date retries it. The nightly run only processes yesterday, so nothing retries it automatically (#69); never blocks anything downstream |
| the store succeeds but the ledger append fails | counted `pins_unledgered` with the memory id logged; a rerun stores that pin again |
| the store reports `stored` with an empty `memory_id` | counted `pins_failed`; no ledger row |
| `pins-applied.tsv` exists but cannot be read | counted `pins_failed` before any store, since a duplicate cannot be ruled out |
| the store returns `mutation_committed_journal_incomplete` with a `memory_id` (the CLI exits 1) | the write is committed: counted `pins_applied`, ledgered, warning logged, so a rerun cannot store it again |
| `shared-memory context` exits nonzero, even with a bank in its output | counted `pins_failed`; no store |

Unchanged from today: SIGPIPE hardening on the log path, the L1 retry rounds with a network wait between them, the L2 retry loop, the idempotency guard, the stale-report move-aside that disarms consuming on failure, the trailing-week `unassembled_dates` sweep, and the vault-note and bookmark consume gates.

## Telemetry

New keys in `run-stats.txt`, following the existing rule that a degraded measurement must say so rather than read as zero:

- `adapters_enabled` — comma-separated list.
- `adapters_unavailable` — `<name>=<reason>` per adapter that could not run.
- `sessions_by_source` — `claude=21,omp=33`. A source that drops to zero on a day the user worked in it is the signal that ingest broke.
- `sessions_duplicate_path`, `sessions_rejected_path`, `sessions_hash_collision`.
- `adapters_rejected_identity`.
- `normalize_failed`, `project_failed`, `stats_failed`, `slim_failed`.

Pin counters live in `findings/<date>/pins-result.txt`, not `run-stats.txt`, because pins apply after L2 has already read the stats: `pins_total`, `pins_applied`, `pins_duplicate`, `pins_invalid`, `pins_rejected_project`, `pins_no_cwd`, `pins_failed`, `pins_unledgered`, `pins_cli_missing`, `pins_unreadable`, `pins_unsupported_harness`.
- `l2_input_bytes` — the total size of the findings the aggregator was handed.

`runner_commit` and `runner_dirty` stay, and matter more after the rename, since the live install still symlinks into the working tree.

### Signal dilution, measured before it is solved

The panel raised that a lopsided day — 200 Claude sessions to 3 OMP — lets the larger source bury the smaller in a single L2 pass, and that nothing bounds the union against the aggregator's context window. Both are real risks. Neither is a measured problem yet: the one observed dual-harness day was 21 to 33.

The response is the same shape as this repo's existing issue #12 gate, which blocks chunk-summarization pending evidence it is needed. `l2_input_bytes` and `sessions_by_source` are recorded from the first run, the prompt is told the per-source counts so it can say plainly when one source is thin, and a threshold on `l2_input_bytes` logs a warning rather than silently truncating. A per-harness pre-summarization phase is built when the telemetry shows it is needed, not before. Building it now would add a phase, a prompt, and a failure mode to serve a day that has not happened.

## Tests

**The existing 283 assertions do not all survive unchanged, and claiming they do would be false.** (Measured on `origin/main` at `e231314`: 283 passed, 0 failed. Two earlier figures in drafts of this document were both wrong: 297 is the count on the `feat/l1-only` branch of `STRML/cc-autodream#49`, and 279 is the count on `retire-compliance-markers`, which drops four compliance-marker assertions. Neither is `main`.) The stdout-only L2 and the removal of `Write`/`Edit` necessarily invalidate every fixture that asserts on a report-path instruction, on the L2 tool flags, or on a model-written report file — `tests/mock-claude.sh` writes the report today, and under the new protocol it must print it. The honest contract is: existing *behavioral* coverage stays green, and the fixtures encoding the old delivery mechanism are rewritten as part of migration step 4 rather than deleted. The suite's assertion count is expected to rise, not hold. Six additions beyond that rewrite:

1. **Fixture adapter.** `adapters/_fixture/` exercises the full contract with neither real harness installed, using a synthetic transcript format. This is what makes the claim "adding codex later is one directory" checkable rather than aspirational. It is excluded from the default adapter set.
2. **Encoding regression.** A project fixture whose path contains a dot, an underscore, and a symlinked prefix. The bug in `merge-reports.sh:162` becomes a permanent test rather than a fixed defect.
3. **Linearizer rejection fixtures.** Malformed JSON, a dangling `parentId`, and a `parentId` cycle, each asserting a nonzero exit with no output. A replay corpus cannot prove these paths, because it only contains whatever happened to occur.
4. **Pin validation fixtures.** Superseded 2026-09-15: pin validation is no longer keyed on an adapter `source`, since one shared Mnemopi store serves every harness. `tests/apply-pins.sh` and `tests/run-all.sh` carry the current fixture set (schema violations, a project absent from `pin-projects.tsv`, a missing `cwd`, a duplicate pin, shell-metacharacter payloads); see the failure matrix in `docs/plans/2026-09-15-mnemopi-pins.md`.

5. **Enumeration rejection fixtures.** A path containing a newline, two adapters claiming one path, and two paths forced onto one truncated hash — each asserting the named counter and that no findings record was written for the rejected session. The forced-collision case is constructed by stubbing the hash function, since a natural 48-bit collision cannot be produced in a test.
6. **Replay harness.** `tests/replay.sh` has two modes, because an archived findings dir and a live session store answer different questions and an earlier draft did not say which one it used.

   - `tests/replay.sh --artifacts <archived-findings-dir>` needs no session files. It re-derives what the runner can recompute from artifacts alone — the artifact hash for each line of the archived `sessions.txt`, the canonical project key for each findings record, sidecar parseability — and asserts the new code reaches the same answers the archived run did. This is the mode that proves the hash contract and the project encoding did not move, and it is the one that runs in CI, because archived dirs are small and self-contained.
   - `tests/replay.sh --ingest <session-root> <date>` needs live session files and runs the real enumerate, normalize, stats and gate path with `--no-l2`, asserting on source tags and skip counters. This is the mode that exercises the adapters, and it runs locally against the host's own stores rather than in CI.

   Neither mode tests operational reality. The panel was right that a replay harness will not catch an environment-specific execution failure of the `tee` SIGPIPE kind, which is the residual risk the single-cutover decision accepts.

Mocks: `tests/mock-claude.sh` stays; `tests/mock-omp.sh` comes across from `omp-autodream`. The suite continues to pin `AUTODREAM_CONFIG` into its sandbox so a developer's live vault is never written to, and continues to force `AUTODREAM_NETCHECK=0` and `AUTODREAM_RETRY_WAIT=0`.

Per this repo's own review rule, `/code-review` is a first pass and not the gate. A change of this size to `run.sh`, the adapters, and the prompts also goes through `/debate:run tight`, so at least one seat does not share Claude's blind spots.

## Migration

One branch, one cutover.

1. Add `preflight.sh`, `lib-project.sh`, and `adapters.sh`; build the claude adapter so that behavior is byte-identical to today. Convert the session list to NUL transport and add the source sidecar.
2. Write the OMP linearizer from scratch, with its rejection fixtures. Build the omp adapter around it, bringing `skills-inventory` and the dual-schema stats parsing across from `omp-autodream`.
3. Unify the two `SESSION_TRIAGE.md` files, which are four lines apart.
4. Rewrite `PROMPT.md` as a pure stdout prompt with every write instruction removed, and split the harness-specific remedy text into per-adapter `facts.md`.
5. Add the pin protocol with project validation against `pin-projects.tsv` and sequential application, via `bin/apply-pins.sh`, against the shared Mnemopi store. Revised 2026-09-15: no adapter-owned GC; see `docs/plans/2026-09-15-mnemopi-pins.md`.
6. Add the fixture adapter, the encoding regression, the pin validation fixtures, and the replay harness.
7. Run the replay harness against archived corpora from several real dates.
8. Rename the repo, update `install.sh` and the adapter install hooks, re-run it, verify the symlinks resolve.
9. Archive `omp-autodream` and `autodream-merge` with pointers.

`STRML/cc-autodream#49` and `STRML/omp-autodream#15` add `AUTODREAM_L1_ONLY=1` so that each install stops after L1 and a separate tool aggregates. Under this design that seam has no consumer, because one runner already covers both harnesses. Both should be closed with an explanation rather than merged. `STRML/cc-autodream#47` is already closed; its linearizer design and its dual-schema `session-stats.sh` are the direct source for the omp adapter and should be credited, though the linearizer itself must be rewritten here since it was never merged anywhere.

## Defects found during review, filed separately

Two problems surfaced that exist in shipped code and are not caused by this change:

1. **GC ignores secondary Claude roots (obsolete).** `bin/run.sh:294` scans every configured root; `bin/run.sh:1296` resolves projects only under `$PROJECTS_DIR`. Pins for sessions in a secondary profile were recorded and skipped. Filed as `STRML/cc-autodream#52`. Superseded 2026-09-15: pins now route by `cwd`, read from `pin-projects.tsv` for the project this run observed, not through per-root Claude memory GC, so this failure mode no longer applies. See `docs/plans/2026-09-15-mnemopi-pins.md`.
2. **`omp-autodream` reads OMP session trees raw.** `omp-autodream/bin/run.sh:623` sets `readpath="$session"` and no linearizer exists in that repo, so triage sees branches the user abandoned.

## Open questions carried forward

1. Does the `sessions-source.txt` sidecar want to be keyed by hash or by path? Hash keeps lines short and matches every other artifact, but makes the file unreadable by eye during debugging.
2. Should `adapters/_fixture/` ship in the released tree or be generated by the test harness? Shipping it makes the contract self-documenting and adds a directory a user may reasonably wonder about.
