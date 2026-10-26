#!/bin/bash
# shellcheck disable=SC2016 # the `bash -c` bodies below are single-quoted on purpose: $1 is theirs, not ours
# Tests for the L2 system prompt: one file (prompts/L2_SYSTEM.txt), one loader (bin/l2-prompt.sh),
# three consumers (the claude adapter, the omp adapter, run.sh's built-in claude fallback).
#
# The text states the stdout grammar that bin/report-format.sh parses. Three byte-identical copies
# used to carry it; the risk was one of them drifting from the parser and an L2 run printing a
# report the runner could not split. A missing prompt must stop an engine from starting rather
# than start it with no instructions, so that failure is pinned here too.
#
# Usage:  tests/l2-prompt.sh
# Exit:   0 if every assertion passes, 1 otherwise.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$HERE/lib-tmp.sh"; suite_tmp ccl2p

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (got [$1] want [$2])"; fi; }

PROMPT_FILE="$REPO/prompts/L2_SYSTEM.txt"
WANT=$(cat "$PROMPT_FILE" 2>/dev/null)

# Inside the suite's own temp root, which suite_tmp removes on every way out.
T=$(mktemp -d "${TMPDIR:-/tmp}/ccl2p.XXXXXX")

# a minimal install tree: bin/, adapters/{claude,omp}, and optionally prompts/
mk_tree(){ # $1=name $2=with-prompt(1|0)
  local r="$T/$1"
  mkdir -p "$r/bin" "$r/adapters/claude" "$r/adapters/omp" "$r/prompts"
  cp "$REPO/bin/l2-prompt.sh" "$r/bin/" 2>/dev/null
  cp "$REPO/adapters/claude/adapter.sh" "$r/adapters/claude/"
  cp "$REPO/adapters/omp/adapter.sh" "$r/adapters/omp/"
  [ "$2" = 1 ] && cp "$PROMPT_FILE" "$r/prompts/" 2>/dev/null
  printf '%s' "$r"
}
# the value after --append-system-prompt in an adapter's NUL-delimited argv
sys_prompt_of(){ tr '\0' '\n' | awk '/^--append-system-prompt$/ { getline; print; exit }'; }

echo "# the file states the grammar the report parser reads"
for tok in AUTODREAM_REPORT_END AUTODREAM_PINS_BEGIN AUTODREAM_PINS_END "line 1 of the prompt" "line 2 of the prompt"; do
  case "$WANT" in *"$tok"*) ok "L2_SYSTEM.txt names $tok" ;; *) no "L2_SYSTEM.txt does not name $tok" ;; esac
done

echo "# the loader"
# shellcheck source=/dev/null
. "$REPO/bin/l2-prompt.sh"
assert_eq "$(l2_system_prompt)" "$WANT" "prints the file"
cmp -s <(l2_system_prompt) "$PROMPT_FILE"; assert_eq "$?" "0" "byte for byte, no newline added"
r=$(mk_tree bare 0)
out=$(env -u AUTODREAM_DIR bash -c '. "$1/bin/l2-prompt.sh"; l2_system_prompt' _ "$r" 2>"$T/err"); rc=$?
assert_eq "$rc" "2" "a missing prompt returns 2"
assert_eq "$out" "" "and prints nothing on stdout"
case "$(cat "$T/err")" in *"L2_SYSTEM.txt not found"*) ok "and says which file is missing" ;; *) no "no message for a missing prompt ($(cat "$T/err"))" ;; esac
r=$(mk_tree emptyfile 0); : > "$r/prompts/L2_SYSTEM.txt"
env -u AUTODREAM_DIR bash -c '. "$1/bin/l2-prompt.sh"; l2_system_prompt' _ "$r" >/dev/null 2>&1; assert_eq "$?" "2" "an empty prompt file is refused too"
r=$(mk_tree viadir 0); mkdir -p "$T/ad"; cp "$PROMPT_FILE" "$T/ad/L2_SYSTEM.txt"
assert_eq "$(AUTODREAM_DIR="$T/ad" bash -c '. "$1/bin/l2-prompt.sh"; l2_system_prompt' _ "$r" 2>/dev/null)" "$WANT" "AUTODREAM_DIR's copy is the second place it looks"
mkdir -p "$T/farm"; ln -s "$REPO/bin/l2-prompt.sh" "$T/farm/l2-prompt.sh"
assert_eq "$(env -u AUTODREAM_DIR bash -c '. "$1/farm/l2-prompt.sh"; l2_system_prompt' _ "$T" 2>/dev/null)" "$WANT" "a symlinked lib resolves into its checkout, like an installed copy"

