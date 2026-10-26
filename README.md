# autodream

Nightly review of your coding-agent sessions. While you sleep it reads yesterday's
transcripts from Claude Code and Oh My Pi (OMP) and leaves you one short report: the
mistakes you keep making, where you lost time, and what's worth remembering.

One repo, one nightly, one report. Each harness is a directory under `adapters/`, so
adding another means writing one directory and touching no shared code. This repo was
`cc-autodream` until 2026-10-03, when the OMP port (`omp-autodream`) folded back into it.

## Why

You have dozens of agent sessions a week. The useful lessons — a wrong
assumption you made twice, a flag that always trips you up, a fix worth pinning to
memory — are buried in transcripts you'll never reread. Each session starts fresh
and rediscovers the same friction.

autodream does the rereading for you. Every night it looks across **all** of
yesterday's sessions, ranks what recurs by frequency × severity (so you see the
patterns, not the one-offs), and writes a dated digest you can skim in a minute. The
highest-confidence, highest-severity findings get pinned to your shared Mnemopi
memory store, so the next session already knows.

This is the cross-session view the built-in per-project auto-memory doesn't give you.
autodream reads full transcripts and tells you what happened, then hands the
lessons to Mnemopi to hold.

## What you get

A report at `~/.claude/dreams/YYYY-MM-DD.md`. See
[`example/2026-05-25.md`](example/2026-05-25.md) for a real one (60 sessions, seven
ranked patterns, five open questions). The shape:

```markdown
# Dream report — 2026-05-29   (21 sessions)

## Top patterns
1. **Editing files before reading them** ×6  ·  high
   Six sessions hit "File has not been read yet". Read-before-Edit isn't sticking.
   → Pin: always Read a file in-session before the first Edit.
2. **$() in Bash triggers permission prompts** ×4  ·  medium
3. **Assuming the host TZ is Pacific** ×2  ·  medium

## Upstream harness changes
- Claude Code v2.x.y added `--foo`; relevant to the rush project's deploy script.
- No releases in the window: Codex, OMP.

## Open questions for the user
1. Add a Read-before-Edit reminder to the project CLAUDE.md?
```

Three ways you actually interact with it:

- **It runs unattended.** A launchd job fires overnight (with morning catch-up
  triggers in case the Mac was asleep). You do nothing.
- **It opens itself.** When a report lands, `notify.sh` writes its open questions to a
  text file and pops it open in your editor — so it's in front of you with morning
  coffee, not waiting to be discovered.
- **It has an interactive suggestion solver.** `review.sh` opens a Claude session
  preloaded with the report and walks the open questions one at a time — restate,
  recommend, then **approve / modify / skip / discuss** — executing the ones you
  approve and logging each decision back into the report.
- **It stays quiet when there's nothing to say.** Most nights the report has no
  open questions, and opening a session just to be told "nothing to do" costs a
  session's tokens to print one line. `review.sh` detects that itself and prints
  the line instead. Same for a report you've already triaged. Anything it can't
  classify still opens the session — a wasted session is cheaper than a buried
  question. `--force` overrides.

## Install

```bash
git clone https://github.com/STRML/autodream ~/git/autodream
cd ~/git/autodream
./install.sh                                              # Claude Code only
./install.sh --adapters claude,omp --l2-engine omp        # both harnesses, OMP writes the report
./install.sh --dry-run --adapters claude,omp              # print what it would do, change nothing
```

`--adapters` lists the harnesses to read, and `--l2-engine` names the one whose CLI runs the
aggregation pass. Pin a model per harness in `config` with `AUTODREAM_L1_MODEL_<NAME>` and
`AUTODREAM_L2_MODEL_<NAME>` (for example `AUTODREAM_L1_MODEL_OMP`). A host with only one harness
installed needs none of this.

