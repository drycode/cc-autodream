#!/bin/bash
# Unit tests for bin/apply-pins.sh: L2's pins.jsonl into Mnemopi via shared-memory.
#
# One test per row of the failure matrix in docs/plans/2026-09-15-mnemopi-pins.md
# (rows A1-A24). shared-memory is always tests/mock-shared-memory.sh, so nothing
# here can write real memory.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
AP="$REPO/bin/apply-pins.sh"
SM="$HERE/mock-shared-memory.sh"
DATE=2020-01-02

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/appins.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# Fresh findings dir. proj-a resolves to a real dir, proj-b has no cwd, and
# proj-c names a dir that does not exist.
setup(){
  T=$(mktemp -d "$ROOT/t.XXXXXX")
  F="$T/findings"
  mkdir -p "$F" "$T/work-a"
  printf 'proj-a\t%s\nproj-b\t\nproj-c\t%s\n' "$T/work-a" "$T/no-such-dir" > "$F/pin-projects.tsv"
}
pin(){ # $1=project $2=title $3=body [$4=kind]
  jq -cn --arg p "$1" --arg t "$2" --arg b "$3" --arg k "${4:-correction}" \
    '{project:$p,title:$t,body:$b,kind:$k}'
}
run_ap(){
  SHARED_MEMORY_BIN="${SM_BIN:-$SM}" MOCK_SM_LOG="$T/calls.jsonl" \
    MOCK_SM_MODE="${MOCK_SM_MODE:-ok}" bash "$AP" "$F" "$DATE" > "$T/out" 2>&1
  RC=$?
}
stat_of(){ sed -n "s/^$1: //p" "$F/pins-result.txt" 2>/dev/null; }
calls(){ if [ -f "$T/calls.jsonl" ]; then wc -l < "$T/calls.jsonl" | tr -d ' '; else echo 0; fi; }
ledger_rows(){ if [ -f "$F/pins-applied.tsv" ]; then wc -l < "$F/pins-applied.tsv" | tr -d ' '; else echo 0; fi; }

echo "# A1: no pins.jsonl"
setup; run_ap
assert_eq "$RC" "0" "exits 0"
assert_eq "$(stat_of pins_total)" "0" "pins_total is 0"
assert_eq "$(calls)" "0" "no call"
assert_eq "$(ledger_rows)" "0" "no ledger"

echo "# A2: shared-memory not found"
setup; pin proj-a "Title" "Body" > "$F/pins.jsonl"
SM_BIN="$T/nonexistent/shared-memory" run_ap
assert_eq "$RC" "0" "exits 0"
assert_eq "$(stat_of pins_cli_missing)" "1" "pins_cli_missing is 1"
assert_eq "$(stat_of pins_applied)" "0" "nothing applied"
assert_eq "$(ledger_rows)" "0" "no ledger"
[ -s "$F/pins.jsonl" ] && ok "pins.jsonl left in place" || no "pins.jsonl left in place"

echo "# A3 + A7: one valid pin, blank lines ignored"
setup; { echo; pin proj-a "Use trash over rm" "Body text"; echo; } > "$F/pins.jsonl"
run_ap
assert_eq "$RC" "0" "exits 0"
assert_eq "$(calls)" "1" "one call"
c=$(head -1 "$T/calls.jsonl" 2>/dev/null)
assert_eq "$(jq -r .tool <<<"$c" 2>/dev/null)" "mnemopi_remember" "calls mnemopi_remember"
assert_eq "$(jq -r .cwd <<<"$c" 2>/dev/null)" "$T/work-a" "--cwd is the project's resolved dir"
assert_eq "$(jq -r .payload.content <<<"$c" 2>/dev/null)" "$(printf 'Use trash over rm\n\nBody text')" "content is title, blank line, body"
assert_eq "$(jq -r .payload.bank <<<"$c" 2>/dev/null)" "bank-work-a" "the project's own bank, from shared-memory context"
assert_eq "$(jq -r .payload.source <<<"$c" 2>/dev/null)" "cc-autodream" "source is cc-autodream"
assert_eq "$(jq -r .payload.metadata.project <<<"$c" 2>/dev/null)" "proj-a" "metadata.project"
assert_eq "$(jq -r .payload.metadata.kind <<<"$c" 2>/dev/null)" "correction" "metadata.kind"
assert_eq "$(jq -r .payload.metadata.autodream_date <<<"$c" 2>/dev/null)" "$DATE" "metadata.autodream_date"
assert_eq "$(stat_of pins_total)" "1" "blank lines are not pins"
assert_eq "$(stat_of pins_invalid)" "0" "blank lines are not invalid"
assert_eq "$(stat_of pins_applied)" "1" "pins_applied is 1"
assert_eq "$(cut -f2 "$F/pins-applied.tsv" 2>/dev/null)" "m1" "ledger row holds the memory id"

