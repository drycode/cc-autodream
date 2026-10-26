#!/bin/bash
# A synthetic harness whose only purpose is to prove the adapter contract is a
# contract rather than a description of what the claude adapter happens to do.
#
# Its session format is one JSON object per file with `cwd` and `turns`. That
# resembles neither real harness deliberately: a fixture shaped like a Claude
# transcript would pass by accident, and would keep passing if the contract
# quietly grew a Claude-specific assumption.
#
# Excluded from the default adapter set by its leading underscore, so a nightly
# run never sees it.
set -u

cmd="${1:-}"
[ "$#" -gt 0 ] && shift

case "$cmd" in

  enumerate) # $1=root ($2/$3 date bounds unused: fixtures are not time-filtered)
    find "$1" -type f -name '*.fixture' -print0 2>/dev/null
    ;;

  normalize) # $1=in $2=out
    [ -r "$1" ] || exit 1
    jq -e . "$1" >/dev/null 2>&1 || exit 1        # fail closed on malformed input
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

  project) # $1=session -> resolved cwd
    [ -r "$1" ] || exit 1
    cwd=$(jq -re '.cwd // empty' "$1" 2>/dev/null) || exit 1
    [ -n "$cwd" ] || exit 1
    realpath "$cwd" 2>/dev/null || exit 1
    ;;

  stats) # $1=in $2=out
    [ -r "$1" ] || exit 1
    bytes=$(wc -c < "$1" | tr -d ' ')
    turns=$(jq -re '.turns // 0' "$1" 2>/dev/null) || turns=0
    [ ! -d "$2" ] || exit 1   # see the note on the first use above
    t=$(mktemp "$2.tmp.XXXXXX" 2>/dev/null) || exit 1
    printf '{"transcript_bytes":%s,"user_message_count":%s,"tool_call_count":0}\n' \
      "${bytes:-0}" "${turns:-0}" > "$t" 2>/dev/null || { rm -f "$t"; exit 1; }
    mv -f "$t" "$2" 2>/dev/null || { rm -f "$t"; exit 1; }
    [ -f "$2" ] || { rm -f "$2/$(basename "$t")" 2>/dev/null; exit 1; }   # see the note above
    ;;

  slim) # $1=in $2=out — a fixture is already small; the contract is what matters
    [ -r "$1" ] || exit 1
    [ ! -d "$2" ] || exit 1   # see the note on the first use above
    t=$(mktemp "$2.tmp.XXXXXX" 2>/dev/null) || exit 1
    cp "$1" "$t" 2>/dev/null || { rm -f "$t"; exit 1; }
    mv -f "$t" "$2" 2>/dev/null || { rm -f "$t"; exit 1; }
    [ -f "$2" ] || { rm -f "$2/$(basename "$t")" 2>/dev/null; exit 1; }   # see the note above
    ;;

  # The fixture harness never runs autodream, so the answer is always "not ours"
  # — but only for a session that can be READ. Answering 1 for a file that is not
  # there makes a vanished transcript indistinguishable from a real user session,
  # and this adapter exists to make a contract gap fail here rather than in
  # production. 3, not 2: 2 means unknown subcommand.
  is-self)
    [ -r "$1" ] || exit 3
    exit 1
    ;;
  engine-bin) printf '%s\n' true ;;

  l2-argv) # [$1=model]
    printf '%s\0' true ${1:+"$1"}
    ;;
  l1-argv) # $1=model
    [ "$#" -ge 1 ] && [ -n "$1" ] || exit 2
    printf '%s\0' true "$1"
    ;;

  warmup-argv) # $1=model
    [ "$#" -ge 1 ] && [ -n "$1" ] || exit 2
    printf '%s\0' true "$1"
    ;;

  l1-env) : ;;

  skills-inventory) printf 'fixture-skill\n' ;;

  *)
    printf '_fixture adapter: unknown subcommand: %s\n' "$cmd" >&2
    exit 2
    ;;
esac
