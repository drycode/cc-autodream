#!/bin/bash
# Mock `claude` binary for cc-autodream integration tests.
#
# run.sh invokes the real claude CLI for both layers. Here we stand in for it:
# read the prompt on stdin, find the two literal-path lines run.sh inlined, and
# write (or deliberately don't write) the expected output file — no model, no
# network. Which layer we are is decided by line 1 of the prompt.
#
# Env knobs (all optional):
#   MOCK_MODE=good           write findings (L1) / print the report on stdout (L2), ending with
#                            the AUTODREAM_REPORT_END sentinel. [default]
#   MOCK_MODE=l1_partial_then_stall  exactly ONE session ever succeeds (claimed via an
#                            atomic mkdir under MOCK_STATE_DIR, which the test must set);
#                            round 1 recovers something, every later round recovers
#                            nothing. Pins the circuit breaker's no-progress streak.
#   MOCK_MODE=l1_incomplete  L1 writes nothing (simulates a worker that exits
#                            without producing JSON); L2 still writes its report.
#   MOCK_MODE=l1_silent      L1 writes nothing and prints nothing, exit 0: the real
#                            2026-09-13 omp death. l1_incomplete still prints "done".
#   MOCK_MODE=l1_malformed   L1 writes a non-empty file that is not JSON.
#   MOCK_MODE=l1_wrongtype   L1 writes {"findings":"oops"}: present, but not an array.
#   MOCK_MODE=l1_noisy_fail  L1 writes nothing, says why on stdout, exits 7.
#   MOCK_MODE=l1_context_overflow  L1 writes nothing, prints a context-size refusal,
#                            and exits 7. This must count as size even though the
#                            diagnostic also starts with "provider error".
#   MOCK_MODE=l1_nested_error  L1 writes a SUCCESSFUL findings file with an "error" key nested
#                            inside a finding. Only a top-level error key marks a failed triage.
#   MOCK_MODE=l1_provider_refusal  L1 writes nothing, prints the Z.ai insufficient-balance
#                            429 (code 1113) and exits 1. The network is fine, so this
#                            must defer the date like an outage and never leave a stub.
#   MOCK_MODE=l1_provider_402  Same, in DeepSeek's wording: "Error code: 402 - Insufficient
#                            Balance". classify_failure has no 402 pattern, so this proves
#                            the permanent check does not depend on it.
#   MOCK_MODE=l1_exit124     L1 exits 124 immediately; MOCK_MODE=l1_exit137 SIGKILLs
#                            itself. Both are what GNU timeout returns for a real
#                            deadline, so they prove classification is not by rc alone.
#   MOCK_MODE=l1_hang        L1 never exits and leaves a child behind, which is the
#                            shape of the 2026-08-19/08-22 wedge. Pair with a small
#                            AUTODREAM_L1_TIMEOUT and MOCK_HANG_PIDS=<file> to assert
#                            the child was reaped with the process group.
#   MOCK_MODE=l2_partial_marker  L2 prints a COMPLETE-LOOKING report (it carries the
#                            open-questions marker) but no sentinel, then exits 0.
#   MOCK_MODE=l2_exit143 / l2_exit137  L2 prints "Execution error" and exits 143 / 137 with no
#                            report: the signal-shaped death of issue 42.
#   MOCK_MODE=l2_fail        L2 prints no report and exits 1 (simulates the
#                            aggregator dying to a mid-run sleep). L1 is unaffected.
#                            Pair with AUTODREAM_L2_ATTEMPTS=1 so the test doesn't
#                            sit through the retry loop.
#   MOCK_MODE=pins           L1 writes a real session_path (like l1_badproject); L2
#                            writes a complete report plus one pins.jsonl pin for proj-a.
#   MOCK_MODE=pins_partial   as pins, but the report is truncated (like l2_partial).
#   MOCK_MODE=pins_forged    L1 writes session_path=$MOCK_FORGED_SESSION, a session it was
#                            never given; L2 pins $MOCK_PIN_PROJECT (default proj-a).
#   MOCK_MODE=pins_tamper    as pins, and L2 also appends $MOCK_FORGED_SESSION to sessions.txt,
#                            sessions-source.txt and a findings JSON, as an injected L2 could.
#   MOCK_MODE=pins_tamper_l1 the same tampering, done by L1 instead of L2.
#   MOCK_MODE=pins_ledger_wipe  as pins, and L1 also empties findings/<date>/pins-applied.tsv.
#   MOCK_MODE=pins_unterminated  as pins, but the pin block has no AUTODREAM_PINS_END line.
#   MOCK_MODE=pins_in_body   the report BODY quotes the pin markers and a pin line; no block after
#                            the sentinel. Nothing may be stored.
#   MOCK_TRIAGE_MODE=fail|nosentinel|empty  the dream-triage call (bin/triage-dream.sh) fails, is cut off
#                            before the sentinel, or delivers nothing. It writes triage-*.txt to
#                            MOCK_CAPTURE_DIR, never l2-*.
#   MOCK_MODE=chunked        L1 answers as one chunk of a longer session (chunk I of N is read from
#                            the chunk note in the prompt): goal-I, a finding unique to the chunk
#                            and one shared by every chunk, outcome fully_achieved on the last
#                            chunk only. A call with no chunk note is answered as in good mode.
#   MOCK_FAIL_CHUNK=N        chunk N fails (every attempt, or only the first with MOCK_FAIL_ONCE=1).
#   MOCK_FAIL_KIND=silent|noisy|context|refusal   how it fails: exit 0 with nothing at all, a
#                            429 on stdout with exit 7, a context overflow with exit 7, or the
#                            Z.ai insufficient-balance refusal with exit 1 (default silent).
#   MOCK_BAD_CHUNK=N         chunk N answers with the WRONG thing, once per output path.
#   MOCK_BAD_KIND=error|nofindings|typed|two   what that wrong answer is (default error): the L1
#                            error object, an object with no findings, findings a string, or two
#                            JSON values in one file.
#   MOCK_TRANSCRIPT_LOG=<file>  append "<transcript path><TAB><its bytes>" for every L1 call, so a
#                            test can prove how much a worker was handed.
#   MOCK_CAPTURE_DIR=<dir>   dump each layer's stdin + argv to <dir>/l{1,2}-*.txt
#                            so tests can assert on the exact prompt framing.
#   MOCK_CALL_LOG=<file>     append the L1 output path for every invocation of
#                            this mock, one per line — lets a test prove the
#                            model was (or was not) invoked for a given session
#                            (e.g. a noise-gated session should never appear).

