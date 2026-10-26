#!/bin/bash
# Tests for bin/report-format.sh: how the runner, the notifier, the streak counter and the review
# launcher read a report's two contracts, the open-questions marker and the L2 stdout sentinel.
#
# Each helper is compared with the inline code it replaced, kept below as a reference
# implementation, over a matrix of fixtures. The refactor is only safe if the two agree on
# output and on exit status for every fixture, the awkward ones included.
#
# Usage:  tests/report-format.sh
# Exit:   0 if every assertion passes, 1 otherwise.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$HERE/lib-tmp.sh"; suite_tmp ccrf
# shellcheck source=/dev/null
. "$REPO/bin/report-format.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (got [$1] want [$2])"; fi; }

# ---- reference implementations: the code the helpers replaced, verbatim ----
old_marker(){ sed -n 's/.*<!-- *autodream:open-questions=\([0-9][0-9]*\) *-->.*/\1/p' "$1" 2>/dev/null | head -1; }
old_has_marker(){ grep -q 'autodream:open-questions=' "$1" 2>/dev/null; }
old_has_sentinel(){ grep -q '^AUTODREAM_REPORT_END$' "$1" 2>/dev/null; }
old_body(){ awk '/^AUTODREAM_REPORT_END$/ { last=NR } { line[NR]=$0 } END { for (i=1; i<last; i++) print line[i] }' "$1"; }
old_after(){ awk '/^AUTODREAM_REPORT_END$/ { f=1; next } f { print }' "$1" 2>/dev/null; }
old_pins(){
  awk '
    /^AUTODREAM_REPORT_END$/ { last = NR }
    { line[NR] = $0 }
    END {
      for (i = last + 1; i <= NR; i++) {
        if (!inb && line[i] == "AUTODREAM_PINS_BEGIN") { inb = 1; continue }
        if (inb && line[i] == "AUTODREAM_PINS_END") { closed = 1; break }
        if (inb) buf[++n] = line[i]
      }
      if (closed) for (j = 1; j <= n; j++) if (buf[j] ~ /^\{/) print buf[j]
    }' "$1" 2>/dev/null
}

# Inside the suite's own temp root, which suite_tmp removes on every way out.
D=$(mktemp -d "${TMPDIR:-/tmp}/ccrf.XXXXXX")

fx(){ printf '%b' "$2" > "$D/$1"; }
fx normal   '# R\n\nbody\n<!-- autodream:open-questions=3 -->\nAUTODREAM_REPORT_END\nAUTODREAM_PINS_BEGIN\n{"a":1}\nnot json\n{"b":2}\nAUTODREAM_PINS_END\nreport: /x\nsummary\n'
fx nosent   '# R\n\nbody\n<!-- autodream:open-questions=2 -->\n'
fx twosent  '# R\nquoting the marker:\nAUTODREAM_REPORT_END\nAUTODREAM_PINS_BEGIN\n{"inj":1}\nAUTODREAM_PINS_END\nmore body\n<!-- autodream:open-questions=1 -->\nAUTODREAM_REPORT_END\nreport: /x\n'
fx lastline '# R\nbody\n<!-- autodream:open-questions=0 -->\nAUTODREAM_REPORT_END\n'
fx firstline 'AUTODREAM_REPORT_END\nreport: /x\n'
fx unclosed '# R\nbody\n<!-- autodream:open-questions=1 -->\nAUTODREAM_REPORT_END\nAUTODREAM_PINS_BEGIN\n{"a":1}\n'
fx pinsabove '# R\nAUTODREAM_PINS_BEGIN\n{"a":1}\nAUTODREAM_PINS_END\nbody\nAUTODREAM_REPORT_END\nreport: /x\n'
fx empty    ''
fx crlf     '# R\r\nbody\r\n<!-- autodream:open-questions=4 -->\r\nAUTODREAM_REPORT_END\r\nreport: /x\r\n'
fx nonl     '# R\nbody\n<!-- autodream:open-questions=5 -->\nAUTODREAM_REPORT_END'
fx spaced   'a\n<!--autodream:open-questions=12-->\nb\n'
fx twomark  'a\n<!-- autodream:open-questions=7 -->\nb\n<!-- autodream:open-questions=9 -->\n'
fx badmark  'a\n<!-- autodream:open-questions=x -->\n'
fx inline   'the text mentions autodream:open-questions=3 in prose\n'
fx indented '  AUTODREAM_REPORT_END\nbody\n'
FIXTURES="normal nosent twosent lastline firstline unclosed pinsabove empty crlf nonl spaced twomark badmark inline indented missing"

# same stdout and same exit status as the reference, for every fixture
same(){ # $1=helper $2=reference
  local f out_new out_old
  for f in $FIXTURES; do
    out_new=$("$1" "$D/$f" 2>/dev/null; echo "rc=$?"); out_old=$("$2" "$D/$f" 2>/dev/null; echo "rc=$?")
    if [ "$out_new" = "$out_old" ]; then ok "$1 matches the old code on $f"
    else no "$1 differs from the old code on $f (new [$out_new] old [$out_old])"; fi
  done
}

echo "# the marker count (strict: digits inside the comment)"
same report_marker_count old_marker
assert_eq "$(report_marker_count "$D/twomark")" "7" "the first marker wins"
assert_eq "$(report_marker_count "$D/spaced")" "12" "no spaces needed inside the comment"
assert_eq "$(report_marker_count "$D/badmark")" "" "a non-numeric marker is no marker"
assert_eq "$(report_marker_count "$D/inline")" "" "prose that mentions the key is no marker"

echo "# the marker presence (loose: any line holding the key)"
same report_has_marker old_has_marker
report_has_marker "$D/badmark"; assert_eq "$?" "0" "the loose check accepts what the strict one rejects, on purpose"
report_has_marker "$D/empty"; assert_eq "$?" "1" "an empty report has none"

echo "# the sentinel"
same report_has_sentinel old_has_sentinel
report_has_sentinel "$D/indented"; assert_eq "$?" "1" "an indented sentinel is not one"
report_has_sentinel "$D/crlf"; assert_eq "$?" "1" "a CRLF sentinel is not one"

echo "# the body: everything before the LAST sentinel"
same report_body old_body
assert_eq "$(report_body "$D/twosent" | tail -1)" "<!-- autodream:open-questions=1 -->" "the last sentinel ends the body"
assert_eq "$(report_body "$D/nosent" | wc -l | tr -d ' ')" "0" "no sentinel, no body"

echo "# what follows a sentinel"
same report_after_sentinel old_after
assert_eq "$(report_after_sentinel "$D/lastline" | wc -l | tr -d ' ')" "0" "a sentinel on the last line has nothing after it"

echo "# the pin block: only a CLOSED block after the LAST sentinel"
same report_pin_lines old_pins
assert_eq "$(report_pin_lines "$D/normal")" '{"a":1}
{"b":2}' "only lines that open a JSON object are kept"
assert_eq "$(report_pin_lines "$D/unclosed")" "" "a block cut off before its END proposes nothing"
assert_eq "$(report_pin_lines "$D/twosent")" "" "a block quoted in the body cannot inject a pin"
assert_eq "$(report_pin_lines "$D/pinsabove")" "" "a block above the sentinel is body text"

echo "# a helper hands its awk status to the caller, so a stage-and-rename chain stops on failure"
report_body "$D/missing" >/dev/null 2>&1; assert_eq "$?" "$(old_body "$D/missing" >/dev/null 2>&1; echo $?)" "a missing file fails the same way"

echo "# existing readers still read through the lib"
assert_eq "$(report_open_questions "$D/normal")" "3" "report_open_questions reads the marker"
assert_eq "$(report_open_questions "$D/empty")" "unknown" "and stays unknown when it cannot tell"

echo "# the callers use the lib and not their own copy"
# Each caller must call the helper it replaced (a mention of the file name proves nothing: an error
# message would do), and must load the lib on a line of its own.
uses(){ # $1=script $2=helper
  if grep -qE "^[^#]*\\b$2\\b" "$REPO/bin/$1"; then ok "bin/$1 calls $2"; else no "bin/$1 does not call $2"; fi
}
uses notify.sh report_marker_count
uses question-streaks.sh report_marker_count
uses triage-dream.sh report_has_sentinel
uses triage-dream.sh report_body
uses run.sh report_has_marker
uses run.sh report_has_sentinel
uses run.sh report_body
uses run.sh report_after_sentinel
uses run.sh report_pin_lines
for f in notify.sh question-streaks.sh triage-dream.sh run.sh; do
  # shellcheck disable=SC2016 # the dollar signs are literal: the regex matches the script's own source line
  if grep -qE '^[[:space:]]*\. "\$(_rf|_lib)"' "$REPO/bin/$f" && grep -q 'report-format\.sh' "$REPO/bin/$f"; then ok "bin/$f sources report-format.sh"; else no "bin/$f does not source report-format.sh"; fi
done
# Any spelling of the marker or sentinel read, strict or loose, belongs in the lib. Comments are skipped.
inline=$(grep -nE "autodream:open-questions=|\\^AUTODREAM_REPORT_END" "$REPO"/bin/*.sh | grep -v 'bin/report-format.sh' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -E "grep|sed|awk" || true)
assert_eq "$inline" "" "no other script reads the marker or the sentinel with its own grep, sed or awk"

echo "# a missing lib is loud, and costs the documented exit codes nothing"
BARE="$D/bare"; mkdir -p "$BARE"
cp "$REPO/bin/question-streaks.sh" "$REPO/bin/notify.sh" "$REPO/bin/portable.sh" "$REPO/bin/lib-install-dir.sh" "$BARE/"
printf '# R\n<!-- autodream:open-questions=1 -->\n' > "$D/r.md"
out=$(AUTODREAM_DIR="$D/ad" bash "$BARE/question-streaks.sh" update "$D/r.md" 2>&1); rc=$?
assert_eq "$rc" "0" "question-streaks.sh update still exits 0 without the lib"
case "$out" in *"report-format.sh not found"*) ok "and says the lib is missing" ;; *) no "update said nothing about the missing lib ($out)" ;; esac
AUTODREAM_DIR="$D/ad" bash "$BARE/question-streaks.sh" status >/dev/null 2>&1; assert_eq "$?" "1" "any other command fails"
out=$(AUTODREAM_DIR="$D/ad" bash "$BARE/notify.sh" "$D/r.md" 2>&1); rc=$?
assert_eq "$rc" "1" "notify.sh fails without the lib"
case "$out" in *"report-format.sh not found"*) ok "and says why" ;; *) no "notify.sh said nothing about the missing lib ($out)" ;; esac

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
