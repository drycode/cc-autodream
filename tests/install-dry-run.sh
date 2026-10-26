#!/usr/bin/env bash
# install.sh --dry-run changes nothing, and --adapters / --l2-engine write one managed config section.
#
# HOME is a sandbox and launchctl is a shim that records its calls; the cutover is rehearsed with
# --dry-run on the real host, so a dry run that wrote anything would be the bug.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
no()   { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }
assert_eq()    { [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }
assert_grep()  { grep -qF -- "$2" "$1" 2>/dev/null && ok "$3" || no "$3 (no [$2] in $1)"; }
assert_nogrep(){ grep -qF -- "$2" "$1" 2>/dev/null && no "$3 (unexpected [$2] in $1)" || ok "$3"; }

SANDBOX=""
cleanup() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

new_sandbox() {
  [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
  SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/ccad-dr.XXXXXX")
  FAKE_HOME="$SANDBOX/home"; LA="$FAKE_HOME/Library/LaunchAgents"
  mkdir -p "$LA" "$SANDBOX/shim" "$SANDBOX/bin"
  CALLS="$SANDBOX/launchctl-calls"; : > "$CALLS"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$CALLS" > "$SANDBOX/shim/launchctl"
  printf '#!/bin/bash\nexit 0\n' > "$SANDBOX/bin/cmux"
  printf '#!/bin/bash\nexit 0\n' > "$SANDBOX/bin/claude"
  chmod +x "$SANDBOX/shim/launchctl" "$SANDBOX/bin/cmux" "$SANDBOX/bin/claude"
}
run_install() { # args are installer args
  env HOME="$FAKE_HOME" PATH="$SANDBOX/shim:$SANDBOX/bin:/usr/bin:/bin" \
      AUTODREAM_CMUX_DEFAULT="$SANDBOX/no-such-cmux" AUTODREAM_EPHEMERAL_DIRS= \
      bash "$REPO/install.sh" "$@" > "$SANDBOX/install.out" 2>&1
}
tree_of() { (cd "$SANDBOX" && find . -path ./install.out -prune -o -path ./launchctl-calls -prune -o -print | sort); }

echo "# --dry-run writes, links and loads nothing"
new_sandbox
BEFORE=$(tree_of)
run_install --dry-run "$SANDBOX/target"; rc=$?
assert_eq "$rc" "0" "the dry run succeeds"
assert_eq "$(tree_of)" "$BEFORE" "the filesystem is byte-for-byte the same afterwards"
assert_eq "$(wc -c < "$CALLS" | tr -d ' ')" "0" "launchctl was never invoked"
assert_grep "$SANDBOX/install.out" "DRY RUN" "it says it is a dry run"
assert_grep "$SANDBOX/install.out" "[dry-run] link $SANDBOX/target/autodream/run.sh -> $REPO/bin/run.sh" "it lists the links it would make"
for f in bin/triage-dream.sh bin/dream-grounding.sh; do
  assert_grep "$SANDBOX/install.out" "[dry-run] link $SANDBOX/target/autodream/$(basename "$f") -> $REPO/$f" "it links $(basename "$f")"
done
assert_grep "$SANDBOX/install.out" "[dry-run] link $SANDBOX/target/autodream/TRIAGE_DREAM.md -> $REPO/prompts/TRIAGE_DREAM.md" "and the triage prompt"
assert_grep "$SANDBOX/install.out" "[dry-run] launchctl bootstrap" "and the launchctl calls it would make"
assert_grep "$SANDBOX/install.out" "would write $LA/" "and where each plist would go"
assert_grep "$SANDBOX/install.out" 'exec "$1" "$(date -v-1d +%Y-%m-%d)"' "it shows the review plist it generated"
assert_nogrep "$SANDBOX/install.out" "ERROR" "with no errors"

echo "# a dry run leaves no scratch directory behind, even when it refuses"
LEFT_BEFORE=$(ls -d "${TMPDIR:-/tmp}"/ccad-dry.* 2>/dev/null | wc -l | tr -d ' ')
echo "# a dry run reports the refusal a real install would hit"
new_sandbox
U=$(id -un | tr -dc 'a-zA-Z0-9')
cat > "$LA/com.$U.autodream.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>com.$U.autodream</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>/elsewhere/run.sh</string></array></dict></plist>
PL
BEFORE=$(cat "$LA/com.$U.autodream.plist")
run_install --dry-run "$SANDBOX/target"; rc=$?
assert_eq "$rc" "0" "the dry run still exits 0"
assert_grep "$SANDBOX/install.out" "already scheduled by" "and names the conflict"
assert_eq "$(cat "$LA/com.$U.autodream.plist")" "$BEFORE" "the foreign plist is untouched"
assert_eq "$(ls -d "${TMPDIR:-/tmp}"/ccad-dry.* 2>/dev/null | wc -l | tr -d ' ')" "$LEFT_BEFORE" "no ccad-dry scratch directory was left in TMPDIR"
"$REPO/install.sh" --help | grep -q 'set -eu' && no "--help prints only the usage block" || ok "--help prints only the usage block"

echo "# --adapters and --l2-engine write one managed section, replaced on re-install"
new_sandbox
run_install --no-schedule --adapters claude,omp --l2-engine omp "$SANDBOX/target"; rc=$?
assert_eq "$rc" "0" "the install succeeds"
C="$SANDBOX/target/autodream/config"
assert_grep "$C" "AUTODREAM_ADAPTERS=claude,omp" "the adapters are in the config"
assert_grep "$C" "AUTODREAM_L2_ENGINE=omp" "and the L2 engine"
run_install --no-schedule --adapters claude "$SANDBOX/target"
assert_eq "$(grep -c '^AUTODREAM_ADAPTERS=' "$C")" "1" "a re-install replaces the adapters line, it does not stack another"
assert_grep "$C" "AUTODREAM_ADAPTERS=claude" "with the new value"
assert_eq "$(grep -c '^# adapters (managed by install.sh)' "$C")" "1" "and keeps a single marker"
assert_grep "$C" "AUTODREAM_L2_ENGINE=omp" "and the L2 engine given earlier is kept, not dropped"
run_install --no-schedule "$SANDBOX/target"
assert_grep "$C" "AUTODREAM_ADAPTERS=claude" "an install with no flags leaves the section alone"
assert_grep "$C" "SESSION_ROOTS=" "and the session-roots section is still there"

echo "# bad values are refused before anything is written"
new_sandbox
run_install --no-schedule --adapters claude,nonesuch "$SANDBOX/target"; rc=$?
assert_eq "$rc" "64" "an unknown adapter exits 64"
[ ! -e "$SANDBOX/target" ] && ok "and nothing was installed" || no "and nothing was installed"
run_install --no-schedule --l2-engine "../x" "$SANDBOX/target"; rc=$?
assert_eq "$rc" "64" "a path-like engine name exits 64"
run_install --no-schedule --adapters; rc=$?
assert_eq "$rc" "64" "a missing value exits 64"

printf '\npassed: %s   failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