This symlinks `bin/*.sh`, `prompts/*.md` and the `adapters/` tree into `~/.claude/autodream/`, creates
`~/.claude/dreams/`, and on macOS installs and bootstraps the nightly launchd
schedule for you (auto-detecting your username, paths, and `claude`/`git` location —
no plist editing). Because the scripts are symlinks, editing the repo copy takes
effect immediately. Requires the CLI of each enabled harness on PATH: `claude` (override with `CLAUDE_BIN`) and `omp` (override with `OMP_BIN`).

Install also detects every Claude config dir on the machine — `~/.claude-nous`,
`~/.claude-ds4`, `~/.claude-sigint`, and any other `~/.claude*/projects` bucket — and
asks whether to index each one (on a non-interactive install it indexes them all and
says so). The choices land in `~/.claude/autodream/root-choices.conf`, and the enabled
set is written to `config` as `SESSION_ROOTS`. You can add or remove a folder later by
editing that file and re-running `./install.sh`.

The schedule fires `run.sh` at 03:15 with morning catch-up triggers (06:15/09:15/12:15)
in case the Mac was asleep; the idempotency guard makes all but the first a one-second
no-op. To skip scheduling and only symlink the scripts:

```bash
./install.sh --no-schedule
```

Install also provisions a second LaunchAgent, `<label>-review`, that opens a cmux triage workspace
when a report has open questions (08:00, 09:15, 12:15, 15:30, 18:15). `./install.sh --no-review`
installs the nightly without it, and removes one an earlier install wrote. The flag applies to that
run only; put `AUTODREAM_REVIEW_AGENT=0` in `~/.claude/autodream/config` (or the environment) to keep
a re-install from provisioning it again.

launchd starts the job with no login shell, so the plist carries a fixed PATH. Install builds it
from the directories of `claude`, `git` and `bash`, plus the CLI of every enabled adapter (`omp`
when `--adapters` includes it, or `OMP_BIN` from the config), and the L2 engine's (`--l2-engine`). A directory under a temp location is
left out and the install says so: a tool shim such as the one cmux puts first on PATH in every
terminal is gone by the time launchd runs the job. `AUTODREAM_EPHEMERAL_DIRS` replaces the list of
temp prefixes (default `$TMPDIR`, `/tmp` and `/var/folders`); set but empty, it turns the check off.
The PATH is written at install time. If you enable an adapter later by editing the config, re-run
`./install.sh`, or set that adapter's `<NAME>_BIN` (`OMP_BIN`) in the config, which `run.sh` reads at
run time and which does not depend on the plist PATH.

launchd won't *wake* the Mac, so to guarantee the 03:15 trigger runs at all, add a
scheduled wake:

```bash
sudo pmset repeat wake MTWRFSU 03:10:00
```

The hand-editable template lives at `launchd/com.user.autodream.plist.example` if you'd
rather install the job yourself.

## Running it by hand

```bash
~/.claude/autodream/run.sh $(date -v-1d +%Y-%m-%d)       # process yesterday
AUTODREAM_FORCE=1 ~/.claude/autodream/run.sh 2026-05-29  # rebuild a date
~/.claude/autodream/review.sh                            # solve the latest report's questions
~/.claude/autodream/review.sh 2026-05-29                 # triage a specific report
~/.claude/autodream/review.sh --force 2026-05-29         # open it even if there's nothing to triage
~/.claude/autodream/pending-triage.sh                    # how many questions are still unanswered, and from which dates
```

### `/autodream` in any Claude Code session

`install.sh` links `skills/autodream` into `~/.claude/skills/`, so `/autodream` works in every project. It does three things:

1. Prints what is waiting: `now triaging 5 issues from dates 2026-10-12 to 2026-10-17`, or `no issues to address!`.
2. Starts yesterday's dream in the background through `autodream-now.sh`.
3. Walks the open questions of every report that has no `## Triage decisions` heading, oldest first. A session logs under `## Triage in progress` and renames the heading after the last question, so a session that stops half way leaves the rest in the queue.

Variants: `/autodream today` runs today so far, and `/autodream force` rebuilds yesterday.

