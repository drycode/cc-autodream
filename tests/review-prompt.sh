#!/bin/bash
# Tests for what bin/review.sh hands the triage session.
#
# The session's --append-system-prompt used to carry the ENTIRE report. On
# 2026-10-27 that refused every launch: the 2026-10-26 report narrated a night
# of Samsung TV work (sdb, root status, dlopen), and Opus 5.5's classifiers
# answered "Opus 5.5's safeguards flagged this session ... [cyber]" before the
# first reply — on the literal prompt "go". The report's questions section is
# ~2KB of decision text and passes; the findings body does not.
#
# What review.sh inlines is report-format.sh's contract, not a markdown parse:
# the text between AUTODREAM_QUESTIONS_BEGIN and AUTODREAM_QUESTIONS_END, with
# the old heading-to-next-heading read kept only for reports written before that
# block existed. So the assertions here are:
#
#   * block present  -> its content inlined verbatim, findings body absent
#   * block content  -> markdown inside it is text, not structure: a fenced or
#                       plain `## ` inside the block does not end anything
#   * legacy report  -> the heading fallback still inlines the section
#   * cap            -> all or nothing; an oversized block is not inlined at all
#   * launch prompt  -> a real instruction, not a bare "go"
#   * temp files     -> none survive the launch
#
# The mock claude dumps each argv element to $ARGV_DIR/argN so the assertions
# read exactly what the session would receive. No network, no model calls.
#
# Usage:  tests/review-prompt.sh
# Exit:   0 if every assertion passes, 1 otherwise.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$HERE/lib-tmp.sh"; suite_tmp ccrevprompt
REVIEW="$REPO/bin/review.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_grep(){   grep -q -- "$2" "$1" 2>/dev/null && ok "$3" || no "$3 (no /$2/ in $1)"; }
assert_nogrep(){ grep -q -- "$2" "$1" 2>/dev/null && no "$3 (/ $2 / unexpectedly in $1)" || ok "$3"; }
assert_eq(){     [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

setup_env(){
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccrevprompt.XXXXXX")
  mkdir -p "$root/dreams" "$root/bin" "$root/argv"
  cat > "$root/bin/claude" <<'MOCK'
#!/bin/bash
rm -f "$ARGV_DIR"/arg*
i=0
for a in "$@"; do
  i=$((i + 1))
  printf '%s' "$a" > "$ARGV_DIR/arg$i"
done
printf '%s' "$i" > "$ARGV_DIR/count"
exit 0
MOCK
  chmod +x "$root/bin/claude"
  printf '%s' "$root"
}

run_review(){ # $1=root [args...]
  local root="$1"; shift
  ARGV_DIR="$root/argv" \
  AUTODREAM_CONFIG="$root/nonexistent-config" \
  AUTODREAM_TRIAGE_SURFACE=inline \
  DREAMS_DIR="$root/dreams" \
  CLAUDE_BIN="$root/bin/claude" \
  bash "$REVIEW" "$@" > "$root/out" 2>&1
}

system_prompt(){ cat "$1/argv/arg4" 2>/dev/null; }
launch_prompt(){ cat "$1/argv/arg5" 2>/dev/null; }

# A report shaped the way PROMPT.md mandates now: findings body, then the
# questions block. FINDINGS-SENTINEL only ever appears in the body.
mk_report(){ # $1=root $2=date $3=questions-block-body
  local root="$1" date="$2" q="$3"
  {
    printf '# Autodream — %s\n\n' "$date"
    printf '## Activity snapshot\n\nFINDINGS-SENTINEL the body nobody needs inlined.\n\n'
    printf '## Top patterns (ranked)\n\n### Some finding\n\nFINDINGS-SENTINEL again.\n\n'
    printf 'AUTODREAM_QUESTIONS_BEGIN\n'
    printf '%s\n' "$q"
    printf 'AUTODREAM_QUESTIONS_END\n\n'
    printf '## Triage decisions\n\n- none yet\n'
  } > "$root/dreams/$date.md"
}

Q_BLOCK='## Open questions for the user

1. **Hook tightening** — should nudge-assumptions.sh block at edit #1?
   - Two findings: the hook fired late, and the agent re-derived the rule.
   - Options: (a) block at #1 (recommended); (b) keep nudging; (c) delete it.

<!-- autodream:open-questions=1 -->'

# --- tests -----------------------------------------------------------------

test_block_content_is_inlined_findings_not(){
  local root; root=$(setup_env); mk_report "$root" 2020-01-02 "$Q_BLOCK"
  run_review "$root" --force 2020-01-02
  system_prompt "$root" > "$root/sp"
  assert_grep "$root/sp" 'Hook tightening' "the questions block is inlined"
  assert_grep "$root/sp" 'block at edit #1' "question body and options are inlined"
  assert_grep "$root/sp" 'open-questions date="2020-01-02"' "the block names the date"
  assert_nogrep "$root/sp" 'FINDINGS-SENTINEL' "the findings body is NOT inlined"
  assert_nogrep "$root/sp" 'Top patterns' "other report sections are NOT inlined"
  assert_nogrep "$root/sp" 'AUTODREAM_QUESTIONS_BEGIN' "the sentinels are not passed through"
}

test_markdown_inside_the_block_is_text(){
  local root; root=$(setup_env)
  # Headings and fences inside the block are content. Under the old markdown
  # parse these ended the section; under the block contract they cannot.
  {
    printf '# Autodream — 2020-01-02\n\n## Top patterns\n\nBODY-SENTINEL\n\n'
    printf 'AUTODREAM_QUESTIONS_BEGIN\n'
    printf '## Open questions for the user\n\n1. **Q** — which heading wins?\n\n'
    printf '```bash\n## not a heading\n- not a question\n```\n\n'
    printf '## Example heading (plain, inside the block)\n\nAFTER-EXAMPLES the rest of the question.\n\n'
    printf '<!-- autodream:open-questions=1 -->\nAUTODREAM_QUESTIONS_END\n'
  } > "$root/dreams/2020-01-02.md"
  run_review "$root" --force 2020-01-02
  system_prompt "$root" > "$root/sp"
  assert_grep "$root/sp" 'AFTER-EXAMPLES' "a plain heading inside the block does not end it"
  assert_grep "$root/sp" 'not a question' "a fenced block inside the block is kept"
  assert_nogrep "$root/sp" 'BODY-SENTINEL' "the findings body is still excluded"
}

test_legacy_report_uses_the_heading_fallback(){
  local root; root=$(setup_env)
  # No block: the report predates the contract. notify.sh's old heading read is
  # the fallback, so the triage session still gets its questions.
  {
    printf '# Autodream — 2020-01-02\n\n## Top patterns\n\nLEGACY-BODY\n\n'
    printf '## Open questions for the user\n\n1. **Legacy question** — still works?\n\n'
    printf '<!-- autodream:open-questions=1 -->\n'
  } > "$root/dreams/2020-01-02.md"
  run_review "$root" --force 2020-01-02
  system_prompt "$root" > "$root/sp"
  assert_grep "$root/sp" 'Legacy question' "a pre-block report still inlines its questions"
  assert_nogrep "$root/sp" 'LEGACY-BODY' "the legacy fallback stops at the next heading"
}

test_launch_prompt_is_an_instruction(){
  local root; root=$(setup_env); mk_report "$root" 2020-01-02 "$Q_BLOCK"
  run_review "$root" --force 2020-01-02
  local p; p=$(launch_prompt "$root")
  assert_eq "$p" 'Start the triage: restate the first open question and recommend one action.' "launch prompt is a real instruction"
  [ "$p" = "go" ] && no "launch prompt is not the bare word go" || ok "launch prompt is not the bare word go"
}

test_prompt_does_not_ask_for_the_whole_report(){
  local root; root=$(setup_env); mk_report "$root" 2020-01-02 "$Q_BLOCK"
  run_review "$root" --force 2020-01-02
  system_prompt "$root" > "$root/sp"
  assert_nogrep "$root/sp" 'Read the report' "system prompt does not instruct a full report read"
  assert_grep "$root/sp" 'Do not read the whole report' "system prompt keeps the model out of the body"
}

test_missing_section_still_launches(){
  local root; root=$(setup_env)
  printf '# Autodream — 2020-01-02\n\n## Top patterns\n\nNothing.\n\n<!-- autodream:open-questions=1 -->\n' \
    > "$root/dreams/2020-01-02.md"
  run_review "$root" --force 2020-01-02
  assert_eq "$(cat "$root/argv/count" 2>/dev/null)" "5" "a section-less report still launches the session"
  system_prompt "$root" > "$root/sp"
  assert_grep "$root/sp" 'open-questions date="2020-01-02"' "the empty block is still well formed"
}

test_cap_is_all_or_nothing(){
  local root; root=$(setup_env)
  local big; big=$(head -c 13000 /dev/zero | tr '\0' 'q')
  mk_report "$root" 2020-01-02 "## Open questions for the user

1. **Huge** — $big

<!-- autodream:open-questions=1 -->"
  run_review "$root" --force 2020-01-02
  system_prompt "$root" > "$root/sp"
  assert_grep "$root/sp" 'truncated="1"' "an oversized block is marked truncated"
  assert_nogrep "$root/sp" 'Huge' "an oversized block is not inlined at all"
  assert_grep "$root/sp" 'between the AUTODREAM_QUESTIONS_BEGIN and AUTODREAM_QUESTIONS_END lines' "the prompt says where to read them"
  local bytes; bytes=$(wc -c < "$root/sp" | tr -d ' ')
  [ "$bytes" -lt 8000 ] && ok "the prompt stays small (${bytes} bytes)" || no "the prompt stays small (got ${bytes} bytes)"
}

test_unclosed_block_is_not_a_block(){
  local root; root=$(setup_env)
  {
    printf '# Autodream — 2020-01-02\n\n## Open questions for the user\n\n1. **Unclosed** — treated how?\n'
    printf 'AUTODREAM_QUESTIONS_BEGIN\n'
    printf '## Open questions for the user\n\n1. **Real** — this one survives.\n\n'
    printf '<!-- autodream:open-questions=1 -->\n'
  } > "$root/dreams/2020-01-02.md"
  run_review "$root" --force 2020-01-02
  assert_eq "$(cat "$root/argv/count" 2>/dev/null)" "5" "an unclosed block does not stop the launch"
}

test_oversized_legacy_report_points_at_the_heading(){
  local root; root=$(setup_env)
  # No block, and too big to inline: the prompt must send the session to the
  # heading section, not to sentinels this report does not contain.
  local big; big=$(head -c 13000 /dev/zero | tr '\0' 'q')
  {
    printf '# Autodream — 2020-01-02\n\n## Open questions for the user\n\n1. **Huge** — %s\n\n' "$big"
    printf '<!-- autodream:open-questions=1 -->\n'
  } > "$root/dreams/2020-01-02.md"
  run_review "$root" --force 2020-01-02
  system_prompt "$root" > "$root/sp"
  assert_grep "$root/sp" 'truncated="1"' "an oversized legacy section is marked truncated"
  assert_grep "$root/sp" '## Open questions for the user' "the prompt points at the heading it actually has"
  assert_nogrep "$root/sp" 'between the AUTODREAM_QUESTIONS_BEGIN' "and not at sentinels the report does not contain"
}

test_temps_are_removed(){
  local root; root=$(setup_env); mk_report "$root" 2020-01-02 "$Q_BLOCK"
  local before; before=$(ls "${TMPDIR:-/tmp}" 2>/dev/null | grep -c '^autodream-questions' || true)
  run_review "$root" --force 2020-01-02
  local after; after=$(ls "${TMPDIR:-/tmp}" 2>/dev/null | grep -c '^autodream-questions' || true)
  assert_eq "$after" "$before" "no question temp file survives the launch"
}

echo "tests/review-prompt.sh"
test_block_content_is_inlined_findings_not
test_markdown_inside_the_block_is_text
test_legacy_report_uses_the_heading_fallback
test_launch_prompt_is_an_instruction
test_prompt_does_not_ask_for_the_whole_report
test_missing_section_still_launches
test_cap_is_all_or_nothing
test_oversized_legacy_report_points_at_the_heading
test_unclosed_block_is_not_a_block
test_temps_are_removed

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
