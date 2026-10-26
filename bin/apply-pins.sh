#!/bin/bash
# Apply Layer 2's memory pins to Mnemopi.
#
#   apply-pins.sh <findings-dir> <target-date>
#
# Reads two files from <findings-dir>:
#   pins.jsonl        one pin per line, written by L2:
#                     {"project","title","body","kind"} plus an optional
#                     "harness": claude|omp|codex, stored as metadata.harness
#   pin-projects.tsv  project<TAB>cwd for every project this run triaged,
#                     written by run.sh. It is the authorization list: a pin
#                     naming any other project is refused.
#
# Each valid pin becomes one `shared-memory call mnemopi_remember`, scoped with
# --cwd to its project's working directory.
#
# Writes, inside <findings-dir>:
#   pins-applied.tsv  <sha1 of the canonical pin><TAB><memory_id> per stored
#                     pin. A pin already listed is skipped, so a rerun never
#                     stores the same memory twice. A failed call writes no row,
#                     so a rerun of the same date retries it; run.sh's
#                     sweep_stranded_pins reruns this for any date in the trailing
#                     week whose counters show failed pins.
#   pins-result.txt   counters, one `key: value` per line.
#
# Exit 2 on bad arguments. Exit 3 when pins-result.txt cannot be cleared or written, so the
# caller does not read an earlier run's counters as this run's; nothing is stored when it
# cannot be cleared. Otherwise exit 0 whatever happened to the pins: a pin must never cost a
# report, and the counters say what went wrong.
#
# SHARED_MEMORY_BIN overrides the CLI (default: `shared-memory` on PATH). The
# test suite points it at a mock so no test writes real memory.
#
# Plan and failure matrix: docs/plans/2026-09-15-mnemopi-pins.md
set -u

