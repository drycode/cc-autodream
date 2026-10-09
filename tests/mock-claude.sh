#!/bin/bash
# Mock `claude` binary for cc-autodream integration tests.
#
# run.sh invokes the real claude CLI for both layers. Here we stand in for it:
# read the prompt on stdin, find the two literal-path lines run.sh inlined, and
# write (or deliberately don't write) the expected output file — no model, no
# network. Which layer we are is decided by line 1 of the prompt.
#
# Env knobs (all optional):
#   MOCK_MODE=good           write findings (L1) / report (L2). [default]
#   MOCK_MODE=l1_incomplete  L1 writes nothing (simulates a worker that exits
#                            without producing JSON); L2 still writes its report.
#   MOCK_CAPTURE_DIR=<dir>   dump each layer's stdin + argv to <dir>/l{1,2}-*.txt
#                            so tests can assert on the exact prompt framing.

input=$(cat)
mode="${MOCK_MODE:-good}"
line1=$(printf '%s\n' "$input" | sed -n '1p')
line2=$(printf '%s\n' "$input" | sed -n '2p')

if printf '%s' "$line1" | grep -q '^Session transcript'; then
  # ---- Layer 1: triage worker ----
  if [ -n "${MOCK_CAPTURE_DIR:-}" ]; then
    printf '%s' "$input" > "$MOCK_CAPTURE_DIR/l1-stdin.txt"
    printf '%s\n' "$@" > "$MOCK_CAPTURE_DIR/l1-args.txt"
  fi
  out=$(printf '%s' "$line2" | sed 's/^Write your findings JSON to this literal absolute path: //')
  sess=$(printf '%s' "$line1" | sed 's/^Session transcript to analyze (literal absolute path): //')
  write_findings() { printf '{"session_path":"x","project":"proj-a","turn_count":2,"tool_call_count":0,"tools_used":[],"skills_invoked":[],"models_used":[],"notable_initiatives":[],"findings":[]}' > "$out"; }
  # Emit a real session_path but a deliberately WRONG project (what nondeterministic
  # haiku does), so run.sh's path-based normalization pass has something to correct.
  write_badproject() {
    # Deliberately lie about both fields: the runner must use its source map,
    # not either model-generated guess or the temporary normalized path.
    printf '{"session_path":"%s","harness":"wrong","project":"WRONG-PROJECT","turn_count":2,"tool_call_count":0,"tools_used":[],"skills_invoked":[],"models_used":[],"notable_initiatives":[],"findings":[]}' "$sess" > "$out"
  }
  case "$mode" in
    l1_incomplete) : ;;                 # never write — simulates a worker that exits empty
    l1_badproject) write_badproject ;;  # wrong project + real path — exercises normalization
    l1_flaky)                           # fail the first dispatch per session, succeed on retry
      if [ -f "$out.attempt" ]; then write_findings; else : > "$out.attempt"; fi ;;
    *) write_findings ;;
  esac
  echo done
else
  # ---- Layer 2: aggregator ----
  if [ -n "${MOCK_CAPTURE_DIR:-}" ]; then
    printf '%s' "$input" > "$MOCK_CAPTURE_DIR/l2-stdin.txt"
    printf '%s\n' "$@" > "$MOCK_CAPTURE_DIR/l2-args.txt"
  fi
  rep=$(printf '%s' "$line2" | sed 's/^Write the report to this literal absolute path: //')
  printf '# Autodream — mock\n\nmock aggregate report\n' > "$rep"
  echo "report: $rep"
  echo "mock: 1 session reviewed, 0 findings, 0 edits"
fi
