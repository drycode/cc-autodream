#!/bin/bash
# Autodream runner — invoked by launchd at ~3am local time.
#
# Two-layer pipeline:
#   L1: For each of yesterday's session JSONLs, spawn a parallel `claude --model claude-haiku-5-5`
#       running SESSION_TRIAGE.md → writes one findings.json per session.
#   L2: One `claude` (CLI default model) running PROMPT.md with Glob and Read only → reads
#       all findings JSONs and prints the report on stdout, ending with AUTODREAM_REPORT_END,
#       then an optional AUTODREAM_PINS_BEGIN/END block. run.sh is the only writer: it strips
#       the sentinel into $DREAMS_DIR/YYYY-MM-DD.md, writes pins.jsonl from the block, and
#       stores the pins in Mnemopi via apply-pins.sh.
#
# Usage:
#   ./run.sh             # process yesterday
#   ./run.sh 2026-05-24  # process a specific date
#   FANOUT=4 ./run.sh    # tune L1 parallelism (default 8)
#
# Environment overrides (all optional):
#   CLAUDE_BIN     path to claude CLI                   default: $HOME/.local/bin/claude
#   PROJECTS_DIR   single root: where session JSONLs live (kept for compat; one root)
#                  default: $HOME/.claude/projects
#   SESSION_ROOTS  colon-separated dirs to scan for session JSONLs. Takes precedence
#                  over PROJECTS_DIR. If neither is set, every $HOME/.claude*/projects
#                  that exists is scanned (primary always first) — each CLAUDE_CONFIG_DIR
#                  profile keeps its own projects/ bucket, so one-dir scanning silently
#                  missed sessions recorded under ~/.claude-nous, ~/.claude-ds4, ...
#   AUTODREAM_DIR  scripts + prompts + state           default: $HOME/.claude/autodream
#   DREAMS_DIR     where final reports are written     default: $HOME/.claude/dreams
#   FANOUT         L1 parallelism                      default: 8
#   AUTODREAM_CHANGELOG  set 0 to skip the upstream-changelog check  default: 1
#   AUTODREAM_CHANGELOG_SOURCES  override the watched harnesses. Semicolon-separated
#                        records of name|remote|path-in-repo|cache-dir. Default watches
#                        Claude Code, Codex and OMP (OMP is a monorepo with no root
#                        CHANGELOG, hence the per-source path). CHANGELOG_REMOTE selects
#                        one source alone and suppresses the others.
#   AUTODREAM_CHANGELOG_MAX_LINES  per-source cap on inserted lines          default: 400
#   CLAUDE_CODE_REPO     persistent cache for the claude-code clone  default: $AUTODREAM_DIR/cache/claude-code
#   CHANGELOG_REMOTE     git remote to clone/pull       default: https://github.com/anthropics/claude-code.git
#   AUTODREAM_L1_ROUNDS  max L1 retry rounds for missing sessions    default: 5
#                        Two consecutive rounds that recover no session trip a circuit
#                        breaker: the run jumps straight to the stub round rather than
#                        spending the rest of the budget on an identical failure.
#   AUTODREAM_L1_TIMEOUT seconds before an L1 worker is killed with     default: 1200
#                        its process group; needs timeout or gtimeout on PATH.
#                        Must be a positive integer (0 would disable the timeout).
#                        SIGKILL follows 30s after the SIGTERM, so the worst-case
#                        bound is AUTODREAM_L1_TIMEOUT + 30.
#   AUTODREAM_L1_WARMUP  set 0 to skip the pre-fanout auth warmup     default: 1
#                        One serial model call per adapter before the parallel dispatch, so
#                        a cold OAuth token is refreshed once instead of by FANOUT workers
#                        at once. Never fatal; result lands in run-stats as l1_warmup.
#   AUTODREAM_L1_WARMUP_TIMEOUT seconds before the warmup is killed    default: 120
#                        Must be a positive integer (0 would disable the deadline).
#   AUTODREAM_L2_ATTEMPTS max L2 attempts to produce a report        default: 3
#   AUTODREAM_RETRY_WAIT seconds to pause between retry rounds       default: 60
#   AUTODREAM_NETCHECK   set 0 to skip waiting-for-network on retry  default: 1
#   AUTODREAM_ADAPTERS   harnesses to scan: names (space/comma) or all   default: claude
#                        (an adapter under adapters/ is accepted, not enabled, until named)
#   AUTODREAM_FORCE      set 1 to rebuild even if a report exists    default: 0
#   AUTODREAM_SLIM_BYTES sessions larger than this are slimmed for L1  default: 262144
#   AUTODREAM_L1_CHUNK_BYTES  a transcript whose worker input is bigger than this is split at line
#                        boundaries and read by one worker per chunk, then merged into the one
#                        findings JSON per session. 0 turns chunking off and restores the head/tail
#                        slim exactly. COST: every oversized session costs up to MAX_CHUNKS worker
#                        calls instead of one, per round, so a night costs up to
#                        (oversized sessions x MAX_CHUNKS) calls plus the rest one each; a session
#                        takes up to MAX_CHUNKS x AUTODREAM_L1_TIMEOUT of wall time (its chunks run
#                        in sequence in one slot)                              default: 0 (off; 300000 is
#                        the value the replay in the PR was run with)
#   AUTODREAM_L1_MAX_CHUNKS  most chunks read per session; over it the middle is dropped and counted
#                        (l1_chunks_elided), the first half and last half are kept   default: 8
#   AUTODREAM_WINDOW     set 0 to place a session in a report day by its file mtime
#                        alone, as before. On (default) it is placed by the timestamps
#                        INSIDE the transcript, and stats and L1 see only that day  default: 1
#   AUTODREAM_L2_ENGINE  adapter whose engine runs L2, and by default reviews every source's
#                        sessions in L1 too: the run's reviewer      default: the first enabled adapter
#   AUTODREAM_TRIAGE     set 1 to triage each delivered report into dreams/DATE.triage.md   default: 0
#                        One extra read-only call on the L2 engine and model, after everything
#                        else (bin/triage-dream.sh; never fatal). Off, nothing changes.
#   AUTODREAM_L2_MODEL   pin the L2 aggregator model (every engine)   default: the adapter's own (claude: the CLI default)
#   AUTODREAM_L2_MODEL_<NAME> / AUTODREAM_L1_MODEL_<NAME>  the same for one engine only. Keyed by
#                        the engine that makes the call, not the source: AUTODREAM_L1_MODEL_OMP is
#                        the model of every L1 call on the omp engine, whichever harness holds the
#                        session, and never reaches the claude CLI
#   AUTODREAM_L1_ENGINE  accepted adapter whose engine reviews every source's sessions in L1
#                                                                     default: the L2 engine
#   AUTODREAM_L1_ENGINE_<NAME>  the same for one source only, e.g. AUTODREAM_L1_ENGINE_OMP=omp
#                        Which harness holds a transcript and which engine reads it are separate:
#                        the source's own adapter still enumerates, linearizes, describes and adds
#                        its triage notes, and only the model call goes to the engine. A name that
#                        is not an accepted adapter leaves those sessions untriaged, never on
#                        another engine. The L1 model defaults to that engine's manifest l1_model.
#   AUTODREAM_SESSION_ROOTS_<NAME>  colon-separated session roots for one adapter other than
#                        claude, in place of its manifest's defaults   default: the manifest's
#   AUTODREAM_REQUIRE_LOGIN  space-separated key=value pairs the login of every engine the run uses
#                        must match before it is handed anything; keys provider, auth, plan,
#                        account, as the engine's whoami verb reports them (claude: claude auth
#                        status). An L1 engine that fails triages nothing; a failing L2 engine
#                        stops the run before it starts      default: record only
#                        (e.g. "provider=firstParty auth=claude.ai plan=max")
#   AUTODREAM_L1_REQUIRE_SERVED  1 discards the findings of any L1 call answered by a model other
#                        than the requested one, as the engine's served verb judges it (claude: an
#                        alias such as haiku matches the claude-haiku-... id it answers as). An
#                        engine with no served verb (omp) cannot be vouched for, so its calls are
#                        discarded too                                  default: 0, record only
#   AUTODREAM_MARKER_EPOCH    first date whose report is REQUIRED to carry the
#                             open-questions marker; earlier unmarked reports are treated
#                             as complete (legacy) rather than abandoned
#                                                                     default: 2026-08-19
#   AUTODREAM_MIN_USER_TURNS  noise-gate floor on user_message_count  default: 2
#   AUTODREAM_MIN_MINUTES     noise-gate floor on duration_minutes    default: 1
#   AUTODREAM_STATS_BIN       override the resolved session-stats.sh path, authoritative
#                             (no existability fallback — lets tests force missing or
#                             malformed stats sidecars)                default: unset
#   AUTODREAM_OVERLAP_BIN     override the resolved overlap-stats.sh path, authoritative
#                             (no existability fallback — lets tests force the "not
#                             measured" paths)                        default: unset
#   AUTODREAM_CONFIG     path to the sourced config file             default: $AUTODREAM_DIR/config
#   AUTODREAM_VAULT_DIR  autodream folder inside an Obsidian/synced vault; enables the
#                        inbox note surface + report publishing       default: unset (off)
#   AUTODREAM_VAULT_BIN  override the resolved vault-notes.sh path, authoritative
#   AUTODREAM_XBOOKMARKS_BIN override the resolved x-bookmarks.sh path, authoritative
#   AUTODREAM_PRUNE_ROOTS    colon-separated dirs to search for repos whose finished
#                            worktrees and branches are pruned     default: unset (off)
#   AUTODREAM_PRUNE_BIN      override the resolved prune-worktrees.sh path, authoritative
#                            (the other AUTODREAM_PRUNE_* knobs are in prune-worktrees.sh)
#   AUTODREAM_TRIAGE_SUGGEST 0 turns off the "repos worth triaging" list  default: on
#   AUTODREAM_TRIAGE_BIN     override the resolved triage-candidates.sh path, authoritative
#                            (the other AUTODREAM_TRIAGE_* knobs are in triage-candidates.sh)

set -u

CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
# PROJECTS_DIR's default is applied here AND its explicit-ness is recorded, because the
# resolution order is SESSION_ROOTS > PROJECTS_DIR(explicit) > autodetect. `:-` can't
# tell "unset" from "set to the default", and treating the always-present default as
# explicit would make autodetect unreachable.
PROJECTS_DIR_EXPLICIT=0
if [ -n "${PROJECTS_DIR+x}" ]; then
  PROJECTS_DIR_EXPLICIT=1
  PROJECTS_DIR="${PROJECTS_DIR:-$HOME/.claude/projects}"
else
  PROJECTS_DIR="$HOME/.claude/projects"
fi
AUTODREAM_DIR="${AUTODREAM_DIR:-$HOME/.claude/autodream}"

# ---- Config file ----
# run.sh historically ignored ~/.claude/autodream/config; only review.sh sourced it. That
# was fine while every key it held was review-only, and stopped being fine the moment a
# key had to reach the nightly run (AUTODREAM_VAULT_DIR). Sourced here, after AUTODREAM_DIR
# is resolved — so AUTODREAM_DIR itself must come from the environment, not the config.
#
# The env-wins dance matters: the config uses plain `KEY=value`, so a bare `.` would let
# the file clobber a variable the caller deliberately exported (tests set env, and a run
# invoked as `AUTODREAM_VAULT_DIR= run.sh` to disable the vault must actually disable it).
# Snapshot the exported environment, source, then replay the snapshot: names the caller
# set win, names only the config sets survive.
#
# `set -a` around the source is the other half: the helper scripts below are separate
# processes, so a config key that stays an unexported shell variable reaches nothing.
#
# This whole script runs under `set -u` (top of file), and sourcing a user-edited file
# under nounset means ANY unbound reference in it (e.g. a typo'd
# X_CREDS_FILE=$AUTODREAM_HOME/x-credentials, meaning AUTODREAM_DIR) aborts the shell
# outright — before LOG_DIR or the log() function exist, so nothing reaches the run log
# and no report is produced. The `|| echo WARNING ...` below can't catch that: nounset
# kills the shell rather than making `.` return non-zero. run.sh never sourced this file
# before the vault-notes feature, so a typo that used to be harmless now silently costs
# a night. Two passes fix it without losing the config-key-name diagnostic:
#   1. A throwaway subshell probe sources the config under the SAME `set -u` this
#      script runs under, purely so bash's own error message (which names the exact
#      unbound variable) can be surfaced as a WARNING. A subshell dying from `set -u`
#      does not kill this shell, and nothing it does touches real state.
#   2. The real source runs with nounset OFF, so a bad reference can't abort us — it
#      degrades to an empty expansion for that one reference, and every other key
#      (before or after the bad line) still gets set and exported normally.
AUTODREAM_CONFIG="${AUTODREAM_CONFIG:-$AUTODREAM_DIR/config}"
if [ -f "$AUTODREAM_CONFIG" ]; then
  _env_snapshot=$(export -p)

  # shellcheck disable=SC1090
  _config_probe_err=$(set -a; set -u; . "$AUTODREAM_CONFIG" 2>&1 1>/dev/null)
  if [ -n "$_config_probe_err" ]; then
    echo "WARNING: $AUTODREAM_CONFIG has an unbound variable reference (continuing without it): $_config_probe_err" >&2
  fi

  set +u
  set -a
  # shellcheck disable=SC1090
  . "$AUTODREAM_CONFIG" || echo "WARNING: failed to source $AUTODREAM_CONFIG (continuing)" >&2
  set +a
  set -u
  eval "$_env_snapshot"
  unset _env_snapshot _config_probe_err
fi
DREAMS_DIR="${DREAMS_DIR:-$HOME/.claude/dreams}"
LOG_DIR="$AUTODREAM_DIR/logs"
FANOUT="${FANOUT:-8}"

# Bound every L1 worker. A worker that never exits holds its xargs -P slot forever, so FANOUT
# hung workers stop the whole run with no error and no report: 2026-08-19 and 2026-08-22 each
# sat wedged for days with all 8 slots taken by workers blocked on their own node_repl and
# mnemopi_embed children (omp-autodream).
#
# GNU timeout, invoked without --foreground, runs the command in a new process group and
# signals the group, so it reaps those grandchildren. A bare kill on the engine process would
# leave them reparented (to launchd on macOS) and running. macOS ships no timeout in its base
# install, so this degrades to unbounded rather than becoming a hard coreutils dependency;
# run-stats records which way it went. TIMEOUT_BIN itself is resolved after the PATH
# augmentation below.
AUTODREAM_L1_TIMEOUT="${AUTODREAM_L1_TIMEOUT:-1200}"
# GNU timeout treats a duration of 0 as "no timeout", so an unvalidated 0 restores the exact
# hang this bounds while the startup log still reports a timeout is set. A non-numeric value is
# worse: timeout rejects it and every worker fails. Refuse both at startup rather than
# discovering it at 03:15.
case "$AUTODREAM_L1_TIMEOUT" in
  ''|*[!0-9]*) echo "FATAL: AUTODREAM_L1_TIMEOUT must be a positive integer (got '$AUTODREAM_L1_TIMEOUT')" >&2; exit 1 ;;
  *) [ "$AUTODREAM_L1_TIMEOUT" -gt 0 ] || { echo "FATAL: AUTODREAM_L1_TIMEOUT must be greater than 0 (0 disables the timeout entirely)" >&2; exit 1; } ;;
esac
# The warmup runs before every recovery path (see "auth warmup" below), so an unbounded warmup
# wedges the run. Same two failure modes as the L1 timeout: 0 means no deadline under GNU
# timeout, and a non-numeric value fails the call. Refuse both here.
AUTODREAM_L1_WARMUP_TIMEOUT="${AUTODREAM_L1_WARMUP_TIMEOUT:-120}"
case "$AUTODREAM_L1_WARMUP_TIMEOUT" in
  ''|*[!0-9]*) echo "FATAL: AUTODREAM_L1_WARMUP_TIMEOUT must be a positive integer (got '$AUTODREAM_L1_WARMUP_TIMEOUT')" >&2; exit 1 ;;
  *) [ "$AUTODREAM_L1_WARMUP_TIMEOUT" -gt 0 ] || { echo "FATAL: AUTODREAM_L1_WARMUP_TIMEOUT must be greater than 0 (0 disables the warmup deadline entirely)" >&2; exit 1; } ;;
esac
# SIGKILL grace after the SIGTERM. The worst-case bound is AUTODREAM_L1_TIMEOUT + L1_KILL_GRACE.
L1_KILL_GRACE=30
# Chunked triage, OFF unless asked for (default 0). 0 is a real value, so only a non-number is refused; a cap below 1 would
# mean no chunk is ever read. Decimal whatever the user wrote: bash arithmetic reads 08 as an
# invalid octal number.
AUTODREAM_L1_CHUNK_BYTES="${AUTODREAM_L1_CHUNK_BYTES:-0}"
case "$AUTODREAM_L1_CHUNK_BYTES" in
  ''|*[!0-9]*) echo "FATAL: AUTODREAM_L1_CHUNK_BYTES must be a non-negative integer (got '$AUTODREAM_L1_CHUNK_BYTES'); 0 turns chunking off" >&2; exit 1 ;;
esac
AUTODREAM_L1_CHUNK_BYTES=$((10#$AUTODREAM_L1_CHUNK_BYTES))
AUTODREAM_L1_MAX_CHUNKS="${AUTODREAM_L1_MAX_CHUNKS:-8}"
case "$AUTODREAM_L1_MAX_CHUNKS" in
  ''|*[!0-9]*) echo "FATAL: AUTODREAM_L1_MAX_CHUNKS must be a positive integer (got '$AUTODREAM_L1_MAX_CHUNKS')" >&2; exit 1 ;;
esac
AUTODREAM_L1_MAX_CHUNKS=$((10#$AUTODREAM_L1_MAX_CHUNKS))
[ "$AUTODREAM_L1_MAX_CHUNKS" -ge 1 ] || { echo "FATAL: AUTODREAM_L1_MAX_CHUNKS must be at least 1" >&2; exit 1; }
# The noise gate hands these to jq --argjson with stderr discarded. A non-number makes jq
# fail, the gate comes back empty, and every session goes to a model call with no message.
for _knob in AUTODREAM_MIN_USER_TURNS AUTODREAM_MIN_MINUTES; do
  case "${!_knob:-0}" in
    ''|*[!0-9]*) echo "FATAL: $_knob must be a non-negative integer (got '${!_knob}')" >&2; exit 1 ;;
  esac
done

# Isolated cwd for every `claude --print` worker (see "AI-title stubs" below). The
# workers all read/write by ABSOLUTE path, so their cwd is functionally irrelevant —
# we point it at a dedicated dir purely to redirect Claude Code's session bucket.
# Claude maps the launch cwd to ~/.claude/projects/<cwd with / and . replaced by ->,
# so running from here lands any stray stub in an isolated bucket we own and wipe,
# instead of polluting the user's real -Users-<you> session history.
WORK_DIR="$AUTODREAM_DIR/work"
WORK_BUCKET="$PROJECTS_DIR/$(printf '%s' "$WORK_DIR" | sed 's#[/.]#-#g')"

_pp="$(dirname "${BASH_SOURCE[0]}")/portable.sh"
# Installed copies are symlinks: a merge updates them before install.sh links a new helper.
[ -r "$_pp" ] || _pp="$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/portable.sh"
# shellcheck source=/dev/null
. "$_pp"
TARGET_DATE="${1:-$(pdate_yesterday)}"
NEXT_DATE=$(pdate_shift "$TARGET_DATE" 1 d)

FINDINGS_DIR="$AUTODREAM_DIR/findings/$TARGET_DATE"
REPORT_PATH="$DREAMS_DIR/$TARGET_DATE.md"
RUN_LOG="$LOG_DIR/run-$TARGET_DATE.log"
SESSIONS_LIST="$FINDINGS_DIR/sessions.txt"

# Self-session prune helper — single source of truth for "is this autodream's own
# transcript?". Resolve it next to this script first (works for the repo copy and the
# ~/.claude/autodream symlink), then fall back to the install dir.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

RUNNER_SRC="${BASH_SOURCE[0]}"
runner_hops=0
# A symlink can point at another symlink, and a target can be relative to the link's own
# directory rather than to $PWD. The hop cap keeps a cycle from hanging the run.
# 8 rather than a bigger round number so the cap is reachable in a test: macOS refuses to
# execute anything behind 16+ links (ELOOP), so a cap at or above that could never fire on
# a script that got far enough to run this code, and an untestable guard is a guess. Linux
# allows 40, where it can genuinely fire. A real install is one hop.
while [ -L "$RUNNER_SRC" ] && [ "$runner_hops" -lt 8 ]; do
  runner_link_dir=$(cd "$(dirname "$RUNNER_SRC")" && pwd) || break
  RUNNER_SRC=$(readlink "$RUNNER_SRC") || break
  case $RUNNER_SRC in /*) ;; *) RUNNER_SRC="$runner_link_dir/$RUNNER_SRC" ;; esac
  runner_hops=$((runner_hops + 1))
done

# Where to look for the libraries below, and it is NOT just SCRIPT_DIR. install.sh
# symlinks each script into ~/.claude/autodream individually, so a merge swaps the
# run.sh those links point at instantly while lib-project.sh, adapters.sh,
# preflight.sh and adapters/ stay missing until install.sh is re-run. Sourcing only
# from SCRIPT_DIR then skips them in silence and the run dies later on
# `session_hash: command not found`, with no report and nothing saying why.
#
# The walk above already resolved this script to its real location, so the repo's
# own bin/ is the fallback. Installed dir first, because that is the layout the
# nightly is supposed to have and the one whose files are meant to win.
RUNNER_BIN_DIR=""
if [ ! -L "$RUNNER_SRC" ]; then
  RUNNER_BIN_DIR=$(cd "$(dirname "$RUNNER_SRC")" 2>/dev/null && pwd) || RUNNER_BIN_DIR=""
fi
# $1=basename -> prints the first readable copy, or nothing.
find_lib() {
  if [ -r "$SCRIPT_DIR/$1" ]; then printf '%s' "$SCRIPT_DIR/$1"; return 0; fi
  if [ -n "$RUNNER_BIN_DIR" ] && [ -r "$RUNNER_BIN_DIR/$1" ]; then
    printf '%s' "$RUNNER_BIN_DIR/$1"; return 0
  fi
  return 1
}

# Harness adapters. run.sh no longer knows which harness it is talking to: it
# asks the adapter to enumerate, normalise, parse and identify. lib-project.sh
# holds the one project encoding every adapter must agree on.
_lib=$(find_lib lib-project.sh) && { # shellcheck source=/dev/null
  . "$_lib"; }
_lib=$(find_lib adapters.sh) && { # shellcheck source=/dev/null
  . "$_lib"; }
# The report contract (marker and sentinel). Not optional: an unfound lib would turn every read of
# a report into "command not found", so stop before any work instead of after L1.
_lib=$(find_lib report-format.sh) || { echo "FATAL: report-format.sh not found beside run.sh or its link target" >&2; exit 1; }
# shellcheck source=/dev/null
. "$_lib"
PREFLIGHT=$(find_lib preflight.sh) || PREFLIGHT="$SCRIPT_DIR/preflight.sh"

PRUNE="$SCRIPT_DIR/prune-self-sessions.sh"
[ -x "$PRUNE" ] || PRUNE="$AUTODREAM_DIR/prune-self-sessions.sh"
# Root prober — decides which $HOME/.claude*/projects dirs to scan (see root-probe.sh).
# AUTODREAM_ROOTPROBE_BIN overrides the resolved path (no existability fallback), so
# tests can point it at a stub and exercise the scan fallbacks deterministically.
if [ -n "${AUTODREAM_ROOTPROBE_BIN:-}" ]; then
  ROOT_PROBE="$AUTODREAM_ROOTPROBE_BIN"
else
  ROOT_PROBE="$SCRIPT_DIR/root-probe.sh"
  [ -x "$ROOT_PROBE" ] || ROOT_PROBE="$AUTODREAM_DIR/root-probe.sh"
fi
# Oversized-transcript slimmer (resolved the same way; exported to the L1 workers).
SLIM="$SCRIPT_DIR/slim-transcript.sh"
[ -x "$SLIM" ] || SLIM="$AUTODREAM_DIR/slim-transcript.sh"
# Deterministic session-stat pre-pass (resolved like the other helper scripts).
# AUTODREAM_STATS_BIN overrides the resolved path outright, with no existability
# fallback, for the same reason AUTODREAM_OVERLAP_BIN does below (#26): tests need to
# force a missing or deliberately broken sidecar generator, and the `[ -x ... ] ||`
# chain would rescue a nonexistent override back to the working repo copy (#27).
if [ -n "${AUTODREAM_STATS_BIN:-}" ]; then
  STATS="$AUTODREAM_STATS_BIN"
else
  STATS="$SCRIPT_DIR/session-stats.sh"
  [ -x "$STATS" ] || STATS="$AUTODREAM_DIR/session-stats.sh"
fi
# Global cross-session overlap pass (#14; resolved like the other helper scripts).
# AUTODREAM_OVERLAP_BIN overrides the resolved path outright (no fallback) so tests can
# point it at a nonexistent or stubbed binary and exercise compute_overlap_stats' "not
# measured" paths deterministically — the normal `[ -x ... ] ||` fallback chain would
# otherwise rescue a nonexistent override back to the working repo copy and defeat the
# whole point of the override (#26).
if [ -n "${AUTODREAM_OVERLAP_BIN:-}" ]; then
  OVERLAP="$AUTODREAM_OVERLAP_BIN"
else
  OVERLAP="$SCRIPT_DIR/overlap-stats.sh"
  [ -x "$OVERLAP" ] || OVERLAP="$AUTODREAM_DIR/overlap-stats.sh"
fi
# Report citation resolver. Deterministic artifact check, no model calls; run.sh calls it
# directly after L2 has produced a report.
CITECHECK="$SCRIPT_DIR/citation-check.sh"
[ -x "$CITECHECK" ] || CITECHECK="$AUTODREAM_DIR/citation-check.sh"
# Optional dream triage (AUTODREAM_TRIAGE=1): fixed grounding checks plus one read-only model call.
TRIAGE_DREAM="$SCRIPT_DIR/triage-dream.sh"
[ -x "$TRIAGE_DREAM" ] || TRIAGE_DREAM="$AUTODREAM_DIR/triage-dream.sh"
# Operator-note collector and X-bookmark fetcher. Both are context-gatherers for L2 and
# both are opt-in: vault-notes.sh degrades to the plain notes.md when no vault is set,
# x-bookmarks.sh to a "not configured" stub when no credentials exist. Overrides are
# authoritative (no existability fallback) for the same reason as STATS/OVERLAP above —
# tests need to force the missing-helper path.
if [ -n "${AUTODREAM_VAULT_BIN:-}" ]; then
  VAULT_NOTES="$AUTODREAM_VAULT_BIN"
else
  VAULT_NOTES="$SCRIPT_DIR/vault-notes.sh"
  [ -x "$VAULT_NOTES" ] || VAULT_NOTES="$AUTODREAM_DIR/vault-notes.sh"
fi
if [ -n "${AUTODREAM_XBOOKMARKS_BIN:-}" ]; then
  XBOOKMARKS="$AUTODREAM_XBOOKMARKS_BIN"
else
  XBOOKMARKS="$SCRIPT_DIR/x-bookmarks.sh"
  [ -x "$XBOOKMARKS" ] || XBOOKMARKS="$AUTODREAM_DIR/x-bookmarks.sh"
fi
# Worktree and branch pruner. Opt-in through AUTODREAM_PRUNE_ROOTS, so an install that
# never sets it runs the helper as a no-op. Override is authoritative, as above.
if [ -n "${AUTODREAM_PRUNE_BIN:-}" ]; then
  PRUNE_WORKTREES="$AUTODREAM_PRUNE_BIN"
else
  PRUNE_WORKTREES="$SCRIPT_DIR/prune-worktrees.sh"
  [ -x "$PRUNE_WORKTREES" ] || PRUNE_WORKTREES="$AUTODREAM_DIR/prune-worktrees.sh"
fi
# Touched-repo triage list. On by default: it only reads issues. Override is authoritative.
if [ -n "${AUTODREAM_TRIAGE_BIN:-}" ]; then
  TRIAGE_CANDIDATES="$AUTODREAM_TRIAGE_BIN"
else
  TRIAGE_CANDIDATES="$SCRIPT_DIR/triage-candidates.sh"
  [ -x "$TRIAGE_CANDIDATES" ] || TRIAGE_CANDIDATES="$AUTODREAM_DIR/triage-candidates.sh"
fi
# Memory pin applier. find_lib, not SCRIPT_DIR alone: an install that predates
# apply-pins.sh has run.sh symlinked in and no apply-pins.sh beside it until install.sh
# runs again, and the repo copy is the one that works in that window.
APPLY_PINS=$(find_lib apply-pins.sh) || APPLY_PINS="$SCRIPT_DIR/apply-pins.sh"

# Report-day window. A session belongs to a day because of the timestamps INSIDE it, not
# because of its file mtime: a session written to again after its day closed (resumed, or
# still running) used to drop out of every later rebuild of that day, and a transcript that
# spans several days was read whole for each of them (issue #113).
#
# The adapter contract is unchanged. enumerate keeps its (root, from, to) arguments and
# still filters on mtime; the runner passes it a far upper date, so the mtime test is a
# LOWER bound only (a file last written before the day began cannot hold a record from it),
# and bin/session-window.sh then keeps the files with a record inside the day and cuts the
# stats and the worker's read down to that day's records.
#
# find_lib, not SCRIPT_DIR alone, for the reason apply-pins.sh gives above: a merge swaps
# run.sh instantly while the helpers a symlinked run.sh looks for stay missing until
# install.sh runs again. The helper is run through bash, not gated on -x, for the reason
# preflight.sh is.
#
# The window is ON only when every piece of it works: the helper is there, it turns the
# report day into epoch bounds, and the far date computes and is accepted by this host's
# find. Any one missing leaves the original bounded enumeration in place, so a degraded
# install reads exactly what it read before and never fails a night over this.
# "Far" is the report day plus five years, not a year-9999 sentinel: BSD find on some macOS
# releases cannot parse a distant date and fails with "Can't parse date/time", so the date
# is also probed here with the same find the adapters run.
SESSION_WINDOW=$(find_lib session-window.sh) || SESSION_WINDOW=""
ENUM_END="$NEXT_DATE"
WINDOW_ON=0
WIN_START_EPOCH=""
WIN_END_EPOCH=""
if [ "${AUTODREAM_WINDOW:-1}" != "0" ] && [ -n "$SESSION_WINDOW" ] \
   && _wb=$(bash "$SESSION_WINDOW" bounds "$TARGET_DATE" "$NEXT_DATE" 2>/dev/null) && [ -n "$_wb" ] \
   && _far=$(pdate_shift "$TARGET_DATE" 5 y) && [ -n "$_far" ] \
   && find / -maxdepth 0 ! -newermt "$_far 00:00:00" >/dev/null 2>&1; then
  WIN_START_EPOCH="${_wb%% *}"
  WIN_END_EPOCH="${_wb##* }"
  WINDOW_ON=1
  ENUM_END="$_far"
fi

# Chunked triage: a transcript too big for one worker is split at line boundaries (chunk-transcript.sh),
# one worker reads each chunk, and merge-chunks.sh turns the answers back into the one findings JSON
# per session that L2 reads. It is ON only when it is asked for (AUTODREAM_L1_CHUNK_BYTES above 0)
# and BOTH helpers are found, found the way session-window.sh is (find_lib: a merge swaps run.sh
# before install.sh links the new helpers). With either missing the oversized transcript is read
# the old way, the head/tail slim, and the run says so. Everything new is behind this one switch:
# L1_CHUNKING=0 reaches the slimmer with no reshape and no full mode, no chunker, no merge and no
# chunk note, so the off path is what it was.
CHUNKER=$(find_lib chunk-transcript.sh) || CHUNKER=""
MERGER=$(find_lib merge-chunks.sh) || MERGER=""
L1_CHUNKING=0
if [ "$AUTODREAM_L1_CHUNK_BYTES" -gt 0 ] && [ -n "$CHUNKER" ] && [ -n "$MERGER" ]; then
  L1_CHUNKING=1
fi

# Provenance of the code actually executing (#29), stamped into run-stats.txt below.
# Resolved by walking this script's own symlink chain rather than by reusing SCRIPT_DIR,
# which is a working directory and not a checkout. install.sh symlinks each script
# individually into ~/.claude/autodream, so that directory is real and has no .git, and
# `cd "$(dirname "$0")"` resolves symlinked *directories* but not a symlinked *file* —
# it lands in the install dir every time. Six of the eight runs through 2026-08-03 wrote
# `runner_commit: unknown` for that reason alone, which is the exact blind spot #29
# existed to close. The two that did stamp a sha were launched from the repo by hand.
# SCRIPT_DIR stays as it is: helper lookup genuinely wants the install dir.
# Everything degrades to "unknown"/"no": a tarball install with no git, or no git binary
# at all, is a supported way to run this and must not fail the run.
# --untracked-files=no on the dirty check: "dirty" is meant to warn that the run used code
# that exists in nobody's history, which only tracked modifications can cause. Counting
# untracked files made the first production run report runner_dirty: yes over a stray
# scratch directory, which is exactly the kind of false alarm that gets a signal ignored.
# Still a symlink means the walk gave up (a cycle, or a chain past the cap) rather than
# arriving anywhere. Resolving the truncated path would stamp whatever checkout it happens
# to sit in, and a confidently wrong sha is worse than no sha at all — the whole point of
# #29 is that this field can be trusted when someone is chasing a bad night.
if [ -L "$RUNNER_SRC" ]; then
  RUNNER_REPO_DIR=""
else
  RUNNER_REPO_DIR=$(cd "$(dirname "$RUNNER_SRC")" && pwd) || RUNNER_REPO_DIR=""
fi
# The empty case has to short-circuit before git rather than lean on git to reject it:
# `git -C "" rev-parse HEAD` does NOT fail, it silently stays in $PWD and answers for
# whatever repo the caller happened to launch from. launchd starts this job from an
# unrelated cwd, so leaving that to git would stamp a stranger's sha and call it
# provenance.
if [ -z "$RUNNER_REPO_DIR" ]; then
  RUNNER_COMMIT=""
else
  RUNNER_COMMIT=$(git -C "$RUNNER_REPO_DIR" rev-parse --short HEAD 2>/dev/null) || RUNNER_COMMIT=""
fi
: "${RUNNER_COMMIT:=unknown}"
if [ "$RUNNER_COMMIT" = "unknown" ]; then
  RUNNER_DIRTY=no
elif [ -n "$(git -C "$RUNNER_REPO_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  RUNNER_DIRTY=yes
else
  RUNNER_DIRTY=no
fi

# The failure classifier is looked up after the runner walk above, because an install
# made before failure-class.sh existed has a link for every other script but not this
# one, and updating the checkout must not break that install's nightly (Codex review of
# omp-autodream b19ec84). The directory the run.sh link points at always has it.
FAILURE_CLASS=""
for candidate in "$SCRIPT_DIR" "$RUNNER_REPO_DIR" "$AUTODREAM_DIR"; do
  [ -n "$candidate" ] && [ -r "$candidate/failure-class.sh" ] && { FAILURE_CLASS="$candidate/failure-class.sh"; break; }
done
if [ -z "$FAILURE_CLASS" ]; then
  printf 'fatal: required failure classifier not found next to %s, %s or %s\n' "$SCRIPT_DIR" "${RUNNER_REPO_DIR:-?}" "$AUTODREAM_DIR" >&2
  exit 1
fi
# shellcheck source=./failure-class.sh
. "$FAILURE_CLASS"

mkdir -p "$FINDINGS_DIR" "$DREAMS_DIR" "$LOG_DIR" "$WORK_DIR"

# Append rather than replace: launchd hands the job a minimal PATH that lacks the engine
# binaries and git, which is why this line exists, but discarding the caller's PATH meant an
# interactive run and the nightly could resolve different binaries (and a test could not put a
# curl shim in front). Appending keeps that fix and lets an explicit caller win, as a shell would.
export PATH="${PATH:+$PATH:}$HOME/.cargo/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
cd "$HOME" || exit 1

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Every FATAL goes through here so the reason survives to the exit path. A run
# that dies writes no report and posts no banner, and until fatal_exit existed
# that made a failed night completely silent — the log line was the only record,
# and nothing reads the log.
FATAL_REASON=""
log_fatal() { FATAL_REASON="$1"; log "FATAL: $1"; }

# The one exit for a run that cannot continue. Leaves a marker the next run can
# read AND posts a banner now, because those cover different failures: a
# transient cause is caught by the marker when a later night succeeds, while a
# persistent one — a lost exec bit, jq off the launchd PATH — never has a later
# success to be read by, so it needs the banner tonight.
#
# Deliberately NOT a stub report. A report is what the idempotency guard reads as
# "this date is complete", and it is not.
fatal_exit() {
  local reason="${FATAL_REASON:-the run stopped before it produced a report}"
  mkdir -p "$FINDINGS_DIR" 2>/dev/null || true
  # NEVER over a date that already has a report. Moving the claude check below the
  # idempotency guard fixed one call site; the destructive behaviour was still
  # here, and AUTODREAM_FORCE bypasses that guard BY DESIGN — which is the
  # documented `autodream-now.sh <date> --force` path. Any fatal under it would
  # then overwrite that date's full L1/L2 telemetry with a five-line stub and
  # announce a FAILED night while dreams/<date>.md sits there complete.
  # unassembled_dates() would not catch it either, because the report exists.
  #
  # The guard covers the WRITE, and only the write. The first version returned
  # here, which took the banner down with it — and this branch is reachable in
  # exactly one situation, the documented `autodream-now.sh <date> --force`
  # rebuild, which runs detached under launchd where the banner is the only
  # surface an operator sees. jq off the launchd PATH, preflight fatals, no
  # marker (correctly), no banner, and unassembled_dates() skips the date because
  # a report exists: the operator polls dreams/<date>.md, finds the OLD report
  # sitting there, and reads a failed rebuild as a successful one. Nothing about
  # protecting a complete date's telemetry requires staying quiet about the run
  # that just died trying to replace it.
  if [ -s "$REPORT_PATH" ]; then
    log "  not overwriting run-stats.txt: $TARGET_DATE already has a complete report"
    notify_fatal "$reason (the existing report for $TARGET_DATE is unchanged)"
    return 1
  fi
  {
    printf '# Autodream run self-audit — %s\n' "$TARGET_DATE"
    printf 'runner_commit: %s\n' "$RUNNER_COMMIT"
    printf 'runner_dirty: %s\n' "$RUNNER_DIRTY"
    printf 'fatal: %s\n' "$reason"
    printf 'sessions_triaged: 0\n'
  } > "$FINDINGS_DIR/run-stats.txt" 2>/dev/null || true
  notify_fatal "$reason"
  return 1
}

# Both fatal paths post the banner, so the posting lives in one place. Keeping
# two copies is how the guarded path lost its banner in the first place.
notify_fatal() { # $1=reason
  [ -x "$AUTODREAM_DIR/notify.sh" ] || return 0
  "$AUTODREAM_DIR/notify.sh" --failure "$TARGET_DATE" "$1" \
    || log "failure notification returned non-zero (continuing)"
}

# Wipe the isolated worker bucket. Claude Code's async AI-title generation writes a
# one-line `{"type":"ai-title",...}` stub into the launch cwd's session bucket even
# under --no-session-persistence (that flag only suppresses the full transcript). By
# running workers from $WORK_DIR those stubs land in $WORK_BUCKET, which we empty
# before and after every run so they never accumulate in the user's session history.
# A run killed mid-flight (this pipeline's normal failure) leaves the temp its adapter was
# writing, `<out>.tmp.XXXXXX`, and slim-transcript.sh's `<dst>.pre.jsonl`. The adapter cannot
# clean up after its own death: a signal trap defers the signal until the delegate returns and
# hangs the run (adapters/claude/adapter.sh says why), so the cleanup lives here, where a
# killed process cannot skip it (#57). Nothing reads either name (the findings glob is *.json
# and slim output is read by exact path), so this is about not accumulating them. It runs
# under the per-date lock, so no live writer of these files exists. A stale temp from a killed
# run is not a partial result anyone should read.
sweep_killed_leftovers() {
  local _f _n=0
  for _f in "$FINDINGS_DIR"/*.tmp.?????? "$FINDINGS_DIR"/*.pre.jsonl; do
    [ -f "$_f" ] || continue
    rm -f "$_f" 2>/dev/null && _n=$((_n + 1))
  done
  [ "$_n" -eq 0 ] || log "removed $_n temp file(s) left in $FINDINGS_DIR by a killed run"
}

clean_work_bucket() { rm -rf "$WORK_BUCKET" 2>/dev/null || true; }

# ---- Session-root selection ----
# autodream scans one or more $HOME/.claude*/projects dirs. Resolution order:
#   1. SESSION_ROOTS (colon-separated, set by env/config) — authoritative.
#   2. PROJECTS_DIR — but ONLY when the caller explicitly set it (its default is applied
#      anyway at startup, so an explicit-set flag is what distinguishes a deliberate
#      single-root choice from an unset variable). Kept for backward compatibility.
#   3. Neither: autodetect every $HOME/.claude*/projects that exists, primary
#      ($HOME/.claude/projects) first, via root-probe.sh. If the probe is missing or
#      fails, fall back to the primary dir alone rather than scanning nothing.
# WORK_BUCKET stays keyed off the PRIMARY dir: the lean workers run under the default
# config, so their AI-title stubs land in the default bucket, which the isolation +
# clean_work_bucket above is built around. Scanning extra roots does not change that.
probe_roots() {
  SESSION_ROOTS="${SESSION_ROOTS:-}"
  if [ -z "$SESSION_ROOTS" ] && [ "$PROJECTS_DIR_EXPLICIT" = "1" ]; then
    SESSION_ROOTS="$PROJECTS_DIR"
  fi
  if [ -n "$SESSION_ROOTS" ]; then
    log "session roots: ${SESSION_ROOTS//:/, }"
    return 0
  fi
  if [ -x "$ROOT_PROBE" ]; then
    # Scan the decided roots only: primary + the ones root-choices.conf says index.
    # An unasked root is held out of the report until the user decides on it — that is
    # the point of the flag file (write_unindexed_flag) the report reads: "found a
    # folder we're not indexing." Scanning an undecided folder would make that flag a
    # lie. Folders the user explicitly ignored are likewise skipped.
    SESSION_ROOTS=$("$ROOT_PROBE" --consolidated 2>/dev/null) || SESSION_ROOTS=""
  fi
  # A last-resort default is NOT a configured root. Discovery returning nothing
  # means a fresh host with no store yet, and that has to stay a legitimate quiet
  # night — the all-roots-unavailable fatal below must not fire on a fallback
  # nobody asked for. This flag is what tells the two apart.
  SESSION_ROOTS_ARE_FALLBACK=0
  if [ -z "$SESSION_ROOTS" ]; then
    SESSION_ROOTS="$HOME/.claude/projects"
    SESSION_ROOTS_ARE_FALLBACK=1
  fi
  log "session roots: ${SESSION_ROOTS//:/, }"
}

# Which roots exist but are NOT indexed — written to a flag file so the morning report
# can tell the human a Claude folder appeared that setup never asked about. Never a
# prompt in the unattended run; the report is the surface.
write_unindexed_flag() {
  local flag="$FINDINGS_DIR/unindexed-roots.txt"
  : > "$flag"
  [ -x "$ROOT_PROBE" ] || { printf 'root-probe.sh not found; cannot detect unindexed claude folders\n' > "$flag"; return 0; }
  "$ROOT_PROBE" --unindexed 2>/dev/null >> "$flag" || true
  [ -s "$flag" ] || printf '(none — every $HOME/.claude*/projects dir is indexed)\n' > "$flag"
}

# Find sessions modified during the target day across every session root.
NL=$'\n'            # for the newline-in-path check below
TAB=$'\t'           # ditto; the tab-separated artifacts cannot carry one
REJECTED_PATHS=0    # session paths a line-based sessions.txt cannot represent
OUT_OF_WINDOW=0     # files modified since the day began that hold no record inside it
SESSIONS_WINDOWED=0 # triaged sessions that spill outside the day, so their stats are cut to it
PARTIAL_ROOTS=0     # roots whose enumerator failed but still returned data
ROOTS_CONFIGURED=0  # roots we were told to scan
ROOTS_SCANNED=0     # roots that existed and were walked
ROOTS_UNAVAILABLE=0 # roots that were configured but are not directories
ROOTS_FAILED=0      # roots reached but whose enumeration failed and returned nothing
SESSION_ROOTS_ARE_FALLBACK=0  # 1 when SESSION_ROOTS is the bare default nobody configured
COLLIDED_DROPPED=0  # paths removed from the worklist by collision handling
SIDECAR_STALE_ROWS=0  # provenance rows that could not be rewritten; sessions_by_source is high by this much
DUPLICATE_PATHS=0   # one path reached twice: overlapping roots, or two adapters
HASH_COLLISIONS=0   # two different paths truncating to one artifact hash
SESSIONS_BY_SOURCE=none

# Which roots an adapter scans. The claude adapter uses the roots root-probe
# resolved, because that prober is what decides which $HOME/.claude*/projects
# dirs are indexed and the user's per-folder choices live there. Any other
# adapter uses its own manifest defaults, since root-probe knows nothing about
# a second harness's store.
adapter_roots() { # $1=adapter name -> one root per line
  # Every line MUST be newline-terminated. `while read` drops a final
  # unterminated line, so a printf '%s' here silently skipped the only root on a
  # single-root host — enumeration found nothing and reported it as a quiet zero.
  if [ "$1" = "claude" ]; then
    printf '%s\n' "$SESSION_ROOTS" | tr ':' '\n'
    return 0
  fi
  local roots up var
  # A host whose harness keeps sessions somewhere else (one store per profile, say) names them.
  up=$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
  var="AUTODREAM_SESSION_ROOTS_$up"
  if [ -n "${!var:-}" ]; then
    printf '%s\n' "${!var}" | tr ':' '\n'
    return 0
  fi
  roots=$(adapter_manifest_get "$1" '.session_roots_default[]' 2>/dev/null) || return 0
  [ -n "$roots" ] || return 0
  printf '%s\n' "$roots"
}

# The adapters actually enumerated this run.
#
# The fallback fires ONLY when the adapter machinery is genuinely absent — an
# install symlinked at a tree predating adapters/ — so a partial upgrade degrades
# instead of losing a night. It must NOT fire when the loader ran and accepted
# zero adapters, because that is a refusal: a claude directory rejected for
# failing containment or carrying a mismatched manifest would otherwise be
# manufactured back into the list and executed anyway, which turns every check in
# adapters.sh into decoration.
#
# Which adapters run is a host decision: AUTODREAM_ADAPTERS, a space or comma separated list of
# names (or `all`), default `claude`. A directory under adapters/ makes an adapter ACCEPTED, not
# enabled, so merging a new harness never changes what a live nightly scans. The hosts that
# want omp say so in their config.
# Resolved ONCE into a global, by a function that prints nothing.
#
# The first version of this was a memoised `enabled_adapters` that every caller
# invoked as `$(enabled_adapters)` — so the cache assignment happened inside a
# command substitution and died with the subshell, leaving ENABLED_ADAPTERS_RESOLVED
# at 0 in the parent on every call. The loader re-ran all three times and the
# duplicate warning the memo was written to stop came straight back. Reproduced
# directly: the uncached body ran 3/3 times and the cache stayed empty.
#
# That is precisely the trap adapters.sh's own header documents for
# adapters_rejected, and writing it again a few hundred lines away is why that
# header says a file crosses the boundary and a variable does not. Here the
# boundary is crossed by not creating one: resolve_enabled_adapters assigns the
# global and returns, callers read ENABLED_ADAPTERS.
ENABLED_ADAPTERS=""
ENABLED_ADAPTERS_RESOLVED=0
resolve_enabled_adapters() {
  [ "$ENABLED_ADAPTERS_RESOLVED" = "1" ] && return 0
  ENABLED_ADAPTERS=$(_enabled_adapters_uncached)
  ENABLED_ADAPTERS_RESOLVED=1
  return 0
}
# The run's reviewer: the engine that writes the summary (AUTODREAM_L2_ENGINE, else the first
# enabled adapter), and by default the engine that reviews every source in L1 as well. One
# function for both, so the per-session pass and the summary cannot drift onto different engines
# without the host asking (AUTODREAM_L1_ENGINE, AUTODREAM_L1_ENGINE_<NAME>).
review_engine() {
  resolve_enabled_adapters
  printf '%s' "${AUTODREAM_L2_ENGINE:-${ENABLED_ADAPTERS%% *}}"
}
# Who an engine's calls run as, read once per engine before it is handed anything: the adapter's
# whoami verb reports the API provider, sign-in method, plan and account of its login (claude:
# `claude auth status`, no model call), and an engine without the verb reports unknown. Each answer
# is logged once and kept in ENGINE_LOGINS (engine, provider, auth, plan, account; tab-separated)
# for run-stats. AUTODREAM_REQUIRE_LOGIN lists key=value pairs that must all match; on a mismatch
# this returns 1 with the reason in LOGIN_REFUSAL.
ENGINE_LOGINS=""
LOGIN_REFUSAL=""
engine_login_ok() { # $1=engine -> 0 when its login meets AUTODREAM_REQUIRE_LOGIN, or nothing is required
  local eng="$1" row who req k want have
  row=$(printf '%s' "$ENGINE_LOGINS" | awk -F'\t' -v e="$eng" '$1 == e { print; exit }')
  if [ -z "$row" ]; then
    who=$(adapter_run "$eng" whoami 2>/dev/null) || who=""
    printf '%s' "$who" | jq -e 'type == "object"' >/dev/null 2>&1 || who='{}'
    row="$eng"$'\t'"$(printf '%s' "$who" | jq -r '[.provider, .auth, .plan, .account] | map(. // "unknown" | tostring) | @tsv')"
    ENGINE_LOGINS="${ENGINE_LOGINS}${row}"$'\n'
    log "login for the $eng engine: $(printf '%s' "$row" | awk -F'\t' '{ printf "provider=%s auth=%s plan=%s account=%s", $2, $3, $4, $5 }')"
  fi
  LOGIN_REFUSAL=""
  for req in ${AUTODREAM_REQUIRE_LOGIN:-}; do
    k=${req%%=*}; want=${req#*=}
    case "$k" in
      provider) have=$(printf '%s' "$row" | cut -f2) ;;
      auth) have=$(printf '%s' "$row" | cut -f3) ;;
      plan) have=$(printf '%s' "$row" | cut -f4) ;;
      account) have=$(printf '%s' "$row" | cut -f5) ;;
      *) LOGIN_REFUSAL="$req is not a provider, auth, plan or account requirement"; return 1 ;;
    esac
    [ "$have" = "$want" ] || { LOGIN_REFUSAL="$k is $have, not $want"; return 1; }
  done
  return 0
}
_enabled_adapters_uncached() {
  # "Genuinely absent" means the loader is not sourced OR the adapters tree does
  # not exist — a tarball or partial install. That is a legacy install and it
  # falls back. It is NOT the same as a present tree from which the loader
  # accepted nothing, which is a refusal and must stop the run. Conflating the
  # two is how the first version of this both broke a non-git install test and
  # would have let a rejected adapter run anyway.
  if ! declare -F adapters_list >/dev/null 2>&1 || [ ! -d "$(adapters_root 2>/dev/null)" ]; then
    printf 'claude'; return 0
  fi
  local a
  a=$(adapters_list 2>/dev/null | tr '\n' ' ')
  a="${a% }"
  if [ -z "${a// /}" ]; then
    printf ''                        # tree present, nothing accepted: a refusal
    return 0
  fi
  local one keep="" want
  want=" $(printf '%s' "${AUTODREAM_ADAPTERS:-claude}" | tr ',' ' ') "
  for one in $a; do
    case "$want" in
      *" all "*|*" $one "*) keep="${keep:+$keep }$one" ;;
      # stderr, NOT stdout: this function's stdout is its return channel, and log() is a bare
      # echo. A diagnostic on stdout was word-split into bogus adapter names.
      *) log "  adapter '$one' is accepted but not enabled (AUTODREAM_ADAPTERS=${AUTODREAM_ADAPTERS:-claude}); not enumerating it" >&2 ;;
    esac
  done
  printf '%s' "$keep"
}

