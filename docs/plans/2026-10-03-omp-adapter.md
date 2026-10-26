# Plan 2: the OMP adapter, and the omp-autodream work cc-autodream lacks

Date: 2026-10-03
Status: Plans 2 and 3 merged, Plan 4 preparation merged (replay, dry-run install, runbook). The cutover itself is not started and needs Sam.
Design: `docs/design/unify-harness-adapters-2026-08-23.md` (approved), Migration steps 2, 3 and the facts half of 4.
Decision (Sam, 2026-10-03): cc-autodream survives and becomes `STRML/autodream`. omp-autodream is archived after the cutover.

## What this plan finds

Plan 1 built the seam, but the divergence between the repos is larger than the design doc counted. At the merge base (`e231314`, 2026-08-07) the two runners were one codebase. Since then omp-autodream gained 60 commits and cc-autodream 15. Measured against `origin/main` of each:

| Feature | cc-autodream | omp-autodream |
| --- | --- | --- |
| adapter seam, `adapters/claude`, `_fixture` | yes | no |
| Mnemopi pins, question streaks, drift check | yes | streaks and drift only |
| OMP session linearizer, OMP stats, skills inventory | no | stats and inventory only; no linearizer |
| `failure-class.sh`, provider-refusal classification | no | yes |
| network-outage deferral, `l1-netdown.txt` | no | yes |
| bounded L1 workers (`AUTODREAM_L1_TIMEOUT`), auth warmup, circuit breaker | no | yes |
| `l1-no-advisor.yml` overlay (mnemopi recall off, advisor off) | no | yes |
| launchd label ownership (`scheduler-label.sh`) | no | yes |
| three-harness changelog window | no | yes |
| review.sh cmux popup dedup (claim and confirmed token) | partial | yes |

The unified repo is not "cc plus an adapter". It is cc's architecture plus about 35 generic runner fixes that landed only in omp between 2026-09-04 and 2026-09-15. Plan 2 therefore ships in two parts: the adapter itself, then the ports.

## Scope of PR 1 (this change)

`adapters/omp/` with the five required subcommands plus `is-self` and `skills-inventory`:

| Subcommand | Implementation |
| --- | --- |
| `enumerate` | `find` over the session root, NUL-delimited; includes nested child sessions |
| `normalize` | `linearize.sh`, written from scratch; fails closed |
| `project` | header `cwd` (or `autodream_meta.cwd` of a normalized copy), resolved |
| `stats` | `stats.sh` (omp-autodream's stats plus `is_advisor` and `nested`), through an atomic temp |
| `slim` | shared `bin/slim-transcript.sh`, which already strips OMP `toolResult` and `toolCall` payloads |
| `is-self` | shared `bin/prune-self-sessions.sh`, now matching OMP's `{"type":"message","message":{"role":"user"}}` shape |
| `skills-inventory` | `skills-inventory.sh` from omp-autodream; prints `name<TAB>description` |

The adapter is not enabled by the runner until per-session dispatch is adapter-aware: `run.sh` already logs and skips any adapter other than `claude`.

Design credit: `STRML/cc-autodream#47` (closed) worked out the tree semantics and the fail-closed rule. `linearize.sh` is a rewrite with its own fixtures, as the design requires.

### Two deviations from the design doc, both small

1. `skills-inventory` prints a second TAB-separated column. The claude adapter prints the name alone. A consumer that wants names takes field 1. The L2 prompt needs the descriptions to decide whether a skill already exists.
2. The L1 flags in `manifest.json` are the ones omp-autodream actually runs (`--approval-mode yolo --no-session --tools=Read,Write`), not the ones in its stale `PORT_CONTRACT.md` (`--permission-mode bypassPermissions --no-session-persistence`).

## Failure matrix

| Condition | Where | Behavior | Test |
| --- | --- | --- | --- |
| malformed JSON line | normalize | exit 4, no output, no temp | `tests/adapter-omp.sh` |
| `parentId` with no entry | normalize | exit 4 | same |
| cycle including the root's child | normalize | exit 4 (chain does not reach a root) | same |
| cycle excluding the root | normalize | exit 4 | same |
| entry with no string `id` | normalize | exit 4 | same |
| Claude transcript, empty file, no session header | normalize | exit 2 | same |
| unreadable input, missing arg, directory destination | normalize | exit 1, nothing planted | same |
| header only, legacy file with no title slot, blank lines, spaces in path | normalize | exit 0 | same |
| abandoned branch | normalize | dropped, counted in `dropped` | same |
| advisor child, task subagent child, parent | normalize, stats | `nested` and `is_advisor` from the path | same |
| `my__advisor.jsonl` | stats | not an advisor (stem anchored) | same |
| header with no `cwd`, `cwd` containing a quote | project | no project / survives escaping | same |
| omp-only host | enumerate | omp sessions enumerated, claude root absent is not an error | contract + `adapters.sh` |
| claude-only host | runner | adapter `omp` accepted by the loader, logged and skipped | existing `run-all.sh` |
| both | runner | claude only until PR 4; omp enabled by PR 4 | PR 4 |
| same path claimed by two adapters, hash collision | union | existing `sessions_duplicate_path`, `sessions_hash_collision` | existing |
| newline, tab, quote, backslash in a path | runner | existing `sessions_rejected_path` | existing |
| empty or missing skill roots | skills-inventory | valid empty inventory, exit 0 | `tests/adapter-omp.sh` |

Mutation checks run against three deliberate defects (leaf taken from the first entry, root check removed, advisor stem unanchored); each is caught.

## PR sequence and status (2026-10-03)

| PR | Content | State |
| --- | --- | --- |
| 1 | `adapters/omp`, linearizer with fixtures, omp stats, skills inventory, OMP-aware `is-self`, contract run for omp, CI wiring | merged, https://github.com/STRML/cc-autodream/pull/81 |
| 6 | launchd label ownership, guarded install, hashed on-demand label, adoptable template | merged, https://github.com/STRML/cc-autodream/pull/82 |
| 7 | three-harness changelog window; also a force-pushed remote is followed, dedupe is scoped to the release, the sparse step works | merged, https://github.com/STRML/cc-autodream/pull/83 |
| 4a | overlap pass drops advisor sidecars (omp-autodream #16, `bin/overlap-stats.sh`) | merged, https://github.com/STRML/cc-autodream/pull/84 |
| 8a | `review.sh` cmux popup dedup by report digest, `tests/review-cmux.sh` | merged, https://github.com/STRML/cc-autodream/pull/85 |
| 2 | L1 worker hardening: stdout and exit-code capture into the `.err`, `failure-class.sh` and oversized-gate classification, bounded workers (`AUTODREAM_L1_TIMEOUT`), auth warmup, circuit breaker, network-outage deferral, no stub on a permanent provider refusal (omp-autodream #37) | merged: https://github.com/STRML/cc-autodream/pull/90, https://github.com/STRML/cc-autodream/pull/92, https://github.com/STRML/cc-autodream/pull/93 |
| 4 | per-session dispatch: source sidecar, per-adapter L1 engine (`l1-argv`), stats and normalize through the adapter, `omp` enabled behind `AUTODREAM_ADAPTERS` | merged: https://github.com/STRML/cc-autodream/pull/87, https://github.com/STRML/cc-autodream/pull/89, https://github.com/STRML/cc-autodream/pull/94 |
| 5 | skill fields measured and enforced, skills inventory and per-source facts for L2, per-harness triage addendum with the advisor sidecar schema | merged: https://github.com/STRML/cc-autodream/pull/95, https://github.com/STRML/cc-autodream/pull/96, https://github.com/STRML/cc-autodream/pull/97 |
| 6b | the review LaunchAgent (cmux popup job) that omp's `install.sh` provisions | merged: https://github.com/STRML/cc-autodream/pull/100 |
| 3 | Plan 3: L2 is read-only (Glob, Read), report and pin block on stdout behind `AUTODREAM_REPORT_END`, runner-written `pins.jsonl`, exit status only for a validated delivery; L2 engine and model chosen per adapter (`AUTODREAM_L2_ENGINE`), `l2-argv` | merged: https://github.com/STRML/cc-autodream/pull/98, https://github.com/STRML/cc-autodream/pull/99 |
| C1 | `install.sh --dry-run`, `--adapters`, `--l2-engine` | merged: https://github.com/STRML/cc-autodream/pull/101 |
| C2 | `tests/replay.sh` (artifacts and ingest modes), results and the cutover runbook below | https://github.com/STRML/cc-autodream/pull/102 |

Merged work follows the plan's own rule: each PR passed `omp-review.sh` on its final commit and CI. The review found real defects in three of the five before merge: a blocking P1 in the adapter (two files held one advisor rule), a blocking P1 in `autodream-now.sh` (a run from the checkout adopted `bin/` as the install dir), and in the changelog port a window-wide dedupe that dropped repeated headings, which led to finding that a force-pushed fork made the OMP pull fail every night.

## Why PR 2 is not a port

The 35 generic fixes cannot be lifted commit by commit. A trial `git cherry-pick` of the first one conflicts in six files, and a trial `git merge omp/main` leaves 61 conflict hunks in 12 files that look mechanical but are not. They are the same decision seen in different places:

- **The L2 delivery protocol differs.** omp-autodream's L2 has no `Write` tool: it prints the report on stdout, `run.sh` slices at an `AUTODREAM_REPORT_END` sentinel, and `report_complete` requires it. cc-autodream's L2 still runs `Glob Read Write Edit`, writes the report file itself, and writes `pins.jsonl` for the Mnemopi pin step (#68). The design doc wants stdout and a sentinel, with pins in a block after it, but cc has not built that, so every L2-touching hunk of the merge picks a side of an unmade decision.
- **Engine invocations are woven through the omp additions.** The warmup, the worker, the version stamp and the fatal "omp not found" check all name `OMP_BIN` and omp flags. In cc they have to become "the L1 engine of this session's adapter". The adapter manifest already lists the flags; nothing builds the command from it yet.
- **The failure classifier reads a `.err` layout the cc worker does not write.** `failure-class.sh` expects the worker's exit code, its stdout and a log tail, which is the first thing the hardened `dispatch_l1` adds.

So PR 2 and PR 4 were one piece of work, the rewrite of `dispatch_l1` around an adapter-built engine command. The four decisions it needed were made (coordinator, 2026-10-03) and implemented:

1. **L2 delivery.** Stdout plus sentinel plus a pin block (Plan 3), no file-based L2: https://github.com/STRML/cc-autodream/pull/98.
2. **Where the engine command comes from.** The `l1-argv` adapter subcommand, NUL-delimited, claude byte for byte: https://github.com/STRML/cc-autodream/pull/87 and https://github.com/STRML/cc-autodream/pull/89.
3. **L2 engine.** `AUTODREAM_L2_ENGINE=<adapter>`, default the first enabled adapter: https://github.com/STRML/cc-autodream/pull/99.
4. **Model per adapter.** `AUTODREAM_L1_MODEL` stays an override, each manifest carries a default, and `AUTODREAM_L1_MODEL_<NAME>` pins one adapter; run-stats records `l1_model_<adapter>` and `l2_engine`/`l2_model`: https://github.com/STRML/cc-autodream/pull/87, https://github.com/STRML/cc-autodream/pull/99.

## Cutover notes for Plan 4 (found on this host, 2026-10-03)

- Both installs have scheduled jobs and review jobs: `com.samuelreed.autodream`, `com.samuelreed.autodream-review`, `com.samuelreed.omp-autodream`, `com.samuelreed.omp-autodream-review`. Cutover has to unload the omp pair or every report opens two triage popups.
- `~/.claude/autodream` carries a `backfill.sh` and a `com.samuelreed.autodream.backfill` job that are not in this repo. Decide whether they belong in `bin/` before the install is repointed.
- `~/.omp/agent/autodream` symlinks into `~/git/oss/omp-autodream`; `~/.claude/autodream` symlinks into this checkout. The live nightly runs whatever is checked out, so a merged PR changes the cc nightly once the main checkout is fast-forwarded.
- omp-autodream PR 16 (advisor sidecar schema) is merged there; its `overlap-stats.sh` change is ported (https://github.com/STRML/cc-autodream/pull/84), its prompt text is not.

## omp-only commits (60, from `e231314..omp/main`)

Status: **in cc** already present; **PR n** ported by that PR (the plan's numbering, see the table above for the merged PR URLs); **ported** and **n/a** carry their reason. No row is left unverified.

| Commit | Subject | Status |
| --- | --- | --- |
| `216c791` | permanent provider refusal defers the date (#37) | ported: https://github.com/STRML/cc-autodream/pull/93 |
| `dfd39a1`, `7f89556`, `b67c2f1`, `5f7ddaa` | question-streaks `clear` fixes | in cc (#71, #75) |
| `1d11e03`, `b72f0e4`, `cb76639`, `600e6dd`, `4eea84d`, `764d77d` | question-streaks watermark, lock, escalation | in cc (#71, `4e5aaf5`) |
| `3c2215f`, `8166f38`, `d905ad7` | docs for streaks and the drift check | in cc (CLAUDE.md carries both) |
| `e1e8f10`, `232c94c` | sibling drift check | in cc (`4b19c8c`); retires with the sibling |
| `d771d59` | X 16-character chunk hash | in cc (`7f11f64`) |
| `896a971` | drop the rtk grep gotcha | in cc (`c2a5eee`) |
| `fa0a317`, `9210dd9`, `acff8a8`, `05d6ead`, `cdfdf3b`, `6ca1584`, `b19ec84`, `676d9b0`, `a9912d4`, `7eda1a8` | `failure-class.sh` and the oversized gate classification | PR 2 |
| `16a3bf5`, `33bf9b1`, `cd309b6` | unmeasured sidecars and skills | PR 2 (sidecar rules) and PR 6 (label parts) |
| `fa5a430`, `d63cf3e` | no route to the API defers the date | PR 3 |
| `d6438d5` | six nights of empty stubs: warmup, breaker; three-harness changelogs | PR 3 (warmup, breaker) and PR 7 (changelogs) |
| `1ff1b59` | mnemopi first-turn recall killed workers | PR 3 (overlay) |
| `e95084d` | bound each L1 worker (#17) | PR 3 |
| `36282e5` | resolve omp from PATH, record the build (#18) | PR 4 (engine resolution per adapter) |
| `4507066`, `0129fc0` | changelog cache guards, warmup wants `ok` | PR 7 and PR 3 |
| `e95e2f2` | launchd ownership reads every plist, warmup timeout validated | PR 6 and PR 3 |
| `bbb4d4b`, `e70492a`, `2ef3031`, `ec829a4`, `aacbc0a`, `1ee66e4` | launchd label ownership, install hardening, stale paths | PR 6 |
| `d1d0cfb` | macOS runners end TMPDIR with a slash | PR 6 (test) |
| `387e7bc`, `87e2588`, `10e1c52`, `90e535b`, `bc9ba5a`, `c8303f6`, `1fef17d`, `3c7587f` | review.sh cmux popup panel rounds 1 to 7 | PR 8 |
| `c16318a` | close out the /code-review sub-80 cleanups (#8) | ported: its `skills-inventory.sh` change (no `-maxdepth` cap, `ignoredSkills` matches directory names) is in `adapters/omp/skills-inventory.sh`, which differs from omp's script by one usage line (verified with `diff`); its `PORT_CONTRACT.md` tool-grant correction is n/a, because the contract is replaced by the adapter docs |
| `9db799d` | stop L2 memory writes; broaden the skill-coverage walk for OMP (#3) | ported in part. Memory: n/a, cc routes pins to Mnemopi (#68), and L2 now cannot write at all (https://github.com/STRML/cc-autodream/pull/98). Skill walk: ported as the adapter-built `skills-inventory.txt` (https://github.com/STRML/cc-autodream/pull/96). The exit-non-zero-on-a-delivered-nothing-night fix (`abda904`) is in https://github.com/STRML/cc-autodream/pull/98. The L1 wall-time log and the self-locating install dir (`4f31240`, `8d739b7`) are in https://github.com/STRML/cc-autodream/pull/91 and https://github.com/STRML/cc-autodream/pull/85 |
| `790d1b6` | README rewrite for the OMP port | n/a: it documents omp-autodream as a product; the unified README is written at the rename, and the facts it carried live in `adapters/omp/facts.md` and CLAUDE.md |
| `6c41c46` | port cc-autodream to OMP | PR 1 and PR 4 |
| `0dffef5` | retire `compliance_markers` telemetry | ported for omp, not for claude. cc `session-stats.sh` still computes `compliance_markers` for claude, whose rule files still emit the markers; `adapters/omp/stats.sh` never did, and `adapters/omp/triage.md` tells omp workers not to emit it (https://github.com/STRML/cc-autodream/pull/97) |

Not a commit but part of the work: omp-autodream #16 (advisor sidecar schema, open, being merged into omp-autodream first) lands in PR 4, and its `SESSION_TRIAGE.md` and `PROMPT.md` text lands in PR 5.

## Replay results (2026-10-03)

`tests/replay.sh` has two modes (see its header). Both ran against this host's real archives, read-only.

Artifacts mode over every archived findings directory: **179 directories (48 from omp-autodream, 131 from cc-autodream), 0 failed.** The WARNs are the archive's, not the code's: directories that hold no findings (nights that never got past enumeration), a run-stats file that predates a counter (skills, failure classes, gated), and one archived claude file from the tool's first day (2026-05-28) that lacks a `findings` array and that the current runner would not accept.

Ingest mode, the whole runner over a staged copy of the real sessions of one date with the engines replaced by `tests/mock-claude.sh`, compared with the run-stats of the nightly that handled that date:

| Source | Date | Sessions (replay / archive) | Gated | Oversized | Overlap events | Result |
| --- | --- | --- | --- | --- | --- | --- |
| omp | 2026-08-20 | 20 / 20 | 4 / 4 | 14 / 14 | 31 / 80, explained | pass, 2 warnings |
| omp | 2026-09-04 | 4 / 4 | 0 / 0 | 4 / 4 | 2 / 2 | pass, 0 warnings |
| omp | 2026-09-13 | 3 / 3 | 0 / 0 | 3 / 3 | 3 / 15, explained | pass, 2 warnings |
| omp | 2026-09-30 | 151 / 151 | 70 / 70 | 25 / 25 | 336 / 1399, explained | pass, 2 warnings |
| claude | 2026-06-15 | 64 / 66 | n/a | n/a | n/a | pass, 6 warnings (the archive predates the counters) |
| claude | 2026-09-30 | 116 / 117 | 38 / 39 | 72 / 72 | 1150 / 1156 | pass, 5 warnings |

Every omp session was read by its adapter (none refused by the linearizer), every session got a stats sidecar and a findings JSON, no worker errored, and the runner exited 0 with a delivered report. Gated and oversized counts match exactly for omp, which is the check that the linearizer, the omp stats and the noise gate agree with omp-autodream's on real data.

Two differences are explained, and the replay says so on its WARN lines:

- **Overlap events read lower for omp.** The archived sidecars carry no `is_advisor` flag, so the archived runner counted each advisor sidecar against its parent. The unified runner flags advisors from the path and the overlap pass drops them (omp-autodream #16, https://github.com/STRML/cc-autodream/pull/84): 7 advisor sidecars on 2026-08-20, and 72 of the 151 session files on 2026-09-30 (the replay's WARN line names the count it measured).
- **2026-09-13 and the claude counts moved.** The 09-13 archive directory was rebuilt in place and holds sidecars from earlier runs, and one claude session of 2026-09-30 is outside the `~/.claude/projects` root the replay used (the archive also scanned the other `~/.claude*` roots).

## Cutover runbook (not run; every step touches the live install and needs Sam)

Rehearse each step first: `./install.sh --dry-run ...` prints what it would do and changes nothing, and `tests/replay.sh` gives the baseline to compare the first real night against. Nothing below renames or archives a repository: that is a separate decision after one clean week on the unified install.

Decide first:

- Which report directory the unified install writes to. omp writes `~/.omp/agent/dreams`, claude writes `~/.claude/dreams`. `DREAMS_DIR` is one value, and the review popup, the vault publish and `question-streaks` all key off it. Recommended: `~/.claude/dreams`, because the claude-side history is longer and the cc nightly already owns it. Copy or link the omp reports in once.
- The L2 engine. Recommended `omp` with `anthropic/claude-opus-5` (omp-autodream's setting), set once by `--l2-engine omp`; claude stays the default for a host that has no omp.

Checklist:

1. Merge state: the main checkout `~/git/oss/cc-autodream` is on `main` at `origin/main` (the cc nightly runs whatever is checked out).
2. Baseline: `tests/replay.sh --ingest omp ~/.omp/agent/sessions <yesterday>` and the same for `claude ~/.claude/projects <yesterday>`; both must report 0 failed.
3. Rehearse: `./install.sh --dry-run --adapters claude,omp --l2-engine omp ~/.claude` and read the plists it prints. Confirm the labels (`<nightly>` and `<nightly>-review`) and that no foreign job holds them.
4. Quiet the omp pair so a night is not processed twice and no report opens two triage popups: `launchctl bootout gui/$(id -u)/com.samuelreed.omp-autodream` and `.../com.samuelreed.omp-autodream-review`. Keep their plists on disk until the first clean night.
5. Install the unified runner over the cc install: `./install.sh --adapters claude,omp --l2-engine omp` (this writes `AUTODREAM_ADAPTERS` and `AUTODREAM_L2_ENGINE` into `~/.claude/autodream/config`, regenerates the nightly and review plists, and re-arms them).
6. Carry the omp host settings into `~/.claude/autodream/config`: `AUTODREAM_L1_MODEL_OMP=neuralwatt/glm-5.3-flash` (the omp config line `AUTODREAM_L1_MODEL=...` today), and `AUTODREAM_L2_MODEL_OMP=anthropic/claude-opus-5` if it should differ from the manifest default. Leave `AUTODREAM_L1_MODEL` unset so claude keeps its own default. Do not copy omp's `SESSION_ROOTS=/Users/.../.omp/agent/sessions` line: `SESSION_ROOTS` belongs to the claude adapter, and pointing it at omp sessions would parse them as claude transcripts. The omp adapter finds its own root from its manifest.
7. Repoint the omp install directory at the same code so `autodream-now.sh`, `autodream-note.sh` and any habit that uses the omp path keep working: replace the per-file symlinks under `~/.omp/agent/autodream` with one link to `~/.claude/autodream` (move the old directory aside first, never delete it).
8. First night: run `~/.claude/autodream/autodream-now.sh <yesterday> --watch`. Check `run-stats.txt`: `adapters_enabled: claude,omp`, `l2_engine: omp`, one `l1_model_<adapter>` per source, `l1_findings_with_error: 0`, `skills_unmeasured` small.
9. `com.samuelreed.autodream.backfill` and `~/.claude/autodream/backfill.sh` belong nowhere in the repo. The script is a one-shot with a hard-coded list of dates (2026-08-28 to 2026-09-03) written for one incident, and its job has `RunAtLoad`. Unload the job (`launchctl bootout gui/$(id -u)/com.samuelreed.autodream.backfill`) and leave the script out of `bin/`. A serial date-range backfill is worth having as a generic tool (`autodream-now.sh` takes one date), but that is its own change.
10. After one clean week: archive omp-autodream and `autodream-merge` with pointers, rename `STRML/cc-autodream` to `STRML/autodream`, and write the unified README. Not before.

Rollback, any time before step 10: `launchctl bootstrap` the omp plists you kept, restore the moved-aside `~/.omp/agent/autodream`, and re-run `./install.sh --no-schedule` from the previous checkout of this repo.

## Remaining after this plan

- Plan 4 proper: run the cutover runbook above, then the rename and the archive. Not started, and not to be started without Sam: it touches the live install.

## Progress (updated after each merged PR)

- Merged: PR 1 (omp adapter, https://github.com/STRML/cc-autodream/pull/81), launchd label (https://github.com/STRML/cc-autodream/pull/82), changelogs (https://github.com/STRML/cc-autodream/pull/83), overlap (https://github.com/STRML/cc-autodream/pull/84), review cmux (https://github.com/STRML/cc-autodream/pull/85, https://github.com/STRML/cc-autodream/pull/88), decisions (https://github.com/STRML/cc-autodream/pull/86), engine seam (https://github.com/STRML/cc-autodream/pull/87, https://github.com/STRML/cc-autodream/pull/89), failure classification (https://github.com/STRML/cc-autodream/pull/90), notes path (https://github.com/STRML/cc-autodream/pull/91), bounded workers (https://github.com/STRML/cc-autodream/pull/92), outage deferral (https://github.com/STRML/cc-autodream/pull/93), omp dispatch (https://github.com/STRML/cc-autodream/pull/94), skill fields (https://github.com/STRML/cc-autodream/pull/95), L2 inputs (https://github.com/STRML/cc-autodream/pull/96), triage addenda (https://github.com/STRML/cc-autodream/pull/97), read-only L2 (https://github.com/STRML/cc-autodream/pull/98), L2 engine (https://github.com/STRML/cc-autodream/pull/99), review agent (https://github.com/STRML/cc-autodream/pull/100), install dry-run (https://github.com/STRML/cc-autodream/pull/101).
- In review: the replay harness, this results section and the runbook (https://github.com/STRML/cc-autodream/pull/102).
- Next: the cutover, with Sam.
