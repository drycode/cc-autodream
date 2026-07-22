#!/bin/bash
# Dream triage — turn a daily autodream report into a review-ready worklist.
#
# Reads one dreams/YYYY-MM-DD.md, grounds each actionable item with read-only
# shell checks, and writes dreams/YYYY-MM-DD.triage.md: a table of proposed
# tickets + draft ticket text for a human to approve. It NEVER creates Linear
# tickets and NEVER edits anything but its own triage output — acting on the
# report stays human-gated (same blast-radius stance as the aggregator, which
# proposes but does not edit source).
#
# Usage:
#   ./triage-dream.sh              # triage the most recent dreams/*.md
#   ./triage-dream.sh 2026-07-14   # triage a specific date
#
# Environment overrides (all optional):
#   CLAUDE_BIN        path to claude CLI          default: $HOME/.local/bin/claude
#   AUTODREAM_DIR     scripts + prompts + state   default: $HOME/.claude/autodream
#   DREAMS_DIR        where reports live          default: $HOME/.claude/dreams
#   AUTODREAM_TRIAGE_MODEL  triage model          default: claude-opus-4-8
#   AUTODREAM_FORCE   set 1 to rebuild an existing triage file   default: 0

set -u

CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
AUTODREAM_DIR="${AUTODREAM_DIR:-$HOME/.claude/autodream}"
DREAMS_DIR="${DREAMS_DIR:-$HOME/.claude/dreams}"
PROJECTS_DIR="${PROJECTS_DIR:-$HOME/.claude/projects}"
TRIAGE_MODEL="${AUTODREAM_TRIAGE_MODEL:-claude-opus-4-8}"

log() { echo "[$(date '+%H:%M:%S')] triage: $*"; }

# Resolve the prompt next to this script first (repo copy or the ~/.claude symlink),
# then fall back to the install dir — same resolution run.sh uses for its helpers.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROMPT="$SCRIPT_DIR/../prompts/TRIAGE_DREAM.md"
[ -f "$PROMPT" ] || PROMPT="$AUTODREAM_DIR/TRIAGE_DREAM.md"
if [ ! -f "$PROMPT" ]; then
  log "ERROR: TRIAGE_DREAM.md not found next to script or in $AUTODREAM_DIR"
  exit 2
fi

# Pick the date: explicit arg, else the most recent dreams/YYYY-MM-DD.md (ignoring
# the *.triage.md sidecars we write ourselves).
if [ "${1:-}" != "" ]; then
  TARGET_DATE="$1"
else
  latest=$(ls -1 "$DREAMS_DIR" 2>/dev/null \
             | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.md$' \
             | sort | tail -1)
  if [ -z "$latest" ]; then
    log "ERROR: no dreams/YYYY-MM-DD.md found in $DREAMS_DIR"
    exit 2
  fi
  TARGET_DATE="${latest%.md}"
fi

REPORT_PATH="$DREAMS_DIR/$TARGET_DATE.md"
TRIAGE_PATH="$DREAMS_DIR/$TARGET_DATE.triage.md"

if [ ! -s "$REPORT_PATH" ]; then
  log "ERROR: no report at $REPORT_PATH"
  exit 2
fi

# Idempotency guard: don't re-triage a date that already has a non-empty triage
# file unless forced. Lets run.sh call this after every report without dup work.
if [ -s "$TRIAGE_PATH" ] && [ "${AUTODREAM_FORCE:-0}" != "1" ]; then
  log "triage already exists for $TARGET_DATE ($TRIAGE_PATH); set AUTODREAM_FORCE=1 to rebuild"
  exit 0
fi

# Isolated cwd for the `claude --print` call, exactly like run.sh: Claude Code's
# async AI-title generation writes a one-line stub into the launch cwd's session
# bucket even under --no-session-persistence, so we run from a dedicated dir whose
# bucket we wipe, instead of polluting the real -Users-<you> session history.
WORK_DIR="$AUTODREAM_DIR/work"
WORK_BUCKET="$PROJECTS_DIR/$(printf '%s' "$WORK_DIR" | sed 's#[/.]#-#g')"
mkdir -p "$WORK_DIR" "$DREAMS_DIR"
clean_work_bucket() { rm -rf "$WORK_BUCKET" 2>/dev/null || true; }

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1

log "date $TARGET_DATE, model $TRIAGE_MODEL -> $TRIAGE_PATH"
clean_work_bucket

# Same literal-path framing + brace-group assembly as L1/L2 in run.sh: keep the
# paths as literal data the worker hands to Read/Write, and preserve the blank
# line before the prompt body. Bash/Grep/Glob are added over the L2 toolset so the
# worker can GROUND report claims (read-only) before proposing them; the prompt
# forbids any mutating command. Subshell scopes the cwd change.
(
  cd "$WORK_DIR" 2>/dev/null || true
  {
    printf "Dream report to triage (literal absolute path): %s\n" "$REPORT_PATH"
    printf "Write your triage file to this literal absolute path: %s\n\n" "$TRIAGE_PATH"
    cat "$PROMPT"
  } | "$CLAUDE_BIN" \
    --print \
    --permission-mode bypassPermissions \
    --model "$TRIAGE_MODEL" \
    --no-session-persistence \
    --tools Read Glob Grep Bash Write \
    --disable-slash-commands \
    --strict-mcp-config \
    --settings '{"disableAllHooks":true}' \
    --append-system-prompt "Headless dream-triage worker. Read the dream report given on line 1 of the prompt, ground each actionable item with READ-ONLY shell checks (grep/ls/find/git log — never anything that writes, deletes, or installs), then write one triage markdown, via the Write tool, to the literal path given on line 2. Those paths are literal strings, not shell variables — never \$-expand them. Do NOT create Linear tickets. Do NOT edit any file other than the triage output. Print only 'done' and the triage path, then exit."
)
RC=$?

clean_work_bucket

if [ -s "$TRIAGE_PATH" ]; then
  log "wrote $TRIAGE_PATH ($(wc -c < "$TRIAGE_PATH" | tr -d ' ') bytes)"
  exit 0
fi

log "no triage file written (exit $RC)"
exit 1
