#!/bin/bash
# Unit tests for bin/preflight.sh.
#
# These dependencies are not new — run.sh already relies on all of them. They
# were simply never checked, and one fails in a way that destroys a night's
# corpus without erroring: with `shasum` absent the artifact hash assignment
# yields an empty string, so every session targets the same findings filename.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$HERE/lib-tmp.sh"; suite_tmp pf
PF="$REPO/bin/preflight.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }
has(){ case "$2" in *"$1"*) ok "$3" ;; *) no "$3 (got: $2)" ;; esac; }

[ -x "$PF" ] || { printf '  FAIL - bin/preflight.sh missing or not executable\n\npassed: 0   failed: 1\n'; exit 1; }

echo "# preflight: a host with every dependency present exits 0"
if "$PF" --l2-bin bash >/dev/null 2>&1; then ok "exits 0 when all present"; else no "exits 0 when all present"; fi

echo "# preflight: a missing L2 engine is a hard failure, named"
out=$("$PF" --l2-bin definitely-not-a-real-binary-xyz 2>&1); rc=$?
assert_eq "$rc" "1" "exits 1 on a missing L2 engine"
has "definitely-not-a-real-binary-xyz" "$out" "names the missing engine"

echo "# preflight: missing shared dependencies are named, not silently skipped"
# An empty PATH dir hides every external command from `command -v`.
empty=$(mktemp -d "${TMPDIR:-/tmp}/pf.XXXXXX")
out=$(PATH="$empty" "$PF" --l2-bin bash 2>&1); rc=$?
assert_eq "$rc" "1" "exits 1 when dependencies are missing"
has "jq"       "$out" "names jq"
has "shasum"   "$out" "names shasum"
has "python3"  "$out" "mentions python3"

echo "# preflight: python3 alone is a DEGRADED warning, never a hard stop"
# run.sh:1248 already skips project-field normalisation gracefully without it.
# Making this fatal would take a host whose python3 is only a pyenv shim from a
# slightly-worse report to no report at all, every night.
if AUTODREAM_PREFLIGHT_FORCE_MISSING=python3 "$PF" --l2-bin bash >/dev/null 2>&1; then
  ok "a missing python3 alone still exits 0"
else
  no "a missing python3 alone still exits 0"
fi
out3=$(AUTODREAM_PREFLIGHT_FORCE_MISSING=python3 "$PF" --l2-bin bash 2>&1)
case "$out3" in *MISSING*python3*) no "python3 is not reported as MISSING" ;; *) ok "python3 is not reported as MISSING" ;; esac
# Assert the DEGRADED line is actually emitted. Without this the test passed on
# any host that HAS python3 — it simulated nothing and proved nothing.
case "$out3" in *DEGRADED*python3*) ok "python3 absence emits a DEGRADED warning" ;;
                *) no "python3 absence emits a DEGRADED warning (got: $out3)" ;; esac
has "realpath" "$out" "names realpath"

echo "# preflight: the reason is carried, not just the name"
has "one filename" "$out" "says what a missing shasum actually costs"
has "containment"  "$out" "says why realpath is security-critical"

echo "# preflight: a flag with no value is a usage error, never a hang"
# `shift 2` with one argument left fails and shifts nothing, so the arg loop
# spun forever. Preflight runs before the idempotency guard, so a wedged one
# would also block every launchd catch-up trigger behind "label already running".
# macOS has no stock `timeout`, and the workflow installs coreutils for
# `gtimeout` only — it deliberately keeps gnubin off PATH because the suite
# depends on BSD date and touch. Same selection run-all.sh already uses.
TO=""
command -v timeout  >/dev/null 2>&1 && TO=timeout
[ -n "$TO" ] || { command -v gtimeout >/dev/null 2>&1 && TO=gtimeout; }
if [ -n "$TO" ]; then
  "$TO" 5 "$PF" --l2-bin >/dev/null 2>&1; rc4=$?
  assert_eq "$rc4" "2" "--l2-bin with no value exits 2 rather than hanging"
else
  ok "no timeout binary available; skipped the hang assertion"
fi

echo "# preflight: the failure is machine-readable for run-stats"
has "preflight_missing:" "$out" "emits a preflight_missing key"

rm -rf "$empty"
printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
