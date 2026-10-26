#!/bin/bash
# Unit tests for bin/lib-project.sh — the canonical project encoding.
#
# This encoding is load-bearing: it is what makes two harnesses' work on one
# real directory group as ONE project, with no reconciliation pass. Getting it
# wrong splits a project silently, because a wrongly-encoded record still looks
# perfectly well-formed.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$HERE/lib-tmp.sh"; suite_tmp libproj
# shellcheck source=/dev/null
. "$REPO/bin/lib-project.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

# Assert the functions exist before asserting on their output. Without this,
# every comparison of two absent-function outputs is empty-equals-empty and the
# suite passes green against no implementation at all.
for fn in encode_project canonical_project; do
  if ! declare -F "$fn" >/dev/null 2>&1; then
    printf '  FAIL - %s is not defined; the rest of this suite would be vacuous\n' "$fn"
    printf '\npassed: 0   failed: 1\n'
    exit 1
  fi
done

echo "# lib-project: encode_project maps everything outside [A-Za-z0-9-] to -"
assert_eq "$(encode_project /Users/x/sites)"   "-Users-x-sites"  "plain path"
assert_eq "$(encode_project /Users/x/.claude)" "-Users-x--claude" "dot becomes a dash"
assert_eq "$(encode_project /Users/x/a_b)"     "-Users-x-a-b"    "underscore becomes a dash"
assert_eq "$(encode_project /Users/x/.a_b.c)"  "-Users-x--a-b-c" "dots and underscores together"
# The three characters above are what the first version mapped, and they are the
# ones this repo's own paths happen to contain. The two below are what it missed,
# and both are live on this host: a stale `-…-Personal Items-…` bucket sits beside
# the real `-…-Personal-Items-…` one, holding an empty memory/ — a project already
# split in two by an encoder that preserved the space.
assert_eq "$(encode_project "/Users/x/Personal Items/RAW")" "-Users-x-Personal-Items-RAW" \
  "a SPACE becomes a dash"
assert_eq "$(encode_project "/Users/x/House (39 Loring)/Imp")" "-Users-x-House--39-Loring--Imp" \
  "parentheses become dashes, one each"
assert_eq "$(encode_project "/Users/x/a+b,c;d")" "-Users-x-a-b-c-d" \
  "every other punctuation character too"
assert_eq "$(encode_project "/Users/x/AbC-9")" "-Users-x-AbC-9" \
  "letters, digits and dashes survive — the map is not a blanket squash"

# Non-ASCII, measured not assumed (2026-10-04): `claude -p` run in a directory
# named `café-日本-😀` under a mktemp dir created the bucket
# `-private-var-folders-...-T-tmp-XXXXXX-caf-------`. After `caf` there are
# seven dashes: é, the literal dash, 日, 本, the literal dash, and TWO for the
# emoji. Claude maps per UTF-16 code unit (a JS regex over the string), so a BMP
# character is one dash however many UTF-8 bytes it takes, and an astral
# character (a surrogate pair) is two. A byte-wise `tr` gets 14 here, not 7.
assert_eq "$(encode_project "/Users/x/café")" "-Users-x-caf-" \
  "a 2-byte UTF-8 character (U+00E9) becomes one dash"
assert_eq "$(encode_project "/Users/x/日本")" "-Users-x---" \
  "3-byte UTF-8 characters (CJK) become one dash each"
assert_eq "$(encode_project "/Users/x/a😀b")" "-Users-x-a--b" \
  "a 4-byte UTF-8 character (astral) becomes two dashes, a UTF-16 surrogate pair"
assert_eq "$(encode_project "/tmp/café-日本-😀")" "-tmp-caf-------" \
  "the mixed path Claude was measured on encodes to the bucket it created"