input=$(cat)
mode="${MOCK_MODE:-good}"

# $1=findings dir. Adds $MOCK_FORGED_SESSION to the runner's worklist files, the way a
# prompt-injected model with the Write tool could.
tamper_worklist() {
  local h
  h=$(printf '%s' "$MOCK_FORGED_SESSION" | shasum -a 1 | cut -c1-12)
  printf '%s\n' "$MOCK_FORGED_SESSION" >> "$1/sessions.txt"
  printf '%s\tclaude\n' "$h" >> "$1/sessions-source.txt"
  printf '{"session_path":"%s","findings":[]}' "$MOCK_FORGED_SESSION" > "$1/$h.json"
}
line1=$(printf '%s\n' "$input" | sed -n '1p')
line2=$(printf '%s\n' "$input" | sed -n '2p')

# ---- Pre-fanout auth warmup ----
# run.sh pipes the single word `ping` before dispatching L1. It is neither layer, and
# without this branch it fell through to the L2 aggregator below, where line2 is empty and
# the report destination resolves to nothing. Handle it first and explicitly.
#
# In the failure modes it answers the way a dead omp does — exit 0, NOTHING on stdout, the
# usual chatter on stderr. That is the whole signature the warmup exists to catch, and a
# fixture that always printed something made `l1_warmup: ok` unfalsifiable.
if [ "$line1" = "ping" ]; then
  printf 'Working...\n' >&2
  case "$mode" in
    l1_incomplete|l1_silent|l1_noisy_fail|l1_context_overflow|l1_hang|l1_exit124|l1_exit137) : ;;
    # exit 0 with a diagnostic on stdout instead of the requested reply
    warmup_diag) echo "error: model deepseek/deepseek-flash is not available" ;;
    *) echo ok ;;
  esac
  exit 0
