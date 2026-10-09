# Codemap — architecture

Token-lean map of cc-autodream. See `CLAUDE.md` for the decisions and gotchas behind it.

## Data flow

```
launchd (com.samuelreed.autodream, several morning triggers)
      │
      ▼
bin/run.sh  TARGET_DATE
      │
      ├─ idempotency guard: report exists for date? → exit 0 (unless AUTODREAM_FORCE=1)
      │
      ├─ Claude *.jsonl → prune-self-sessions.sh --filter → sessions.txt
      ├─ OMP root JSONLs + Codex rollout JSONLs (mtime window)
      │     └─ exclude Codex subagents/Claude Code-vscode companions; normalize-transcript.py → work/normalized/<date>/
      │          source-map.jsonl tracks original path/cwd/harness; skip no-user sessions
      ├─ L1 retry loop (AUTODREAM_L1_ROUNDS):
      │     dispatch_l1: xargs -P FANOUT → claude --print (haiku, lean flags) per session
      │       reads session .jsonl, writes findings/<date>/<sha>.json   (idempotent; .err on fail)
      │     l1_missing_count → wait_for_network → retry the still-missing
      │
      ├─ rewrite findings session_path/harness/project from source map (not model guesses)
      ├─ run-stats.txt          (self-audit telemetry)
      ├─ changelog_window()      → findings/<date>/changelog-window.md  (git log -p on claude-code CHANGELOG)
      │
      ├─ L2 retry loop (AUTODREAM_L2_ATTEMPTS):
      │     claude --print (opus, lean flags) with PROMPT.md
      │       reads all findings/<date>/*.json + changelog-window.md + run-stats.txt
      │       writes dreams/<date>.md; may edit project MEMORY.md (📌) + touched-projects.txt
      │
      ├─ notify.sh → open-questions inbox file (Sublime)
      └─ optional: claude-memory gc per touched project
```

## Files

| File | Role |
|---|---|
| `bin/run.sh` | orchestrator: guard, enumerate+filter, L1 retry loop, changelog, L2 retry loop, notify, gc |
| `bin/autodream-now.sh` | run NOW via a transient one-shot launchd agent (escapes the ~10-min cap on bg tasks/ssh). `[DATE] [--force] [--watch] [--dry-run]`. RunAtLoad only (no kickstart → no double run); picks the scheduled plist that runs `run.sh` for its label namespace |
| `bin/normalize-transcript.py` | streaming OMP/Codex → Claude-shaped JSONL with source metadata and bounded tool output |
| `bin/prune-self-sessions.sh` | self-session predicate (single source of truth): list / `--delete` / `--filter` |
| `bin/notify.sh` | extract "Open questions" → inbox file in Sublime |
| `bin/review.sh` | interactive morning triage (`claude --append-system-prompt <report>`); `AUTODREAM_TRIAGE_SURFACE=cmux` (config/env) launches it in its own cmux workspace instead of inline |
| `prompts/SESSION_TRIAGE.md` | L1 prompt: per-session JSON schema |
| `prompts/PROMPT.md` | L2 prompt: report sections incl. Upstream changes + Autodream self-audit, memory rules |
| `tests/run-all.sh` | integration tests vs `mock-claude.sh` (offline) |
| `tests/mock-claude.sh` | stand-in claude; modes: good / l1_incomplete / l1_flaky |
| `launchd/com.user.autodream.plist.example` | schedule (multi-trigger catch-up + pmset note) |
| `install.sh` | symlink scripts/prompts into `~/.claude/autodream/`; by default also generates + bootstraps the nightly launchd schedule (auto-detected label/PATH/dirs; `--no-schedule` to skip) |

## Key invariants

- L1 worker is **idempotent**: a session with a non-empty `<sha>.json` is skipped. Failures leave no JSON (retry target); deterministic errors (unreadable file) write a JSON (done).
- A `dreams/<date>.md` exists only after a successful L2 → it is the "done" signal for the idempotency guard.
- `prune-self-sessions.sh` matches only the FIRST user turn against autodream's own prompt framing → human sessions about autodream are not false positives.
- claude is always invoked with the lean flags + subscription auth; never `--bare`/`CLAUDE_CODE_SIMPLE` (breaks auth).

## Environment overrides

All optional; full list (with defaults) is documented in `bin/run.sh`'s header. The ones you reach for most:

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_BIN` | `$HOME/.local/bin/claude` | path to `claude` CLI |
| `PROJECTS_DIR` | `$HOME/.claude/projects` | where Claude Code stores session JSONLs |
| `AUTODREAM_HARNESSES` | `claude,omp,codex` | select source harnesses |
| `AUTODREAM_LIST_ONLY` | `0` | `1` prints per-harness scan counts and stops before L1 |
| `AUTODREAM_DIR` | `$HOME/.claude/autodream` | scripts + runtime state |
| `DREAMS_DIR` | `$HOME/.claude/dreams` | where reports are written |
| `FANOUT` | `8` | L1 parallelism |
| `AUTODREAM_FORCE` | `0` | `1` rebuilds even if a report exists |
| `AUTODREAM_CHANGELOG` | `1` | `0` skips the upstream-changelog check |
| `CLAUDE_CODE_REPO` / `CHANGELOG_REMOTE` | cache dir / anthropics/claude-code | changelog clone source/cache |
| `AUTODREAM_L1_ROUNDS` / `AUTODREAM_L2_ATTEMPTS` | `5` / `3` | sleep-resilient retry bounds |
| `AUTODREAM_NETCHECK` / `AUTODREAM_RETRY_WAIT` | `1` / `60` | network-wait between retry rounds |
| `AUTODREAM_SLIM_BYTES` | `262144` | sessions larger than this are slimmed for L1 |
| `SUBL` | `$HOME/bin/subl` then PATH | Sublime CLI for `notify.sh` |
| `AUTODREAM_TRIAGE_SURFACE` | `inline` | `review.sh` triage surface: `inline` (current terminal) or `cmux` (own workspace) |
| `AUTODREAM_TRIAGE_FOCUS` | `false` | cmux surface only: `true` switches to the new workspace on launch, `false` opens it in the background |
| `CMUX_BIN` | `/Applications/cmux.app/.../bin/cmux` then PATH | cmux CLI, used when surface is `cmux` |
| `AUTODREAM_CONFIG` | `$AUTODREAM_DIR/config` | sourced KEY=VALUE config (env vars override it) |

## Lean queries / no self-pollution (see CLAUDE.md for full detail)

- Both layers call `claude --print` with composed lean flags (`--no-session-persistence --disable-slash-commands --strict-mcp-config --settings '{"disableAllHooks":true}'` + `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` …) — minimal footprint while keeping subscription/OAuth auth.
- `--no-session-persistence` stops workers leaving their own transcripts; the enumeration also pipes through `prune-self-sessions.sh --filter` to drop any left by older runs. Without this, ~90% of a night's corpus is autodream re-reading itself.
