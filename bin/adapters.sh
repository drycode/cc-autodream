#!/bin/bash
# Adapter loading and dispatch.
#
# THE MANIFEST IS DATA. It is JSON, read with jq, and never sourced. A sourced
# manifest executes arbitrary code as the user, and a plugin format whose parser
# is bash is an injection surface the moment a third-party adapter is a
# reasonable idea. $HOME is the only interpolation, done by substitution rather
# than evaluation, so a manifest holding backticks yields literal backticks.
#
# IDENTITY IS THE DIRECTORY BASENAME, never a manifest field, because dispatch
# builds a command path from it. A manifest that could name its own directory
# could reintroduce exactly the path construction that JSON parsing was adopted
# to remove. The manifest's `name` must AGREE with the basename — a mismatch is
# a load-time refusal rather than a silently preferred value, because two
# disagreeing identities is the state where a later reader picks the wrong one.
#
# A BASENAME CHECK IS NOT CONTAINMENT. `adapters/evil` may be a symlink pointing
# anywhere on the filesystem, so each directory is resolved with realpath and
# refused unless it is still under the adapters root.
#
# REJECTIONS GO TO A FILE, NOT A VARIABLE. `adapters_list` is almost always
# called as `$(adapters_list)`, and a variable assigned inside a command
# substitution never comes back to the caller — the same trap that cost this
# repo the cookie-expiry remediation text in vault-notes.sh, where FAIL_REASON
# was set inside nested $(...) and died with the subshell. A file crosses the
# boundary; a variable does not.
set -u

# Where refusals are recorded. Callers may point this at a findings dir so the
# count reaches run-stats.txt; it defaults beside the adapters root.
adapters_reject_log() {
  if [ -n "${ADAPTERS_REJECT_LOG:-}" ]; then printf '%s' "$ADAPTERS_REJECT_LOG"; return 0; fi
  # Default into TMPDIR, not the adapters root. _adapter_reject only ever appends
  # and only run.sh truncates, so a repo-tree default meant any other caller — an
  # interactive `. bin/adapters.sh; adapters_list`, or a future tool —
  # accumulated refusals across invocations and adapters_rejected then reported
  # stale names as this run's. It also left untracked cruft in a checkout that
  # .gitignore does not cover. Per-PID so two callers cannot cross-contaminate.
  printf '%s' "${TMPDIR:-/tmp}/autodream-adapters-rejected.$$"
}

# Two layouts have to work, and assuming only one is how the first version of
# this change shipped a silently broken install. In the REPO, bin/ and adapters/
# are siblings. Under the INSTALL, install.sh symlinks everything flat into
# ~/.claude/autodream, so adapters/ sits beside adapters.sh rather than one level
# up. Check the flat layout first: the nightly runs from the installed copy, so
# that is the expensive one to get wrong.
adapters_root() {
  if [ -n "${ADAPTERS_ROOT:-}" ]; then printf '%s' "$ADAPTERS_ROOT"; return 0; fi
  local here
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [ -d "$here/adapters" ]; then printf '%s' "$here/adapters"; return 0; fi
  printf '%s' "$(cd "$here/.." && pwd)/adapters"
}

# Comma-separated list of refused directory names, readable after a
# $(adapters_list) call because it is backed by a file.
adapters_rejected() {
  local log out; log=$(adapters_reject_log)
  # `none`, never an empty string. run.sh writes this straight into run-stats.txt,
  # and `adapters_rejected: ` with nothing after it cannot be told apart from a key
  # that was never measured — the exact ambiguity overlap_measured and
  # stats_sidecars_unparseable exist here to refuse. A caller-side
  # `|| printf none` cannot save it either, because returning 0 with no output is
  # success.
  if [ -f "$log" ]; then
    out=$(sort -u "$log" | tr '\n' ',' | sed 's/,$//')
  else
    out=""
  fi
  # `unknown` beats a confident `none` when the log could not be written. The
  # refusals happened; this just cannot name them.
  if [ -z "$out" ] && [ -f "$(_adapter_reject_broken_marker)" ]; then
    out="unknown (the reject log could not be written)"
  fi
  [ -n "$out" ] || out=none
  printf '%s' "$out"
}