scan_roots() {
  # BOTH lists, checked. build_source_sidecar reads .src, so a raw worklist that
  # holds two colliding paths while .src has lost a row means detection runs over
  # an incomplete input and both paths reach dispatch — the same fail-open
  # overwrite, one stage earlier than the collision index.
  if ! { : > "$SESSIONS_LIST.raw"; } 2>/dev/null \
     || ! { : > "$SESSIONS_LIST.src"; } 2>/dev/null; then
    log_fatal "cannot write the session lists in $FINDINGS_DIR"
    return 1
  fi
  REJECTED_PATHS=0
  local src adapters
  resolve_enabled_adapters
  adapters="$ENABLED_ADAPTERS"
  # The accepted set, resolved once for enumerate_for's per-root gate.
  ACCEPTED_ADAPTERS=$(adapters_list 2>/dev/null)
  if [ -z "${adapters// /}" ]; then
    # Two distinct causes reach here and they need different messages: the
    # loader accepted nothing at all, or it accepted adapters but none of them
    # is claude. Printing the first for the second sends the reader hunting a
    # containment or manifest failure that never happened.
    local accepted; accepted=$(adapters_list 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    if [ -n "$accepted" ]; then
      log_fatal "no usable adapter — accepted [$accepted] but none is enabled (AUTODREAM_ADAPTERS=${AUTODREAM_ADAPTERS:-claude}). Refusing to scan."
    else
      log_fatal "the adapter loader ran and accepted no adapters (rejected: $(adapters_rejected 2>/dev/null)). Refusing to scan."
    fi
    RAW=0
    # This path is a TOTAL outage with a mundane trigger — adapters/claude/adapter.sh
    # losing its exec bit to a tarball copy, a restrictive umask or
    # core.fileMode=false, since _adapter_ok requires -x. A host that produced a
    # full report last night then produces nothing, every night.
    #
    # The marker and the banner come from fatal_exit in run(), which every fatal
    # path funnels through; log_fatal above is what carries the reason to it.
    return 1
  fi
  for src in $adapters; do
    scan_one_adapter "$src" || return 1
  done
  # Roots were configured and not one of them was reachable. That is a broken
  # SESSION_ROOTS or a vanished store, and it must not read as a quiet night:
  # RAW would be 0, every shortfall counter would be 0, and the stub would say
  # no files were modified. A fresh host with NO roots configured is a different
  # thing and stays legitimate.
  # The fatal is about roots that were never REACHED, and it stays that way.
  # Subtracting ROOTS_FAILED here looked symmetric and was a regression: on a
  # single-root host — the default install — "enumerator exited nonzero and
  # returned nothing" is the exact shape of a quiet date plus any transient find
  # error, a bucket vanishing mid-walk or one unreadable directory (see the note
  # at the enumeration branch). That host would then get no report at all on a
  # night whose honest answer is the empty-night stub.
  #
  # A failed root is not silent without this: it warns in the log, increments
  # roots_failed, reaches run-stats.txt on both the zero-session and full paths,
  # and PROMPT.md's Corpus integrity bullet names it in the morning report. That
  # is the right weight for "we read less than we meant to" — a caveat on the
  # night, not the loss of it.
  if [ "${SESSION_ROOTS_ARE_FALLBACK:-0}" != "1" ] \
     && [ "$ROOTS_CONFIGURED" -gt 0 ] && [ "$ROOTS_SCANNED" -eq 0 ]; then
    log_fatal "all $ROOTS_CONFIGURED configured session root(s) are unavailable; refusing to report an empty night over a store that was never reached"
    return 1
  fi

  # A transcript reachable from two roots (one dir a symlink of another) must be
  # triaged exactly once; the first source to claim a path keeps it.
  sort_unique_inplace "$SESSIONS_LIST.raw" "the session worklist" || return 1
  RAW=$(wc -l < "$SESSIONS_LIST.raw" | tr -d ' ')
}

scan_one_adapter() { # $1=adapter name
  local src="$1" r
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    # SESSION_ROOTS is colon-separated, so a root path containing ':' is unrepresentable:
    # the split above already fragmented it. Catch the symptom — a fragment that is not
    # a directory (or that was split out of one) — and say why it's being skipped rather
    # than silently scanning nothing.
    ROOTS_CONFIGURED=$((ROOTS_CONFIGURED + 1))
    if [ ! -d "$r" ]; then
      ROOTS_UNAVAILABLE=$((ROOTS_UNAVAILABLE + 1))
      log "WARNING: session root is not a directory (possible ':' in path — SESSION_ROOTS is colon-separated): $r"
      continue
    fi
    ROOTS_SCANNED=$((ROOTS_SCANNED + 1))
    # NUL transport for the fan-out, so a path carrying a space, a tab or a glob
    # character survives intact. It does NOT save a path carrying a newline:
    # sessions.txt is line-delimited and stays that way, because the hash
    # assignments in l1_missing_count() and dispatch_l1() key each artifact by
    # sha1 of the whole line, oversized-gate.sh recomputes that same hash from
    # the file, and every archived findings dir depends on the shape. Such a path is currently written as two lines and
    # the runner then invents a session that does not exist, so it is rejected
    # here — before either representation is built — rather than transported.
    # Stage enumeration to a file and CHECK its status. Reading the adapter
    # through process substitution hid the producer's exit code, so a root that
    # failed on permissions or I/O emitted nothing and the run carried on to
    # finalise a cheerful "no sessions" report over a corpus it never saw.
    local nulfile status
    nulfile=$(mktemp "$FINDINGS_DIR/.enum.XXXXXX") || { log_fatal "cannot stage enumeration in $FINDINGS_DIR"; return 1; }
    enumerate_for "$src" "$r" > "$nulfile"
    status=$?
    if [ "$status" -ne 0 ]; then
      # A nonzero status does NOT mean nothing was read. BSD find exits 1 when a
      # single subdirectory is unreadable or vanishes mid-walk while still
      # printing every other match — verified: 3 files, one locked directory,
      # exit 1, two paths printed. Treating that as fatal threw away a usable
      # corpus and produced NO report on a night that previously produced a full
      # one, which is worse than the silent-zero this check exists to catch.
      #
      # So the distinction is output, not status. Nothing read AND a failure is a
      # real enumeration failure and stops the run. Something read with a failure
      # is a partial walk: carry on with what was returned and say so loudly, so
      # a shrinking corpus is visible in the log and the counter rather than
      # being mistaken for a quiet night.
      if [ -s "$nulfile" ]; then
        PARTIAL_ROOTS=$((PARTIAL_ROOTS + 1))
        log "WARNING: enumeration for adapter '$src' at root $r exited $status but returned data; continuing with a possibly INCOMPLETE corpus for this root"
      else
        # Nothing read from THIS root. That is not a reason to throw away the
        # roots that worked. Multi-root scanning is this tool's premise, and a
        # secondary root (~/.claude-nous/projects, ~/.claude-sigint/projects)
        # legitimately matches nothing on a given date — while BSD find exits 1
        # for ANY unreadable subdirectory anywhere in the walk, match or no
        # match. Verified on this host: an unreadable sibling directory makes
        # `find` exit 1 both with and without matches; without it, exit 0. So one
        # permission-denied directory under a quiet secondary root used to kill a
        # night on which the primary root had a full corpus — and kill it
        # invisibly, because run() returned 1 before notify.sh ran and no
        # findings JSONs were written for unassembled_dates() to notice.
        #
        # Count it, say it loudly, carry on. The all-roots-failed case below is
        # what still refuses to report over a store nothing was read from.
        ROOTS_FAILED=$((ROOTS_FAILED + 1))
        log "WARNING: enumeration failed for adapter '$src' at root $r (exit $status) and returned nothing; this root contributes NO sessions to tonight's corpus"
        rm -f "$nulfile"
        continue
      fi
    fi
    while IFS= read -r -d '' sp; do
      # Reject the two characters the line-based artifacts cannot carry. Verified on this
      # host against the real consumers rather than assumed:
      #   newline    sessions.txt is line-delimited; find writes it as two lines
      #              and the runner then triages a session that does not exist
      #   tab        pin-projects.tsv and the source map are tab-separated, so a tab in a
      #              project directory or session path shifts their columns
      # Backslash and quotes used to be refused here too, because the L1 fan-out read
      # sessions.txt through `xargs -I {}`, which deleted a backslash and died on a quote
      # (#54). dispatch_l1 now hands each worker its path NUL-delimited, and the worker
      # writes JSON through jq, so those are carried like any other character.
      case "$sp" in
        *"$NL"*|*"$TAB"*)
          REJECTED_PATHS=$((REJECTED_PATHS + 1))
          log "  skip: session path holds a newline or tab, which the line-based artifact lists cannot carry: $(printf '%q' "$sp")"
          continue
          ;;
      esac
      # Report-day window gate. With the window on, the adapter's find bounds mtime from
      # below only, so a file modified after the day closed is kept when it holds a record
      # INSIDE the day, and a file modified since the day began that holds none is left out
      # and COUNTED, so it cannot read as a quiet night. Exit 1 is that verdict: records
      # with clocks and none in the day, or no clock at all and modified after the day
      # (its mtime decides, as the bounded find decided). Any other status is the helper
      # failing, and a failing helper must cost extra work, never drop a session.
      if [ "$WINDOW_ON" = 1 ]; then
        bash "$SESSION_WINDOW" in-window "$sp" "$WIN_START_EPOCH" "$WIN_END_EPOCH" </dev/null >/dev/null 2>&1
        if [ "$?" -eq 1 ]; then
          OUT_OF_WINDOW=$((OUT_OF_WINDOW + 1))
          continue
        fi
      fi
      # Paired writes, both checked. Losing either half desynchronises the
      # worklist from its provenance, and the collision detector reads the
      # provenance half.
      # source FIRST: the adapter name is a validated safe identifier with no tab,
      # so `read -r src sp` lets sp absorb the whole remainder. The reverse order
      # truncated any path holding a tab and silently lost its provenance.
      if ! printf '%s\n' "$sp" >> "$SESSIONS_LIST.raw" 2>/dev/null \
         || ! printf '%s\t%s\n' "$src" "$sp" >> "$SESSIONS_LIST.src" 2>/dev/null; then
        log_fatal "could not record $sp in the session lists"
        # Remove the staging file on THIS exit too. Under AUTODREAM_FORCE=1 the
        # findings dir is reused across reruns, so repeated failures would pile up
        # .enum.* files in the directory the aggregator globs.
        rm -f "$nulfile"
        return 1
      fi
    done < "$nulfile"
    rm -f "$nulfile"
  done < <(adapter_roots "$src")
  return 0
}

# Enumeration for one adapter and one root. Delegates to the adapter when one is
# installed; the inline find is the fallback for an install whose tree predates
# adapters/, so a partial upgrade degrades rather than losing the night.
enumerate_for() { # $1=adapter $2=root -> NUL-delimited paths
  # Gated on the adapter having been ACCEPTED, not merely on adapter.sh being
  # executable: an executable check alone would run a directory that failed
  # containment.
  # ACCEPTED_ADAPTERS is assigned directly in scan_roots, not rebuilt through
  # adapters_list per root: that walk costs two realpaths and a jq for every adapter
  # directory, and its answer cannot change mid-run because nothing writes to
  # adapters/ while the scan is in flight.
  if declare -F adapter_run >/dev/null 2>&1 \
     && printf '%s\n' ${ACCEPTED_ADAPTERS:-} | grep -qxF "$1" \
     && [ -x "$(adapters_root 2>/dev/null)/$1/adapter.sh" ]; then
    # Return the ADAPTER's status, not a literal 0. A `return 0` here silently
    # defeated the caller's status check: enumeration was staged to a file and
    # the exit code examined, and this wrapper handed it a success every time.
    # The suite passed 306 assertions over that, because none of them ran an
    # adapter whose enumerate fails. tests/run-all.sh now has one.
    #
    # The upper date is ENUM_END: the day after the report day with the window off, and
    # far in the future with it on, where the in-transcript timestamps decide instead.
    adapter_run "$1" enumerate "$2" "$TARGET_DATE" "$ENUM_END"
    return $?
  fi
  # The fallback is CLAUDE-ONLY. It hardcodes *.jsonl, and nothing reads
  # session_glob from a manifest, so walking another harness's roots with the
  # Claude glob would return nothing and read as a quiet night — a silent wrong
  # answer rather than a loud one. Unreachable today because only claude is ever
  # enabled, but it becomes live the moment a second adapter ships alongside an
  # install whose adapters/ link is stale, which is the exact skew this fallback
  # exists for.
  if [ "$1" != "claude" ]; then
    log "  no adapter for '$1' and no fallback that knows its session format; this root contributes nothing" >&2
    return 1
  fi
  find "$2" -type f -name '*.jsonl' \
       -newermt "$TARGET_DATE 00:00:00" \
       ! -newermt "$ENUM_END 00:00:00" \
       -print0 2>/dev/null
}

# Source provenance, keyed by the artifact hash rather than tagged into
# sessions.txt. That file stays one bare path per line because the hash
# assignments in l1_missing_count() and dispatch_l1() key each artifact by sha1
# of the WHOLE line, oversized-gate.sh recomputes the same hash from it, and
# every archived findings dir depends on the shape. Adding a field would silently invalidate all of them.
#
# The hash formula is deliberately NOT changed to include the source either, for
# the same reason. Instead the two ways two adapters can land on one artifact are
# detected: the same path claimed twice (a misconfiguration — keep the first),
# and two DIFFERENT paths truncating to one hash (no sensible winner — skip both).
# Sort a file unique, in place, atomically, and report failure.
#
# `sort -u FILE -o FILE` can leave FILE empty or partial when it fails, and every
# consumer downstream then trusts that damaged file. The worklist and the
# collision drop set both used the unchecked form; the drop set was fixed first
# and the worklist was left, which is exactly the kind of half-fix this whole
# review has been catching. One helper, both callers.
sort_unique_inplace() { # $1=file $2=what (for the log)
  local f="$1" what="$2"
  if sort -u "$f" > "$f.su.$$" 2>/dev/null && mv -f "$f.su.$$" "$f" 2>/dev/null; then
    return 0
  fi
  rm -f "$f.su.$$"
  log_fatal "could not deduplicate $what; refusing to continue over a possibly damaged list"
  return 1
}

# Rewrite a file by filtering it, atomically, with EVERY failure accounted for.
#
# This exists because the same three-line pattern was patched site by site across
# four review rounds and each patch closed one hole and left another: the grep
# status was swallowed, then checked but the mv was not, then the mv was guarded
# but its failure was silent. Three copies meant three chances to get it wrong.
#
# Contract: on success the file is replaced. On ANY failure the original is left
# untouched, a reason is logged, and the caller gets a nonzero status so it can
# decide whether that is survivable. grep exit 1 means "no lines matched", which
# for a filter is a legitimate empty result, not an error.
rewrite_filtered() { # $1=file $2=what (for the log) ; remaining args = grep args
  local file="$1" what="$2"; shift 2
  local tmp="$file.rw.$$" grc
  grep "$@" "$file" > "$tmp" 2>/dev/null; grc=$?
  if [ "$grc" -gt 1 ]; then
    rm -f "$tmp"
    log "  WARNING: could not rewrite $what (grep exit $grc); leaving it unchanged"
    return 1
  fi
  if ! mv -f "$tmp" "$file" 2>/dev/null; then
    rm -f "$tmp"
    log "  WARNING: could not replace $what (mv failed); leaving it unchanged"
    return 1
  fi
  return 0
}

build_source_sidecar() {
  local sidecar="$FINDINGS_DIR/sessions-source.txt"
  local seen="$FINDINGS_DIR/.hash-to-path"
  local drop="$FINDINGS_DIR/.collided"
  # Fail closed on the bookkeeping files. If .hash-to-path cannot be written,
  # every path looks unseen and no collision is ever DETECTED; if .collided
  # cannot be appended, the drop set is short and the fatal dedup block below is
  # bypassed. Either way both sessions reach dispatch and overwrite the shared
  # artifact — the failure this whole function exists to prevent, arrived at by
  # a silently unwritable temp file.
  if ! { : > "$sidecar"; } 2>/dev/null || ! { : > "$seen"; } 2>/dev/null \
     || ! { : > "$drop"; } 2>/dev/null; then
    log_fatal "cannot write the provenance bookkeeping files in $FINDINGS_DIR; refusing to run collision detection blind"
    return 1
  fi
  DUPLICATE_PATHS=0; HASH_COLLISIONS=0; SESSIONS_BY_SOURCE=""
  local src sp h prev
  # source FIRST, so a path holding any remaining oddity is absorbed whole by the
  # last variable rather than truncated into it.
  while IFS=$'\t' read -r src sp; do
    [ -n "$sp" ] || continue
    # `|| continue` treated "legitimately absent" (exit 1, dropped at enumeration)
    # and "grep failed" (exit >1) as the same thing. On an I/O error that skips
    # the row silently, so a collision may never be DETECTED at all and the
    # unchanged worklist is dispatched with both paths on one artifact — failing
    # open on the way in to the check that fails closed on the way out.
    grep -qxF "$sp" "$SESSIONS_LIST.raw" 2>/dev/null; local prc=$?
    case "$prc" in
      0) : ;;                # present, carry on
      1) continue ;;         # dropped at enumeration, expected
      *) log_fatal "could not check the worklist for $sp (grep exit $prc); refusing to build provenance over an unreadable list"
         return 1 ;;
    esac
    if ! h=$(session_hash "$sp"); then
      log_fatal "could not derive an artifact hash for $sp; refusing to run collision detection on unusable keys"
      return 1
    fi
    # The stored path is everything after the 12-char hash and its tab, taken by
    # offset rather than by field split, so no delimiter inside the path matters.
    #
    # awk's status is checked: a read error returns empty, which is
    # indistinguishable from "hash unseen". A write-only .hash-to-path passes the
    # truncate and append guards and still cannot be read, so every path would
    # look new, .collided would stay empty, and both colliding sessions reach
    # dispatch.
    if ! prev=$(awk -v k="$h" 'substr($0,1,12)==k {print substr($0,14); exit}' "$seen" 2>/dev/null); then
      log_fatal "could not read the collision index; refusing to detect collisions blind"
      return 1
    fi
    if [ -n "$prev" ]; then
      if [ "$prev" = "$sp" ]; then
        DUPLICATE_PATHS=$((DUPLICATE_PATHS + 1))
        # NOT "claimed by more than one adapter". Only `claude` is ever enabled, and
        # sessions.txt.src is not deduplicated while .raw is sort -u'd, so every
        # duplicate today is one transcript reached through two entries of
        # SESSION_ROOTS — ordinary on a host where root-probe autodetects each
        # $HOME/.claude*/projects and one is a symlink of another. Naming adapters
        # sends the reader after a misconfiguration that does not exist.
        log "  duplicate: $sp was reached more than once (two session roots, or two adapters); keeping the first"
      else
        # Two DIFFERENT paths on one truncated hash. There is no sensible winner,
        # so BOTH are dropped from the worklist. An earlier version logged
        # "skipping both" while skipping neither: it removed the sidecar row and
        # left both paths in sessions.txt.raw, so two workers still raced for one
        # <hash>.json and silently overwrote each other. The log said one thing and
        # the code did another, which is worse than not checking at all.
        HASH_COLLISIONS=$((HASH_COLLISIONS + 1))
        log "  COLLISION: $h maps to two different sessions; dropping both: $prev / $sp"
        if ! printf '%s\n%s\n' "$prev" "$sp" >> "$drop" 2>/dev/null; then
          log_fatal "could not record a collided path for removal; refusing to dispatch two sessions onto one artifact"
          return 1
        fi
        # Rewrite unconditionally. `grep -v` exits 1 when it removes the only line,
        # so a guarded `&& mv` left the stale mapping behind in exactly the
        # single-entry case.
        # DELIBERATELY survivable. A stale provenance row overstates
        # sessions_by_source by one and the helper has already logged why; the
        # worklist, which is not survivable, is handled below.
        #
        # NOT counted here. Incrementing on a failed ATTEMPT is what kept this
        # counter attempt-based: a later rewrite may well remove the row, and a
        # single row may be attempted several times. The count is taken from the
        # final sidecar once, below.
        rewrite_filtered "$sidecar" "the source sidecar" -v "^$h	" || :
      fi
      continue
    fi
    if ! printf '%s\t%s\n' "$h" "$sp" >> "$seen" 2>/dev/null; then
      log_fatal "could not record $sp in the collision index; refusing to detect collisions blind"
      return 1
    fi
    # Fail closed, like every sibling write in this function. A silent `|| :` here
    # drops rows on a full disk, SESSIONS_BY_SOURCE is then computed from the short
    # sidecar below and reported as fact, with no counter and no line saying it is
    # short. This function's own header argues that a silently unwritable file is
    # how you arrive at the failure it exists to prevent.
    if ! printf '%s\t%s\n' "$h" "$src" >> "$sidecar" 2>/dev/null; then
      log_fatal "could not record provenance for $h in $sidecar"
      return 1
    fi
  done < "$SESSIONS_LIST.src" || {
    log_fatal "could not read the session source list; refusing to detect collisions over an unreadable input"
    return 1
  }
  rm -f "$seen"

  # Actually remove the colliding sessions from the worklist. Without this the
  # detection is decorative.
  if [ -s "$drop" ]; then
    # Deduplicate first. The earlier path is appended again for every later
    # collision on the same hash, so three paths sharing one hash produce
    # A,B,A,C — four lines describing three drops. Everything below counts and
    # filters from this file, so the duplicate propagated into the telemetry.
    # BOTH the worklist filter and the post-filter verification read this pattern
    # file, so a damaged one lets a collided path through while everything
    # downstream reports success.
    if ! sort_unique_inplace "$drop" "the collision drop set"; then
      rm -f "$drop"; return 1
    fi

    # The worklist is the one that must FAIL CLOSED. Leaving it unchanged means
    # both colliding paths are still in it, so two workers target one <hash>.json
    # and overwrite each other — exactly what this branch exists to prevent.
    if ! rewrite_filtered "$SESSIONS_LIST.raw" "the worklist" -vxF -f "$drop"; then
      log_fatal "refusing to dispatch two sessions onto one artifact"
      rm -f "$drop"; return 1
    fi
    # Verify the drop rather than trusting an exit code. grep -q returns 1 for
    # "not found", which is what we want, but anything ABOVE 1 is an I/O error
    # and would otherwise take the same success path — failing open on the one
    # check that exists to fail closed.
    grep -qxF -f "$drop" "$SESSIONS_LIST.raw" 2>/dev/null; local vrc=$?
    if [ "$vrc" -ne 1 ]; then
      log_fatal "could not confirm the collided paths are gone from the worklist (grep exit $vrc); refusing to dispatch two sessions onto one artifact"
      rm -f "$drop"; return 1
    fi
    # RAW is the ENUMERATED count and stays that way. Overwriting it with the
    # post-drop worklist size made a forced two-session collision report
    # sessions_found_raw: 0 and "0 session file(s) were enumerated" — telling the
    # reader nothing was there when two things were, and were dropped for cause.
    COLLIDED_DROPPED=$(( $(wc -l < "$drop" | tr -d ' ') ))
    # Their provenance rows go too. Note the narrower claim: this removes rows
    # for COLLISION drops only. build_source_sidecar runs before the self-prune
    # and the empty-session filter, so the sidecar still carries rows for worker
    # transcripts and 0-turn shells that are later excluded. Nothing consumes it
    # yet; the first consumer that joins it against <hash>.json must expect
    # hashes with no findings record.
    while IFS= read -r sp; do
      [ -n "$sp" ] || continue
      h=$(session_hash "$sp") || continue
      # Survivable: a stale row overstates sessions_by_source by one and the
      # helper has already said so. The worklist, which is not survivable, was
      # handled above.
      rewrite_filtered "$sidecar" "the provenance row for $h" -v "^$h	" || :
    done < "$drop"

    # Count stale rows from the FINAL sidecar, over UNIQUE hashes. Two things
    # made the earlier version wrong in both directions: it added a count when a
    # rewrite ATTEMPT failed, and it then iterated dropped PATHS. A two-path
    # collision with one persistent stale row reported 3 — one attempt plus the
    # same hash found twice — and a transient failure a later rewrite had already
    # repaired reported 1 when the honest answer was 0. What the reader needs is
    # how many rows are stale now, so that is what is measured.
    # Stage, THEN sort. `producer || exit 1 | sort -u` is masked: without
    # pipefail sort exits 0 on empty input, so a failing producer produced an
    # empty successful assignment and the metric read 0 — the exact false zero
    # this branch exists to avoid.
    local stale_hashes hstage ok_stage=1
    hstage="$FINDINGS_DIR/.stale-hashes.$$"
    : > "$hstage" 2>/dev/null || ok_stage=0
    if [ "$ok_stage" = "1" ]; then
      while IFS= read -r sp; do
        [ -n "$sp" ] || continue
        if ! session_hash "$sp" >> "$hstage" 2>/dev/null; then ok_stage=0; break; fi
        printf '\n' >> "$hstage" 2>/dev/null || { ok_stage=0; break; }
      done < "$drop"
    fi
    if [ "$ok_stage" = "1" ] && stale_hashes=$(sort -u "$hstage" 2>/dev/null); then
      rm -f "$hstage"
      SIDECAR_STALE_ROWS=0
      local sh grc2
      for sh in $stale_hashes; do
        grep -q "^$sh	" "$sidecar" 2>/dev/null; grc2=$?
        case "$grc2" in
          0) SIDECAR_STALE_ROWS=$((SIDECAR_STALE_ROWS + 1)) ;;
          1) : ;;                       # genuinely absent
          # An error is NOT "absent". Reporting 0 because the check itself broke
          # is the false-clean reading this repo already refuses elsewhere with
          # overlap_measured; say unknown instead.
          *) SIDECAR_STALE_ROWS=unknown; break ;;
        esac
      done
    else
      rm -f "$hstage"
      SIDECAR_STALE_ROWS=unknown
      log "  WARNING: could not compute the stale-row count; reporting it as unknown rather than zero"
    fi
  fi
  rm -f "$drop"

  # Counted from the FINAL sidecar rather than from the loop, because collision
  # resolution removes rows after the fact and a count taken during the walk
  # reported sessions that no longer exist in the worklist.
  SESSIONS_BY_SOURCE=$(awk -F'\t' 'NF>1 {print $2}' "$sidecar" 2>/dev/null | sort | uniq -c \
    | awk 'NF {printf "%s%s=%s", (NR>1?",":""), $2, $1}')
  [ -n "$SESSIONS_BY_SOURCE" ] || SESSIONS_BY_SOURCE="none"
}

