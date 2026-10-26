#!/bin/bash
# Contract tests for the claude adapter.
#
# This adapter invents no behavior — every subcommand delegates to the script
# that already implements it. What these tests pin is the CONTRACT: exit codes,
# atomic output, and the two path shapes a Claude session can have.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
A="$REPO/adapters/claude/adapter.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

[ -x "$A" ] || { printf '  FAIL - adapters/claude/adapter.sh missing or not executable\n'
                 printf '\npassed: 0   failed: 1\n'; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/adclaude.XXXXXX")

# Cleanup lives in a trap because this suite parks a process that blocks forever
# on purpose. The FIFO test below starts a `slim` whose first read waits for a
# writer that never comes. Both cleanups used to sit on the last lines of the
# file, so a run that ended any other way — Ctrl-C, a harness timeout, an early
# exit — reached neither, and the delegate was reparented to init and blocked
# for good.
#
# Measured, not hypothesised: 22 interrupted runs over about 90 minutes on
# 2026-08-26 left 66 slim-transcript.sh processes alive. They were still there
# nine days later, each holding a FIFO open in a temp directory that had already
# been deleted.
#
# A trap is safe HERE in a way it is not in adapters/claude/adapter.sh, which
# documents the opposite conclusion and issue #57 explains at length. The
# difference is not that this suite is interruptible and that one is not. Bash
# defers a trapped signal until the FOREGROUND child returns in both, and a
# foreground `sleep` is NOT interruptible — measured on bash 5.3.15 and on
# /bin/bash 3.2.57, a trapped TERM sent 1s into `sleep 5` fires at t=5, while
# the same signal during `wait` fires at t=1.
#
# The difference is that the deferral is BOUNDED here and unbounded there. Every
# foreground child in this file is a `sleep 0.05` or faster, so the worst case
# is a signal handled 50ms late. adapter.sh's foreground child is the delegate
# itself, which blocks forever on the FIFO, so a trap there converts a prompt
# death into a hang.
# Reap by PROCESS GROUP, never by name. Two rounds of #62 review went into this
# and both were spent on `pkill -f`, which is the wrong tool twice over: it
# matches an unanchored REGEX, so an interpolated $TMPDIR of /tmp/a[b] silently
# matched nothing, and once $TMPDIR was out of the pattern the mktemp suffix
# still identified the run only probabilistically. A pattern names processes by
# what they look like; the group names exactly the ones this run started.
#
# `set -m` around the launch puts the adapter in its own process group, so the
# delegate and the two bash subshells beneath it inherit that pgid. Killing the
# negative pid reaches all of them in one call, and it keeps working after the
# adapter dies: a reparented child keeps its process group.
reap_delegate() {
  [ -n "${slim_pgid:-}" ] || return 0
  kill -TERM -"$slim_pgid" 2>/dev/null
  kill -KILL -"$slim_pgid" 2>/dev/null
  return 0
}

cleanup() {
  # Both guards below default under `set -u`: the FIFO branch may never have run
  # (no mkfifo), leaving $slim_pgid unset, and the trap is armed before $tmp is
  # guaranteed populated.
  reap_delegate
  [ -n "${tmp:-}" ] && [ -d "${tmp:-}" ] && rm -rf "$tmp"
  return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Can this host read a process state at all? An empty read from `ps` means two
# different things below: "the process is gone" (ps ran, found nothing) and "ps
# cannot run" (a sandbox answered `Operation not permitted`). Folding the second
# into the first made the SIGTERM assertion pass without testing anything. This
# asks `ps` about the suite's own shell, which is certainly alive, so an empty
# answer here can only mean ps is unusable.
ps_usable() {
  [ -n "$(ps -o state= -p $$ 2>/dev/null | tr -d ' ')" ]
}

echo "# claude adapter: the ps probe notices a ps that cannot run"
psstub="$tmp/psstub"; mkdir -p "$psstub"
printf '#!/bin/sh\necho "ps: Operation not permitted" >&2\nexit 1\n' > "$psstub/ps"
chmod +x "$psstub/ps"
if PATH="$psstub:$PATH" ps_usable; then
  no "ps_usable reported a ps that fails to execute as usable"
else
  ok "ps_usable rejects a ps that fails to execute"
fi

# A real cwd to resolve against, created inside the sandbox so the test owns it.
proj="$tmp/proj a"          # a space, because NUL transport is supposed to allow it
mkdir -p "$proj"
projreal=$(cd "$proj" && pwd -P)

# Session at the normal depth: <root>/projects/<bucket>/<file>.jsonl
mkdir -p "$tmp/root/projects/-bucket"
S="$tmp/root/projects/-bucket/s1.jsonl"
printf '%s\n' \
  "{\"type\":\"user\",\"cwd\":\"$projreal\",\"message\":{\"content\":\"hello\"}}" \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}' > "$S"

echo "# claude adapter: project returns the resolved cwd, not the bucket name"
assert_eq "$("$A" project "$S")" "$projreal" "resolved cwd from the transcript"
if "$A" project "$tmp/root/projects/-bucket/nope.jsonl" >/dev/null 2>&1; then
  no "a missing session exits nonzero"
else ok "a missing session exits nonzero"; fi

echo "# claude adapter: normalize is a verbatim copy for this harness"
out="$tmp/norm.jsonl"
if "$A" normalize "$S" "$out"; then ok "normalize exits 0"; else no "normalize exits 0"; fi
if cmp -s "$S" "$out"; then ok "normalize copied the file verbatim"; else no "normalize copied the file verbatim"; fi
# Glob, not a literal. mktemp creates `<out>.tmp.XXXXXX`, so `<out>.tmp` names a
# path nothing ever creates and the assertion passed against a leaking
# implementation. This was the third copy of that same mistake — the two in
# adapter-contract.sh were fixed a commit earlier and this one was missed,
# because it was the assertion nobody had reason to re-read.
set -- "$out".tmp*
if [ -e "$1" ]; then no "no temp left behind (found $(basename "$1"))"; else ok "no temp left behind"; fi

echo "# claude adapter: a failed normalize leaves no partial output"
if "$A" normalize "$tmp/missing.jsonl" "$tmp/partial.jsonl" 2>/dev/null; then
  no "missing input exits nonzero"
else ok "missing input exits nonzero"; fi
if [ -e "$tmp/partial.jsonl" ]; then no "no partial output on failure"; else ok "no partial output on failure"; fi

echo "# claude adapter: stats writes a sidecar with numeric transcript_bytes"
if "$A" stats "$S" "$tmp/s1.stats.json" 2>/dev/null; then ok "stats exits 0"; else no "stats exits 0"; fi
if jq -e '.transcript_bytes | numbers' "$tmp/s1.stats.json" >/dev/null 2>&1; then
  ok "the sidecar has a numeric transcript_bytes"
else no "the sidecar has a numeric transcript_bytes"; fi
# stats was the one writing subcommand with no cleanup assertion at all, in
# either suite. normalize and slim each got one; stats writes a temp exactly the
# same way and nothing looked for it, so it could produce a valid sidecar and
# leak its temp on every session with the whole suite green.
set -- "$tmp"/s1.stats.json.tmp*
if [ -e "$1" ]; then no "stats left no temp (found $(basename "$1"))"; else ok "stats left no temp"; fi

echo "# claude adapter: slim writes a reduced copy"
if "$A" slim "$S" "$tmp/slim.jsonl" 2>/dev/null; then ok "slim exits 0"; else no "slim exits 0"; fi
if [ -s "$tmp/slim.jsonl" ]; then ok "slim wrote output"; else no "slim wrote output"; fi

echo "# claude adapter: a signalled slim dies promptly and writes no destination"
# Two properties, and the second one is here because trying to add a third broke
# it. The temp-and-rename wrap must keep a partial write out of the destination
# when a run is killed, AND the adapter must still die when signalled.
#
# It does NOT assert the temp is cleaned up. That would demand a signal trap, and
# a trap makes this worse: bash defers a trapped signal until the foreground
# child returns, so the adapter ignores SIGTERM for as long as the delegate runs.
# The version of this test that asserted temp cleanup hung for the full timeout
# against exactly that fix and left orphaned delegates behind. The stale temp is
# tracked as an issue; the responsiveness assertion below is what stops a future
# reader from "fixing" the leak the obvious way.
#
# The interrupt is made deterministic with a FIFO. `[ -r ]` on it succeeds, so
# the delegate starts and its first read blocks forever with no writer, which
# parks the adapter at a known point AFTER mktemp and BEFORE the rename.
fifodir="$tmp/fifo"; mkdir -p "$fifodir"
mkfifo "$fifodir/src.jsonl" 2>/dev/null
if [ -p "$fifodir/src.jsonl" ]; then
  # Monitor mode only around the launch: it gives this job its own process group
  # (pgid == pid) so reap_delegate can signal the whole tree. Restored right
  # after, because job control changes behaviour for everything that follows.
  set -m
  "$A" slim "$fifodir/src.jsonl" "$fifodir/out.jsonl" >/dev/null 2>&1 &
  slim_pid=$!
  set +m
  slim_pgid=$slim_pid
  # Wait for the temp to APPEAR before signalling. A busy spin returns long
  # before the adapter has reached mktemp, and killing it that early makes the
  # assertion below vacuous — it passed against the untrapped code exactly once,
  # for that reason. Poll on a real interval and assert the temp existed, so a
  # test that never opened the window fails instead of reporting success.
  waited=0; saw_tmp=0
  while [ "$waited" -lt 100 ]; do
    set -- "$fifodir"/out.jsonl.tmp*
    if [ -e "$1" ]; then saw_tmp=1; break; fi
    sleep 0.05
    waited=$((waited + 1))
  done
  if [ "$saw_tmp" = "1" ]; then ok "the temp was observed before signalling"
  else no "the temp never appeared, so the interrupt assertions prove nothing"; fi
  kill -TERM "$slim_pid" 2>/dev/null
  # Poll for the adapter to actually go away rather than blocking in `wait`. A
  # bare `wait` on a process that ignores the signal hangs the suite instead of
  # failing it, which is how the trapped version presented.
  # Read the process STATE, not `kill -0`. A background child that has exited
  # stays a zombie until the shell reaps it, and `kill -0` succeeds on a zombie —
  # so a `kill -0` poll here reports "did not terminate" for a process that
  # already did, depending entirely on when bash got round to reaping. That is a
  # test that fails on a busy CI machine and passes locally. An empty state means
  # gone; Z means exited and not yet reaped. Both are termination.
  # An unusable ps FAILS the assertion rather than skipping it: this is the check
  # that stops a signal trap being re-added to the adapter, and a quiet skip would
  # stop it doing that on exactly the hosts where ps is restricted.
  died=0; waited=0; psok=0
  if ps_usable; then
    psok=1
    while [ "$waited" -lt 60 ]; do
      st=$(ps -o state= -p "$slim_pid" 2>/dev/null | tr -d ' ')
      case "$st" in ""|Z*) died=1; break ;; esac
      sleep 0.05
      waited=$((waited + 1))
    done
  fi
  if [ "$psok" = "0" ]; then
    no "ps is unavailable, so the SIGTERM assertion cannot be evaluated"
    kill -9 "$slim_pid" 2>/dev/null
  elif [ "$died" = "1" ]; then
    ok "a signalled slim terminates instead of ignoring SIGTERM"
  else
    no "a signalled slim did not terminate within 3s"
    kill -9 "$slim_pid" 2>/dev/null
  fi
  wait "$slim_pid" 2>/dev/null
  reap_delegate
  if [ -e "$fifodir/out.jsonl" ]; then
    no "a signalled slim wrote no destination file"
  else
    ok "a signalled slim wrote no destination file"
  fi