echo "# A4: rerun over the same pins"
run_ap
assert_eq "$(calls)" "1" "no second call"
assert_eq "$(stat_of pins_duplicate)" "1" "pins_duplicate is 1"
assert_eq "$(stat_of pins_applied)" "0" "nothing newly applied"
assert_eq "$(ledger_rows)" "1" "ledger unchanged"

echo "# A5: an unparseable line does not stop the valid one"
setup; { echo '{not json'; pin proj-a "Good" "Body"; } > "$F/pins.jsonl"
run_ap
assert_eq "$(stat_of pins_invalid)" "1" "pins_invalid is 1"
assert_eq "$(stat_of pins_applied)" "1" "the valid pin applied"

echo "# A6: schema violations"
setup
long=$(printf 'x%.0s' $(seq 1 151))
{
  jq -cn '{project:"proj-a",body:"b",kind:"correction"}'
  pin proj-a "Title" "   "
  pin proj-a "Title" "Body" bogus
  pin proj-a "$long" "Body"
  pin proj-a "$(printf 'two\nlines')" "Body"
} > "$F/pins.jsonl"
run_ap
assert_eq "$(stat_of pins_invalid)" "5" "all five rejected"
assert_eq "$(calls)" "0" "no call"

echo "# A8: project not observed in this run"
setup; pin proj-z "Title" "Body" > "$F/pins.jsonl"
run_ap
assert_eq "$(stat_of pins_rejected_project)" "1" "pins_rejected_project is 1"
assert_eq "$(calls)" "0" "no call"

echo "# A9: project observed but cwd unresolvable"
setup; { pin proj-b "Title" "Body"; pin proj-c "Title" "Body"; } > "$F/pins.jsonl"
run_ap
assert_eq "$(stat_of pins_no_cwd)" "2" "pins_no_cwd is 2"
assert_eq "$(calls)" "0" "no call"

echo "# A10: pin-projects.tsv missing"
setup; rm -f "$F/pin-projects.tsv"; pin proj-a "Title" "Body" > "$F/pins.jsonl"
run_ap
assert_eq "$(stat_of pins_rejected_project)" "1" "rejected without an observed-project list"
assert_eq "$(calls)" "0" "no call"

echo "# A11: CLI failure is not ledgered, and a rerun of the same date retries"
setup; pin proj-a "Title" "Body" > "$F/pins.jsonl"
MOCK_SM_MODE=fail run_ap
assert_eq "$RC" "0" "exits 0"
assert_eq "$(stat_of pins_failed)" "1" "pins_failed is 1"
assert_eq "$(ledger_rows)" "0" "no ledger row"
run_ap
assert_eq "$(stat_of pins_applied)" "1" "retry applies it"
assert_eq "$(ledger_rows)" "1" "ledger row after retry"

echo "# A12: exit 0 with output that is not JSON"
setup; pin proj-a "Title" "Body" > "$F/pins.jsonl"
MOCK_SM_MODE=garbage run_ap
assert_eq "$(stat_of pins_failed)" "1" "pins_failed is 1"
assert_eq "$(ledger_rows)" "0" "no ledger row"

echo "# A13: hostile content passes through as data"
setup
body=$(printf 'say "hi" \\ back $(touch %s/pwned) `touch %s/pwned2`\nline two' "$T" "$T")
pin proj-a "Title" "$body" > "$F/pins.jsonl"
run_ap
assert_eq "$(jq -r .payload.content "$T/calls.jsonl" 2>/dev/null)" "$(printf 'Title\n\n%s' "$body")" "content byte-identical"
[ ! -e "$T/pwned" ] && [ ! -e "$T/pwned2" ] && ok "no command ran" || no "no command ran"

echo "# A15: stored, but the ledger row cannot be written"
setup; pin proj-a "Title" "Body" > "$F/pins.jsonl"
mkdir "$F/pins-applied.tsv"   # a directory: every append to it fails, even as root
run_ap
assert_eq "$RC" "0" "exits 0"
assert_eq "$(calls)" "1" "the store call ran"
assert_eq "$(stat_of pins_unledgered)" "1" "pins_unledgered is 1"
assert_eq "$(stat_of pins_applied)" "0" "not counted as applied"
grep -q 'stored m1 but could not write' "$T/out" && ok "the memory id is logged" || no "the memory id is logged"

