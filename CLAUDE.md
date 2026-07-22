# CLAUDE.md — cc-autodream

Operating notes for working on this repo. Read this before changing `bin/run.sh` or the prompts. The README is the user-facing pitch; this file is the stuff that bit us and the decisions behind the design, so future sessions don't re-derive them.

## What it is

A nightly two-layer pipeline that reads yesterday's Claude Code session transcripts and produces a ranked daily report plus a few pinned MEMORY.md entries.

- **Layer 1** (`prompts/SESSION_TRIAGE.md`, haiku, fanned out one per session): reads one transcript, writes one findings JSON.
- **Layer 2** (`prompts/PROMPT.md`, opus, single call): reads all findings JSONs, writes `dreams/YYYY-MM-DD.md`, optionally pins to project MEMORY.md.
- `bin/run.sh` orchestrates both layers and everything around them.

## Where state lives

All under `$AUTODREAM_DIR` (default `~/.claude/autodream/`) except the reports:

- `findings/YYYY-MM-DD/*.json` — Layer 1 output, one per session (keyed by a 12-char sha1 of the session path). `*.json.err` is a worker's stderr on failure.
- `findings/YYYY-MM-DD/sessions.txt` (+ `.raw`) — the enumerated session list (`.raw` is pre-self-filter).
- `findings/YYYY-MM-DD/changelog-window.md` — upstream changelog diff for the date (see below).
- `findings/YYYY-MM-DD/run-stats.txt` — self-audit telemetry the aggregator reads.
- `findings/YYYY-MM-DD/touched-projects.txt` — sidecar listing projects whose MEMORY.md L2 edited (drives the optional `claude-memory gc`).
- `cache/claude-code/` — persistent clone of `anthropics/claude-code` for the changelog.
- `logs/run-YYYY-MM-DD.log` — full run log (run.sh tees here). `logs/launchd.{out,err}.log` — launchd's capture.
- `dreams/YYYY-MM-DD.md` (default `~/.claude/dreams/`) — the final report.

Scripts/prompts are symlinked into `~/.claude/autodream/` by `install.sh`, so editing the repo copy takes effect immediately. The installed launchd job is `com.samuelreed.autodream` (not the `com.user.*` example label).