Triage runs the fixes you approve, so permission prompts interrupt it. The skill recommends a `claude --dangerously-skip-permissions` session to avoid them.

Only the last `AUTODREAM_PENDING_DAYS` days (default 14) count, so a report nobody triaged stops nagging after two weeks. To skip the link, pass `install.sh --no-skill`. An install into a directory other than `~/.claude` does not link the skill, because the skill looks for the scripts in `~/.claude/autodream`; set `AUTODREAM_SKILLS_DIR` to link it anyway, and export `AUTODREAM_DIR` (and `DREAMS_DIR`, if the reports are not in its sibling `dreams/`) in the shell that runs Claude Code.

### Which sessions belong to a day

A session belongs to the day its records say, not the day its file was last written.
`run.sh` takes every transcript modified since the day began and keeps the ones holding a
record timestamped inside that local day (midnight to midnight, so a daylight-saving day is
23 or 25 hours). A session resumed after its day closed is therefore still in that day's
rebuild, and stats and triage for the day read only that day's records of a transcript that
spans several (the worker is told it holds a slice). A transcript with no timestamps at all is
placed by its mtime, as before. Files modified since the day began that hold no record in it
are counted as `sessions_out_of_window` in `run-stats.txt`. `AUTODREAM_WINDOW=0` puts
the old mtime-only placement back. `install.sh` links the helper, `bin/session-window.sh`;
until it has run again after an update the runner finds it in the checkout, and a runner that
finds it nowhere reads the old way and says `session_window: off`.

### Long sessions are read in chunks

Layer 1 used to give a worker the first 400 and last 200 lines of an oversized transcript, bookkeeping
records included. On a real 3,479-line session only 36% of the lines were conversation, so the worker
saw about 2% of it. With `AUTODREAM_L1_CHUNK_BYTES=300000` (**off by default**, `0`) a transcript over that many bytes is cleaned
of Claude Code bookkeeping, split at line boundaries, read by one worker per chunk, and merged into the
one findings JSON per session that Layer 2 already reads: the goal from the first chunk, the outcome from
the last, the findings unioned. A chunk answer is untrusted, so only one findings object with no `error`
counts; anything else is redone on its own, and a session is merged only when every chunk answered.

**It costs more.** An oversized session now takes up to `AUTODREAM_L1_MAX_CHUNKS` worker calls (default
8) instead of one, so a night costs up to *oversized sessions x 8* calls plus one per other session, and
a session takes up to 8 x `AUTODREAM_L1_TIMEOUT` of wall time because its chunks run in sequence. On
this host's 2026-10-02 (70 oversized sessions) that was 73 calls instead of 70: two sessions needed more
than one chunk. Over the cap the middle is dropped and counted (`l1_chunks_elided`). `run-stats.txt`
records `l1_chunks`, `l1_chunk_calls`, `l1_chunked_sessions` and `l1_chunks_elided`. Unset or `0`
is the old head/tail view exactly.

`review.sh` exits without opening a session when the report has no open questions
or already carries a `## Triage decisions` section, printing where the report is
and the `--force` line to open it anyway. It reads the
`<!-- autodream:open-questions=N -->` marker that `PROMPT.md` makes the nightly run
emit; reports written before that marker existed fall back to a prose check, and
anything ambiguous opens the session as before.

By default `review.sh` runs the triage session inline in the current terminal —
and if you launch it as a shell script, macOS hands it to whatever app is the
default handler for shell scripts (often iTerm2). To make it open in its own
cmux workspace instead, drop a config file at `~/.claude/autodream/config`
(see `example/config.example`):

```bash
AUTODREAM_TRIAGE_SURFACE=cmux    # inline (default) | cmux
```

### A morning band inside Claude Code (optional)

