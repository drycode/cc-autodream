#!/bin/bash
# One temp root per test suite, removed on every way out (issue #63).
#
# A suite that makes its temp dirs with `mktemp -d` and removes them on its last
# line leaks them on Ctrl-C, a harness timeout or an early exit, and macOS never
# collects a non-empty tree under /tmp (com.apple.tmp_cleaner only takes empty
# directories older than 3 days). `suite_tmp NAME` makes ONE directory, points
# TMPDIR at it so every later `mktemp` in the suite and in whatever it runs lands
# inside, and arms the cleanup. That covers call sites a variable cannot track,
# such as a `mktemp -d` inside `$(...)`, whose assignment dies with the subshell.
#
# Source it, then call suite_tmp once, before the first mktemp.
#
# bash runs an EXIT trap on a trapped signal only if the handler exits, so INT
# and TERM exit with the conventional 128+n status. The EXIT trap leaves the
# suite's own exit status alone: a trap that does not call `exit` cannot flip a
# red suite green. A trap is right in a test suite and wrong in
# adapters/claude/adapter.sh, which must die promptly on SIGTERM (issue #57).
suite_tmp() { # $1=short suite name
  # Arm the traps BEFORE the directory exists, so a signal between mktemp and the
  # trap cannot leak it. `${SUITE_TMP:-}` keeps the cleanup a no-op until it is set.
  SUITE_TMP=""
  trap 'rm -rf "${SUITE_TMP:-}"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # Strip a trailing slash: macOS and GitHub's runners set TMPDIR with one, mktemp
  # keeps the resulting "//", and a suite that compares a path to what `cd && pwd`
  # prints (tests/notes-path.sh) then fails on a string mismatch.
  local root="${TMPDIR:-/tmp}"
  SUITE_TMP=$(mktemp -d "${root%/}/$1-suite.XXXXXX") || return 1
  export TMPDIR="$SUITE_TMP"
}
# Residual window: a signal that lands after mktemp creates the directory and
# before the assignment above leaks it. It is microseconds wide and bash cannot
# close it without blocking signals; tests/tmp-cleanup.sh waits for the suite to
# make an entry inside the root so it never fires there.
