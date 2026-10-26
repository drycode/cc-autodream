#!/bin/bash
# Unit tests for bin/adapters.sh — loading, identity safety, containment.
#
# The security-relevant assertions here are the last three groups. Dispatch
# builds a command path from the adapter's directory name, so anything that can
# influence that name can influence what gets executed. The manifest is data,
# read with jq and never sourced; the basename is validated; and the directory
# is realpath-contained, because a basename check alone does not stop
# adapters/evil being a symlink to somewhere else entirely.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$HERE/lib-tmp.sh"; suite_tmp adapters

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }
has(){ case "$2" in *"$1"*) ok "$3" ;; *) no "$3 (got: [$2])" ;; esac; }

[ -f "$REPO/bin/adapters.sh" ] || {
  printf '  FAIL - bin/adapters.sh missing; the rest of this suite would be vacuous\n'
  printf '\npassed: 0   failed: 1\n'; exit 1; }

# shellcheck source=/dev/null
. "$REPO/bin/adapters.sh"

for fn in adapters_root adapters_list adapter_manifest_get adapter_run adapters_rejected; do
  declare -F "$fn" >/dev/null 2>&1 || {
    printf '  FAIL - %s is not defined; the rest of this suite would be vacuous\n' "$fn"
    printf '\npassed: 0   failed: 1\n'; exit 1; }
done

TMPROOTS=""
sandbox(){ local d; d=$(mktemp -d "${TMPDIR:-/tmp}/adapters.XXXXXX"); TMPROOTS="$TMPROOTS $d"; printf '%s' "$d"; }
mk_adapter(){ # $1=root $2=dirname $3=manifest name field
  mkdir -p "$1/$2"
  printf '{"name":"%s","engine_bin":"bash"}\n' "$3" > "$1/$2/manifest.json"
  printf '#!/bin/bash\nprintf "ran %%s" "$1"\n' > "$1/$2/adapter.sh"
  chmod +x "$1/$2/adapter.sh"
}
# Each case gets a fresh reject log, since adapters_list runs in a command
# substitution and could not report rejections through a shell variable.
use(){ ADAPTERS_ROOT="$1"; ADAPTERS_REJECT_LOG="$1/.rejected"; : > "$ADAPTERS_REJECT_LOG"; }

echo "# adapters: a well-formed adapter loads and dispatches"
root=$(sandbox); mk_adapter "$root" claude claude; use "$root"
assert_eq "$(adapters_list)" "claude" "the adapter is listed"
assert_eq "$(adapter_manifest_get claude .engine_bin)" "bash" "a manifest value reads back"
assert_eq "$(adapter_run claude hello)" "ran hello" "dispatch reaches adapter.sh"

echo "# adapters: rejections survive command substitution"
root=$(sandbox); mk_adapter "$root" claude wrongname; use "$root"
assert_eq "$(adapters_list)" "" "a name/basename mismatch is refused"
has "claude" "$(adapters_rejected)" "the refusal is visible AFTER a \$(adapters_list) call"

echo "# adapters: an unsafe basename is refused"
root=$(sandbox); mk_adapter "$root" ".evil" ".evil"; use "$root"
assert_eq "$(adapters_list)" "" "a dot-prefixed basename is refused"
# Absent from the list is not the same as REFUSED. "$root"/*/ never matched a
# dot-prefixed directory, so .evil was invisible rather than rejected and
# adapters_rejected reported `none` — which reads as "nothing was refused".
has ".evil" "$(adapters_rejected)" "a dot-prefixed dir is RECORDED as refused, not merely skipped"
root=$(sandbox); mk_adapter "$root" "Bad" "Bad"; use "$root"
assert_eq "$(adapters_list)" "" "an uppercase basename is refused"
has "Bad" "$(adapters_rejected)" "an uppercase dir is RECORDED as refused, not merely skipped"

echo "# adapters: a symlink escaping the adapters root is refused"
root=$(sandbox); outside=$(sandbox); mk_adapter "$outside" evil evil
ln -s "$outside/evil" "$root/evil"; use "$root"
assert_eq "$(adapters_list)" "" "a symlinked adapter dir is refused"
has "evil" "$(adapters_rejected)" "the containment escape is recorded"