r=$(mk_tree wsonly 0); printf '  \n\n\t\n' > "$r/prompts/L2_SYSTEM.txt"
env -u AUTODREAM_DIR bash -c '. "$1/bin/l2-prompt.sh"; l2_system_prompt' _ "$r" >/dev/null 2>&1; assert_eq "$?" "2" "a prompt file of only whitespace is refused too"
# a symlink whose target is RELATIVE, as a hand-made link might be (install.sh writes absolute ones)
mkdir -p "$T/rel/real/bin" "$T/rel/real/prompts" "$T/rel/farm"
cp "$REPO/bin/l2-prompt.sh" "$T/rel/real/bin/"; cp "$PROMPT_FILE" "$T/rel/real/prompts/"
ln -s ../real/bin/l2-prompt.sh "$T/rel/farm/l2-prompt.sh"
assert_eq "$(env -u AUTODREAM_DIR bash -c '. "$1/rel/farm/l2-prompt.sh"; l2_system_prompt' _ "$T" 2>/dev/null)" "$WANT" "a relative symlink target resolves against the link's own directory"

echo "# the claude adapter"
r=$(mk_tree withprompt 1)
got=$(CLAUDE_BIN=/opt/test/claude bash "$r/adapters/claude/adapter.sh" l2-argv | sys_prompt_of)
assert_eq "$got" "$WANT" "l2-argv carries the file's text"
got=$(CLAUDE_BIN=/opt/test/claude bash "$REPO/adapters/claude/adapter.sh" l2-argv | sys_prompt_of)
assert_eq "$got" "$WANT" "the real adapter does too"
r=$(mk_tree noprompt 0)
out=$(env -u AUTODREAM_DIR CLAUDE_BIN=/opt/test/claude bash "$r/adapters/claude/adapter.sh" l2-argv 2>/dev/null | wc -c | tr -d ' ')
env -u AUTODREAM_DIR CLAUDE_BIN=/opt/test/claude bash "$r/adapters/claude/adapter.sh" l2-argv >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "with no prompt file, l2-argv fails instead of starting an engine without one"
assert_eq "$out" "0" "and prints no argv"

echo "# the omp adapter"
r=$(mk_tree ompwith 1)
got=$(OMP_BIN=/opt/test/omp bash "$r/adapters/omp/adapter.sh" l2-argv some-model | sys_prompt_of)
assert_eq "$got" "$WANT" "l2-argv carries the file's text"
r=$(mk_tree ompnone 0)
out=$(env -u AUTODREAM_DIR OMP_BIN=/opt/test/omp bash "$r/adapters/omp/adapter.sh" l2-argv some-model 2>/dev/null | wc -c | tr -d ' ')
env -u AUTODREAM_DIR OMP_BIN=/opt/test/omp bash "$r/adapters/omp/adapter.sh" l2-argv some-model >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "with no prompt file, l2-argv fails"
assert_eq "$out" "0" "and prints no argv"
assert_eq "$(OMP_BIN=/opt/test/omp bash "$REPO/adapters/omp/adapter.sh" l2-argv some-model | sys_prompt_of)" "$WANT" "the real adapter carries it"

echo "# one source: no consumer keeps its own copy"
copies=$(grep -ln "Headless aggregator" "$REPO"/bin/*.sh "$REPO"/adapters/*/adapter.sh 2>/dev/null || true)
assert_eq "$copies" "" "no script holds the prompt text inline"
if grep -q "l2-prompt.sh" "$REPO/bin/run.sh"; then ok "run.sh's built-in fallback reads it through the loader"; else no "run.sh does not use l2-prompt.sh"; fi
if grep -q "L2_SYSTEM.txt" "$REPO/install.sh"; then ok "install.sh links the prompt into the install"; else no "install.sh does not link L2_SYSTEM.txt"; fi
if grep -q "l2-prompt.sh" "$REPO/install.sh"; then ok "install.sh links the loader"; else no "install.sh does not link l2-prompt.sh"; fi

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