If you live in Claude Code, `mods/autodream-band/` brings the report to you instead of waiting for you to run
`review.sh`. When the newest report has open questions or a medium/high pattern, a one-line band appears above the
prompt with **Triage**, **View** and **Dismiss**, and `/dream` opens the report's key sections in a pane. **Triage**
(or `/dream triage`) runs `review.sh` in a fresh session in a cmux split beside the one you are in. The mod reads the
same `DREAMS_DIR`, `AUTODREAM_DIR` and `CMUX_BIN` variables as `review.sh`, so it needs no config of its own.

```bash
claude --plugin-dir /path/to/autodream/mods/autodream-band
```

Commands, fallbacks and how to test it are in [`mods/autodream-band/README.md`](mods/autodream-band/README.md).

## Moving from omp-autodream

`omp-autodream` is archived. Its fixes live here (the provider-refusal deferral, bounded workers,
the changelog window, the review popup dedup) and the OMP session reader is `adapters/omp/`.
To move an existing OMP install: unload its launchd jobs, run
`./install.sh --adapters claude,omp --l2-engine omp`, and carry its L1 model over as
`AUTODREAM_L1_MODEL_OMP`. Do not copy its `SESSION_ROOTS` line: the omp adapter finds
`~/.omp/agent/sessions` itself, and a stray root would make the Claude adapter parse OMP files.
The full runbook, with rollback, is in `docs/plans/2026-10-03-omp-adapter.md`.

## Leaving notes for the next run

Notes you leave get answered in the report's **Operator notes** section, with evidence
from that night's sessions — "how often did I actually use /graphify, and did it work?"
comes back as a count and a verdict, not a guess.

From a terminal:

```bash
~/.claude/autodream/autodream-note.sh "evaluate how often /graphify is used"
~/.claude/autodream/autodream-note.sh --expires 2026-10-01 "check the codemaps hook overhead"
```

From anywhere else, including your phone, point autodream at a folder in a synced
vault and drop a markdown file in its inbox:

```bash
# in ~/.claude/autodream/config — quote it, the iCloud path has spaces
AUTODREAM_VAULT_DIR="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault/autodream"
```

The run creates the rest on its own:

| path | what it holds |
| --- | --- |
| `<vault>/inbox/*.md` | drop a note here; one file per note, any filename |
| `<vault>/processed/<date>/` | where a note moves once a report has read it |
| `<vault>/reports/<date>.md` | the nightly report, copied in so you can read it in bed |

Add `expires: YYYY-MM-DD` as YAML frontmatter to a note that should retire itself. A
note is only archived after a report actually read it, so a failed run leaves your
inbox alone, and so does a note you write while a run is in flight.

## Ideas from your X bookmarks

Point autodream at your X bookmarks and the report gains an **Ideas from bookmarks**
section: what you saved, crossed against what you actually worked on that day. A
bookmark that connects to nothing gets left out — the section is the intersection, not
a reading list.

X's official API can't do this (the bookmarks endpoint needs the $200/mo Basic tier),
so this reads the same web endpoint your browser does, with your session cookies:

1. Open x.com in a browser, logged in. DevTools → Application → Cookies → `https://x.com`.
2. Copy the values of `auth_token` and `ct0`.
3. Put them in `~/.claude/autodream/x-credentials`:

```bash
X_AUTH_TOKEN=paste_auth_token_here
X_CT0=paste_ct0_here
```

```bash
chmod 600 ~/.claude/autodream/x-credentials
~/.claude/autodream/x-bookmarks.sh status   # check it took
```

Bookmarks are marked read once a report has covered them, so each one gives you an
idea once. Without that file the feature is simply off. When the cookies expire the
report says so and tells you to re-paste; the run itself never fails over it.

## Pruning finished worktrees and branches

Sessions leave worktrees under `<repo>/.claude/worktrees/` and `<repo>/.worktrees/`, and
branches on GitHub, long after the PR merged. Set `AUTODREAM_PRUNE_ROOTS` and each
nightly run removes the ones that are provably finished. Without it the step does nothing.

```
~/.claude/autodream/config
AUTODREAM_PRUNE_ROOTS="$HOME/git"      # colon-separated, searched 3 levels deep
```

