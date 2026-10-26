#!/bin/bash
# Dream triage: turn one finished report into a review-ready worklist. Opt-in, one extra model
# call per night, and none unless AUTODREAM_TRIAGE=1 (run.sh) or this script is run by hand.
#
# What it does, in order:
#   1. dream-grounding.sh runs a FIXED set of read-only checks (is the skill the report names
#      installed, is the allowlist key it proposes in settings.json, does the commit it cites
#      resolve) and writes findings/<date>/triage/grounding.json. No model, no shell for a model.
#   2. The L2 engine (an adapter, the same seam as the report) is given Read and Glob over a
#      staging directory holding report.md and grounding.json, and prints the worklist on
#      stdout ending with the AUTODREAM_REPORT_END sentinel.
#   3. The runner, not the model, writes dreams/<date>.triage.md from the text before the
#      LAST sentinel. A capture with no sentinel writes nothing.
#
# It never creates tickets and never edits anything but its own two outputs. The model holds no
# Write tool and no shell, so the report text it reads cannot make it do either.
#
# Usage:
#   triage-dream.sh              # the newest dreams/YYYY-MM-DD.md
#   triage-dream.sh 2026-07-14   # one date
#
# Environment (all optional):
#   AUTODREAM_DIR          scripts, prompts and state          default: $HOME/.claude/autodream
#   DREAMS_DIR             where reports live                  default: $HOME/.claude/dreams
#   PROJECTS_DIR           the primary session root            default: $HOME/.claude/projects
#   AUTODREAM_L2_ENGINE    adapter whose engine runs the pass  default: the first of AUTODREAM_ADAPTERS
#   AUTODREAM_L2_MODEL / AUTODREAM_L2_MODEL_<NAME>   the model, resolved exactly as for L2
#   AUTODREAM_TRIAGE_TIMEOUT  seconds before the call is killed   default: 900
#                          (needs timeout or gtimeout on PATH; without one the pass is skipped, exit 1)
#   AUTODREAM_FORCE        1 rebuilds an existing triage file   default: 0
#   plus the dream-grounding.sh knobs (AUTODREAM_SKILL_DIRS, AUTODREAM_SETTINGS_FILES,
#   AUTODREAM_TRIAGE_REPOS).
#
# Exit 0: wrote the file, or one already exists. 1: the pass produced nothing. 2: cannot run.

set -u

log() { echo "[$(date '+%H:%M:%S')] triage: $*"; }

# Where the libraries and the prompt live. The install symlinks each script into
# $AUTODREAM_DIR, so this script's own directory may not hold them.
SRC="${BASH_SOURCE[0]}"
SCRIPT_DIR=$(cd "$(dirname "$SRC")" && pwd)
REAL_DIR="$SCRIPT_DIR"
[ -L "$SRC" ] && REAL_DIR=$(cd "$(dirname "$(readlink "$SRC")")" 2>/dev/null && pwd) || true
AUTODREAM_DIR="${AUTODREAM_DIR:-$HOME/.claude/autodream}"
find_file() { # $1=basename -> first readable copy
  local d
  for d in "$SCRIPT_DIR" "$REAL_DIR" "$AUTODREAM_DIR" "$REAL_DIR/../prompts"; do
    [ -r "$d/$1" ] && { printf '%s' "$d/$1"; return 0; }
  done
  return 1
}
_rf=$(find_file report-format.sh) || { log "ERROR: report-format.sh not found beside $SRC"; exit 2; }
# shellcheck source=/dev/null
. "$_rf"

# The config, with the caller's environment winning over it (run.sh's rule).
CONFIG_FILE="${AUTODREAM_CONFIG:-$AUTODREAM_DIR/config}"
if [ -f "$CONFIG_FILE" ]; then
  # Sourcing a user-edited file under nounset kills the shell with its error hidden, so probe
  # in a subshell first, as run.sh does, and say what is wrong.
  # shellcheck disable=SC1090
  if _cfg_err=$( (set -a; set -u; . "$CONFIG_FILE") 2>&1 >/dev/null ); then
    _env=$(export -p)
    set -a
    # shellcheck source=/dev/null
    . "$CONFIG_FILE" 2>/dev/null
    set +a
    eval "$_env" 2>/dev/null || true
  else
    log "WARNING: ignoring $CONFIG_FILE: $_cfg_err"
  fi