# ---- Empty-session filter: drop 0-turn shells before fanout ----
# Most of a quiet night's corpus is auto-opened/aborted sessions that hold no user
# input (observed: ~150 of 163 files on 2026-05-30 were single-line `ai-title` shells).
# They cost an L1 worker each for zero signal. A session is SUBSTANTIVE iff it has at
# least one `user` turn that isn't `isMeta:true`; everything else is skippable. The
# predicate is deliberately conservative — any user turn keeps the session, and a jq
# parse failure keeps it too (bias to triage, never silently drop a real session).
# Reads a session-list file on stdin, prints the substantive subset.
# Disable with AUTODREAM_SKIP_EMPTY=0.
filter_empty_sessions() {
  while IFS= read -r sp; do
    [ -n "$sp" ] || continue
    if session_is_substantive "$sp"; then
      printf '%s\n' "$sp"
    fi
  done
}

# exit 0 = keep (substantive or unparseable), 1 = skip (provably a 0-turn shell).
session_is_substantive() {
  local sp="$1" verdict
  [ -r "$sp" ] || return 0
  # Both transcript shapes, because the worklist holds every enabled harness. Claude: a user
  # record that is not meta. OMP: a `message` record with role user holding a text item;
  # UI-only custom_message records never count. Unparseable files are kept (bias to triage).
  verdict=$(jq -s 'if any(.[]; (.type=="user" and (.isMeta != true)) or ((.type=="message") and (.message.role=="user") and ([.message.content[]? | select(.type=="text")] | length > 0))) then 1 else 0 end' "$sp" 2>/dev/null) || return 0
  [ "$verdict" = "0" ] && return 1
  return 0
}

# ---- Upstream changelog: detect Claude Code releases committed on the target day ----
# Clones (once) and pulls anthropics/claude-code into a persistent cache, then diffs
# CHANGELOG.md over [TARGET_DATE, NEXT_DATE) by real commit date and writes the inserted
# entries into the findings dir for Layer 2 to read. There is no remote `git blame`/`log`,
# so we keep a persistent local cache (not a tmpdir): nightly cost is one delta `git pull`.
# git is the only dependency. Any failure is recorded in the output file, never aborts the
# pipeline. Window matches the session scan exactly, so each release is reported once.
# Disable with AUTODREAM_CHANGELOG=0; point CHANGELOG_REMOTE at a local repo for offline tests.
#
# Three harnesses are watched, not one: the user works across Claude Code, Codex and OMP,
# and a release note only earns its place in the report when it lands in a tool actually
# in use. OMP keeps no root CHANGELOG — it is a monorepo and the CLI's log lives at
# packages/coding-agent/CHANGELOG.md — so the path is per-source rather than assumed.
#
# One source's failure never silences the others: each gets its own cache, its own
# clone/pull and its own section, and a dead remote writes an explicit failure line into
# that section rather than an empty file that reads like a quiet night upstream.
changelog_sources() {
  # An explicit CHANGELOG_REMOTE selects a SINGLE source and suppresses the defaults.
  # Back-compat for the old one-repo knob, and load-bearing for the test suite: the
  # changelog test points this at a local fixture, and a default list that still ran
  # would have the suite cloning three real remotes — the promise that it never touches
  # the network, broken silently.
  if [ -n "${CHANGELOG_REMOTE:-}" ]; then
    printf '%s|%s|%s|%s\n' "Claude Code" "$CHANGELOG_REMOTE" "CHANGELOG.md" \
      "${CLAUDE_CODE_REPO:-$AUTODREAM_DIR/cache/claude-code}"
    return 0
  fi
  if [ -n "${AUTODREAM_CHANGELOG_SOURCES:-}" ]; then
    printf '%s\n' "$AUTODREAM_CHANGELOG_SOURCES" | tr ';' '\n' | sed '/^[[:space:]]*$/d'
    return 0
  fi
  printf '%s|%s|%s|%s\n' \
    "Claude Code" "https://github.com/anthropics/claude-code.git" "CHANGELOG.md" "${CLAUDE_CODE_REPO:-$AUTODREAM_DIR/cache/claude-code}"
  printf '%s|%s|%s|%s\n' \
    "Codex" "https://github.com/openai/codex.git" "CHANGELOG.md" "$AUTODREAM_DIR/cache/codex"
  printf '%s|%s|%s|%s\n' \
    "OMP" "https://github.com/STRML/oh-my-pi.git" "packages/coding-agent/CHANGELOG.md" "$AUTODREAM_DIR/cache/oh-my-pi"
  # STRML/oh-my-pi is the fork this host runs, which is rebased onto upstream on every sync, so
  # it carries the build in use. To watch upstream itself set AUTODREAM_CHANGELOG_SOURCES.
}

# True only when $1's parent directory resolves, symlinks and all, inside $AUTODREAM_DIR/cache.
# A `..` anywhere is refused before resolving, so the basename cannot climb out either.
cache_owns() {
  local cache parent
  case "$1" in *..*) return 1 ;; esac
  cache=$(cd "$AUTODREAM_DIR/cache" 2>/dev/null && pwd -P) || return 1
  parent=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 1
  case "$parent/" in "$cache"/*) return 0 ;; esac
  return 1
}

# Append one source's section to $5. Never returns non-zero — a source that cannot be
# reached says so in its own section and the run carries on.
#
# The section goes to a named file rather than stdout, and that is not a style choice:
# log() writes to stdout, so a stdout-emitting version run inside a `{ … } > "$out"`
# block silently interleaves every "cloning …" progress line into the changelog L2 then
# reads as release notes. Caught in a live run against all three remotes.
changelog_one() { # $1=name $2=remote $3=path $4=repo $5=out
  local name="$1" remote="$2" path="$3" repo="$4" out="$5"
  local head_sha n added

  if [ -d "$repo/.git" ]; then
    # A cache this install owns is disposable, so it follows the remote even when the remote
    # was rewritten. `pull --ff-only` failed forever once a fork was rebased and force-pushed
    # (the OMP fork is, on every upstream sync): the section then read "pull failed" every
    # night. A repo outside the cache keeps the conservative pull, because resetting it would
    # discard someone's work.
    local sync='git pull --ff-only --quiet'
    if cache_owns "$repo"; then sync='git fetch --quiet origin && git reset --hard --quiet FETCH_HEAD'; fi
    if ! ( cd "$repo" && eval "$sync" ) 2>>"$RUN_LOG"; then
      log "changelog[$name]: pull failed"
      printf '## %s\n\nGit pull failed; %s changes not checked this run.\n\n' "$name" "$name" >> "$out"
      return 0
    fi
  else
    # Only a cache this install owns may be cleared. AUTODREAM_CHANGELOG_SOURCES names the
    # path, so a typo pointing at a real non-git directory must not be deleted to make room
    # for a clone (debate review of e95e2f2).
    # The path as written proves nothing: `$AUTODREAM_DIR/cache/../x` matches the prefix,
    # and so does `$AUTODREAM_DIR/cache/link/x` where link points elsewhere, and rm -rf
    # follows both (Codex review of 0129fc0). Resolve the parent physically and compare
    # that. Outside the cache nothing is deleted at all; git clone accepts a missing or
    # empty target directory.
    if cache_owns "$repo"; then rm -rf "$repo"; fi
    if [ -e "$repo" ] && [ -n "$(ls -A "$repo" 2>/dev/null)" ]; then
      log "changelog[$name]: $repo exists, is not a git repo and is outside $AUTODREAM_DIR/cache; refusing to delete it"
      printf '## %s\n\nCache path %s is a non-empty directory that is not a git clone; %s changes not checked this run.\n\n' "$name" "$repo" "$name" >> "$out"
      return 0
    fi
    log "changelog[$name]: cloning $remote -> $repo..."
    # blob:none + sparse keeps a monorepo clone cheap — oh-my-pi carries Cargo, bazel and
    # a node_modules tree, and we want one markdown file out of it. Blobs for the path we
    # actually log are fetched on demand. Real remotes only: git ignores --filter on a
    # local clone, and the suite's offline fixture must behave the same either way.
    local cloneargs=()
    case "$remote" in
      *://*|*@*:*) cloneargs=(--filter=blob:none --sparse) ;;
    esac
    if ! git clone --quiet "${cloneargs[@]+"${cloneargs[@]}"}" "$remote" "$repo" 2>>"$RUN_LOG"; then
      log "changelog[$name]: clone failed"
      printf '## %s\n\nGit clone failed; %s changes not checked this run.\n\n' "$name" "$name" >> "$out"
      return 0
    fi
    if [ "${#cloneargs[@]}" -gt 0 ]; then
      # A file, not a directory: cone mode refuses a file path outright (the old call failed and
      # `|| true` hid it), so ask for non-cone mode and anchor the pattern with a leading slash.
      ( cd "$repo" && git sparse-checkout set --no-cone "/$path" ) >/dev/null 2>>"$RUN_LOG" || true
    fi
  fi

  head_sha=$( cd "$repo" && git rev-parse --short HEAD 2>/dev/null ) || head_sha="?"
  n=$( cd "$repo" && git log --format=%H \
         --since="$TARGET_DATE 00:00:00" --until="$NEXT_DATE 00:00:00" \
         -- "$path" 2>/dev/null | wc -l | tr -d ' ' )
  # Inserted changelog lines (new version headers + bullets), oldest-first; strip the
  # diff's leading '+' but drop the '+++ b/<path>' file header.
  # Dedupe non-blank lines, keep every blank. A changelog edited across many commits in one
  # window re-inserts the same lines repeatedly: OMP's log moved 119 commits for 2026-09-08
  # through 09-10 and emitted `## [18.1.16]` three times with its bullets under each. Blank
  # lines are exempt or the markdown collapses into one paragraph. The key is the line AND the
  # release header it sits under: `### Fixed` and `- Fixed a crash` repeat across releases, and
  # a window-wide key dropped them from the second release, leaving its bullets under no
  # heading or the first release's (review of https://github.com/STRML/cc-autodream/pull/83).
  added=$( cd "$repo" && git log -p --reverse \
             --since="$TARGET_DATE 00:00:00" --until="$NEXT_DATE 00:00:00" \
             -- "$path" 2>/dev/null \
           | grep '^+' | grep -v '^+++' | sed 's/^+//' \
           | awk '!NF { print; next } /^## \[/ { hdr = $0 } !seen[hdr SUBSEP $0]++' )
  # Cap per source. One chatty monorepo must not crowd the other harnesses out of L2's
  # context; the cap is per section, so a quiet source is never truncated for a loud one.
  local cap="${AUTODREAM_CHANGELOG_MAX_LINES:-400}" total
  # A non-numeric cap made the -gt test below error out as false under set -u without -e,
  # so the section went out uncapped (debate review of e95e2f2). Fall back to the default.
  # Compare numerically, not by pattern: "00" is all digits and still zero, and head -n 00
  # then fails and drops the section's content.
  local cap_ok=no
  case "$cap" in
    ''|*[!0-9]*) ;;
    *) [ "$cap" -gt 0 ] 2>/dev/null && cap_ok=yes ;;
  esac
  if [ "$cap_ok" = no ]; then
    log "changelog[$name]: AUTODREAM_CHANGELOG_MAX_LINES='$cap' is not a positive integer; using 400"
    cap=400
  fi
  total=$(printf '%s\n' "$added" | wc -l | tr -d ' ')
  if [ "${total:-0}" -gt "$cap" ]; then
    added=$(printf '%s\n' "$added" | head -n "$cap")
    added="$added
[...truncated: $total lines in window, showing first $cap. Raise AUTODREAM_CHANGELOG_MAX_LINES to see the rest.]"
    log "changelog[$name]: $total lines truncated to $cap"
  fi

  if [ "${n:-0}" -gt 0 ] && [ -n "$added" ]; then
    printf '## %s\n# Source: %s @ %s (%s)\n# Commits touching the changelog in window: %s\n\n%s\n\n' \
      "$name" "$remote" "$head_sha" "$path" "$n" "$added" >> "$out"
    log "changelog[$name]: $n commit(s) in window"
  else
    printf '## %s\n# Source: %s @ %s (%s)\n\nNo changelog commits in this window.\n\n' \
      "$name" "$remote" "$head_sha" "$path" >> "$out"
    log "changelog[$name]: no commits in window"
  fi
}

changelog_window() {
  local out="$FINDINGS_DIR/changelog-window.md"
  [ "${AUTODREAM_CHANGELOG:-1}" != "0" ] || { log "changelog check disabled (AUTODREAM_CHANGELOG=0)"; return 0; }
  command -v git >/dev/null 2>&1 || { log "changelog: git not found; skipping"; return 0; }

  local srcs; srcs=$(changelog_sources)
  # Truncate once here, then every section appends. Nothing in this function may wrap the
  # loop in a `> "$out"` block: log() writes to stdout, so that would file the runner's
  # own progress lines as upstream release notes.
  printf '# Harness changelogs — commits in [%s, %s)\n\n' "$TARGET_DATE" "$NEXT_DATE" > "$out"
  local name remote path repo
  # Here-string rather than a pipe: a piped while-read runs in a subshell, which is a trap
  # the moment this loop needs to set a variable the caller reads.
  while IFS='|' read -r name remote path repo; do
    [ -n "$name" ] || continue
    changelog_one "$name" "$remote" "$path" "$repo" "$out"
  done <<< "$srcs"
  log "changelog: window written -> $out"
}

# ---- Sleep/network resilience helpers ----
# A laptop that sleeps mid-run loses the network and whole batches of workers fail
# (this is the common overnight failure: started on a brief wake, slept through the
# run, ~half the workers errored, L2 produced no report). The L1 worker is already
# idempotent — a session with a findings JSON is skipped — so we can just re-dispatch
# the still-missing sessions across wake/sleep cycles until they all land, and retry
# L2 until a report exists. Tunable; network-wait/sleep are disabled in tests.

# A report is COMPLETE when it carries the end-of-document marker PROMPT.md mandates, not
# merely when its path is non-empty. `-s` cannot tell a finished report from one the
# aggregator was killed halfway through writing, and a truncated report satisfies `-s`
# exactly as well as a good one. That mattered three separate ways: the L2 retry loop
# would break after attempt 1 on a partial file, the superseded good copy would be
# deleted, and the consume gate would archive the user's notes and stamp bookmarks read
# against a half-written report. Mid-write death is precisely the sleep-kill scenario all
# of this exists for, so "non-empty" was never the right test. The marker is the last
# thing PROMPT.md emits, which is what makes its presence mean the write reached the end.
#
# Deliberately not `L2_RC -eq 0`: the CLI can exit non-zero after a perfectly good write.
report_complete() {
  # Both gates live in report_finishes(): the marker says the write reached the
  # end, the questions block says the section four consumers read is where they
  # think it is. The live gate, the abandoned-date sweep and the pin sweep call
  # the same function so they cannot disagree about whether a date is finished.
  report_finishes "$REPORT_PATH" "${TARGET_DATE:-}"
}

# ---- L2 attempt diagnostics (issue 42) ----
# L2 attempt 1 has died with exit 143 (SIGTERM) and a bare "Execution error" on 2026-08-01,
# 08-31, 09-02, 09-04, 09-19 and 10-02, and nothing in the log says who sent the signal.
# run.sh applies no timeout of its own to L2, so the TERM comes from outside. When an attempt
# exits 143, 137 or 124, l2_diag_end writes findings/<date>/l2-attempt-N.diag: timestamps, the
# exit code, the worker's pid and parent chain, the launchd job's state, load, memory pressure,
# the kernel's last sleep and wake times, and the other autodream or claude processes.
#
# Evidence only. Every probe runs bounded (3s) in its own background job and cannot fail the
# run: a hung launchctl costs three seconds, a missing tool costs one line. No behavior depends
# on any of it.
l2_diag_probe() { # $1=heading, rest=command (function or binary). Always returns 0.
  local title="$1" out pid i=0
  shift
  printf '## %s\n' "$title"
  out=$(mktemp "${TMPDIR:-/tmp}/l2diag.XXXXXX" 2>/dev/null) || { echo "(no scratch file)"; return 0; }
  ( "$@" > "$out" 2>&1 ) &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    pkill -P "$pid" 2>/dev/null
    kill -9 "$pid" 2>/dev/null
    echo "(probe still running after 3s; abandoned)"
  fi
  wait "$pid" 2>/dev/null
  # Line-based, so a huge command line cannot cut the output mid-line and glue the next heading to it.
  cut -c1-600 "$out" 2>/dev/null | head -n 80
  rm -f "$out"
  return 0
}

l2_diag_chain() { # $1=pid: that process and every parent up to launchd
  local p="$1" n=0
  while [ "${p:-0}" -gt 0 ] 2>/dev/null && [ "$n" -lt 10 ]; do
    ps -o pid=,ppid=,pgid=,etime=,user=,command= -p "$p" 2>/dev/null
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    n=$((n + 1))
  done
}

l2_diag_memory() { # kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical
  printf 'vm_pressure_level: %s (1 normal, 2 warn, 4 critical)\n' "$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)"
  sysctl vm.swapusage 2>/dev/null
  vm_stat 2>/dev/null | head -6
}

l2_diag_launchd() { # $1=label: the job's state, user domain first, then the login session's
  local uid out; uid=$(id -u)
  out=$(launchctl print "gui/$uid/$1" 2>&1) || out=$(launchctl print "user/$uid/$1" 2>&1)
  printf '%s\n' "$out" | head -60
}

l2_diag_jobs() { # the label is not always known to the runner; the job list names it, with pid and last exit
  launchctl list 2>&1 | grep -iE 'autodream|^PID' | head -20
}

l2_diag_sleepwake() { # the kernel's last sleep and wake, so a sleep inside the attempt shows
  local k v
  for k in sleeptime waketime boottime; do
    v=$(sysctl -n "kern.$k" 2>/dev/null | sed -n 's/.*sec = \([0-9]*\).*/\1/p')
    printf '%s: %s (%s)\n' "$k" "${v:-unknown}" "$([ -n "$v" ] && pdate_fmt_epoch "$v" "+%a %b %e %H:%M:%S %Y")"
  done
  pmset -g batt 2>/dev/null | head -2
}

l2_diag_procs() { # every other autodream or claude process, with its parent and age
  ps -axo pid=,ppid=,etime=,command= 2>/dev/null | grep -E 'autodream|claude' | grep -v 'grep -E' | head -40
}

l2_diag_snapshot() { # $1=when: the host's state at one moment
  l2_diag_probe "load average at $1" uptime
  l2_diag_probe "memory pressure at $1" l2_diag_memory
}

# The start half of the record is gathered by a background job, so an attempt that goes on to
# succeed (nearly all of them, and every one in the test suite) pays nothing for it. Sets
# L2_DIAG_T0, L2_DIAG_FILE (the job's output) and L2_DIAG_JOB (its pid); l2_diag_end collects it.
l2_diag_start_body() {
  printf 'start_time: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf 'runner_pid: %s\n' "$$"
  l2_diag_probe "parent chain at start (runner first)" l2_diag_chain "$$"
  l2_diag_snapshot start
}

l2_diag_start() {
  L2_DIAG_T0=$(date +%s); L2_DIAG_FILE=""; L2_DIAG_JOB=""
  L2_DIAG_FILE=$(mktemp "${TMPDIR:-/tmp}/l2start.XXXXXX" 2>/dev/null) || { L2_DIAG_FILE=""; L2_DIAG_JOB=""; return 0; }
  ( l2_diag_start_body > "$L2_DIAG_FILE" 2>&1 < /dev/null ) &
  L2_DIAG_JOB=$!
}

# Stop the start job, wait at most 3s for it first when its output is wanted, and print what it wrote.
l2_diag_collect() { # $1=1 to wait for the job and print its output, 0 to discard it
  local i=0
  if [ "$1" = 1 ]; then
    while [ -n "${L2_DIAG_JOB:-}" ] && kill -0 "${L2_DIAG_JOB:-}" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
    cat "${L2_DIAG_FILE:-}" 2>/dev/null
  fi
  [ -n "${L2_DIAG_JOB:-}" ] && { pkill -P "${L2_DIAG_JOB:-}" 2>/dev/null; kill "${L2_DIAG_JOB:-}" 2>/dev/null; wait "${L2_DIAG_JOB:-}" 2>/dev/null; }
  [ -n "${L2_DIAG_FILE:-}" ] && rm -f "${L2_DIAG_FILE:-}"
  return 0
}

# $1=attempt $2=attempts $3=exit code $4=file holding the worker pid; reads l2_diag_start's globals
l2_diag_end() {
  local n="$1" total="$2" rc="$3" pidfile="$4" f end label worker start
  case "$rc" in 143|137|124) ;; *) l2_diag_collect 0; return 0 ;; esac
  f="$FINDINGS_DIR/l2-attempt-$n.diag"
  end=$(date +%s)
  start=$(l2_diag_collect 1)
  worker=$(cat "$pidfile" 2>/dev/null)
  label="${AUTODREAM_LAUNCHD_LABEL:-${XPC_SERVICE_NAME:-}}"
  {
    printf 'attempt: %s/%s\n' "$n" "$total"
    printf 'exit_code: %s\n' "$rc"
    printf 'worker_pid: %s\n' "${worker:-unknown}"
    printf 'end_epoch: %s\n' "$end"
    printf 'start_epoch: %s\n' "${L2_DIAG_T0:-unknown}"
    printf 'elapsed_seconds: %s\n' "$(( end - ${L2_DIAG_T0:-$end} ))"
    printf 'runner_timeout_fired: no (run.sh applies no timeout to L2, so exit %s came from the engine process or a signal sent to it)\n' "$rc"
    printf 'runner_survived: yes (this runner reached the end of the attempt, so the signal did not hit it)\n'
    printf 'launchd_label: %s\n' "${label:-none}"
    printf '%s\n' "$start"
    l2_diag_snapshot end
    l2_diag_probe "sleep and wake times" l2_diag_sleepwake
    l2_diag_probe "worker at end (gone means it died)" ps -o pid=,ppid=,etime=,command= -p "${worker:-0}"
    l2_diag_probe "other autodream or claude processes at end" l2_diag_procs
    l2_diag_probe "launchd jobs naming autodream at end" l2_diag_jobs
    case "$label" in ""|0) ;; *) l2_diag_probe "launchd job state at end" l2_diag_launchd "$label" ;; esac
  } > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null && log "L2 attempt $n exited $rc; diagnostics in $f" || rm -f "$f.tmp" 2>/dev/null
  return 0
}

# Whether the report at $REPORT_PATH finishes this date, for the idempotency guard (#111).
# The guard used to test only `-s`, so a half-written report (a run killed mid-write, or an
# older runner's partial) read as done: every later trigger no-opped, and question-streaks
# cleared the board over it. A complete report carries the marker. A report for a date before
# AUTODREAM_MARKER_EPOCH predates the marker, and is the same exemption unassembled_dates()
# makes, so the two cannot disagree about whether a date is finished.
report_finishes_date() {
  [ -s "$REPORT_PATH" ] || return 1
  report_complete && return 0
  [[ "$TARGET_DATE" < "${AUTODREAM_MARKER_EPOCH:-2026-08-19}" ]]
}

