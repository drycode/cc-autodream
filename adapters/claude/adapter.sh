#!/bin/bash
# Claude Code harness adapter.
#
# Every subcommand delegates to the script that already implements this
# behavior. Nothing is invented here. The point of this file is that run.sh
# stops knowing which harness it is talking to — not that anything about
# Claude ingest changes.
set -u

# cd -P, not plain cd. Logical resolution would succeed against a
# coincidental $TARGET/bin in the installed layout and silently land in the
# wrong directory; -P follows the adapters symlink physically first, so this
# resolves to the real bin/ regardless of what else exists alongside.
BIN=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../bin" && pwd)

# Effort for an L1 worker: AUTODREAM_L1_EFFORT_CLAUDE, then AUTODREAM_L1_EFFORT, then high.
# Haiku 5.5 trades cost for quality on this dial and triage yield was the weak point of the
# old Haiku, so the default leans to quality; the pricing makes that cheap. "off" omits the
# flag (the model's own default). An unknown level is an error, never a silent fallback.
l1_effort() {
  local e="${AUTODREAM_L1_EFFORT_CLAUDE:-${AUTODREAM_L1_EFFORT:-high}}"
  case "$e" in
    off) return 0 ;;
    low|medium|high|xhigh|max) printf '%s\n' "$e" ;;
    *) echo "adapter claude: bad AUTODREAM_L1_EFFORT '$e' (low|medium|high|xhigh|max|off)" >&2; return 1 ;;
  esac
}

cmd="${1:-}"
[ "$#" -gt 0 ] && shift