if [ $# -ne 2 ] || [ ! -d "${1:-}" ]; then
  echo "usage: apply-pins.sh <findings-dir> <target-date>" >&2
  exit 2
fi

FINDINGS_DIR=$1
TARGET_DATE=$2
PINS="$FINDINGS_DIR/pins.jsonl"
PROJECTS="$FINDINGS_DIR/pin-projects.tsv"
LEDGER="$FINDINGS_DIR/pins-applied.tsv"
RESULT="$FINDINGS_DIR/pins-result.txt"
SM="${SHARED_MEMORY_BIN:-shared-memory}"

# Counters from an earlier run of this date must never stand in for this run's if the
# write below fails; run.sh logs whatever file it finds.
if ! rm -f "$RESULT" 2>/dev/null || [ -e "$RESULT" ]; then
  echo "apply-pins: could not clear $RESULT; storing nothing so the old counters cannot pass for this run's" >&2
  exit 3
fi

# A pin is valid when this filter prints it. Anything else, including a line
# holding two JSON values, prints nothing.
VALID='select(type == "object")
  | select((.project | type) == "string" and (.project | length) > 0
           and (.project | test("[\\t\\n\\r]") | not))
  | select((.title | type) == "string" and (.title | test("\\S"))
           and (.title | length) <= 150 and (.title | test("[\\n\\r]") | not))
  | select((.body | type) == "string" and (.body | test("\\S"))
           and (.body | length) <= 4000)
  | select(.kind as $k | ["correction", "preference", "fact", "decision"] | any(. == $k))
  | select((has("harness") | not) or (.harness as $h | ["claude", "omp", "codex"] | any(. == $h)))
  | {project, title, body, kind} + (if has("harness") then {harness} else {} end)'

RESULT_FAILED=0
total=0 applied=0 duplicate=0 invalid=0 rejected_project=0 no_cwd=0 failed=0 unledgered=0 cli_missing=0 unreadable=0 unsupported_harness=0

write_result() {
  {
    printf 'pins_total: %s\n' "$total"
    printf 'pins_applied: %s\n' "$applied"
    printf 'pins_duplicate: %s\n' "$duplicate"
    printf 'pins_invalid: %s\n' "$invalid"
    printf 'pins_rejected_project: %s\n' "$rejected_project"
    printf 'pins_no_cwd: %s\n' "$no_cwd"
    printf 'pins_failed: %s\n' "$failed"
    printf 'pins_unledgered: %s\n' "$unledgered"
    printf 'pins_cli_missing: %s\n' "$cli_missing"
    printf 'pins_unreadable: %s\n' "$unreadable"
    printf 'pins_unsupported_harness: %s\n' "$unsupported_harness"
  } > "$RESULT.tmp" && mv "$RESULT.tmp" "$RESULT" || RESULT_FAILED=1
  echo "apply-pins: total=$total applied=$applied duplicate=$duplicate invalid=$invalid rejected_project=$rejected_project no_cwd=$no_cwd failed=$failed unledgered=$unledgered cli_missing=$cli_missing unreadable=$unreadable"
}

# $1=project -> prints its cwd column; exit 1 when the run never saw the project.
# ENVIRON, not awk -v: -v expands backslash escapes, so a model-written project
# could match a row it does not name.
project_cwd() {
  local row
  row=$(P="$1" awk -F'\t' '$1 == ENVIRON["P"] { print "y\t" $2; exit }' "$PROJECTS" 2>/dev/null)
  [ -n "$row" ] || return 1
  printf '%s' "${row#y$'\t'}"
}

# $1=line -> prints one outcome: invalid rejected_project no_cwd duplicate failed unledgered applied
apply_line() {
  local canon project cwd hash ctx bank payload out rc id
  canon=$(jq -cS -s "if length == 1 then .[0] | $VALID else empty end" <<<"$1" 2>/dev/null)
  [ -n "$canon" ] || { echo invalid; return; }
  # A tagged pin is only safe when the installed shared-memory filters on the tag at
  # startup. Without that it would load into every harness, so it is held, not stored.
  if [ "$GATE_OK" != 1 ] && [ "$(jq -r 'has("harness")' <<<"$canon")" = true ]; then echo unsupported_harness; return; fi
  project=$(jq -r .project <<<"$canon")
  cwd=$(project_cwd "$project") || { echo rejected_project; return; }
  if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then echo no_cwd; return; fi
  # mnemopi_remember takes its bank from the payload, then MNEMOPI_MCP_BANK, then
  # "default", and never from --cwd. Without the project's retainBank named here, every
  # pin lands in the global store. No bank means no store.
  # Captured first so the context call's own exit status counts; piped straight into jq,
  # only jq's status would.
  ctx=$("$SM" context --cwd "$cwd" </dev/null 2>/dev/null) || { echo failed; return; }
  bank=$(jq -er '.retainBank | strings | select(length > 0)' <<<"$ctx" 2>/dev/null) || { echo failed; return; }
  # The bank is part of the identity: a forced rebuild can resolve a project to another
  # directory (/tmp/a_b and /tmp/a-b encode alike), and a pin stored in one bank is not
  # stored in the other.
  hash=$(printf '%s\n%s' "$bank" "$canon" | shasum -a 1 | cut -d' ' -f1)
  # `cut` succeeds even when shasum dies, which leaves an empty hash. Ledgered, an empty
  # hash would make every later pin in the file look like a duplicate.
  [[ $hash =~ ^[0-9a-f]{40}$ ]] || { echo failed; return; }
  # An unreadable ledger reads the same as "not stored yet" below, which would store the
  # pin again. When duplicates cannot be ruled out, store nothing.
  if [ -e "$LEDGER" ] && [ ! -r "$LEDGER" ]; then echo failed; return; fi
  if [ -f "$LEDGER" ] && cut -f1 "$LEDGER" | grep -qxF "$hash"; then echo duplicate; return; fi
  payload=$(jq -cn --argjson pin "$canon" --arg date "$TARGET_DATE" --arg bank "$bank" '{
    bank: $bank,
    content: ($pin.title + "\n\n" + $pin.body),
    source: "cc-autodream",
    importance: 0.7,
    metadata: ({kind: $pin.kind, project: $pin.project, autodream_date: $date, origin: "cc-autodream"} + (if $pin.harness then {harness: $pin.harness} else {} end))
  }')
  # </dev/null: the caller reads pins.jsonl on a separate fd, but a CLI that
  # reads stdin must never be able to swallow the pins after this one.
  # The exit status cannot decide this on its own. shared-memory exits 1 with status
  # mutation_committed_journal_incomplete when the write committed but its journal append
  # failed; that memory exists and has an id, and calling it a failure would store it
  # again on the next run.
  out=$("$SM" call mnemopi_remember "$payload" --cwd "$cwd" </dev/null)
  rc=$?
  # "stored" counts only with exit 0. mutation_committed_journal_incomplete is the one
  # status that may pair a nonzero exit with a stored memory; anything else is a failure
  # and stays retryable. An empty id is not a stored memory anyone can find; ledgered, it
  # would block every retry.
  id=$(jq -er --argjson rc "$rc" '
    select((.status == "stored" and $rc == 0) or .status == "mutation_committed_journal_incomplete")
    | .memory_id | strings | select(length > 0)' <<<"$out" 2>/dev/null) || { echo failed; return; }
  if [ "$(jq -r .status <<<"$out" 2>/dev/null)" = "mutation_committed_journal_incomplete" ]; then
    echo "apply-pins: stored $id, but shared-memory reported mutation_committed_journal_incomplete" >&2
  fi
  # The memory is already stored. A ledger row that cannot be written means the next run
  # stores it again, so this is its own outcome and never counts as applied. The id goes
  # to the run log so the duplicate can be found and removed.
  if ! printf '%s\t%s\n' "$hash" "$id" >> "$LEDGER" 2>/dev/null; then
    echo "apply-pins: stored $id but could not write $LEDGER; a rerun will store this pin again" >&2
    echo unledgered
    return
  fi
  echo applied
}

if [ ! -e "$PINS" ]; then
  write_result
  exit $((RESULT_FAILED * 3))
fi

# Read the file once, and check that read. A redirect on the loop below that fails to
# open runs zero iterations, and the counters would say L2 proposed no pins.
if ! CONTENT=$(cat -- "$PINS" 2>/dev/null); then
  unreadable=1
  write_result
  echo "apply-pins: could not read $PINS; pins stay there" >&2
  exit $((RESULT_FAILED * 3))
fi

if ! command -v "$SM" >/dev/null 2>&1; then
  cli_missing=1
  total=$(grep -c '[^[:space:]]' <<<"$CONTENT" || true)
  write_result
  echo "apply-pins: $SM not found; pins stay in $PINS" >&2
  exit $((RESULT_FAILED * 3))
fi

# Capability probe. A bare `--host` fails closed in a shared-memory built with the harness
# gate (agent-mnemopi PR 12) and is ignored by an older one, so the error text tells them
# apart without storing anything.
GATE_OK=0
case $("$SM" startup --host </dev/null 2>/dev/null) in
  *"--host needs a harness name"*) GATE_OK=1 ;;
esac

while IFS= read -r line <&3 || [ -n "$line" ]; do
  case $line in *[![:space:]]*) ;; *) continue ;; esac
  total=$((total + 1))
  case $(apply_line "$line") in
    applied)          applied=$((applied + 1)) ;;
    duplicate)        duplicate=$((duplicate + 1)) ;;
    invalid)          invalid=$((invalid + 1)) ;;
    rejected_project) rejected_project=$((rejected_project + 1)) ;;
    no_cwd)           no_cwd=$((no_cwd + 1)) ;;
    unledgered)       unledgered=$((unledgered + 1)) ;;
    unsupported_harness) unsupported_harness=$((unsupported_harness + 1)) ;;
    *)              failed=$((failed + 1)) ;;
  esac
done 3<<<"$CONTENT"

write_result
exit $((RESULT_FAILED * 3))
