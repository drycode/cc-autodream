#!/bin/bash
# The one place that decides which install directory a script belongs to (#112).
#
# Six scripts used to carry their own copy of this resolver, and the copies
# drifted: they disagreed on which files prove a directory is an install, on
# whether to warn, and one never looked at its own location at all. The writer
# and the reader of the operator notes disagreed on the directory the moment an
# install lived anywhere but ~/.claude/autodream (#91), and every note landed in
# a file the nightly never opened, with no error.
#
# Source this, then call:
#
#   resolve_install_dir "${BASH_SOURCE[0]}" [NAME]
#
# Sets AUTODREAM_DIR (and does not export it):
#   1. an AUTODREAM_DIR already in the environment wins;
#   2. else the directory the script sits in, when it carries an install marker:
#      `config` (install.sh writes it) or `PROMPT.md` (one of its symlinks). The
#      other marker some copies tested, `l1-no-advisor.yml`, came from the OMP
#      install and nothing here installs it. BASH_SOURCE stays UNRESOLVED on purpose:
#      install.sh symlinks each script into $TARGET, so the link's own directory
#      IS the install dir, while the resolved path is the repo. No marker lives in
#      the repo's bin/, so running from a checkout never mistakes bin/ for an install;
#   3. else the legacy default ~/.claude/autodream. With NAME it says so on stderr
#      ("NAME: WARNING ..."); without it the fallback is silent, which is what the
#      scripts that never warned (autodream-now, notify, question-streaks) keep.
resolve_install_dir() { # $1=the calling script's path  $2=optional name for the warning
  local src="$1" name="${2:-}" dir
  [ -z "${AUTODREAM_DIR:-}" ] || return 0
  dir="$(cd "$(dirname "$src")" 2>/dev/null && pwd)"
  if [ -n "$dir" ] && { [ -f "$dir/config" ] || [ -f "$dir/PROMPT.md" ]; }; then
    AUTODREAM_DIR="$dir"
    return 0
  fi
  [ -z "$name" ] || echo "$name: WARNING no install markers next to $src; falling back to legacy $HOME/.claude/autodream" >&2
  AUTODREAM_DIR="$HOME/.claude/autodream"
}