echo "# adapters: an adapter missing its manifest or adapter.sh is refused"
# Each of these pairs an empty list with the refusal record on purpose. An empty
# list alone cannot tell "the loader saw this and refused it" from "the glob
# never matched it" — which is exactly how a malformed `.evil` read as `none`
# refused for as long as it did. Every rejection case below reaches
# _adapter_reject in bin/adapters.sh, so every one of them can say so.
root=$(sandbox); mkdir -p "$root/bare"; use "$root"
assert_eq "$(adapters_list)" "" "a directory with neither file is refused"
has "bare" "$(adapters_rejected)" "a dir with neither file is RECORDED as refused"
root=$(sandbox); mk_adapter "$root" half half; rm "$root/half/adapter.sh"; use "$root"
assert_eq "$(adapters_list)" "" "a manifest with no adapter.sh is refused"
has "half" "$(adapters_rejected)" "a manifest with no adapter.sh is RECORDED as refused"

echo "# adapters: underscore-prefixed dirs are excluded from the default set"
root=$(sandbox); mk_adapter "$root" claude claude; mk_adapter "$root" _fixture _fixture; use "$root"
assert_eq "$(adapters_list)" "claude" "_fixture is not in the default set"
# `none`, not the empty string. run.sh writes this value straight into
# run-stats.txt, where a blank cannot be told apart from a key that was never
# measured — and a caller-side `|| printf none` cannot rescue it, because
# returning 0 with no output is success.
assert_eq "$(adapters_rejected)" "none" "excluding a test adapter is not a rejection"

echo "# adapters: the manifest is data — \$HOME substitutes, nothing evaluates"
root=$(sandbox); mkdir -p "$root/claude"
canary="$root/pwned"
printf '{"name":"claude","session_roots_default":["$HOME/x`touch %s`$(touch %s)"]}\n' "$canary" "$canary" \
  > "$root/claude/manifest.json"
printf '#!/bin/bash\ntrue\n' > "$root/claude/adapter.sh"; chmod +x "$root/claude/adapter.sh"
use "$root"
got=$(adapter_manifest_get claude '.session_roots_default[0]')
has "$HOME/x" "$got" "\$HOME was substituted"
has 'touch'   "$got" "the shell metacharacters survive as literal text"
[ -e "$canary" ] && no "the manifest must not execute anything" || ok "the manifest executed nothing"

echo "# adapters: a malformed manifest is refused, not partially trusted"
root=$(sandbox); mkdir -p "$root/claude"
printf 'this is not json at all\n' > "$root/claude/manifest.json"
printf '#!/bin/bash\ntrue\n' > "$root/claude/adapter.sh"; chmod +x "$root/claude/adapter.sh"
use "$root"
assert_eq "$(adapters_list)" "" "unparseable JSON is refused"
has "claude" "$(adapters_rejected)" "unparseable JSON is RECORDED as refused"

echo "# adapters: dispatch validates the name it builds a path from"
# The header of bin/adapters.sh argues that identity is the directory basename
# precisely BECAUSE dispatch builds a command path out of it. That argument only
# holds if the dispatching functions check. Every caller today passes a name that
# came through adapters_list, so this is not reachable now — it is the guarantee
# the seam is supposed to make to the third-party adapter that arrives later,
# and a guarantee nothing enforces is a comment.
root=$(sandbox); mk_adapter "$root" claude claude; use "$root"
outside=$(sandbox); mkdir -p "$outside/evil"
printf '#!/bin/bash\nprintf pwned\n' > "$outside/evil/adapter.sh"; chmod +x "$outside/evil/adapter.sh"
printf '{"name":"evil","engine_bin":"bash"}\n' > "$outside/evil/manifest.json"
esc="../$(basename "$outside")/evil"
if adapter_run "$esc" x >/dev/null 2>&1; then
  no "adapter_run must refuse a traversing name"
else
  ok "adapter_run refuses a traversing name"
fi
assert_eq "$(adapter_run "$esc" x 2>/dev/null)" "" "and executes nothing"
if adapter_manifest_get "$esc" .name >/dev/null 2>&1; then
  no "adapter_manifest_get must refuse a traversing name"
else
  ok "adapter_manifest_get refuses a traversing name"
fi
# The valid name still works, so the guard is a check and not a blanket refusal.
assert_eq "$(adapter_run claude hello)" "ran hello" "a valid name still dispatches"

echo "# adapters: an unwritable reject log reports unknown, never a confident none"
# The refusal happened; adapters_rejected just cannot name it. Saying `none` there
# is worst on the total-outage path, where run.sh fatals with "accepted no
# adapters (rejected: none)" and the operator is told nothing was refused when
# everything was. The flag has to be a FILE: _adapter_reject runs inside
# $(adapters_list), so a shell variable set there never reaches this caller.
root=$(sandbox); mk_adapter "$root" "Bad" "Bad"
ADAPTERS_ROOT="$root"
# A directory where the log should be: every append fails, nothing can be named.
ADAPTERS_REJECT_LOG="$root/.rejected-dir"; mkdir -p "$ADAPTERS_REJECT_LOG"
rm -f "$(_adapter_reject_broken_marker)"
assert_eq "$(adapters_list)" "" "the malformed adapter is still refused"
has "unknown" "$(adapters_rejected)" "an unwritable log reports unknown, not none"
rm -f "$(_adapter_reject_broken_marker)"

