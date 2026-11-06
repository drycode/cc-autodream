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

# ------------------------------------------------- the scheduled job's environment --
make_sched() { # make_sched <label> <runner-dir> <env-dict-body>
  cat > "$SANDBOX/LaunchAgents/$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$1</string>
    <key>ProgramArguments</key>
    <array><string>/bin/bash</string><string>$2/run.sh</string></array>
    <key>EnvironmentVariables</key>
    <dict>
$3
    </dict>
</dict>
</plist>
PLIST
}
dry() { # dry [VAR=value ...] -> OUT, RC: a --dry-run with extra caller env
  OUT="$(env PATH="$SANDBOX/bin:$PATH" AUTODREAM_DIR="$SANDBOX/install" DREAMS_DIR="$SANDBOX/dreams" \
    LAUNCH_AGENTS_DIR="$SANDBOX/LaunchAgents" "$@" bash "$SUT" 2020-03-01 --dry-run 2>&1)"
  RC=$?
}
has() { case "$OUT" in *"$1"*) ok "$2" ;; *) nope "$2" "no [$1] in: $OUT" ;; esac; }
lacks() { case "$OUT" in *"$1"*) nope "$2" "unexpected [$1] in: $OUT" ;; *) ok "$2" ;; esac; }

echo "# the one-shot job gets this install's scheduled environment"
make_sched com.test.autodream "$SANDBOX/install" \
'        <key>CLAUDE_CONFIG_DIR</key><string>/x/claude-profile</string>
        <key>PATH</key><string>/sched/only/path</string>
        <key>ODD_VALUE</key><string>a&amp;b&lt;c&gt;</string>'
dry
assert_eq "0" "$RC" "the dry run succeeds"
has "<key>CLAUDE_CONFIG_DIR</key><string>/x/claude-profile</string>" "the login setting is copied"
has "<string>a&amp;b&lt;c&gt;</string>" "copied values stay XML-escaped"
lacks "/sched/only/path" "PATH stays the one-shot's own"
has "env from the scheduled job: CLAUDE_CONFIG_DIR ODD_VALUE" "the copied keys are named"
sed -n '/^<?xml/,/^<\/plist>/p' <<<"$OUT" > "$SANDBOX/dry.plist"
plutil -lint "$SANDBOX/dry.plist" >/dev/null 2>&1 && ok "the generated plist lints" || nope "the generated plist lints" "$(plutil -lint "$SANDBOX/dry.plist" 2>&1)"

echo "# the plist written for a real launch is owner-only"
launch 2020-03-02 absent
WRITTEN="$(ls "$SANDBOX"/install/com.test.autodream.ondemand.*.plist 2>/dev/null | head -n 1)"
assert_eq "600" "$(stat -f %Lp "$WRITTEN" 2>/dev/null)" "the on-demand plist is mode 600"
rm -f "$SANDBOX/LaunchAgents/com.test.autodream.plist"

echo "# another install's job is never read, even on the label"
mkdir -p "$SANDBOX/elsewhere"
make_sched com.test.autodream "$SANDBOX/elsewhere" \
'        <key>CLAUDE_CONFIG_DIR</key><string>/other/install/profile</string>'
dry
lacks "/other/install/profile" "another install's environment is not copied"
has "env from the scheduled job: none" "it says nothing was copied"
rm -f "$SANDBOX/LaunchAgents/com.test.autodream.plist"

echo "# the caller's own shell environment is not copied"
dry CLAUDE_CONFIG_DIR=/caller/shell/profile
lacks "/caller/shell/profile" "a caller's CLAUDE_CONFIG_DIR does not reach the job"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