# A FILE, not a variable — for exactly the reason the header gives. The first
# version of this used a shell flag, which _adapter_reject sets from inside
# _adapter_ok, from inside adapters_list, which every caller runs as
# $(adapters_list): the assignment died with the subshell and the flag was always
# 0 in the parent. Third time this trap has been laid in this repo, so it is
# spelled out here as well as at the top.
#
# It exists so adapters_rejected can say `unknown` rather than a confident
# `none`. A false `none` is worst on the total-outage path: the loader refuses
# every adapter, run.sh fatals with "accepted no adapters (rejected: none)", and
# the operator is told nothing was refused when everything was. The marker lives
# beside the log where possible and falls back to TMPDIR, because the case being
# reported is precisely the log's directory being unwritable.
_adapter_reject_broken_marker() {
  printf '%s' "${TMPDIR:-/tmp}/autodream-adapters-rejectlog-broken.$$"
}
_adapter_reject() { # $1=name
  local log; log=$(adapters_reject_log)
  # The BRACES matter. `printf ... >> "$log" 2>/dev/null` sets up the append
  # before the suppression, so bash reports a failure to OPEN $log on the
  # original stderr and the line reads as silenced while it is not — visible in
  # tests/adapters.sh as a raw `bin/adapters.sh: line NN: …: Is a directory`.
  # run.sh happens to capture this call under `adapters_list 2>/dev/null`, so the
  # nightly never saw it; any other caller does.
  { printf '%s\n' "$1" >> "$log"; } 2>/dev/null \
    || : > "$(_adapter_reject_broken_marker)" 2>/dev/null || true
}

# Safe identifier: lowercase start, then lowercase/digit/underscore/dash only.
# No separators, so the name cannot walk out of the adapters root on its own.
#
# The character sets are ENUMERATED, not ranges. `[a-z]` is collation-dependent:
# under a UTF-8 locale the order is aAbBcC..., so the range matches uppercase
# too. That made this check pass on macOS (C collation) and silently accept an
# uppercase basename on Linux — a containment check that was weaker on the
# platform CI actually runs. Enumeration has no such ambiguity.
#
# Separate from _adapter_ok because the DISPATCHERS need it too. The header
# above argues that identity is the directory basename because dispatch builds a
# command path from it; that argument is only true if the functions doing the
# building check. Every caller today hands them a name that came through
# adapters_list, so this is defence for the third-party adapter that arrives
# later rather than a live hole — but an unenforced guarantee is a comment.
_adapter_name_safe() { # $1=name
  case "$1" in
    [abcdefghijklmnopqrstuvwxyz]*) : ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!abcdefghijklmnopqrstuvwxyz0123456789_-]*) return 1 ;;
  esac
  return 0
}

