#!/bin/bash
# bin/dream-grounding.sh (fixed, model-free checks) and bin/triage-dream.sh (the read-only
# model pass over their output). No network, no model: the engine is tests/mock-claude.sh.
#
# The capture files here are the mock's triage-* files, never its l2-* files, so this suite
# cannot disturb an assertion about L2's own arguments and prompt.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$HERE/lib-tmp.sh"; suite_tmp dreamtriage
GROUND="$REPO/bin/dream-grounding.sh"
TRIAGE="$REPO/bin/triage-dream.sh"
MOCK="$HERE/mock-claude.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }
assert_grep(){ grep -q -- "$2" "$1" 2>/dev/null && ok "$3" || no "$3 (no /$2/ in $1)"; }
assert_nogrep(){ grep -q -- "$2" "$1" 2>/dev/null && no "$3 (/$2/ unexpectedly in $1)" || ok "$3"; }
assert_file(){ [ -f "$1" ] && ok "$2" || no "$2 (missing: $1)"; }
assert_no_file(){ [ ! -e "$1" ] && ok "$2" || no "$2 (unexpected: $1)"; }
status_of(){ jq -r --arg c "$2" '.claims[] | select(.claim == $c) | .status' "$1"; }

mk_root(){
  local r; r=$(mktemp -d "${TMPDIR:-/tmp}/dt.XXXXXX")
  mkdir -p "$r/skills/real-skill" "$r/plugins/p/skills/plug-skill" "$r/autodream/findings/2020-01-02" "$r/dreams" "$r/cap" "$r/home"
  : > "$r/skills/real-skill/SKILL.md"
  : > "$r/plugins/p/skills/plug-skill/SKILL.md"
  printf '{"permissions":{"allow":["Bash(git status:*)","mcp__srv__tool"]}}\n' > "$r/settings.json"
  printf '%s' "$r"
}
mk_repo(){ # $1=dir -> a repo with one commit; prints its full sha
  mkdir -p "$1" && git -C "$1" init -q 2>/dev/null && git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "the cited change" 2>/dev/null
  git -C "$1" rev-parse HEAD 2>/dev/null
}
mk_report(){ # $1=path $2=sha
  cat > "$1" <<R
# Autodream - fixture

## Skill coverage gaps
- The report says \`ghost-skill\` is missing, but \`real-skill\` and \`p:plug-skill\` are not.
- Also \`Read\` and \`ghost-skill\` again.

## Proposed action
- Add \`Bash(git status:*)\` and \`Bash(rm -rf:*)\` and \`mcp__srv__tool\` to the allowlist.
- Commit \`$2\` fixed it; \`deadbee0\` did not exist; session \`47eba605cf1e\` is a findings hash.
- A plain \`some-token\` on a line about nothing.

<!-- autodream:open-questions=0 -->
R
}
ground(){ # $1=root $2=report [$3=extra env...] -> runs the grounding script into $1/g.json
  local r="$1" rep="$2"; shift 2
  env AUTODREAM_SKILL_DIRS="$r/skills:$r/plugins" AUTODREAM_SETTINGS_FILES="$r/settings.json" \
    AUTODREAM_TRIAGE_REPOS="${REPOS:-}" "$@" bash "$GROUND" "$rep" "$r/g.json"
}

echo "# grounding: skills, allowlist keys and commits are checked by fixed code"
root=$(mk_root); sha=$(mk_repo "$root/repo"); mk_report "$root/r.md" "${sha:-0000000}"
REPOS="$root/repo" ground "$root" "$root/r.md"; rc=$?
assert_eq "$rc" "0" "the check runs"
g="$root/g.json"
assert_eq "$(status_of "$g" ghost-skill)" "absent" "a skill that is not installed is absent"
assert_eq "$(status_of "$g" real-skill)" "present" "a skill under the skills dir is present"
assert_eq "$(status_of "$g" p:plug-skill)" "present" "a plugin skill is found, by its name after the colon"
assert_eq "$(jq '[.claims[] | select(.claim == "ghost-skill")] | length' "$g")" "1" "a span quoted twice is one claim"
assert_eq "$(status_of "$g" Read)" "" "a tool name is not a skill claim"
assert_eq "$(status_of "$g" some-token)" "" "a span on a line that does not mention skills is not a skill claim"
assert_eq "$(status_of "$g" 'Bash(git status:*)')" "present" "an allowlist rule that is in permissions.allow is present"
assert_eq "$(status_of "$g" 'Bash(rm -rf:*)')" "absent" "one that is not is absent"
assert_eq "$(status_of "$g" mcp__srv__tool)" "present" "an mcp tool name is checked as a rule too"
assert_eq "$(status_of "$g" "$sha")" "present" "a cited commit that resolves is present"
assert_grep "$g" 'the cited change' "and the evidence names the commit"
assert_eq "$(status_of "$g" deadbee0)" "absent" "a hex span that is no commit is absent"
assert_eq "$(status_of "$g" 47eba605cf1e)" "" "a 12-hex findings hash is citation-check's, not a sha claim"
assert_eq "$(jq '.claims | length' "$g")" "8" "and nothing else became a claim"
rm -rf "$root"

echo "# grounding: a check that cannot run says unknown, never absent"
root=$(mk_root); mk_report "$root/r.md" abcdef1
ground "$root" "$root/r.md" AUTODREAM_SETTINGS_FILES="$root/missing.json"
assert_eq "$(status_of "$root/g.json" 'Bash(git status:*)')" "unknown" "no readable settings file is unknown"
assert_eq "$(status_of "$root/g.json" abcdef1)" "unknown" "no repository is unknown"
rm -rf "$root"

echo "# grounding: an unreadable report is an error, not an empty result"
root=$(mk_root)
env AUTODREAM_SKILL_DIRS="$root/skills" bash "$GROUND" "$root/none.md" "$root/g.json" 2>/dev/null; rc=$?
assert_eq "$rc" "2" "exit 2 for a missing report"
assert_no_file "$root/g.json" "and no output file"
rm -rf "$root"

run_triage(){ # $1=root [env...] ; the mock is the engine
  local r="$1"; shift
  env HOME="$r/home" AUTODREAM_DIR="$r/autodream" DREAMS_DIR="$r/dreams" PROJECTS_DIR="$r/projects" \
    AUTODREAM_CONFIG="$r/none-config" AUTODREAM_SKILL_DIRS="$r/skills" AUTODREAM_SETTINGS_FILES="$r/settings.json" \
    CLAUDE_BIN="$MOCK" MOCK_CAPTURE_DIR="$r/cap" "$@" bash "$TRIAGE" 2020-01-02 > "$r/out.txt" 2>&1
}

echo "# triage: grounding goes to the model as data, the runner writes the worklist"
root=$(mk_root); mk_report "$root/dreams/2020-01-02.md" abcdef1
run_triage "$root"; rc=$?
assert_eq "$rc" "0" "the pass succeeds"
t="$root/dreams/2020-01-02.triage.md"
assert_grep "$t" '^# Dream triage' "the worklist is written by the runner"
assert_grep "$t" 'skill ghost-skill absent' "and the model saw the grounding"
assert_nogrep "$t" 'AUTODREAM_REPORT_END' "the sentinel and what follows it are cut"
assert_nogrep "$t" 'report: ignored' "including the trailer"
assert_file "$root/autodream/findings/2020-01-02/triage/grounding.json" "grounding.json is kept beside the findings, not in them"
assert_eq "$(ls "$root/autodream/findings/2020-01-02"/*.json 2>/dev/null | wc -l | tr -d ' ')" "0" "so L2's findings glob cannot reach it"
assert_grep "$root/cap/triage-args.txt" '^Glob$' "the engine is given Glob"
assert_grep "$root/cap/triage-args.txt" '^Read$' "and Read"
assert_nogrep "$root/cap/triage-args.txt" '^Write$' "and not Write"
assert_nogrep "$root/cap/triage-args.txt" '^Bash$' "and no Bash"
assert_nogrep "$root/cap/triage-args.txt" '^--model$' "no model is named by this script"
assert_grep "$root/cap/triage-stdin.txt" 'Findings directory to aggregate' "the prompt keeps the framing the adapter's system prompt expects"
assert_grep "$root/cap/triage-stdin.txt" '^# Dream triage worker' "followed by the triage prompt"
assert_no_file "$root/cap/l2-args.txt" "and nothing touched L2's capture files"
assert_no_file "$root/cap/l2-stdin.txt" "in either direction"

echo "# triage: idempotent, and AUTODREAM_FORCE rebuilds"
rm -f "$root/cap"/*; printf 'old\n' > "$t"
run_triage "$root"; rc=$?
assert_eq "$rc" "0" "an existing triage is a no-op"
assert_eq "$(cat "$t")" "old" "and is not touched"
assert_no_file "$root/cap/triage-args.txt" "the engine was not called"
run_triage "$root" AUTODREAM_FORCE=1
assert_grep "$t" '^# Dream triage' "FORCE rebuilds it"
rm -rf "$root"

echo "# triage: a failed or cut-off call writes nothing"
for m in fail nosentinel empty; do
  root=$(mk_root); mk_report "$root/dreams/2020-01-02.md" abcdef1
  run_triage "$root" MOCK_TRIAGE_MODE=$m; rc=$?
  assert_eq "$rc" "1" "$m: exit 1"
  assert_no_file "$root/dreams/2020-01-02.triage.md" "$m: no triage file"
  assert_no_file "$root/dreams/2020-01-02.triage.md.tmp" "$m: no stray temp"
  rm -rf "$root"
done

echo "# triage: the engine is an adapter, picked the way L2's is"
root=$(mk_root); mk_report "$root/dreams/2020-01-02.md" abcdef1
run_triage "$root" AUTODREAM_ADAPTERS=claude,omp AUTODREAM_L2_ENGINE=omp AUTODREAM_L2_MODEL_OMP=omp/triage-model OMP_BIN="$MOCK"; rc=$?
assert_eq "$rc" "0" "an omp engine runs the pass"
assert_grep "$root/cap/triage-args.txt" '^--tools=Glob,Read$' "with the omp adapter's own read-only grant"
assert_grep "$root/cap/triage-args.txt" '^omp/triage-model$' "and the model resolved per adapter"
rm -rf "$root"
root=$(mk_root); mk_report "$root/dreams/2020-01-02.md" abcdef1
run_triage "$root" AUTODREAM_L2_ENGINE=nonesuch; rc=$?
assert_eq "$rc" "2" "an engine that is not an adapter is refused"
assert_no_file "$root/cap/triage-args.txt" "before any call"
rm -rf "$root"

echo "# grounding: no installed skills listable is unknown; a cap is recorded, not silent"
root=$(mk_root); mk_report "$root/r.md" abcdef1
env AUTODREAM_SKILL_DIRS="$root/empty" AUTODREAM_SETTINGS_FILES="$root/settings.json" bash "$GROUND" "$root/r.md" "$root/g.json"
assert_eq "$(status_of "$root/g.json" ghost-skill)" "unknown" "with no skill listable, a skill claim is unknown, not absent"
ground "$root" "$root/r.md" AUTODREAM_GROUNDING_MAX=2
assert_eq "$(jq -r .truncated "$root/g.json")" "true" "a capped run says it was truncated"
assert_eq "$(jq '.claims | length' "$root/g.json")" "2" "and kept the cap"
ground "$root" "$root/r.md"
assert_eq "$(jq -r .truncated "$root/g.json")" "false" "an uncapped one says it was not"
rm -rf "$root"

echo "# triage prompt: present/absent are existence results, compared with what the report claims"
assert_grep "$REPO/prompts/TRIAGE_DREAM.md" 'only say whether the thing exists' "the prompt does not treat a status as a verdict"
assert_grep "$REPO/prompts/TRIAGE_DREAM.md" 'the report relies on it and the claim is' "and gives both polarities"

echo "# triage: a rebuilt report makes an older triage stale; a bad config is named, not fatal"
root=$(mk_root); mk_report "$root/dreams/2020-01-02.md" abcdef1
printf 'old\n' > "$root/dreams/2020-01-02.triage.md"
touch -t 202001010000 "$root/dreams/2020-01-02.triage.md"
run_triage "$root"
assert_grep "$root/dreams/2020-01-02.triage.md" '^# Dream triage' "a triage older than its report is rebuilt"
printf 'X=$UNSET_VARIABLE_FOR_TEST\n' > "$root/bad-config"
rm -f "$root/dreams/2020-01-02.triage.md"
run_triage "$root" AUTODREAM_CONFIG="$root/bad-config"; rc=$?
assert_eq "$rc" "0" "an unusable config does not stop the pass"
assert_grep "$root/out.txt" 'WARNING: ignoring' "and the log names it"
rm -rf "$root"

echo "# review.sh with no date never opens a triage file as the report"
root=$(mk_root); mk_report "$root/dreams/2020-01-02.md" abcdef1
printf '# Dream triage - not a report\n' > "$root/dreams/2020-01-02.triage.md"
out=$(env AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" AUTODREAM_CONFIG="$root/none" CLAUDE_BIN=/usr/bin/false HOME="$root/home" bash "$REPO/bin/review.sh" 2>&1)
case "$out" in *2020-01-02.triage*) no "review.sh picked the triage file: $out" ;; *) ok "review.sh picked the report" ;; esac
rm -rf "$root"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