echo "# lib-project: the encoding matches real Claude buckets on this host"
# The regression that motivated this file: seanperkins/autodream-merge maps only
# `/`, so it produces -Users-<u>-.claude for a directory Claude stores as
# -Users-<u>--claude. Assert against a bucket name only if it actually exists,
# so the test is meaningful here and inert on a machine without that history.
real_bucket="$HOME/.claude/projects/$(encode_project "$HOME/.claude")"
if [ -d "$real_bucket" ]; then
  ok "encode_project agrees with a real on-disk bucket for \$HOME/.claude"
else
  ok "no \$HOME/.claude bucket on this host; skipped the on-disk cross-check"
fi

# The stronger version of the check above: sweep EVERY path-derived bucket and
# require the encoder to reproduce its name from a cwd recorded inside it. This
# is what found the space bug — an eyeball survey of dash-shaped names cannot,
# because the broken form is also dash-shaped. Skipped where there is no corpus.
#
# Buckets not starting with `-` are CLAUDE_CODE_PROJECT_DIR_NAME slugs
# (owner-repo), which override cwd encoding entirely and would be counted as
# false misses. `./` prefixes every glob because a bucket name starting with `-`
# is an option to every tool that reads it.
sweep_root="$HOME/.claude/projects"
if [ -d "$sweep_root" ] && command -v jq >/dev/null 2>&1; then
  swept=0; missed=0; first_miss=""
  for d in "$sweep_root"/-*/; do
    [ -d "$d" ] || continue
    b=$(basename "$d")
    f=$(ls "$d"*.jsonl 2>/dev/null | head -1); [ -n "$f" ] || continue
    # ALL cwds, not the first. A transcript carries subagent records whose cwd is
    # a different directory, so `head -1` reports a false miss on a correct
    # encoder — it did exactly that once while this test was being written.
    hit=0; saw=0
    while IFS= read -r cwd; do
      [ -n "$cwd" ] || continue
      saw=1
      [ "$(encode_project "$cwd")" = "$b" ] && { hit=1; break; }
    done <<EOF
$(jq -re 'select(.cwd != null) | .cwd' "$f" 2>/dev/null | sort -u)
EOF
    # A bucket whose sampled transcript records NO cwd says nothing about the
    # encoder — ai-title stubs and queue-operation envelopes carry none — and
    # counting it as a miss made this sweep fail on 50 buckets it had no evidence
    # about. Only a bucket that offered at least one cwd is a test case.
    [ "$saw" = "1" ] || continue
    swept=$((swept + 1))
    if [ "$hit" != "1" ]; then
      missed=$((missed + 1))
      [ -n "$first_miss" ] || first_miss="$b"
    fi
  done
  if [ "$swept" -eq 0 ]; then
    ok "no path-derived buckets to sweep on this host"
  elif [ "$missed" -eq 0 ]; then
    ok "encode_project reproduces all $swept path-derived bucket names on this host"
  else
    no "encode_project missed $missed of $swept real buckets (first: $first_miss)"
  fi
fi

echo "# lib-project: canonical_project resolves symlinks before encoding"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/libproj.XXXXXX")
mkdir -p "$tmp/real.dir"
ln -s "$tmp/real.dir" "$tmp/link"
want=$(encode_project "$(cd "$tmp/real.dir" && pwd -P)")
assert_eq "$(canonical_project "$tmp/link")" "$want" "symlink resolves to its target"

echo "# lib-project: an unresolvable path fails loudly, never silently encodes"
if canonical_project "$tmp/does-not-exist" >/dev/null 2>&1; then
  no "missing path must exit nonzero"
else
  ok "missing path exits nonzero"
fi
assert_eq "$(canonical_project "$tmp/does-not-exist" 2>/dev/null)" "" "missing path prints nothing"

echo "# lib-project: session_hash returns 12 lowercase hex, or fails"
h=$(session_hash "/some/path.jsonl") && ok "session_hash succeeds on a normal path" || no "session_hash succeeds on a normal path"
assert_eq "${#h}" "12" "the key is exactly 12 characters"
case "$h" in *[!0123456789abcdef]*) no "the key is lowercase hex" ;; *) ok "the key is lowercase hex" ;; esac

