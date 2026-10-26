#!/usr/bin/env bash
# Tests for bin/autodream-now.sh's launch guard (#78).
#
# Every on-demand run for an install shares one launchd label. The script used to
# `launchctl bootout` that label unconditionally before `bootstrap`, so launching a
# second date while the first was still running evicted the first mid-run: no report,
# no error, orphaned workers. The guard refuses to launch over a live process.
#
# launchctl is a mock on PATH; nothing here touches the real launchd.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SUT="$REPO/bin/autodream-now.sh"

PASS=0
FAIL=0
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
nope() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else nope "$3" "want [$1] got [$2]"; fi; }

mkdir -p "$SANDBOX/bin" "$SANDBOX/install" "$SANDBOX/dreams" "$SANDBOX/LaunchAgents"
CALLS="$SANDBOX/calls"
# MOCK_STATE: running = loaded with a live pid, idle = loaded with no process, absent = not loaded.
cat > "$SANDBOX/bin/launchctl" <<'MOCK'
#!/bin/bash
echo "$*" >> "$MOCK_CALLS"
case "$1" in
  print)
    [ "$MOCK_STATE" = absent ] && exit 113
    echo "gui/501/label = {"
    echo "	state = $MOCK_STATE"
    [ "$MOCK_STATE" = running ] && printf '\tpid = 4242\n\tpid = 4243\n\tpid = 4244\n\tpid = 4245\n' 
    echo "}"
    ;;
esac
exit 0
MOCK
chmod +x "$SANDBOX/bin/launchctl"

launch() { # launch <date> <state> -> runs the SUT, sets OUT and RC
  : > "$CALLS"
  OUT="$(PATH="$SANDBOX/bin:$PATH" MOCK_CALLS="$CALLS" MOCK_STATE="$2" \
    AUTODREAM_DIR="$SANDBOX/install" DREAMS_DIR="$SANDBOX/dreams" \
    LAUNCH_AGENTS_DIR="$SANDBOX/LaunchAgents" bash "$SUT" "$1" 2>&1)"
  RC=$?
}
verbs() { awk '{print $1}' "$CALLS" | tr '\n' ' '; }

echo "# a first launch, nothing loaded"
launch 2020-01-01 absent
assert_eq "0" "$RC" "launch with no prior job succeeds"
assert_eq "bootstrap " "$(verbs | sed 's/print //;s/bootout //')" "it bootstraps the job"

echo "# the previous job finished: its label is still loaded, with no process"
launch 2020-01-02 idle
assert_eq "0" "$RC" "launch over a finished job succeeds"
case "$(verbs)" in *bootout*bootstrap*) ok "it boots the finished job out, then bootstraps" ;; *) nope "it boots the finished job out, then bootstraps" "calls: $(verbs)" ;; esac

echo "# the previous job is still running"
launch 2020-01-03 idle   # writes the holder plist
launch 2020-01-04 running
[ "$RC" -ne 0 ] && ok "a second date is refused while the first is running" || nope "a second date is refused while the first is running" "rc=$RC out=$OUT"
case "$(verbs)" in *boot*) nope "no bootout or bootstrap happened" "calls: $(verbs)" ;; *) ok "no bootout or bootstrap happened" ;; esac
case "$OUT" in *2020-01-03*) ok "the message names the date that holds the label" ;; *) nope "the message names the date that holds the label" "out: $OUT" ;; esac
LAST_DATE="$(sed -n 's#.*<string>\([0-9]\{4\}-[0-9][0-9]-[0-9][0-9]\)</string>.*#\1#p' "$SANDBOX"/install/*.plist)"
assert_eq "2020-01-03" "$LAST_DATE" "the holder's plist was not overwritten"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