# Pins that a complete report left behind and no run ever finished applying: the run died between
# the report landing and the pin step (issue 72), or a store call failed or the CLI was missing and
# no one reran that date (issue 69). Nothing else revisits an old date: the nightly only
# processes yesterday and the idempotency guard skips a date that has a report.
#
# A findings dir in the trailing window qualifies when it holds a non-empty pins.jsonl, the
# pin-projects.tsv the run that proposed them wrote (the authorization list, never rebuilt here
# from files a model could have touched), a complete report no older than the pins (older means
# the report is not the one behind them), and either no pins-result.txt or counters showing
# failed, cli_missing, unreadable or unsupported_harness pins. The ledger makes the rerun
# safe: a pin already stored is a duplicate. A pin that cannot be stored is retried each
# night until its date leaves the window.
# $1=date label -> 0 when that date's run lock exists and its pid is alive. Unlike
# acquire_run_lock it never reclaims a stale lock; it only reads.
lock_held_by_live_run() {
  local lock="$AUTODREAM_DIR/locks/run-$1.lock" pid
  pid=$(cat "$lock/pid" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

sweep_stranded_pins() {
  local window="${AUTODREAM_UNASSEMBLED_WINDOW:-7}" root="$AUTODREAM_DIR/findings"
  local d label report res n
  [ -d "$root" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    label=$(basename "$d")
    [ -s "$d/pins.jsonl" ] || continue
    # A forced rebuild of the target date replaces its pins; the rebuild owns them.
    [ "$label" = "$TARGET_DATE" ] && [ "${AUTODREAM_FORCE:-0}" = "1" ] && continue
    report="$DREAMS_DIR/$label.md"
    report_finishes "$report" "$label" || continue
    [ ! "$d/pins.jsonl" -nt "$report" ] || continue
    # Another date's own run may be in its pin step right now (autodream-now.sh runs under a
    # different launchd label). Two apply-pins on one date both read the ledger before either
    # appends, and store a pin twice, so a date whose lock is held by a live pid is left alone.
    if [ "$label" != "$TARGET_DATE" ] && lock_held_by_live_run "$label"; then
      log "pin sweep: $label has a run in flight; leaving its pins to that run"
      continue
    fi
    res="$d/pins-result.txt"
    # A result file older than the pins describes an earlier run of the date (a forced rebuild
    # replaced the pins and died before applying them), so it settles nothing.
    if [ -e "$res" ] && [ ! "$d/pins.jsonl" -nt "$res" ]; then
      n=$(awk -F': ' '/^pins_(failed|cli_missing|unreadable|unsupported_harness): / { t += $2 } END { print t + 0 }' "$res" 2>/dev/null)
      [ "${n:-0}" -gt 0 ] || continue
    fi
    if [ ! -s "$d/pin-projects.tsv" ]; then
      log "pin sweep: $label has pins but no pin-projects.tsv, so no project is authorized; they stay in $d/pins.jsonl"
      continue
    fi
    log "pin sweep: applying the pins $label never finished storing"
    bash "$APPLY_PINS" "$d" "$label" >> "$RUN_LOG" 2>&1 \
      || log "pin sweep: apply-pins exited non-zero for $label (counters unavailable)"
    [ ! -r "$res" ] || log "pin sweep: $label: $(tr '\n' ' ' < "$res")"
  done < <(find "$root" -maxdepth 1 -type d -name '2[0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]' 2>/dev/null \
    | sort | tail -n "$window")
}

# ---- One run per date at a time (#55) ----
# launchd serialises a label against itself and nothing more, and autodream-now.sh runs
# under a different label than the scheduled nightly, so an on-demand run and a trigger for
# the same date are two processes sharing one findings dir, one sidecar set and one report
# path. The second one's move-aside would even carry off the first one's report mid-build.
# `mkdir` is the lock: atomic on every filesystem here, and needs no flock. The directory
# holds the owner's pid and process start time. A run killed mid-flight (this pipeline's
# documented failure mode) leaves the directory behind, so a holder that is gone, or whose
# pid now belongs to a different process, is reclaimed. The lock sits outside the findings
# dir, so clearing a date's findings for a clean rebuild cannot release it under a live run.
RUN_LOCK="$AUTODREAM_DIR/locks/run-$TARGET_DATE.lock"

proc_start() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '; }

# 0 = the lock's holder is alive, 1 = gone (stale), 2 = the holder has not written its pid yet.
run_lock_holder_state() {
  local pid start
  pid=$(cat "$RUN_LOCK/pid" 2>/dev/null) || pid=""
  [ -n "$pid" ] || return 2
  kill -0 "$pid" 2>/dev/null || return 1
  start=$(cat "$RUN_LOCK/start" 2>/dev/null) || start=""
  # No recorded start (ps unavailable): the live pid is all there is to go on.
  [ -z "$start" ] || [ "$(proc_start "$pid")" = "$start" ]
}

# Move the stale lock aside (rename is atomic, so one reclaimer wins) rather than rmdir it:
# a second reclaimer that judged the same stale holder must not delete the winner's NEW lock.
reclaim_run_lock() { # $1=the pid judged stale ("" when none was ever written)
  local dead="$RUN_LOCK.stale.$$"
  mv "$RUN_LOCK" "$dead" 2>/dev/null || return 0
  if [ "$(cat "$dead/pid" 2>/dev/null)" = "$1" ]; then
    rm -rf "$dead"
    return 0
  fi
  # We moved a lock that a faster reclaimer had already replaced. Put it back.
  mv "$dead" "$RUN_LOCK" 2>/dev/null || { log "WARNING: could not restore another run's lock from $dead"; return 0; }
}

# 0 = taken, 1 = another live run holds it. A lock directory that cannot be made at all
# (read-only state dir) does not stop the night: an unlocked run is the old behaviour.
acquire_run_lock() {
  mkdir -p "$(dirname "$RUN_LOCK")" 2>/dev/null || { log "WARNING: could not create $(dirname "$RUN_LOCK"); running without the per-date lock"; return 0; }
  local tries=0 st pid
  until mkdir "$RUN_LOCK" 2>/dev/null; do
    pid=$(cat "$RUN_LOCK/pid" 2>/dev/null) || pid=""
    run_lock_holder_state; st=$?
    [ "$st" -ne 0 ] || { RUN_LOCK_HOLDER="$pid"; return 1; }
    tries=$((tries + 1))
    if [ "$st" -eq 2 ] && [ "$tries" -le 3 ]; then sleep 1; continue; fi
    reclaim_run_lock "$pid"
    [ "$tries" -lt 8 ] || { RUN_LOCK_HOLDER="${pid:-unknown}"; return 1; }
  done
  printf '%s\n' "$$" > "$RUN_LOCK/pid"
  proc_start "$$" > "$RUN_LOCK/start"
  return 0
}

# Only the owner removes it. This is also installed as the EXIT trap, which a run that never
# took the lock reaches too, and which must not touch the holder's.
release_run_lock() {
  [ "$(cat "$RUN_LOCK/pid" 2>/dev/null)" = "$$" ] || return 0
  rm -rf "$RUN_LOCK"
}

# $1=adapter name $2=session path -> the project the session belongs to: the directory
# directly under the LONGEST of the adapter's roots that holds it, so with nested roots
# (/c and /c/projects) a session under /c/projects/<bucket> names <bucket>, not "projects".
# Claude nests transcripts at
# several depths under one bucket (<bucket>/<session>.jsonl, <bucket>/<session>/subagents/
# agent-*.jsonl, <bucket>/<session>/subagents/workflows/wf_*/agent-*.jsonl), and a bucket
# can itself be named "subagents", so no rule based on directory names finds the bucket at
# every depth. A session under none of the adapter's roots falls back to its parent dir.
session_project() {
  local r rest best=""
  if [ -n "$1" ]; then
    while IFS= read -r r; do
      r=${r%/}
      [ -n "$r" ] || continue
      case $2 in
        "$r"/*/*) [ "${#r}" -gt "${#best}" ] && best=$r ;;
      esac
    done < <(adapter_roots "$1")
  fi
  if [ -n "$best" ]; then
    rest=${2#"$best"/}
    printf '%s' "${rest%%/*}"
    return 0
  fi
  basename "$(dirname "$2")"
}

# $1=findings dir -> one hash<TAB>project<TAB>cwd row per session in sessions.txt. run.sh
# calls it before the first model call and holds the result in memory: L1 and L2 both run
# with the Write tool and bypassPermissions, so every file this reads, sessions.txt and
# sessions-source.txt included, is one they could rewrite before the pins are applied.
# The rows feed two consumers: pin_projects_from_rows (the pin authorization list) and the
# findings project normalization, which looks each findings file up by its hash.
#
# It walks sessions.txt, the runner's own worklist, and never a findings JSON. Outside the
# slim case a findings session_path is whatever the L1 model wrote, so reading it would let
# a transcript name another project's session and authorize memory there.
#
# A cwd is unusable, and recorded as "?", when the adapter cannot resolve it (usually a
# removed worktree), when it holds a tab or newline, or when its bucket is an encoded path
# (starts with "-") that the cwd does not encode to. Slug buckets from
# CLAUDE_CODE_PROJECT_DIR_NAME (owner-repo) skip that encoding check, because no cwd ever
# encodes to a slug. An adapter cwd is always absolute, so it can never be "?" itself.
session_rows() {
  local dir=$1 s hash src proj cwd
  # A missing worklist would otherwise read as "no projects" and refuse every pin silently.
  [ -r "$dir/sessions.txt" ] || return 1
  while IFS= read -r s <&3; do
    [ -n "$s" ] || continue
    hash=$(session_hash "$s") || continue
    src=$(awk -F'\t' -v h="$hash" '$1 == h { print $2; exit }' "$dir/sessions-source.txt" 2>/dev/null)
    proj=$(session_project "$src" "$s")
    case $proj in ''|*$'\t'*|*$'\n'*) continue ;; esac
    cwd="?"
    if [ -n "$src" ]; then
      cwd=$(adapter_run "$src" project "$s" 2>/dev/null </dev/null) || cwd="?"
      [ -n "$cwd" ] || cwd="?"
    fi
    case $cwd in *$'\t'*|*$'\n'*) cwd="?" ;; esac
    case $proj in
      -*) if [ "$cwd" != "?" ] && [ "$(encode_project "$cwd")" != "$proj" ]; then cwd="?"; fi ;;
    esac
    printf '%s\t%s\t%s\n' "$hash" "$proj" "$cwd"
  done 3< "$dir/sessions.txt"
}

# stdin: session_rows output -> one project<TAB>cwd row per project. A project gets a cwd
# only when all its sessions agree on one usable cwd. An unusable "?" still counts as a
# distinct cwd, so it makes the project ambiguous rather than vanishing. Anything looser
# stores one project's pin in another project's bank: a transcript sitting in a bucket its
# cwd does not encode to, or two directories that encode to one bucket (/tmp/a_b and
# /tmp/a-b). A project with no usable cwd keeps an empty column, and apply-pins.sh refuses
# its pins as no_cwd.
pin_projects_from_rows() {
  awk -F'\t' '
    NF < 3 { next }
    !($2 in seen) { seen[$2] = 1; order[++n] = $2 }
    !(($2, $3) in pair) { pair[$2, $3] = 1; count[$2]++; cwd[$2] = $3 }
    END {
      for (i = 1; i <= n; i++) {
        p = order[i]
        printf "%s\t%s\n", p, (count[p] == 1 && cwd[p] != "?" ? cwd[p] : "")
      }
    }
  '
}

# $1=findings dir -> writes the rows pin_projects_from_rows produced before L1 ran to
# pin-projects.tsv. The old file goes first, so an authorization list from an earlier run
# never outlives a failed write. Fails when the build itself failed.
write_pin_projects() {
  local dir=$1
  rm -f "$dir/pin-projects.tsv" || return 1
  [ "${PIN_PROJECTS_BUILT:-0}" = "1" ] || return 1
  if [ -n "$PIN_PROJECTS_TSV" ]; then printf '%s\n' "$PIN_PROJECTS_TSV"; fi > "$dir/pin-projects.tsv.tmp" \
    && mv "$dir/pin-projects.tsv.tmp" "$dir/pin-projects.tsv"
}

# $1=findings dir -> puts pins-applied.tsv back to what it held before any model ran (or removes
# it when it did not exist). Fails when it cannot.
restore_pins_ledger() {
  local f="$1/pins-applied.tsv" cur
  [ "${PINS_LEDGER_OK:-1}" = "1" ] || return 1
  if [ "${PINS_LEDGER_PRESENT:-0}" != "1" ]; then
    [ -e "$f" ] || return 0
    log "pins-applied.tsv appeared while the models ran; removing it"
    rm -f "$f"
    return
  fi
  cur=$(cat -- "$f" 2>/dev/null && printf x) || cur=""
  [ "$cur" != "$PINS_LEDGER_SNAPSHOT_X" ] || return 0
  log "pins-applied.tsv changed while the models ran; restoring it"
  printf '%s' "${PINS_LEDGER_SNAPSHOT_X%x}" > "$f.tmp" && mv -f "$f.tmp" "$f"
}

net_up() { # net_up [-l secs] URL: exit 0 if that host answers (any HTTP reply beats no reply)
  local code rc hdr limit maxt up=1
  local -a bound=()
  limit="${AUTODREAM_NETUP_LIMIT:-8}"
  if [ "${1:-}" = "-l" ]; then limit="$2"; shift 2; fi
  # No URL means the caller could not name a host to ask. That is "the check cannot answer", which
  # reads as up for the reason given at the exit-127 test below.
  [ -n "${1:-}" ] || return 0
  # A network filter can hold curl in close() after the reply has already arrived (found at the
  # 2026-10-03 cutover: Little Snitch on this host). curl then prints nothing and its own --max-time
  # cannot interrupt a close(), so the probe read a healthy network as down and the run waited out
  # the whole cap. The status line is written to a header file the moment it arrives, so a reply
  # counts even when curl never gets to report it, and a timeout binary bounds the stall.
  [ -z "${TIMEOUT_BIN:-}" ] || bound=("$TIMEOUT_BIN" -k 2 "$limit")
  hdr=$(mktemp "${TMPDIR:-/tmp}/netup.XXXXXX" 2>/dev/null) || hdr=""
  # curl's own limit never exceeds the probe's, so a host without a timeout binary is bounded too.
  maxt=5; [ "$limit" -lt "$maxt" ] 2>/dev/null && maxt="$limit"
  code=$(${bound[@]+"${bound[@]}"} curl -s --max-time "$maxt" -o /dev/null ${hdr:+-D "$hdr"} -w '%{http_code}' "$1" 2>/dev/null); rc=$?
  # 127 is "not found" and 126 is "found but not executable". Both mean the shell could
  # not run curl at all — absent, not executable.
  # That is "the check cannot answer", not "the host is down", and reading it as down
  # made a machine without curl wait out the full cap and defer a healthy run, every
  # run, for a reason nothing reported. Bias to up: a wrong "up" costs one round of
  # workers, a wrong "down" costs the whole date. Checking the exit status rather than
  # `command -v` also covers a curl that is present but unrunnable.
  { [ "$rc" -eq 127 ] || [ "$rc" -eq 126 ]; } && up=0
  if [ "$up" -ne 0 ] && [ -n "$code" ] && [ "$code" != "000" ]; then up=0; fi
  if [ "$up" -ne 0 ] && [ -n "$hdr" ] && grep -q '^HTTP/' "$hdr" 2>/dev/null; then up=0; fi
  [ -z "$hdr" ] || rm -f "$hdr"
  return "$up"
}

# Seconds this run spent blocked on wait_for_network, summed across rounds. Reported in
# run-stats.txt so the self-audit can tell an outage from a transcript problem — on
# 2026-09-04 it could not, and blamed 90 minutes of dead network on oversized transcripts.
NET_DOWN_SECONDS=0

# The URLs the L1 workers need, one per distinct provider (any one answering opens the gate): each enabled adapter's own L1 model,
# not a fixed host. Empty when no adapter has a resolvable provider, which wait_for_network reads
# as "nothing to ask". Read from the per-source map, which was resolved against each source's L1
# engine (AUTODREAM_L1_ENGINE_<NAME>): an omp source on the claude engine needs anthropic.
l1_probe_urls() {
  local src url
  while IFS=$'\t' read -r src url; do
    [ -n "$src" ] && [ -n "$url" ] || continue
    printf '%s\n' "$url"
  done <<< "${AUTODREAM_L1_PROBE_URLS:-}" | awk 'NF && !seen[$0]++'
}

l2_probe_url() { provider_probe_url "$L2_ENGINE" "$L2_MODEL" 2>/dev/null; }

# $1 = the URLs to gate on, one per line; the network is up when any one answers. A dead route to one provider
# must not hold back sessions that run on another: a worker that does need the dead one fails,
# is classified as an outage by its own probe, and defers the date through the existing path. The cap is wall-clock and counts the probes
# themselves: it used to count only the sleeps, so each probe (up to AUTODREAM_NETUP_LIMIT) ran past
# the bound it was handed, and a hung one was only noticed after it returned. A probe now gets at
# most what is left of the cap, and the first one always runs, so a cap of 0 still asks once.
wait_for_network() { # 0 = network is up, 1 = gave up after the cap; no-op when AUTODREAM_NETCHECK=0
  [ "${AUTODREAM_NETCHECK:-1}" != "0" ] || return 0
  [ -n "${1:-}" ] || return 0
  local start elapsed step left lim url down cap="${AUTODREAM_NETCHECK_CAP:-1800}" probe="${AUTODREAM_NETUP_LIMIT:-8}"
  # A non-numeric cap makes every [ "$elapsed" -ge "$cap" ] test error out, and an erroring
  # test reads as false — so the give-up branch became unreachable and the bound that was
  # supposed to limit the wait removed it instead.
  case "$cap" in ''|*[!0-9]*) log "AUTODREAM_NETCHECK_CAP='$cap' is not a number; using 1800"; cap=1800 ;; esac
  start=$(date +%s)
  while :; do
    down=1; asked=0
    while IFS= read -r url; do
      # Sized per URL, not per pass: with several providers down, every probe in the pass spends
      # the same clock the cap is counting. Once it is spent, the pass stops: a floor of 1s on
      # every later URL ran the pass N-1 probes past the cap. Only the first probe floors, so a
      # cap of 0 still asks once.
      left=$(( cap - ($(date +%s) - start) ))
      [ "$left" -ge 1 ] || [ "$asked" -eq 0 ] || break
      [ "$left" -ge 1 ] || left=1
      asked=1
      lim=$probe; [ "$left" -lt "$lim" ] && lim=$left
      if net_up -l "$lim" "$url"; then down=0; break; fi
      log "no answer from $url"
    done <<< "$1"
    [ "$down" -eq 1 ] || break
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$cap" ]; then
      NET_DOWN_SECONDS=$((NET_DOWN_SECONDS + elapsed))
      log "network still down after ~${elapsed}s of checks (cap ${cap}s)"
      # Was `return 0` — "proceeding anyway". Proceeding meant dispatching a full round
      # of workers at a host with no route, which fails every one of them in ~9s and
      # burns a retry round to learn nothing. The caller now defers the date instead.
      return 1
    fi
    log "waiting for network to return... (${elapsed}s)"
    # Never sleep past the cap. A fixed 15s step meant any cap below 15 still waited a
    # full 15 seconds, so the wait overran the bound it was handed and reported a
    # network_down_seconds larger than the configured maximum.
    step=$(( cap - elapsed )); [ "$step" -gt 15 ] && step=15
    sleep "$step"
  done
  # Down time is from the first failed probe to the one that answered. A healthy first probe adds nothing.
  [ -z "${elapsed:-}" ] || NET_DOWN_SECONDS=$((NET_DOWN_SECONDS + $(date +%s) - start))
  return 0
}

# The one test for a usable findings JSON, run with jq -s: exactly one JSON value, an object, with a
# findings array. jq -e judges only the LAST value in a file, so a forged object followed by a good
# one passed the old `.findings | arrays` check and L2 read the first (#167). merge-chunks.sh --check
# is the same rule for chunk answers. Exported because the worker is a separate bash -c.
export L1_FINDINGS_OK='length == 1 and (.[0] | type == "object" and (.findings | type) == "array")'

l1_missing_count() { # count sessions in $SESSIONS_LIST that still have no findings JSON
  local m=0 s h
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    # An unvalidated hash here counts the session missing forever and the retry
    # loop re-dispatches it every round.
    h=$(session_hash "$s") || { m=$((m + 1)); continue; }
    # Same check the dispatcher applies on the way out (L1_FINDINGS_OK).
    jq -s -e "$L1_FINDINGS_OK" "$FINDINGS_DIR/$h.json" >/dev/null 2>&1 || m=$((m + 1))
  done < "$SESSIONS_LIST"
  printf '%s' "$m"
}

# What chunked triage cost tonight, from the two ledgers: "sessions chunks elided calls". Sessions
# and chunks count what the chunker planned (the last plan per session, since a retry plans again),
# elided the chunks it dropped from the middle, calls the engine calls actually made. A night with
# chunking off, or with nothing over the limit, reads 0 0 0 0.
l1_chunk_totals() {
  local plans calls
  plans=$(awk 'NF >= 3 { n[$1] = $2; e[$1] = $3 } END { for (h in n) { s++; c += n[h]; x += e[h] } printf "%d %d %d", s, c, x }' \
            "$FINDINGS_DIR/l1-chunks.txt" 2>/dev/null)
  calls=$(grep -c . "$FINDINGS_DIR/l1-chunk-calls.txt" 2>/dev/null || true)
  printf '%s %s\n' "${plans:-0 0 0}" "${calls:-0}"
}

# Finished chunk answers on disk. A round that completes chunks but no whole session has still made
# progress, and the circuit breaker below would otherwise read it as a barren round. Always 0 when
# chunking is off (the directory does not exist), so the breaker is what it was.
l1_chunk_answers() {
  find "$FINDINGS_DIR/.chunks" -type f -name '*.chunkout' 2>/dev/null | wc -l | tr -d ' '
}

# True when a findings file carries the top-level error key: what the runner writes for a
# failed triage and what the L1 prompt tells a worker to write when it cannot fit a
# transcript. A text match on "error": would also fire on a successful file whose evidence
# quotes one, and with no .err to classify it that file would drop out of both sides of the
# size-attributable share.
findings_has_error() { # $1=findings file
  jq -e 'type == "object" and has("error")' "$1" >/dev/null 2>&1
}

findings_json_count() {
  find "$FINDINGS_DIR" -maxdepth 1 -type f -name '*.json' ! -name '*.stats.json' 2>/dev/null \
    | wc -l | tr -d ' '
}

# Two kinds of leftover that this run's worklist does not own (#113). Both read SESSIONS_LIST,
# which is empty on a night that found nothing, so the same scan serves the early stub exit.
#
# An orphaned .err is a failed triage nobody has finished: no findings JSON beside it, and its
# session is not in the worklist (the file is gone, or this run no longer places it in the day).
# While its session is in the worklist the retry loop owns it and l1_missing_count counts it;
# one with no owner is retried by nothing and seen by no other counter, so l1_err_files cannot
# tell "two workers crashed tonight" from "two crashed last week and nobody retried". Counted
# and named, not retried: the .err is the only record of which session it was, and a worker with
# the Write tool could have put any path in it.
#
# A findings JSON outside the worklist is handled by reconcile_findings_with_worklist.
worklist_hashes() {
  [ -f "$SESSIONS_LIST" ] || return 0
  # session_hash prints no trailing newline, so each hash is printed on its own line here:
  # grep -x below matches whole lines, and two hashes run together never match anything.
  local _s _h
  while IFS= read -r _s; do
    [ -n "$_s" ] || continue
    _h=$(session_hash "$_s") || continue
    printf '%s\n' "$_h"
  done < "$SESSIONS_LIST"
}
# L2 reads every findings JSON in the directory, and a forced rerun reuses the directory, so a
# JSON left by an earlier run for a session this run's worklist no longer owns would reach the
# report as that day's work (#56). It is silent: a stale <hash>.json is a well-formed record.
# The ones outside the worklist are moved to outside-worklist/, which L2's glob does not reach,
# and counted and named. Moved, not deleted: deleting findings is not this runner's call, and a
# later rebuild whose worklist owns the session again gets its JSON back before L1 runs, so the
# rerun does not pay for the triage twice. Runs once per run, before the pre-L1 cache snapshot.
reconcile_findings_with_worklist() {
  FINDINGS_OUTSIDE_WORKLIST=0; OUTSIDE_FINDINGS_NAMES=""
  local _hashes _f _h _dest _q="$FINDINGS_DIR/outside-worklist"
  _hashes=$(worklist_hashes)
  for _f in "$_q"/*.json; do
    [ -f "$_f" ] || continue
    _h=$(basename "$_f" .json)
    printf '%s\n' "$_hashes" | grep -qxF "$_h" || continue
    if [ -e "$FINDINGS_DIR/$_h.json" ]; then
      log "WARNING: $_h.json is in outside-worklist/ and in the findings dir; leaving the set-aside copy where it is"
      continue
    fi
    if mv "$_f" "$FINDINGS_DIR/$_h.json" 2>/dev/null; then
      log "restored $_h.json from outside-worklist/: its session is in this run's worklist again"
    else
      log "WARNING: could not restore $_f; this session will be triaged again"
    fi
  done
  for _f in "$FINDINGS_DIR"/*.json; do
    [ -f "$_f" ] || continue
    _h=$(basename "$_f" .json)
    case "$_h" in *[!0-9a-f]*|"") continue ;; esac
    [ "${#_h}" -eq 12 ] || continue
    printf '%s\n' "$_hashes" | grep -qxF "$_h" && continue
    # Never overwrite an earlier set-aside copy: a second one gets a timestamped name.
    _dest="$_q/$_h.json"
    [ ! -e "$_dest" ] || _dest="$_q/$_h.json.$(date +%s)"
    if ! { mkdir -p "$_q" && mv "$_f" "$_dest"; } 2>/dev/null; then
      log "WARNING: could not set aside $_f; L2 will read it though its session is not in this run's worklist"
      continue
    fi
    FINDINGS_OUTSIDE_WORKLIST=$((FINDINGS_OUTSIDE_WORKLIST + 1))
    OUTSIDE_FINDINGS_NAMES="${OUTSIDE_FINDINGS_NAMES:+$OUTSIDE_FINDINGS_NAMES }$_h"
  done
  if [ "$FINDINGS_OUTSIDE_WORKLIST" -gt 0 ]; then
    log "WARNING: $FINDINGS_OUTSIDE_WORKLIST findings JSON(s) belong to no session in this run's worklist; moved to $_q so L2 does not read them: $OUTSIDE_FINDINGS_NAMES"
  fi
}
# A cached L1 result is reused only if this run would accept it now, for two reasons.
#
# A no-engine record (no_engine, written by dispatch_l1 when a source had no usable engine) is
# final only for the config that wrote it: an engine choice naming no accepted adapter, a missing
# model, a login failing AUTODREAM_REQUIRE_LOGIN. Once this run resolves an engine and a model for
# the session's source, the record is dropped and the session triaged. The source comes from
# AUTODREAM_SOURCE_MAP, never from the record, which a worker could have written.
#
# With AUTODREAM_L1_REQUIRE_SERVED=1, a findings JSON or chunk answer a model wrote is held to the
# verdict the runner stored beside it (<answer>.served, written in dispatch_l1): one with no
# verdict, or any verdict but match, came from a run that did not require it, or from before the
# verdict existed, and is dropped so this run triages it again. A record the runner wrote itself,
# with no model behind it (a noise-gate skip, an unreadable session, a normalize failure, a
# no-engine record, a final-round stub), is kept when its .served says runner and its findings are
# empty. Provenance comes from that marker, which the runner writes, never from the record's keys
# or shape: a worker can write error, skipped or no_engine as easily as the runner can (#167). A
# runner record from before the marker existed is triaged once more and comes back marked.
#
# The limit, which this shares with the match verdict: every .served lives in the findings dir,
# where a worker holding the Write tool can reach it, so a worker that rewrites ANOTHER session's
# record and its .served together is not caught here. The dispatcher replaces each worker's own
# .served after it exits, which covers the worker's own session only. Closing the cross-session
# case needs provenance a worker cannot write at all, not a better check on these files.
#
# Runs once, after reconcile_findings_with_worklist and before the pre-L1 cache snapshot, so the
# dispatcher, l1_missing_count and L1_PRECACHED all see the same set. Counted in run-stats as
# l1_cache_dropped and named in the log.
L1_CACHE_DROPPED=0
drop_unacceptable_l1_cache() {
  L1_CACHE_DROPPED=0
  local _h _f _src _unrouted="" _unverified="" _chunks=0 _served=0
  [ "${AUTODREAM_L1_REQUIRE_SERVED:-0}" = 1 ] && _served=1
  while IFS= read -r _h; do
    [ -n "$_h" ] || continue
    _f="$FINDINGS_DIR/$_h.json"
    [ -f "$_f" ] || continue
    # Dropping a no-engine record only costs a triage, so its shape is enough to do that.
    if l1_record_has_no_engine "$_f"; then
      _src=$(printf '%s\n' "$AUTODREAM_SOURCE_MAP" | awk -F'\t' -v h="$_h" '$1 == h { print $2; exit }')
      if l1_source_has_engine "$_src"; then
        rm -f "$_f" "$_f.served"
        L1_CACHE_DROPPED=$((L1_CACHE_DROPPED + 1)); _unrouted="${_unrouted:+$_unrouted }$_h"
        continue
      fi
    fi
    [ "$_served" = 1 ] || continue
    l1_record_is_runner_only "$_f" && continue
    [ "$(served_verdict "$_f")" = match ] && continue
    rm -f "$_f" "$_f.served"
    L1_CACHE_DROPPED=$((L1_CACHE_DROPPED + 1)); _unverified="${_unverified:+$_unverified }$_h"
  done < <(worklist_hashes)
  if [ "$_served" = 1 ]; then
    for _f in "$FINDINGS_DIR"/.chunks/*/*.chunkout; do
      [ -f "$_f" ] || continue
      [ "$(served_verdict "$_f")" = match ] && continue
      rm -f "$_f" "$_f.served"
      L1_CACHE_DROPPED=$((L1_CACHE_DROPPED + 1)); _chunks=$((_chunks + 1))
    done
  fi
  [ -z "$_unrouted" ] || log "dropped no-engine record(s) whose source now has an L1 engine, to triage again: $_unrouted"
  [ -z "$_unverified" ] && [ "$_chunks" -eq 0 ] \
    || log "AUTODREAM_L1_REQUIRE_SERVED=1: dropped cached L1 result(s) no served verdict vouches for, to triage again (sessions: ${_unverified:-none}; chunk answers: $_chunks)"
}
# 0 for a no-engine record, by its no_engine key or, for one written before the key, by its error.
# Only ever used to drop a record, so a worker that forges one buys itself a retriage, nothing more.
l1_record_has_no_engine() { # $1=findings JSON
  jq -s -e 'length == 1 and (.[0] | (.no_engine == true or ((.error // "") | tostring | startswith("no L1 engine for this session"))) and .findings == [])' "$1" >/dev/null 2>&1
}
# 0 when this run resolved an engine and a model for the source, as dispatch_l1 will read them.
l1_source_has_engine() { # $1=source adapter
  local _e _m
  case "$1" in ""|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*) return 1 ;; esac
  _e=$(printf '%s\n' "$AUTODREAM_L1_ENGINES" | awk -F'\t' -v s="$1" '$1 == s { print $2; exit }')
  _m=$(printf '%s\n' "$AUTODREAM_L1_MODELS" | awk -F'\t' -v s="$1" '$1 == s { print $2; exit }')
  case "$_e" in ""|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*) return 1 ;; esac
  [ -n "$_m" ] && [ -x "$ADAPTERS_DIR/$_e/adapter.sh" ]
}
# 0 for a record the runner wrote with no model behind it: its .served says runner (the dispatcher
# writes that marker beside every such record) and it holds one value with no findings. The empty
# findings array is a second guard, for a worker that rewrites another session's record in place.
l1_record_is_runner_only() { # $1=findings JSON
  [ "$(served_verdict "$1")" = runner ] || return 1
  jq -s -e 'length == 1 and .[0].findings == []' "$1" >/dev/null 2>&1
}
served_verdict() { cut -s -f4 "$1.served" 2>/dev/null | head -1; } # $1=answer -> its stored verdict
scan_worklist_leftovers() {
  L1_ERR_ORPHANED=0; ORPHAN_ERR_NAMES=""
  local _hashes _f _h
  _hashes=$(worklist_hashes)
  for _f in "$FINDINGS_DIR"/*.json.err; do
    [ -f "$_f" ] || continue
    _h=$(basename "$_f" .json.err)
    [ ! -f "$FINDINGS_DIR/$_h.json" ] || continue
    printf '%s\n' "$_hashes" | grep -qxF "$_h" && continue
    L1_ERR_ORPHANED=$((L1_ERR_ORPHANED + 1))
    ORPHAN_ERR_NAMES="${ORPHAN_ERR_NAMES:+$ORPHAN_ERR_NAMES }$_h"
  done
  if [ "$L1_ERR_ORPHANED" -gt 0 ]; then
    log "WARNING: $L1_ERR_ORPHANED .err file(s) have no findings JSON and belong to no session in this run's worklist, so nothing will retry them: $ORPHAN_ERR_NAMES"
  fi
}

# Cut a transcript down to the report day's records. 0 = the slice was written to $2,
# 1 = nothing to cut (the window is off, or every timestamped record is already inside the
# day) and $2 is untouched, 2 = the helper failed and the caller reads the whole transcript.
# A failed cut costs a larger read; it never costs the session.
day_slice() { # $1=transcript $2=slice path
  [ "$WINDOW_ON" = 1 ] || return 1
  bash "$SESSION_WINDOW" day-file "$1" "$WIN_START_EPOCH" "$WIN_END_EPOCH" "$2" </dev/null 2>/dev/null
}

compute_session_stats() {
  local session hash stats
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    # A hash failure means no sidecar is written for this session. It is NOT
    # counted here: stats_sidecars_unparseable is initialised to 0 in the
    # oversized-gate loop, which runs after this function, so an increment here
    # would be wiped — and referencing it before that assignment trips `set -u`
    # outright. That loop walks the same sessions.txt and counts this session
    # there, which is why the #27 fix reads the list rather than the sidecar
    # glob. Say it out loud here so the log names the session.
    hash=$(session_hash "$session") || {
      log "  WARNING: could not derive an artifact hash for $session; no stats sidecar will exist for it"
      continue
    }
    stats="$FINDINGS_DIR/$hash.stats.json"
    rm -f "$stats"
    # The session's own adapter computes its stats (omp records are not claude records). The
    # AUTODREAM_STATS_BIN override still wins, and a session with no recorded source keeps the
    # claude script, so an install that predates the source sidecar degrades instead of failing.
    local src stats_rc=1 statsin="$session" normtmp="" daytmp="" slice_rc
    src=$(awk -F'\t' -v h="$hash" '$1 == h { print $2; exit }' "$FINDINGS_DIR/sessions-source.txt" 2>/dev/null)
    local own_adapter=0
    if [ -z "${AUTODREAM_STATS_BIN:-}" ] && [ -n "$src" ] && [ "$src" != "claude" ] \
       && [ -x "$(adapters_root 2>/dev/null)/$src/adapter.sh" ]; then
      own_adapter=1
      # Stats describe the live conversation the worker will read, not the append-only tree it
      # came from: abandoned branches would otherwise add user turns and stretch the duration,
      # and the noise gate reads these numbers. So a normalizing adapter is linearized first.
      if [ "$(adapter_manifest_get "$src" '.normalize' 2>/dev/null)" = "true" ]; then
        normtmp="$FINDINGS_DIR/$hash.statsin.jsonl"
        if adapter_run "$src" normalize "$session" "$normtmp" >/dev/null 2>&1 && [ -s "$normtmp" ]; then
          statsin="$normtmp"
        else
          rm -f "$normtmp"; normtmp=""
        fi
      fi
    fi
    # Then cut to the report day. The order matters and is the same one the worker uses: a
    # tree is linearized FIRST and the live chain is what gets cut. Cutting the raw tree would
    # leave entries whose parent was cut away, and the linearizer fails closed on a dangling
    # parent, which would refuse every omp session that spans a day boundary.
    daytmp="$FINDINGS_DIR/$hash.statsday.jsonl"
    day_slice "$statsin" "$daytmp"; slice_rc=$?
    case "$slice_rc" in
      0) statsin="$daytmp"; SESSIONS_WINDOWED=$((SESSIONS_WINDOWED + 1)) ;;
      1) daytmp="" ;;
      *) daytmp=""; log "  WARNING: could not cut $session to $TARGET_DATE; its stats cover the whole transcript" ;;
    esac
    if [ "$own_adapter" = 1 ]; then
      adapter_run "$src" stats "$statsin" "$stats" >/dev/null 2>&1; stats_rc=$?
    elif [ -x "$STATS" ]; then
      "$STATS" "$statsin" "$stats" >/dev/null 2>&1; stats_rc=$?
    fi
    [ -z "$normtmp" ] || rm -f "$normtmp"
    [ -z "$daytmp" ] || rm -f "$daytmp"
    if [ "$stats_rc" -eq 0 ] && [ -s "$stats" ] && jq -e 'type == "object"' "$stats" >/dev/null 2>&1; then
      echo "stats: $session ($hash)" >&2
    else
      rm -f "$stats"
      echo "stats failed: $session ($hash); continuing without precomputed stats" >&2
    fi
  done < "$SESSIONS_LIST"
}

# ---- Global overlap pass (#14): cross-session "multi-clauding" stat ----
# Runs once compute_session_stats has written every session's *.stats.json sidecar
# (each carries the mechanical user_turn_timestamps array). Overlap is a GLOBAL,
# cross-session computation — it can't be done per-session inside compute_session_stats
# or dispatch_l1's xargs subshells, which only ever see one session at a time. Sets
# OVERLAP_EVENTS / SESSIONS_WITH_OVERLAP (default "0"/"0" on any failure/absence so the
# run-stats.txt writer always has a value, never aborts the pipeline) AND OVERLAP_MEASURED,
# a tri-state marker (#26) so a genuine zero-overlap night can't be confused with a
# non-measurement:
#   1 = a real measurement happened (overlap-stats.sh ran and produced parseable output,
#       even if the answer is 0 pairs / 0 sessions — that is a legitimate result)
#   0 = no measurement happened: the script was missing/not executable, produced no
#       output, or produced output jq couldn't extract both fields from. Each of these
#       gets its own explicit "not measured" log line so a non-measurement is never
#       silently reported as the same "overlap: 0 pair(s)" line as a real zero.
compute_overlap_stats() {
  OVERLAP_EVENTS=0
  SESSIONS_WITH_OVERLAP=0
  OVERLAP_MEASURED=0
  if [ ! -x "$OVERLAP" ]; then
    log "overlap not measured: overlap-stats.sh not found/executable (counts left at 0/0)"
    return 0
  fi
  local json events involved
  json=$("$OVERLAP" "$FINDINGS_DIR" 2>>"$RUN_LOG")
  if [ -z "$json" ]; then
    log "overlap not measured: overlap-stats.sh produced no output (counts left at 0/0)"
    return 0
  fi
  events=$(printf '%s' "$json" | jq -r '.overlap_events // empty' 2>/dev/null)
  involved=$(printf '%s' "$json" | jq -r '.sessions_with_overlap // empty' 2>/dev/null)
  if [ -z "$events" ] || [ -z "$involved" ]; then
    log "overlap not measured: overlap-stats.sh output was unparseable (counts left at 0/0)"
    return 0
  fi
  OVERLAP_EVENTS="$events"
  SESSIONS_WITH_OVERLAP="$involved"
  OVERLAP_MEASURED=1
  log "overlap: $OVERLAP_EVENTS pair(s), $SESSIONS_WITH_OVERLAP session(s) involved"
}

# $1=transcript path -> its parent session file, or nothing for a top-level transcript. A child
# lives in a directory named after its parent's file, so walking up until "<dir>.jsonl" is a
# file finds the parent at any depth: claude nests workers at <bucket>/<id>/subagents/ and
# <bucket>/<id>/subagents/workflows/wf_*/, omp at <bucket>/<stamp>_<id>/.
session_parent() {
  local d depth=0
  d=$(dirname "$1")
  while [ "$depth" -lt 6 ] && [ "$d" != / ] && [ "$d" != . ]; do
    [ -f "$d.jsonl" ] && { printf '%s' "$d.jsonl"; return 0; }
    d=$(dirname "$d"); depth=$((depth + 1))
  done
  return 1
}

# $1=findings dir -> one worker-hash<TAB>parent-hash row per nested transcript in sessions.txt
# (a sidecar with isSidechain or nested set: a claude subagent or workflow worker, an omp
# advisor or task child). The parent hash is the parent file's artifact key, or, when that file
# is gone, the path that file would have (same string session_parent returns), so a fanout still groups. Held in the
# runner's memory like session_rows, for the same reason: L1 and L2 can rewrite the worklist.
fanout_rows() {
  local dir=$1 s hash parent
  [ -r "$dir/sessions.txt" ] || return 0
  while IFS= read -r s <&3; do
    [ -n "$s" ] || continue
    hash=$(session_hash "$s") || continue
    jq -e '.isSidechain == true or .nested == true' "$dir/$hash.stats.json" >/dev/null 2>&1 || continue
    parent=$(session_parent "$s") || case $s in
      */subagents/*) parent=${s%%/subagents/*}.jsonl ;;
      *) parent=$(dirname "$s").jsonl ;;
    esac
    printf '%s\t%s\n' "$hash" "$(session_hash "$parent")"
  done 3< "$dir/sessions.txt"
}

# Splits the report's session total into top-level sessions and nested workers (#79), so a
# parent that spawned thirty workers stops reading as thirty-one sessions. Runs after L1 so a
# gated stub drops out, the same set the Activity snapshot's N counts. Sets FANOUT_TOP,
# FANOUT_NESTED, FANOUT_PARENTS and FANOUT_LARGEST, and writes fanouts.tsv (worker hash, parent
# hash) for L2. Needs FANOUT_ROWS from fanout_rows, which ran before any model did.
compute_fanout_stats() {
  local json hash row ungated=0 rows=""
  FANOUT_TOP=0; FANOUT_NESTED=0; FANOUT_PARENTS=0; FANOUT_LARGEST=0
  for json in "$FINDINGS_DIR"/*.json; do
    [ -f "$json" ] || continue
    case "$json" in *.stats.json) continue ;; esac
    grep -q '"skipped": *"below_noise_gate"' "$json" 2>/dev/null && continue
    ungated=$((ungated + 1))
    hash=$(basename "$json" .json)
    row=$(printf '%s\n' "$FANOUT_ROWS" | grep -m1 "^$hash"$'\t') || continue
    rows="${rows}${row}"$'\n'
  done
  if [ -n "$rows" ]; then printf '%s' "$rows" > "$FINDINGS_DIR/fanouts.tsv"; else : > "$FINDINGS_DIR/fanouts.tsv"; fi
  [ -n "$rows" ] || { FANOUT_TOP=$ungated; return 0; }
  FANOUT_NESTED=$(printf '%s' "$rows" | grep -c .)
  FANOUT_TOP=$((ungated - FANOUT_NESTED))
  FANOUT_PARENTS=$(printf '%s' "$rows" | cut -f2 | sort -u | grep -c .)
  FANOUT_LARGEST=$(printf '%s' "$rows" | cut -f2 | sort | uniq -c | sort -rn | awk 'NR == 1 { print $1 }')
}

dispatch_l1() { # one parallel pass; idempotent worker → only the still-missing sessions run
  # NUL-delimited, one argument per worker, so the path reaches the worker byte for byte.
  # `xargs -I {}` turned a tab into a space, deleted a backslash and died on a quote with
  # "unterminated quote", taking the whole night's dispatch with it (#54). A newline cannot
  # reach here: enumeration refuses it, because sessions.txt is line-based. -n 1 without -I
  # also lifts the 255-byte limit -I puts on the substituted argument.
  [ -s "$SESSIONS_LIST" ] || return 0
  tr '\n' '\0' < "$SESSIONS_LIST" | xargs -0 -n 1 -P "$FANOUT" bash -c '
    session="$1"
    # Same contract as session_hash in the parent, inlined: this is a separate
    # bash -c and the function is not in scope. No apostrophes anywhere in this
    # body — one silently breaks the single-quoted block while bash -n still
    # passes. An empty hash would send every worker to the same artifact.
    hashout=$(printf "%s" "$session" | shasum -a 1 2>/dev/null) || exit 0
    hash=${hashout:0:12}
    case "$hash" in
      [0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef]) : ;;
      *) exit 0 ;;
    esac
    t0=$(date +%s)
    output="$FINDINGS_DIR/$hash.json"
    errlog="$output.err"
    # The worker printed its whole diagnosis to stdout and this used to be /dev/null, so every
    # failure looked the same: an .err holding the single line "Working..." and a hand-written
    # sentence from the runner. Kept only when the worker fails; deleted with the errlog on success.
    outlog="$output.out"

    # Idempotent, but validate: a non-empty file that is malformed or lacks a
    # top-level findings key is NOT a completed triage (a worker that emitted
    # garbage JSON). Treat it as missing so this pass re-dispatches it, rather
    # than letting it count as done and feed broken records to L2.
    # `jq -e .findings` is truthy for a STRING or an OBJECT, so {"findings":"oops"} counted as a
    # finished session and reached L2 as a result. The filter comes from the environment
    # (L1_FINDINGS_OK, defined once in the parent) because this body is a single-quoted bash -c
    # where a quote silently breaks the quoting, and l1_missing_count must run the same check.
    jq -s -e "$L1_FINDINGS_OK" "$output" >/dev/null 2>&1 && exit 0
    # A file that fails the check is moved out of the way now, not left in place: every later
    # step reads a non-empty $output as this round having produced a result, so a chunk failure
    # with the old file still there skipped the final stub and the rejected file reached L2.
    # Kept as <hash>.json.rejected (no glob for *.json reaches it) as the evidence of what it was.
    if [ -e "$output" ]; then
      mv -f "$output" "$output.rejected" 2>/dev/null || rm -f "$output"
      rm -f "$output.served"
    fi

    # Validate the session is readable BEFORE spawning a worker. A path that find
    # enumerated but that is gone/unreadable by dispatch time otherwise sends the
    # worker into a cat/wc/Read retry loop. Emit a structured error record instead;
    # this is deterministic, so leaving it in $output (idempotent-skipped on re-run)
    # is correct — retrying would not help.
    if [ ! -r "$session" ]; then
      jq -cn --arg p "$session" "{session_path: \$p, error: \"session file not readable at dispatch\", findings: []}" > "$output"
      printf "runner\t-\t-\trunner\n" > "$output.served"
      rm -f "$errlog"
      echo "skip (unreadable): $session ($hash)" >&2
      exit 0
    fi

    # ---- Noise gate: skip the L1 model call for low-signal sessions ----
    # Uses the mechanical stats sidecar (session-stats.sh, computed once during
    # enumeration) so gating never needs a model call of its own. Subagent
    # transcripts (isSidechain) and high tool-count sessions are never gated;
    # they are legitimate work, just often short on user turns (see CLAUDE.md).
    # An uncomputable duration (0, meaning zero or one timestamped line) never
    # gates on the duration rule alone; bias to triage when it cannot be
    # measured. A missing or unparseable stats sidecar also never gates; bias
    # to triage. Defaults: 2 user turns, 1 minute; either condition alone gates.
    statsfile="$FINDINGS_DIR/$hash.stats.json"
    if [ -s "$statsfile" ]; then
      gate=$(jq -r --argjson min_turns "${AUTODREAM_MIN_USER_TURNS:-2}" --argjson min_minutes "${AUTODREAM_MIN_MINUTES:-1}" "if (.isSidechain == true) or ((.tool_call_count // 0) >= 5) then 0 elif (.user_message_count // 0) < \$min_turns then 1 elif ((.duration_minutes // 0) > 0) and ((.duration_minutes // 0) < \$min_minutes) then 1 else 0 end" "$statsfile" 2>/dev/null)
      if [ "$gate" = "1" ]; then
        jq -cn --arg p "$session" "{session_path: \$p, skipped: \"below_noise_gate\", findings: []}" > "$output"
        printf "runner\t-\t-\trunner\n" > "$output.served"
        rm -f "$errlog"
        echo "gated (below noise threshold): $session ($hash)" >&2
        exit 0
      fi
    fi

    # Oversized transcripts (multi-MB, base64 images, giant tool outputs) blow the
    # worker token budget so it errors out instead of triaging. Slim those first and
    # point the worker at the reduced copy; small sessions are read verbatim. The
    # findings session_path is rewritten back to the original after a successful run.
    readpath="$session"
    slimfile=""
    normfile=""
    # An adapter whose sessions are not a flat transcript (omp: an append-only tree) is
    # linearized to the live conversation first, and the worker reads that copy. Which adapters
    # need it comes from the manifests via the environment, like the source map. A session the
    # adapter cannot prove is the live conversation gets a deterministic error record rather
    # than a worker reading abandoned branches.
    wsrc=$(printf "%s\n" "$AUTODREAM_SOURCE_MAP" | awk -F"\t" -v h="$hash" "\$1 == h { print \$2; exit }")
    case " $AUTODREAM_NORMALIZE_SOURCES " in
      *" $wsrc "*)
        normfile="$FINDINGS_DIR/$hash.norm.jsonl"
        normerr=$("$ADAPTERS_DIR/$wsrc/adapter.sh" normalize "$session" "$normfile" 2>&1 >/dev/null | head -c 300)
        if [ ! -s "$normfile" ]; then
          rm -f "$normfile"
          # The adapter reason (duplicate id, dangling parent, cycle, missing jq) goes into the
          # record, so a refusal can be told from an environment fault by reading it.
          jq -cn --arg p "$session" --arg a "$wsrc" --arg why "$normerr" \
            "{session_path: \$p, error: (\"session could not be normalized by the \" + \$a + \" adapter: \" + \$why), findings: []}" > "$output"
          printf "runner\t-\t-\trunner\n" > "$output.served"
          rm -f "$errlog"
          echo "skip (not normalizable): $session ($hash)" >&2
          exit 0
        fi
        readpath="$normfile"
        ;;
    esac
    # A transcript that spans more than the report day is cut to the day first, AFTER the
    # normalize step above: a tree is linearized and the live chain is what gets cut. The
    # other order leaves entries whose parent was cut away, which the linearizer refuses.
    # Status 0 wrote the slice, 1 means nothing to cut, 2 means the helper failed; both of
    # those read the whole transcript, because a failed cut must cost a larger read and
    # never the session. The stats sidecar the noise gate read was cut the same way.
    dayfile=""
    if [ "${WINDOW_ON:-0}" = 1 ]; then
      dayfile="$FINDINGS_DIR/$hash.day.jsonl"
      if bash "$SESSION_WINDOW" day-file "$readpath" "$WIN_START_EPOCH" "$WIN_END_EPOCH" "$dayfile" </dev/null 2>/dev/null; then
        readpath="$dayfile"
      else
        rm -f "$dayfile"; dayfile=""
      fi
    fi
    sz=$(wc -c < "$readpath" | tr -d " ")
    slimsrc=""
    if [ "${sz:-0}" -gt "${AUTODREAM_SLIM_BYTES:-262144}" ] && [ -x "$SLIM" ]; then
      slimfile="$FINDINGS_DIR/$hash.slim.jsonl"
      slimsrc="$readpath"
      # While chunked triage is on the slim keeps every conversation line (the chunker sizes the
      # pieces) and drops Claude Code bookkeeping first, so the lines it keeps are conversation.
      # Off, both variables are 0 and the slimmer writes what it always wrote.
      if AUTODREAM_SLIM_RESHAPE="${L1_CHUNKING:-0}" AUTODREAM_SLIM_FULL="${L1_CHUNKING:-0}" "$SLIM" "$readpath" "$slimfile" 2>/dev/null && [ -s "$slimfile" ]; then
        readpath="$slimfile"
        echo "slimmed: $session ($sz bytes) ($hash)" >&2
      else
        rm -f "$slimfile"; slimfile=""
      fi
    fi

    # The engine is the session adapter, not a constant. The source comes from the map the
    # runner built before any model ran (AUTODREAM_SOURCE_MAP), never from a file under the
    # findings dir: an L1 worker holds the Write tool and could rewrite those, and the source
    # decides which binary the NEXT worker executes. The adapter prints its own argv and
    # environment (tests/adapter-contract.sh), so nothing here names claude or omp.
    src=$(printf "%s\n" "$AUTODREAM_SOURCE_MAP" | awk -F"\t" -v h="$hash" "\$1 == h { print \$2; exit }")
    model=$(printf "%s\n" "$AUTODREAM_L1_MODELS" | awk -F"\t" -v s="$src" "\$1 == s { print \$2; exit }")
    # The engine comes from the same parent-built environment (AUTODREAM_L1_ENGINE_<NAME>), and is
    # usually the source itself. An empty one means the override named no accepted adapter.
    engine=$(printf "%s\n" "$AUTODREAM_L1_ENGINES" | awk -F"\t" -v s="$src" "\$1 == s { print \$2; exit }")
    argv=()
    envs=()
    case "$src" in
      ""|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*) src="" ;;
    esac
    case "$engine" in
      ""|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*) engine="" ;;
    esac
    if [ -n "$src" ] && [ -n "$engine" ] && [ -n "$model" ] && [ -x "$ADAPTERS_DIR/$engine/adapter.sh" ]; then
      while IFS= read -r -d "" arg; do argv+=("$arg"); done < <("$ADAPTERS_DIR/$engine/adapter.sh" l1-argv "$model" 2>/dev/null)
      while IFS= read -r line; do [ -n "$line" ] && envs+=("$line"); done < <("$ADAPTERS_DIR/$engine/adapter.sh" l1-env 2>/dev/null)
    fi
    if [ "${#argv[@]}" -eq 0 ]; then
      # Deterministic for this run: retrying in a later round would not change the answer, so a
      # structured error record is left in place, skipped by the rounds that follow and counted by
      # l1_findings_with_error. It is not deterministic across runs. The engine choice, the model
      # pin and the login check all come from the config, so no_engine marks the record and a later
      # run whose config resolves an engine for this source drops it and triages the session
      # (drop_unacceptable_l1_cache in the parent).
      rm -f "$slimfile" "$normfile" "$dayfile"
      jq -cn --arg p "$session" --arg s "$src" --arg m "$model" "{session_path: \$p, no_engine: true, error: (\"no L1 engine for this session (source [\" + \$s + \"], model [\" + \$m + \"])\"), findings: []}" > "$output"
      printf "runner\t-\t-\trunner\n" > "$output.served"
      rm -f "$errlog"
      echo "skip (no engine): $session ($hash)" >&2
      exit 0
    fi

    # ---- Chunked triage: split a transcript too big for one worker ----
    # The worker input (the slim, or the transcript itself when it was small enough not to be slimmed)
    # over AUTODREAM_L1_CHUNK_BYTES is cut at line boundaries into at most AUTODREAM_L1_MAX_CHUNKS
    # chunks, one engine call each, merged below. Chunk INPUTS are rebuilt on every dispatch (they are
    # deterministic for an unchanged transcript) and live under .chunks/<hash>/in/, which the parent
    # removes after the round whatever happened to this worker. Chunk OUTPUTS are model answers, kept
    # under .chunks/<hash>/ with a non-.json suffix so nothing that globs the findings directory can
    # mistake one for a session, and named by the sha1 of their chunk, so a retry reuses an answer
    # only for an identical chunk.
    chunked=0; nchunks=1; elided=0; chunkroot=""; l1_blocked=0
    if [ "${L1_CHUNKING:-0}" = 1 ]; then
      csz=$(wc -c < "$readpath" | tr -d " ")
      if [ "${csz:-0}" -gt "$AUTODREAM_L1_CHUNK_BYTES" ]; then
        chunkroot="$FINDINGS_DIR/.chunks/$hash"
        cinfo=""
        if ( umask 077; mkdir -p "$chunkroot/in" ) 2>/dev/null; then
          cinfo=$(bash "$CHUNKER" "$readpath" "$chunkroot/in" "$AUTODREAM_L1_CHUNK_BYTES" "$AUTODREAM_L1_MAX_CHUNKS" 2>/dev/null) || cinfo=""
        fi
        read -r nchunks elided <<< "$cinfo"
        case "$nchunks" in ""|*[!0-9]*) nchunks=0 ;; esac
        case "$elided" in ""|*[!0-9]*) elided=0 ;; esac
        if [ "$nchunks" -ge 1 ]; then
          chunked=1
          printf "%s %s %s\n" "$hash" "$nchunks" "$elided" >> "$FINDINGS_DIR/l1-chunks.txt"
          echo "chunked: $session ($hash) $nchunks chunks ($elided elided)" >&2
        else
          # The chunker could not run (a full disk, an unwritable directory). Never hand one worker
          # the whole uncapped slim: fall back to the exact off path, the capped head/tail slim of
          # the same input. If that cannot be made either, read nothing this round: the output stays
          # absent, the session is retried, and the last round writes the honest stub.
          nchunks=1; elided=0
          rm -rf "$chunkroot/in"
          echo "WARNING: chunker failed for $session ($hash); falling back to the capped head/tail slim" >&2
          # A transcript under AUTODREAM_SLIM_BYTES was never slimmed, so there may be no slim file
          # yet; the fallback still has to be bounded, so it makes one from the input itself.
          [ -n "$slimfile" ] || slimfile="$FINDINGS_DIR/$hash.slim.jsonl"
          if AUTODREAM_SLIM_FULL=0 AUTODREAM_SLIM_RESHAPE=0 "$SLIM" "${slimsrc:-$readpath}" "$slimfile" 2>/dev/null && [ -s "$slimfile" ]; then
            readpath="$slimfile"
          else
            cap="${AUTODREAM_SLIM_CAP:-262144}"
            case "$cap" in ""|*[!0-9]*) cap=262144 ;; esac
            if ( umask 077; head -c "$cap" "$readpath" > "$slimfile.cap" ) 2>/dev/null && mv -f "$slimfile.cap" "$slimfile"; then
              readpath="$slimfile"
            else
              rm -f "$slimfile.cap"; l1_blocked=1
            fi
          fi
        fi
      fi
    fi

    # Pass the paths as LITERAL data (not KEY=value) so the worker hands them
    # straight to the Read/Write tools and never tries to $-expand them in a shell
    # (there is no such env var, so it would expand to nothing and fail — exactly
    # the failure mode that broke earlier runs). Assemble via a brace group piped
    # straight to claude: a `prompt=$(...)` capture strips the trailing newlines,
    # which would glue the SESSION_TRIAGE.md body onto the end of the output-path
    # line and corrupt it. The printf keeps its blank-line separator this way.
    # Launch from the isolated worker cwd so any AI-title stub lands in $WORK_BUCKET,
    # not the real session bucket. All paths below are absolute, so cd is safe here.
    cd "$WORK_DIR" 2>/dev/null || true
    # An array rather than ${TIMEOUT_BIN:+...}: both behave correctly, including for a path with
    # spaces, but the array says plainly that this is an optional argv prefix. Set OUTSIDE the
    # brace group below: a brace group in a pipeline runs in a subshell, so an assignment made in
    # there is invisible to the right-hand side and the wrapper would silently disappear.
    l1wrap=()
    [ -n "$TIMEOUT_BIN" ] && l1wrap=("$TIMEOUT_BIN" -k "$L1_KILL_GRACE" "$AUTODREAM_L1_TIMEOUT")
    # What the worker is told about a chunk, appended to its prompt before the stats block (which
    # SESSION_TRIAGE.md says comes last). The wording "chunk I of N of ONE session" is matched by
    # tests/mock-claude.sh, so change both together. The stats belong to the whole session (or day),
    # which is why they are copied verbatim and not recounted from one chunk.
    l1_chunk_note() { # $1=i $2=n $3=chunks dropped from the middle
      printf "This transcript is chunk %s of %s of ONE session, split at line boundaries. Other workers triage the other chunks. A tool call and its result can fall in different chunks, and the opening goal and the final outcome may be in a chunk other than yours. Long lines were cut by the slimmer, so a cut line is not malformed input. Report only what is in this chunk, and judge the outcome from the end state of this chunk. The stats below describe the whole session (or the report day, when a note above says so), not this chunk: copy them verbatim." "$1" "$2"
      if [ "${3:-0}" -gt 0 ]; then
        printf " %s chunks from the middle of the session were omitted for size." "$3"
      fi
    }
    # One engine call. $1 is the transcript to read, $2 the findings path the worker is told to
    # write, $3 and $4 hold the engine stderr and stdout. Returns 0 only when $2 ends up holding a
    # findings object; on a failure it leaves its evidence in $3 and the network verdict in
    # netdown (and in the ledger), and the caller decides what the failure costs the session.
    # $5, set only for one chunk of a chunked session, is the chunk note for the prompt, and makes
    # the answer be judged by the chunk contract (merge-chunks.sh --check: exactly one object, no
    # error key) rather than by a findings array alone. l1_subject names what failed in the
    # diagnostic line: the session, or a chunk of it. That line is skipped by failure-class.sh on
    # its prefix, so naming a chunk there costs the classifier nothing.
    l1_attempt() {
      # Stamped here, NOT reused from t0. t0 is taken before validation, the noise gate and
      # slimming, so a large transcript can burn real time before timeout is even launched;
      # counting that as worker runtime lets an intrinsic 124 or 137 clear the elapsed check with
      # no deadline having fired. Only the interval timeout itself was running can answer that.
      l1start=$(date +%s)
      {
        printf "Session transcript to analyze (literal absolute path): %s\n" "$1"
        printf "Write your findings JSON to this literal absolute path: %s\n\n" "$2"
        cat "$AUTODREAM_DIR/SESSION_TRIAGE.md"
        # One triage document for every harness. A harness whose transcripts differ from the
        # claude shape the document describes adds adapters/<name>/triage.md, appended here for
        # that adapter sessions only, so claude workers receive exactly the text they always did.
        if [ -n "$src" ] && [ -r "$ADAPTERS_DIR/$src/triage.md" ]; then
          printf "\n"
          cat "$ADAPTERS_DIR/$src/triage.md"
        fi
        if [ -n "$dayfile" ]; then
          # Said plainly, because a worker handed a slice has no other way to know the first
          # turn it reads is not the start of the session.
          printf "\n## Report day\n\nThis transcript is the part of a longer session that was recorded on %s (local time). Records from other days were removed, so it can open in the middle of a task and end before the task does. The stats below describe this part only.\n" "$TARGET_DATE"
        fi
        if [ -n "${5:-}" ]; then
          printf "\n## Chunk note\n\n%s\n" "$5"
        fi
        if [ -s "$FINDINGS_DIR/$hash.stats.json" ]; then
          printf "\n## Precomputed session stats (authoritative — copy these into your output)\n\n\`\`\`json\n"
          cat "$FINDINGS_DIR/$hash.stats.json"
          printf "\n\`\`\`\n"
        fi
      } | ${l1wrap[@]+"${l1wrap[@]}"} env ${envs[@]+"${envs[@]}"} "${argv[@]}" > "$4" 2> "$3"
      # Index 1 is the engine side of the pipe; index 0 is the brace group.
      l1rc="${PIPESTATUS[1]}"
      l1elapsed=$(($(date +%s) - l1start))
      # 124 is timeout reporting that it fired; 137 is 128+SIGKILL, which is what the -k grace
      # period escalates to. Elapsed is the positive evidence that the deadline actually fired: GNU
      # timeout propagates the exit status of the child, so a worker that exits 124 by itself, or
      # that the OOM killer SIGKILLs at second zero, arrives here looking identical to a real
      # timeout (verified against coreutils 9.11: a self-killed child returned 137 after 0s under a
      # 100s bound). Only trust 137 as a timeout when the wrapper is actually in the pipeline.
      # Second resolution leaves a one-second boundary window, against a bound of twenty minutes.
      if [ -n "$TIMEOUT_BIN" ] && { [ "$l1rc" = "124" ] || [ "$l1rc" = "137" ]; } \
         && [ "$l1elapsed" -ge "$AUTODREAM_L1_TIMEOUT" ]; then
        printf "worker exceeded AUTODREAM_L1_TIMEOUT=%ss and was killed with its process group (rc=%s)\n" \
          "$AUTODREAM_L1_TIMEOUT" "$l1rc" >> "$3"
        # The errlog cannot carry this fact: it is truncated by the next retry and deleted outright
        # whenever the worker leaves any output, so a timeout that later succeeds, or that wrote
        # something before dying, would vanish from the stats. The ledger is per-run and
        # append-only, so neither can erase it.
        printf "%s\n" "$hash" >> "$FINDINGS_DIR/l1-timeouts.txt"
        # A worker killed mid-write leaves a truncated findings JSON. That is not a result: kept,
        # it reads as success, deletes the errlog, and feeds partial input to L2. Drop it so this
        # session retries like any other failure.
        rm -f "$2"
      fi

      # Which model answered, from the engine result record (adapter verb served), for every call
      # whatever it produced, so a night accounts for each one. Whether that is the requested model
      # is the adapter verdict, not a string compare here: the CLI answers with a canonical id
      # (claude-haiku-5-5) for a model asked for by alias (haiku), and only the adapter knows its
      # naming. An engine that reports nothing is recorded as unknown and unmeasured, never as a
      # match or a mismatch. With AUTODREAM_L1_REQUIRE_SERVED=1 a call whose verdict is not match
      # loses its findings, so nothing a substituted or unverifiable model wrote reaches L2.
      l1served=$("$ADAPTERS_DIR/$engine/adapter.sh" served "$4" "$model" 2>/dev/null) || l1served=""
      l1smodels=$(printf "%s" "$l1served" | cut -f1)
      l1scost=$(printf "%s" "$l1served" | cut -s -f2)
      l1sverdict=$(printf "%s" "$l1served" | cut -s -f3)
      case "$l1sverdict" in match|mismatch) ;; *) l1sverdict=unmeasured ;; esac
      printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$hash" "$engine" "$model" "${l1smodels:-unknown}" "$l1scost" "$l1sverdict" >> "$FINDINGS_DIR/l1-served.tsv"
      if [ "${AUTODREAM_L1_REQUIRE_SERVED:-0}" = 1 ] && [ -s "$2" ] && [ "$l1sverdict" != match ]; then
        if [ "$l1sverdict" = mismatch ]; then
          printf "the call was answered by [%s], not the requested model [%s]; its findings are discarded (AUTODREAM_L1_REQUIRE_SERVED=1)\n" "$l1smodels" "$model" >> "$3"
        else
          printf "the %s engine did not report which model answered, so the call cannot be held to the requested model [%s]; its findings are discarded (AUTODREAM_L1_REQUIRE_SERVED=1)\n" "$engine" "$model" >> "$3"
        fi
        rm -f "$2" "$2.served"
        return 1
      fi

      # Non-empty is not the same as valid. A worker that writes malformed JSON, or JSON with no
      # .findings array, used to take the success branch below: both diagnostics were deleted and
      # the file was left for L2. The dispatcher validates .findings on its way IN, so the next
      # round would re-run the session, but by then the exit code, the stdout capture and the
      # reason were gone, and on the final round the malformed file simply reached the aggregator.
      # Validate the same way on the way out, so a bad write is a failure with its evidence intact.
      if [ -n "${5:-}" ]; then
        l1_ok() { bash "$MERGER" --check "$1"; }
      else
        l1_ok() { jq -s -e "$L1_FINDINGS_OK" "$1" >/dev/null 2>&1; }
      fi
      if [ -s "$2" ] && ! l1_ok "$2"; then
        printf "worker wrote output with no usable .findings key; treating as a failure\n" >> "$3"
        head -c 2000 "$2" >> "$3" 2>/dev/null
        rm -f "$2"
      fi

      # The verdict travels with the answer it describes, in <answer>.served (engine, requested
      # model, models that answered, verdict), written by the runner after the engine has exited,
      # so whatever the worker wrote there itself is replaced. A later run reads it before reusing
      # the answer: with AUTODREAM_L1_REQUIRE_SERVED=1 a cached findings JSON or chunk answer is
      # reused only when this says match (drop_unacceptable_l1_cache in the parent).
      rm -f "$2.served"
      if [ -s "$2" ]; then
        printf "%s\t%s\t%s\t%s\n" "$engine" "$model" "${l1smodels:-unknown}" "$l1sverdict" > "$2.served"
        return 0
      fi
      # Worker exited without writing findings JSON. Record a diagnostic so the
      # failure is visible.
      printf "worker produced no findings JSON for %s (incomplete run: the engine exited without writing output)\n" "${l1_subject:-$session}" >> "$3"
      # The three facts that were missing every time this fired. Without the exit code a provider
      # refusal and a killed process read identically, and without the stdout capture the whole
      # diagnosis went to /dev/null while the .err kept the one line the worker happened to put
      # on stderr (omp-autodream, 2026-09-04: a dead network hid behind three fine transcripts and
      # the report blamed their size).
      printf "worker exit code: %s after %ss\n" "$l1rc" "$l1elapsed" >> "$3"
      if [ -s "$4" ]; then
        printf -- "--- worker stdout, last 40 lines ---\n" >> "$3"
        tail -n 40 "$4" >> "$3"
      else
        printf "worker stdout was empty\n" >> "$3"
      fi
      rm -f "$4"
      # Was the host reachable at the moment this worker failed? Without this a failure
      # caused by a sleeping Mac is indistinguishable from a transcript the worker could
      # not digest, and the oversized gate would count it as evidence it is not. One curl,
      # only on the failure path.
      # Three states, not two. An absent curl reports nothing and exits 127, which the
      # first version read as "no route" — so a host without curl would have had EVERY
      # worker failure excluded from the oversized gate, permanently and invisibly.
      # unknown is not netdown: it never ledgers and never suppresses the stub.
      netdown=unknown
      # The host the engine of this worker talks to, resolved before any model ran
      # (AUTODREAM_L1_PROBE_URLS), not a fixed one: an omp worker on deepseek failing while
      # api.anthropic.com answers is not "network up", and the reverse is not an outage.
      probeurl=$(printf "%s\n" "${AUTODREAM_L1_PROBE_URLS:-}" | awk -F"\t" -v s="$src" "\$1 == s { print \$2; exit }")
      if [ -n "$probeurl" ]; then
        probehost=${probeurl#*://}; probehost=${probehost%%/*}
        netcode=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$probeurl" 2>/dev/null)
        netrc=$?
        if [ "$netrc" -eq 127 ] || [ "$netrc" -eq 126 ]; then
          printf "curl could not be run here (exit %s: not found, or not executable); this failure is unclassified, not an outage\n" "$netrc" >> "$3"
        elif [ -z "$netcode" ] || [ "$netcode" = "000" ]; then
          netdown=true
        else
          netdown=false
        fi
        if [ "$netdown" = "true" ]; then
          printf "no route to %s when this worker failed (curl http_code=%s)\n" "$probehost" "${netcode:-000}" >> "$3"
        fi
      fi
      # Ledger every classified failure, with its round, and never rewrite a line. A
      # bare hash was wrong: the ledger is truncated once per RUN, so a round-1 outage
      # entry survived into round 5 and excluded a round-5 failure that had a completely
      # different cause. Readers take the HIGHEST round recorded for a hash, so the last
      # attempt is the one that counts. Append-only keeps the parallel xargs subshells
      # from racing, same as l1-timeouts.txt.
      # A reachable network does not mean a working provider. A billing refusal (Z.ai
      # code 1113, 2026-10-01 and 10-02) answers curl fine, so netdown is false, and the
      # stub below used to consume the session permanently. Classify the
      # failure from its own .err; a permanent refusal (no balance or quota) is ledgered as
      # "provider" and defers like an outage. A transient 429 or 5xx keeps its stub.
      if [ "$netdown" != "true" ] && [ -r "$FAILURE_CLASS" ] \
         && (. "$FAILURE_CLASS"; provider_is_permanent "$3"); then
        netdown=provider
        printf "provider refusal when this worker failed; no stub, the session is left for a later run\n" >> "$3"
      fi
      if [ "$netdown" != "unknown" ]; then
        printf "%s %s %s\n" "$hash" "${AUTODREAM_CURRENT_ROUND:-1}" "$netdown" >> "$FINDINGS_DIR/l1-netdown.txt"
      fi
      return 1
    }
    netdown=unknown
    if [ "$l1_blocked" = 1 ]; then
      printf "no bounded input could be made for %s; skipping the engine call this round\n" "$session" >> "$errlog"
      echo "WARNING: no bounded input for $session ($hash); skipping L1 this round" >&2
    elif [ "$chunked" = 1 ]; then
      # One engine call per chunk, in sequence in this slot. A chunk answer is untrusted: it counts
      # only if it is exactly one findings object with no error key (merge-chunks.sh --check), and
      # anything else is discarded so the retry round redoes THAT chunk alone. A finished answer is
      # reused, which is what makes a retry cheap and a failure partway not start over. A chunk
      # failure is a worker failure: l1_attempt writes the same evidence, makes the same network
      # and provider verdict and ledgers it the same way, and the final-round stub below is the
      # session level and only the session level. After a no-route or a permanent provider refusal
      # the rest of the chunks are not tried, since they would fail the same way and each would
      # burn a call.
      parts=(); cfail=0; cfirst=""; ci=1
      # An answer is reusable only for the same chunk text read under the same instructions: the
      # triage prompt, the harness addendum, the engine and model, the chunk count and omitted count the
      # chunk note states, and the stats block the worker
      # copies from (merge-chunks.sh takes the stats fields from chunk 1). All of it is in the
      # cache name, so a retry after the prompt, the engine, the model or the session changed redoes
      # the chunk instead of merging a stale answer with fresh ones. The engine is there in its own
      # right: one model id can be served by two engines, through different system prompts and tools.
      ccfg=$( { cat "$AUTODREAM_DIR/SESSION_TRIAGE.md" 2>/dev/null
                if [ -n "$src" ] && [ -r "$ADAPTERS_DIR/$src/triage.md" ]; then cat "$ADAPTERS_DIR/$src/triage.md"; fi
                printf "%s %s %s %s %s\n" "$src" "$engine" "$model" "$nchunks" "$elided"
                cat "$FINDINGS_DIR/$hash.stats.json" 2>/dev/null; } | shasum -a 1 2>/dev/null | cut -c1-8 )
      while [ "$ci" -le "$nchunks" ]; do
        cin=$(printf "%s/in/chunk-%02d.jsonl" "$chunkroot" "$ci")
        csha=$(shasum -a 1 "$cin" 2>/dev/null | cut -c1-12)
        cout=$(printf "%s/%02d-%s-%s.chunkout" "$chunkroot" "$ci" "$csha" "$ccfg")
        parts+=("$cout")
        if bash "$MERGER" --check "$cout"; then
          echo "reuse: chunk $ci/$nchunks of $session ($hash)" >&2
        else
          rm -f "$cout"
          cerr=$(printf "%s/%02d.err" "$chunkroot" "$ci")
          cof=$(printf "%s/%02d.out" "$chunkroot" "$ci")
          printf "%s %s %s\n" "$hash" "${AUTODREAM_CURRENT_ROUND:-1}" "$ci" >> "$FINDINGS_DIR/l1-chunk-calls.txt"
          l1_subject="chunk $ci/$nchunks of $session"
          if l1_attempt "$cin" "$cout" "$cerr" "$cof" "$(l1_chunk_note "$ci" "$nchunks" "$elided")"; then
            rm -f "$cerr" "$cof"
          else
            cfail=1
            [ -n "$cfirst" ] || cfirst="$cerr"
            if [ "$netdown" = "true" ] || [ "$netdown" = "provider" ]; then break; fi
          fi
          l1_subject=""
        fi
        ci=$((ci + 1))
      done
      if [ "$cfail" = 0 ]; then
        # Merged only when EVERY chunk answered properly, and merge-chunks.sh refuses anything else
        # itself. A merge that fails anyway drops every cached answer so the next round cannot
        # loop on them.
        if bash "$MERGER" --session "$session" --elided "$elided" "${parts[@]}" > "$output.merge" 2>> "$errlog" \
           && [ -s "$output.merge" ] && jq -s -e "$L1_FINDINGS_OK" "$output.merge" >/dev/null 2>&1; then
          mv -f "$output.merge" "$output"
          # The merged answer is vouched for only as far as its chunks were: match when every chunk
          # answer says match, mismatch when any says mismatch, unmeasured otherwise (a chunk
          # whose engine reports no model, or an answer cached before the verdict existed).
          mverdict=match; mmodels=""
          for cpart in "${parts[@]}"; do
            cpv=$(cut -s -f4 "$cpart.served" 2>/dev/null | head -1)
            cpm=$(cut -s -f3 "$cpart.served" 2>/dev/null | head -1)
            mmodels="$mmodels,${cpm:-unknown}"
            case "$cpv" in
              match) ;;
              mismatch) mverdict=mismatch ;;
              *) [ "$mverdict" = mismatch ] || mverdict=unmeasured ;;
            esac
          done
          mmodels=$(printf "%s\n" "${mmodels#,}" | tr "," "\n" | sort -u | paste -s -d "," -)
          printf "%s\t%s\t%s\t%s\n" "$engine" "$model" "$mmodels" "$mverdict" > "$output.served"
        else
          rm -f "$output.merge" "${parts[@]}" "${parts[@]/%/.served}"
          printf "merging the %s chunk answers of %s failed; they were discarded so the next round redoes them\n" "$nchunks" "$session" >> "$errlog"
        fi
      else
        # The first failing chunk is the session evidence: a later chunk that succeeds must not
        # overwrite what the failure said, and failure-class.sh classifies this file as it does any.
        cp "$cfirst" "$errlog" 2>/dev/null
      fi
    else
      l1_attempt "$readpath" "$output" "$errlog" "$outlog"
    fi

    if [ -s "$output" ]; then
      # Reported path should be the real session, not the temp slim copy. Then drop
      # the slim file (regenerable; keeps the findings dir clean).
      # A literal replace inside the JSON strings: sed would read a # or & in the session
      # path as part of its own syntax, and a quote or backslash would break the JSON.
      for tmpcopy in "$slimfile" "$normfile" "$dayfile"; do
        [ -n "$tmpcopy" ] || continue
        jq -c --arg a "$tmpcopy" --arg b "$session" "walk(if type == \"string\" then split(\$a) | join(\$b) else . end)" "$output" > "$output.rw" 2>/dev/null \
          && mv "$output.rw" "$output" || rm -f "$output.rw"
      done
      rm -f "$slimfile" "$normfile" "$dayfile"
      rm -f "$errlog" "$outlog"
      echo "ok: $session ($hash) [$(($(date +%s) - t0))s]"
    else
      rm -f "$slimfile" "$normfile" "$dayfile"
      # On the FINAL retry round, fall back to a metadata-only findings stub so
      # the session is visible to L1_ERRORED and the L2 aggregator instead of
      # disappearing into a silent .err file (2026-06-11 self-audit: 12 .err
      # files with l1_findings_with_error=0).
      # Earlier rounds leave $output absent so the next round can retry; only
      # the last round writes the stub. AUTODREAM_L1_ROUNDS comes through the
      # environment (exported below).
      #
      # EXCEPT when the network was down or the provider refused outright. A stub satisfies
      # l1_missing_count (it carries a .findings key), so writing one marks the session DONE:
      # MISSING drops to zero, the run never defers, L2 publishes on a short corpus, and the
      # next run skips the session because its slot is filled. Leaving the slot empty is what
      # makes the retry work; the run defers instead, so the silent-failure concern is
      # answered by the deferral, not the stub.
      if [ "$netdown" = "true" ] || [ "$netdown" = "provider" ]; then
        echo "FAIL ($([ "$netdown" = "true" ] && echo "network down" || echo "provider refusal"); no stub, left for a later run): $session ($hash) [$(($(date +%s) - t0))s] — see $errlog" >&2
      elif [ "${AUTODREAM_CURRENT_ROUND:-1}" -ge "${AUTODREAM_L1_ROUNDS:-5}" ]; then
        sz=$(wc -c < "$session" 2>/dev/null | tr -d " ")
        lines=$(wc -l < "$session" 2>/dev/null | tr -d " ")
        cmeta="{}"
        [ "$chunked" = 1 ] && cmeta="{\"chunks\":$nchunks,\"chunks_elided\":$elided}"
        jq -cn --arg p "$session" --arg r "${AUTODREAM_L1_ROUNDS:-5}" --argjson b "${sz:-0}" --argjson l "${lines:-0}" --argjson sl "$([ -n "$slimfile" ] && echo true || echo false)" --argjson cm "$cmeta" \
          "{session_path: \$p, error: (\"worker exited without findings JSON after \" + \$r + \" rounds\"), meta: ({bytes: \$b, lines: \$l, slimmed: \$sl} + \$cm), findings: []}" > "$output"
        printf "runner\t-\t-\trunner\n" > "$output.served"
        echo "FAIL (metadata stub written): $session ($hash) [$(($(date +%s) - t0))s] — see $errlog" >&2
      else
        echo "FAIL: $session ($hash) [$(($(date +%s) - t0))s] — see $errlog" >&2
      fi
    fi
    # Chunk scratch is only worth keeping while a retry is pending: the inputs never (they are
    # rebuilt), the answers until the session has a findings JSON, a stub included.
    if [ -n "$chunkroot" ]; then
      rm -rf "$chunkroot/in"
      if [ -s "$output" ]; then rm -rf "$chunkroot"; fi
    fi
  ' _
  # A worker killed mid-round never reached its own cleanup, and what it leaves is transcript text:
  # the chunk inputs and, with chunking on, a slim that is now the whole conversation. Every
  # worker has returned by here, so any of these still on disk is a leftover, and the parent
  # removes them. The chunk ANSWERS stay for the retry. This is deliberately not a trap in the
  # worker: a trapped TERM is deferred until the foreground engine exits (the adapter comment
  # says what that cost), so a trap would trade a stale file for a worker that ignores SIGTERM.
  # Gated on L1_CHUNKING so the off path leaves exactly what it always left.
  # The empty .chunks directory goes here and not in a worker: eight workers create their own
  # subdirectory in it at once, and one removing it between another's two mkdir steps would make
  # that chunker fail for no reason.
  if [ "${L1_CHUNKING:-0}" = 1 ]; then
    rm -rf "$FINDINGS_DIR"/.chunks/*/in 2>/dev/null
    rm -f "$FINDINGS_DIR"/*.slim.jsonl "$FINDINGS_DIR"/*.slim.jsonl.cap "$FINDINGS_DIR"/*.day.jsonl "$FINDINGS_DIR"/*.norm.jsonl 2>/dev/null
    rmdir "$FINDINGS_DIR/.chunks" 2>/dev/null
  fi
  return 0
}

# What L2 needs to know about each harness that contributed sessions tonight, and which skills are
# installed. Both come from the adapters, so adding a harness adds no code here.
#
# skills-inventory.txt: one `name<TAB>description` line per active skill (an adapter that knows
# no description prints the name alone), deduplicated by name across adapters, first wins. If
# EVERY adapter failed the file says so, and PROMPT.md tells L2 not to file coverage gaps from
# an unavailable inventory: an empty inventory would claim no skills are installed.
#
# adapter-facts.md: each contributing source's facts.md under a heading, so L2 proposes a
# remedy that exists for that harness (a permissions.allow entry means nothing to omp). Only
# sources that actually had sessions are included, taken from the map captured before any
# model ran, never from a file a worker could have rewritten.
write_adapter_inputs() {
  local inv="$FINDINGS_DIR/skills-inventory.txt" facts="$FINDINGS_DIR/adapter-facts.md"
  local srcs src out any_ok=0 body
  srcs=$(printf '%s\n' "$AUTODREAM_SOURCE_MAP" | awk -F'\t' 'NF >= 2 && !seen[$2]++ { print $2 }')
  body=""
  for src in $ENABLED_ADAPTERS; do
    if out=$(adapter_run "$src" skills-inventory 2>/dev/null); then
      any_ok=1
      body="${body}${out}"$'\n'
    else
      log "  skills inventory unavailable from the $src adapter"
    fi
  done
  if [ "$any_ok" = "1" ]; then
    {
      printf '# skills-inventory.txt — authoritative active on-disk skill list for L2 (adapters: %s)\n' "$(printf '%s' "$ENABLED_ADAPTERS" | tr ' ' ',')"
      printf '%s' "$body" | awk -F'\t' 'NF && !seen[$1]++'
    } > "$inv" 2>/dev/null || printf '# skills-inventory.txt unavailable\n' > "$inv"
  else
    printf '# skills-inventory.txt unavailable\n' > "$inv"
  fi
  : > "$facts" 2>/dev/null || return 0
  for src in $srcs; do
    [ -f "$(adapters_root 2>/dev/null)/$src/facts.md" ] || continue
    {
      printf '## Source: %s\n\n' "$src"
      cat "$(adapters_root)/$src/facts.md"
      printf '\n'
    } >> "$facts" 2>/dev/null || true
  done
  return 0
}

# Dates in the trailing window whose findings were produced but never assembled into a
# complete report (#36). Echoes "unassembled|legacy", both comma-separated, either empty.
#
# The completeness test is the open-questions marker, not `-s`, for the same reason every
# other consumer uses it: a report killed mid-write is not a report. TARGET_DATE is skipped
# because this run is about to assemble it, and a stub findings dir left by an earlier
# attempt at the same date would otherwise report itself as a failure.
#
# The marker became mandatory partway through this tool's life, so every report written
# before that is non-empty, complete, and unmarked. Judged by the marker alone they all
# look abandoned: on this host the check named six consecutive good reports every single
# night, which is exactly how a real warning gets trained into background noise. Dates
# before AUTODREAM_MARKER_EPOCH therefore accept a non-empty report, and are reported
# under their own key so the exemption is visible rather than silent.
#
# Why a date and not a heuristic: "non-empty but unmarked" is genuinely ambiguous - it is
# either a legacy report or a truncated capture - and the only fact that separates them is
# when the contract began. The exposure is bounded by design: the scan looks back
# AUTODREAM_UNASSEMBLED_WINDOW days, so an epoch that is wrong for a given install
# self-corrects within a week of upgrading. Set it when backfilling older dates.
unassembled_dates() {
  local window="${AUTODREAM_UNASSEMBLED_WINDOW:-7}" root="$AUTODREAM_DIR/findings"
  local epoch="${AUTODREAM_MARKER_EPOCH:-2026-08-19}"
  local d date_label report found out="" legacy=""
  [ -d "$root" ] || { printf '|'; return 0; }
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    date_label=$(basename "$d")
    [ "$date_label" = "$TARGET_DATE" ] && continue
    # Findings JSONs, OR a run-stats.txt carrying `fatal:`. A dir holding nothing
    # but *.stats.json sidecars was never triaged, so it has nothing to assemble
    # and is not a failure — but a dir holding only a fatal marker is a night that
    # died before it could triage anything, which is the case with no other
    # surface at all: no report, no notification, and no findings to rebuild from.
    found=$(find "$d" -maxdepth 1 -type f -name '*.json' ! -name '*.stats.json' 2>/dev/null | head -1)
    local why=""
    if [ -z "$found" ]; then
      # Commas out. PROMPT.md tells L2 to read this value as a comma-separated
      # date list, and the likeliest reason embeds one: the adapter-loader refusal
      # interpolates adapters_rejected, which is itself comma-separated, so
      # `rejected: claude,evil` turned one dead date into three list entries.
      why=$(sed -n 's/^fatal: //p' "$d/run-stats.txt" 2>/dev/null | head -1 | tr ',' ';')
      [ -n "$why" ] || continue
    fi
    report="$DREAMS_DIR/$date_label.md"
    if [ -s "$report" ]; then
      report_finishes "$report" "$date_label" && continue
      # Non-empty and unmarked. Before the epoch that is a legacy report; on or after it,
      # it is a truncated capture and stays on the abandoned list. ISO dates compare
      # lexicographically, so this is chronological.
      if [[ "$date_label" < "$epoch" ]]; then
        legacy="${legacy:+$legacy, }$date_label"
        continue
      fi
    fi
    # Carry the REASON, not just the label. fatal_exit writes it into that date's
    # run-stats.txt, and L2 only ever reads its OWN date's file — so without this
    # the marker was written and never read by anything, and PROMPT.md's "A night
    # that died" bullet was unreachable. The banner was the only working half.
    out="${out:+$out, }$date_label${why:+ (${why})}"
  done < <(find "$root" -maxdepth 1 -type d -name '2[0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]' 2>/dev/null \
    | sort | tail -n "$window")
  printf '%s|%s' "$out" "$legacy"
}

run() {
  log "===== autodream start: $(date) ====="
  log "runner: $RUNNER_COMMIT$([ "$RUNNER_DIRTY" = "yes" ] && echo " (dirty)")"
  log "target date: $TARGET_DATE"
  if ! acquire_run_lock; then
    log "another run for $TARGET_DATE holds the lock (pid ${RUN_LOCK_HOLDER:-unknown}, $RUN_LOCK); nothing to do"
    return 0
  fi
  log "findings:    $FINDINGS_DIR"
  log "report:      $REPORT_PATH"
  log "fanout:      $FANOUT"
  log "claude:      $CLAUDE_BIN"
  if [ -n "$TIMEOUT_BIN" ]; then
    log "l1 timeout:  $AUTODREAM_L1_TIMEOUT s via $TIMEOUT_BIN"
  else
    log "WARNING: no timeout binary found (brew install coreutils); L1 workers run unbounded and one hang stops the run"
  fi

  # ---- Session roots (which $HOME/.claude*/projects dirs we scan) ----
  probe_roots

  # Flag found-but-not-indexed Claude folders for the report (never a prompt here).
  # Written before the idempotency guard on purpose: a catch-up trigger that no-ops for
  # today should still report folders that appeared since setup.
  write_unindexed_flag

  # ---- Dates that were triaged but never assembled (#36) ----
  # A run killed during L2 leaves a full findings dir and no report, and nothing notices:
  # notify.sh never runs, so there is not even a quiet banner. 2026-07-26 sat that way for
  # two days and was found during an unrelated investigation; 2026-08-01 did it again.
  # The catch-up triggers cannot cover it — launchd will not start a second instance of a
  # label that is already running, so a run slow enough to span its own catch-up window
  # turns those triggers into nothing at all.
  #
  # Recovery is cheap whenever the findings survive (`autodream-now.sh <date>` skips
  # straight to L2), so the gap was never the data. It was that nobody was told. This says
  # so in the log and in run-stats.txt, which puts it in the next morning's report.
  _UNASSEMBLED_RAW=$(unassembled_dates)
  UNASSEMBLED="${_UNASSEMBLED_RAW%%|*}"
  LEGACY_MARKER="${_UNASSEMBLED_RAW##*|}"
  if [ -n "$UNASSEMBLED" ]; then
    log "WARNING: these dates have findings but no complete report: $UNASSEMBLED"
    log "         rebuild one cheaply with: $AUTODREAM_DIR/autodream-now.sh <date>"
  fi
  # Not a warning: these reports are fine, they just predate the marker. Logged so the
  # exemption is auditable - if a date shows up here that should NOT be legacy, the epoch
  # is wrong and that is worth seeing rather than inferring from a missing warning.
  if [ -n "$LEGACY_MARKER" ]; then
    log "note: unmarked reports predating AUTODREAM_MARKER_EPOCH (treated as complete): $LEGACY_MARKER"
  fi

  # Pins an earlier run left unapplied, whichever date they belong to, before the guard can
  # return. Needs only files on disk, so it runs whether or not this date has work to do.
  sweep_stranded_pins

  # ---- Idempotency guard: a finished report means we're done ----
  # A report is only written after a successful L2 and carries the open-questions marker
  # when it is whole, so a report with the marker means the date is complete. This makes launchd catch-up/relaunch (the sleep-resilience strategy:
  # multiple wake-time triggers) cheap no-ops once the night succeeded. A run that
  # failed overnight left NO report, so it correctly proceeds and finishes the work.
  if report_finishes_date && [ "${AUTODREAM_FORCE:-0}" != "1" ]; then
    log "report already exists for $TARGET_DATE ($REPORT_PATH); nothing to do (AUTODREAM_FORCE=1 to rebuild)"
    return 0
  fi
  # Present but not finished: the move-aside before L2 sets it aside as .stale-<epoch>. It is
  # kept if the rebuild fails and discarded once a complete report replaces it.
  if [ -s "$REPORT_PATH" ] && [ "${AUTODREAM_FORCE:-0}" != "1" ]; then
    log "report at $REPORT_PATH lacks the open-questions marker; treating $TARGET_DATE as unfinished and rebuilding it"
  fi

  # The `claude` binary is checked by preflight below, NOT here. An earlier commit
  # moved a `[ -x "$CLAUDE_BIN" ]` test to this spot and its message claimed that
  # made preflight's --l2-bin branch reachable. It did not: this still ran first,
  # and for an absolute path — which CLAUDE_BIN defaults to — `command -v` cannot
  # fail once `[ -x ]` has passed, so the l2_engine branch stayed exercised only by
  # its own test suite. Two gates for one dependency with the second one dead.
  # Preflight owns it, so the check that reports the failure is the one that fires.

  # ---- Preflight: the shared dependencies this script already assumes ----
  # Before anything is ENUMERATED, because the dangerous one fails silently: with
  # shasum absent the artifact hash assignment yields an empty string and every
  # session in the night writes to the same findings filename. A run that got
  # that far would produce one record where it should have produced a hundred
  # and report success. Stopping here costs a night; continuing corrupts one.
  #
  # But BELOW the idempotency guard, which is not enumeration. Above it, a host
  # missing one dependency turned an already-complete date from a one-second
  # no-op into a failed run and an exit 1 on each of the four morning triggers.
  #
  # Gated on -r and invoked through bash, not gated on -x. install.sh's own
  # comment worries about a distribution path that loses the exec bit — a zip, a
  # restrictive umask — and an `[ -x ]` gate answers that by SKIPPING the check
  # silently, which lands you back in exactly the empty-hash corruption preflight
  # exists to stop. A present-but-unreadable preflight says so instead.
  if [ -r "$PREFLIGHT" ]; then
    # Pass the L2 engine. Without it L2_BIN was always empty, so preflight's
    # l2_engine check could only ever fire from its own test suite — a dependency
    # gate with a branch production never reached.
    if ! bash "$PREFLIGHT" --l2-bin "$CLAUDE_BIN" 2>>"$RUN_LOG"; then
      log_fatal "preflight failed; see the MISSING lines in this log. Nothing was enumerated."
      fatal_exit
      return 1
    fi
  else
    log "WARNING: preflight not readable at $PREFLIGHT; the shared-dependency check did NOT run"
  fi

  # ---- Enumerate sessions modified during the target day ----
  if [ "$WINDOW_ON" = 1 ]; then
    log "scanning for sessions with a record between $TARGET_DATE and $NEXT_DATE (placed by the timestamps inside each transcript; a file with none by its mtime)..."
  else
    log "scanning for sessions modified between $TARGET_DATE and $NEXT_DATE..."
  fi
  # Adapter refusals belong with this run's artifacts, not written back into the
  # installed source tree where they persist across runs and vanish entirely on a
  # read-only install.
  export ADAPTERS_REJECT_LOG="$FINDINGS_DIR/.adapters-rejected"
  : > "$ADAPTERS_REJECT_LOG" 2>/dev/null || true
  scan_roots || { fatal_exit; return 1; }
  build_source_sidecar || { fatal_exit; return 1; }
  # A named L2 engine that is not an accepted adapter is refused now, before any model has been
  # paid for, not after L1 has finished and L2 has nothing to run.
  if [ -n "${AUTODREAM_L2_ENGINE:-}" ] && ! adapters_list 2>/dev/null | grep -qxF "$AUTODREAM_L2_ENGINE"; then
    log_fatal "AUTODREAM_L2_ENGINE=$AUTODREAM_L2_ENGINE is not an accepted adapter (accepted: $(adapters_list 2>/dev/null | tr '\n' ' ')). Refusing to start."
    fatal_exit; return 1
  fi
  # And an engine that cannot print a command at all (omp with no model resolved, an adapter
  # without l2-argv) is refused for the same reason. The argv probe skips claude, whose built-in
  # fallback builds the command itself.
  #
  # The system prompt is checked for every engine, claude included: its fallback reads the same file,
  # and an engine started without it runs L2 with no word on where the report goes. Found here, the
  # night stops before L1 is paid for; found later, every L2 attempt fails after it.
  # shellcheck source=/dev/null
  if ! (_l=$(find_lib l2-prompt.sh) && . "$_l" && l2_system_prompt >/dev/null 2>&1); then
    log_fatal "prompts/L2_SYSTEM.txt (read through bin/l2-prompt.sh) was not found beside run.sh, its link target or in AUTODREAM_DIR. Refusing to start."
    fatal_exit; return 1
  fi
  _l2e=$(review_engine)
  if [ "$_l2e" != "claude" ] && [ -n "$_l2e" ]; then
    _l2m=$(adapter_l2_model "$_l2e" 2>/dev/null) || _l2m=""
    if ! adapter_run "$_l2e" l2-argv ${_l2m:+"$_l2m"} 2>/dev/null | head -c 1 | grep -q .; then
      log_fatal "the $_l2e adapter cannot produce an L2 command (model [${_l2m:-none}]); set AUTODREAM_L2_MODEL_$(printf '%s' "$_l2e" | tr 'a-z-' 'A-Z_'). Refusing to start."
      fatal_exit; return 1
    fi
  fi
  # The engine that writes the summary (and runs dream triage) receives every finding, so its login
  # is held to AUTODREAM_REQUIRE_LOGIN before anything is read.
  if ! engine_login_ok "$_l2e"; then
    log_fatal "the $_l2e engine, which writes the summary, fails AUTODREAM_REQUIRE_LOGIN ($LOGIN_REFUSAL). Refusing to start."
    fatal_exit; return 1
  fi

  # Exclude autodream's OWN headless worker/aggregator transcripts. New runs leave none
  # (--no-session-persistence), but runs predating that fix littered ~/.claude/projects/
  # and those files must not be re-triaged. The prune helper owns the predicate; if it's
  # missing, fall back to the raw list rather than silently dropping real sessions.
  if [ -x "$PRUNE" ]; then
    "$PRUNE" --filter < "$SESSIONS_LIST.raw" > "$SESSIONS_LIST" 2>/dev/null || cp "$SESSIONS_LIST.raw" "$SESSIONS_LIST"
  else
    cp "$SESSIONS_LIST.raw" "$SESSIONS_LIST"
  fi
  COUNT_AFTER_PRUNE=$(wc -l < "$SESSIONS_LIST" | tr -d ' ')
  # Subtract the collision drops first. They left the worklist BEFORE the
  # self-prune ran, so charging them to EXCLUDED made a forced two-session
  # collision report self_sessions_excluded: 2 — the report calling files
  # "autodream-own" that were nothing of the kind.
  EXCLUDED=$(( RAW - COLLIDED_DROPPED - COUNT_AFTER_PRUNE ))
  [ "$EXCLUDED" -lt 0 ] && EXCLUDED=0

  # Drop 0-turn shells (auto-opened/aborted sessions with no user input) before fanout.
  # Independent of the self-prune above, so the two telemetry counts don't overlap.
  SKIPPED_EMPTY=0
  if [ "${AUTODREAM_SKIP_EMPTY:-1}" != "0" ]; then
    filter_empty_sessions < "$SESSIONS_LIST" > "$SESSIONS_LIST.nonempty" \
      && mv "$SESSIONS_LIST.nonempty" "$SESSIONS_LIST" \
      || rm -f "$SESSIONS_LIST.nonempty"
  fi
  COUNT=$(wc -l < "$SESSIONS_LIST" | tr -d ' ')
  SKIPPED_EMPTY=$(( COUNT_AFTER_PRUNE - COUNT ))
  if [ "$L1_CHUNKING" = 1 ]; then
    log "L1 chunked triage on: worker input over $AUTODREAM_L1_CHUNK_BYTES bytes is read in chunks, at most $AUTODREAM_L1_MAX_CHUNKS per session (worst case $AUTODREAM_L1_MAX_CHUNKS engine calls for one session in one round); AUTODREAM_L1_CHUNK_BYTES=0 turns it off"
  elif [ "$AUTODREAM_L1_CHUNK_BYTES" -gt 0 ]; then
    log "WARNING: chunked triage is configured (AUTODREAM_L1_CHUNK_BYTES=$AUTODREAM_L1_CHUNK_BYTES) but chunk-transcript.sh or merge-chunks.sh was not found; oversized transcripts are read the old way, the head/tail slim"
  fi
  log "found $RAW session files; excluded $EXCLUDED autodream-own, skipped $SKIPPED_EMPTY empty; $COUNT to triage; $OUT_OF_WINDOW out of window (modified since the day began, nothing inside it)"

  if [ "$COUNT" -eq 0 ]; then
    log "no sessions to triage; writing stub report and exiting"
    # A zero-session night is not always an empty night. Every session can be
    # rejected for an unrepresentable path or dropped by collision handling, and
    # run-stats.txt is written on this path too. Without it the report said "no
    # sessions were modified" while the counters that would have contradicted it
    # were never recorded anywhere. Say what was refused.
    # HASH_COLLISIONS counts collision EVENTS and each drops at least two paths,
    # so adding it to a path total understates the loss. Report the two
    # separately rather than inventing a combined figure that is wrong.
    local refused=$(( REJECTED_PATHS + HASH_COLLISIONS ))
    # An empty worklist owns nothing, so every .err with no findings JSON is orphaned and every
    # findings JSON is outside it. Counted here too: a night that found no session must not
    # report zero over a directory that holds stale failures.
    reconcile_findings_with_worklist
    scan_worklist_leftovers
    local early_err_files; early_err_files=$(ls -1 "$FINDINGS_DIR"/*.json.err 2>/dev/null | wc -l | tr -d ' ')
    {
      printf '# Autodream run self-audit — %s\n' "$TARGET_DATE"
      printf 'runner_commit: %s\n' "$RUNNER_COMMIT"
      printf 'runner_dirty: %s\n' "$RUNNER_DIRTY"
      printf 'sessions_found_raw: %s\n' "$RAW"
      printf 'sessions_triaged: 0\n'
      # Emitted on the zero-triage path too: without them a night where every
      # session was a worker transcript or an empty shell looks identical to a
      # night with no files at all.
      printf 'self_sessions_excluded: %s\n' "$EXCLUDED"
      printf 'sessions_skipped_empty: %s\n' "$SKIPPED_EMPTY"
      printf 'sessions_rejected_path: %s\n' "$REJECTED_PATHS"
      printf 'sessions_out_of_window: %s\n' "$OUT_OF_WINDOW"
      printf 'session_window: %s\n' "$([ "$WINDOW_ON" = 1 ] && echo on || echo off)"
      printf 'sessions_windowed: 0\n'
      printf 'sessions_duplicate_path: %s\n' "$DUPLICATE_PATHS"
      printf 'sessions_hash_collision: %s\n' "$HASH_COLLISIONS"
      printf 'sessions_dropped_to_collision: %s\n' "$COLLIDED_DROPPED"
      printf 'sidecar_stale_rows: %s\n' "$SIDECAR_STALE_ROWS"
      # The shortfall counters belong here most of all: this block exists so a
      # zero-triage night does not read as an empty one, and a partial walk or a
      # regression to single-root scanning is exactly what would explain it.
      printf 'roots_partially_enumerated: %s\n' "$PARTIAL_ROOTS"
      printf 'roots_unavailable: %s\n' "$ROOTS_UNAVAILABLE"
      printf 'roots_failed: %s\n' "$ROOTS_FAILED"
      printf 'session_roots: %s\n' "$(( $(printf '%s' "$SESSION_ROOTS" | tr -cd ':' | wc -c) + 1 ))"
      printf 'session_roots_list: %s\n' "$SESSION_ROOTS"
      printf 'adapters_rejected: %s\n' "$(adapters_rejected 2>/dev/null)"
      printf 'adapters_enabled: %s\n' "$(printf '%s' "$ENABLED_ADAPTERS" | tr ' ' ',' | sed 's/,$//')"
      printf 'sessions_by_source: %s\n' "${SESSIONS_BY_SOURCE:-none}"
      # The rest of the key set, emitted as real zeroes rather than omitted.
      # PROMPT.md tells L2 that keys missing from run-stats.txt mean the runner
      # predated the stat, so a zero-session night on CURRENT code produced a
      # morning report blaming a stale checkout for the gap. A night with nothing
      # to triage genuinely did zero L1 rounds and measured no overlap; saying so
      # is different from not saying it.
      # Key names copied from the full-run block below, not invented. The first
      # draft of this emitted l1_missing, oversized_slimmed, overlap_pairs and
      # elapsed — none of which that block writes — which would have left the real
      # keys still missing while adding four L2 has never seen.
      printf 'sessions_dropped_after_failures: 0\n'
      printf 'gated: 0\n'
      printf 'l1_rounds_max: %s\n' "${AUTODREAM_L1_ROUNDS:-5}"
      printf 'l1_rounds_used: 0\n'
      printf 'l1_timeout_bin: %s\n' "${TIMEOUT_BIN:-none}"
      printf 'l1_timeout_seconds: %s\n' "$AUTODREAM_L1_TIMEOUT"
      printf 'l1_timed_out: 0\n'
      printf 'l1_warmup: not_reached\n'
      printf 'l1_breaker_fired: not_reached\n'
      printf 'l1_chunk_bytes: %s\n' "$([ "$L1_CHUNKING" = 1 ] && echo "$AUTODREAM_L1_CHUNK_BYTES" || echo 0)"
      printf 'l1_max_chunks: %s\n' "$AUTODREAM_L1_MAX_CHUNKS"
      printf 'l1_chunked_sessions: 0\n'
      printf 'l1_chunks: 0\n'
      printf 'l1_chunk_calls: 0\n'
      printf 'l1_chunks_elided: 0\n'
      printf 'l1_findings_written: 0\n'
      printf 'l1_missing_after_retries: 0\n'
      printf 'l1_err_files: %s\n' "$early_err_files"
      printf 'l1_err_files_orphaned: %s\n' "$L1_ERR_ORPHANED"
      printf 'l1_findings_outside_worklist: %s\n' "$FINDINGS_OUTSIDE_WORKLIST"
      printf 'l1_findings_with_error: 0\n'
      printf 'l1_errored_silent: 0\n'
      printf 'l1_errored_provider: 0\n'
      printf 'l1_errored_unclassified: 0\n'
      printf 'l1_sessions_already_done_at_start: 0\n'
      printf 'l1_cache_dropped: 0\n'
      printf 'l1_sessions_freshly_processed: 0\n'
      printf 'l1_elapsed_seconds: 0\n'
      printf 'oversized_total: 0\n'
      printf 'oversized_errored: 0\n'
      printf 'oversized_errored_silent: 0\n'
      printf 'oversized_errored_provider: 0\n'
      printf 'oversized_errored_unclassified: 0\n'
      printf 'oversized_unmeasurable: %s\n' "${OVERSIZED_UNMEASURABLE:-0}"
      printf 'stats_sidecars_unparseable: 0\n'
      # A night with nothing to triage genuinely measured no overlap. That is not
      # the same as the overlap pass having failed, and the zero counts below are
      # the honest pair that goes with it.
      printf 'overlap_measured: no\n'
      printf 'overlap_events: 0\n'
      printf 'sessions_with_overlap: 0\n'
      printf 'sessions_top_level: 0\nsessions_nested: 0\nfanout_parents: 0\nlargest_fanout: 0\n'
      # EMPTY, not `none`. PROMPT.md defines empty as "none" for this key and tells
      # L2 to name the dates for any non-empty value, so `none` was handed to it as
      # a date list to report.
      printf 'unassembled_dates: %s\n' "${UNASSEMBLED:-}"
    } > "$FINDINGS_DIR/run-stats.txt" 2>/dev/null || true
    cat > "$REPORT_PATH" <<EOF
# Autodream — $TARGET_DATE

No sessions were triaged on this date.

$( if [ "${ROOTS_FAILED:-0}" -gt 0 ] || [ "${ROOTS_UNAVAILABLE:-0}" -gt 0 ]; then
     # A failed root makes "no session files were modified" a claim this run
     # cannot support: it did not read one of the stores it was meant to. The
     # fatal for a single failed root was removed because on a single-root host
     # that shape is a quiet date plus a transient find error, and losing the
     # night is the wrong trade. That is only defensible while the stub refuses
     # to state an empty night as fact.
     # Both classes, and against ROOTS_CONFIGURED rather than ROOTS_SCANNED. A root
     # that was never a directory — a `:` inside a SESSION_ROOTS entry, or a store
     # that moved — was not read either, and it is missing from ROOTS_SCANNED
     # entirely, so measuring against that under-reported how many were configured.
     printf '%s of %s configured session root(s) were unreadable or failed to enumerate, so this run did not read the whole store. Nothing was triaged from what it did read. See roots_failed and roots_unavailable in run-stats.txt — whether this was an empty night is unknown.' \
       "$(( ROOTS_FAILED + ROOTS_UNAVAILABLE ))" "$ROOTS_CONFIGURED"
   elif [ "$RAW" -eq 0 ] && [ "$refused" -eq 0 ] && [ "$OUT_OF_WINDOW" -gt 0 ]; then
     # Files were modified since the day began, so "none were modified" is false. They
     # hold no record inside the day, which makes this a quiet day for them to be quiet
     # about, but it is said with the count rather than left to read as an empty store.
     printf 'No session had a record inside this day. %s file(s) modified since it began hold none and belong to another day. See sessions_out_of_window in run-stats.txt.' \
       "$OUT_OF_WINDOW"
   elif [ "$RAW" -eq 0 ] && [ "$refused" -eq 0 ]; then
     printf 'No session files were modified.'
   else
     # Refused paths never reach sessions.txt.raw, so they are NOT part of RAW.
     # Folding them into "N session file(s) were modified" produced sentences
     # like "0 session file(s) were modified ... 3 with an unrepresentable path".
     # The two are counted separately because they are separate facts.
     printf 'Nothing was triaged. %s session file(s) were enumerated (%s autodream-own, %s with no substantive turns); a further %s path(s) were refused before enumeration, and %s hash-collision event(s) each dropped two or more paths. See run-stats.txt — this is not an empty night.' \
       "$RAW" "$EXCLUDED" "$SKIPPED_EMPTY" "$REJECTED_PATHS" "$HASH_COLLISIONS"
   fi )

(Generated $(date -u +%Y-%m-%dT%H:%M:%SZ))

AUTODREAM_QUESTIONS_BEGIN
## Open questions for the user

None; no sessions were triaged on this date.

<!-- autodream:open-questions=0 -->
AUTODREAM_QUESTIONS_END
EOF
    # A question-free report still counts as a report. Without this the streak
    # store would keep yesterday's questions alive across an empty night, and a
    # question that reappeared two reports later would be called consecutive when
    # it was not. The early return below is why this cannot live at the usual call
    # site at the top of the report-present block.
    if [ -x "$AUTODREAM_DIR/question-streaks.sh" ]; then
      env AUTODREAM_DIR="$AUTODREAM_DIR" "$AUTODREAM_DIR/question-streaks.sh" update "$REPORT_PATH" "$FINDINGS_DIR" \
        || log "question-streaks returned non-zero (continuing)"
    fi
    return 0
  fi

  # Compute once from the final enumeration. Retry rounds reuse these sidecars;
  # they are intentionally not regenerated during dispatch retries.
  compute_session_stats

  # Global pass: must run AFTER every session's sidecar exists (overlap is a
  # cross-session computation, not per-session). Deliberately BEFORE the noise gate
  # runs inside dispatch_l1 below — gated sessions' sidecars still exist and still
  # participate in overlap (see the comment in bin/overlap-stats.sh).
  compute_overlap_stats
  FANOUT_ROWS=$(fanout_rows "$FINDINGS_DIR")

  # ---- Pin authorization, fixed before any model runs ----
  # L1 and L2 both run with the Write tool and bypassPermissions, so any file they can
  # reach they can rewrite: sessions.txt, sessions-source.txt, findings JSON. The projects
  # a memory pin may name are therefore computed here, before the first model call, and
  # held in this shell's memory until the pins are applied after the report.
  PIN_PROJECTS_BUILT=0
  PIN_PROJECTS_TSV=""
  SESSION_ROWS=""
  if SESSION_ROWS=$(session_rows "$FINDINGS_DIR") \
     && PIN_PROJECTS_TSV=$(printf '%s\n' "$SESSION_ROWS" | pin_projects_from_rows); then
    PIN_PROJECTS_BUILT=1
  else
    log "WARNING: could not build the pin authorization list; this run will not store memory pins"
  fi

  # The ledger of stored pins gets the same treatment: a worker with the Write tool could
  # empty it, and the apply step would then store every pin again. Its content is held here
  # and put back before the pins are applied. A ledger that exists but cannot be read
  # leaves nothing to restore from, so this run stores no pins.
  PINS_LEDGER_PRESENT=0
  PINS_LEDGER_SNAPSHOT_X=""
  PINS_LEDGER_OK=1
  if [ -e "$FINDINGS_DIR/pins-applied.tsv" ]; then
    # The trailing x keeps $(...) from stripping the ledger's final newline.
    if PINS_LEDGER_SNAPSHOT_X=$(cat -- "$FINDINGS_DIR/pins-applied.tsv" 2>/dev/null && printf x); then
      PINS_LEDGER_PRESENT=1
    else
      log "WARNING: could not read pins-applied.tsv; this run will not store memory pins"
      PINS_LEDGER_OK=0
    fi
  fi

  # ---- Layer 1: haiku triage, parallel, retried across sleep/network gaps ----
  # Lean-query env (claude-cells internal/claude/query.go pattern): keep subscription
  # OAuth auth but strip per-call bloat — no CLAUDE.md auto-load, no telemetry/error
  # reporting. Combined with the per-call flags (--no-session-persistence, --tools,
  # --disable-slash-commands, --strict-mcp-config, --settings disableAllHooks) this is
  # the token-minimal footprint WITHOUT --bare (which would disable OAuth/keychain auth
  # and require an API key). Exported once so both the L1 xargs subshells and the L2
  # call inherit it.
  export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1
  export CLAUDE_BIN AUTODREAM_DIR FINDINGS_DIR SLIM WORK_DIR
  # The report-day window, read by the dispatcher subshell to cut a multi-day transcript.
  export WINDOW_ON SESSION_WINDOW WIN_START_EPOCH WIN_END_EPOCH TARGET_DATE
  # Chunked triage, read by the dispatcher subshell. L1_CHUNKING is the one switch: 0 leaves the
  # slimmer in its default mode and never reaches the chunker or the merge.
  export L1_CHUNKING CHUNKER MERGER AUTODREAM_L1_CHUNK_BYTES AUTODREAM_L1_MAX_CHUNKS
  # Which adapter runs each session, and which model each adapter's workers use, fixed here
  # before the first model call and held in the environment (see the worker comment). The
  # models are resolved once per adapter, not per session.
  ADAPTERS_DIR=$(adapters_root)
  AUTODREAM_SOURCE_MAP=$(cat "$FINDINGS_DIR/sessions-source.txt" 2>/dev/null)
  AUTODREAM_L1_MODELS=""
  AUTODREAM_L1_ENGINES=""
  AUTODREAM_L1_PROBE_URLS=""
  local _src _model _purl _engine _reviewer
  _reviewer=$(review_engine)
  while IFS= read -r _src; do
    [ -n "$_src" ] || continue
    # The engine first: a choice that names no accepted adapter leaves this source with no model,
    # so its sessions get error records instead of a call on some other engine.
    _engine=$(adapter_l1_engine "$_src" "$_reviewer" 2>/dev/null) || _engine=""
    _model=""
    if [ -n "$_engine" ]; then
      _model=$(adapter_l1_model "$_src" "$_reviewer" 2>/dev/null) || _model=""
    else
      log "WARNING: the L1 engine chosen for adapter $_src names no accepted adapter; its sessions will not be triaged"
    fi
    AUTODREAM_L1_MODELS="${AUTODREAM_L1_MODELS}${_src}"$'\t'"${_model}"$'\n'
    AUTODREAM_L1_ENGINES="${AUTODREAM_L1_ENGINES}${_src}"$'\t'"${_engine}"$'\n'
    _purl=$(provider_probe_url "$_engine" "$_model" 2>/dev/null) || _purl=""
    AUTODREAM_L1_PROBE_URLS="${AUTODREAM_L1_PROBE_URLS}${_src}"$'\t'"${_purl}"$'\n'
    [ -n "$_model" ] || log "WARNING: no L1 model resolves for adapter $_src; its sessions will not be triaged"
    if [ -n "$_engine" ] && [ "$_engine" != "$_src" ]; then
      log "L1 model for $_src: ${_model:-<none>} (on the $_engine engine)"
    else
      log "L1 model for $_src: ${_model:-<none>}"
    fi
  done < <(printf '%s\n' "$AUTODREAM_SOURCE_MAP" | awk -F'\t' 'NF >= 2 && !seen[$2]++ { print $2 }')
  AUTODREAM_NORMALIZE_SOURCES=""
  while IFS= read -r _src; do
    [ -n "$_src" ] || continue
    [ "$(adapter_manifest_get "$_src" '.normalize' 2>/dev/null)" = "true" ] \
      && AUTODREAM_NORMALIZE_SOURCES="${AUTODREAM_NORMALIZE_SOURCES:+$AUTODREAM_NORMALIZE_SOURCES }$_src"
  done < <(printf '%s\n' "$AUTODREAM_SOURCE_MAP" | awk -F'\t' 'NF >= 2 && !seen[$2]++ { print $2 }')
  # Every L1 engine is held to AUTODREAM_REQUIRE_LOGIN before any transcript is sent (engine_login_ok).
  # One that fails is taken out of AUTODREAM_L1_ENGINES, so the sessions it would have read get error
  # records and no model call, the same path as a choice naming no accepted adapter.
  local _eng
  while IFS= read -r _eng; do
    [ -n "$_eng" ] || continue
    engine_login_ok "$_eng" && continue
    log "WARNING: the $_eng engine fails AUTODREAM_REQUIRE_LOGIN ($LOGIN_REFUSAL); the sessions it would read will not be triaged"
    AUTODREAM_L1_ENGINES=$(printf '%s' "$AUTODREAM_L1_ENGINES" | awk -F'\t' -v e="$_eng" 'BEGIN { OFS = "\t" } $2 == e { $2 = "" } { print }')$'\n'
  done < <(printf '%s' "$AUTODREAM_L1_ENGINES" | awk -F'\t' 'NF >= 2 && $2 != "" && !seen[$2]++ { print $2 }')
  export ADAPTERS_DIR AUTODREAM_SOURCE_MAP AUTODREAM_L1_MODELS AUTODREAM_L1_ENGINES AUTODREAM_L1_PROBE_URLS AUTODREAM_NORMALIZE_SOURCES
  # AUTODREAM_L1_ROUNDS is referenced by the dispatcher subshell to decide
  # whether this is the last retry round (gates the metadata-stub fallback).
  export AUTODREAM_L1_ROUNDS
  # Read by the dispatcher subshell to bound each worker. TIMEOUT_BIN is empty when no timeout
  # binary exists, which the worker treats as run-unbounded.
  export TIMEOUT_BIN AUTODREAM_L1_TIMEOUT L1_KILL_GRACE FAILURE_CLASS

  # Truncate the timeout ledger here rather than where FINDINGS_DIR is created: this point is
  # past the idempotency guard, so a catch-up trigger that no-ops on a finished date cannot wipe
  # that date's record of what timed out.
  : > "$FINDINGS_DIR/l1-timeouts.txt"
  : > "$FINDINGS_DIR/l1-netdown.txt"
  # Per-run chunk ledgers, append-only like the two above. l1-chunks.txt holds one "hash chunks
  # elided" line each time a session is planned (a retry plans it again, so readers keep the last
  # line per hash); l1-chunk-calls.txt one "hash round chunk" line per engine call actually made, a
  # reused answer making none, which is what a night cost in model calls.
  if [ "$L1_CHUNKING" = 1 ]; then
    : > "$FINDINGS_DIR/l1-chunks.txt"
    : > "$FINDINGS_DIR/l1-chunk-calls.txt"
  fi

  sweep_killed_leftovers
  reconcile_findings_with_worklist
  drop_unacceptable_l1_cache

  clean_work_bucket  # start clean: drop any stub left by a prior run's workers

  # Pre-L1 cache snapshot: how many sessions in the worklist already have a valid
  # findings JSON before any worker runs. Without this, a re-run after a partial
  # crash shows an "impossible" l1_elapsed_seconds (e.g. 2s for 36 sessions)
  # because the dispatcher's idempotent skip exits every worker instantly. The
  # aggregator's self-audit needs this to disambiguate "fast run" from "broken
  # timer".
  L1_PRECACHED=$(l1_missing_count)
  L1_PRECACHED=$(( COUNT - L1_PRECACHED ))

  # ---- Auth warmup: one serial model call per adapter before the parallel dispatch ----
  # FANOUT workers starting cold at once all find the same expired token and all try to refresh
  # it. One serial call first means the refresh happens once. It never fails the run; the verdict
  # lands in run-stats as l1_warmup. Bounded by its own deadline, because it runs ahead of every
  # recovery path (the retry loop, the circuit breaker, wait_for_network): an unbounded warmup
  # that hangs on exactly the cold-start condition it targets wedges the run before all of them,
  # with launchd suppressing later triggers while the job stays alive. With no timeout binary it
  # is skipped, not run unbounded.
  L1_WARMUP=skipped
  if [ "${AUTODREAM_L1_WARMUP:-1}" = "0" ]; then
    :
  elif [ -z "$TIMEOUT_BIN" ]; then
    L1_WARMUP=skipped_no_timeout
    log "L1 auth warmup skipped: no timeout binary, and an unbounded warmup can wedge the run before every retry path"
  else
    L1_WARMUP=ok
    while IFS=$'\t' read -r _wsrc _wmodel; do
      [ -n "$_wsrc" ] && [ -n "$_wmodel" ] || continue
      # Warm the engine the workers will call, which an AUTODREAM_L1_ENGINE_<NAME> override moves.
      _weng=$(printf '%s\n' "$AUTODREAM_L1_ENGINES" | awk -F'\t' -v s="$_wsrc" '$1 == s { print $2; exit }')
      [ -n "$_weng" ] || continue
      _wargv=(); _wenv=()
      while IFS= read -r -d "" _a; do _wargv+=("$_a"); done < <(adapter_run "$_weng" warmup-argv "$_wmodel" 2>/dev/null)
      while IFS= read -r _l; do [ -n "$_l" ] && _wenv+=("$_l"); done < <(adapter_run "$_weng" l1-env 2>/dev/null)
      if [ "${#_wargv[@]}" -eq 0 ]; then
        L1_WARMUP=failed
        log "L1 auth warmup FAILED for $_wsrc: the adapter printed no warmup command"
        continue
      fi
      _werr="$FINDINGS_DIR/l1-warmup.$_wsrc.err"
      # ${arr[@]+"${arr[@]}"}, not "${arr[@]}": run.sh runs under /bin/bash 3.2 with set -u, where
      # expanding an EMPTY array is an unbound-variable error. omp's l1-env prints nothing, so the
      # pipeline aborted before timeout started and the warmup recorded failed, blaming a healthy provider.
      _wout=$(printf 'ping\n' | env ${_wenv[@]+"${_wenv[@]}"} "$TIMEOUT_BIN" -k 10 "$AUTODREAM_L1_WARMUP_TIMEOUT" "${_wargv[@]}" 2>"$_werr")
      _wrc=$?
      # The warmup asks for the single word ok. Anything else on stdout with exit 0 is a
      # diagnostic, not a reply, and must not read as a healthy provider. Case and surrounding
      # whitespace or punctuation are tolerated.
      _wword=$(printf '%s' "$_wout" | tr -d '[:space:][:punct:]' | tr '[:upper:]' '[:lower:]')
      if [ "$_wrc" -eq 0 ] && [ "$_wword" = "ok" ]; then
        log "L1 auth warmup ok ($_wsrc)"
      else
        L1_WARMUP=failed
        # The point of the warmup is that this line exists before 8 workers repeat the failure in
        # parallel and bury it. Name both streams: an empty stdout IS the finding.
        log "L1 auth warmup FAILED for $_wsrc (exit $_wrc): stdout=[${_wout:-<empty>}] stderr=[$(head -c 300 "$_werr" 2>/dev/null | tr '\n' ' ')]"
      fi
    done < <(printf '%s' "$AUTODREAM_L1_MODELS")
    unset _wsrc _wmodel _weng _wargv _wenv _a _l _werr _wout _wrc _wword
  fi

  L1_START=$(date +%s)
  L1_ROUNDS="${AUTODREAM_L1_ROUNDS:-5}"
  MISSING=$COUNT
  LAST_ROUND_RUN=0
  # Set when a round could not be dispatched because the host had no route, or when the last
  # round failed with no route or a permanent provider refusal. The run then stops before L2
  # and writes no report, so the date stays unassembled and a later catch-up trigger retries
  # it. A report written from a dead-network or no-balance run looks complete, ships open
  # questions, and its own self-audit cannot tell the corpus is missing.
  NET_DEFERRED=no
  # Consecutive rounds that recovered nothing. A streak, not a comparison against the last
  # round's ending count: comparing end-to-end counts calls two rounds barren whenever the SECOND
  # one is, because round 1 having recovered sessions is invisible in its own ending number.
  # Round 1 taking 3 missing down to 1 and round 2 recovering none leaves both ends equal at 1,
  # which tripped the breaker after a single bad round and logged the lie that rounds 1 and 2
  # both recovered nothing. Any recovery resets the streak to zero.
  L1_NOPROGRESS=0
  L1_BREAKER=no
  for round in $(seq 1 "$L1_ROUNDS"); do
    # Check BEFORE dispatching, including round 1: the overnight failure is a Mac that slept
    # through its trigger, so round 1 is the round most likely to run at a host with no route.
    if ! wait_for_network "$(l1_probe_urls)"; then
      NET_DEFERRED=yes
      log "L1 round $round not dispatched: no route to the API. Deferring $TARGET_DATE for a later run."
      break
    fi
    log "L1 triage round $round/$L1_ROUNDS (fanout=$FANOUT)..."
    # The dispatcher's subshell reads this to decide whether the last-round
    # metadata-stub fallback should fire for sessions that produced no output.
    export AUTODREAM_CURRENT_ROUND="$round"
    # Sampled before the dispatch, so "did THIS round recover anything" is answerable without
    # inferring it from the previous round's ending count.
    round_start_missing=$(l1_missing_count)
    round_start_chunks=$(l1_chunk_answers)
    dispatch_l1
    LAST_ROUND_RUN="$round"
    MISSING=$(l1_missing_count)
    L1_DONE=$(findings_json_count)
    log "L1 round $round: $L1_DONE done, $MISSING still missing"
    [ "$MISSING" -eq 0 ] && break
    if [ "$MISSING" -lt "$round_start_missing" ] || [ "$(l1_chunk_answers)" -gt "$round_start_chunks" ]; then
      L1_NOPROGRESS=0
    else
      L1_NOPROGRESS=$((L1_NOPROGRESS + 1))
    fi
    # Circuit breaker. The retry budget is built for a Mac sleeping through a round, and against
    # that it works. Against a worker that dies the same way every time it buys nothing and hides
    # the shape: 2026-09-08 spent all five rounds and 405s to write 16 empty stubs, and the
    # run-stats it left (l1_rounds_used 5 of 5, l1_timed_out 0) read as a healthy retry loop
    # rather than as five identical failures. Two consecutive rounds that recover no session
    # means deterministic, not transient.
    #
    # It still has to dispatch once more. The metadata-stub fallback fires only when the
    # dispatcher sees AUTODREAM_CURRENT_ROUND at the budget, so breaking out here without that
    # round would leave the slots empty, and an empty slot is not a stub. So jump to the last
    # round rather than skipping to the end: three dispatches instead of five, with the same
    # artifacts on disk. The -lt guard matters at AUTODREAM_L1_ROUNDS=2 (the suite runs low
    # budgets): there the final round IS the stub round and has already run.
    if [ "$L1_NOPROGRESS" -ge 2 ] && [ "$round" -lt "$L1_ROUNDS" ]; then
      L1_BREAKER=yes
      log "L1 circuit breaker: $L1_NOPROGRESS consecutive rounds recovered nothing ($MISSING still missing) as of round $round. Failure is deterministic; skipping $((L1_ROUNDS - round - 1)) retry round(s) and dispatching the stub round."
      export AUTODREAM_CURRENT_ROUND="$L1_ROUNDS"
      dispatch_l1
      LAST_ROUND_RUN="$L1_ROUNDS"
      MISSING=$(l1_missing_count)
      L1_DONE=$(findings_json_count)
      log "L1 stub round: $L1_DONE done, $MISSING still missing"
      break
    fi
    if [ "$round" -lt "$L1_ROUNDS" ]; then
      log "L1 retrying $MISSING missing session(s) after a network/sleep check..."
      sleep "${AUTODREAM_RETRY_WAIT:-60}"
    fi
  done
  # Decide the outage question AFTER the retry budget, not during it: one transient DNS
  # timeout mid-round must be ridden out on the next round, not defer the date. Both
  # conditions are required: sessions are still missing, AND the last round that dispatched
  # saw a no-route failure or a permanent provider refusal. A run that recovered is never
  # deferred, however bad round 1 was.
  if [ "$MISSING" -gt 0 ] && [ "$LAST_ROUND_RUN" -gt 0 ] \
     && [ -s "$FINDINGS_DIR/l1-netdown.txt" ] \
     && awk -v r="$LAST_ROUND_RUN" '$2 == r && ($3 == "true" || $3 == "provider") { found = 1 } END { exit !found }' \
          "$FINDINGS_DIR/l1-netdown.txt"; then
    NET_DEFERRED=yes
    log "L1 finished with $MISSING session(s) missing and round $LAST_ROUND_RUN failing with no route or a provider refusal — deferring $TARGET_DATE for a later run"
  fi
  L1_ELAPSED=$(( $(date +%s) - L1_START ))
  L1_OK=$(findings_json_count)
  L1_FAIL=$(ls -1 "$FINDINGS_DIR"/*.json.err 2>/dev/null | wc -l | tr -d " ")
  # Leftovers this run's worklist does not own: see scan_worklist_leftovers.
  scan_worklist_leftovers
  read -r L1_CHUNKED_SESSIONS L1_CHUNKS L1_CHUNKS_ELIDED L1_CHUNK_CALLS <<< "$(l1_chunk_totals)"
  # In-band failures: a worker that ran to completion but couldn't fit the transcript
  # writes a findings JSON carrying a top-level "error" key (empty findings). These are
  # NOT .json.err files, so l1_err_files=0 masked them — count them explicitly so the
  # self-audit can alarm on a high extraction-failure rate (slimming should drive →0).
  L1_ERRORED=0
  # Count every stub, then classify its surviving .err before the self-audit decides whether
  # the failure says anything about transcript size. A provider refusal or a worker that died
  # silently is not evidence about size (see failure-class.sh).
  L1_ERRORED_SILENT=0
  L1_ERRORED_PROVIDER=0
  L1_ERRORED_UNCLASSIFIED=0
  for findingsfile in "$FINDINGS_DIR"/*.json; do
    [ -f "$findingsfile" ] || continue
    case "$findingsfile" in *.stats.json) continue ;; esac
    findings_has_error "$findingsfile" || continue
    L1_ERRORED=$((L1_ERRORED + 1))
    failure_class=$(classify_failure "$findingsfile.err")
    case "$failure_class" in
      silent) L1_ERRORED_SILENT=$((L1_ERRORED_SILENT + 1)) ;;
      provider) L1_ERRORED_PROVIDER=$((L1_ERRORED_PROVIDER + 1)) ;;
      unclassified) L1_ERRORED_UNCLASSIFIED=$((L1_ERRORED_UNCLASSIFIED + 1)) ;;
    esac
  done
  # Noise-gated sessions: dispatch_l1 wrote a stub instead of calling the model
  # (see the "Noise gate" comment in dispatch_l1). Counted from the findings
  # dir rather than a shared counter, since each gate decision happens inside
  # an independent xargs subshell with no shared state to increment.
  GATED=$(find "$FINDINGS_DIR" -maxdepth 1 -type f -name '*.json' ! -name '*.stats.json' \
    -exec grep -l '"skipped": *"below_noise_gate"' {} + 2>/dev/null | wc -l | tr -d " ")
  compute_fanout_stats
  log "L1 done in ${L1_ELAPSED}s: $L1_OK done ($L1_ERRORED with errors: $L1_ERRORED_SILENT silent, $L1_ERRORED_PROVIDER provider, $L1_ERRORED_UNCLASSIFIED unclassified; $GATED gated), $MISSING missing (.err files: $L1_FAIL)"

  # ---- Oversized-transcript measurement gate (#12) ----
  # Issue #12 proposes chunk-summarizing oversized transcripts instead of slimming them;
  # that implementation is BLOCKED pending evidence it's actually needed. These two
  # counters are the measurement: how many triaged sessions exceeded AUTODREAM_SLIM_BYTES
  # (the same threshold dispatch_l1 checks before calling slim-transcript.sh), and of
  # those, how many still ended in an in-band failure (the same top-level "error" key
  # L1_ERRORED checks above) despite the existing fallback stack (slimming, chunked-Read
  # guidance, metadata-stub path). Gate: if oversized_errored/oversized_total sustains
  # >= 5% over a trailing week, that's the signal issue #12's gate has opened; below that
  # the fallback stack is doing its job. This script only records the counters — the L2
  # self-audit and the human do the trailing-week judgment.
  # Computed post-hoc from the *.stats.json sidecars' transcript_bytes field, same
  # post-hoc pattern as GATED/L1_ERRORED above: the per-worker sz variable at dispatch
  # time (line ~309) lives in an xargs subshell with no shared state to increment
  # directly, so this re-derives it from the sidecar written before dispatch instead.
  #
  # Iterate the SESSION LIST, not the *.stats.json glob (#27). A sidecar that was never
  # written — compute_session_stats deletes the file whenever session-stats.sh fails —
  # is absent from the glob entirely, so the session it belonged to used to drop out of
  # oversized_total without appearing anywhere. Walking the worklist means every triaged
  # session is accounted for exactly once, whatever state its sidecar is in, and stale
  # sidecars left by an earlier enumeration no longer sneak into the count.
  #
  # STATS_SIDECARS_UNPARSEABLE is the shared health signal for every sidecar consumer
  # (#27). One broken sidecar corrupts several counters at once — the noise gate reads
  # the same file inside dispatch_l1 — so the failures are counted once here rather than
  # each stat carrying its own measured/not-measured flag. A sidecar counts as
  # unparseable when it is missing, empty, not valid JSON, or carries no numeric
  # transcript_bytes. The noise gate's own read is deliberately left alone: it already
  # biases to triage on an unreadable sidecar (worst case, a wasted model call), and the
  # only thing missing there was the signal, which this counter now supplies.
  OVERSIZED_TOTAL=0
  OVERSIZED_ERRORED=0
  OVERSIZED_ERRORED_SILENT=0
  OVERSIZED_ERRORED_PROVIDER=0
  OVERSIZED_ERRORED_UNCLASSIFIED=0
  STATS_SIDECARS_UNPARSEABLE=0
  OVERSIZED_UNMEASURABLE=0
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    # Same reasoning as compute_session_stats above: no hash means no sidecar to
    # UNMEASURABLE: excluded from both counters, exactly as oversized-gate.sh:105
    # does for the same case. An earlier version of this counted it in
    # oversized_total but never in oversized_errored, and its comment claimed that
    # dropping the session biased the #12 gate closed. The reasoning was inverted.
    # The gate is oversized_errored / oversized_total, so padding the DENOMINATOR
    # with sessions whose size was never read pushes the share DOWN and holds the
    # gate closed; dropping one raises it. That version also made the runner and
    # oversized-gate.sh disagree about the same findings dir — run.sh reporting
    # `12 / 0` and GATE CLOSED where the gate tool reported 0 oversized and 12
    # unmeasurable.
    #
    # Nor is it a sidecar parse failure: a session with no derivable key has no
    # sidecar to parse. Conflating the two hid a keying failure inside a counter
    # about file contents, so it gets its own.
    hash=$(session_hash "$session") || {
      OVERSIZED_UNMEASURABLE=$((OVERSIZED_UNMEASURABLE + 1))
      log "  WARNING: could not derive an artifact hash for $session; excluded from the oversized gate as unmeasurable"
      continue
    }
    statsfile="$FINDINGS_DIR/$hash.stats.json"
    sz=""
    [ -s "$statsfile" ] && sz=$(jq -r '.transcript_bytes | numbers | floor' "$statsfile" 2>/dev/null)
    case "$sz" in ''|*[!0-9]*) sz="" ;; esac
    if [ -z "$sz" ]; then
      STATS_SIDECARS_UNPARSEABLE=$((STATS_SIDECARS_UNPARSEABLE + 1))
      # Measure the transcript directly rather than letting the session fall out of the
      # count. transcript_bytes is `wc -c` of the file the stats were computed over, which
      # is the file the worker reads: the transcript itself, or the normalized copy, or the
      # day slice when the transcript spans more than the report day. dispatch_l1 sizes that
      # same file before slimming, so this is the same quantity from its original source for
      # a single-day transcript, and the whole file (an overstatement) for a multi-day one. It is
      # not an estimate. A clamped 0 here would bias the #12 gate toward staying closed,
      # which is the whole point of the issue.
      sz=$(wc -c < "$session" 2>/dev/null | tr -d ' ')
      case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
    fi
    if [ "$sz" -gt "${AUTODREAM_SLIM_BYTES:-262144}" ]; then
      OVERSIZED_TOTAL=$((OVERSIZED_TOTAL + 1))
      findingsfile="$FINDINGS_DIR/$hash.json"
      if [ -f "$findingsfile" ] && findings_has_error "$findingsfile"; then
        OVERSIZED_ERRORED=$((OVERSIZED_ERRORED + 1))
        failure_class=$(classify_failure "$findingsfile.err")
        case "$failure_class" in
          silent) OVERSIZED_ERRORED_SILENT=$((OVERSIZED_ERRORED_SILENT + 1)) ;;
          provider) OVERSIZED_ERRORED_PROVIDER=$((OVERSIZED_ERRORED_PROVIDER + 1)) ;;
          unclassified) OVERSIZED_ERRORED_UNCLASSIFIED=$((OVERSIZED_ERRORED_UNCLASSIFIED + 1)) ;;
        esac
      fi
    fi
  done < "$SESSIONS_LIST"
  log "oversized: $OVERSIZED_TOTAL session(s) over ${AUTODREAM_SLIM_BYTES:-262144} bytes ($OVERSIZED_ERRORED errored: $OVERSIZED_ERRORED_SILENT silent, $OVERSIZED_ERRORED_PROVIDER provider, $OVERSIZED_ERRORED_UNCLASSIFIED unclassified)"
  if [ "$STATS_SIDECARS_UNPARSEABLE" -gt 0 ]; then
    log "stats sidecars unparseable: $STATS_SIDECARS_UNPARSEABLE of $COUNT (sizes fell back to a live read; gated/oversized counts are degraded)"
  fi

  # ---- Normalize the project field deterministically from the session path ----
  # SESSION_TRIAGE.md asks the L1 worker to emit "project" by hand, and haiku does it
  # nondeterministically: one run surfaced the SAME -Users-sean dir as "-Users-sean",
  # "Users-sean" (dash stripped), and even the bare session UUID (filename, not dir).
  # That splinters L2's per-project grouping. The project is the bucket the runner already
  # computed for each session in SESSION_ROWS (see session_rows), before L1 ran. Each findings
  # file is looked up by its own name, the session hash, never by the session_path the model
  # wrote, and its project field is overwritten. Deterministic, idempotent on re-runs.
  if command -v python3 >/dev/null 2>&1; then
    SESSION_ROWS="$SESSION_ROWS" python3 - "$FINDINGS_DIR" <<'PY'
import glob, json, os, sys
findings_dir = sys.argv[1]
projects = {}
for row in os.environ.get("SESSION_ROWS", "").splitlines():
    parts = row.split("\t")
    if len(parts) >= 2 and parts[1]:
        projects[parts[0]] = parts[1]
fixed = 0
for path in sorted(glob.glob(os.path.join(findings_dir, "*.json"))):
    proj = projects.get(os.path.basename(path)[:-len(".json")])
    if not proj:
        continue
    try:
        with open(path) as f:
            data = json.load(f)
    except (ValueError, OSError):
        continue  # malformed JSON: leave for the triage-failures report section
    if not isinstance(data, dict):
        continue  # valid JSON that is not an object (`[]`, `null`): nothing to normalize
    if data.get("project") != proj:
        data["project"] = proj
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, path)
        fixed += 1
print(fixed)
PY
    # shellcheck disable=SC2181
    if [ $? -eq 0 ]; then
      log "normalized project field from session path"
    else
      log "WARNING: project-field normalization exited nonzero; some findings keep the project the L1 model wrote"
    fi
  else
    log "python3 not found; skipping project-field normalization (L2 grouping may show dupes)"
  fi

  # ---- Enforce the mechanical skill fields from the sidecars ----
  # Deliberately NOT inside the python3 block above. The prompt asks the worker to copy
  # these from the precomputed stats, but asking is not enforcing, and gating enforcement
  # on an optional interpreter meant that on a host without python3 the pipeline quietly
  # returned to believing whatever the model wrote — the exact failure this replaced.
  # jq is already a hard dependency of this script, so this cannot silently degrade.
  # compute_session_stats regenerates every sidecar each run, so a sidecar that is missing,
  # unreadable, or lacks any of the four skill keys means session-stats.sh did not measure
  # this session's skills, and whatever skill fields the findings JSON carries are the
  # worker's own guess. All four are removed and counted, never kept, or L2 ranks them as
  # mechanical counts (Codex reviews of 0129fc0, cd309b6 and 33bf9b1). Checking one key
  # was not enough: copying the keys that exist would leave the worker's guesses for the
  # rest. A sidecar with missing keys passes generation's type check and only breaks here.
  SKILLS_ENFORCED=0
  SKILLS_DROPPED=0
  # Rewrites that failed (full disk, unwritable dir): the worker's own skill fields survive in
  # those files, so the count has to be visible or L2 ranks guesses as measurements.
  SKILLS_FAILED=0
  for fjson in "$FINDINGS_DIR"/*.json; do
    case "$fjson" in *.stats.json) continue ;; esac
    [ -s "$fjson" ] || continue
    jq -s -e "$L1_FINDINGS_OK" "$fjson" >/dev/null 2>&1 || continue
    sidecar="${fjson%.json}.stats.json"
    skilltmp="$fjson.skills.tmp"
    if ! jq -e 'type == "object" and (["skills_invoked", "skills_invoked_count", "skills_invoked_counts", "skills_authored"] - keys | length == 0)' "$sidecar" >/dev/null 2>&1; then
      if jq 'del(.skills_invoked, .skills_invoked_count, .skills_invoked_counts, .skills_authored)' \
          "$fjson" > "$skilltmp" 2>/dev/null && [ -s "$skilltmp" ]; then
        mv "$skilltmp" "$fjson"
        SKILLS_DROPPED=$((SKILLS_DROPPED + 1))
      else
        rm -f "$skilltmp"
        SKILLS_FAILED=$((SKILLS_FAILED + 1))
      fi
      continue
    fi
    if jq --slurpfile sc "$sidecar" '
          . as $f
          | (($sc[0]) // {}) as $st
          | reduce ("skills_invoked", "skills_invoked_count", "skills_authored", "skills_invoked_counts") as $k
              ($f; if ($st | has($k)) then .[$k] = $st[$k] else . end)
        ' "$fjson" > "$skilltmp" 2>/dev/null && [ -s "$skilltmp" ]; then
      mv "$skilltmp" "$fjson"
      SKILLS_ENFORCED=$((SKILLS_ENFORCED + 1))
    else
      rm -f "$skilltmp"
      SKILLS_FAILED=$((SKILLS_FAILED + 1))
    fi
  done
  log "enforced mechanical skill fields from sidecars on $SKILLS_ENFORCED findings file(s); removed unmeasured skill fields from $SKILLS_DROPPED whose sidecar was missing, unreadable, or incomplete; $SKILLS_FAILED rewrite(s) failed"

  # ---- Self-audit stats: runtime telemetry only the runner can see ----
  # The aggregator can't observe its own machinery — which sessions were autodream's
  # own (already excluded), how many workers failed, how many retry rounds it took.
  # Surface it so PROMPT.md's "Autodream self-audit" section can flag regressions
  # (e.g. the self-pollution exclusion count climbing again) and propose source fixes.
  # Sessions enumerated by find but unaccounted for at run end — not pruned as
  # self/empty, not in findings. This is the gap the 2026-06-11 self-audit
  # caught: 12 .err files existed but stats showed l1_missing_after_retries=0
  # because both denominators counted from the POST-prune sessions.txt. By
  # computing against RAW and subtracting the legitimate prunes, any session
  # lost to a filter mis-classification or silent worker death surfaces here.
  # Bounded at 0 in case of a counting bug in the prunes.
  # Collision drops are deliberate, not failures, and have their own key.
  DROPPED_AFTER_FAILURES=$(( RAW - COLLIDED_DROPPED - L1_OK - EXCLUDED - SKIPPED_EMPTY ))
  [ "$DROPPED_AFTER_FAILURES" -lt 0 ] && DROPPED_AFTER_FAILURES=0
  L1_FRESHLY_PROCESSED=$(( L1_OK - L1_PRECACHED ))
  [ "$L1_FRESHLY_PROCESSED" -lt 0 ] && L1_FRESHLY_PROCESSED=0
  # How many directories we scanned for sessions (colon-count + 1). Kept as its own
  # stat so a regression to single-root scanning is visible from the artifact.
  SESSION_ROOT_COUNT=$(( $(printf '%s' "$SESSION_ROOTS" | tr -cd ':' | wc -c) + 1 ))
  {
    printf '# Autodream run self-audit — %s\n' "$TARGET_DATE"
    # Which code produced this file (#29). install.sh symlinks ~/.claude/autodream/*.sh
    # straight at the repo working tree, so the nightly executes whatever is checked out
    # at 03:15 — a tree sitting behind origin runs old code even though the fix is merged.
    # That has now cost real data twice: the 2026-07-24 overlap-stats.sh dangle, and a
    # tree stuck on a local commit from 2026-07-20 to 2026-07-24 that wrote four nights
    # of run-stats.txt with no oversized_*/gated/overlap_* keys at all. Absent keys are a
    # terrible signal — they read as "this stat did not apply" rather than "this runner
    # predates the stat", and telling those apart took a reflog dig both times. Stamping
    # the commit makes the runner's age legible from the artifact itself.
    printf 'runner_commit: %s\n' "$RUNNER_COMMIT"
    printf 'runner_dirty: %s\n' "$RUNNER_DIRTY"
    printf 'session_roots: %s\n' "$SESSION_ROOT_COUNT"
    printf 'session_roots_list: %s\n' "$SESSION_ROOTS"
    printf 'sessions_found_raw: %s\n' "$RAW"
    # Paths dropped at enumeration because a line-based sessions.txt cannot hold
    # them. Recorded rather than left implicit: a nonzero value here means a real
    # transcript exists that no report will ever mention, which is exactly the
    # kind of silent shortfall this file exists to make visible.
    printf 'sessions_rejected_path: %s\n' "$REJECTED_PATHS"
    # Files modified since the day began that hold no record inside it (a session still
    # being written on a later day, or one touched after its own day). They belong to
    # another day's report, and a count here is what keeps a night whose files all
    # fell outside the window from reading as a quiet one. session_window says whether
    # the timestamp window was in force at all: a stats file with it off, or without the
    # key, was placed by file mtime alone. sessions_windowed is how many of the triaged
    # sessions spill outside the day, whose stats and L1 read are cut to the day.
    printf 'sessions_out_of_window: %s\n' "$OUT_OF_WINDOW"
    printf 'session_window: %s\n' "$([ "$WINDOW_ON" = 1 ] && echo on || echo off)"
    printf 'sessions_windowed: %s\n' "${SESSIONS_WINDOWED:-0}"
    # Roots whose enumerator errored yet still returned paths. Nonzero means this
    # night's corpus may be short by an unknown amount — not a failure, but not a
    # clean read either, and the aggregator should not treat the totals as complete.
    printf 'roots_partially_enumerated: %s\n' "$PARTIAL_ROOTS"
    printf 'roots_unavailable: %s\n' "$ROOTS_UNAVAILABLE"
    printf 'roots_failed: %s\n' "$ROOTS_FAILED"
    # Which harnesses produced this night's corpus. A source that drops to zero
    # on a day the user worked in it is the signal that its ingest broke, and
    # that is invisible without a per-source count.
    printf 'adapters_enabled: %s\n' "$(printf '%s' "$ENABLED_ADAPTERS" | tr ' ' ',' | sed 's/,$//')"
    # Refusals that still left claude accepted are otherwise completely silent —
    # a third-party adapter failing containment, a mismatched manifest name, a
    # lost exec bit. Same silent-shortfall class as overlap_measured and
    # stats_sidecars_unparseable: the value is that a zero here means something.
    printf 'adapters_rejected: %s\n' "$(adapters_rejected 2>/dev/null)"
    printf 'sessions_by_source: %s\n' "$SESSIONS_BY_SOURCE"
    printf 'sessions_duplicate_path: %s\n' "$DUPLICATE_PATHS"
    printf 'sessions_hash_collision: %s\n' "$HASH_COLLISIONS"
    printf 'self_sessions_excluded: %s\n' "$EXCLUDED"
    printf 'sessions_skipped_empty: %s\n' "$SKIPPED_EMPTY"
    printf 'sessions_triaged: %s\n' "$COUNT"
    # Sessions within sessions_triaged that were skipped before any model call
    # (noise gate). Structurally cannot appear in l1_findings_with_error since
    # they never reached a model; the self-audit denominator for the
    # extraction-failure rate must subtract this out.
    printf 'gated: %s\n' "$GATED"
    # vs.-raw denominator: a session lost to ANY path (prune mis-classification,
    # silent worker death, slim leftovers) shows up here. Always >= 0; if
    # nonzero, the aggregator should investigate even when l1_missing=0.
    printf 'sessions_dropped_to_collision: %s\n' "$COLLIDED_DROPPED"
    printf 'sidecar_stale_rows: %s\n' "$SIDECAR_STALE_ROWS"
    printf 'sessions_dropped_after_failures: %s\n' "$DROPPED_AFTER_FAILURES"
    # LAST_ROUND_RUN, not $round: the loop variable is assigned before a round dispatches, so a
    # loop that stopped before dispatching would still read as having used that round.
    printf 'l1_rounds_used: %s\n' "$LAST_ROUND_RUN"
    printf 'l1_rounds_max: %s\n' "$L1_ROUNDS"
    printf 'l1_timeout_bin: %s\n' "${TIMEOUT_BIN:-none}"
    printf 'l1_timeout_seconds: %s\n' "$AUTODREAM_L1_TIMEOUT"
    printf 'l1_timed_out: %s\n' "$(sort -u "$FINDINGS_DIR/l1-timeouts.txt" 2>/dev/null | grep -c . || true)"
    # How the auth warmup went: ok, failed, skipped (disabled) or skipped_no_timeout. A failed
    # warmup that precedes a night of empty stubs is the diagnosis; an ok one rules it out.
    printf 'l1_warmup: %s\n' "${L1_WARMUP:-not_reached}"
    # Which model each adapter's workers ran, so a report that reads differently can be traced to
    # the engine that produced it. One key per source that had sessions tonight.
    while IFS=$'\t' read -r _msrc _mval; do
      [ -n "$_msrc" ] || continue
      printf 'l1_model_%s: %s\n' "$(printf '%s' "$_msrc" | tr '-' '_')" "${_mval:-none}"
    done <<< "$AUTODREAM_L1_MODELS"
    # And on which adapter's engine, which AUTODREAM_L1_ENGINE_<NAME> can move off the source.
    while IFS=$'\t' read -r _msrc _mval; do
      [ -n "$_msrc" ] || continue
      printf 'l1_engine_%s: %s\n' "$(printf '%s' "$_msrc" | tr '-' '_')" "${_mval:-none}"
    done <<< "${AUTODREAM_L1_ENGINES:-}"
    # Who each engine the run used ran as (engine_login_ok), and which models answered the L1 calls
    # recorded for this date in l1-served.tsv, so a report traces to the login and model behind it.
    # The cost is the engine's own estimate at API prices, not what a subscription bills.
    while IFS=$'\t' read -r _msrc _pprov _pauth _pplan _pacct; do
      [ -n "$_msrc" ] || continue
      printf 'login_%s: provider=%s auth=%s plan=%s account=%s\n' "$(printf '%s' "$_msrc" | tr '-' '_')" "$_pprov" "$_pauth" "$_pplan" "$_pacct"
    done <<< "${ENGINE_LOGINS:-}"
    # Mismatch is the adapter verdict (column 6), the same one AUTODREAM_L1_REQUIRE_SERVED acts on.
    # A call the engine reported no model for (omp has no served verb), or a row written before the
    # verdict existed, is unmeasured: counted on its own line, never as a match or a mismatch.
    if [ -s "$FINDINGS_DIR/l1-served.tsv" ]; then
      printf 'l1_served_models: %s\n' "$(cut -f4 "$FINDINGS_DIR/l1-served.tsv" | sort | uniq -c | awk '{ printf "%s%s=%s", (NR > 1 ? " " : ""), $2, $1 }')"
      printf 'l1_served_mismatch: %s\n' "$(awk -F'\t' '$6 == "mismatch"' "$FINDINGS_DIR/l1-served.tsv" | wc -l | tr -d ' ')"
      printf 'l1_served_unmeasured: %s\n' "$(awk -F'\t' '$6 != "match" && $6 != "mismatch"' "$FINDINGS_DIR/l1-served.tsv" | wc -l | tr -d ' ')"
      printf 'l1_cost_usd_estimate: %s\n' "$(awk -F'\t' '$5 != "" { s += $5 } END { printf "%.4f", s }' "$FINDINGS_DIR/l1-served.tsv")"
      # The calls the sum above leaves out because their engine reported no cost (omp, or a claude
      # call with no result object), so an all-omp night reads 0.0000 beside a count, not alone.
      printf 'l1_cost_unmeasured: %s\n' "$(awk -F'\t' '$5 == ""' "$FINDINGS_DIR/l1-served.tsv" | wc -l | tr -d ' ')"
    else
      printf 'l1_served_models: none\nl1_served_mismatch: 0\nl1_served_unmeasured: 0\nl1_cost_usd_estimate: 0.0000\nl1_cost_unmeasured: 0\n'
    fi
    # yes when the circuit breaker cut the retry budget, so a short l1_rounds_used is not
    # mistaken for a run that finished early and cleanly.
    printf 'l1_breaker_fired: %s\n' "${L1_BREAKER:-not_reached}"
    # What chunked triage cost. l1_chunk_bytes is the setting in force (0 = off, including when the
    # helpers were not found); the rest are 0 on a night nothing was over the limit. l1_chunks is the
    # chunk workers the oversized sessions needed, l1_chunk_calls the engine calls actually made
    # (retries add, a reused answer makes none), and l1_chunks_elided how many chunks the cap
    # dropped from the middle of a session: a nonzero value is a degraded read, named here so it
    # cannot pass as a complete one.
    printf 'l1_chunk_bytes: %s\n' "$([ "$L1_CHUNKING" = 1 ] && echo "$AUTODREAM_L1_CHUNK_BYTES" || echo 0)"
    printf 'l1_max_chunks: %s\n' "$AUTODREAM_L1_MAX_CHUNKS"
    printf 'l1_chunked_sessions: %s\n' "${L1_CHUNKED_SESSIONS:-0}"
    printf 'l1_chunks: %s\n' "${L1_CHUNKS:-0}"
    printf 'l1_chunk_calls: %s\n' "${L1_CHUNK_CALLS:-0}"
    printf 'l1_chunks_elided: %s\n' "${L1_CHUNKS_ELIDED:-0}"
    printf 'l1_findings_written: %s\n' "$L1_OK"
    printf 'l1_findings_with_error: %s\n' "$L1_ERRORED"
    # Why those stubs exist, by class. A silent worker death (exit 0, empty stdout), a provider
    # refusal and an unclassifiable failure are not evidence that a transcript was too large, so
    # the size-attributable failure rate removes all three: (errors - silent - provider -
    # unclassified) / (triaged - gated).
    printf 'l1_errored_silent: %s\n' "$L1_ERRORED_SILENT"
    printf 'l1_errored_provider: %s\n' "$L1_ERRORED_PROVIDER"
    printf 'l1_errored_unclassified: %s\n' "$L1_ERRORED_UNCLASSIFIED"
    # Oversized-transcript measurement gate (#12) — see the computation above L1_ERRORED
    # for the gate meaning (M/N >= 5% over a trailing week opens issue #12).
    printf 'oversized_total: %s\n' "$OVERSIZED_TOTAL"
    printf 'oversized_errored: %s\n' "$OVERSIZED_ERRORED"
    printf 'oversized_errored_silent: %s\n' "$OVERSIZED_ERRORED_SILENT"
    printf 'oversized_errored_provider: %s\n' "$OVERSIZED_ERRORED_PROVIDER"
    printf 'oversized_errored_unclassified: %s\n' "$OVERSIZED_ERRORED_UNCLASSIFIED"
    printf 'oversized_unmeasurable: %s\n' "${OVERSIZED_UNMEASURABLE:-0}"
    # Sidecar health (#27): how many of sessions_triaged had a stats sidecar that was
    # missing, empty, or carried no numeric transcript_bytes. Every consumer of the
    # sidecars degrades when this is non-zero — `gated` under-counts (an unreadable
    # sidecar never gates, by design) and the oversized sizes came from a live read
    # rather than the sidecar — so it caveats those two keys rather than duplicating
    # a flag onto each of them.
    printf 'stats_sidecars_unparseable: %s\n' "$STATS_SIDECARS_UNPARSEABLE"
    printf 'l1_missing_after_retries: %s\n' "$MISSING"
    printf 'l1_err_files: %s\n' "$L1_FAIL"
    # Of those, the ones with no findings JSON and no session in tonight's worklist: failed
    # triage that nothing will retry. Nonzero is a stale failure, not tonight's.
    printf 'l1_err_files_orphaned: %s\n' "$L1_ERR_ORPHANED"
    # Findings JSONs in the directory that no session in tonight's worklist owns. L2 reads them
    # all, so a nonzero value means the report includes sessions this run did not place in the day.
    printf 'l1_findings_outside_worklist: %s\n' "$FINDINGS_OUTSIDE_WORKLIST"
    # Cached vs. fresh: lets the aggregator distinguish a sub-second "elapsed"
    # caused by everything already being done from a broken timer.
    printf 'l1_sessions_already_done_at_start: %s\n' "$L1_PRECACHED"
    # Cached results this run would not reuse (drop_unacceptable_l1_cache), triaged again instead.
    printf 'l1_cache_dropped: %s\n' "$L1_CACHE_DROPPED"
    printf 'l1_sessions_freshly_processed: %s\n' "$L1_FRESHLY_PROCESSED"
    printf 'l1_elapsed_seconds: %s\n' "$L1_ELAPSED"
    # Global cross-session overlap stat (#14) — see compute_overlap_stats above.
    # overlap_measured (#26) disambiguates a genuine zero-overlap night from the
    # script not running/producing usable output; the two count keys are always
    # emitted (0 when unmeasured) so existing consumers never hit a missing key.
    printf 'overlap_measured: %s\n' "$([ "$OVERLAP_MEASURED" = "1" ] && echo yes || echo no)"
    printf 'overlap_events: %s\n' "$OVERLAP_EVENTS"
    printf 'sessions_with_overlap: %s\n' "$SESSIONS_WITH_OVERLAP"
    # The Activity snapshot's session total split into top-level sessions and nested workers
    # (#79). Both count ungated sessions, the same set as the report's N; fanouts.tsv names
    # each worker and its parent.
    printf 'sessions_top_level: %s\n' "$FANOUT_TOP"
    printf 'sessions_nested: %s\n' "$FANOUT_NESTED"
    printf 'fanout_parents: %s\n' "$FANOUT_PARENTS"
    printf 'largest_fanout: %s\n' "$FANOUT_LARGEST"
    printf 'skills_unmeasured: %s\n' "${SKILLS_DROPPED:-0}"
    printf 'skills_enforcement_failed: %s\n' "${SKILLS_FAILED:-0}"
    # Other dates that were triaged and never assembled (#36). Empty means none in the
    # window, which is the reading that matters — this is the key that gets a killed run
    # noticed the next morning instead of during an unrelated investigation two days on.
    printf 'unassembled_dates: %s\n' "${UNASSEMBLED:-}"
    # Always emitted, even empty: a reader should never have to tell "no legacy reports"
    # apart from "this runner predates the key", which is the same ambiguity the epoch
    # exists to resolve.
    printf 'legacy_marker_reports: %s\n' "${LEGACY_MARKER:-}"
    # Network health, L1 side. run-stats.txt is closed before L2 runs, so the L2 side is
    # appended after the aggregator loop as network_down_seconds_l2 / network_deferred_l2.
    printf 'network_down_seconds: %s\n' "$NET_DOWN_SECONDS"
    printf 'network_deferred: %s\n' "$NET_DEFERRED"
    # network_down_seconds is time the runner spent blocked BETWEEN rounds; the per-worker
    # ledger is one curl at the instant a worker failed. A flapping network makes the first
    # large and the second false for every worker, which is not a contradiction.
    if [ "$NET_DOWN_SECONDS" -gt 0 ] \
       && ! awk '$3 == "true" { found = 1 } END { exit !found }' \
              "$FINDINGS_DIR/l1-netdown.txt" 2>/dev/null; then
      printf 'network_flapped: yes\n'
    else
      printf 'network_flapped: no\n'
    fi
  } > "$FINDINGS_DIR/run-stats.txt"

  # Baseline for the L2-scoped network keys appended after the aggregator loop.
  NET_DOWN_SECONDS_PRE_L2="$NET_DOWN_SECONDS"

  # ---- Defer the date when the network never came back or the provider refused ----
  # Stop above L2 rather than aggregating a corpus known to be short. Findings written so far
  # stay on disk and the worker is idempotent, so a later catch-up trigger picks up exactly
  # the sessions still missing. Writing no report is what makes that happen: the idempotency
  # guard keys on the report existing, and unassembled_dates() names this date until one does.
  # Keep the test narrow: only a round that could not run, or whose last round failed outright,
  # defers, never a slow or partial one.
  if [ "$NET_DEFERRED" = "yes" ]; then
    log "deferring $TARGET_DATE: L2 would summarize $((COUNT - MISSING)) of $COUNT sessions"
    log "a later run will retry the $MISSING session(s) still missing; findings so far are kept"
    # PROMPT.md reads all four network keys; this return jumps over the post-L2 append, and an
    # absent key cannot be told from an older runner. L2 did not run: zero waits, no deferral.
    printf 'network_down_seconds_l2: 0\n' >> "$FINDINGS_DIR/run-stats.txt"
    printf 'network_deferred_l2: no\n' >> "$FINDINGS_DIR/run-stats.txt"
    clean_work_bucket
    return 1
  fi

  # ---- Upstream changelog window (writes changelog-window.md for L2 to read) ----
  changelog_window

  # ---- Operator notes (writes operator-notes.md for L2 to read) ----
  # Merges every capture surface — the terminal-written notes.md and the vault inbox —
  # into one file so PROMPT.md reads a single path. Adding a surface is a change to
  # vault-notes.sh, never to the prompt. Best-effort: a broken vault must not cost the
  # report, so failure here logs and continues.
  if [ -x "$VAULT_NOTES" ]; then
    "$VAULT_NOTES" collect "$FINDINGS_DIR" || log "operator-note collection failed (continuing)"
  else
    log "vault-notes.sh not found at $VAULT_NOTES; skipping operator-note collection"
  fi

  # ---- X bookmarks (writes x-bookmarks.md for L2 to read) ----
  # Unread bookmarks become idea fuel: L2 cross-references what the user saved against
  # what they actually worked on. The script always exits 0 and always writes the file,
  # including a "not configured" stub, so this seam has exactly one shape for L2.
  if [ -x "$XBOOKMARKS" ]; then
    "$XBOOKMARKS" collect "$FINDINGS_DIR" || log "x-bookmark collection failed (continuing)"
  else
    log "x-bookmarks.sh not found at $XBOOKMARKS; skipping bookmark collection"
  fi

  # ---- Was the queryId scraping walk actually exercised tonight? (#38) ----
  # The walk against X's JS bundle is the one part of the fetcher with no test, and the
  # part most likely to break, since it turns on X's bundle layout rather than on anything
  # here. A cached id produces a working fetch without proving the walk still works, so
  # `cache` and `fresh` have to be told apart or a walk that stopped working stays hidden
  # until the cache expires. Appended rather than written above because the collector that
  # knows the answer runs after run-stats.txt is closed; the key is always emitted so a
  # consumer never has to handle it being absent.
  XQID_SOURCE=not_attempted
  if [ -s "$FINDINGS_DIR/x-bookmarks-queryid.txt" ]; then
    XQID_SOURCE=$(tr -d '[:space:]' < "$FINDINGS_DIR/x-bookmarks-queryid.txt")
    [ -n "$XQID_SOURCE" ] || XQID_SOURCE=not_attempted
  fi
  printf 'x_queryid_source: %s\n' "$XQID_SOURCE" >> "$FINDINGS_DIR/run-stats.txt"

  # ---- Finished worktrees and branches ----
  # Removes worktrees and local/remote branches whose PR merged (see prune-worktrees.sh for
  # the full proof rules). Opt-in via AUTODREAM_PRUNE_ROOTS. It needs nothing from L1 or L2
  # and L2 does not read its output, so a failure here logs and the report is unaffected.
  # The artifact lands in the findings dir: worktree-prune.md (read it) and .tsv (grep it).
  PRUNE_SUMMARY="prune: not configured"
  if [ -z "${AUTODREAM_PRUNE_ROOTS:-}" ]; then
    :
  elif [ -x "$PRUNE_WORKTREES" ]; then
    PRUNE_SUMMARY=$("$PRUNE_WORKTREES" "$FINDINGS_DIR" 2>>"$RUN_LOG" | tail -1) || PRUNE_SUMMARY="prune: failed"
    [ -n "$PRUNE_SUMMARY" ] || PRUNE_SUMMARY="prune: failed"
    log "$PRUNE_SUMMARY (details: $FINDINGS_DIR/worktree-prune.md)"
  else
    log "prune-worktrees.sh not found at $PRUNE_WORKTREES; skipping worktree prune"
    PRUNE_SUMMARY="prune: helper missing"
  fi
  printf 'worktree_prune: %s\n' "$PRUNE_SUMMARY" >> "$FINDINGS_DIR/run-stats.txt"

  # ---- Repos worth triaging ----
  # Counts untriaged open issues in the repos tonight's sessions ran in and writes
  # triage-candidates.md for L2 to copy into the report (L2 has no shell or gh, so the runner
  # does the counting). SESSION_ROWS was built before any model ran, so it is the runner's own
  # list of working directories and not something a model could have rewritten. A failure here
  # logs and the report is unaffected.
  TRIAGE_SUMMARY="triage: off"
  # A rerun must not leave the earlier run's list for L2 to copy.
  rm -f "$FINDINGS_DIR/triage-candidates.md" "$FINDINGS_DIR/triage-candidates.tsv" 2>/dev/null
  if [ "${AUTODREAM_TRIAGE_SUGGEST:-1}" = 0 ]; then
    :
  elif [ -x "$TRIAGE_CANDIDATES" ]; then
    TRIAGE_SUMMARY=$(printf '%s\n' "$SESSION_ROWS" | "$TRIAGE_CANDIDATES" "$FINDINGS_DIR" 2>>"$RUN_LOG" | tail -1) || TRIAGE_SUMMARY="triage: failed"
    [ -n "$TRIAGE_SUMMARY" ] || TRIAGE_SUMMARY="triage: failed"
    log "$TRIAGE_SUMMARY (details: $FINDINGS_DIR/triage-candidates.md)"
  else
    log "triage-candidates.sh not found at $TRIAGE_CANDIDATES; skipping the triage list"
    TRIAGE_SUMMARY="triage: helper missing"
  fi
  printf 'triage_candidates: %s\n' "$TRIAGE_SUMMARY" >> "$FINDINGS_DIR/run-stats.txt"

  # ---- Skills inventory and per-source facts (written for L2 to read) ----
  write_adapter_inputs

  # ---- Layer 2: opus aggregate, retried until a report lands ----
  # The aggregator call can also die to a mid-run sleep (this is what left exit 1 +
  # "no report" overnight). Retry until $REPORT_PATH is non-empty, waiting for the
  # network between attempts. Idempotent: a re-run overwrites the report harmlessly.
  # NO --model BY DEFAULT. The aggregator runs on whatever the CLI's default is,
  # so upgrading the account upgrades the nightly report and nothing here has to
  # be edited.
  #
  # No model is pinned here: a pin is a decision to re-make every time the roster
  # moves, and a date-gated branch hid that and left an unreachable default.
  #
  # AUTODREAM_L2_MODEL overrides, for pinning a specific model deliberately.
  # If you set it, pin an EXACT string: the CLI silently falls back on an
  # unrecognized --model rather than failing (verified 2026-06-09 on 2.1.170;
  # bare "claude-fable-5" was one of those, where "fable" and the [1m]-suffixed
  # form both worked). A silent fallback is why the value is recorded below.
  #
  # The engine that runs L2 is an adapter, chosen by AUTODREAM_L2_ENGINE and by default the
  # first enabled adapter. It prints its own argv (adapters/<name>/adapter.sh l2-argv), so this
  # file names no binary. The model resolves per adapter (AUTODREAM_L2_MODEL_<NAME>, then
  # AUTODREAM_L2_MODEL, then the manifest); none at all is legitimate and means the engine's own
  # default. A model id belongs to one engine, which is why the per-adapter form exists.
  #
  # bash 3.2 with set -u treats "${a[@]}" on an EMPTY array as an unbound variable, so every
  # expansion of the argv and env arrays below is guarded.
  L2_ENGINE=$(review_engine)
  L2_MODEL=$(adapter_l2_model "$L2_ENGINE" 2>/dev/null) || L2_MODEL=""
  log "L2 engine: $L2_ENGINE, model: ${L2_MODEL:-<engine default>}"
  # Recorded because neither is fixed by this file. When a report's character changes, the first
  # question is what produced it, and the answer has to survive in the artifact rather than only
  # in a log nobody reads. `default` is the honest value when no model was named: the engine
  # picks, and this script is not told what it picked. Absent on a zero-session night, which is
  # correct: that path returns before L2 runs at all.
  printf 'l2_engine: %s\n' "$L2_ENGINE" >> "$FINDINGS_DIR/run-stats.txt"
  printf 'l2_model: %s\n' "${L2_MODEL:-default}" >> "$FINDINGS_DIR/run-stats.txt"
  L2_ARGV=()
  while IFS= read -r -d "" _a; do L2_ARGV+=("$_a"); done < <(adapter_run "$L2_ENGINE" l2-argv ${L2_MODEL:+"$L2_MODEL"} 2>/dev/null)
  L2_ENVS=()
  while IFS= read -r _l; do [ -n "$_l" ] && L2_ENVS+=("$_l"); done < <(adapter_run "$L2_ENGINE" l1-env 2>/dev/null)
  unset _a _l
  if [ "${#L2_ARGV[@]}" -eq 0 ] && [ "$L2_ENGINE" = "claude" ]; then
    # An install whose adapters/ tree predates l2-argv (the per-file symlink installs this script
    # supports, see enumerate_for) still has to deliver the night. The fallback is claude-only,
    # for the same reason enumerate_for's is: it hardcodes one engine's invocation.
    log "  the claude adapter printed no L2 command here (an adapters/ tree that predates l2-argv); using the built-in claude invocation"
    # The system prompt is prompts/L2_SYSTEM.txt, the same text the adapters read. Without it no
    # argv is built at all (the warning below fires), because an L2 run with no word on where the
    # report goes only looks like a night's work.
    # shellcheck source=/dev/null
    L2_SYS=$(_l=$(find_lib l2-prompt.sh) && . "$_l" && l2_system_prompt) || L2_SYS=""
    if [ -n "$L2_SYS" ]; then
      L2_ARGV=("$CLAUDE_BIN" --print --permission-mode bypassPermissions ${L2_MODEL:+--model "$L2_MODEL"} \
        --no-session-persistence --tools Glob Read --disable-slash-commands --strict-mcp-config \
        --settings '{"disableAllHooks":true}' \
        --append-system-prompt "$L2_SYS")
    else
      log "WARNING: the built-in claude invocation needs prompts/L2_SYSTEM.txt through bin/l2-prompt.sh, and neither could be read"
    fi
  fi
  if [ "${#L2_ARGV[@]}" -eq 0 ]; then
    log "WARNING: the $L2_ENGINE adapter produced no L2 command; every L2 attempt will fail"
    # An empty argv would run a bare `env`, which prints the environment into the report capture.
    L2_ARGV=(false)
  fi

  # ---- Move a stale report aside before attempting L2 ----
  # The only way to reach this line with $REPORT_PATH already non-empty is
  # AUTODREAM_FORCE=1 (the idempotency guard above returns early otherwise): a previous
  # run of this same TARGET_DATE left a report on disk and we're rebuilding. Nothing
  # below distinguishes "this run wrote it" from "it was already there" — the retry
  # loop's `[ -s "$REPORT_PATH" ] && break` and the consume gate further down both just
  # stat the path. Left in place, an old report satisfies BOTH: the retry loop stops
  # after attempt 1 even though this run's L2 never wrote anything, and the consume
  # gate then archives the vault note / marks bookmarks read as if something had
  # actually read them. That's the exact overnight failure mode this script is built
  # around (Mac sleeps mid-run, every L2 attempt fails) turning into silent,
  # unrecoverable data loss for the user's notes and bookmarks. Move the old file aside
  # first so `-s "$REPORT_PATH"` again means "this run produced it" for both checks.
  # Moved aside, not deleted: if every L2 attempt below still fails, the user's last
  # good report for this date must stay recoverable, not vanish.
  # CONSUME_SAFE is the whole point of this block, not a side effect of it. If the move
  # fails we are back in precisely the state the move exists to prevent: an old report
  # sitting at $REPORT_PATH that a failed L2 will let the retry loop and the consume gate
  # both mistake for this run's output. Continuing anyway would archive unread notes and
  # stamp bookmarks read against a report nothing produced — the silent, unrecoverable
  # loss this is all guarding. So a failed move disarms consuming for the run rather than
  # logging a warning and carrying on.
  CONSUME_SAFE=1
  PINS_SAFE=1
  if [ -s "$REPORT_PATH" ]; then
    STALE_REPORT="$REPORT_PATH.stale-$(date +%s)"
    if mv "$REPORT_PATH" "$STALE_REPORT"; then
      log "existing report for $TARGET_DATE moved aside to $STALE_REPORT before rebuilding"
    else
      log "WARNING: could not move the existing report aside; this run will NOT archive notes or mark bookmarks read, because a stale report can no longer be told apart from a fresh one"
      STALE_REPORT=""
      CONSUME_SAFE=0
    fi
  fi

  L2_ATTEMPTS="${AUTODREAM_L2_ATTEMPTS:-3}"
  # Delivery gate across attempts. L2_ATTEMPTED separates a fresh run that actually spawned the
  # aggregator from the legacy short-circuits above (the idempotency guard and the COUNT=0 stub
  # both return before L2); L2_DELIVERED flips to 1 only when an attempt's capture carried the
  # AUTODREAM_REPORT_END sentinel. Both default to 0 so the move-aside below can tell "this run
  # confirmed delivery" from "this run never reached L2": a marker-bearing report left by an
  # earlier night must not be read as this run's output.
  L2_ATTEMPTED=0
  L2_DELIVERED=0
  L2_START=$(date +%s)
  L2_STDOUT="$FINDINGS_DIR/report.stdout"   # L2 holds no Write tool: the report arrives on stdout
  L2_RC=1
  for attempt in $(seq 1 "$L2_ATTEMPTS"); do
    L2_ATTEMPTED=1
    log "L2 aggregation attempt $attempt/$L2_ATTEMPTS..."
    # A pins.jsonl already here came from an earlier run or an earlier attempt, and no
    # complete report from THIS attempt stands behind it. Move it aside before every
    # attempt, or a dead attempt's pins get stored alongside the next attempt's report.
    # Moved, not deleted, so a pin that never reached Mnemopi stays readable. A failed
    # move clears PINS_SAFE for the run, for the same reason CONSUME_SAFE works that way.
    if [ -e "$FINDINGS_DIR/pins.jsonl" ]; then
      # mktemp, not a timestamp: two forced rebuilds inside one second would otherwise pick
      # the same name, and the second move would overwrite the first run's unapplied pins.
      if STALE_PINS=$(mktemp "$FINDINGS_DIR/pins.jsonl.stale-XXXXXX") \
         && mv -f "$FINDINGS_DIR/pins.jsonl" "$STALE_PINS"; then
        log "moved an earlier pins.jsonl aside before this attempt"
      else
        log "WARNING: could not move an earlier pins.jsonl aside; this run will not store memory pins"
        PINS_SAFE=0
        # The empty mktemp placeholder is litter once the move fails, one per attempt.
        if [ -n "${STALE_PINS:-}" ] && [ -f "$STALE_PINS" ] && [ ! -s "$STALE_PINS" ]; then
          rm -f "$STALE_PINS"
        fi
      fi
    fi
    # Same literal-path framing and brace-group assembly as L1 (see the L1 worker comment): keep
    # the paths as literal data the aggregator reads with Glob/Read, and preserve the blank-line
    # separator before PROMPT.md instead of letting a `prompt=$(...)` capture strip it and glue
    # the doc onto the report-path line. Subshell so the cwd change (isolating the AI-title stub
    # into $WORK_BUCKET, same as L1) is scoped to this call. $? after the subshell is the
    # pipeline's exit (claude's).
    #
    # L2 holds Glob and Read only. It cannot write the report, pins, or anything else under the
    # findings directory, so the one hostile-input surface that used to need a quarantine (an L2
    # that rewrote sessions-source.txt or forged a pin) is closed at the tool grant, and the
    # runner is the only writer of $REPORT_PATH and pins.jsonl.
    #
    # The engine starts through a one-line sh that records its own pid and then execs, so the
    # pid in the diagnostics is the engine's (issue 42). exec keeps the pid, stdin and argv.
    L2_PIDFILE=$(mktemp "${TMPDIR:-/tmp}/l2pid.XXXXXX" 2>/dev/null) || L2_PIDFILE=/dev/null
    l2_diag_start 2>/dev/null || true
    (
      cd "$WORK_DIR" 2>/dev/null || true
      {
        printf "Findings directory to aggregate (literal absolute path): %s\n" "$FINDINGS_DIR"
        printf "Report destination (literal absolute path): %s\n\n" "$REPORT_PATH"
        cat "$AUTODREAM_DIR/PROMPT.md"
      } | env ${L2_ENVS[@]+"${L2_ENVS[@]}"} /bin/sh -c 'printf %s "$$" > "$0" 2>/dev/null; exec "$@"' "$L2_PIDFILE" ${L2_ARGV[@]+"${L2_ARGV[@]}"}
    ) > "$L2_STDOUT"

    L2_RC=$?
    l2_diag_end "$attempt" "$L2_ATTEMPTS" "$L2_RC" "$L2_PIDFILE" 2>/dev/null || true
    [ "$L2_PIDFILE" = /dev/null ] || rm -f "$L2_PIDFILE"
    # ---- The runner writes the report from L2's stdout ----
    # The AUTODREAM_REPORT_END sentinel is the completion gate: everything before the LAST
    # occurrence is the report body, and a capture without one is a degraded report whether or
    # not it carries the open-questions marker, because the marker alone cannot prove the output
    # reached the end. Both writes are staged to a .tmp and renamed so a half-staged file never
    # lands at $REPORT_PATH. Lines after the sentinel (the pin block, the report path, the
    # summary) are appended to the run log so a stripped capture never loses them.
    L2_SENTINEL=0
    report_has_sentinel "$L2_STDOUT" && L2_SENTINEL=1
    # ---- Pins: the block after the sentinel becomes pins.jsonl, written by the runner ----
    # Only a delivered report carries pins, and only the block that follows the LAST sentinel
    # counts, so a report that quotes the markers in its body cannot inject one. The block needs
    # its END line: a capture cut off inside it proposes nothing, rather than half a pin. Only
    # lines that open a JSON object are kept; apply-pins.sh validates each one against the
    # authorization list that was fixed before any model ran.
    #
    # Written BEFORE the report is staged. A report that stands complete on disk then always has
    # its pins.jsonl and pin-projects.tsv beside it, so a kill after the report lands cannot
    # leave a complete report whose pins were never proposed (issue 72); a kill before it leaves
    # no complete report, and the rerun moves these aside and asks L2 again.
    if [ "$L2_SENTINEL" = "1" ] && [ "$PINS_SAFE" = "1" ]; then
      if report_pin_lines "$L2_STDOUT" > "$FINDINGS_DIR/pins.jsonl.tmp" \
         && [ -s "$FINDINGS_DIR/pins.jsonl.tmp" ] && mv -f "$FINDINGS_DIR/pins.jsonl.tmp" "$FINDINGS_DIR/pins.jsonl"; then
        log "wrote $(wc -l < "$FINDINGS_DIR/pins.jsonl" | tr -d ' ') proposed pin(s) from the L2 pin block"
        # The authorization list goes to disk with the pins, so a later run can still apply them
        # if this one dies before the pin step (see sweep_stranded_pins).
        write_pin_projects "$FINDINGS_DIR" || log "WARNING: could not write pin-projects.tsv; these pins wait for a later run that can"
      else
        rm -f "$FINDINGS_DIR/pins.jsonl.tmp"
      fi
    fi
    L2_COMPLETE=0
    if report_has_sentinel "$L2_STDOUT"; then
      if report_body "$L2_STDOUT" > "$REPORT_PATH.tmp" && mv "$REPORT_PATH.tmp" "$REPORT_PATH"; then
        L2_COMPLETE=1
      else
        log "WARNING: could not stage the sentinel-stripped report at $REPORT_PATH"
      fi
    elif [ -s "$L2_STDOUT" ]; then
      log "WARNING: L2 stdout carried no AUTODREAM_REPORT_END sentinel; keeping the whole capture as a degraded report (incomplete, will retry)"
      cat "$L2_STDOUT" > "$REPORT_PATH.tmp" && mv "$REPORT_PATH.tmp" "$REPORT_PATH" 2>/dev/null || true
    fi
    report_after_sentinel "$L2_STDOUT" >> "$RUN_LOG" 2>/dev/null || true
    L2_DELIVERED=$L2_COMPLETE
    # Break only on a sentinel-validated capture that also carries the open-questions marker;
    # a degraded capture (sentinel absent) never satisfies the loop.
    if [ "$L2_DELIVERED" = "1" ] && report_complete; then
      break
    fi
    if [ -s "$REPORT_PATH" ]; then
      if report_complete; then
        log "L2 attempt $attempt wrote a complete-looking report but no AUTODREAM_REPORT_END sentinel; not a validated delivery, retrying (exit $L2_RC)"
      else
        log "L2 attempt $attempt left a report with no open-questions marker; treating it as truncated and retrying (exit $L2_RC)"
      fi
    else
      log "L2 attempt $attempt wrote no report (exit $L2_RC)"
    fi
    if [ "$attempt" -lt "$L2_ATTEMPTS" ]; then
      # Spending the remaining attempts against a host with no route produces nothing but a
      # later exit, so stop and record the deferral.
      if ! wait_for_network "$(l2_probe_url)"; then
        NET_DEFERRED=yes
        log "L2 retry not attempted: no route to the API — deferring $TARGET_DATE for a later run"
        break
      fi
      sleep "${AUTODREAM_RETRY_WAIT:-60}"
    fi
  done
  clean_work_bucket  # all workers have exited; remove their AI-title stubs

  # L2-scoped network health, appended because the block above was closed before L2 ran.
  # Classify the LAST attempt too: the probe in the retry loop only runs between attempts, so a
  # route that dropped before the final attempt was never seen and the run would record
  # network_deferred_l2: no. Only probe when L2 failed; a delivered report needs no explanation.
  if [ "${AUTODREAM_NETCHECK:-1}" != "0" ] && [ "$L2_DELIVERED" != "1" ] && ! net_up "$(l2_probe_url)"; then
    NET_DEFERRED=yes
    log "L2 produced no report and the API is unreachable; recording this as a network deferral"
  fi
  printf 'network_down_seconds_l2: %s\n' "$(( NET_DOWN_SECONDS - NET_DOWN_SECONDS_PRE_L2 ))" >> "$FINDINGS_DIR/run-stats.txt"
  printf 'network_deferred_l2: %s\n' "$NET_DEFERRED" >> "$FINDINGS_DIR/run-stats.txt"

  L2_ELAPSED=$(( $(date +%s) - L2_START ))
  log "L2 done in ${L2_ELAPSED}s (exit $L2_RC, $attempt attempt(s))"

  # ---- A truncated report must not become the permanent one ----
  # Every attempt can leave a marker-less file behind (killed mid-write, each time), and
  # nothing below removes it. The idempotency guard at the top of run() tests `-s` alone,
  # so the very next launchd catch-up trigger would see a non-empty report, log "nothing
  # to do", and return — the multi-trigger retry design silently disarmed by the file it
  # exists to replace, with a half-written report standing as the day's output forever.
  # That is the same "non-empty is not complete" error as the other three consumers, at a
  # fourth site, and it is the one that makes the mistake permanent rather than one-night.
  #
  # Move it aside rather than delete it: it may hold most of a report, and a partial
  # report is worth reading even though it must not block a retry. The stub written when
  # COUNT=0 returns long before this line, so it is never affected.
  if [ -f "$REPORT_PATH" ] && [ "$L2_ATTEMPTED" = "1" ] && { [ "$L2_DELIVERED" != "1" ] || ! report_complete; }; then
    PARTIAL_REPORT="$REPORT_PATH.partial-$(date +%s)"
    if mv "$REPORT_PATH" "$PARTIAL_REPORT"; then
      log "WARNING: every L2 attempt left an incomplete report; moved it to $PARTIAL_REPORT so a later trigger retries this date"
    else
      log "WARNING: an incomplete report is at $REPORT_PATH and could not be moved aside; later triggers will treat this date as done"
    fi
  fi

  # ---- Retire the copies this date no longer needs, and name the ones it keeps ----
  # This has to sit outside the `-f "$REPORT_PATH"` test below. A successful partial move
  # leaves that path gone, so the stale copy went unmentioned in the one outcome where the
  # user most needs to be told where their last good report went.
  #
  # The moved-aside copy was insurance against this rebuild producing nothing. A complete
  # report means the insurance has expired, and dropping it is what stops every --force
  # rebuild from leaving another .stale-<epoch> file in the dreams dir forever. Only a
  # COMPLETE report supersedes the old one; a truncated file is not a rebuild.
  if [ -n "${STALE_REPORT:-}" ] && [ -s "$STALE_REPORT" ]; then
    if report_complete; then
      rm -f "$STALE_REPORT" && log "rebuild succeeded; discarded the superseded report copy"
    else
      log "this run produced no complete report; the previous one for $TARGET_DATE is still at $STALE_REPORT"
    fi
  fi

  # Partials are prefixes of a report that now exists in full, so a complete report
  # supersedes every one of them for this date — including partials from earlier nights,
  # which is the case the .stale-* rule above can never reach because it only knows about
  # the copy this run made. Without this they pile up in the dreams dir with nothing to
  # ever remove them.
  if report_complete; then
    for partial in "$REPORT_PATH".partial-*; do
      [ -e "$partial" ] || continue
      if rm -f "$partial"; then log "discarded superseded partial report $partial"; fi
    done
  elif [ -n "${PARTIAL_REPORT:-}" ] && [ -s "$PARTIAL_REPORT" ]; then
    log "the incomplete report for $TARGET_DATE is readable at $PARTIAL_REPORT"
  fi

  if [ -f "$REPORT_PATH" ]; then
    log "report bytes: $(wc -c < "$REPORT_PATH" | tr -d ' ')"

    # ---- Escalate questions this report has now asked N nights running ----
    # Before the pins and notify.sh, deliberately: it only reads the report and writes one
    # local file, while those steps call out (notify.sh runs the user's AUTODREAM_OPEN
    # synchronously, apply-pins.sh calls the Mnemopi store). If either hangs, a kill there
    # leaves a report on disk that the next trigger skips, and a streak update placed after
    # them would never run for it, so a stale question would miss its escalation
    # (https://github.com/STRML/autodream/issues/77). The failure it
    # answers is not a missing signal but an unchanging one — the X bookmarks question was
    # asked six times across ten failing nights, each night's banner identical to the last,
    # and nothing moved until the user noticed by accident. Never fatal; it is bookkeeping.
    if [ -x "$AUTODREAM_DIR/question-streaks.sh" ]; then
      env AUTODREAM_DIR="$AUTODREAM_DIR" "$AUTODREAM_DIR/question-streaks.sh" update "$REPORT_PATH" "$FINDINGS_DIR" \
        || log "question-streaks returned non-zero (continuing)"
    fi

    # ---- Memory pins: L2's pins.jsonl into Mnemopi ----
    # First step after the report that calls out (the streak update above only writes a local
    # file), ahead of notify.sh and the consume steps. notify.sh runs
    # AUTODREAM_OPEN synchronously, so a blocking editor command holds the run there; if
    # the run dies in that wait, the next run skips the date and pins placed after it are
    # never stored.
    #
    # Pins need a complete report from THIS run behind them: report_complete, CONSUME_SAFE
    # (cleared when the old report could not be moved aside), and PINS_SAFE (cleared when an
    # earlier pins.jsonl could not be moved aside). They skip the consume date gate on
    # purpose: an old-date rebuild still teaches something real, and apply-pins.sh's ledger
    # stops a rerun from storing the same pin twice.
    #
    # pin-projects.tsv is the authorization list. It holds only projects this run
    # triaged, each with the working directory its session's adapter resolved, so a pin
    # naming any other project is refused and memory is never scoped by a path the model
    # wrote. Plan and failure matrix: docs/plans/2026-09-15-mnemopi-pins.md.
    PINS="$FINDINGS_DIR/pins.jsonl"
    if [ -s "$PINS" ] && { ! report_complete || [ "${CONSUME_SAFE:-1}" != "1" ] || [ "$PINS_SAFE" != "1" ]; }; then
      log "skipping memory pins: no complete report from this run stands behind $PINS"
    elif [ -s "$PINS" ] && ! write_pin_projects "$FINDINGS_DIR"; then
      log "skipping memory pins: could not write pin-projects.tsv, so no project is authorized"
    elif [ -s "$PINS" ] && ! restore_pins_ledger "$FINDINGS_DIR"; then
      log "skipping memory pins: could not restore pins-applied.tsv, so duplicates cannot be ruled out"
    elif [ -s "$PINS" ]; then
      if bash "$APPLY_PINS" "$FINDINGS_DIR" "$TARGET_DATE" >> "$RUN_LOG" 2>&1; then
        log "memory pins: $(tr '\n' ' ' 2>/dev/null < "$FINDINGS_DIR/pins-result.txt" || echo "counters unavailable")"
      else
        log "memory pin counters unavailable: apply-pins exited non-zero (check pins-applied.tsv for what it stored; unstored pins stay in $PINS)"
      fi
    fi

    # ---- Report citation integrity (appended to run-stats.txt) ----
    # Deliberately here and not in the run-stats block above: those keys are written
    # BEFORE L2 runs, and this check needs the finished report. Appending keeps one
    # self-audit artifact to read in the morning instead of a second sidecar.
    # Never fatal — a citation defect is a measurement, and the report still ships.
    if [ -x "$CITECHECK" ]; then
      if CITE_OUT=$("$CITECHECK" "$REPORT_PATH" "$FINDINGS_DIR" 2>>"$RUN_LOG"); then
        printf '%s\n' "$CITE_OUT" >> "$FINDINGS_DIR/run-stats.txt"
        CITE_BAD=$(printf '%s\n' "$CITE_OUT" | awk -F': ' '/^citations_(unresolved|to_gated): /{n+=$2} END{print n+0}')
        if [ "$CITE_BAD" -gt 0 ]; then
          log "WARNING: $CITE_BAD report citation(s) do not resolve to a triaged session — see citations_* in run-stats.txt"
        else
          log "citations: all resolved to triaged sessions"
        fi
      else
        # The checker could not run (missing jq, unreadable inputs). Record that rather
        # than leaving the keys absent, which reads as "this runner predates the stat".
        printf 'citations_total: unmeasured\ncitations_unresolved: unmeasured\ncitations_to_gated: unmeasured\n' \
          >> "$FINDINGS_DIR/run-stats.txt"
        log "citations: check did not run (keys recorded as unmeasured)"
      fi
    fi

    # ---- Drop open-questions file into Sublime (no-op if zero questions) ----
    if [ -x "$AUTODREAM_DIR/notify.sh" ]; then
      log "writing open-questions inbox file..."
      "$AUTODREAM_DIR/notify.sh" "$REPORT_PATH" || log "notify step returned non-zero (continuing)"
    fi

    # ---- Consume what L2 just read ----
    # Deliberately gated on a NON-EMPTY report, not merely an existing one. Archiving a
    # note or stamping a bookmark read after a run that produced nothing would throw away
    # the only copy of input the user cared about — the failure mode is silent and
    # unrecoverable, so the guard is stricter than the enclosing -f check.
    #
    # Also gated on TARGET_DATE being the date a normal nightly run would process
    # (yesterday, right now — same computation the default at the top of this script
    # uses). collect() above is date-agnostic: it reads whatever is CURRENTLY in the
    # vault inbox and CURRENTLY unread, regardless of which date's findings dir it's
    # writing into. That's exactly right when TARGET_DATE is tonight's date — but
    # CLAUDE.md documents reprocessing an old one (AUTODREAM_FORCE=1 run.sh
    # 2026-05-29), and archive/mark-read have no idea the date is old: a successful
    # rebuild of 2026-05-29 would archive a note the user wrote THIS morning into
    # processed/2026-05-29/ and stamp today's unread bookmarks read, and tonight's real
    # run would then find an empty inbox and nothing unread — the note never reaches
    # any report. Collection still runs unconditionally above, so L2 still SEES
    # today's notes/bookmarks as context; only the consuming side is skipped for an
    # old-date reprocess.
    # AUTODREAM_CONSUME_DATE overrides which date counts as "the normal nightly one",
    # authoritatively and with no fallback, for the same reason AUTODREAM_STATS_BIN and
    # AUTODREAM_OVERLAP_BIN do: the suite pins a fixed historical TARGET_DATE, so without
    # an override every consume path would take the skip branch and the tests that cover
    # archiving would pass while asserting nothing.
    NORMAL_TARGET_DATE="${AUTODREAM_CONSUME_DATE:-$(pdate_yesterday)}"
    if ! report_complete; then
      log "report is present but carries no open-questions marker; skipping vault-notes archive and x-bookmark mark-read rather than consuming input against a truncated report"
    else
      # Publishing is NOT a consuming step — it copies the report into the vault so it
      # can be read on a phone, and a reprocessed date is exactly as worth reading as a
      # fresh one. It stays outside the date gate; only archive and mark-read, which
      # destroy the user's only copy of their input, are gated.
      if [ -x "$VAULT_NOTES" ]; then
        "$VAULT_NOTES" publish "$REPORT_PATH" || log "vault report publish failed (continuing)"
      fi
      if [ "${CONSUME_SAFE:-1}" != "1" ]; then
        log "skipping vault-notes archive and x-bookmark mark-read: a stale report could not be moved aside, so this report cannot be attributed to this run"
      elif [ "$TARGET_DATE" = "$NORMAL_TARGET_DATE" ]; then
        if [ -x "$VAULT_NOTES" ]; then
          "$VAULT_NOTES" archive "$FINDINGS_DIR" || log "vault note archive failed (notes stay in the inbox)"
        fi
        if [ -x "$XBOOKMARKS" ]; then
          "$XBOOKMARKS" mark-read "$FINDINGS_DIR" || log "x-bookmark mark-read failed (they stay unread)"
        fi
      else
        log "target date $TARGET_DATE is not $NORMAL_TARGET_DATE (today's normal nightly date); skipping vault-notes archive and x-bookmark mark-read so today's inbox/unread bookmarks aren't consumed by this reprocess (still collected as L2 context)"
      fi
    fi

    # ---- Dream triage: an optional worklist from the finished report ----
    # Opt-in (AUTODREAM_TRIAGE=1), and last on purpose: it is one more model call, so a hang or
    # a failure there must not hold back the pins, the banner or the consume steps above. Only a
    # validated delivery is triaged. The engine is L2's (an adapter), the model gets Read and
    # Glob only, and bin/triage-dream.sh writes dreams/<date>.triage.md itself. Never fatal.
    if [ "${AUTODREAM_TRIAGE:-0}" = "1" ] && [ "$L2_DELIVERED" = "1" ] && report_complete; then
      if [ -x "$TRIAGE_DREAM" ]; then
        log "dream triage: running ($TRIAGE_DREAM)"
        env AUTODREAM_DIR="$AUTODREAM_DIR" DREAMS_DIR="$DREAMS_DIR" PROJECTS_DIR="$PROJECTS_DIR" \
          AUTODREAM_L2_ENGINE="$L2_ENGINE" "$TRIAGE_DREAM" "$TARGET_DATE" >> "$RUN_LOG" 2>&1 \
          || log "dream triage produced no worklist (continuing)"
        clean_work_bucket
      else
        log "dream triage requested but triage-dream.sh was not found; skipping"
      fi
    fi
  else
    # Where the recoverable copies are was already logged above, in the one block that
    # runs whether or not this path still holds a file.
    log "WARNING: no report at $REPORT_PATH"
  fi

  log "===== autodream end: $(date) ====="
  # A validated delivery is the only success, and it is the same predicate the move-aside and
  # consume gates use: a sentinel-validated capture (L2_DELIVERED) that also carries the
  # open-questions marker (report_complete). A degraded night can leave the aggregator's own
  # exit code at 0, which would tell the launchd job (the only watcher this unattended run has)
  # that the night produced a usable report when it produced none. Anything short of validated
  # keeps the aggregator's status when it was non-zero, else 1.
  if [ "$L2_DELIVERED" = "1" ] && report_complete; then
    return 0
  fi
  if [ "${L2_RC:-0}" -ne 0 ]; then
    return "$L2_RC"
  fi
  return 1
}

# ---- The logger must not be able to take the run down with it ----
# `run 2>&1 | tee -a "$RUN_LOG"` turns every log line into a write to a pipe, so whatever
# kills tee kills the run on its very next log call — by SIGPIPE, with no error line,
# before the L2 retry loop, the move-aside blocks, or the consume gate are ever reached.
# Three runs on 2026-08-02 died exactly there and left 2026-08-01 with no report at all:
# `Terminated: 15` on tee, `Broken pipe: 13` on run, and a log ending mid-sentence at
# "L2 aggregation attempt 1/3...". Every recovery path in this script assumes it gets to
# run, and a logger that can revoke that assumption defeats all of them at once.
#
# A file has no reader to lose, so that is where an unattended run writes. Ignoring
# SIGPIPE covers the interactive path too, where tee is still worth having and a closed
# terminal should cost the run its output rather than its life.
trap '' PIPE
trap release_run_lock EXIT
if [ -t 1 ]; then
  run 2>&1 | tee -a "$RUN_LOG"
  exit "${PIPESTATUS[0]}"
fi
echo "autodream: logging to $RUN_LOG"
run >> "$RUN_LOG" 2>&1
exit $?