else
  ok "mkfifo unavailable here; skipped the interrupt test"
fi

echo "# claude adapter: is-self defers to the one self-pollution predicate"
W="$tmp/root/projects/-bucket/worker.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"Session transcript to analyze (literal absolute path): /x"}}' > "$W"
if "$A" is-self "$W"; then ok "an autodream worker transcript is ours"; else no "an autodream worker transcript is ours"; fi
if "$A" is-self "$S"; then no "a real session is not ours"; else ok "a real session is not ours"; fi

echo "# claude adapter: an unknown subcommand exits 2, never 0"
"$A" not-a-subcommand >/dev/null 2>&1; assert_eq "$?" "2" "unknown subcommand exits 2"

# $tmp and any parked delegate are removed by the EXIT trap, which also covers
# the paths that never reach this line.
echo "# l2-argv: Glob and Read only, and no model unless one is named"
L2=$(CLAUDE_BIN=/opt/test/claude "$A" l2-argv | tr '\0' '\n')
assert_eq "$(printf '%s\n' "$L2" | sed -n '1p')" "/opt/test/claude" "the engine binary comes first"
assert_eq "$(printf '%s\n' "$L2" | sed -n '/^--tools$/{n;p;n;p;}' | tr '\n' ' ')" "Glob Read " "L2 holds Glob and Read"
case "$L2" in *--model*) no "no --model without a model" ;; *) ok "no --model without a model" ;; esac
assert_eq "$(CLAUDE_BIN=/opt/test/claude "$A" l2-argv opus | tr '\0' '\n' | sed -n '/^--model$/{n;p;}')" "opus" "a named model is passed through"
case "$L2" in *AUTODREAM_REPORT_END*AUTODREAM_PINS_BEGIN*) ok "the system prompt carries the sentinel grammar" ;; *) no "the system prompt carries the sentinel grammar" ;; esac

