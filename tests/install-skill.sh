#!/usr/bin/env bash
# The global /autodream skill: where install.sh links it, and when it leaves it alone.
#
# The install target is a sandbox directory (its first positional argument) and HOME is a
# sandbox too, so nothing here touches ~/.claude. --no-schedule keeps launchd out of it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
no()   { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }
assert_eq()   { if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (got [$1] want [$2])"; fi; }
absent()  { if [ -e "$1" ]; then no "$2"; else ok "$2"; fi; }
linked()  { if [ -L "$1" ]; then ok "$2"; else no "$2"; fi; }
assert_grep() { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else no "$3 (no [$2] in $1)"; fi; }

SANDBOX=""
trap '[ -n "$SANDBOX" ] && rm -rf "$SANDBOX"' EXIT

new_sandbox() {
  [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
  SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/ccad-sk.XXXXXX")
  SANDBOX=$(cd "$SANDBOX" && pwd)
  mkdir -p "$SANDBOX/home" "$SANDBOX/target"
}
# install [env KEY=VALUE ...] -- <installer args>
install() {
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  env HOME="$SANDBOX/home" ${envs[@]+"${envs[@]}"} bash "$REPO/install.sh" --no-schedule "$@" > "$SANDBOX/install.out" 2>&1
}

echo "# the default install links the skill and the scripts it calls"
new_sandbox
install -- "$SANDBOX/home/.claude"; rc=$?
assert_eq "$rc" "0" "the install succeeds"
assert_eq "$(readlink "$SANDBOX/home/.claude/skills/autodream")" "$REPO/skills/autodream" "the skill is linked under HOME/.claude/skills"
assert_eq "$(sed -n '2p' "$SANDBOX/home/.claude/skills/autodream/SKILL.md")" "name: autodream" "and its SKILL.md is readable through the link"
assert_eq "$(readlink "$SANDBOX/home/.claude/autodream/pending-triage.sh")" "$REPO/bin/pending-triage.sh" "pending-triage.sh is linked"
assert_eq "$(readlink "$SANDBOX/home/.claude/autodream/report-format.sh")" "$REPO/bin/report-format.sh" "and so is the library it sources"

echo "# a trailing slash on the default dir is still the default"
new_sandbox
install -- "$SANDBOX/home/.claude/"; rc=$?
assert_eq "$rc" "0" "the install succeeds"
assert_eq "$(readlink "$SANDBOX/home/.claude/skills/autodream")" "$REPO/skills/autodream" "the skill is linked"

new_sandbox
install -- "$SANDBOX/home/.claude//"; rc=$?
assert_eq "$rc" "0" "a doubled trailing slash installs"
assert_eq "$(readlink "$SANDBOX/home/.claude/skills/autodream")" "$REPO/skills/autodream" "and still links the skill"

echo "# a custom install dir is not linked, because the skill would not find the scripts"
new_sandbox
install -- "$SANDBOX/target"; rc=$?
assert_eq "$rc" "0" "the install succeeds"
absent "$SANDBOX/home/.claude/skills" "no skill is linked under HOME"
absent "$SANDBOX/target/skills" "and none under the custom dir"
assert_grep "$SANDBOX/install.out" "AUTODREAM_SKILLS_DIR" "the install says how to link it"

echo "# --no-skill leaves the skills dir alone"
new_sandbox
install -- --no-skill "$SANDBOX/home/.claude"; rc=$?
assert_eq "$rc" "0" "the install succeeds"
absent "$SANDBOX/home/.claude/skills" "no skills dir is created"

echo "# AUTODREAM_SKILLS_DIR links there, for a custom install too"
new_sandbox
install AUTODREAM_SKILLS_DIR="$SANDBOX/elsewhere" -- "$SANDBOX/target"; rc=$?
assert_eq "$rc" "0" "the install succeeds"
assert_eq "$(readlink "$SANDBOX/elsewhere/autodream")" "$REPO/skills/autodream" "the skill is linked there"
absent "$SANDBOX/home/.claude/skills" "and not under HOME"

echo "# a skill the user already has is left alone, and the install still finishes"
new_sandbox
mkdir -p "$SANDBOX/home/.claude/skills/autodream"
printf 'mine\n' > "$SANDBOX/home/.claude/skills/autodream/SKILL.md"
install -- "$SANDBOX/home/.claude"; rc=$?
assert_eq "$rc" "0" "the install succeeds"
assert_eq "$(cat "$SANDBOX/home/.claude/skills/autodream/SKILL.md")" "mine" "the user's skill is untouched"
assert_grep "$SANDBOX/install.out" "already exists and is not this repo's" "the install says why"
assert_grep "$SANDBOX/install.out" "/autodream skill not linked" "and that the skill is missing"
linked "$SANDBOX/home/.claude/autodream/run.sh" "the scripts are still linked"

echo "# a symlink the user already has at that name is not replaced"
new_sandbox
mkdir -p "$SANDBOX/home/.claude/skills" "$SANDBOX/mine"
printf 'mine\n' > "$SANDBOX/mine/SKILL.md"
ln -s "$SANDBOX/mine" "$SANDBOX/home/.claude/skills/autodream"
install -- "$SANDBOX/home/.claude"; rc=$?
assert_eq "$rc" "0" "the install succeeds"
assert_eq "$(readlink "$SANDBOX/home/.claude/skills/autodream")" "$SANDBOX/mine" "the user's link still points at their skill"
assert_grep "$SANDBOX/install.out" "already exists and is not this repo's" "and the install says so"

echo "# a link to this repo's skill is refreshed"
new_sandbox
mkdir -p "$SANDBOX/home/.claude/skills"
ln -s "$REPO/skills/autodream" "$SANDBOX/home/.claude/skills/autodream"
install -- "$SANDBOX/home/.claude"; rc=$?
assert_eq "$rc" "0" "a re-install succeeds"
assert_eq "$(readlink "$SANDBOX/home/.claude/skills/autodream")" "$REPO/skills/autodream" "and the link is still ours"

echo "# a link that cannot be made is reported, not announced as done"
new_sandbox
mkdir -p "$SANDBOX/ro"; chmod 555 "$SANDBOX/ro"
install AUTODREAM_SKILLS_DIR="$SANDBOX/ro" -- "$SANDBOX/target"; rc=$?
chmod 755 "$SANDBOX/ro"
assert_eq "$rc" "0" "the install still finishes"
assert_grep "$SANDBOX/install.out" "/autodream skill not linked" "and says the skill is missing"
if grep -qF -- "$SANDBOX/ro/autodream -> " "$SANDBOX/install.out"; then no "and does not print a link line"; else ok "and does not print a link line"; fi

echo "# a dry run links nothing"
new_sandbox
install -- --dry-run "$SANDBOX/home/.claude"; rc=$?
assert_eq "$rc" "0" "the dry run succeeds"
assert_grep "$SANDBOX/install.out" "[dry-run] link $SANDBOX/home/.claude/skills/autodream -> $REPO/skills/autodream" "it says what it would link"
absent "$SANDBOX/home/.claude/skills" "and creates no skills dir"

printf '\npassed: %s   failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