# shellcheck disable=SC2086
rm -rf $TMPROOTS
echo "# adapter_l1_model: per-adapter override, then the generic one, then the manifest default"
l1counts=$(mktemp "${TMPDIR:-/tmp}/l1model.XXXXXX")
(
  export ADAPTERS_ROOT="$REPO/adapters"
  . "$REPO/bin/adapters.sh"
  unset AUTODREAM_L1_MODEL AUTODREAM_L1_MODEL_CLAUDE AUTODREAM_L1_MODEL_OMP
  assert_eq "$(adapter_l1_model claude)" "claude-haiku-5-5" "the manifest default"
  assert_eq "$(adapter_l1_model omp)" "deepseek/deepseek-flash" "each adapter has its own default"
  AUTODREAM_L1_MODEL=generic/model
  assert_eq "$(adapter_l1_model claude)" "generic/model" "the generic override applies to every adapter"
  AUTODREAM_L1_MODEL_OMP=neuralwatt/glm-5.3-flash
  assert_eq "$(adapter_l1_model omp)" "neuralwatt/glm-5.3-flash" "the per-adapter override beats the generic one"
  assert_eq "$(adapter_l1_model claude)" "generic/model" "and leaves the other adapter on the generic one"
  assert_eq "$(AUTODREAM_L1_MODEL= AUTODREAM_L1_MODEL_OMP= adapter_l1_model omp)" "deepseek/deepseek-flash" "an empty override is not an override"
  adapter_l1_model ../evil >/dev/null 2>&1; assert_eq "$?" "1" "an unsafe name resolves nothing"
  unset AUTODREAM_L1_MODEL AUTODREAM_L1_MODEL_OMP
  adapter_l1_model nonesuch >/dev/null 2>&1; assert_eq "$?" "1" "an adapter with no manifest and no override resolves nothing"
  printf '%s %s\n' "$pass" "$fail" > "$l1counts"
)
# A missing counts file means the subshell died before reporting, which is a failure, not a
# pass: the assertions inside it never reached the totals.
if read -r _p _f < "$l1counts" 2>/dev/null; then pass=$_p; fail=$_f
else no "adapter_l1_model assertions did not report their counts"; fi
rm -f "$l1counts" 2>/dev/null

echo "# provider_probe_url: net_up probes the provider a layer actually calls"
probecounts=$(mktemp)
(
  assert_eq "$(provider_probe_url omp deepseek/deepseek-flash)" "https://api.deepseek.com/" "an omp deepseek model probes deepseek"
  assert_eq "$(provider_probe_url omp anthropic/claude-opus-5)" "https://api.anthropic.com/" "an omp anthropic model probes anthropic"
  assert_eq "$(provider_probe_url omp neuralwatt/glm-5.3-flash)" "https://api.neuralwatt.com/" "an omp neuralwatt model probes neuralwatt"
  assert_eq "$(provider_probe_url claude claude-haiku-5-5)" "https://api.anthropic.com/" "claude has no provider prefix and probes anthropic"
  assert_eq "$(provider_probe_url claude '')" "https://api.anthropic.com/" "claude with no model (the CLI default) probes anthropic"
  provider_probe_url omp nosuchprovider/x >/dev/null 2>&1; assert_eq "$?" "1" "an unknown provider has no probe"
  provider_probe_url omp '' >/dev/null 2>&1; assert_eq "$?" "1" "an omp layer with no model resolved has no probe"
  provider_probe_url omp bare-model >/dev/null 2>&1; assert_eq "$?" "1" "an omp model with no provider prefix has no probe"
  assert_eq "$(AUTODREAM_NETUP_URL_NOSUCHPROVIDER=https://x.test/ provider_probe_url omp nosuchprovider/x)" "https://x.test/" "an env pin gives an unknown provider a probe"
  assert_eq "$(AUTODREAM_NETUP_URL_DEEPSEEK=https://y.test/ provider_probe_url omp deepseek/x)" "https://y.test/" "and overrides a known one"
  printf '%s %s\n' "$pass" "$fail" > "$probecounts"
)
if read -r _p _f < "$probecounts" 2>/dev/null; then pass=$_p; fail=$_f
else no "provider_probe_url assertions did not report their counts"; fi
rm -f "$probecounts" 2>/dev/null

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