fi

if printf '%s' "$line1" | grep -q '^Session transcript'; then
  # ---- Layer 1: triage worker ----
  if [ -n "${MOCK_CAPTURE_DIR:-}" ]; then
    printf '%s' "$input" > "$MOCK_CAPTURE_DIR/l1-stdin.txt"
    printf '%s\n' "$@" > "$MOCK_CAPTURE_DIR/l1-args.txt"
    # The engine environment the dispatcher gave this worker, one NAME=value per line, so a test
    # can tell an adapter-provided variable from one inherited by accident.
    env | grep -E '^(CLAUDE_CODE_DISABLE_CLAUDE_MDS|DISABLE_TELEMETRY|DISABLE_ERROR_REPORTING)=' | sort > "$MOCK_CAPTURE_DIR/l1-env.txt"
  fi
  out=$(printf '%s' "$line2" | sed 's/^Write your findings JSON to this literal absolute path: //')
  sess=$(printf '%s' "$line1" | sed 's/^Session transcript to analyze (literal absolute path): //')
  [ -n "${MOCK_CALL_LOG:-}" ] && printf '%s\n' "$out" >> "$MOCK_CALL_LOG"
  # What the worker was pointed at, so a test can tell the normalized copy from the raw tree.
  [ -n "${MOCK_CAPTURE_DIR:-}" ] && [ -r "$sess" ] && cp "$sess" "$MOCK_CAPTURE_DIR/l1-read-$(basename "$out" .json).txt"
  [ -n "${MOCK_CAPTURE_DIR:-}" ] && printf '%s\n' "$@" > "$MOCK_CAPTURE_DIR/l1-args-$(basename "$out" .json).txt"
  [ -n "${MOCK_CAPTURE_DIR:-}" ] && printf '%s' "$input" > "$MOCK_CAPTURE_DIR/l1-stdin-$(basename "$out" .json).txt"
  [ -n "${MOCK_TRANSCRIPT_LOG:-}" ] && printf '%s\t%s\n' "$sess" "$(wc -c < "$sess" 2>/dev/null | tr -d ' ')" >> "$MOCK_TRANSCRIPT_LOG"
  # Chunk I of N, from the chunk note the runner appends to the prompt of one chunk of a longer
  # session. Empty for an ordinary session.
  ci=""; cn=""
  read -r ci cn <<< "$(printf '%s' "$input" | sed -n 's/.*chunk \([0-9][0-9]*\) of \([0-9][0-9]*\) of ONE session.*/\1 \2/p' | head -1)"
  write_chunked() { # $1=i $2=n
    jq -cn --argjson i "$1" --argjson n "$2" '{session_path:"x",project:"proj-a",turn_count:2,tool_call_count:0,tools_used:[],
      skills_invoked:[],models_used:[],notable_initiatives:["initiative-\($i)"],underlying_goal:"goal-\($i)",
      outcome:(if $i == $n then "fully_achieved" else "partially_achieved" end),
      satisfaction_signals:{happy:0,satisfied:1,dissatisfied:0,frustrated:0},instructions_given:[],
      findings:[{category:"permission_prompt",severity:"low",what:"finding-from-chunk-\($i)",evidence_excerpt:"x",proposed_rule:"y"},
                {category:"other",severity:"low",what:"shared across chunks",evidence_excerpt:"x",proposed_rule:"y"}]}' > "$out"
  }
  if [ -n "$ci" ] && [ "$ci" = "${MOCK_FAIL_CHUNK:-0}" ] && { [ -z "${MOCK_FAIL_ONCE:-}" ] || [ ! -f "$out.failed" ]; }; then
    : > "$out.failed"
    case "${MOCK_FAIL_KIND:-silent}" in
      silent) exit 0 ;;
      noisy) echo "provider error: 429 rate_limit_exceeded"; exit 7 ;;
      context) echo "provider error: 400 context_length_exceeded: prompt is too long"; exit 7 ;;
      refusal) echo '429 {"type":"error","error":{"type":"rate_limit_error","code":"1113","message":"[1113][Insufficient balance or no resource package. Please recharge.]"}}'; exit 1 ;;
    esac
  fi
  if [ -n "$ci" ] && [ "$ci" = "${MOCK_BAD_CHUNK:-0}" ] && [ ! -f "$out.bad" ]; then
    : > "$out.bad"
    case "${MOCK_BAD_KIND:-error}" in
      error) printf '{"session_path":"x","error":"could not read","findings":[]}' > "$out" ;;
      nofindings) printf '{"session_path":"x"}' > "$out" ;;
      typed) printf '{"session_path":"x","findings":"oops"}' > "$out" ;;
      two) printf '{"error":"x","findings":[]}\n{"session_path":"x","findings":[]}\n' > "$out" ;;
    esac
    echo done
    exit 0
  fi
  write_findings() { printf '{"session_path":"x","project":"proj-a","turn_count":2,"tool_call_count":0,"tools_used":[],"skills_invoked":[],"models_used":[],"notable_initiatives":[],"underlying_goal":null,"outcome":"fully_achieved","satisfaction_signals":{"happy":0,"satisfied":1,"dissatisfied":0,"frustrated":0},"instructions_given":["always run tests after edits"],"findings":[]}' > "$out"; }
  # Emit a real session_path but a deliberately WRONG project (what nondeterministic
  # haiku does), so run.sh's path-based normalization pass has something to correct.
  write_badproject() { printf '{"session_path":"%s","project":"WRONG-PROJECT","turn_count":2,"tool_call_count":0,"tools_used":[],"skills_invoked":[],"models_used":[],"notable_initiatives":[],"findings":[]}' "$sess" > "$out"; }
  case "$mode" in
    chunked) if [ -n "$ci" ]; then write_chunked "$ci" "$cn"; else write_findings; fi ;;
    l1_incomplete) : ;;                 # never write — simulates a worker that exits empty
    l1_silent) exit 0 ;;                # never write AND print nothing: the 2026-09-13 omp
                                        # death (first-turn recall), exit 0 with empty stdout.
                                        # l1_incomplete still echoes "done" below, so it is not.
    l1_malformed)                       # non-empty output that is not a findings JSON.
      # The runner used to accept any non-empty file as success, delete both diagnostics,
      # and hand this to L2 on the final round.
      printf 'this is not json at all\n' > "$out"
      echo done
      exit 0 ;;
    l1_wrongtype)                       # .findings present but a STRING, not an array.
      # jq -e .findings is truthy for this, so it used to pass both the idempotency read
      # and the outbound validation and reach L2 as a successful result.
      printf '{"session_path":"x","findings":"oops"}' > "$out"
      echo done
      exit 0 ;;
    l1_noisy_fail)                      # writes nothing, but says WHY on stdout and exits
      # nonzero. This is the real shape: omp puts its diagnosis on stdout and only
      # "Working..." on stderr, and run.sh sent stdout to /dev/null, so every failure
      # arrived looking identical. Pins the exit-code and stdout capture.
      echo "provider error: 429 rate_limit_exceeded"
      exit 7 ;;
    l1_context_overflow)
      echo "provider error: 400 context_length_exceeded: prompt is too long"
      exit 7 ;;
    l1_rewrite_source)                  # a hostile worker: points every session at an engine that is not claude
      write_findings
      awk -F'\t' 'BEGIN{OFS="\t"} {print $1, "evil"}' "$(dirname "$out")/sessions-source.txt" > "$(dirname "$out")/sessions-source.txt.new" \
        && mv "$(dirname "$out")/sessions-source.txt.new" "$(dirname "$out")/sessions-source.txt" ;;
    l1_provider_refusal)
      echo '429 {"type":"error","error":{"type":"rate_limit_error","code":"1113","message":"[1113][Insufficient balance or no resource package. Please recharge.]"}}'
      exit 1 ;;
    l1_provider_402)
      echo "Error code: 402 - {'error': {'message': 'Insufficient Balance', 'type': 'unknown_error'}}"
      exit 1 ;;
    l1_exit124) exit 124 ;;             # intrinsic 124, no deadline involved. GNU timeout
                                        # propagates a child's own status, so this arrives
                                        # looking exactly like a timeout; only elapsed tells
                                        # them apart.
    l1_exit137) kill -9 $$ ;;           # intrinsic 137, same reasoning
    l1_hang)                            # never exit, and leave a child behind. The child is
      # the point: it outlives a kill aimed at this process alone, so a test that
      # finds it gone proves the timeout signalled the whole process group, which
      # is what stops the real node_repl/mnemopi_embed orphans from piling up.
      sleep 600 & printf '%s\n' "$!" >> "${MOCK_HANG_PIDS:-/dev/null}"
      sleep 600 ;;
    l1_partial_then_stall)
      # Exactly one session ever succeeds; every other one fails forever. Round 1 therefore
      # RECOVERS something while later rounds recover nothing — the shape that exposed the
      # circuit breaker's off-by-one, where comparing a round's ending count against the
      # previous round's ending count called two rounds barren as soon as the second was.
      #
      # mkdir, not a file test: workers run at FANOUT 8, so a test-then-create would let
      # several of them win the claim at once and the fixture would recover a different
      # number of sessions per run. mkdir succeeds for exactly one caller.
      if mkdir "${MOCK_STATE_DIR:?l1_partial_then_stall needs MOCK_STATE_DIR}/one-succeeded" 2>/dev/null; then
        write_findings
      fi ;;
    l1_nested_error)                    # a real finding that happens to carry an error key
      printf '{"session_path":"x","project":"proj-a","findings":[{"category":"tool_loop","error":"ENOENT while reading a file","severity":"low"}]}' > "$out"
      echo done ;;
    l1_badproject|pins|pins_partial|pins_tamper) write_badproject ;;  # wrong project + real path — exercises normalization
    pins_tamper_l1) write_badproject; tamper_worklist "$(dirname "$out")" ;;
    pins_ledger_wipe) write_badproject; : > "$(dirname "$out")/pins-applied.tsv" ;;  # a worker empties the ledger
    pins_forged)                        # session_path names a session this worker was never given
      printf '{"session_path":"%s","project":"WRONG-PROJECT","findings":[]}' "$MOCK_FORGED_SESSION" > "$out" ;;
    l1_flaky)                           # fail the first dispatch per session, succeed on retry
      if [ -f "$out.attempt" ]; then write_findings; else : > "$out.attempt"; fi ;;
    *) write_findings ;;
  esac
  echo done
