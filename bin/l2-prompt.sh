#!/bin/bash
# Sourced, never executed. The system prompt every L2 engine runs under, kept in
# prompts/L2_SYSTEM.txt so the claude adapter, the omp adapter and run.sh's built-in claude
# fallback all say the same thing. It states the stdout grammar that bin/report-format.sh parses
# (the report, AUTODREAM_REPORT_END, the optional pin block, the summary), so a change to that
# grammar is one edit here and one in report-format.sh.
#
# l2_system_prompt prints the text with no trailing newline added. It returns 2 and says why on
# stderr when no copy can be read: an engine started without this prompt would run L2 with no
# instruction about where the report goes, and the output would look like a night's work.

l2_system_prompt() {
  local self dir f
  self="${BASH_SOURCE[0]}"
  # An installed copy is a symlink into the checkout, and the prompt sits beside bin/ there.
  if [ -L "$self" ]; then
    f=$(readlink "$self")
    case "$f" in /*) self="$f" ;; *) self="$(dirname "$self")/$f" ;; esac
  fi
  dir=$(cd -P "$(dirname "$self")" 2>/dev/null && pwd) || dir=""
  for f in "$dir/../prompts/L2_SYSTEM.txt" "${AUTODREAM_DIR:-}/L2_SYSTEM.txt"; do
    # Not just non-empty: a file of blank lines would start an engine with an empty instruction.
    if [ -r "$f" ] && grep -q '[^[:space:]]' "$f" 2>/dev/null; then cat "$f"; return 0; fi
  done
  echo "l2-prompt: prompts/L2_SYSTEM.txt not found or empty (looked beside ${dir:-the lib} and in AUTODREAM_DIR=${AUTODREAM_DIR:-unset})" >&2
  return 2
}