fi

DREAMS_DIR="${DREAMS_DIR:-$HOME/.claude/dreams}"
PROJECTS_DIR="${PROJECTS_DIR:-$HOME/.claude/projects}"
export PATH="$PATH:$HOME/.cargo/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"

if [ -n "${1:-}" ]; then
  TARGET_DATE="$1"
else
  TARGET_DATE=$(find "$DREAMS_DIR" -maxdepth 1 -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md' 2>/dev/null \
                  | sort | tail -1 | xargs -I{} basename {} .md)
fi
[ -n "$TARGET_DATE" ] || { log "ERROR: no dreams/YYYY-MM-DD.md in $DREAMS_DIR"; exit 2; }
REPORT_PATH="$DREAMS_DIR/$TARGET_DATE.md"
TRIAGE_PATH="$DREAMS_DIR/$TARGET_DATE.triage.md"
FINDINGS_DIR="$AUTODREAM_DIR/findings/$TARGET_DATE"
STAGE="$FINDINGS_DIR/triage"

[ -s "$REPORT_PATH" ] || { log "ERROR: no report at $REPORT_PATH"; exit 2; }
# Current means newer than the report it was made from: a rebuilt report leaves an older triage stale.
if [ -s "$TRIAGE_PATH" ] && [ ! "$REPORT_PATH" -nt "$TRIAGE_PATH" ] && [ "${AUTODREAM_FORCE:-0}" != "1" ]; then
  log "triage already exists for $TARGET_DATE; AUTODREAM_FORCE=1 rebuilds it"
  exit 0
fi

PROMPT=$(find_file TRIAGE_DREAM.md) || { log "ERROR: TRIAGE_DREAM.md not found beside the script or in $AUTODREAM_DIR"; exit 2; }
GROUNDING=$(find_file dream-grounding.sh) || { log "ERROR: dream-grounding.sh not found"; exit 2; }
ADAPTERS_LIB=$(find_file adapters.sh) || { log "ERROR: adapters.sh not found"; exit 2; }
# shellcheck source=/dev/null
. "$ADAPTERS_LIB"

# ---- The engine: an adapter, resolved as run.sh resolves L2's ----
ACCEPTED=$(adapters_list 2>/dev/null)
ENABLED=$(printf '%s' "${AUTODREAM_ADAPTERS:-claude}" | tr ',' ' ')
[ "$ENABLED" = "all" ] && ENABLED=$(printf '%s' "$ACCEPTED" | tr '\n' ' ')
ENGINE="${AUTODREAM_L2_ENGINE:-${ENABLED%% *}}"
if ! printf '%s\n' "$ACCEPTED" | grep -qxF "$ENGINE"; then
  log "ERROR: engine '$ENGINE' is not an accepted adapter (accepted: $(printf '%s' "$ACCEPTED" | tr '\n' ' '))"
  exit 2
fi
MODEL=$(adapter_l2_model "$ENGINE" 2>/dev/null) || MODEL=""
ARGV=()
while IFS= read -r -d "" a; do ARGV+=("$a"); done < <(adapter_run "$ENGINE" l2-argv ${MODEL:+"$MODEL"} 2>/dev/null)
ENVS=()
while IFS= read -r l; do [ -n "$l" ] && ENVS+=("$l"); done < <(adapter_run "$ENGINE" l1-env 2>/dev/null)
if [ "${#ARGV[@]}" -eq 0 ]; then
  log "ERROR: the $ENGINE adapter produced no L2 command (model [${MODEL:-none}])"
  exit 1
fi

# ---- Grounding: fixed checks, written as data ----
mkdir -p "$STAGE" || { log "ERROR: cannot create $STAGE"; exit 2; }
cp "$REPORT_PATH" "$STAGE/report.md" || { log "ERROR: cannot stage the report"; exit 2; }
INV="$STAGE/skills-inventory.txt"
: > "$INV"
for a in $ENABLED; do
  printf '%s\n' "$ACCEPTED" | grep -qxF "$a" && adapter_run "$a" skills-inventory 2>/dev/null >> "$INV"
done
if ! AUTODREAM_SKILL_INVENTORY_FILE="$INV" bash "$GROUNDING" "$STAGE/report.md" "$STAGE/grounding.json" "$FINDINGS_DIR/pin-projects.tsv"; then
  log "ERROR: grounding did not run; nothing to triage against"
  exit 1
fi
log "date $TARGET_DATE, engine $ENGINE, model ${MODEL:-<engine default>}; grounding: $(jq -r '[.claims[] | .status] | group_by(.) | map("\(.[0]) \(length)") | join(", ")' "$STAGE/grounding.json" 2>/dev/null)"

# ---- The model pass: Read and Glob over the staging directory, output on stdout ----
# The same isolated cwd as run.sh's workers, so an AI-title stub lands in a bucket we wipe.
WORK_DIR="$AUTODREAM_DIR/work"
WORK_BUCKET="$PROJECTS_DIR/$(printf '%s' "$WORK_DIR" | sed 's#[/.]#-#g')"
mkdir -p "$WORK_DIR" 2>/dev/null
clean_work_bucket() { rm -rf "$WORK_BUCKET" 2>/dev/null || true; }
clean_work_bucket

TMO=()
TIMEOUT="${AUTODREAM_TRIAGE_TIMEOUT:-900}"
case "$TIMEOUT" in ''|*[!0-9]*|0) TIMEOUT=900 ;; esac
for t in timeout gtimeout; do
  command -v "$t" >/dev/null 2>&1 && { TMO=("$t" -k 30 "$TIMEOUT"); break; }
