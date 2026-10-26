#!/bin/bash
# Shared-dependency preflight. Runs before anything is enumerated, and a
# failure here is a hard stop rather than a degraded run.
#
# None of these are new assumptions — run.sh already depends on all four:
#
#   jq        every findings record, sidecar and manifest is parsed with it
#   shasum    the hash assignments in l1_missing_count() and dispatch_l1() key each artifact by sha1
#   python3   the project-field normalisation step normalises project identity
#   realpath  NEW: adapter containment and cwd canonicalisation
#
# The `shasum` case is the one worth stating out loud, because it is the only
# dependency whose absence produces no error at all. `h=$(printf '%s' "$s" |
# shasum -a 1 | cut -c1-12)` assigns the empty string when shasum is missing,
# so every session in the night writes to the SAME findings filename and the
# run ends with one record where it should have had a hundred. Nothing in the
# existing code notices.
#
# `realpath` is security-critical rather than convenient: it does adapter
# directory containment and cwd canonicalisation. A host that reached adapter
# loading without it would fall back to weaker containment, which is exactly
# the failure the check exists to prevent — so it is never a degraded path.
set -u

L2_BIN=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --l2-bin)
      # `shift 2` with only one argument left FAILS and shifts nothing, so $#
      # never decreases and this loop spins forever. Preflight runs before the
      # idempotency guard, so a wedged one would also block every launchd
      # catch-up trigger behind the "label already running" rule.
      [ "$#" -ge 2 ] || { printf 'preflight: --l2-bin requires a value\n' >&2; exit 2; }
      L2_BIN="$2"; shift 2
      ;;
    *) shift ;;
  esac
done

MISSING_KEYS=""
missing=0

# Test-only injection. Emptying PATH to hide one dependency also hides bash's
# own helpers, so the suite could not otherwise exercise a single missing tool
# without breaking everything around it. Comma-separated list of names to treat
# as absent; unset in every real run.
_forced_missing() { # $1=command
  case ",${AUTODREAM_PREFLIGHT_FORCE_MISSING:-}," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

need() { # $1=command $2=what its absence costs
  if _forced_missing "$1" || ! command -v "$1" >/dev/null 2>&1; then
    printf 'MISSING: %s — %s\n' "$1" "$2" >&2
    MISSING_KEYS="${MISSING_KEYS:+$MISSING_KEYS,}$1"
    missing=$((missing + 1))
  fi
}

need jq       "every findings record, sidecar and adapter manifest is parsed with it"
need shasum   "the artifact key is sha1 of the session path; without it the hash is empty and every session collides on one filename, silently"
# python3 is a WARNING, not a hard stop. the project-field normalisation step already degrades
# gracefully without it ("skipping project-field normalization (L2 grouping may
# show dupes)"), and making preflight fatal here contradicted that: on a host
# where python3 is only a pyenv shim absent from the launchd PATH, the nightly
# would go from a slightly-worse report to no report at all, every night.
if _forced_missing python3 || ! command -v python3 >/dev/null 2>&1; then
  printf 'DEGRADED: python3 — project-field normalisation will be skipped; L2 grouping may show duplicate projects\n' >&2
fi
need realpath "adapter directory containment and cwd canonicalisation; without it containment is weaker, which is the failure this check exists to prevent"

if [ -n "$L2_BIN" ] && ! command -v "$L2_BIN" >/dev/null 2>&1; then
  printf 'MISSING: %s — the configured L2 engine; no report is possible without it\n' "$L2_BIN" >&2
  MISSING_KEYS="${MISSING_KEYS:+$MISSING_KEYS,}l2_engine"
  missing=$((missing + 1))
fi

if [ "$missing" -ne 0 ]; then
  printf 'preflight_missing: %s\n' "$MISSING_KEYS"
  exit 1
fi
exit 0
