#!/bin/bash
# Oh My Pi (omp) harness adapter.
#
# An OMP session is an append-only tree, not a flat transcript, so unlike the claude
# adapter this one has real work to do: `normalize` linearizes the tree to the live
# conversation (linearize.sh), and `stats` reads omp's own record shapes (stats.sh).
# `slim`, `is-self` and the enumeration walk reuse the shared scripts, which already
# understand omp records.
#
# The session store is $HOME/.omp/agent/sessions/<project-encoded>/<stamp>_<uuid>.jsonl.
# Child sessions sit in a directory named after the parent file
# (<stamp>_<uuid>/__advisor.jsonl, <stamp>_<uuid>/<Name>.jsonl) and ARE sessions to triage.
set -u

# cd -P for the same reason as the claude adapter: follow the install's symlinks
# physically, so ADIR is the real adapters/omp and BIN the real bin/.
ADIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN=$(cd -P "$ADIR/../../bin" && pwd)

# Which omp runs. An explicit OMP_BIN wins, for pinning a build; then PATH; then the places
# omp installs to, because a launchd job has a minimal PATH. On 2026-08-25 a 17.3.7-versus-
# 18.0.4 split between PATH and the hard-coded default cost half of every L1 round to
# provider 400s, and nothing in the log said which omp ran.
omp_bin() {
  local c
  if [ -n "${OMP_BIN:-}" ]; then printf '%s' "$OMP_BIN"; return 0; fi
  c=$(command -v omp 2>/dev/null || true)
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  for c in "$HOME/.local/bin/omp" "$HOME/.bun/bin/omp" /opt/homebrew/bin/omp /usr/local/bin/omp; do
    if [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
  done
  printf '%s' omp
}

cmd="${1:-}"
[ "$#" -gt 0 ] && shift

# Run "$@" writing a unique temp beside $dest, then rename. A nonzero exit leaves no
# $dest and no temp; a directory at $dest is refused up front (see the claude adapter
# for why `mv` into one reports success while writing nothing where the caller looks).
atomic() { # $1=dest, rest = command taking the temp path as its LAST argument
  local dest="$1" t; shift
  [ ! -d "$dest" ] || return 1
  t=$(mktemp "$dest.tmp.XXXXXX" 2>/dev/null) || return 1
  "$@" "$t" || { rm -f "$t"; return 1; }
  mv -f "$t" "$dest" 2>/dev/null || { rm -f "$t"; return 1; }
  [ -f "$dest" ] || { rm -f "$dest/$(basename "$t")" 2>/dev/null; return 1; }
}

case "$cmd" in

  enumerate) # $1=root $2=target-date $3=next-date -> NUL-delimited session paths
    # $2 and $3 are an mtime window and nothing more. The runner passes a $3 far in the
    # future when it places a session in a day by the timestamps inside the transcript
    # (bin/session-window.sh), which turns this into a lower bound only and keeps the
    # adapter contract free of any knowledge of that window.
    # stderr is kept: find exits 1 for an unreadable directory and the runner has to
    # tell a partial corpus from a failed root on that status.
    find "$1" -type f -name '*.jsonl' \
         -newermt "$2 00:00:00" \
         ! -newermt "$3 00:00:00" \
         -print0
    ;;

  normalize) # $1=in $2=out
    [ "$#" -ge 2 ] || exit 2
    # linearize.sh is its own atomic writer, refuses a directory destination, and exits
    # nonzero with no output for anything it cannot prove is the live conversation.
    "$ADIR/linearize.sh" "$1" "$2" || exit 1
    ;;

  project) # $1=session -> the session's real working directory
    [ -r "$1" ] || exit 1
    # The session header carries the cwd. A linearized copy carries it in autodream_meta,
    # so either shape answers. jq, not grep: a cwd with a quote or backslash is
    # JSON-escaped and a regex over the raw line truncates it.
    cwd=$(jq -re 'select((.type == "session" or .type == "autodream_meta") and (.cwd | type) == "string") | .cwd' "$1" 2>/dev/null | head -1)
    [ -n "$cwd" ] || exit 1
    realpath "$cwd" 2>/dev/null || exit 1
    ;;

  stats) # $1=session (raw or normalized) $2=out
    [ "$#" -ge 2 ] || exit 2
    atomic "$2" "$ADIR/stats.sh" "$1" || exit 1
    ;;

  slim) # $1=in $2=out
    [ "$#" -ge 2 ] || exit 2
    atomic "$2" "$BIN/slim-transcript.sh" "$1" || exit 1
    ;;

  is-self) # $1=session -> exit 0 if this is one of autodream's own transcripts
    # Same readability guard as every sibling: an unreadable file must not answer "not
    # ours", because that is the answer a real user session gets.
    [ -r "$1" ] || exit 3
    exec "$BIN/prune-self-sessions.sh" --is-self "$1"
    ;;

  engine-bin) # -> the omp this adapter runs: an absolute path, or the bare name when none was found
    printf '%s\n' "$(omp_bin)"
    ;;

  l1-argv) # $1=model -> NUL-delimited argv for one L1 worker; the prompt arrives on stdin
    [ "$#" -ge 1 ] && [ -n "$1" ] || exit 2
    # The invocation omp-autodream runs today, so a night on the unified runner is the same
    # worker. Three of the flags are load-bearing and each cost a night to learn:
    #   --config <overlay>   turns off the advisor, local provider probes (a sleeping Mac made
    #                        them take 3.6s each) and first-turn mnemopi recall, which made
    #                        headless workers exit 0 with empty stdout before any model call.
    #   --tools=Read,Write   read the transcript, write the findings JSON, nothing else.
    #   --no-session         leave no transcript, so the next night does not triage this one.
    printf '%s\0' "$(omp_bin)" \
      --allow-home \
      -p \
      --approval-mode yolo \
      --no-session \
      --config "${NO_ADVISOR_CFG:-$ADIR/l1-no-advisor.yml}" \
      --model "$1" \
      --tools=Read,Write \
      --append-system-prompt 'Headless triage worker. Read the session transcript and write exactly one findings JSON object, via the Write tool, to the literal output path given on line 2 of the prompt. Those paths are literal strings, not shell variables — never $-expand them. Print only the literal word done and exit.'
    ;;

  warmup-argv) # $1=model -> NUL-delimited argv for the auth warmup call; the word ping arrives on stdin
    [ "$#" -ge 1 ] && [ -n "$1" ] || exit 2
    # omp-autodream's warmup: the worker's flags minus --tools, and a system prompt that asks for
    # one word. It carries the same overlay, so the call that refreshes the token is the call a
    # worker would have made.
    printf '%s\0' "$(omp_bin)" \
      --allow-home \
      -p \
      --approval-mode yolo \
      --no-session \
      --config "${NO_ADVISOR_CFG:-$ADIR/l1-no-advisor.yml}" \
      --model "$1" \
      --append-system-prompt 'Reply with the single word ok and exit.'
    ;;

  l1-env) # -> KEY=VALUE lines the engine needs in its environment: none for omp
    :
    ;;

  l2-argv) # $1=model -> NUL-delimited argv for the L2 aggregator; the prompt arrives on stdin
    [ "$#" -ge 1 ] && [ -n "$1" ] || exit 2
    # The L1 overlay applies here too (advisor off, no local provider probes, no first-turn
    # recall). Glob and Read only: the report and the pins come back on stdout.
    # The system prompt is prompts/L2_SYSTEM.txt, read through the loader. No file means no argv.
    # shellcheck source=/dev/null
    sysprompt=$(. "$BIN/l2-prompt.sh" && l2_system_prompt) || exit 2
    printf '%s\0' "$(omp_bin)" \
      --allow-home \
      -p \
      --approval-mode yolo \
      --no-session \
      --config "${NO_ADVISOR_CFG:-$ADIR/l1-no-advisor.yml}" \
      --model "$1" \
      --tools=Glob,Read \
      --append-system-prompt "$sysprompt"
    ;;

  skills-inventory)
    # One active skill per line: name, and when known a TAB and its description. The
    # claude adapter prints the name alone; a consumer that wants only names takes
    # field 1. The script writes a file with four comment lines first, so it goes to a
    # temp and the comments are dropped here. A failure prints nothing and exits 1, so
    # the caller writes its "unavailable" sentinel instead of an empty inventory that
    # would claim no skills are installed.
    inv=$(mktemp "${TMPDIR:-/tmp}/omp-skills.XXXXXX") || exit 1
    if "$ADIR/skills-inventory.sh" "$inv"; then
      grep -v '^#' "$inv"
      rc=0
    else
      rc=1
    fi
    rm -f "$inv"
    exit "$rc"
    ;;

  *)
    printf 'omp adapter: unknown subcommand: %s\n' "$cmd" >&2
    exit 2
    ;;
esac
