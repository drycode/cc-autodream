# CLAUDE.md — cc-autodream

Operating notes for working on this repo. Read this before changing `bin/run.sh` or the prompts. The README is the user-facing pitch; this file is the stuff that bit us and the decisions behind the design, so future sessions don't re-derive them.

## What it is

A nightly two-layer pipeline that reads yesterday's Claude Code session transcripts and produces a ranked daily report plus a few pins to the shared Mnemopi memory store.

- **Layer 1** (`prompts/SESSION_TRIAGE.md`, `claude-haiku-5-5` at effort high, fanned out one per session): reads one transcript, writes one findings JSON.
- **Layer 2** (`prompts/PROMPT.md`, opus, single call): reads all findings JSONs, writes `dreams/YYYY-MM-DD.md`, optionally proposes pins to `pins.jsonl` for `run.sh` to apply.
- `bin/run.sh` orchestrates both layers and everything around them.

Legacy `MEMORY.md` memory is retired on this host: autodream no longer writes `MEMORY.md` pins and no longer runs `claude-memory gc`. See `docs/plans/2026-09-15-mnemopi-pins.md`.

## Session roots: one dir is not the corpus

The user runs several Claude config dirs at once (`~/.claude-nous`, `~/.claude-ds4`,
`~/.claude-sigint`, ...), each with its own `projects/` bucket. autodream used to scan
only `$HOME/.claude/projects`, so the nightly report silently stopped seeing the real
work — triage collapsed 132 → 7 → 8 → 1 sessions/night on 2026-08-03…06 purely because
the sessions had moved to the other buckets. The fix is multi-root scanning:

- `SESSION_ROOTS` (colon-separated) wins; else `PROJECTS_DIR` (single root, kept for
  compat); else autodetect every `$HOME/.claude*/projects` via `bin/root-probe.sh`,
  primary first. `run.sh` logs the resolved list every run.
- `WORK_BUCKET` stays keyed off the PRIMARY dir: lean workers run under the default
  config, so their AI-title stubs land in the default bucket — scanning extra roots
  does not change the isolation/wipe story.
- `root-choices.conf` remembers the per-folder index decision. install.sh runs
  root-probe with `--ask` on a TTY, `--default-index` otherwise, and writes the managed
  `SESSION_ROOTS` section to `config` (the awk in install.sh converges re-installs by
  dropping the old managed section first). The nightly run passes neither flag, so it
  never writes choices — unindexed roots are *reported* (`findings/<date>/unindexed-roots.txt`)
  instead, which is the "found a folder, ask the user" surface.
- Semantics: a folder is scanned iff it's `index` or the always-on primary. An *unasked*
  folder is held out of the report until the user decides — that's what the flag
  "found a folder we're not indexing" means, and scanning it would make the flag a lie.
  `--default-index` on install flips every unasked folder to `index` so a fresh install
  covers everything silently.
- Compatibility (verified 2026-08-07 against real files): claude-code-router wraps
  sessions in a `{"type":"queue-operation",...}` envelope before the normal records —
  `session-stats.sh`, `prune-self-sessions.sh`, and L1's prompt all key off
  `.type == "user"`, so the envelope is invisible to them. cc-ds4's transcripts are
  standard shapes under `projects/` (its `history.jsonl`/`spend-ledger.jsonl` live
  outside `projects/`, so the glob never trips on them). ccam keeps an accounts file,
  no transcript store. The `projects/`-bucket glob IS the compatibility layer.
- run-stats carries `session_roots` (count) + `session_roots_list` so a regression to
  single-root scanning is visible from the artifact.

## Where state lives

All under `$AUTODREAM_DIR` (default `~/.claude/autodream/`) except the reports:

- `findings/YYYY-MM-DD/*.json` — Layer 1 output, one per session (keyed by a 12-char sha1 of the session path). `*.json.err` is a worker's stderr on failure.
- `findings/YYYY-MM-DD/sessions.txt` (+ `.raw`) — the enumerated session list (`.raw` is pre-self-filter).
- `findings/YYYY-MM-DD/changelog-window.md` — upstream changelog diff for the date (see below).
- `findings/YYYY-MM-DD/run-stats.txt` — self-audit telemetry the aggregator reads.
- `findings/YYYY-MM-DD/.chunks/<hash>/` — chunked triage scratch for a session still pending: `in/` (chunk inputs, removed every round), `NN-<sha>-<cfg>.chunkout` (finished chunk answers, kept for the retry) and `NN.err`/`NN.out` (a failed chunk's evidence). Removed when the session has a findings JSON. `l1-chunks.txt` and `l1-chunk-calls.txt` are the per-run ledgers behind the chunk counters.
- `findings/YYYY-MM-DD/operator-notes.md` — every capture surface's notes merged into the one file L2 reads. `vault-notes-manifest.txt` alongside it lists the inbox files that went into it.
- `findings/YYYY-MM-DD/x-bookmarks.md` — unread X bookmarks for the "Ideas from bookmarks" section, plus `x-bookmarks-manifest.txt` of their ids. `x-bookmarks/seen.jsonl` holds the persistent read state.
- `findings/YYYY-MM-DD/pins.jsonl` — Layer 2's proposed pins, one JSON object per line (`project`, `title`, `body`, `kind`). A file left by an earlier run or attempt is moved to a unique `pins.jsonl.stale-XXXXXX` (mktemp) before each L2 attempt.
- `findings/YYYY-MM-DD/fanouts.tsv` — `worker-hash<TAB>parent-hash` for every ungated nested transcript (a claude subagent or workflow worker, an omp advisor or task child), written after L1 so L2 can read it. Nested means a sidecar with `isSidechain` or `nested` set; the parent is found by walking up from the transcript until `<dir>.jsonl` is a file, which holds at every depth both harnesses nest to. `run-stats.txt` carries the counts (`sessions_top_level`, `sessions_nested`, `fanout_parents`, `largest_fanout`), and `bin/overlap-stats.sh` drops the same sidecars, because a worker overlaps its parent and its siblings by construction.
- `findings/YYYY-MM-DD/pin-projects.tsv` — `project<TAB>cwd` rows for every project in this run's worklist (`sessions.txt`), computed before the first L1 call and written after a complete report. The rows are held in the runner's memory in between, because L1 and L2 both run with the Write tool and could rewrite the worklist files. Project and cwd both come from the real session path, never from a findings JSON, whose `session_path` the L1 model writes. The project is the directory directly under the longest session root that holds the session, at any nesting depth below it. A cwd the adapter cannot resolve (a removed worktree), a cwd that does not encode to its dash bucket (slug buckets like `STRML-cc-autodream` skip that check), or a bucket with more than one distinct cwd, gets an empty column; `bin/apply-pins.sh` reads it to authorize and resolve each pin.
- `findings/YYYY-MM-DD/pins-applied.tsv` — the ledger of applied pins, `<sha1 of the resolved bank and the canonical pin><TAB><memory_id>`, so a rerun does not write the same pin twice. `run.sh` holds the ledger in memory before any model runs and puts it back before the pins are applied, because a worker with the Write tool could empty it.
- `findings/YYYY-MM-DD/pins-result.txt` — pin application counters (`pins_total`, `pins_applied`, `pins_invalid`, and so on).
- `findings/YYYY-MM-DD/unindexed-roots.txt` — Claude folders (`~/.claude*/projects`) that exist but are not indexed, for the self-audit section. Written before the idempotency guard so a catch-up no-op still reports folders that appeared since setup.
- `findings/YYYY-MM-DD/triage-candidates.{md,tsv}` — touched GitHub repos whose untriaged open issues cleared `AUTODREAM_TRIAGE_MIN`, written by `bin/triage-candidates.sh` from the runner's own session rows (never a findings JSON). L2 only copies the `.md` into "Repos to triage"; the counting and the cooldown (`triage-suggested.tsv`) are the script's, and `tests/triage-candidates.sh` pins each row of its failure matrix. The `.tsv` has one row per repo with status `candidate`, `below`, `cooldown` or `skipped` and the reason.
- `findings/YYYY-MM-DD/worktree-prune.{md,tsv}` — what `bin/prune-worktrees.sh` removed, kept and skipped that night, one TSV row per worktree (`action<TAB>repo<TAB>branch<TAB>path<TAB>reason`). The step is opt-in through `AUTODREAM_PRUNE_ROOTS`; the proof rules and keep rules are in the script header and the README, and `tests/prune-worktrees.sh` pins each one. It deletes remote branches, so a new rule there needs a test that pins a KEEP before it needs one that pins a removal.
- `root-choices.conf` — the per-folder index decision (`~/.claude-ds4/projects=index`), written by `bin/root-probe.sh` at install time. The primary `~/.claude/projects` is always indexed.
- `cache/claude-code/` — persistent clone of `anthropics/claude-code` for the changelog.
- `logs/run-YYYY-MM-DD.log` — full run log (run.sh tees here). `logs/launchd.{out,err}.log` — launchd's capture.
- `dreams/YYYY-MM-DD.md` (default `~/.claude/dreams/`) — the final report.

Scripts/prompts are symlinked into `~/.claude/autodream/` by `install.sh`, so editing the repo copy takes effect immediately. The installed launchd job is `com.samuelreed.autodream` (not the `com.user.*` example label).

`install.sh` also installs that scheduled job by default (unless `--no-schedule`): it generates the plist with auto-detected PATH/dirs and the label `bin/scheduler-label.sh` returns (see below), then `bootout`+`bootstrap`s it. `RunAtLoad` is false, so install *arms* the schedule without firing a run; the four morning triggers (03:15/06:15/09:15/12:15) match the example plist. It does not run `pmset` (sudo) — it only prints the `pmset repeat wake` recommendation. The `launchd/*.example` file is kept as a hand-editable fallback.

### The label is owned by a runner, not by a name (omp-autodream#14, issue #60)

`bin/scheduler-label.sh` decides which launchd label an install owns, and `install.sh` and `bin/autodream-now.sh` both call it. They used to answer separately and wrong: any `*autodream*.plist` whose body mentioned `run.sh` was treated as ours, so installing a second autodream on a host with a first one adopted the first one's label and rewrote that job. Nothing failed loudly. The overwritten job's triage sat dead for 18 days, and https://github.com/STRML/cc-autodream/issues/66 is the same blackout seen from this side.

- **Ownership is the runner.** A plist is ours only when its `ProgramArguments` invoke a `run.sh` under this install's directory, compared with `pwd -P` so a trailing slash or a symlinked parent cannot cause a miss. A miss would be silent: a fresh label on every re-install.
- **Our own label wins**, even when it is not the default, so a renamed job keeps its name. Every plist in the LaunchAgents dir is read, not an `*autodream*.plist` glob: launchd keys a job by its Label, so a filename glob missed both our job renamed to `nightly.plist` and a foreign job holding the default label in `backup.plist`.
- **A conflict on the default name is refused.** `scheduler-label.sh` exits 3 and `install.sh` skips scheduling but still installs the symlinks. Any other nonzero from `install_schedule` (a plist failing `plutil -lint`, a bootstrap that did not take) fails the install.
- **The on-demand label carries a hash of the install dir** (`<label>.ondemand.<8 hex>`), because the `bootout` before each on-demand run evicts whatever holds the label and another install's on-demand plist lives in its own `AUTODREAM_DIR`, where no scan sees it.
- **The shipped template must be adoptable by this check.** It used `bash -lc "$HOME/.../run.sh"`, which runs but whose literal string never matches an install dir, so a job installed from the template got a second one beside it on the next `./install.sh`.

The default label is `com.<user>.autodream`; the review LaunchAgent takes `<label>-review` (see "The review triage LaunchAgent" below).

## How claude is invoked — the lean-query pattern (do not use `--bare`)

Both layers call `claude --print` with a composed set of minimal-footprint flags borrowed from claude-cells `internal/claude/query.go`. The point: strip per-call bloat (hooks, skills, MCP, CLAUDE.md auto-load) while KEEPING subscription/OAuth auth.

```
--no-session-persistence            # see self-pollution below
--tools Read Write                  # L1; L2 uses: Glob Read Write Edit
--disable-slash-commands            # no skills
--strict-mcp-config                 # no MCP servers
--settings '{"disableAllHooks":true}'   # no hooks (incl. the big SessionStart injection)
```
plus env `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1`, and `--permission-mode bypassPermissions` so workers can write.

**Do NOT switch to `--bare` or `CLAUDE_CODE_SIMPLE=1`.** Verified (2026-05) with a control on this host: plain `claude --print` authenticates, but both `--bare` and `CLAUDE_CODE_SIMPLE=1` return "Not logged in". They disable OAuth/keychain auth and require `ANTHROPIC_API_KEY` (or an apiKeyHelper), and `--bare`'s toolset is only Bash+Edit (no Read/Write/Glob). The composed flags above give the same minimal footprint without breaking auth or the file tools. (claude-cells uses simple mode only inside containers, where creds are a mounted `.credentials.json` file, not the macOS keychain.)

### Who starts the L1 worker (decision 2 of the consolidation)

`dispatch_l1` no longer names an engine. For each session it takes the adapter from the source map, the adapter's argv from `adapter.sh l1-argv <model>`, and its environment from `l1-env`, and runs `env <env> <argv>` with the prompt on stdin. The claude adapter's argv is the invocation listed above, byte for byte (`tests/adapter-claude.sh` pins it against the old literal text).

- **The source map is held in the environment, not read from the findings dir.** `AUTODREAM_SOURCE_MAP` (hash and adapter per session) and `AUTODREAM_L1_MODELS` (model per adapter) are built before the first model call. An L1 worker holds the Write tool and could rewrite `sessions-source.txt`, and the source decides which binary the next worker executes. `test_l1_engine_cannot_be_redirected_by_a_worker` has a worker do exactly that and checks the next session still runs on the real engine; reading the file instead fails it.
- **Haiku 5.5, effort and a replaced system prompt (2026-10-07).** The claude manifest's `l1_model` is `claude-haiku-5-5` (verified: `--model claude-haiku-5-5` and the `haiku` alias both answer as it; an id the CLI does not know falls back silently, so re-check `modelUsage` in `--output-format json` when changing it). `l1-argv` and `warmup-argv` add `--effort` from `AUTODREAM_L1_EFFORT_CLAUDE`, then `AUTODREAM_L1_EFFORT`, then `high`; `off` omits it and an unknown level exits 2. They also pass `--system-prompt` instead of `--append-system-prompt`, which drops Claude Code's default prompt: one-word call 6.9k -> 5.0k input tokens, and a real triage run on a 250 KB slice cost $0.159 against $0.215 with the same number of findings. L2 is untouched.
- **The model** resolves `AUTODREAM_L1_MODEL_<ADAPTER>`, then `AUTODREAM_L1_MODEL`, then the manifest's `l1_model` (`adapter_l1_model`). A model id belongs to one engine, which is why a host with two engines pins them per adapter.
- **No engine is a deterministic error.** A session whose adapter is not executable, or resolves no model, gets a findings record with `error: no L1 engine for this session`, left in place and counted by `l1_findings_with_error`. Retrying cannot change the answer, and the run still reports.

## Self-pollution (the eating-its-own-tail bug)

Every `claude --print` call used to persist its own session JSONL into `~/.claude/projects/-Users-<you>/`. So a run that triaged ~190 sessions left ~190 worker transcripts, and the NEXT night's run enumerated those as "sessions" to triage. On a real day, ~90% of the corpus was autodream looking at itself (215 enumerated vs. 21 real on 2026-05-29).

Three defenses, all in place:
1. **Root cause**: `--no-session-persistence` on every call. New runs leave no transcript.
2. **Enumeration filter**: after `find`, the session list is piped through `bin/prune-self-sessions.sh --filter`, which drops any session whose first user turn is one of autodream's own inlined prompts (markers: `Session transcript to analyze (literal absolute path)`, `Findings directory to aggregate (literal absolute path)`, legacy `SESSION_PATH=` / `FINDINGS_DIR=`). This catches transcripts left by runs predating the fix.
3. **Backlog cleanup**: `bin/prune-self-sessions.sh` (dry-run lists, `--delete` removes). `prune-self-sessions.sh` is the single source of truth for the "is this ours?" predicate; run.sh resolves it relative to itself (`BASH_SOURCE`).

The predicate is anchored to the FIRST user message so a human session that merely *discusses* autodream is not a false positive.

### The AI-title stub vector (second-order self-pollution)

`--no-session-persistence` suppresses the full transcript but NOT Claude Code's **AI-title generation**: a fire-and-forget background call that writes a one-line `{"type":"ai-title",...}` stub into the launch cwd's project bucket. Because workers ran from `cd "$HOME"`, those stubs landed in the real `-Users-<you>` bucket and polluted session history / `search-sessions` — 339 of them accumulated 2026-05-25…06-02 (titles like "Analyze Claude session findings", "Aggregate daily findings into report"). Whether a stub lands is version/timing-dependent (the `--print` process sometimes exits before the async write flushes — current builds often drop it, older ones flushed it), so the fix must not assume the binary's current behavior.

Two defenses:
1. **cwd isolation + wipe (run.sh)**: both layers now launch from `$AUTODREAM_DIR/work` (`WORK_DIR`), not `$HOME`. Claude maps cwd → `~/.claude/projects/<cwd with / and . → ->`, so any stub lands in the isolated `WORK_BUCKET` instead of the real bucket. `clean_work_bucket` (`rm -rf "$WORK_BUCKET"`) runs before L1 and after L2, so stubs never accumulate. Workers read/write only by absolute path, so cwd is functionally irrelevant — L1 cd's inside the worker subshell; L2 cd's inside a subshell so the change does not leak into the notify/pin steps. **Watch the apostrophes**: the L1 worker body is a single-quoted `bash -c '...'`, so a `'` in a comment there silently breaks quoting (it still passes `bash -n`).
2. **Pruner title predicate (`is_self_title`)**: catches orphan stubs in the real bucket left by runs predating defense 1. Gated on (a) NO user turn anywhere in the file — a real session keeps its title alongside its conversation turns, so it is never a title-only orphan and is never matched — AND (b) the title paraphrases our L1/L2 prompts (session triage → findings, aggregate findings → report). Tuned against the real backlog: spares terminal-tab-title stubs and unrelated headless orphans (e.g. "GCU Rush firmware development").

## Sleep resilience

The overnight failure mode: launchd fires at the scheduled time on a brief wake, the Mac sleeps in and out during the run, workers lose the network and fail (we saw 104/215 fail, L2 exit 1, no report).

launchd facts: `StartCalendarInterval` is anacron-like (runs once on the next wake if asleep at the trigger), NOT vanilla cron. But launchd does not WAKE the Mac (use `pmset repeat wake` for that), and it does nothing about sleep DURING a run.

run.sh handles it with:
- **L1 retry loop** (`dispatch_l1` + `l1_missing_count`): re-dispatches only the sessions still missing a findings JSON, up to `AUTODREAM_L1_ROUNDS` (5), calling `wait_for_network` between rounds. The worker is idempotent, so retries are cheap.
- **L2 retry loop**: retries the aggregator up to `AUTODREAM_L2_ATTEMPTS` (3) until `$REPORT_PATH` is non-empty.
- **Idempotency guard**: at the top of `run()`, if a finished report exists for the date it exits in a second (`AUTODREAM_FORCE=1` to rebuild). Finished means the open-questions marker is present (or the date predates `AUTODREAM_MARKER_EPOCH`); a marker-less report is moved aside and rebuilt (#111). This is what makes multiple launchd catch-up triggers safe.
- **Per-date run lock** (#55): `run()` takes `$AUTODREAM_DIR/locks/run-<date>.lock` (a `mkdir`, with the owner's pid and start time inside) before touching the findings dir, because launchd serialises a label only against itself and `autodream-now.sh` uses another. A live holder makes the second run log and exit 0; a dead holder (a killed run, the normal failure here) or a reused pid is reclaimed.
- The plist example schedules several morning triggers (03:15/06:15/09:15/12:15) so a failed-overnight date gets retried on later wakes; the guard no-ops the rest.

`net_up` checks reachability of `api.anthropic.com` (any HTTP code beats `000`). Disable the wait with `AUTODREAM_NETCHECK=0` (tests set this).

### The logger could kill the run, and did (2026-08-02)

Every recovery path above assumes it gets to run. `run 2>&1 | tee -a "$RUN_LOG"` quietly revoked that assumption for all of them at once: it made each log line a write to a pipe, so whatever killed `tee` killed the run by SIGPIPE on the next `log` call. Three runs died there on 2026-08-02 — two scheduled, one detached, so launchd was not the cause — and 2026-08-01 ended with no report at all. The signature is a run log that stops mid-sentence at `L2 aggregation attempt 1/3...` and a `Terminated: 15` on tee beside a `Broken pipe: 13` on run in the launchd stderr. Nothing else says anything, because the thing that would have said it is what died.

The fix is that an unattended run writes to the file directly (a file has no reader to lose) and `trap '' PIPE` covers the interactive path, where `tee` is still worth having. A closed terminal now costs the run its output rather than its life. `test_dead_stdout_does_not_kill_the_run` pins it by piping a real run into a reader that closes immediately.

What still has no root cause is who SIGTERMs `tee`. It was not `claude --print` signalling its process group (tested directly: a sibling `sleep` survives a worker call), it was not sleep (`pmset -g log` shows the Mac awake), and it was not launchd (the detached run died the same way). The run no longer cares, which is the point, but the signal source is worth naming if it ever shows up somewhere that does.

## Upstream changelog window

`changelog_window()` runs `git log -p` on a changelog over `[TARGET_DATE, NEXT_DATE)` (real commit dates; the raw CHANGELOG has no dates, the git history does). The inserted lines go to `changelog-window.md`, which L2 reads for the "Upstream harness changes" report section. Any git failure writes a note and never aborts the run. There is no remote `git blame`; that is why we keep a persistent local clone.

Since 2026-09-11 it watches **three** harnesses rather than one, because the user works across all three: Claude Code, Codex, and OMP. `changelog_sources()` holds the list as `name|remote|path|cache-dir` records. Four things in that design are load-bearing:

- **The path is per-source.** OMP is a monorepo with no root CHANGELOG — the CLI's log is at `packages/coding-agent/CHANGELOG.md`. A hardcoded `CHANGELOG.md` silently yields an empty section for it.
- **Failures are per-source.** Each harness gets its own cache, its own clone/pull, and its own `## <Harness>` section in the one output file. A dead remote writes an explicit failure line into its own section; it never blanks the others, and it never produces an empty file that reads like a quiet night upstream.
- **`CHANGELOG_REMOTE` selects a single source and suppresses the defaults.** Back-compat for the old one-repo knob, and the reason the test suite stays offline: the changelog test points that variable at a local fixture, and a default list that still ran would have the suite cloning three real remotes. `AUTODREAM_CHANGELOG_SOURCES` overrides the whole set.
- **Sections are appended to a named file, never emitted on stdout.** `log()` writes to stdout, so an earlier draft that built the file inside a `{ … } > "$out"` block filed every "cloning …" progress line as an upstream release note. Caught in a live run against all three remotes; `test_changelog_multi_source` pins it.

Output is deduped and capped. A changelog edited across many commits in one window re-inserts the same lines repeatedly — OMP moved 119 commits over 2026-09-08..10 and emitted `## [18.1.16]` three times, each with its bullets. Non-blank lines are deduped order-preserving (blanks exempt, or the markdown collapses into one paragraph) and each section is capped at `AUTODREAM_CHANGELOG_MAX_LINES` (400) with an explicit truncation note, so one chatty monorepo cannot crowd the other harnesses out of L2's context.

## Which day a session belongs to (the report-day window, #113)

A session is placed in a report day by the timestamps INSIDE its transcript, not by its file mtime. Enumeration was `find -newermt DAY ! -newermt NEXT`, so a session written to again after its day closed (a resumed session, or OMP rewriting its title line) dropped out of every later rebuild of that day. On 2026-09-01 a rebuild of 2026-08-21 kept the two advisor sidecars and lost the two parents they described, then reported `l1_missing_after_retries: 0` over the short corpus. Two decisions carry it:

- **The adapter contract did not change.** `enumerate` still takes `(root, from, to)` and still filters on mtime. `run.sh` passes it a far `to` (the report day plus five years, as `ENUM_END`), so the mtime test becomes a lower bound: a file last written before the day began cannot hold a record from it. `bin/session-window.sh in-window` then keeps a file when at least one record has a top-level `.timestamp` string inside `[local midnight, next local midnight)`. The bounds come from BSD `date`, so a DST day is 23 or 25 hours. The five-year date is not a year-9999 sentinel because BSD `find` on some macOS releases fails with "Can't parse date/time" on a distant date; `run.sh` also probes the date with the same `find` before using it.
- **Both harnesses write the same field, and it is the only one read.** Measured on this host's OMP store (1,348 sessions): every record except the `title` slot carries a top-level `timestamp` in the form `2026-10-01T16:12:38.483Z`. `message.timestamp` on an OMP message is an epoch-millisecond NUMBER on a record that already has the string, and is deliberately ignored. A record whose timestamp is missing, null, numeric or in another shape has no clock: it neither selects a file nor lands in a slice.

What the verdict is, per file: records with clocks and one inside the day -> in. Records with clocks and none inside -> out, counted in `sessions_out_of_window` (this includes a file touched inside the day whose records are all older, which an mtime-only run triaged under the wrong day). No clock at all -> placed by mtime exactly as the bounded find placed it, so a no-clock file touched after its day still drops out of that day's rebuild; there is nothing else to place it by. A helper failure (exit 2) keeps the session: extra work, never a dropped session.

**The slice.** The stats and the L1 worker read the day's records of a transcript that spills outside the day. `session-window.sh day-file` writes the slice only when some timestamped record lies outside the day (so a single-day transcript is read byte for byte as before), carries the original's mtime (so `transcript_mtime` in the sidecar still describes the session), and treats an empty slice as an error, so the caller reads the whole transcript rather than nothing. The order is the part that bites: **normalize first, cut second.** OMP sessions are linearized to the live chain and the chain is cut. Cutting the raw tree leaves entries whose parent was cut away, and `linearize.sh` fails closed on a dangling `parentId`, which would refuse every OMP session that spans a day boundary. The slice keeps the `autodream_meta` header (it has no clock, and `stats.sh` and `project` read it) and writes the first kept entry with `parentId` null, so the slice is a closed chain. An OMP session whose only entries inside the day are on an abandoned branch has a meta-only slice, no user turns, and is noise-gated, not read whole. `compute_session_stats` and the worker both do it, in that order, and both clean up `<hash>.statsday.jsonl` / `<hash>.day.jsonl`. A worker handed a slice is told so (a `## Report day` paragraph in its prompt).

What the cut changes in the numbers: `duration_minutes`, user-turn and tool counts, the noise gate, the overlap pass and the oversized gate now describe the day. `transcript_bytes` is the size of the file the worker reads, so for a multi-day session it is the slice's. `oversized-gate.sh`'s fallback still `wc -c`'s the whole transcript when a sidecar is missing.

**Both halves of #113.** (a) The session is back in the corpus. (b) Because it is back in `sessions.txt`, the existing retry loop dispatches it (no findings JSON), `l1_missing_count` counts it, and a successful worker deletes its stale `.err`. That is the case the issue observed, and `test_rebuild_keeps_a_session_touched_after_its_day_and_retries_its_stale_err` reproduces it (no report, a pre-seeded `.err`, a session touched three days later) and fails on `origin/main` on exactly those assertions. What re-enumeration cannot fix is an `.err` whose session is no longer in the worklist at all (the file was deleted, or `AUTODREAM_WINDOW=0`). That one is counted as `l1_err_files_orphaned` and named in the log, not retried: the `.err` is the only record of which session it was, and a worker with the Write tool could have put any path in it. `l1_err_files` still counts every `.err` in the directory. The same scan runs on a night with nothing to triage (the early stub exit), so a stale failure is not reported as zero there either.

**Findings left by an earlier run (#56).** A rebuild of a date first run on file mtime keeps whatever findings JSONs that run wrote, including those for a session the window no longer places in the day, and L2 reads every findings JSON in the directory. Before L1, `reconcile_findings_with_worklist` moves each JSON outside this run's worklist into `findings/<date>/outside-worklist/` (counted as `l1_findings_outside_worklist`, named in the log) so L2's glob cannot reach it. Moved, not deleted; it is restored when its session is back in a later worklist. A clean rebuild still means removing the date's findings directory first if the stale files should go for good, as "Running / rerunning a date" says.

`AUTODREAM_WINDOW=0` restores mtime-only placement. The window is also off, and run-stats say `session_window: off`, when `session-window.sh` cannot be found (found through `find_lib`, so the checkout counts before `install.sh` re-links), the day will not convert to epoch bounds, or this `find` rejects the far date. The five-year reach is a limit, not an accident: a session last written more than five years after a report day is not found by a rebuild of that day.

Things that cost time here: the L1 worker is a single-quoted `bash -c` and the new code in it must have no apostrophes; the L1 fan-out used to hit `xargs -I {}`'s 255-byte argument limit (a long `TMPDIR` plus a nested OMP child path); it is NUL-delimited with `xargs -0 -n 1` now (#54), so that limit is gone; fixtures with timestamps must put them inside `DATE`, because a record outside the day now outranks the mtime that `touch -t` gave the file; and under the Claude Code sandbox `git init` fails on `.git/hooks` inside the worktree, after which the changelog tests run their `git` calls against the ENCLOSING repo (one run rewrote the branch under test), so point `TMPDIR` for `tests/run-all.sh` outside any checkout.

## Reading a long session: chunked triage

Layer 1 used to read an oversized transcript through `slim-transcript.sh`: the first 400 and last 200 lines of the raw stream, cut to 400 characters. Measured 2026-10-02 on a real 3,479-line session, only 36% of the lines were conversation (24% hook and reminder attachments, 21% `mode`, `permission-mode`, `last-prompt` and `bridge-session` records), the head and tail were mostly that noise, and the timestamp sat after the message so the line cut deleted it: the worker saw 17% of the lines and about 2% of the text, and returned nothing. Issue #12 stayed closed behind a failure-rate gate because the failure rate was never the problem; the yield was. A controlled test on one session had Haiku find nothing on the old slim and on the full conversation, and Opus find a real permission-gate issue only on the full conversation, so there are two causes (what the worker is shown, and what Haiku makes of it) and this change fixes the first. On this host's 2026-10-02 (70 oversized sessions after the day cut) the old view showed 1,330 of the 6,099 conversation lines and the new one shows all of them in 1.9 MB instead of 2.9 MB.

- **One gate, off is the old behaviour.** `AUTODREAM_L1_CHUNK_BYTES` (default 0, which is off; 300000 is the value it was replayed with) and `AUTODREAM_L1_MAX_CHUNKS` (default 8) are validated at startup like the timeout knobs (`10#`, so `08` is not an invalid octal). `L1_CHUNKING` is 1 only when the knob is above 0 and BOTH `chunk-transcript.sh` and `merge-chunks.sh` are found with `find_lib`; a missing helper reads the old way and logs a WARNING. With it 0 the slimmer is called with `AUTODREAM_SLIM_RESHAPE=0 AUTODREAM_SLIM_FULL=0` (its defaults), no chunker, no merge, no chunk note, no ledger files: on a fixture run against the previous runner, every transcript a worker read, every prompt and every findings JSON was byte-identical, and so were the 70 findings of a replay of 2026-10-02.
- **The slimmer.** `RESHAPE=1` drops bookkeeping by a DENYLIST (record types `bridge-session last-prompt permission-mode mode atis-latch ai-title queue-operation file-history-snapshot file-history-delta dev-mods`, attachment subtypes that are hook and reminder machinery, `system/stop_hook_summary` and `system/turn_duration`) and rebuilds `user`, `assistant`, `attachment` and `system` records with `type` and `timestamp` first and the message reduced to `role` and `content`. It is a denylist of attachment subtypes too, because an unknown subtype costs bytes when kept and costs signal when dropped, and an allowlist of user and assistant would delete every OMP record. Before dropping a record type, grep the prompts for it: `skill_listing` and `queued_command` are named by SESSION_TRIAGE.md and the first draft's denylist caught one of them. OMP and unknown-schema records come out of the reshape exactly as without it (the pre-pass has always re-serialised every record and stripped OMP toolResult payloads, so they are not raw-identical to the file, and the test says so). `FULL=1` keeps every surviving line: no head/tail, no cap, no footer, because the footer would land in the last chunk as a line that is not JSON. Lines are still cut to `AUTODREAM_SLIM_MAXLINE`, so "each chunk parses as JSONL" holds for the chunker's own contract (it splits only at line boundaries) and not for a slimmed input, whose long lines are cut.
- **The chunker** counts bytes (`LC_ALL=C awk`), cuts only at line boundaries, makes a line longer than the limit a chunk of its own, and keeps the first ceil(MAX/2) and last floor(MAX/2) chunks when there are more than MAX: the start holds the goal and the end holds the outcome. A cap of 1 keeps the first chunk only. It prints `COUNT ELIDED` and leaves no file behind on a failure. A tool call and its result are separate lines, so a cut puts one at the end of a chunk and the other at the start of the next; the chunk note tells the worker to expect that.
- **The worker.** The input over the limit is split into `findings/<date>/.chunks/<hash>/in/chunk-NN.jsonl`, one engine call per chunk IN SEQUENCE in the same xargs slot, each answering to `.chunks/<hash>/NN-<sha of the chunk>-<cfg>.chunkout`. The name carries the chunk's hash and an 8-character digest of everything else the answer depended on (SESSION_TRIAGE.md, the harness addendum, the engine and model, and the session's stats sidecar, which the merge copies from chunk 1), so a retry reuses an answer only for an identical chunk read under identical instructions: a changed prompt, model or session redoes the chunk instead of merging a stale answer with fresh ones. The `.chunkout` suffix and the hidden directory keep every consumer that globs `*.json` away from them (`findings_json_count` and the gated count scan the findings dir with `-maxdepth 1`, which never reaches `.chunks/`; the suffix is the second guard, for any consumer that walks deeper). The chunk note goes before the stats block, because SESSION_TRIAGE.md says the stats come last, and says the stats describe the whole session. The merged findings carry `meta: {chunks, chunks_elided}` and each finding a `chunk` tag.
- **A chunk answer is untrusted.** `merge-chunks.sh --check` is the single definition (one JSON value, an object, no `error` key, a `findings` array) used on the way out of every call, before a cached answer is reused, and again inside the merge, which refuses (exit 3, nothing on stdout) when any chunk fails it. Plain `jq -e .findings` judges only the LAST value in a file and is truthy for a string, which is how an error object followed by a good one, or `{"findings":"oops"}`, used to count. A session is merged only when every chunk passed; otherwise nothing is published for it that round, the failed chunk is redone alone next round, and on the last round the session gets the ordinary stub, now carrying `meta.chunks`, never a merge of the chunks that did answer.
- **A chunk failure is a worker failure.** `l1_attempt` writes the same evidence to a per-chunk `NN.err` and the first failing chunk's is copied to `<hash>.json.err`, so a later chunk that succeeds cannot erase it. The chunk is named inside the existing `worker produced no findings JSON for ...` line, which `failure-class.sh` skips by prefix; any NEW line in the `.err` would be read as worker output (before the exit-code line) or as worker stdout (after it, until a known marker), so none was added. A no-route or permanent provider refusal ends that session's chunk loop, since the other chunks would fail the same way and each burns a call, and defers the date as for any worker. The circuit breaker counts a new chunk answer as progress, because a round that finishes most chunks and no whole session is not barren and would otherwise trip it after two rounds. `l1_timed_out` counts sessions (the ledger is `sort -u` by hash), so several chunk timeouts are one.
- **If the chunker fails**, the worker falls back to the exact off path (the default-mode slim of the same input), never to the uncapped full slim; if that cannot be made either it reads nothing this round and the last round writes the stub.
- **Cleanup without a trap.** There is no per-run temp directory and no signal trap in the worker, and a trapped TERM is deferred until the foreground engine exits (the adapter says so), so chunk inputs, which are transcript text, are mode 0600 and rebuilt every dispatch, removed by the worker when it can and by the dispatcher after every round whatever happened. Answers stay until the session has a findings JSON, a stub included.
- **What it costs.** A session that completes costs up to MAX_CHUNKS calls (8) plus one per retry of a failed chunk, and the absolute ceiling is MAX_CHUNKS x `AUTODREAM_L1_ROUNDS` (40) if every call fails, which the circuit breaker cuts to about three rounds. A night costs up to (oversized sessions x 8) + (the rest x 1): measured 73 calls for 70 oversized sessions on one real day, 560 at the cap. A session's wall time is up to 8 x `AUTODREAM_L1_TIMEOUT` since its chunks run in sequence. `run-stats.txt` has `l1_chunk_bytes`, `l1_max_chunks`, `l1_chunked_sessions`, `l1_chunks` (the workers the sessions needed), `l1_chunk_calls` (calls actually made) and `l1_chunks_elided` (chunks the cap dropped: a nonzero value is a degraded read).
- **omp** chunks the linearized copy after the day cut, in that order: `normalize`, then `day-file`, then slim, then chunk. The first chunk opens with the `autodream_meta` header.

Tests: `tests/chunk-transcript.sh` and `tests/merge-chunks.sh` are unit suites; the slimmer's modes are in `tests/slim-transcript.sh`; the integration cases are the `test_chunk*` functions in `tests/run-all.sh` with the mock's `MOCK_MODE=chunked`, `MOCK_FAIL_CHUNK`/`MOCK_FAIL_KIND`/`MOCK_FAIL_ONCE` and `MOCK_BAD_CHUNK`/`MOCK_BAD_KIND`. Run them with `TMPDIR` OUTSIDE every checkout and SHORT: the changelog tests run `git` against whatever repo contains `TMPDIR` when `git init` is denied, and `xargs -I {}` refuses an argument of 255 bytes or more.

## Operator notes: one file for the prompt, many surfaces for the human

`PROMPT.md` reads exactly one notes path, `findings/<date>/operator-notes.md`, and `bin/vault-notes.sh` writes it by merging every capture surface. Adding a surface is a change to that script and never to the prompt. Today there are two:

- `~/.claude/autodream/notes.md`, appended by `autodream-note.sh`. Terminal-only, unchanged, still the right thing for an agent leaving itself a note mid-session.
- `$AUTODREAM_VAULT_DIR/inbox/*.md`, one file per note. This is the surface that gets used away from the keyboard — Obsidian mobile, Shortcuts, a share sheet, anything that writes a file into a synced folder. Optional YAML frontmatter `expires: YYYY-MM-DD`; expired notes are dropped at collect time so the prompt keeps exactly one expiry format to parse (the `- [added] (expires DATE)` lines).

Consumed inbox files move to `processed/<date>/` and the report is copied to `reports/<date>.md` for phone reading. Both steps are gated on a **non-empty** report, deliberately stricter than the `-f` check that encloses them: archiving a note the aggregator never read destroys the only copy, silently and unrecoverably. The manifest exists for the same reason — `collect` records which files it read and `archive` moves only those, so a note written during the ten minutes a run takes is not swallowed unread.

The vault lives in iCloud, which evicts file contents under storage pressure and leaves a `.<name>.icloud` placeholder. 03:15 is exactly when nothing has touched the vault for hours, so `materialize()` calls `brctl download` and waits for the placeholders to clear (`AUTODREAM_ICLOUD_WAIT`, default 30s). A note still dataless after the wait is written into `operator-notes.md` as `UNREADABLE` and left in the inbox rather than skipped — a note the user wrote and we could not read is worth saying out loud.

### run.sh sources the config now

It didn't until this feature; only `review.sh` did, which was fine while every key was review-only and stopped being fine the moment `AUTODREAM_VAULT_DIR` had to reach the nightly run. Two details in that block are load-bearing and both were caught by tests rather than by reading:

- **`set -a` around the source.** The helper scripts are separate processes, so a config key that stays an unexported shell variable reaches nothing. Without it the config parses fine and the feature silently does not happen.
- **The `export -p` snapshot replayed after.** The config uses plain `KEY=value`, so a bare `.` lets the file clobber a variable the caller deliberately exported. Tests set env; a run invoked with an explicit `AUTODREAM_VAULT_DIR=` to disable the vault has to actually disable it.

`AUTODREAM_DIR` is resolved before the source and therefore cannot be set from the config. That is not an oversight — it names the file's own location.

### What the consume gate actually has to check (PR #37 review)

"Only consume after a real report" turned out to need three conditions, not one. A review found the first version satisfied by things that are not a real report at all:

- **`-s "$REPORT_PATH"` is not proof this run wrote it.** Under `AUTODREAM_FORCE=1` the idempotency guard is bypassed while the *previous* run's report is still on disk, and nothing ever truncates that path. A sleep-killed L2 then left the old file standing, which both broke the retry loop out after one attempt and let the consume step archive an unread note. The fix is to move an existing report aside *before* the L2 loop, so the path being non-empty means what the code always assumed it meant. The copy is kept and logged on failure, discarded on success so `--force` doesn't litter `.stale-<epoch>` files forever.
- **The date matters.** Both collectors are date-agnostic — they read the *current* inbox and the *currently* unread bookmarks regardless of which date's findings dir they write into. Reprocessing an old date therefore consumed today's pending input. Consuming is now gated on `TARGET_DATE` matching the date a normal nightly run would process. `AUTODREAM_CONSUME_DATE` overrides that authoritatively, because the suite pins a fixed historical date and without the override every archive assertion would pass while testing nothing.
- **Publishing is not consuming.** Copying the report into the vault stays outside the date gate; only `archive` and `mark-read` destroy the user's only copy.
- **A failed move-aside must disarm consuming, not warn.** The first version logged a warning and carried on when the `mv` failed, which puts you back in exactly the state the move exists to prevent: a stale report at `$REPORT_PATH` that a failed L2 lets both the retry loop and the consume gate mistake for fresh output. `CONSUME_SAFE=0` turns the whole consume phase off for that run. A guard whose failure path continues is not a guard.

The copies those moves leave behind are retired by one block that sits *outside* the `-f "$REPORT_PATH"` test, and it has to (#40). A successful `.partial-*` move deletes that path, so anything nested under that test was skipped in exactly the outcome where the user most needs to be told where their last good report went. A complete report supersedes every `.partial-*` for its date, including ones from earlier nights, since a partial is a prefix of a report that now exists in full.

Credentials never go in `argv`. `-H "cookie: auth_token=…"` puts a full account-takeover token in the process list for the life of the request, readable by anything running as the same user, and the nightly run makes several of these unattended. `x-bookmarks.sh` writes them to a 0600 `curl --config` file inside the per-run `$TMP` that the EXIT trap removes.

`materialize()` calls **both** `brctl download` and `fileproviderctl materialize`. `brctl` predates the FileProvider migration and on current macOS often succeeds while doing nothing, which would silently reduce the iCloud wait to a passive timeout dressed up as a fetch.

### Bash traps this feature hit, all of them silent

Each of these passed a smoke test and failed in a way that produced no error:

- **`$(grep -c ... || echo 0)` yields `"0\n0"`.** `grep -c` prints `0` *and* exits 1 on no match, so the fallback fires too. The arithmetic that follows then dies under `set -e`. Triggered by a `notes.md` holding only its header — exactly what the user is left with after deleting notes a report said were addressed.
- **A variable set inside `$(...)` never comes back.** `fail()` assigned `FAIL_REASON` from inside nested command substitutions (`qid=$(get_query_id)` → `qid=$(detect_query_id)`), so the cookie-expiry remediation text died with the subshell and the report said a fetch failed for no reason. The reason now goes to a file, which crosses the boundary.
- **An iCloud-evicted file is not a zero-byte file.** macOS replaces it outright with a dot-prefixed `.<name>.icloud` placeholder, so a `-name '*.md'` walk matches *nothing* and the unreadable-note branch was unreachable for the only case it existed for. Placeholders get their own pass and are never manifested, so the note stays in the inbox to retry.
- **Sourcing a user-edited config under `set -u` kills the shell.** Not the source — the shell, so `|| echo WARNING` cannot fire. `run.sh` now probes the config in a throwaway subshell purely to capture bash's own error naming the bad variable, then sources for real with nounset off. Both helper scripts need the same guard; fixing only `run.sh` left them dying instead.
- **`mv` across filesystems is a copy, not a rename.** State staged in `$TMPDIR` and moved onto `$STATE_DIR` was never the atomic swap its comment claimed. Stage in the destination directory and gate the `mv` on the staging copy having succeeded.
- **State that has to change together goes in one file, written with one rename.** Two files cannot be updated atomically, so every write order leaves a failure point between them. `question-streaks.sh` kept its watermark in a second file, and three Codex rounds on omp-autodream PR #25 in a row each found a new order in which the two disagreed. Moving the watermark into the state file's first line ended it (see "Open questions that never get answered"). When a fix starts choosing which of two files to write first, merge the files instead.

## X bookmarks as idea fuel

`bin/x-bookmarks.sh` fetches recent bookmarks into `findings/<date>/x-bookmarks.md`; `PROMPT.md`'s "Ideas from bookmarks" section crosses them against the day's findings. The section's whole value is the intersection, so the prompt is explicit that a bookmark with no connection to this run gets left out and "none connected" is a correct answer — otherwise the model manufactures links and the section becomes a reading list the user already read.

The official API is not an option: `GET /2/users/:id/bookmarks` has never been on the free tier and needs Basic at $200/mo (checked 2026-08-02). So it reads X's internal web GraphQL endpoint with cookies pasted once into `$AUTODREAM_DIR/x-credentials`. The queryId in that endpoint's path rotates on X deploys, which is why the script scrapes it from the live JS bundle and caches it rather than hardcoding one.

Two invariants keep this from ever costing a night's report: the script always exits 0, and it always writes its output file — including a "not configured" stub and a `# x-bookmarks: fetch failed — <reason>` header. `mark-read` runs only after a non-empty report, same reasoning as the note archive above: a bookmark stamped read by a run that produced nothing is a bookmark the user never gets an idea from.

The queryId walk against X's JS bundle stays untested, and #38 closed on that rather than on a fixture. A fixture would assert that our regex matches a string we wrote, and would keep passing on the only day it mattered — the day X changes its chunk naming. A live canary was rejected too: it buys a few hours of notice over the nightly report, at the cost of an unattended job hitting a third party on a schedule. What shipped instead is `x_queryid_source` in `run-stats.txt` (`fresh` / `cache` / `failed` / `not_attempted`), because the one state nothing could see was `cache` — the fetch works, so the walk looks fine, while it may have rotted at any point since the last `fresh`. `x-bookmarks.sh` stamps it on every path via a file rather than a variable, for the reason the whole script does: `get_query_id` runs inside a command substitution.

`bin/cookie-cadence.sh` (#39) answers how long a pasted cookie pair lasts, which is what decides whether automating the capture is worth its moving parts. Same shape as `oversized-gate.sh`: it recomputes from the `x-bookmarks.md` headers already on disk, makes no model calls, reads no credentials, and is safe to re-run. Two things in it are load-bearing rather than decorative. It counts only the 401/403 rejection and the login-page redirect as expiries — a dead network or a missing jq says nothing about the cookies, and folding those in would make a yearly chore read as a weekly one with no visible sign of the error. And a stretch of working nights with no expiry at the end of it is right-censored, so it is reported as a lower bound and never as a lifetime.

## Self-audit

run.sh writes `run-stats.txt` (raw/excluded/triaged counts, L1 rounds/done/missing/err, elapsed). PROMPT.md's "Autodream self-audit" section reads it and is told to flag self-pollution regressions (excluded count climbing), pipeline-capacity problems (oversized transcripts that blow the token budget), retry/sleep health, and to propose concrete cc-autodream source fixes since the user authors the tool. It proposes; it does not edit cc-autodream source.

### Degraded measurements must say so, not read as zero

Two counters exist only to keep a broken measurement from looking like a real result, and any new stat should follow the same rule. `overlap_measured: yes|no` (#26) marks whether the cross-session overlap pass actually ran. `stats_sidecars_unparseable: N` (#27) counts sessions whose `*.stats.json` sidecar was missing, empty, or had no numeric `transcript_bytes`.

The sidecar counter is deliberately one number rather than a flag per stat: a broken sidecar degrades several counters at once (the noise gate and the oversized gate both read the same file), so the failure is counted once and PROMPT.md caveats the affected keys. The oversized loop walks `sessions.txt` rather than the `*.stats.json` glob — a sidecar that was never written is absent from the glob, and the session it belonged to used to vanish from `oversized_total` silently. Sizes for those sessions fall back to `wc -c` on the transcript itself, which is exactly what `transcript_bytes` holds anyway, so the #12 gate keeps a truthful number instead of a clamped 0.

The noise gate's own sidecar read still biases to triage on an unparseable sidecar and that stays — the cost is one wasted model call. What was missing there was never the behavior, only the signal.

### Nobody was told (`unassembled_dates`)

A run killed during L2 leaves a complete findings dir and no report, and every surface that would have said so is downstream of the death: `notify.sh` never runs, so there is not even a quiet banner. The catch-up triggers cannot cover it either, because launchd will not start a second instance of a label that is already running — a run slow enough to span its own catch-up window converts those triggers into nothing at all. 2026-07-26 sat unassembled for two days and was found during an unrelated investigation; 2026-08-01 repeated it.

`unassembled_dates()` sweeps the trailing week at the top of `run()` — deliberately *above* the idempotency guard, so a catch-up trigger that no-ops for today still reports older abandoned dates. It lists dates holding findings JSONs (sidecar-only dirs were never triaged and are not failures) whose report is missing or marker-less, and the result goes to the log and to `run-stats.txt`, which puts it in the next morning's report. The data was never the problem: `autodream-now.sh <date>` rebuilds one in minutes because the findings survive and it skips straight to L2.

### Which code actually ran (`runner_commit`)

`install.sh` symlinks `~/.claude/autodream/*.sh` straight at the repo working tree, so the nightly executes whatever is checked out at 03:15. A tree behind origin runs old code even though the fix is merged and the PR is green. This has cost data twice: the 2026-07-24 `overlap-stats.sh` dangle, and a tree stuck on a local commit from 2026-07-20 to 2026-07-24 that wrote four nights of `run-stats.txt` with no `oversized_*` / `gated` / `overlap_*` keys at all.

`run-stats.txt` therefore carries `runner_commit` + `runner_dirty` (#29). The diagnostic that matters: a `run-stats.txt` that is *missing keys*, rather than holding suspicious values, means an old runner — not a stat that didn't apply. Both times it took a reflog dig to establish that.

`bin/oversized-gate.sh` exists because of the same incident. The #12 gate is a trailing-window judgment but `run.sh` records one night at a time, so a stretch of old-runner nights used to be unrecoverable. It recomputes the window from the `*.stats.json` sidecars and findings JSONs still on disk, which survive independently of whether the runner knew how to count them. Artifacts only, no model calls, safe to re-run. It refuses to call an empty window a measured 0%, and quotes a rule-of-three upper bound so a clean run isn't read as stronger evidence than the sample supports.

### A failed worker leaves its evidence, and the failure is classified (omp-autodream 2026-09-04, #26)

The worker's stdout used to go to `/dev/null`, so every failure looked the same: an `.err` holding the one line `Working...` plus a hand-written sentence. On 2026-09-04 that hid a dead network behind three fine transcripts, and the report blamed their size (`oversized_errored / oversized_total` read 3/4, the number that opens issue #12). Re-run by hand against a live network, those transcripts triaged in 73 to 78 seconds. Now a failed worker's `.err` records its exit code and elapsed time and the last 40 lines of its stdout, or says plainly that stdout was empty. The `.err` and `.out` are deleted only when the worker succeeds.

- **Non-empty is not valid.** A worker that writes malformed JSON, or JSON whose `.findings` is not an array, is a failure with its evidence kept, not a success. `jq -e .findings` is truthy for a string, so the check is `.findings | arrays`, on the way in (idempotency, `l1_missing_count`) and on the way out. The malformed file is removed so it cannot reach L2.
- `bin/failure-class.sh` is the single failure predicate sourced by both `run.sh` and
`bin/oversized-gate.sh`. It assigns every error stub to one of four classes from its
`.err`: `unclassified` when the file is missing, empty, or predates the
`worker exit code:` capture; `silent` for exit 0 with the exact
`worker stdout was empty` line; `provider` when the worker's own output shows a
429/auth/5xx/overload/quota refusal without a size signature; and `size` for
everything else, including context-limit signatures, timeouts, and other nonzero
exits. The worker's own output is its stderr (the top of the `.err`, before the
exit-code line) plus the captured stdout section. Every line `run.sh` writes itself is
skipped by its exact text: the timeout note, the malformed-output dump, the session-path
line, the exit-code line, the omp log tail and the network notes. A session path or a
dumped findings JSON can say `quota` or `HTTP 500` with no provider refusing anything,
and the omp log may belong to a sibling worker. The stdout section ends only at
`run.sh`'s next marker, never at a `--- ` line the worker printed itself. A number counts as a status code only after an HTTP,
status, code or error label, so `read 520 bytes` is not a 5xx; a bare code needs its
reason phrase (`503 Service Unavailable`). Words match with spaces, hyphens or
underscores, so `prompt-too-long` stays size even beside an HTTP 500.

The size and provider word lists are best-effort and will never be complete: five of the
seven review rounds on PR #26 found another phrasing. That is acceptable because of the default.
A wording neither list knows lands in `size`, which is the owner's decision (2026-09-15):
a session is only counted once its byte size is over the threshold, so an unexplained
failure there is a size failure. Add a wording when a real `.err` shows one, with a
matrix row in `test_failure_class_provider_matrix`; do not grow the lists speculatively.

`run.sh` and `bin/oversized-gate.sh` look for the classifier next to themselves, then next
to the file their symlink points at, then in `AUTODREAM_DIR`. An install made before this
file existed has a link for every other script but not this one, and updating the
checkout must not break its nightly.

`run.sh` records silent, provider, and unclassified counts beside both
`l1_findings_with_error` and `oversized_errored`. The #12 share removes all three
classes from its numerator and denominator, so only failures with no better
explanation count against size. On 2026-09-13 the raw ratio read 6/7 while every
failed worker had died in omp's first-turn memory recall; the classified window now
reports that it measured nothing about size. `bin/oversized-gate.sh` recomputes all
four classes from artifacts even when `run-stats.txt` predates the counters. It also
skips any date whose stats read `network_deferred: yes`, because those runs counted
oversized sessions that never reached a worker and their share reads low (Codex
review of 2400815).

### A hung worker, a cold token and a deterministic failure (omp-autodream, 2026-08 to 2026-09)

Three controls on the L1 loop, each from a night that went wrong in a way the retry budget could not see:

- **Workers are bounded** (`AUTODREAM_L1_TIMEOUT`, default 1200, SIGKILL 30s after the SIGTERM). A worker that never exits holds its `xargs -P` slot forever, so `FANOUT` hung workers stop the whole run with no error and no report; 2026-08-19 and 2026-08-22 each sat wedged for days with every slot taken by workers blocked on their own `node_repl` and `mnemopi_embed` children. GNU `timeout` without `--foreground` signals the whole process group, which is what reaps those grandchildren; a bare kill on the engine would leave them running. macOS ships no `timeout`, so with none on PATH the run degrades to unbounded and says so in run-stats (`l1_timeout_bin: none`). A timeout is recognised by exit 124 or 137 **and** elapsed time at or past the bound: GNU `timeout` propagates the child's own status, so a worker that exits 124 by itself, or is OOM-killed at second zero, looks identical to a real one (measured: a self-killed child returned 137 after 0s under a 100s bound). The timed-out hash goes in `l1-timeouts.txt`, an append-only per-run ledger, because the `.err` is deleted whenever a retry succeeds. The partial findings file is removed, because a worker killed mid-write leaves truncated JSON that would read as a result.
- **The auth warmup** is one serial `ping` per adapter before the parallel dispatch, so `FANOUT` cold workers do not all refresh the same expired token at once. Each adapter prints its own `warmup-argv`: the worker's flags with a system prompt that asks for one word. It is bounded by its own deadline (`AUTODREAM_L1_WARMUP_TIMEOUT`, default 120) because it runs ahead of every recovery path; with no `timeout` binary it is skipped, never run unbounded. The reply must be the word `ok` on stdout with exit 0: a worker that dies prints nothing and exits 0 with only chatter on stderr, which an exit-code check alone calls healthy. `l1_warmup` in run-stats says `ok`, `failed`, `skipped` or `skipped_no_timeout`.
- **The circuit breaker** stops the retry budget after two consecutive rounds that each recovered nothing. The budget is built for a Mac sleeping through a round; against a worker that dies the same way every time it buys nothing and hides the shape (2026-09-08 spent five rounds and 405s writing 16 empty stubs, and the run-stats read as a healthy retry loop). It is a streak, not a comparison of ending counts, which tripped it after one bad round when round 1 had recovered something. It still dispatches once more, at the budget, because the metadata-stub fallback only fires there and an empty slot is not a stub. `l1_breaker_fired: yes` and `l1_rounds_used` (the last round that actually dispatched) keep a short run from reading as a clean one.

### A dead network or a refusing provider defers the date; it never publishes a short corpus (omp-autodream 2026-09-04, #37)

A report written from a run that could not reach the model looks complete, ships open questions, and its own self-audit cannot tell the corpus is missing. So:

- `wait_for_network` runs before every L1 round (round 1 included) and returns 1 once `AUTODREAM_NETCHECK_CAP` is spent. The run then sets `NET_DEFERRED=yes`, writes no report and exits 1, so `unassembled_dates()` names the date and a later trigger retries it.
- A worker failure probes `curl` once. No route, or a permanent provider refusal (`provider_is_permanent` in `failure-class.sh`: no balance or quota, Z.ai 1113, DeepSeek 402), is ledgered in `l1-netdown.txt` as `<hash> <round> true|provider` and gets no metadata stub. A stub fills the slot, so the session would never be retried.
- Only the LAST round that dispatched decides the deferral, so one transient flap is ridden out by the next round. A curl that is absent or not executable (exit 127/126) is "cannot tell", never "down".
- `run-stats.txt` carries `network_down_seconds`, `network_deferred`, `network_flapped`, and after L2 `network_down_seconds_l2` / `network_deferred_l2` (both also on the deferral exit).
- `run.sh` appends to the caller's `PATH` instead of replacing it, so a caller (or a test) can put a shim in front.

### Several harnesses in one run: enabled is a host decision, and every session goes through its own adapter

`AUTODREAM_ADAPTERS` (names, space or comma separated, or `all`; default `claude`) names the harnesses a run scans. An adapter that sits under `adapters/` is accepted, not enabled, so merging a harness never changes what a live nightly reads. For an enabled adapter the session's own adapter does the work:

- `stats` comes from the adapter (omp records are not claude records). `AUTODREAM_STATS_BIN` still overrides, and a session with no recorded source keeps the claude script.
- A manifest with `"normalize": true` (omp: an append-only tree) is linearized first and the worker reads `<hash>.norm.jsonl`, the live branch only. A tree the linearizer refuses (duplicate id, dangling parent, cycle) becomes a structured error record ("could not be normalized by the <adapter> adapter") and no worker is started. `findings.session_path` is rewritten back to the real session, and the copy is removed.
- The substantive-session filter accepts both shapes: a claude user record, or an omp `message` record with role user and a text item.
- The L1 engine, model and warmup come from the adapter (see "Who starts the L1 worker").

### Skill fields are measured, not guessed (omp-autodream 2026-09-04)

`skills_invoked`, `skills_invoked_count`, `skills_invoked_counts` and `skills_authored` come from the stats sidecar (`session-stats.sh` for claude: a `Skill` tool call or a `<command-name>` slash line is an invocation, a Write or Edit of a `SKILL.md` is authoring). After L1 the runner overwrites those four fields in every findings JSON from the sidecar. A sidecar that is missing, unreadable or lacks any of the four means the skills were not measured, so all four are removed from that findings JSON and counted in `skills_unmeasured`. A worker's own list was how a report concluded a 200-skill inventory never fires.

### What L2 is told about each harness (`skills-inventory.txt`, `adapter-facts.md`)

Both files are written by `write_adapter_inputs` just before L2, from the adapters. `skills-inventory.txt` unions every enabled adapter's `skills-inventory` output (name, optionally a TAB and a description), deduplicated by name; if every adapter fails it says `# skills-inventory.txt unavailable` and PROMPT.md tells L2 not to file coverage gaps from it, because an empty list would claim no skills are installed. `adapter-facts.md` holds one `## Source: <name>` section per harness that had sessions tonight, taken from the source map captured before any model ran: a remedy for a finding has to be a surface that exists for the harness the evidence came from. A new harness adds an `adapters/<name>/facts.md` and a `skills-inventory` subcommand, not code in `run.sh`.

### One triage document, one addendum per harness that differs

`prompts/SESSION_TRIAGE.md` is the single L1 prompt. A harness whose transcripts differ from the claude shape it describes adds `adapters/<name>/triage.md`; the worker appends it for that adapter's sessions only (it says it wins where it disagrees), so a claude worker receives exactly SESSION_TRIAGE.md plus the stats block. `adapters/omp/triage.md` carries omp's record shapes, the harness-tool rule, the retired `compliance_markers`, `is_advisor` and `skills_authored`, and the restricted schema for advisor sidecars (no `sandbox_friction`, `tool_loop` or `missed_skill`). PROMPT.md excludes advisor turns from the session-turn total and files any advisor tool-behavior finding under Triage failures.

### L2 is read-only: the report and the pins arrive on stdout (omp-autodream 2026-09-13, plan 2026-09-15)

L2 holds Glob and Read. It cannot write the report, `pins.jsonl`, or anything under the findings directory, so the runner is the only writer and an injected L2 cannot rewrite `sessions-source.txt` or forge a pin. The grammar of its stdout:

```
<report body>
AUTODREAM_REPORT_END
AUTODREAM_PINS_BEGIN        (optional)
{"project":...,"title":...,"body":...,"kind":...}     one JSON object per line
AUTODREAM_PINS_END
report: <path>
<3-line summary>
```

- Delivery means a capture with the sentinel. The report is everything before the LAST sentinel; a capture without one is kept as a degraded report, moved aside as `.partial-<epoch>`, and retried. The open-questions marker alone is not proof of completion.
- Pins come only from a closed block after the last sentinel, so a report that quotes the markers cannot inject one, and a block cut off before its END line proposes nothing. `apply-pins.sh` still validates every line against the authorization list fixed before any model ran.
- The run exits 0 only for a validated delivery (sentinel plus marker); otherwise the aggregator's own non-zero status, else 1, so the launchd job sees a night that produced nothing.

### Which engine runs L2

L2 is an adapter too. `AUTODREAM_L2_ENGINE=<adapter name>` picks it (default: the first enabled adapter, so `claude` on an untouched install); a name that is not an accepted adapter stops the run before L1, not after. The adapter prints the command (`adapter.sh l2-argv [model]`, NUL-delimited, prompt on stdin, tools Glob and Read only) and `l1-env` supplies its environment. The model resolves `AUTODREAM_L2_MODEL_<NAME>`, then `AUTODREAM_L2_MODEL`, then the manifest's `l2_model`; none at all is valid and means the engine's own default (claude). `run-stats.txt` records `l2_engine`, `l2_model` (`default` when none was named) and one `l1_model_<adapter>` per source that had sessions, so a report that reads differently can be traced to the engine that wrote it. An install whose `adapters/` tree predates `l2-argv` keeps the built-in claude invocation, for claude only. Every engine gets the same system prompt, `prompts/L2_SYSTEM.txt`, through `bin/l2-prompt.sh`; it names the stdout grammar `bin/report-format.sh` parses, so change them together. A missing prompt file makes `l2-argv` exit 2 rather than start an engine without it.

### The review triage LaunchAgent

`install.sh` provisions a second agent, `<nightly label>-review`, next to the nightly one: it runs `review.sh <yesterday>` at 08:00, 09:15, 12:15, 15:30 and 18:15 with `AUTODREAM_TRIAGE_SURFACE=cmux`, and review.sh's launch marker keeps it to one workspace per report. The date is a `$(date -v-1d ...)` evaluated at fire time (the installer refuses to write the plist if that expression was frozen). cmux and claude are resolved the way review.sh resolves them (config, then PATH, then `AUTODREAM_CMUX_DEFAULT` or the app bundle path) and pinned absolutely in the agent's environment; with either missing the agent is skipped and a previously provisioned one is booted out, so a machine that lost cmux does not keep firing a failing trigger. A refused nightly schedule provisions no review agent. `--no-review` (this run) or `AUTODREAM_REVIEW_AGENT=0` (environment, then config, so it survives a re-install) opts out the same way: the agent is not provisioned and a loaded one is booted out and its plist removed. `tests/install-review-agent.sh` drives the real installer against a sandbox HOME with a shimmed `launchctl`; `tests/install-path.sh` covers the opt-out and the plist PATH below.

### What goes in the plist PATH

launchd has no login shell and the job runs with only the PATH install writes, so a CLI the job needs has to be reachable from it. `install.sh` resolves `claude`, `git`, `bash`, the `engine_bin` of every enabled adapter (`--adapters`, else `AUTODREAM_ADAPTERS` from the config) and the L2 engine's (`--l2-engine`, else `AUTODREAM_L2_ENGINE`; a host can scan claude and run L2 on omp) and puts their directories first. The config is read by sourcing it, as `run.sh` does, so `export KEY=value` and quotes read the same. An adapter's `<NAME>_BIN` from the config wins over the PATH lookup, so `omp` under `~/.bun/bin` is reachable without being on the installer's PATH; one only in the installer's environment does not count, because launchd will not carry it and the adapter would then look for the bare engine name on PATH. Two things here were learned on a real host:

- **A shell's temp PATH entries must not be baked in.** cmux puts `$TMPDIR/cmux-cli-shims/<uuid>` first on PATH in every terminal it opens, and the installer used to copy that directory, and the shim `claude` in it, into both plists. They are gone after the session. `ephemeral_dir` drops any PATH entry under `$TMPDIR`, `/tmp` or `/var/folders` before the tools are resolved, and says so. `AUTODREAM_EPHEMERAL_DIRS` replaces the prefix list; set but empty, it turns the check off, which the install suites need because every fake tool they make lives under `$TMPDIR`. A DEV cmux build under `DerivedData` is not ephemeral and is left alone.
- **omp is not on the usual PATH.** A bun install puts it in `~/.bun/bin`, which no default PATH carries. Without the adapter's directory in the plist the omp worker cannot start and the night's omp sessions are lost without an error (`FATAL: omp not found` in the run log, no report from that source).

The PATH is fixed when the plist is written, so enabling an adapter afterwards by editing the config needs a re-install, or `<NAME>_BIN` in the config (read by `run.sh` at run time, independent of the plist). `--no-review` stops where a refused label stops: the review label is `<our label>-review`, and on a refused label that is another install's agent, which this installer must not boot out or remove (`tests/install-path.sh` pins it).

### Rehearsing an install: `--dry-run`, `--adapters`, `--l2-engine`

`install.sh --dry-run` runs the same code with every write replaced by a `[dry-run]` line: the links, the config sections, the plists (generated and `plutil`-linted in a scratch directory, then shown with the path they would be written to) and each `launchctl` call. What only reads still runs, so a dry run reports the refusal a real install would hit (a foreign job holding the label, a non-empty real directory where a link goes) and still exits 0 for the survivable one. `tests/install-dry-run.sh` asserts the sandbox tree is identical afterwards and that `launchctl` was never invoked. `--adapters <names|all>` and `--l2-engine <name>` write one managed `# adapters (managed by install.sh)` section into the config, replaced in place on re-install and left alone when the flags are absent; both are validated against `adapters/` before anything is written (exit 64). run.sh sources the config with the caller's environment winning, so an exported variable still beats it.

### Replay: does this code read real data the way the code that wrote the archive did

`tests/replay.sh` runs the unified runner's code over archived data, offline and read-only. `--artifacts <findings-dir>...` recomputes shape, failure classes, enforced skill fields, the overlap pass and the oversized gate from a findings directory on disk and compares each figure with the `run-stats.txt` the original run wrote. `--ingest <adapter> <session-root> <date> [--against <findings-dir>]` stages a copy of the sessions modified from that date until five years after, the runner's own reach (the enumeration `find` does not follow a symlinked root, so a link would find nothing; the window is the runner's job, so an older runner reads the same copy), installs into a throwaway home, runs the whole pipeline with `tests/mock-claude.sh` as every engine, and checks that every session was enumerated, normalized, given a sidecar and a findings JSON. Output is PASS, WARN or FAIL per check; only a FAIL fails the run. A WARN is a difference the archive explains (a counter it predates, a corpus that moved, a rebuilt directory, advisor sidecars the old runner did not flag), and the line says which. It cannot say whether a model would triage these sessions well, because the engines are mocks. Results for this host's archives are in `docs/plans/2026-10-03-omp-adapter.md`; `test_replay_harness_works_on_synthetic_data` keeps the harness itself honest.

## Running / rerunning a date

```
~/.claude/autodream/run.sh 2026-05-29        # process a date
AUTODREAM_FORCE=1 ~/.claude/autodream/run.sh 2026-05-29   # rebuild despite an existing report
```
To reprocess cleanly (e.g. after the corpus changed), delete that date's findings dir AND report first, then run; otherwise idempotency reuses old findings and the guard skips. Env knobs are documented in `run.sh`'s header and the README.

### Running on-demand without the 10-min cap (`autodream-now.sh`)

A full run routinely exceeds 10 minutes, so launching `run.sh` from a foreground/background context that has a time cap (a Claude Code background Bash task, an ssh session that may drop) gets it killed mid-flight. `bin/autodream-now.sh` sidesteps this by handing the run to **launchd**, which owns the process — no time cap, survives the caller disconnecting.

```
~/.claude/autodream/autodream-now.sh                  # yesterday, now
~/.claude/autodream/autodream-now.sh 2026-05-29 --force   # specific date, rebuild
~/.claude/autodream/autodream-now.sh 2026-05-29 --watch   # tail run log until report lands
~/.claude/autodream/autodream-now.sh 2026-05-29 --dry-run # print plist + commands, run nothing
```

How it works: it writes a transient one-shot LaunchAgent (`<base-label>.ondemand`, `RunAtLoad`) into `$AUTODREAM_DIR`, `bootout`s any prior instance, then `bootstrap`s it so launchd runs `run.sh <date>` once and the job exits. `RunAtLoad` is the *only* trigger — it deliberately does not also `kickstart`, or a fast run (e.g. the idempotency no-op) would fire twice. It never touches the scheduled nightly job. Everything is auto-detected: it resolves its own symlink to find `run.sh`, picks the scheduled plist whose `ProgramArguments` reference `run.sh` (not the sibling `*-review` job) to borrow its label namespace, and detects uid + the `claude`/`git` dirs for the agent's PATH — so it is not specific to one user or host. It refuses to launch while the label holds a live pid (`launchctl print` shows `pid =`): every on-demand run shares the one label, so the `bootout` would kill the in-flight run (#78). Wait for it, or `launchctl bootout` it yourself. The default date is computed with plain `date -v-1d`, exactly like run.sh (no TZ override). `--force` maps to `AUTODREAM_FORCE=1`; the caller's `AUTODREAM_DIR`/`DREAMS_DIR` are passed through. Progress is in `$AUTODREAM_DIR/logs/run-<date>.log`; the agent's own stdout/stderr go to `logs/ondemand.{out,err}.log`.

When you (the agent) need to kick off a run, prefer this over a background Bash task — fire it, then poll `dreams/<date>.md` instead of holding a long task open.

## Reviewing changes here

Almost everything in this repo is shell, and a shell bug here fails silently on a
nightly cron nobody is watching. `/code-review` is a fine first pass but it is not the
gate. Before merging any change to `run.sh`, `bin/*.sh`, `install.sh`, the launchd
plists, or the prompts, also run `/debate:run tight` — that preset is Codex + Gemini +
DeepSeek, so at least one seat does not share Claude's blind spots.

This is not a hypothetical. PR #37 (merged 2026-08-02) was reviewed by a fanout of 30+
Claude verifier subagents. They found 18 real defects, which is the case for the fanout.
But ten of those verifiers issued verdicts quoting `file:line` they had never read, and
three of them accused a sibling of fabricating citations while fabricating their own.
Adding more Claude seats does not catch that, because every seat fails the same way.
A different vendor does.

DeepSeek direct retains prompts and trains on them. That is fine for this repo, which is
public. For private code, swap the seat rather than skipping the pass.

## Tests

`tests/run-all.sh` drives the real `run.sh` against `tests/mock-claude.sh` (no network, no model). Mock modes: `good` (default), `l1_incomplete` (worker writes nothing), `l1_flaky` (fails first dispatch per session, succeeds on retry). The suite forces `AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0` and a low `AUTODREAM_L1_ROUNDS` so it never sleeps or hits the network. Runs on macOS and Linux since 2026-10-07: every `date -v`, `date -j -f`, `date -r <epoch>` and `stat -f` goes through `bin/portable.sh` (`pdate_*`, `pstat_*`), which `tests/portable.sh` pins with literal expected values on both. A new script or test that needs one of those calls the helper, never the raw tool: GNU `date -d` also accepts "tomorrow", so the helpers check the shape first. CI split: `tests.yml` runs everything but the launchd suites on Linux; `launchd.yml` runs `install-*`, `scheduler-label`, `autodream-now` and `portable` on macOS only when a launchd file or `portable.sh` changes, plus the whole suite weekly (cron) and on dispatch, because bash 3.2 and BSD flags are where the silent failures have come from and a Linux-only gate never sees them. Locally, the Linux half runs in docker: copy the repo, run as a non-root user (root defeats every chmod-based test), one fresh copy per suite. It runs `run.sh` under `/bin/bash`, the interpreter its shebang names and launchd uses (3.2 on macOS), not whatever `bash` is first on PATH: under bash 5 an empty array expands to nothing, under 3.2 with `set -u` it is an unbound-variable error, and a warmup that aborted for exactly that reason passed the whole suite until the suite ran the shipped interpreter. Run it after any run.sh/prompt change — it now also invokes the five unit suites (`lib-project`, `preflight`, `adapters`, `adapter-claude`, `adapter-contract`) and folds their counts into its totals, so one command covers everything CI runs. They were workflow-only for a while, which meant a local pre-push run skipped adapter containment, the manifest-name check and the whole contract suite.

`tests/session-window.sh` covers `bin/session-window.sh` directly: the bounds on DST days in New York, London and Sydney (expected values are literals worked out separately, not the `date` call the helper uses), the inclusive start and exclusive end, fractional seconds, torn lines, no-clock files placed by mtime, clocks in a shape it does not read, an out-of-order file, `autodream_meta`, and the `parentId` handling. Its integration side is the `test_window_*` and `test_rebuild_*` cases in `tests/run-all.sh`.

`tests/apply-pins.sh` covers `bin/apply-pins.sh` directly: schema validation, the ledger that stops a rerun double-writing, an unobserved project, a missing `cwd`, a missing `pin-projects.tsv`, and shell-metacharacter payloads in a pin body. `tests/mock-shared-memory.sh` stands in for the `shared-memory` CLI. `SHARED_MEMORY_BIN` is pinned to that mock everywhere the suite runs `apply-pins.sh`, so no test call can write real Mnemopi memory.

The suite pins `AUTODREAM_CONFIG` into its sandbox now that `run.sh` sources the config. Without that pin, a developer whose real config points `AUTODREAM_VAULT_DIR` at a live Obsidian vault would have the test suite writing notes and reports into it. `MOCK_MODE=l2_fail` makes the aggregator write nothing and exit 1, which is how the "don't archive an unread note" guard is tested; pair it with `AUTODREAM_L2_ATTEMPTS=1` so the test doesn't sit through the retry loop.

`tests/x-bookmarks.sh` covers the bookmark fetcher with `curl` shimmed and the queryId cache pre-seeded, so nothing touches X. The bundle-scraping walk is untested on purpose — it runs against a live third party and a fake proves nothing about it. Everything downstream of the HTTP call is pinned hard, because that is where both development bugs lived: the emit came out oldest-first (it trusted file order, which is only chronological within one run), and `mark-read` silently no-opped on every row (`$ids | index(.id)` rebinds `.` to the array before `.id` is read, so it indexed an array with a string). Neither showed up in a smoke test and both would have quietly wasted the feature.

`tests/cookie-cadence.sh` pins `bin/cookie-cadence.sh`'s classification against every header shape the fetcher writes. Fixtures rather than a smoke test, because a misclassification produces a number that looks exactly as authoritative as a correct one.

`tests/review-skip.sh` covers `bin/review.sh`'s skip/launch decision against fixture reports, with an inline mock claude that just touches a marker file — if the marker exists, review.sh reached `exec claude`. It pins `AUTODREAM_CONFIG` to a nonexistent path so the host's own config (`AUTODREAM_TRIAGE_SURFACE=cmux`) can't leak in and spawn a real workspace mid-test. Run it after any review.sh change, and after changing PROMPT.md's Open-questions marker contract.

`tests/review-cmux.sh` covers `bin/review.sh`'s `AUTODREAM_TRIAGE_SURFACE=cmux` launch path (the morning review job's workspace popup) with a mock cmux binary — no real workspace ever spawns. It pins the same-day dedup marker contract against the report: first trigger opens and stamps a confirmed token (claim dir + `.confirmed` sibling), a same-day same-digest trigger is deduped, `--force` bypasses the marker, a failed create releases the claim and exits non-zero, the marker binds to the report content digest (a rebuilt report opens again), stale claims and tokens >14 days get reaped, a confirmed marker survives the reclaim grace window while an abandoned (unconfirmed, old) claim is reclaimed and a young unconfirmed claim suppresses concurrent triggers, a headless (non-TTY) run with missing cmux fails non-zero instead of falling back to a headless inline claude, and a logs dir that can't be created fails loudly. Run it after any change to the cmux branch of review.sh.

## The OMP adapter (`adapters/omp`)

Plan 2 of the consolidation, `docs/plans/2026-10-03-omp-adapter.md`. An OMP session is an append-only tree, so `normalize` is real work here, unlike the claude adapter's copy:

- **`linearize.sh` keeps only the chain from the live leaf to the root.** The live leaf is the last entry in the file, because omp does not persist its in-memory leaf pointer. It fails closed with no output on a malformed line, an entry with no string `id`, a dangling `parentId` or a cycle, and callers must skip the session instead of reading the raw file, which credits the user with branches they abandoned. A cycle that excludes the root is caught by the chain's first entry still having a parent; a cycle through every entry is caught the same way, which is why that check is the load-bearing one.
- **Nested sessions are real sessions.** `<stamp>_<id>/__advisor.jsonl` and `<stamp>_<id>/<Name>.jsonl` are children of `<stamp>_<id>.jsonl`. Provenance comes from the path, not from the entries: an advisor has no user turns and no `session_init`. A child is found by its parent file existing, or, once the parent is deleted, by its directory being named like a session file (`<ISO stamp>_<id>`; a bucket is a dash-encoded path and never is). `autodream_meta` carries `nested` and `is_advisor`, and `stats` copies them into the sidecar, because the filename of a normalized temp copy says neither. `isSidechain` is `is_advisor or nested`, so a child is exempt from the noise gate the way a claude subagent is; a stats script handed a raw file works the same out of the path, because a linearized copy's own directory says nothing. A user-role message with `message.attribution` of `agent` (a parent steering a child, hook output, an advisor's whole prompt stream) is not a human turn: `user_message_count` and `user_turn_timestamps` skip it, and a message with no attribution field counts, as in files from before the field.
- **Accepted is not enabled.** `run.sh` scans only the adapters named in `AUTODREAM_ADAPTERS` (default `claude`), so a directory under `adapters/` is safe on a claude nightly. `install.sh --adapters claude,omp` writes the choice into the config.
- `skills-inventory` prints `name<TAB>description`; the claude adapter prints the name alone.
- **Tool calls have two shapes and a main session writes both.** `stats` counts `custom/tool_execution_start` records, and falls back to the assistant messages' `toolCall` blocks only when the file has none: an advisor transcript has only the blocks (minus the calls its toolset rejected with `Tool "<name>" not available`, matched to their result by call id), a main session has each call as a record and as a block, and a union counts every main-session call twice. `tools_used` follows the same source.

## The Claude Code mod (`mods/autodream-band`)

An optional mod for Claude Code itself (a hot-reloading plugin of function hooks, not shell): a band above the prompt when the newest report has open questions, `/dream` to read it, and Triage to run `review.sh` in a cmux split. It is the only thing in the repo that **parses the report**, so `prompts/PROMPT.md` now has a second reader besides L2's own consumers. These four shapes are its contract, and `hooks/lib.ts` is where to change it when one moves:

- the title `# Autodream — YYYY-MM-DD`;
- `## Top patterns` with `### <title>` blocks carrying `- **Severity**: high|medium|low`;
- `## Open questions` and the `<!-- autodream:open-questions=N -->` marker (no marker reads as zero questions, so the band stays hidden);
- a `## Triage decisions` heading, which is what makes the band go away.

It finds `review.sh`, the reports and cmux through the variables `review.sh` reads (`AUTODREAM_DIR`, `DREAMS_DIR`, `CMUX_BIN`) with the same defaults, so a new knob in `review.sh` means a matching line in `locations()`. It cannot see a value that lives only in `$AUTODREAM_DIR/config`. Its in-session walk-through (`/dream here`) is a prompt of its own in `triagePrompt`, modelled on `review.sh`'s system prompt but not generated from it: if `review.sh`'s rules change, check whether the mod's should.

Its tests run under Claude Code, not in `tests/run-all.sh` and not in CI (`claude plugin validate mods/autodream-band`, `claude plugin test mods/autodream-band`; `tsc -p` needs the types Claude Code writes into the git-ignored `.claude-plugin/types/` when it loads the mod). `$.env.get` takes a literal variable name, so the variables a mod reads can be listed: a loop over names fails validation.

### The focus mod (`mods/autodream-focus`): the one place the user writes into the nightly run from a transcript

A second, opt-in mod: a `+ autodream focus` button at the top right of every prompt and reply that tags the turn for the next run to take a close look at. It is its own plugin so that `autodream-band` stays read-only, and `install.sh` deliberately does not install or load it (`claude --plugin-dir`, or add it to `CLAUDE_CODE_PLUGIN_DIRS`). Decisions that are easy to undo by accident:

- **The button is on the right, drawn `position: absolute`.** A left column cost every row two cells in a narrow split, and a row below cost a line per message. Absolute is also what makes hover-only work: `display: none` with `hover: { display: 'flex' }` reflows nothing. Tagged, it stays lit.
- **Two files, one writer each.** The mod rewrites `$AUTODREAM_DIR/tags.jsonl`, always from what is on disk rather than from memory, so two open sessions mostly keep each other's tags (the gap between its read and its write is not closed, and `$.fs.write` is not an atomic rename). `bin/vault-notes.sh` appends to `tags-consumed.txt`, `<id><TAB><report date><TAB><taggedAt>`. A tag is its id AND its `taggedAt` (untagging and tagging a turn again reuses the id), and the ledger rows of the report being built do not count, so a forced rebuild of a consumed date keeps its tags. Pending is the difference. A session open at 03:15 cannot race a run because neither side edits the other's file.
- **A read that fails must never lead to a write.** The mod rewrites the whole file, so "could not read" treated as "empty" replaces every tag with the one being added. Only a file that does not exist is empty; one that exists and will not read (`$.fs.read` refuses over 4 MiB, which a file that only grows reaches) makes the button say so and do nothing. A rewrite also hands back every line it did not understand, and the unknown fields of a line it did.
- **Three things the mod tests cannot catch, all found live.** The test engine's row is not an engine node, so (1) a wrapper `Box` with a `width` prop around `next(e)` is refused at runtime ("engine node under a Box with prop width") and the plain row is drawn, with nothing but a dim transcript line to say so; (2) a plain `Button` pads its label, so a box narrower than label plus padding truncates it to an ellipsis, hence the box is the label's length plus 5; (3) the label is text, not an icon, on purpose: the first version was an eye emoji, and with the emoji selector (U+FE0F) the engine measures it wider than Ghostty draws it and truncated it, while the bare one drew too small. Words cannot be measured wrong. When the button is missing, read the session transcript for `ui.render (UserMessage) refused:` before guessing; there is no debug log unless the session started with `--debug`.
- **The surface is `vault-notes.sh`, not the prompt.** A pending tag becomes a `## note: focus-…` block in `operator-notes.md` carrying its own instruction, the quoted turn and the transcript path, which L2 can Read. It counts toward `active:` in the header, so PROMPT.md's "skip if `active: 0`" rule needed no change. The header gains `tagged: N`.
- **Consumed by `archive`, never `collect`.** Same gates as an inbox note (a complete report, this run's own, the normal nightly date), so a failed L2 or a rebuild of an old date leaves tags pending. A tag is held for the report of the local day it was made on, and `vault-notes.sh` decides that day from the UTC `taggedAt` with BSD `date` (cutoff = the first instant after the reported day, so a DST day is 23 or 25 hours). The mod writes no day on purpose: its environment has no timezone, and a UTC date would hold back, by a night, exactly the tags made in the evening while reviewing the day. A timestamp that does not parse counts as already due, so a tag arrives late rather than never.
- **Tag text is data.** It is quoted line by line (`> `) so a turn containing `## note: …` cannot open a block of its own, and the block says the quote is content to analyze, not instructions. Assistant text can echo anything a tool fetched.
- **No jq is a missed note, not a clean zero.** The same rule as the iCloud placeholder and `overlap_measured`: `focus-tags — UNREADABLE`, counted in `unreadable:`, nothing manifested. A `tags.jsonl` that exists and will not read (permissions, a jq error) is reported the same way: `tag_pending` runs into a temp file, not a process substitution, so its exit status is seen. macOS 15 ships `jq` in `/usr/bin`, so the test builds a PATH without it.
- **`read` and tabs.** The per-tag fields are split on the unit separator, not a tab: tab is IFS whitespace, `read` collapses a run of them, and an empty `cwd` or timestamp in the middle would shift every field after it.

What is not verified: that a row's `requestId` in `ui.render` is the transcript's own `uuid` (the mod API does not promise it), which is why the note quotes the turn and names the session rather than relying on the id to locate it. The mod's tests run under Claude Code (`claude plugin validate|test mods/autodream-focus`); the `vault-notes.sh` side is `test_focus_tag_*` in `tests/run-all.sh`.

## One repo, no sibling to drift from

This repo used to have a twin, **omp-autodream**, the OMP port, and five helpers were kept
byte-identical with it by a drift check (`bin/check-shared-drift.sh`, `shared-with-sibling.txt`).
The reason was real: on 2026-09-11 the X bookmarks queryId walk was fixed in omp-autodream after
X moved to 16-character webpack chunk hashes, the identical file here was never touched, and this
install kept failing every night for ten nights while both repos' suites passed, each internally
consistent. omp-autodream is archived and its code lives here (see "Moving from omp-autodream" in
the README), so there is one copy of each helper and nothing to compare against. The check and its
manifest were removed in issue #106. The habit that outlives them: **a review finding is a class,
not a site.** Before fixing a pattern in one script, grep for it in the others.

## Open questions that never get answered

The nightly asks; nothing makes it louder when the asking stops working. Between
2026-09-05 and 09-14 the X bookmarks walk was broken, every report said
`x_queryid_source: failed`, and the Open questions section asked "Fix the X bookmarks
walker, or turn the feature off?" six times. Ten nights, six asks, one banner a night that
looked exactly like the night before. Nothing moved until the user noticed the *other*
install's reports had gone quiet.

Detection was never the problem. **A signal that repeats at constant volume is a signal you
learn to skim.**

`bin/question-streaks.sh` counts the repeats and makes the Nth ask look different from the
first. `run.sh` calls it first after a complete report, ahead of the pins and `notify.sh`, so a hung
`AUTODREAM_OPEN` or store cannot skip it (issue #77). The normal banner still goes out every
night and a second, differently-worded one fires only for questions that have gone stale.
Escalations also land in `findings/<date>/question-escalations.txt`.

Four decisions in it are load-bearing:

- **A question is keyed by its bolded title, exactly.** Verified against five consecutive
  reports (2026-09-10..14): the body prose is rewritten nightly, but the title is
  BYTE-identical across all of them. So no fuzzy scoring is needed, and heavier
  normalization would risk collapsing two genuinely different questions onto one key and
  silently merging their streaks.
- **The count is mechanical, not the model's.** L2 already writes "Sixth ask" into its own
  prose, but that is the model counting its own history out of context — exactly the kind
  of number that drifts. This one is derived from the reports on disk.
- **A streak counts consecutive REPORTS, not calendar days.** A night that produced no
  report must not reset one; surviving the failing nights is the entire point. A question
  absent from a report that *was* produced is treated as resolved and forgotten, so nothing
  has to be cleared by hand.
- **A marker promising questions while none parse is a warning, not a zero.** If PROMPT.md
  ever stops emitting bold titles, the quiet failure would freeze every streak at its last
  value and the escalation would never fire again — the same class of bug as a broken
  sidecar reading as a real measurement. A report with no marker at all is incomplete and
  is refused too: a truncated L2 report parses as zero questions and would clear the board.

Details from the Codex reviews of omp-autodream PR #25, ported here in #71, each with a test:

- **The store is the install's.** A bare run of the helper (`status`, `clear`) resolves
  its install dir from its own symlink when that dir carries a `config` or
  `l1-no-advisor.yml`, and `run.sh` passes `AUTODREAM_DIR` at both call sites.
- **One file holds the board and its watermark.** The newest counted date is the first
  line of `question-streaks.tsv` (`#last<TAB>YYYY-MM-DD`), so a question-free report
  leaves that line and an older rebuild is still refused. Every write is a temp file in
  the same directory and one rename, so a failure at any step leaves the old file whole.
  The watermark first lived in a second file, and three Codex rounds in a row found a way
  for the two files to disagree that let history back in. A state file that exists but
  cannot be read refuses the update, because reading it as empty restarts every streak.
  `clear` keeps the watermark.
- **`clear` takes the same lock as `update`**, before its "nothing to clear" check, and
  fails loudly when it cannot. It also fails on a key no streak carries (omp-autodream
  #32): printing "cleared" for a mistyped key left the real streak escalating.
- **The state directory exists before the lock.** The lock lives beside the state, so on a
  new state path the lock could never be taken.

Threshold is `AUTODREAM_QUESTION_ESCALATE_AT` (default 3). `question-streaks.sh status`
prints the current streaks; `clear all|<key>` forgets one after you have acted on it.

`/debate:run tight` found seven defects in the first draft, all in the new code and all
after the suite was green. Four are why the file reads as it does now:

- **Reruns forged escalations.** `AUTODREAM_FORCE=1 run.sh <today>` re-counted a report
  already counted, and rebuilding an OLDER date rewrote live state with history. Updates
  are now idempotent per report date and refuse to go backwards.
- **A zero-question report never cleared anything**, because `run.sh` returns early on the
  nothing-was-triaged path, before the usual call site. That path calls the updater too
  now — otherwise a question reappearing two reports later was called consecutive.
- **Concurrency could lose an increment.** The scheduled nightly and `autodream-now.sh`
  carry different launchd labels, so one-instance-per-label does not keep them apart. The
  read-modify-write takes an atomic `mkdir` lock, reclaims a stale one by age, and SKIPS
  rather than blocks when it cannot get it.
- **A parser breakage only wrote to the run log.** That is this feature's own failure mode
  one level up: every streak silently frozen, no escalation ever again, indistinguishable
  from a quiet week. A mismatch now posts a banner saying the escalation is down.

Replayed against the real 09-10..14 reports it escalates on **09-12** — two nights before
the user actually caught the bookmarks failure.

## Gotchas (host environment)

- The Claude Code sandbox denies writes under `~/.claude/` (including `rm` of symlinks/findings); those operations need the sandbox disabled.
- Subagent transcripts live in `projects/.../<session>/subagents/agent-*.jsonl` and ARE legitimate sessions to triage; they are not self-pollution.
- `claude --print` worker calls run from cwd `$HOME`, so any transcript they (used to) leave landed in the `-Users-<you>` project bucket.