done
# Unbounded, a wedged engine would hold the run (and its lock) at the end of the night, so
# without a timeout binary the pass is skipped, as L1's warmup is.
if [ "${#TMO[@]}" -eq 0 ]; then
  log "no timeout or gtimeout on PATH; skipping triage rather than run an unbounded model call"
  exit 1
fi

STDOUT_FILE="$STAGE/triage.stdout"
rm -f "$STDOUT_FILE"
(
  cd "$WORK_DIR" 2>/dev/null || true
  {
    printf 'Findings directory to aggregate (literal absolute path): %s\n' "$STAGE"
    printf 'Report destination (literal absolute path): %s\n\n' "$TRIAGE_PATH"
    cat "$PROMPT"
  } | env ${ENVS[@]+"${ENVS[@]}"} ${TMO[@]+"${TMO[@]}"} "${ARGV[@]}"
) > "$STDOUT_FILE"
RC=$?
clean_work_bucket

# ---- The runner writes the file, from the text before the last sentinel ----
if ! report_has_sentinel "$STDOUT_FILE"; then
  log "no AUTODREAM_REPORT_END sentinel in the engine's output (exit $RC); wrote nothing"
  exit 1
fi
report_body "$STDOUT_FILE" > "$TRIAGE_PATH.tmp"
if [ ! -s "$TRIAGE_PATH.tmp" ]; then
  rm -f "$TRIAGE_PATH.tmp"
  log "the engine delivered an empty worklist (exit $RC); wrote nothing"
  exit 1
fi
mv -f "$TRIAGE_PATH.tmp" "$TRIAGE_PATH" || { log "ERROR: could not write $TRIAGE_PATH"; exit 1; }
log "wrote $TRIAGE_PATH ($(wc -c < "$TRIAGE_PATH" | tr -d ' ') bytes)"
exit 0