`install.sh` also installs that scheduled job by default (unless `--no-schedule`): it generates the plist with auto-detected label/PATH/dirs (same detection as `autodream-now.sh` — reuses an existing `*autodream*` plist's label if present, else synthesizes `com.<user>.autodream`), then `bootout`+`bootstrap`s it. `RunAtLoad` is false, so install *arms* the schedule without firing a run; the four morning triggers (03:15/06:15/09:15/12:15) match the example plist. It does not run `pmset` (sudo) — it only prints the `pmset repeat wake` recommendation. The `launchd/*.example` file is kept as a hand-editable fallback.

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
1. **cwd isolation + wipe (run.sh)**: both layers now launch from `$AUTODREAM_DIR/work` (`WORK_DIR`), not `$HOME`. Claude maps cwd → `~/.claude/projects/<cwd with / and . → ->`, so any stub lands in the isolated `WORK_BUCKET` instead of the real bucket. `clean_work_bucket` (`rm -rf "$WORK_BUCKET"`) runs before L1 and after L2, so stubs never accumulate. Workers read/write only by absolute path, so cwd is functionally irrelevant — L1 cd's inside the worker subshell; L2 cd's inside a subshell so the change does not leak into the notify/GC steps. **Watch the apostrophes**: the L1 worker body is a single-quoted `bash -c '...'`, so a `'` in a comment there silently breaks quoting (it still passes `bash -n`).
2. **Pruner title predicate (`is_self_title`)**: catches orphan stubs in the real bucket left by runs predating defense 1. Gated on (a) NO user turn anywhere in the file — a real session keeps its title alongside its conversation turns, so it is never a title-only orphan and is never matched — AND (b) the title paraphrases our L1/L2 prompts (session triage → findings, aggregate findings → report). Tuned against the real backlog: spares terminal-tab-title stubs and unrelated headless orphans (e.g. "GCU Rush firmware development").

## Sleep resilience

The overnight failure mode: launchd fires at the scheduled time on a brief wake, the Mac sleeps in and out during the run, workers lose the network and fail (we saw 104/215 fail, L2 exit 1, no report).

launchd facts: `StartCalendarInterval` is anacron-like (runs once on the next wake if asleep at the trigger), NOT vanilla cron. But launchd does not WAKE the Mac (use `pmset repeat wake` for that), and it does nothing about sleep DURING a run.

run.sh handles it with:
- **L1 retry loop** (`dispatch_l1` + `l1_missing_count`): re-dispatches only the sessions still missing a findings JSON, up to `AUTODREAM_L1_ROUNDS` (5), calling `wait_for_network` between rounds. The worker is idempotent, so retries are cheap.
- **L2 retry loop**: retries the aggregator up to `AUTODREAM_L2_ATTEMPTS` (3) until `$REPORT_PATH` is non-empty.
- **Idempotency guard**: at the top of `run()`, if a report already exists for the date it exits in a second (`AUTODREAM_FORCE=1` to rebuild). This is what makes multiple launchd catch-up triggers safe.
- The plist example schedules several morning triggers (03:15/06:15/09:15/12:15) so a failed-overnight date gets retried on later wakes; the guard no-ops the rest.

`net_up` checks reachability of `api.anthropic.com` (any HTTP code beats `000`). Disable the wait with `AUTODREAM_NETCHECK=0` (tests set this).

## Upstream changelog window

`changelog_window()` clones/pulls `anthropics/claude-code` into `cache/claude-code` and runs `git log -p` on `CHANGELOG.md` over `[TARGET_DATE, NEXT_DATE)` (real commit dates; the raw CHANGELOG has no dates, the git history does). The inserted lines go to `changelog-window.md`, which L2 reads for the "Upstream Claude Code changes" report section. Any git failure writes a note and never aborts the run. There is no remote `git blame`; that is why we keep a persistent local clone.

## Self-audit

run.sh writes `run-stats.txt` (raw/excluded/triaged counts, L1 rounds/done/missing/err, elapsed). PROMPT.md's "Autodream self-audit" section reads it and is told to flag self-pollution regressions (excluded count climbing), pipeline-capacity problems (oversized transcripts that blow the token budget), retry/sleep health, and to propose concrete cc-autodream source fixes since the user authors the tool. It proposes; it does not edit cc-autodream source.

## Dream triage (`triage-dream.sh`)

A third, optional pass that turns a finished report into a review-ready worklist. The report *summarizes* the day; triage extracts its actionable items, **grounds each against reality with read-only shell checks** (the aggregator reads transcripts, so its filesystem claims are often stale — e.g. "skill X is absent" when it is invocable, or a proposed allowlist key whose exact name was never verified), and writes `dreams/YYYY-MM-DD.triage.md`: a ranked table (title / type / priority / grounding / ready?) plus per-item detail and *draft* ticket text.

Same blast-radius stance as the aggregator: it **proposes but never acts** — it creates no Linear tickets and edits nothing but its own triage output. Acting stays human-gated.

- `prompts/TRIAGE_DREAM.md` is the prompt; `bin/triage-dream.sh` is the runner (same lean-query flags as L1/L2, but adds `Bash Grep Glob` so it can ground claims read-only — the prompt forbids any mutating command).
- run.sh calls it as a **guarded, non-fatal step after a successful report** (inside the `if [ -f "$REPORT_PATH" ]` block). Set `AUTODREAM_TRIAGE=0` to skip it. It is idempotent (won't re-triage a date with an existing non-empty `.triage.md` unless `AUTODREAM_FORCE=1`), so the morning catch-up triggers never dup-triage.
- Standalone: `~/.claude/autodream/triage-dream.sh` (latest report) or `... 2026-07-14` (a specific date). Model override: `AUTODREAM_TRIAGE_MODEL` (default `claude-opus-4-8`).
- It reuses the same `$WORK_DIR` cwd-isolation + `clean_work_bucket` wipe as run.sh, so its `claude --print` call never leaves an AI-title stub in the real session bucket.

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

How it works: it writes a transient one-shot LaunchAgent (`<base-label>.ondemand`, `RunAtLoad`) into `$AUTODREAM_DIR`, `bootout`s any prior instance, then `bootstrap`s it so launchd runs `run.sh <date>` once and the job exits. `RunAtLoad` is the *only* trigger — it deliberately does not also `kickstart`, or a fast run (e.g. the idempotency no-op) would fire twice. It never touches the scheduled nightly job. Everything is auto-detected: it resolves its own symlink to find `run.sh`, picks the scheduled plist whose `ProgramArguments` reference `run.sh` (not the sibling `*-review` job) to borrow its label namespace, and detects uid + the `claude`/`git` dirs for the agent's PATH — so it is not specific to one user or host. The default date is computed with plain `date -v-1d`, exactly like run.sh (no TZ override). `--force` maps to `AUTODREAM_FORCE=1`; the caller's `AUTODREAM_DIR`/`DREAMS_DIR` are passed through. Progress is in `$AUTODREAM_DIR/logs/run-<date>.log`; the agent's own stdout/stderr go to `logs/ondemand.{out,err}.log`.

When you (the agent) need to kick off a run, prefer this over a background Bash task — fire it, then poll `dreams/<date>.md` instead of holding a long task open.

## Tests

`tests/run-all.sh` drives the real `run.sh` against `tests/mock-claude.sh` (no network, no model). Mock modes: `good` (default), `l1_incomplete` (worker writes nothing), `l1_flaky` (fails first dispatch per session, succeeds on retry). The suite forces `AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0` and a low `AUTODREAM_L1_ROUNDS` so it never sleeps or hits the network. macOS only (BSD `date`/`touch`). Run it after any run.sh/prompt change.

## Gotchas (host environment)

- The user's shell rewrites `grep` to `rtk grep`, which rejects some flags (`-h`); prefer `tail`/`rg`-style invocations when scripting against logs interactively.
- The Claude Code sandbox denies writes under `~/.claude/` (including `rm` of symlinks/findings); those operations need the sandbox disabled.
- Subagent transcripts live in `projects/.../<session>/subagents/agent-*.jsonl` and ARE legitimate sessions to triage; they are not self-pollution.
- `claude --print` worker calls run from cwd `$HOME`, so any transcript they (used to) leave landed in the `-Users-<you>` project bucket.
