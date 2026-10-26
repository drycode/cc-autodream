#!/usr/bin/env bash
# autodream-note.sh — leave a free-text note for the next cc-autodream run.
#
# The L2 aggregator reads $AUTODREAM_DIR/notes.md (via vault-notes.sh) and addresses each active note in
# its "Operator notes" report section (usage counts, is-it-working reads, etc.). Notes
# past their --expires date are ignored and flagged for removal, so the file self-retires.
#
# Usage:
#   autodream-note.sh "evaluate how often /graphify is used"
#   autodream-note.sh --expires 2026-10-01 "evaluate how well graphify works"
set -euo pipefail

# Resolve the install dir the way notify.sh, review.sh and run.sh do: env first, else this
# script's own directory when it carries an install marker (install.sh writes `config` and links
# PROMPT.md), else the legacy default with a warning. BASH_SOURCE stays unresolved on purpose:
# install.sh symlinks the scripts into $TARGET, so the link's directory IS the install dir.
# Hard-coding $HOME/.claude/autodream here made the writer and the reader disagree the moment an
# install lived anywhere else: vault-notes.sh takes AUTODREAM_DIR from the launchd plist, so every
# note landed in a file the nightly never opened. No error, no missing note reported.
_src="${BASH_SOURCE[0]}"; _lib="$(dirname "$_src")/lib-install-dir.sh"
# Installed copies are symlinks: a merge updates them before install.sh links a new helper.
[ -r "$_lib" ] || _lib="$(dirname "$(readlink "$_src" 2>/dev/null || echo "$_src")")/lib-install-dir.sh"
# shellcheck source=/dev/null
. "$_lib"
resolve_install_dir "$_src" autodream-note.sh
NOTES="${AUTODREAM_NOTES_FILE:-$AUTODREAM_DIR/notes.md}"
EXPIRES=""
if [ "${1:-}" = "--expires" ]; then EXPIRES="${2:-}"; shift 2; fi
TEXT="${*:-}"
[ -n "$TEXT" ] || { echo "usage: autodream-note.sh [--expires YYYY-MM-DD] \"note text\"" >&2; exit 2; }

mkdir -p "$(dirname "$NOTES")"
if [ ! -f "$NOTES" ]; then
  printf '# Operator notes for autodream\n\nFree-text notes the next run should address in its "Operator notes" section.\nFormat: `- [added] (expires DATE) text` — expiry optional; expired notes are ignored.\n\n' > "$NOTES"
fi

TODAY="$(date +%F)"
if [ -n "$EXPIRES" ]; then
  printf -- '- [%s] (expires %s) %s\n' "$TODAY" "$EXPIRES" "$TEXT" >> "$NOTES"
else
  printf -- '- [%s] %s\n' "$TODAY" "$TEXT" >> "$NOTES"
fi
echo "noted -> $NOTES"