case "$cmd" in

  enumerate) # $1=root $2=target-date $3=next-date -> NUL-delimited session paths
    # $2 and $3 are an mtime window and nothing more. The runner passes a $3 far in the
    # future when it places a session in a day by the timestamps inside the transcript
    # (bin/session-window.sh), which turns this into a lower bound only and keeps the
    # adapter contract free of any knowledge of that window.
    # stderr is NOT discarded. find exits 1 for any unreadable directory in the
    # walk, and the runner has to decide between a partial corpus and a failed
    # root on that status alone. Swallowing the reason left it reporting bare
    # `(exit 1)` with nothing to act on. Only stdout is the contract.
    find "$1" -type f -name '*.jsonl' \
         -newermt "$2 00:00:00" \
         ! -newermt "$3 00:00:00" \
         -print0
    ;;

  normalize) # $1=in $2=out
    [ "$#" -ge 2 ] || exit 2   # see the note on stats|slim below
    # A Claude transcript is a flat list of turns, so normalisation is a copy.
    # It still writes through a .tmp and renames: the contract says a failed
    # subcommand leaves NO output, and a half-written file that a later step
    # reads as a whole session is worse than no session at all.
    [ -r "$1" ] || exit 1
    # A unique temp in the DESTINATION directory. A fixed "$2.tmp" is a shared
    # name: two invocations writing the same output would clobber or remove each
    # other's temp file and leave the result from the wrong one, or none.
    # A directory at the destination is refused. `mv -f "$t" "$2"` would move
    # the temp INSIDE it and return success, so the adapter would report a write
    # it never performed and leave a randomly-named file in the caller's
    # directory. The delegates used to reject this themselves, because a `>`
    # redirection to a directory fails; wrapping them removed that.
    [ ! -d "$2" ] || exit 1
    t=$(mktemp "$2.tmp.XXXXXX" 2>/dev/null) || exit 1
    cp "$1" "$t" 2>/dev/null || { rm -f "$t"; exit 1; }
    mv -f "$t" "$2" 2>/dev/null || { rm -f "$t"; exit 1; }
    # Post-condition, because the guard above is a check-then-act. Something can
    # create a directory at $2 between the two, and `mv` then moves the temp
    # INSIDE it and returns 0 — success reported with no output written, which
    # is the exact failure the guard exists to stop. macOS has no `mv -T`, so
    # the destination is verified to be a regular file afterwards and the stray
    # removed. Verified by deleting the guard above: this alone still satisfies
    # the directory-destination contract test, so it is a real backstop and not
    # decoration. The guard stays anyway — it fails before any work, and it is
    # what stops a file appearing inside the caller's directory even briefly.
    #
    # This NARROWS the race rather than closing it. A sequence that creates a
    # directory at $2 after the guard, lets mv move the temp inside it, then
    # replaces $2 with a regular file before this check, still reports success
    # with the output somewhere else. Closing that needs an atomic
    # rename-if-not-a-directory, which is renameat2 on Linux and does not exist
    # on macOS, where this runs. Winning any of these needs write access to the
    # findings dir, at which point the dir is already the attacker's; these
    # checks exist because silent wrong success is the failure this repo keeps
    # getting caught by, not because there is a threat model. Named here rather
    # than papered over with a fourth layer that would not close it either.
    [ -f "$2" ] || { rm -f "$2/$(basename "$t")" 2>/dev/null; exit 1; }
    ;;

  project) # $1=session -> the session's real working directory
    [ -r "$1" ] || exit 1
    # jq, not grep: a cwd containing a quote or a backslash is JSON-escaped, and
    # a regex over the raw line either truncates at the escaped quote or hands
    # realpath a doubled backslash.
    cwd=$(jq -re 'select(.cwd != null) | .cwd' "$1" 2>/dev/null | head -1)
    [ -n "$cwd" ] || exit 1
    realpath "$cwd" 2>/dev/null || exit 1
    ;;

  # stats and slim delegate like everything else, but they cannot `exec`. Both
  # delegated scripts write the destination directly — slim-transcript.sh in two
  # steps, a `>` for the body and a `>>` for the footer — so an interruption
  # leaves a non-empty file with no footer, and the caller's `-s` check accepts
  # it and sends a truncated session to L1 as if it were whole.
  #
  # The atomicity belongs here rather than in those scripts: the contract is the
  # adapter's (docs/design/unify-harness-adapters-2026-08-23.md:131 requires it
  # of every subcommand that writes a file), and both scripts have callers
  # outside this seam. Same shape as normalize above — a unique temp in the
  # DESTINATION directory, renamed on success, removed on failure.
  #
  # DELIBERATELY NO SIGNAL TRAP, and this was measured rather than assumed. A
  # killed run leaves the temp behind, which is real but cosmetic: nothing reads
  # `*.tmp.*` — the findings glob is `*.json` and slim output is read by exact
  # path. Adding `trap 'rm -f "$t"' ... TERM` costs far more than it saves,
  # because bash defers a TRAPPED signal until the foreground child returns. The
  # delegate is that child, so the trap converts a prompt death into an adapter
  # that ignores SIGTERM for as long as the delegate runs — verified here: the
  # test below hung for 120s and left orphaned slim-transcript.sh processes
  # holding their input open. Being killed mid-flight is this pipeline's normal
  # failure, so trading a stale temp for a hung process is the wrong direction.
  # Backgrounding the delegate and killing it from the trap would work and is
  # five lines of signal plumbing in a file whose whole claim is that nothing is
  # invented here. The runner sweeps `*.tmp.??????` and `*.pre.jsonl` out of the findings
  # dir at the start of each run (sweep_killed_leftovers in bin/run.sh, #57).
  stats|slim)
    # Arity BEFORE dereferencing $2. Under `set -u` a one-arg call died with
    # "$2: unbound variable" and status 1 — indistinguishable from a legitimate
    # skip-this-session failure, when the caller actually made a usage error.
    [ "$#" -ge 2 ] || exit 2
    case "$cmd" in
      stats) delegate="$BIN/session-stats.sh" ;;
      slim)  delegate="$BIN/slim-transcript.sh" ;;
    esac
    [ ! -d "$2" ] || exit 1   # see the note on the first use above
    t=$(mktemp "$2.tmp.XXXXXX" 2>/dev/null) || exit 1
    "$delegate" "$1" "$t" || { rm -f "$t"; exit 1; }
    mv -f "$t" "$2" 2>/dev/null || { rm -f "$t"; exit 1; }
    [ -f "$2" ] || { rm -f "$2/$(basename "$t")" 2>/dev/null; exit 1; }   # see the note above
    ;;

  is-self) # $1=session -> exit 0 if this is one of autodream's own transcripts
    # The readability guard every sibling subcommand has. Without it a vanished
    # or unreadable transcript answers "not one of ours" — prune-self-sessions.sh
    # greps with 2>/dev/null and returns 1 either way — which is indistinguishable
    # from a real user session, and the contract has no channel to say "I could
    # not read it". Exit 2 is the unknown-subcommand code and would be wrong here;
    # this is a readable-input failure, so the caller sees a nonzero that is not 1.
    [ -r "$1" ] || exit 3
    # Delegated, never reimplemented: prune-self-sessions.sh is the single
    # source of truth for this predicate, and a marker added there must not
    # have to be remembered here too.
    exec "$BIN/prune-self-sessions.sh" --is-self "$1"
    ;;

  engine-bin) # -> the absolute path of the engine this adapter runs
    # CLAUDE_BIN, the same variable run.sh has always honored, defaulting to where the
    # installer puts it. Printed even when absent: the runner decides what absence means.
    printf '%s\n' "${CLAUDE_BIN:-$HOME/.local/bin/claude}"
    ;;

  l1-argv) # $1=model -> NUL-delimited argv for one L1 worker; the prompt arrives on stdin
    [ "$#" -ge 1 ] && [ -n "$1" ] || exit 2
    # --system-prompt REPLACES Claude Code's default prompt (about 1.9k tokens a call, measured
    # 2026-10-07: 6.9k -> 5.0k input on a one-word call, and 26% cheaper on a real triage run with
    # the same findings count). The worker prompt is self-contained, so nothing is lost. Tools are
    # already Read and Write only; hooks, skills, MCP and CLAUDE.md are off.
    # The invocation run.sh hard-coded before the engine moved behind the
    # adapter: tests/adapter-claude.sh pins it against that literal text, so a change here
    # that alters what the nightly runs has to say so. NO shell expansion of the paths in
    # the system prompt, hence the escaped dollar sign in the text.
    # --output-format json makes stdout one small result object that names the models that
    # answered (read back by `served`). Not stream-json: --verbose would echo every Read result,
    # the whole transcript, onto stdout, and a failed worker copies its stdout into the .err.
    effort=$(l1_effort) || exit 2
    set -- "$1" ${effort:+--effort "$effort"}
    model=$1; shift
    printf '%s\0' "${CLAUDE_BIN:-$HOME/.local/bin/claude}" \
      --print \
      --output-format json \
      --permission-mode bypassPermissions \
      --model "$model" \
      "$@" \
      --no-session-persistence \
      --tools Read Write \
      --disable-slash-commands \
      --strict-mcp-config \
      --settings '{"disableAllHooks":true}' \
      --system-prompt 'Headless triage worker. Read the session transcript and write exactly one findings JSON object, via the Write tool, to the literal output path given on line 2 of the prompt. Those paths are literal strings, not shell variables — never $-expand them. Print only the literal word done and exit.'
    ;;

  warmup-argv) # $1=model -> NUL-delimited argv for the auth warmup call; the word ping arrives on stdin
    [ "$#" -ge 1 ] && [ -n "$1" ] || exit 2
    # The same flags as an L1 worker, so the warmup exercises the same auth and settings path,
    # with a system prompt that asks for one word instead of a findings file. A warmup that took
    # a different path would refresh a token the workers never use.
    effort=$(l1_effort) || exit 2
    set -- "$1" ${effort:+--effort "$effort"}
    model=$1; shift
    printf '%s\0' "${CLAUDE_BIN:-$HOME/.local/bin/claude}" \
      --print \
      --permission-mode bypassPermissions \
      --model "$model" \
      "$@" \
      --no-session-persistence \
      --tools Read \
      --disable-slash-commands \
      --strict-mcp-config \
      --settings '{"disableAllHooks":true}' \
      --system-prompt 'Reply with the single word ok and exit.'
    ;;

  served) # $1=stdout of one L1 call -> "<model>[,<model>...]<TAB><estimated cost USD>", exit 1 without a result
    # The models come from the result object's modelUsage, which lists every model that answered
    # any part of the call. The cost is the CLI's estimate at API prices, not what a subscription
    # bills; it is kept because it compares models on real numbers.
    [ "$#" -ge 1 ] && [ -r "$1" ] || exit 1
    line=$(jq -r 'select(type == "object" and .type == "result")
      | [((.modelUsage // {}) | keys | sort | join(",")), ((.total_cost_usd // "") | tostring)] | @tsv' "$1" 2>/dev/null | head -1)
    case "$line" in ""|$'\t'*) exit 1 ;; esac
    printf '%s\n' "$line"
    ;;

  whoami) # -> one JSON object {provider, auth, plan, account}, each "unknown" when not reported
    # Who this engine's calls run as, read from the login they will use, with no model call:
    # `claude auth status --json` reports the API provider (firstParty is Anthropic's own API),
    # the sign-in method, the subscription plan and the account email.
    out=$("${CLAUDE_BIN:-$HOME/.local/bin/claude}" auth status --json </dev/null 2>/dev/null) || out=""
    [ -n "$out" ] || out="{}"
    printf '%s' "$out" | jq -c '{provider: (.apiProvider // "unknown"), auth: (.authMethod // "unknown"),
      plan: (.subscriptionType // "unknown"), account: (.email // "unknown")} | map_values(tostring)' 2>/dev/null \
      || printf '{"provider":"unknown","auth":"unknown","plan":"unknown","account":"unknown"}\n'
    ;;

  l1-env) # -> KEY=VALUE lines the engine needs in its environment
    # Lean-query env: keep subscription auth, strip per-call bloat (no CLAUDE.md auto-load,
    # no telemetry or error reporting). See CLAUDE.md, "How claude is invoked".
    printf '%s\n' CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1
    ;;

  l2-argv) # [$1=model] -> NUL-delimited argv for the L2 aggregator; the prompt arrives on stdin
    # Glob and Read only: the report and the pins come back on stdout and the runner is the only
    # writer. The model is optional, and absent means the CLI's own default, so an upgrade of the
    # account upgrades the nightly report with nothing edited here.
    set -- ${1:+--model "$1"}
    # The system prompt is prompts/L2_SYSTEM.txt, read through the loader. No file means no argv:
    # an engine started without it would run L2 with no word on where the report goes.
    # shellcheck source=/dev/null
    sysprompt=$(. "$BIN/l2-prompt.sh" && l2_system_prompt) || exit 2
    printf '%s\0' "${CLAUDE_BIN:-$HOME/.local/bin/claude}" \
      --print \
      --permission-mode bypassPermissions \
      "$@" \
      --no-session-persistence \
      --tools Glob Read \
      --disable-slash-commands \
      --strict-mcp-config \
      --settings '{"disableAllHooks":true}' \
      --append-system-prompt "$sysprompt"
    ;;

  skills-inventory)
    for d in "$HOME"/.claude/skills/*/ "$HOME"/.claude/plugins/*/skills/*/; do
      [ -f "$d/SKILL.md" ] || continue
      printf '%s\n' "$(basename "$d")"
    done
    ;;

  *)
    printf 'claude adapter: unknown subcommand: %s\n' "$cmd" >&2
    exit 2
    ;;
esac