echo "# l1-argv reproduces the invocation run.sh hard-coded before the engine moved behind the adapter"
# The expected text is copied from run.sh as it stood at b473c6f6d (the dispatch_l1 call), not
# derived from the adapter, so this fails if the adapter and the old nightly ever disagree.
OLD_SYSPROMPT="Headless triage worker. Read the session transcript and write exactly one findings JSON object, via the Write tool, to the literal output path given on line 2 of the prompt. Those paths are literal strings, not shell variables — never \$-expand them. Print only the literal word done and exit."
OLD_SETTINGS="{\"disableAllHooks\":true}"
printf '%s\0' /opt/test/claude --print --permission-mode bypassPermissions --model claude-haiku-5-5 --effort high \
  --no-session-persistence --tools Read Write --disable-slash-commands --strict-mcp-config \
  --settings "$OLD_SETTINGS" --system-prompt "$OLD_SYSPROMPT" > "$tmp/old-argv"
CLAUDE_BIN=/opt/test/claude "$A" l1-argv claude-haiku-5-5 > "$tmp/new-argv"
if cmp -s "$tmp/old-argv" "$tmp/new-argv"; then ok "the claude L1 argv is the old hard-coded one with --effort high and --system-prompt"
else no "the claude L1 argv is the old hard-coded one with --effort high and --system-prompt"; fi
echo "# l1 effort: env override, off, and an invalid level"
assert_eq "$(AUTODREAM_L1_EFFORT=low CLAUDE_BIN=/opt/test/claude "$A" l1-argv m | tr '\0' '\n' | sed -n '/^--effort$/{n;p;}')" "low" "AUTODREAM_L1_EFFORT sets the level"
assert_eq "$(AUTODREAM_L1_EFFORT=low AUTODREAM_L1_EFFORT_CLAUDE=max CLAUDE_BIN=/opt/test/claude "$A" l1-argv m | tr '\0' '\n' | sed -n '/^--effort$/{n;p;}')" "max" "the per-adapter variable wins"
assert_eq "$(AUTODREAM_L1_EFFORT=off CLAUDE_BIN=/opt/test/claude "$A" l1-argv m | tr '\0' '\n' | grep -c '^--effort$')" "0" "off omits the flag"
if AUTODREAM_L1_EFFORT=turbo CLAUDE_BIN=/opt/test/claude "$A" l1-argv m >/dev/null 2>&1; then no "an unknown level is refused"; else ok "an unknown level is refused"; fi
assert_eq "$(CLAUDE_BIN=/opt/test/claude "$A" engine-bin)" "/opt/test/claude" "engine-bin honors CLAUDE_BIN"
assert_eq "$(env -u CLAUDE_BIN HOME=/h "$A" engine-bin)" "/h/.local/bin/claude" "engine-bin defaults to the installer's location"
assert_eq "$("$A" l1-env | tr '\n' ' ')" "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 " "l1-env is the lean-query environment"

echo "# warmup-argv: the worker's flags with a one-word system prompt"
WA=$(CLAUDE_BIN=/opt/test/claude "$A" warmup-argv claude-haiku-5-5 | tr '\0' '\n')
assert_eq "$(printf '%s\n' "$WA" | tail -1)" "Reply with the single word ok and exit." "the system prompt asks for one word"
LA=$(CLAUDE_BIN=/opt/test/claude "$A" l1-argv claude-haiku-5-5 | tr '\0' '\n')
# Everything but the tools list and the system prompt must match the worker's, so the warmup takes the same auth path.
assert_eq "$(printf '%s\n' "$WA" | sed -n '1,/^--tools$/p' | sed '$d')" "$(printf '%s\n' "$LA" | sed -n '1,/^--tools$/p' | sed '$d')" "the flags before --tools match the worker's"

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