A branch counts as finished when a PR from the same repo into the default branch is merged
and the PR's head commit is the branch tip (squash merges count), or when such a PR was
closed unmerged at least 7 days ago with its head at the tip and the branch fully on the
remote. A repo with no remote at all uses plain ancestry: the tip is already in the default
branch. A repo whose origin is not on GitHub is left alone. Everything else stays, and the
report says why:

| Reason | Meaning |
|---|---|
| `open-pr`, `base-of-open-pr`, `base-of-pr` | a PR for the branch is open, an open PR targets it, or any PR ever targeted it (a long-lived branch) |
| `dirty` | uncommitted or untracked files in the worktree |
| `recent` | a file changed in the last 12 hours (`AUTODREAM_PRUNE_GRACE_MIN`) |
| `rebase-or-bisect`, `locked`, `submodules` | a rebase or bisect is running; `git worktree lock`; the worktree has a `.gitmodules` |
| `protected` | main, master, develop, dev, development, trunk, staging, stage, production, prod, next, canary, gh-pages, release\*, v\<digit\>\*, the default branch, and `AUTODREAM_PRUNE_PROTECT` (colon-separated globs) |
| `ignored-files`, `trash-failed` | ignored files other than build output and no Trash to put them in; `trash` failed |
| `gh-unavailable` | `gh` is missing, logged out or failed, or the repo has `AUTODREAM_PRUNE_OPEN_LIMIT` (200) open PRs or more |
| `cap`, `time-budget` | `AUTODREAM_PRUNE_MAX` removals (25) or `AUTODREAM_PRUNE_BUDGET_SEC` (1200 seconds) used up tonight |

Every removal is written to `~/.claude/autodream/prune-ledger.tsv` before anything changes. The file
is append-only. Per removal it gets an `intent` line (repo, branch, local tip, remote tip, worktree
path, the PR URL that proves it, and the exact commands that put the branch back), then one line per
step, then `complete`. If the ledger cannot be written, nothing is removed. Before the first change
the tip is pinned as `refs/prune-ledger/<run id>/<branch>` in the repo, so `git gc` cannot prune it,
and a failed pin also means nothing is removed. To undo a removal, run the `recover` column of its
`intent` line (it works in bash, zsh and fish):

```
git -C <repo> branch <branch> <tip> ; git -C <repo> push origin <tip>:refs/heads/<branch>
```

The push half is there only when the branch existed on the remote. Pins cost a few bytes each. When
you no longer need to undo anything, delete them with
`git for-each-ref --format='%(refname)' refs/prune-ledger | xargs -n1 git update-ref -d`.

The remote branch is deleted by a push that names the proven commit as the lease, so a push
that landed after the fetch makes GitHub refuse the delete. The worktree directory goes to
the Trash (`AUTODREAM_PRUNE_TRASH=0` deletes it with git instead). Read the result in
`findings/<date>/worktree-prune.md`, or try it first with
`~/.claude/autodream/prune-worktrees.sh --dry-run <out-dir>`. The step needs `gh`, `jq` and
`git`, and a failure in it never costs the report: every network call and `trash` has a timeout (`AUTODREAM_PRUNE_CALL_SEC`, 60), and a hard stop at the budget plus `AUTODREAM_PRUNE_KILL_SLACK` (120) writes the report and exits.

## Suggesting a triage

When tonight's sessions ran in a GitHub repo with a pile of untriaged issues, the report says so under
"Repos to triage" and names the checkout to run `/triage` in. The runner counts, because the aggregator
has no shell or `gh`; the aggregator only copies the table.

```
sessions' cwds ─► repo root + owner/repo ─► gh issue list ─► untriaged >= 3 ─► cooldown ─► report
                  (worktree = its repo)      (open, 200 max)  (no state label    (7 days, or
                                                              or needs-triage)   +3 issues)
```