echo "# A16: a result file that cannot be written leaves no stale counters behind"
setup; pin proj-a "Title" "Body" > "$F/pins.jsonl"
printf 'pins_applied: 99\n' > "$F/pins-result.txt"
mkdir "$F/pins-result.txt.tmp"
run_ap
assert_eq "$RC" "3" "exits 3 so the caller reports counters unavailable"
if grep -q 'pins_applied: 99' "$F/pins-result.txt" 2>/dev/null; then no "stale counters removed"; else ok "stale counters removed"; fi

echo "# A17: a shasum that fails at runtime never writes an empty hash"
setup; { pin proj-a "One" "Body"; pin proj-a "Two" "Body"; } > "$F/pins.jsonl"
mkdir -p "$T/bin"; printf '#!/bin/bash\nexit 3\n' > "$T/bin/shasum"; chmod +x "$T/bin/shasum"
PATH="$T/bin:$PATH" run_ap
assert_eq "$(stat_of pins_duplicate)" "0" "no pin is mistaken for a duplicate"
assert_eq "$(stat_of pins_failed)" "2" "both pins fail"
assert_eq "$(calls)" "0" "nothing stored without a hash"
assert_eq "$(ledger_rows)" "0" "no ledger row"

echo "# A18: shared-memory context cannot name the project's bank"
setup; pin proj-a "Title" "Body" > "$F/pins.jsonl"
MOCK_SM_MODE=nocontext run_ap
assert_eq "$(stat_of pins_failed)" "1" "pins_failed is 1"
assert_eq "$(calls)" "0" "no remember call into a guessed bank"
assert_eq "$(ledger_rows)" "0" "no ledger row"

echo "# A19: the store reports success with an empty memory_id"
setup; pin proj-a "Title" "Body" > "$F/pins.jsonl"
MOCK_SM_MODE=emptyid run_ap
assert_eq "$(stat_of pins_failed)" "1" "pins_failed is 1"
assert_eq "$(stat_of pins_applied)" "0" "not counted as applied"
assert_eq "$(ledger_rows)" "0" "no ledger row without a usable id"

echo "# A20: a ledger that exists but cannot be read"
setup; pin proj-a "Title" "Body" > "$F/pins.jsonl"
printf 'somehash\tm0\n' > "$F/pins-applied.tsv"; chmod 000 "$F/pins-applied.tsv"
run_ap
chmod 600 "$F/pins-applied.tsv"
assert_eq "$(stat_of pins_failed)" "1" "pins_failed is 1"
assert_eq "$(calls)" "0" "nothing stored while duplicates cannot be ruled out"

echo "# A21: the write committed but its journal append failed (CLI exits 1)"
setup; pin proj-a "Title" "Body" > "$F/pins.jsonl"
MOCK_SM_MODE=journal run_ap
assert_eq "$(stat_of pins_applied)" "1" "a committed write counts as applied"
assert_eq "$(stat_of pins_failed)" "0" "not counted as failed"
assert_eq "$(cut -f2 "$F/pins-applied.tsv" 2>/dev/null)" "m1" "ledgered with its memory id, so a rerun cannot store it again"
grep -q 'journal' "$T/out" && ok "the incomplete journal is logged" || no "the incomplete journal is logged"
MOCK_SM_MODE=journal run_ap
assert_eq "$(calls)" "1" "a rerun makes no second store"

echo "# A22: shared-memory context exits nonzero but still prints a bank"
setup; pin proj-a "Title" "Body" > "$F/pins.jsonl"
MOCK_SM_MODE=ctxexit run_ap
assert_eq "$(stat_of pins_failed)" "1" "pins_failed is 1"
assert_eq "$(calls)" "0" "no store with a bank from a failed context call"

echo "# A23: the store call exits nonzero while printing a stored result"
setup; pin proj-a "Title" "Body" > "$F/pins.jsonl"
MOCK_SM_MODE=storedexit1 run_ap
assert_eq "$(stat_of pins_failed)" "1" "a nonzero store is a failure"
assert_eq "$(stat_of pins_applied)" "0" "not counted as applied"
assert_eq "$(ledger_rows)" "0" "no ledger row, so a later run can retry"