echo "# lib-project: the hex class is enumerated, because ranges are collation-dependent"
# Verified on this host: under bash 3.2 with an en_US.UTF-8 collation, `A`
# MATCHES [0-9a-f]; under bash 5.3 it does not. The nightly runs #!/bin/bash,
# which is 3.2, so a range here would accept uppercase exactly where it matters.
# This is the same behaviour that made an uppercase adapter basename pass on CI
# and never locally. Run the check under the shell and locale that expose it.
if [ -x /bin/bash ]; then
  r=$(LC_ALL=en_US.UTF-8 /bin/bash -c 'case "A" in [0123456789abcdef]) echo MATCHED ;; *) echo rejected ;; esac')
  assert_eq "$r" "rejected" "the enumerated set rejects uppercase under bash 3.2 + UTF-8"
  # Informational, NOT an assertion. Pinning "the range form is broken" would
  # fail the day a shell fixes it, which is the wrong thing to guard. What must
  # hold is that OUR pattern rejects uppercase; whether the range still does not
  # is a fact about the platform, reported for the next reader.
  r=$(LC_ALL=en_US.UTF-8 /bin/bash -c 'case "A" in [0-9a-f]) echo MATCHED ;; *) echo rejected ;; esac')
  printf '  note - the range form [0-9a-f] vs "A" under bash 3.2 + UTF-8: %s\n' "$r"
else
  ok "no /bin/bash to test the collation behaviour against; skipped"
fi

echo "# lib-project: session_hash ITSELF rejects a non-lowercase-hex digest"
# The collation check above tests a hard-coded pattern, not the function. A
# regression putting [0-9a-f] back into session_hash would sail past it, so this
# drives the FUNCTION through a shasum whose digest contains uppercase.
#
# The digest starts ABCDE and deliberately not ABCDEF. Under the en_US.UTF-8
# collation the order runs ...eEfFgG..., so F sorts AFTER f and falls outside
# a-f while A through E fall inside. A digest beginning ABCDEF is therefore
# rejected by the range form too — for the wrong reason — and the test would pass
# against the very regression it exists to catch. Verified character by
# character on this host.
upstub=$(mktemp -d "${TMPDIR:-/tmp}/hexstub.XXXXXX")
printf '%s\n' '#!/bin/bash' 'cat >/dev/null 2>&1' 'echo "ABCDE0123456789abcdef0123456789abcdef012  -"' > "$upstub/shasum"
chmod +x "$upstub/shasum"
if PATH="$upstub:$PATH" session_hash "/x" >/dev/null 2>&1; then
  no "session_hash must reject an uppercase digest"
else
  ok "session_hash rejects an uppercase digest"
fi
assert_eq "$(PATH="$upstub:$PATH" session_hash "/x" 2>/dev/null)" "" "and prints nothing"
# A short digest must fail too: 12 characters is the contract, not a maximum.
printf '%s\n' '#!/bin/bash' 'cat >/dev/null 2>&1' 'echo "abc  -"' > "$upstub/shasum"
if PATH="$upstub:$PATH" session_hash "/x" >/dev/null 2>&1; then
  no "session_hash must reject a short digest"
else
  ok "session_hash rejects a short digest"
fi
rm -rf "$upstub"

echo "# lib-project: a shasum that fails at runtime yields no hash, not an empty one"
stub=$(mktemp -d "${TMPDIR:-/tmp}/hashstub.XXXXXX")
printf '#!/bin/bash\nexit 3\n' > "$stub/shasum"; chmod +x "$stub/shasum"
if PATH="$stub:$PATH" session_hash "/x" >/dev/null 2>&1; then
  no "a failing shasum must not produce a hash"
else
  ok "a failing shasum produces no hash"
fi
assert_eq "$(PATH="$stub:$PATH" session_hash "/x" 2>/dev/null)" "" "and prints nothing"
rm -rf "$stub"

rm -rf "$tmp"
printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