An issue is untriaged when it has none of `needs-info`, `ready-for-agent`, `ready-for-human` and
`wontfix`, or when it carries `needs-triage`. A repo that was never triaged has none of those labels, so
all its open issues count and its first triage gets suggested. Skipped, with the reason in
`findings/<date>/triage-candidates.tsv`: a removed or non-git working directory, an origin that is not on
GitHub, issues turned off, a repo you cannot triage in (read-only access, so an upstream project) or an archived one, and any `gh` failure (the step never fails the run). A repo already suggested
in the last `AUTODREAM_TRIAGE_COOLDOWN_DAYS` (7) days is held back unless its untriaged count grew by
`AUTODREAM_TRIAGE_GROW` (3). The record is `~/.claude/autodream/triage-suggested.tsv`. A suggestion never
counts as an open question. It is on by default and only reads; set `AUTODREAM_TRIAGE_SUGGEST=0` to turn it off.

## Running long jobs

A full run usually takes more than 10 minutes. If you're kicking it off from
something that kills long jobs (a Claude Code background task, a flaky ssh session),
use `autodream-now.sh` — it hands the run to launchd, which has no time cap and keeps
going after you disconnect:

```bash
~/.claude/autodream/autodream-now.sh                    # yesterday, right now
~/.claude/autodream/autodream-now.sh 2026-05-29 --force # a specific date, rebuild
~/.claude/autodream/autodream-now.sh 2026-05-29 --watch # follow the log until the report lands
```

## How it works (short version)

Two layers: a cheap per-session pass (`claude-haiku-5-5`, effort `high`; set `AUTODREAM_L1_EFFORT` to `low|medium|high|xhigh|max|off`) extracts structured findings from each
transcript, then a single smarter pass (`opus`) ranks them across the whole day and
writes the report. It also diffs the changelog of each harness you work across (Claude
Code, Codex, OMP) over the day, so the report can flag releases that change how you work.
Each source has its own cache and its own section, so one unreachable remote never
silences the others. Override the watched set with `AUTODREAM_CHANGELOG_SOURCES`.

Everything lives on disk (findings JSON, the report, run logs, stats) and every step
is idempotent, so you can rerun any date. Configuration knobs are documented in
`bin/run.sh`'s header.

Reading sessions is done through a **harness adapter**, so the runner does not know
which agent produced a transcript. Two ship today, `claude` and `omp`; the seam is what lets a
third arrive without forking the pipeline.

- `adapters/<name>/` — one directory per harness: `manifest.json` (data, read with
  `jq`, never sourced), `adapter.sh` (enumerate, normalize, project, stats, slim,
  is-self, skills-inventory), and `facts.md` (the remedy vocabulary for that harness, so
  a fix is phrased in terms the harness actually has) → `adapters/claude/facts.md`
- `bin/adapters.sh` — adapter discovery, identity validation and containment
- `bin/lib-project.sh` — the canonical project encoding and artifact hash every
  adapter must agree on
- `bin/preflight.sh` — the shared-dependency gate, run before anything is enumerated

For the internals — data flow, file map, state layout, environment overrides, the
lean-query pattern, the adapter contract, and the "don't eat your own tail"
self-pollution defenses — see **`codemaps/architecture.md`**, **`CLAUDE.md`**, and
**`docs/design/unify-harness-adapters-2026-08-23.md`** for the subcommand table
the adapter contract is defined by.

## Caveats

- macOS-only as written (BSD `date`, `launchd`, `osascript`/`open`). The core pipeline
  is portable; the scheduling and notify bits are mac-specific. The morning
  open-questions file opens with your default `.md` app; set `AUTODREAM_OPEN`
  (e.g. `subl`, `code -g`, `open -a Obsidian`) to pick a specific editor.
- Runs in `bypassPermissions` mode (workers Write findings). Don't run it in a
  shared environment.
- The first run clones the watched harness repos for the changelog window (the OMP one
  is a sparse, blob-less clone of one file); it degrades gracefully with no git/network.

## License

MIT — see LICENSE.