# A directory is a usable adapter iff every one of these holds. Ordered cheapest
# first, but each is load-bearing rather than defensive: see the header.
_adapter_ok() { # $1=basename
  local root dir real realroot name
  root=$(adapters_root)
  dir="$root/$1"

  # A leading underscore marks a test-only adapter. Excluded silently, because
  # it is a deliberate exclusion rather than a refusal worth counting.
  case "$1" in _*) return 1 ;; esac

  _adapter_name_safe "$1" || { _adapter_reject "$1"; return 1; }

  # Containment. A symlinked adapter dir passes every check above and still
  # points anywhere, so resolve both sides and require the prefix.
  real=$(realpath "$dir" 2>/dev/null)     || { _adapter_reject "$1"; return 1; }
  realroot=$(realpath "$root" 2>/dev/null) || { _adapter_reject "$1"; return 1; }
  case "$real" in
    "$realroot"/*) : ;;
    *) _adapter_reject "$1"; return 1 ;;
  esac

  [ -f "$dir/manifest.json" ] && [ -x "$dir/adapter.sh" ] || { _adapter_reject "$1"; return 1; }

  # jq -e fails on unparseable JSON, so a malformed manifest is refused whole
  # rather than partially trusted.
  name=$(jq -re '.name // empty' "$dir/manifest.json" 2>/dev/null) || { _adapter_reject "$1"; return 1; }
  [ "$name" = "$1" ] || { _adapter_reject "$1"; return 1; }
  return 0
}

adapters_list() {
  local root d n
  root=$(adapters_root)
  [ -d "$root" ] || return 0
  # BOTH globs. "$root"/*/ never matches a dot-prefixed directory, so a hostile
  # or malformed `.evil` was silently invisible rather than recorded as a
  # refusal — and adapters_rejected then reported `none`, which reads as "nothing
  # was refused" when something was.
  for d in "$root"/*/ "$root"/.*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    case "$n" in .|..) continue ;; esac
    _adapter_ok "$n" && printf '%s\n' "$n"
  done
  return 0
}

adapter_manifest_get() { # $1=name $2=jq path -> value on stdout
  local root v
  _adapter_name_safe "$1" || return 1
  root=$(adapters_root)
  v=$(jq -re "${2} // empty" "$root/$1/manifest.json" 2>/dev/null) || return 1
  # $HOME by substitution, never evaluation.
  printf '%s' "${v//\$HOME/$HOME}"
}

adapter_run() { # $1=name $2=subcommand [args...]
  local root name
  name="$1"
  _adapter_name_safe "$name" || return 1
  root=$(adapters_root); shift
  "$root/$name/adapter.sh" "$@"
}

# The model one adapter's L1 workers run, resolved in a fixed order so a host can pin one
# harness without touching another:
#   AUTODREAM_L1_MODEL_<NAME>   that adapter only (the name upper-cased, dashes to underscores)
#   AUTODREAM_L1_MODEL          every adapter
#   the manifest's l1_model     the adapter's own default
# A model id belongs to one engine (neuralwatt/glm-5.3-flash means nothing to claude), which
# is why the per-adapter form exists: the generic one is an override for hosts with one engine.
adapter_l1_model() { # $1=name -> model on stdout, exit 1 when none resolves
  local name="$1" up var v
  _adapter_name_safe "$name" || return 1
  up=$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')
  var="AUTODREAM_L1_MODEL_$up"
  v="${!var:-}"
  [ -n "$v" ] || v="${AUTODREAM_L1_MODEL:-}"
  [ -n "$v" ] || v=$(adapter_manifest_get "$name" '.l1_model' 2>/dev/null) || v=""
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# The same, for the L2 aggregator. The manifest's l2_model may be absent, which for claude means
# "let the CLI pick", so this exits 1 with no output and the caller passes no model at all.
#   AUTODREAM_L2_MODEL_<NAME>  that adapter only
#   AUTODREAM_L2_MODEL         every adapter
#   the manifest's l2_model    the adapter's own default
adapter_l2_model() { # $1=name -> model on stdout, exit 1 when none resolves
  local name="$1" up var v
  _adapter_name_safe "$name" || return 1
  up=$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')
  var="AUTODREAM_L2_MODEL_$up"
  v="${!var:-}"
  [ -n "$v" ] || v="${AUTODREAM_L2_MODEL:-}"
  [ -n "$v" ] || v=$(adapter_manifest_get "$name" '.l2_model' 2>/dev/null) || v=""
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# The URL net_up probes for one engine layer, derived from the model that layer calls rather than
# from a constant. L1 on the omp adapter runs deepseek/... and L2 on omp runs anthropic/..., so a
# probe pinned to api.anthropic.com read a dead deepseek route as healthy and a dead anthropic one
# as a deepseek outage. The provider is the part of the model id before the slash. The claude
# adapter has no provider prefix: it always talks to Anthropic, even with no model named (the CLI's
# own default). Exits 1 with no output when the
# provider has no known host, which the caller reads as "cannot answer", not "down".
#   AUTODREAM_NETUP_URL_<PROVIDER>   pin one provider's probe URL (upper-cased, non-alnum to _)
provider_probe_url() { # $1=adapter name $2=model (may be empty) -> URL on stdout
  local name="${1:-}" model="${2:-}" provider up var v
  if [ "$name" = "claude" ]; then provider=anthropic
  else
    case "$model" in */*) provider="${model%%/*}" ;; *) return 1 ;; esac
  fi
  up=$(printf '%s' "$provider" | tr 'a-z' 'A-Z' | tr -c 'A-Z0-9' '_')
  var="AUTODREAM_NETUP_URL_$up"
  v="${!var:-}"
  if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  case "$provider" in
    anthropic)  printf '%s' "https://api.anthropic.com/" ;;
    deepseek)   printf '%s' "https://api.deepseek.com/" ;;
    neuralwatt) printf '%s' "https://api.neuralwatt.com/" ;;
    zai|z-ai)   printf '%s' "https://api.z.ai/" ;;
    runinfra)   printf '%s' "https://api.runinfra.ai/" ;;
    *) return 1 ;;
  esac
}
