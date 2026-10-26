#!/usr/bin/env bash
# What install.sh puts in the nightly plist's PATH, and which agents it provisions.
#
# HOME is a sandbox and launchctl is a shim that records its calls, so nothing here touches this
# machine's launchd. Every tool is a fake executable; the installer only needs to find them.
# The cases:
#   - a PATH entry under a temp directory (a cmux shim, a per-session dir) never reaches a plist,
#     and a CLAUDE_BIN taken from one is never pinned;
#   - --no-review, and AUTODREAM_REVIEW_AGENT=0 in the environment or the config, provision no
#     review agent and remove one that is there;
#   - the CLI of every enabled adapter is reachable from the plist PATH, not only claude's.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
no()   { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }
assert_eq()     { [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }
assert_grep()   { grep -qF -- "$2" "$1" 2>/dev/null && ok "$3" || no "$3 (no [$2] in $1)"; }
assert_nogrep() { grep -qF -- "$2" "$1" 2>/dev/null && no "$3 ([$2] unexpectedly in $1)" || ok "$3"; }

SANDBOX=""
cleanup() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

fake() { printf '#!/bin/bash\nexit 0\n' > "$1"; chmod +x "$1"; }

new_sandbox() { # sets SANDBOX FAKE_HOME LA CALLS; fake launchctl, cmux and claude
  [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
  SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/ccad-ip.XXXXXX")
  # macOS TMPDIR ends in a slash, so the path above holds a "//". The installer writes the
  # directories it finds through cd and pwd, which collapse it; compare against the same form.
  SANDBOX=$(cd "$SANDBOX" && pwd)
  FAKE_HOME="$SANDBOX/home"; LA="$FAKE_HOME/Library/LaunchAgents"
  mkdir -p "$LA" "$SANDBOX/shim" "$SANDBOX/bin"
  CALLS="$SANDBOX/launchctl-calls"; : > "$CALLS"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$CALLS" > "$SANDBOX/shim/launchctl"
  chmod +x "$SANDBOX/shim/launchctl"
  fake "$SANDBOX/bin/cmux"; fake "$SANDBOX/bin/claude"
}
# run_install <PATH> [env KEY=VALUE ...] -- <installer args>
run_install() {
  local p="$1"; shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  env HOME="$FAKE_HOME" PATH="$p" AUTODREAM_CMUX_DEFAULT="$SANDBOX/no-such-cmux" \
      ${envs[@]+"${envs[@]}"} bash "$REPO/install.sh" "$@" > "$SANDBOX/install.out" 2>&1
}
nightly_plist() { local f; for f in "$LA"/*.plist; do case "$f" in *-review.plist) ;; *) echo "$f"; return ;; esac; done; }
review_plist()  { ls "$LA"/*-review.plist 2>/dev/null | head -1; }
# The PATH string of a plist file, or of the first plist a dry run printed.
plist_path()    { sed -n 's|.*<key>PATH</key><string>\(.*\)</string>.*|\1|p' "$1" | head -1; }
has_dir()       { case ":$1:" in *":$2:"*) return 0 ;; *) return 1 ;; esac; }

basepath() { printf "%s" "$SANDBOX/shim:/usr/bin:/bin"; }

echo "# a PATH entry under a temp directory never reaches the plist or the pinned claude"
new_sandbox
mkdir -p "$SANDBOX/ephemeral/shims" "$SANDBOX/stable"
fake "$SANDBOX/ephemeral/shims/claude"; fake "$SANDBOX/stable/claude"
run_install "$SANDBOX/shim:$SANDBOX/ephemeral/shims:$SANDBOX/stable:$SANDBOX/bin:/usr/bin:/bin" \
  AUTODREAM_EPHEMERAL_DIRS="$SANDBOX/ephemeral" -- "$SANDBOX/target"; rc=$?
assert_eq "$rc" "0" "the install succeeds"
P=$(plist_path "$(nightly_plist)")
has_dir "$P" "$SANDBOX/stable" && ok "the stable claude dir is in the nightly PATH" || no "the stable claude dir is in the nightly PATH ($P)"
has_dir "$P" "$SANDBOX/ephemeral/shims" && no "the temp shim dir is not in the nightly PATH ($P)" || ok "the temp shim dir is not in the nightly PATH"
assert_grep "$(review_plist)" "<key>CLAUDE_BIN</key><string>$SANDBOX/stable/claude</string>" "the review agent pins the stable claude, not the shim"
assert_grep "$SANDBOX/install.out" "ignoring PATH entries under a temp directory" "the install says what it ignored"
assert_grep "$SANDBOX/install.out" "$SANDBOX/ephemeral/shims" "and which directory"

echo "# a claude reachable only through a temp directory is not pinned, and the install still succeeds"
new_sandbox
mkdir -p "$SANDBOX/ephemeral/shims"; fake "$SANDBOX/ephemeral/shims/claude"; rm -f "$SANDBOX/bin/claude"
run_install "$SANDBOX/shim:$SANDBOX/ephemeral/shims:$SANDBOX/bin:/usr/bin:/bin" \
  AUTODREAM_EPHEMERAL_DIRS="$SANDBOX/ephemeral" -- "$SANDBOX/target"; rc=$?
assert_eq "$rc" "0" "the install succeeds"
assert_eq "$(ls "$LA"/*.plist | wc -l | tr -d ' ')" "1" "only the nightly agent is provisioned"
assert_grep "$SANDBOX/install.out" "claude binary not usable" "and it says why the review agent was skipped"
assert_nogrep "$(nightly_plist)" "$SANDBOX/ephemeral" "no temp path in the nightly plist"

echo "# by default the list is TMPDIR plus the system temp dirs"
new_sandbox
mkdir -p "$SANDBOX/tmp/cmux-shims"; fake "$SANDBOX/tmp/cmux-shims/claude"; rm -f "$SANDBOX/bin/claude"
run_install "$SANDBOX/shim:$SANDBOX/tmp/cmux-shims:/usr/bin:/bin" TMPDIR="$SANDBOX/tmp/" -- "$SANDBOX/target"; rc=$?
assert_eq "$rc" "0" "the install succeeds"
assert_nogrep "$(nightly_plist)" "$SANDBOX/tmp" "a directory under TMPDIR is dropped"

echo "# AUTODREAM_EPHEMERAL_DIRS set but empty turns the check off"
new_sandbox
run_install "$SANDBOX/shim:$SANDBOX/bin:/usr/bin:/bin" AUTODREAM_EPHEMERAL_DIRS= -- "$SANDBOX/target"; rc=$?
assert_eq "$rc" "0" "the install succeeds"
has_dir "$(plist_path "$(nightly_plist)")" "$SANDBOX/bin" && ok "a fake-tool dir under TMPDIR is kept" || no "a fake-tool dir under TMPDIR is kept"
assert_nogrep "$SANDBOX/install.out" "ignoring PATH entries" "and nothing is reported as ignored"

echo "# --no-review provisions the nightly agent only"
new_sandbox
run_install "$(basepath):$SANDBOX/bin" AUTODREAM_EPHEMERAL_DIRS= -- --no-review "$SANDBOX/target"; rc=$?
assert_eq "$rc" "0" "the install succeeds"
[ -z "$(review_plist)" ] && ok "no review plist is written" || no "no review plist is written"
assert_eq "$(grep -c '^bootstrap' "$CALLS")" "1" "only the nightly agent is bootstrapped"
grep -qE "^bootout .*-review$" "$CALLS" && ok "any review job already loaded is booted out" || no "any review job already loaded is booted out"
assert_grep "$SANDBOX/install.out" "not provisioned (--no-review)" "the install says why"

echo "# --no-review removes a review plist an earlier install wrote"
new_sandbox
run_install "$(basepath):$SANDBOX/bin" AUTODREAM_EPHEMERAL_DIRS= -- "$SANDBOX/target"
[ -n "$(review_plist)" ] && ok "precondition: the first install wrote it" || no "precondition: the first install wrote it"
run_install "$(basepath):$SANDBOX/bin" AUTODREAM_EPHEMERAL_DIRS= -- --no-review "$SANDBOX/target"
[ -z "$(review_plist)" ] && ok "the second install removed it" || no "the second install removed it"

echo "# AUTODREAM_REVIEW_AGENT=0 in the config makes the opt-out stick across re-installs"
new_sandbox
mkdir -p "$SANDBOX/target/autodream"; printf 'AUTODREAM_REVIEW_AGENT=0\n' > "$SANDBOX/target/autodream/config"
run_install "$(basepath):$SANDBOX/bin" AUTODREAM_EPHEMERAL_DIRS= -- "$SANDBOX/target"
[ -z "$(review_plist)" ] && ok "no review plist from the config value" || no "no review plist from the config value"
assert_grep "$SANDBOX/install.out" "not provisioned (AUTODREAM_REVIEW_AGENT=0)" "and the install names the setting"

echo "# the environment wins over the config"
new_sandbox
mkdir -p "$SANDBOX/target/autodream"; printf 'AUTODREAM_REVIEW_AGENT=0\n' > "$SANDBOX/target/autodream/config"
run_install "$(basepath):$SANDBOX/bin" AUTODREAM_EPHEMERAL_DIRS= AUTODREAM_REVIEW_AGENT=1 -- "$SANDBOX/target"
[ -n "$(review_plist)" ] && ok "AUTODREAM_REVIEW_AGENT=1 in the environment provisions it" || no "AUTODREAM_REVIEW_AGENT=1 in the environment provisions it"

echo "# --no-review in a dry run shows no review plist"
new_sandbox
run_install "$(basepath):$SANDBOX/bin" AUTODREAM_EPHEMERAL_DIRS= -- --dry-run --no-review "$SANDBOX/target"; rc=$?
assert_eq "$rc" "0" "the dry run succeeds"
assert_nogrep "$SANDBOX/install.out" "-review.plist" "no review plist is shown"
assert_grep "$SANDBOX/install.out" "not provisioned (--no-review)" "and it says why"

echo "# --no-review never touches another install's review agent: a refused label stops before it"
new_sandbox
U=$(id -un | tr -dc 'a-zA-Z0-9')
cat > "$LA/com.$U.autodream.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>com.$U.autodream</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>/elsewhere/run.sh</string></array></dict></plist>
PL
sed "s/com.$U.autodream/com.$U.autodream-review/" "$LA/com.$U.autodream.plist" > "$LA/com.$U.autodream-review.plist"
BEFORE=$(cat "$LA/com.$U.autodream-review.plist")
run_install "$(basepath):$SANDBOX/bin" AUTODREAM_EPHEMERAL_DIRS= -- --no-review "$SANDBOX/target"; rc=$?
assert_eq "$rc" "0" "the install still exits 0 on the refusal"
assert_eq "$(cat "$LA/com.$U.autodream-review.plist")" "$BEFORE" "the other install's review plist is left byte-identical"
grep -q "autodream-review" "$CALLS" && no "launchctl was not asked about the other install's review agent" || ok "launchctl was not asked about the other install's review agent"

echo "# the CLI of every enabled adapter is reachable from the plist PATH"
new_sandbox
mkdir -p "$SANDBOX/omp-home"; fake "$SANDBOX/omp-home/omp"
run_install "$(basepath):$SANDBOX/bin:$SANDBOX/omp-home" AUTODREAM_EPHEMERAL_DIRS= -- --adapters claude,omp "$SANDBOX/target"
has_dir "$(plist_path "$(nightly_plist)")" "$SANDBOX/omp-home" && ok "omp's dir is in the PATH when omp is enabled" || no "omp's dir is in the PATH when omp is enabled"
new_sandbox
mkdir -p "$SANDBOX/omp-home"; fake "$SANDBOX/omp-home/omp"
run_install "$(basepath):$SANDBOX/bin:$SANDBOX/omp-home" AUTODREAM_EPHEMERAL_DIRS= -- "$SANDBOX/target"
has_dir "$(plist_path "$(nightly_plist)")" "$SANDBOX/omp-home" && no "omp's dir stays out of the PATH on a claude-only install" || ok "omp's dir stays out of the PATH on a claude-only install"

echo "# an adapter enabled in the config, with no flag, counts"
new_sandbox
mkdir -p "$SANDBOX/omp-home" "$SANDBOX/target/autodream"; fake "$SANDBOX/omp-home/omp"
printf 'AUTODREAM_ADAPTERS=claude,omp\n' > "$SANDBOX/target/autodream/config"
run_install "$(basepath):$SANDBOX/bin:$SANDBOX/omp-home" AUTODREAM_EPHEMERAL_DIRS= -- "$SANDBOX/target"
has_dir "$(plist_path "$(nightly_plist)")" "$SANDBOX/omp-home" && ok "omp's dir is in the PATH" || no "omp's dir is in the PATH"

echo "# OMP_BIN in the config names the dir even when omp is not on PATH"
new_sandbox
mkdir -p "$SANDBOX/bun/bin" "$SANDBOX/target/autodream"; fake "$SANDBOX/bun/bin/omp"
printf 'OMP_BIN=%s\n' "$SANDBOX/bun/bin/omp" > "$SANDBOX/target/autodream/config"
run_install "$(basepath):$SANDBOX/bin" AUTODREAM_EPHEMERAL_DIRS= -- --adapters claude,omp "$SANDBOX/target"
has_dir "$(plist_path "$(nightly_plist)")" "$SANDBOX/bun/bin" && ok "the OMP_BIN dir is in the PATH" || no "the OMP_BIN dir is in the PATH"

echo "# the L2 engine's CLI counts too: scan claude, run L2 on omp"
new_sandbox
mkdir -p "$SANDBOX/omp-home"; fake "$SANDBOX/omp-home/omp"
run_install "$(basepath):$SANDBOX/bin:$SANDBOX/omp-home" AUTODREAM_EPHEMERAL_DIRS= -- --adapters claude --l2-engine omp "$SANDBOX/target"
has_dir "$(plist_path "$(nightly_plist)")" "$SANDBOX/omp-home" && ok "--l2-engine omp adds omp's dir" || no "--l2-engine omp adds omp's dir"
new_sandbox
mkdir -p "$SANDBOX/omp-home" "$SANDBOX/target/autodream"; fake "$SANDBOX/omp-home/omp"
printf 'AUTODREAM_L2_ENGINE=omp\n' > "$SANDBOX/target/autodream/config"
run_install "$(basepath):$SANDBOX/bin:$SANDBOX/omp-home" AUTODREAM_EPHEMERAL_DIRS= -- "$SANDBOX/target"
has_dir "$(plist_path "$(nightly_plist)")" "$SANDBOX/omp-home" && ok "AUTODREAM_L2_ENGINE=omp in the config adds omp's dir" || no "AUTODREAM_L2_ENGINE=omp in the config adds omp's dir"

echo "# the config is read the way run.sh reads it: export, quotes and later lines"
new_sandbox
mkdir -p "$SANDBOX/omp-home" "$SANDBOX/target/autodream"; fake "$SANDBOX/omp-home/omp"
printf 'AUTODREAM_ADAPTERS=claude\nexport AUTODREAM_ADAPTERS="claude,omp"\n' > "$SANDBOX/target/autodream/config"
run_install "$(basepath):$SANDBOX/bin:$SANDBOX/omp-home" AUTODREAM_EPHEMERAL_DIRS= -- "$SANDBOX/target"
has_dir "$(plist_path "$(nightly_plist)")" "$SANDBOX/omp-home" && ok "an exported, quoted AUTODREAM_ADAPTERS is honoured" || no "an exported, quoted AUTODREAM_ADAPTERS is honoured"

echo "# an OMP_BIN only in the installer's environment is not carried to launchd, so it adds nothing"
new_sandbox
mkdir -p "$SANDBOX/omp-home" "$SANDBOX/dev"; fake "$SANDBOX/omp-home/omp"; fake "$SANDBOX/dev/omp-dev"
run_install "$(basepath):$SANDBOX/bin:$SANDBOX/omp-home" AUTODREAM_EPHEMERAL_DIRS= OMP_BIN="$SANDBOX/dev/omp-dev" -- --adapters claude,omp "$SANDBOX/target"
P=$(plist_path "$(nightly_plist)")
has_dir "$P" "$SANDBOX/dev" && no "the environment-only OMP_BIN dir stays out of the PATH" || ok "the environment-only OMP_BIN dir stays out of the PATH"
has_dir "$P" "$SANDBOX/omp-home" && ok "omp is found on PATH as the job will find it" || no "omp is found on PATH as the job will find it"

echo "# --adapters all reaches every real adapter, and never the _fixture one"
new_sandbox
mkdir -p "$SANDBOX/omp-home"; fake "$SANDBOX/omp-home/omp"
run_install "$(basepath):$SANDBOX/bin:$SANDBOX/omp-home" AUTODREAM_EPHEMERAL_DIRS= -- --adapters all "$SANDBOX/target"; rc=$?
assert_eq "$rc" "0" "the install succeeds"
has_dir "$(plist_path "$(nightly_plist)")" "$SANDBOX/omp-home" && ok "omp's dir is in the PATH" || no "omp's dir is in the PATH"

printf '\ninstall-path: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