elif printf '%s' "$input" | grep -q '^# Dream triage worker'; then
  # ---- Dream triage (bin/triage-dream.sh): its own capture files, never l2-*, so a test that
  # asserts on L2's args or stdin cannot be overwritten by this call ----
  if [ -n "${MOCK_CAPTURE_DIR:-}" ]; then
    printf '%s' "$input" > "$MOCK_CAPTURE_DIR/triage-stdin.txt"
    printf '%s\n' "$@" > "$MOCK_CAPTURE_DIR/triage-args.txt"
  fi
  tdir=$(printf '%s' "$line1" | sed 's/^Findings directory to aggregate (literal absolute path): //')
  case "${MOCK_TRIAGE_MODE:-good}" in
    fail) echo "mock: triage failed" >&2; exit 1 ;;
    nosentinel) printf '# Dream triage - mock\n\ncut off mid-w' ; exit 0 ;;
    empty) echo "AUTODREAM_REPORT_END"; exit 0 ;;
  esac
  # Echo what grounding said about each claim, so a test can see the data reached the model.
  printf '# Dream triage - mock\n\n'
  [ -r "$tdir/grounding.json" ] && jq -r '.claims[] | "- \(.kind) \(.claim) \(.status)"' "$tdir/grounding.json"
  echo "AUTODREAM_REPORT_END"
  echo "report: ignored"