echo "# A24: a pins.jsonl that exists but cannot be read"
setup; pin proj-a "Title" "Body" > "$F/pins.jsonl"; chmod 000 "$F/pins.jsonl"
run_ap
chmod 600 "$F/pins.jsonl"
assert_eq "$RC" "0" "exits 0"
assert_eq "$(stat_of pins_unreadable)" "1" "unreadable file: pins_unreadable is 1"
assert_eq "$(calls)" "0" "unreadable file: no call"
setup; pin proj-a "Title" "Body" > "$F/pins.jsonl"; chmod 000 "$F/pins.jsonl"
SM_BIN="$T/nonexistent/shared-memory" run_ap
chmod 600 "$F/pins.jsonl"
assert_eq "$(stat_of pins_unreadable)" "1" "unreadable file with no CLI: pins_unreadable is 1"
setup; mkdir "$F/pins.jsonl"
run_ap
assert_eq "$(stat_of pins_unreadable)" "1" "a directory named pins.jsonl: pins_unreadable is 1"

echo "# A25: optional harness tag becomes metadata.harness; unknown values are invalid"
setup
{
  pin proj-a "Tagged" "Body" | jq -c '. + {harness:"omp"}'
  pin proj-a "Untagged" "Body"
  pin proj-a "Bad tag" "Body" | jq -c '. + {harness:"vim"}'
  pin proj-a "Null tag" "Body" | jq -c '. + {harness:null}'
  pin proj-a "Array tag" "Body" | jq -c '. + {harness:["omp"]}'
  pin proj-a "Array kind" "Body" | jq -c '. + {kind:["correction"]}'
} > "$F/pins.jsonl"
run_ap
assert_eq "$(stat_of pins_applied)" "2" "tagged and untagged pins applied"
assert_eq "$(stat_of pins_invalid)" "4" "unknown, null and array harness, and an array kind, rejected"
assert_eq "$(jq -r 'select(.payload.content | startswith("Tagged")) | .payload.metadata.harness' "$T/calls.jsonl" 2>/dev/null)" "omp" "metadata.harness is omp"
assert_eq "$(jq -r 'select(.payload.content | startswith("Untagged")) | .payload.metadata | has("harness")' "$T/calls.jsonl" 2>/dev/null)" "false" "untagged pin carries no harness key"

echo "# A26: a shared-memory without the harness gate holds tagged pins and still stores untagged ones"
setup
{
  pin proj-a "Tagged" "Body" | jq -c '. + {harness:"omp"}'
  pin proj-a "Untagged" "Body"
} > "$F/pins.jsonl"
MOCK_SM_GATE=0 run_ap
assert_eq "$(stat_of pins_unsupported_harness)" "1" "tagged pin held"
assert_eq "$(stat_of pins_applied)" "1" "untagged pin applied"
assert_eq "$(calls)" "1" "only one remember call"
assert_eq "$(ledger_rows)" "1" "held pin is not ledgered"
run_ap
assert_eq "$(stat_of pins_applied)" "1" "rerun with the gate present applies the held pin"
assert_eq "$(stat_of pins_duplicate)" "1" "and recognises the untagged one as stored"

echo "# A27: the ledger is keyed on the bank too: the same pin resolving to another bank is stored there (#70)"
setup; pin proj-a "Title" "Body" > "$F/pins.jsonl"
run_ap
assert_eq "$(stat_of pins_applied)" "1" "first run stores the pin"
mkdir -p "$T/work-a2"; printf 'proj-a\t%s\n' "$T/work-a2" > "$F/pin-projects.tsv"
run_ap
assert_eq "$(stat_of pins_applied)" "1" "a rebuild that resolves the project to another bank stores the pin there"
assert_eq "$(jq -r .payload.bank "$T/calls.jsonl" 2>/dev/null | paste -sd, -)" "bank-work-a,bank-work-a2" "one store per bank"
printf 'proj-a\t%s\n' "$T/work-a2" > "$F/pin-projects.tsv"
run_ap
assert_eq "$(stat_of pins_duplicate)" "1" "the same pin in the same bank is still a duplicate"

echo "# A28: a result file that cannot be cleared stores nothing and exits 3 (#70)"
setup; pin proj-a "Title" "Body" > "$F/pins.jsonl"
run_ap
chmod 555 "$F"
run_ap
rc28=$RC
chmod 755 "$F"
assert_eq "$rc28" "3" "exits 3 so the caller does not read the old counters"
assert_eq "$(calls)" "1" "no pin was stored on the failed run"

echo "# A14: no arguments"
setup
SHARED_MEMORY_BIN="$SM" bash "$AP" > "$T/out" 2>&1
assert_eq "$?" "2" "usage exits 2"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
