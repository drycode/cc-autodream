#!/usr/bin/env bash
# install.sh provisions the review triage LaunchAgent beside the nightly one.
#
# HOME is a sandbox and launchctl is a shim that records its calls, so nothing here touches
# this machine's launchd. cmux and claude are fake executables: the installer only needs to
# find them, never run them.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
no()   { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }
assert_eq()   { [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }
assert_grep() { grep -qF -- "$2" "$1" 2>/dev/null && ok "$3" || no "$3 (no [$2] in $1)"; }

SANDBOX=""
cleanup() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

new_sandbox() { # -> sets SANDBOX, FAKE_HOME, LA, CALLS; fake cmux and claude under $SANDBOX/bin
  [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
  SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/ccad-ra.XXXXXX")
  FAKE_HOME="$SANDBOX/home"; LA="$FAKE_HOME/Library/LaunchAgents"
  mkdir -p "$LA" "$SANDBOX/shim" "$SANDBOX/bin"
  CALLS="$SANDBOX/launchctl-calls"; : > "$CALLS"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$CALLS" > "$SANDBOX/shim/launchctl"
  printf '#!/bin/bash\nexit 0\n' > "$SANDBOX/bin/cmux"
  printf '#!/bin/bash\nexit 0\n' > "$SANDBOX/bin/claude"
  chmod +x "$SANDBOX/shim/launchctl" "$SANDBOX/bin/cmux" "$SANDBOX/bin/claude"
}
run_install() { # runs the installer into $SANDBOX/target
  env HOME="$FAKE_HOME" PATH="$SANDBOX/shim:$SANDBOX/bin:/usr/bin:/bin" \
      AUTODREAM_CMUX_DEFAULT="$SANDBOX/no-such-cmux" AUTODREAM_EPHEMERAL_DIRS= \
      bash "$REPO/install.sh" "$SANDBOX/target" > "$SANDBOX/install.out" 2>&1
}
review_plist() { ls "$LA"/*-review.plist 2>/dev/null | head -1; }

echo "# a normal install provisions both agents"
new_sandbox
run_install; rc=$?
assert_eq "$rc" "0" "the install succeeds"
P=$(review_plist)
[ -n "$P" ] && ok "a review plist was written beside the nightly one" || no "a review plist was written beside the nightly one"
NIGHTLY=""; for f in "$LA"/*.plist; do case "$f" in *-review.plist) ;; *) NIGHTLY="$f" ;; esac; done
assert_eq "$(basename "$P" .plist)" "$(basename "$NIGHTLY" .plist)-review" "its label is the nightly label plus -review"
assert_grep "$P" 'exec "$1" "$(date -v-1d +%Y-%m-%d)"' "yesterday's date is evaluated at fire time, not frozen at install"
assert_grep "$P" "$SANDBOX/target/autodream/review.sh" "it runs the installed review.sh"
assert_grep "$P" "<key>CMUX_BIN</key><string>$SANDBOX/bin/cmux</string>" "the resolved cmux path is pinned in its environment"
assert_grep "$P" "<key>CLAUDE_BIN</key><string>$SANDBOX/bin/claude</string>" "so is the resolved claude"
assert_grep "$P" '<key>AUTODREAM_TRIAGE_SURFACE</key><string>cmux</string>' "and the triage surface"
assert_eq "$(grep -c '<key>Hour</key>' "$P")" "5" "it fires on five morning and afternoon triggers"
assert_grep "$CALLS" "bootstrap" "launchctl bootstrap was called"
assert_eq "$(grep -c '^bootstrap' "$CALLS")" "2" "once per agent"
assert_grep "$SANDBOX/install.out" "daily 08:00/09:15/12:15/15:30/18:15" "the install says when it fires"

echo "# without cmux there is no review agent, and a stale one is unloaded"
new_sandbox
rm -f "$SANDBOX/bin/cmux"
run_install; rc=$?
assert_eq "$rc" "0" "the install still succeeds"
[ -z "$(review_plist)" ] && ok "no review plist is written" || no "no review plist is written"
assert_grep "$SANDBOX/install.out" "cmux not found" "the install says why"
grep -qE "^bootout .*-review$" "$CALLS" && ok "any previously provisioned review job is booted out" || no "any previously provisioned review job is booted out"
assert_eq "$(grep -c '^bootstrap' "$CALLS")" "1" "only the nightly agent is bootstrapped"

echo "# a stale review plist is removed, not just unloaded, when cmux disappears"
new_sandbox
run_install >/dev/null; P=$(review_plist)
[ -n "$P" ] && ok "precondition: the first install wrote the review plist" || no "precondition: the first install wrote the review plist"
rm -f "$SANDBOX/bin/cmux"
run_install >/dev/null
[ -z "$(review_plist)" ] && ok "the second install, without cmux, removed it" || no "the second install, without cmux, removed it"

echo "# a config CLAUDE_BIN that points at nothing falls back to the claude on PATH"
new_sandbox
mkdir -p "$SANDBOX/target/autodream"; printf 'CLAUDE_BIN="/stale/no-such-claude"\n' > "$SANDBOX/target/autodream/config"
run_install >/dev/null; P=$(review_plist)
[ -n "$P" ] && ok "the review agent is still provisioned" || no "the review agent is still provisioned"
assert_grep "$P" "<key>CLAUDE_BIN</key><string>$SANDBOX/bin/claude</string>" "and pins the usable claude"

echo "# a path with & is XML-escaped so the plist still lints"
new_sandbox
mkdir -p "$SANDBOX/a&b"; mv "$SANDBOX/bin/cmux" "$SANDBOX/a&b/cmux"
mkdir -p "$SANDBOX/target/autodream"; printf 'CMUX_BIN="%s"\n' "$SANDBOX/a&b/cmux" > "$SANDBOX/target/autodream/config"
run_install; rc=$?
assert_eq "$rc" "0" "the install succeeds"
P=$(review_plist)
assert_grep "$P" "a&amp;b/cmux" "the ampersand is escaped"
if command -v plutil >/dev/null 2>&1; then plutil -lint "$P" >/dev/null 2>&1 && ok "the plist passes plutil -lint" || no "the plist passes plutil -lint"; fi

echo "# a refused nightly schedule provisions no review agent either"
new_sandbox
U=$(id -un | tr -dc 'a-zA-Z0-9')
cat > "$LA/com.$U.autodream.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>com.$U.autodream</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>/elsewhere/run.sh</string></array></dict></plist>
PL
run_install; rc=$?
assert_eq "$rc" "0" "a refusal does not fail the install"
[ -z "$(review_plist)" ] && ok "no review plist is written" || no "no review plist is written"

printf '\npassed: %s   failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