else
  # ---- Layer 2: aggregator ----
  if [ -n "${MOCK_CAPTURE_DIR:-}" ]; then
    printf '%s' "$input" > "$MOCK_CAPTURE_DIR/l2-stdin.txt"
    printf '%s\n' "$@" > "$MOCK_CAPTURE_DIR/l2-args.txt"
  fi
  rep=$(printf '%s' "$line2" | sed 's/^Report destination (literal absolute path): //')
  case "$mode" in
    l2_exit143) printf 'Execution error'; exit 143 ;;
    l2_exit137) printf 'Execution error'; exit 137 ;;
  esac
  if [ "$mode" = "l2_fail" ]; then
    echo "mock: aggregator failed" >&2
    exit 1
  fi
  case "$mode" in
    pins|pins_partial|pins_forged|pins_tamper|pins_tamper_l1|pins_unterminated|pins_in_body|pins_ledger_wipe) writes_pins=1 ;;
    *) writes_pins=0 ;;
  esac
  fdir=$(printf '%s' "$line1" | sed 's/^Findings directory to aggregate (literal absolute path): //')
  [ "$mode" = "pins_tamper" ] && tamper_worklist "$fdir"
  pin_line=$(printf '{"project":"%s","title":"Mock lesson","body":"Mock evidence and rule.","kind":"correction"}' "${MOCK_PIN_PROJECT:-proj-a}")
  # l2_partial: a NON-EMPTY capture with no AUTODREAM_REPORT_END sentinel, what a mid-output
  # kill leaves behind. run.sh keeps it as a degraded report and retries; `-s` cannot tell it
  # from a good report, which is why delivery is gated on the sentinel.
  if [ "$mode" = "l2_partial" ] || [ "$mode" = "pins_partial" ]; then
    printf '# Autodream — mock\n\n## Top patterns\n\n1. truncated mid-w'
    [ "$writes_pins" = 1 ] && printf '\nAUTODREAM_PINS_BEGIN\n%s\nAUTODREAM_PINS_END\n' "$pin_line"
    echo "mock: partial stdout, no sentinel" >&2
    exit 0
  fi
  # l2_partial_marker: an otherwise complete report (it carries the open-questions marker
  # report_complete() checks) but no sentinel. The marker alone must not count as delivery.
  if [ "$mode" = "l2_partial_marker" ]; then
    printf '# Autodream — mock\n\nmock aggregate report\n\n<!-- autodream:open-questions=0 -->\n'
    exit 0
  fi
  # pins_in_body: the report itself quotes the pin markers. Only the block after the LAST
  # sentinel may count, so this must store nothing.
  if [ "$mode" = "pins_in_body" ]; then
    printf '# Autodream — mock\n\nquoted:\nAUTODREAM_PINS_BEGIN\n%s\nAUTODREAM_PINS_END\n\n<!-- autodream:open-questions=0 -->\nAUTODREAM_REPORT_END\nreport: %s\n' "$pin_line" "$rep"
    exit 0
  fi
  # The open-questions marker is part of the real contract (PROMPT.md mandates it) and run.sh
  # treats its absence as a truncated report, so the good path emits it too, on stdout, ending
  # with the sentinel the runner strips, then the optional pin block.
  printf '# Autodream — mock\n\nmock aggregate report\n\n<!-- autodream:open-questions=0 -->\n'
  echo "AUTODREAM_REPORT_END"
  if [ "$writes_pins" = 1 ]; then
    if [ "$mode" = "pins_unterminated" ]; then
      printf 'AUTODREAM_PINS_BEGIN\n%s\n' "$pin_line"
    else
      printf 'AUTODREAM_PINS_BEGIN\n%s\nAUTODREAM_PINS_END\n' "$pin_line"
    fi
  fi
  echo "report: $rep"
  echo "sessions reviewed: 1"
  echo "findings: 0"
fi
