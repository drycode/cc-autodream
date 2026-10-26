# Adapter Substrate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce the harness-adapter substrate into cc-autodream so the Claude runner dispatches through an adapter, with no observable change in behavior.

**Architecture:** Three new library scripts (`lib-project.sh`, `preflight.sh`, `adapters.sh`) plus one real adapter (`adapters/claude/`) and one test-only adapter (`adapters/_fixture/`). `bin/run.sh` stops calling harness-specific logic directly and calls adapter subcommands instead. Session enumeration moves to NUL transport and gains a source sidecar, duplicate-path detection, and hash-collision detection. Nothing about L2, pins, memory, or OMP is touched here.

**Tech Stack:** bash 3.2 (macOS ships it — no associative arrays, no `mapfile`), `jq`, `shasum`, `python3`, `realpath`.

**Spec:** `docs/design/unify-harness-adapters-2026-08-23.md`

## Global Constraints

- **bash 3.2 compatible.** No associative arrays, no `mapfile`/`readarray`, no `${var^^}`. macOS ships bash 3.2 and the nightly runs there.
- **Behavior must not change.** The full suite is green at 283 passed / 0 failed on `origin/main` at `e231314`. Every task ends with that number holding or rising. It must never fall.
- **`shellcheck --severity=warning bin/*.sh adapters/*/*.sh` clean; `--severity=error tests/*.sh` clean.** Matches the repo's CI.
- **Adapter identity is the directory basename**, matching `[a-z][a-z0-9_-]*`, never a manifest field, and the directory must `realpath` to a path under the adapters root.
- **The artifact hash formula does not change.** It stays `sha1(bare session path)` truncated to 12 characters. Archived findings dirs and `bin/oversized-gate.sh` recompute it and must keep working.
- **`sessions.txt` stays one bare absolute path per line.** NUL transport applies to the in-memory fan-out only.
- **Every new counter is written to `run-stats.txt`**, following the repo's rule that a degraded measurement says so rather than reading as zero.
- **Test style matches `tests/run-all.sh`**: `ok`/`no`/`assert_eq`/`assert_grep`/`assert_file` helpers, `set -u`, fixed date `2020-01-02`.

---

### Task 1: Canonical project encoding

The load-bearing correctness fix. `seanperkins/autodream-merge` maps only `/`; Claude also maps `.` and `_`, and records the symlink-resolved physical path.

**Files:**
- Create: `bin/lib-project.sh`
- Test: `tests/lib-project.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `encode_project <abs-path>` prints the encoded bucket name on stdout, exit 0. `canonical_project <path>` resolves symlinks then encodes; exit 1 with no output if the path cannot be resolved.

- [ ] **Step 1: Write the failing test**

Create `tests/lib-project.sh`:

```bash
#!/bin/bash
# Unit tests for bin/lib-project.sh — the canonical project encoding.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$REPO/bin/lib-project.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

echo "# lib-project: encode_project maps / . and _ to -"
assert_eq "$(encode_project /Users/x/sites)" "-Users-x-sites" "plain path"
assert_eq "$(encode_project /Users/x/.claude)" "-Users-x--claude" "dot becomes a dash"
assert_eq "$(encode_project /Users/x/a_b)" "-Users-x-a-b" "underscore becomes a dash"
assert_eq "$(encode_project /Users/x/.a_b.c)" "-Users-x--a-b-c" "dots and underscores together"

echo "# lib-project: canonical_project resolves symlinks before encoding"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/libproj.XXXXXX")
mkdir -p "$tmp/real.dir"
ln -s "$tmp/real.dir" "$tmp/link"
want="$(encode_project "$(cd "$tmp/real.dir" && pwd -P)")"
assert_eq "$(canonical_project "$tmp/link")" "$want" "symlink resolves to its target"

echo "# lib-project: an unresolvable path fails loudly, never silently encodes"
canonical_project "$tmp/does-not-exist" >/dev/null 2>&1 \
  && no "missing path must exit nonzero" || ok "missing path exits nonzero"
assert_eq "$(canonical_project "$tmp/does-not-exist" 2>/dev/null)" "" "missing path prints nothing"

rm -rf "$tmp"
printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/lib-project.sh`
Expected: FAIL — `bin/lib-project.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

Create `bin/lib-project.sh`:

```bash
#!/bin/bash
# Canonical project identity, shared by every adapter.
#
# Claude derives a project bucket name from the session's cwd by mapping path
# separators AND dots AND underscores to dashes, on the symlink-resolved
# physical path. Verified against real buckets: /Users/x/.claude is stored as
# -Users-x--claude, not -Users-x-.claude, and /var/... is stored under
# -private-var-... because macOS resolves it.
#
# This lives in one place because every adapter must produce the SAME key for
# the same real directory — that is what makes one project out of two
# harnesses' work, and it is why this design has no reconciliation pass.
# seanperkins/autodream-merge reconciles after the fact with an encoder that
# maps only `/`, which silently splits every project whose path holds a `.`
# or `_`. Deriving once, here, removes the failure rather than fixing it.

encode_project() { # $1=absolute path -> encoded bucket name
  printf '%s' "$1" | tr '/._' '---'
}

canonical_project() { # $1=path -> encoded name for its resolved physical path
  local real
  real=$(realpath "$1" 2>/dev/null) || return 1
  [ -n "$real" ] || return 1
  encode_project "$real"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/lib-project.sh`
Expected: `passed: 7   failed: 0`

- [ ] **Step 5: Verify the full suite still passes**

Run: `AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 bash tests/run-all.sh 2>&1 | tail -3`
Expected: `passed: 283   failed: 0`

- [ ] **Step 6: Lint**

Run: `shellcheck --severity=warning bin/lib-project.sh && shellcheck --severity=error tests/lib-project.sh`
Expected: no output

- [ ] **Step 7: Commit**

```bash
git add bin/lib-project.sh tests/lib-project.sh
git commit -m "feat: canonical project encoding shared by every adapter" -m "Maps / . and _ to dashes on the symlink-resolved path, which is what Claude actually does. Deriving this once at triage time is what lets two harnesses group one directory as one project without a reconciliation pass."
```

---

### Task 2: Preflight dependency checks

**Files:**
- Create: `bin/preflight.sh`
- Test: `tests/preflight.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `bin/preflight.sh [--l2-bin <name>]` exits 0 when every dependency is present; exits 1 and prints one `MISSING: <name> — <why>` line per absent dependency. `preflight_missing_keys` prints the telemetry keys for the ones that failed.

- [ ] **Step 1: Write the failing test**

Create `tests/preflight.sh`:

```bash
#!/bin/bash
# Unit tests for bin/preflight.sh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
PF="$REPO/bin/preflight.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

echo "# preflight: a host with every dependency present exits 0"
"$PF" --l2-bin bash >/dev/null 2>&1 && ok "exits 0 when all present" || no "exits 0 when all present"

echo "# preflight: a missing L2 engine is a hard failure, named"
out=$("$PF" --l2-bin definitely-not-a-real-binary-xyz 2>&1)
[ $? -ne 0 ] && ok "exits nonzero on missing L2 engine" || no "exits nonzero on missing L2 engine"
case "$out" in *"definitely-not-a-real-binary-xyz"*) ok "names the missing engine" ;;
               *) no "names the missing engine (got: $out)" ;; esac

echo "# preflight: a missing shared dependency is named, not silently skipped"
# Shadow shasum with an empty PATH entry so the probe cannot find it.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pf.XXXXXX")
out=$(PATH="$tmp" "$PF" --l2-bin bash 2>&1)
case "$out" in *jq*)      ok "names jq" ;;      *) no "names jq (got: $out)" ;; esac
case "$out" in *shasum*)  ok "names shasum" ;;  *) no "names shasum (got: $out)" ;; esac
case "$out" in *realpath*) ok "names realpath" ;; *) no "names realpath (got: $out)" ;; esac

echo "# preflight: realpath is security-critical, so its absence is a hard stop"
case "$out" in *"containment"*) ok "says why realpath matters" ;;
               *) no "says why realpath matters (got: $out)" ;; esac

rm -rf "$tmp"
printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/preflight.sh`
Expected: FAIL — `bin/preflight.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

Create `bin/preflight.sh`:

```bash
#!/bin/bash
# Shared-dependency preflight. Runs before L1, and a failure here is a hard stop.
#
# These are not new assumptions — run.sh already depends on all four. They were
# simply never checked, and one of them fails silently in a way that destroys a
# night's corpus: with `shasum` absent the artifact hash assignment yields an
# empty string, so every session targets the same findings filename and the run
# ends with one record where it should have had a hundred.
#
# `realpath` is new and it is security-critical rather than convenient. It does
# adapter directory containment and cwd canonicalisation. A host that reached
# adapter loading without it would fall back to weaker containment, which is
# exactly the failure the check exists to prevent, so it is never a degraded path.
set -u

L2_BIN=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --l2-bin) L2_BIN="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

MISSING_KEYS=""
missing=0

need() { # $1=command $2=why
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'MISSING: %s — %s\n' "$1" "$2" >&2
    MISSING_KEYS="${MISSING_KEYS:+$MISSING_KEYS,}$1"
    missing=$((missing + 1))
  fi
}

need jq       "every findings record and manifest is parsed with it"
need shasum   "the artifact key is sha1 of the session path; without it every session collides on one filename"
need python3  "project normalisation and the stats sidecars"
need realpath "adapter directory containment and cwd canonicalisation; without it containment is weaker, which is the failure this check exists to prevent"

if [ -n "$L2_BIN" ] && ! command -v "$L2_BIN" >/dev/null 2>&1; then
  printf 'MISSING: %s — the configured L2 engine; no report is possible without it\n' "$L2_BIN" >&2
  MISSING_KEYS="${MISSING_KEYS:+$MISSING_KEYS,}l2_engine"
  missing=$((missing + 1))
fi

[ "$missing" -eq 0 ] || { printf 'preflight_missing: %s\n' "$MISSING_KEYS"; exit 1; }
exit 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/preflight.sh`
Expected: `passed: 7   failed: 0`

- [ ] **Step 5: Verify the full suite still passes**

Run: `AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 bash tests/run-all.sh 2>&1 | tail -3`
Expected: `passed: 283   failed: 0`

- [ ] **Step 6: Lint**

Run: `shellcheck --severity=warning bin/preflight.sh && shellcheck --severity=error tests/preflight.sh`
Expected: no output

- [ ] **Step 7: Commit**

```bash
git add bin/preflight.sh tests/preflight.sh
git commit -m "feat: preflight the shared dependencies run.sh already assumes" -m "A missing shasum is the dangerous one: the hash assignment silently empties and every session targets one findings filename. realpath is new and security-critical, so its absence is a hard stop rather than a fallback to weaker containment."
```

---

### Task 3: Adapter loading and identity validation

**Files:**
- Create: `bin/adapters.sh`
- Test: `tests/adapters.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `adapters_root` prints the adapters directory. `adapters_list` prints one safe adapter name per line, `_`-prefixed directories excluded. `adapter_manifest_get <name> <jq-path>` prints one manifest value with `$HOME` substituted. `adapter_run <name> <subcommand> [args...]` dispatches to `adapters/<name>/adapter.sh`. `ADAPTERS_REJECTED` holds a comma-separated list of refused directory names.

- [ ] **Step 1: Write the failing test**

Create `tests/adapters.sh`:

```bash
#!/bin/bash
# Unit tests for bin/adapters.sh — loading, identity safety, containment.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

sandbox(){ mktemp -d "${TMPDIR:-/tmp}/adapters.XXXXXX"; }
mk_adapter(){ # $1=root $2=name $3=manifest-name-field
  mkdir -p "$1/$2"
  printf '{"name":"%s","engine_bin":"bash","writes_memory":true}\n' "$3" > "$1/$2/manifest.json"
  printf '#!/bin/bash\necho "ran $1"\n' > "$1/$2/adapter.sh"
  chmod +x "$1/$2/adapter.sh"
}

echo "# adapters: a well-formed adapter loads and dispatches"
root=$(sandbox); mk_adapter "$root" claude claude
ADAPTERS_ROOT="$root" . "$REPO/bin/adapters.sh"
assert_eq "$(adapters_list)" "claude" "the adapter is listed"
assert_eq "$(adapter_manifest_get claude .engine_bin)" "bash" "manifest value reads back"
assert_eq "$(adapter_run claude hello)" "ran hello" "dispatch reaches adapter.sh"

echo "# adapters: manifest name must equal the directory basename"
root=$(sandbox); mk_adapter "$root" claude somethingelse
ADAPTERS_ROOT="$root" . "$REPO/bin/adapters.sh"
assert_eq "$(adapters_list)" "" "a name/basename mismatch is refused"
case "$ADAPTERS_REJECTED" in *claude*) ok "the refusal is counted" ;;
                             *) no "the refusal is counted (got: $ADAPTERS_REJECTED)" ;; esac

echo "# adapters: an unsafe basename is refused"
root=$(sandbox); mk_adapter "$root" ".evil" ".evil"
ADAPTERS_ROOT="$root" . "$REPO/bin/adapters.sh"
assert_eq "$(adapters_list)" "" "a dot-prefixed basename is refused"

echo "# adapters: a symlink escaping the adapters root is refused"
root=$(sandbox); outside=$(sandbox); mk_adapter "$outside" evil evil
ln -s "$outside/evil" "$root/evil"
ADAPTERS_ROOT="$root" . "$REPO/bin/adapters.sh"
assert_eq "$(adapters_list)" "" "a symlinked adapter dir is refused"
case "$ADAPTERS_REJECTED" in *evil*) ok "the escape is counted" ;;
                             *) no "the escape is counted (got: $ADAPTERS_REJECTED)" ;; esac

echo "# adapters: underscore-prefixed dirs are excluded from the default set"
root=$(sandbox); mk_adapter "$root" claude claude; mk_adapter "$root" _fixture _fixture
ADAPTERS_ROOT="$root" . "$REPO/bin/adapters.sh"
assert_eq "$(adapters_list)" "claude" "_fixture is not in the default set"

echo "# adapters: \$HOME is substituted, never evaluated"
root=$(sandbox); mkdir -p "$root/claude"
printf '{"name":"claude","session_roots_default":["$HOME/x`touch /tmp/pwned`"]}\n' > "$root/claude/manifest.json"
printf '#!/bin/bash\ntrue\n' > "$root/claude/adapter.sh"; chmod +x "$root/claude/adapter.sh"
ADAPTERS_ROOT="$root" . "$REPO/bin/adapters.sh"
got=$(adapter_manifest_get claude '.session_roots_default[0]')
assert_eq "$got" "$HOME/x\`touch /tmp/pwned\`" "backticks survive as literal text"
[ -e /tmp/pwned ] && no "manifest must not execute anything" || ok "manifest executed nothing"

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/adapters.sh`
Expected: FAIL — `bin/adapters.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

Create `bin/adapters.sh`:

```bash
#!/bin/bash
# Adapter loading and dispatch.
#
# The manifest is JSON, read with jq, and NOT sourced shell. A sourced manifest
# executes arbitrary code as the user, and a plugin format whose parser is bash
# is an injection surface the moment a third-party adapter is a reasonable idea.
#
# Identity is the DIRECTORY BASENAME and never a manifest field, because dispatch
# builds a command path from it. A manifest that could name the directory could
# reintroduce exactly the path construction that JSON parsing was adopted to
# remove. The basename check alone is not containment either: adapters/evil may
# be a symlink pointing anywhere, so each directory is realpath-resolved and
# refused unless it is still under the adapters root.
set -u

ADAPTERS_REJECTED=""

adapters_root() {
  if [ -n "${ADAPTERS_ROOT:-}" ]; then printf '%s' "$ADAPTERS_ROOT"; return 0; fi
  local here; here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  printf '%s' "$here/adapters"
}

_adapter_reject() { ADAPTERS_REJECTED="${ADAPTERS_REJECTED:+$ADAPTERS_REJECTED,}$1"; }

# A directory is a usable adapter iff: safe basename, not underscore-prefixed,
# realpath-contained under the adapters root, has a manifest and an executable
# adapter.sh, and the manifest's `name` equals the basename.
_adapter_ok() { # $1=name
  local root dir real name
  root=$(adapters_root)
  dir="$root/$1"
  case "$1" in
    _*) return 1 ;;                                  # test-only, excluded silently
    [a-z]*) : ;;                                     # must start lowercase
    *) _adapter_reject "$1"; return 1 ;;
  esac
  case "$1" in *[!a-z0-9_-]*) _adapter_reject "$1"; return 1 ;; esac
  real=$(realpath "$dir" 2>/dev/null) || { _adapter_reject "$1"; return 1; }
  case "$real" in
    "$(realpath "$root" 2>/dev/null)"/*) : ;;
    *) _adapter_reject "$1"; return 1 ;;             # symlink escaped the root
  esac
  [ -f "$dir/manifest.json" ] && [ -x "$dir/adapter.sh" ] || { _adapter_reject "$1"; return 1; }
  name=$(jq -r '.name // ""' "$dir/manifest.json" 2>/dev/null) || { _adapter_reject "$1"; return 1; }
  [ "$name" = "$1" ] || { _adapter_reject "$1"; return 1; }
  return 0
}

adapters_list() {
  local root d n
  root=$(adapters_root)
  [ -d "$root" ] || return 0
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    _adapter_ok "$n" && printf '%s\n' "$n"
  done
}

adapter_manifest_get() { # $1=name $2=jq path
  local root v
  root=$(adapters_root)
  v=$(jq -r "${2} // empty" "$root/$1/manifest.json" 2>/dev/null) || return 1
  # $HOME is the only interpolation, by substitution rather than evaluation.
  printf '%s' "${v//\$HOME/$HOME}"
}

adapter_run() { # $1=name $2=subcommand [args...]
  local root name; root=$(adapters_root); name="$1"; shift
  "$root/$name/adapter.sh" "$@"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/adapters.sh`
Expected: `passed: 12   failed: 0`

- [ ] **Step 5: Verify the full suite still passes**

Run: `AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 bash tests/run-all.sh 2>&1 | tail -3`
Expected: `passed: 283   failed: 0`

- [ ] **Step 6: Lint**

Run: `shellcheck --severity=warning bin/adapters.sh && shellcheck --severity=error tests/adapters.sh`
Expected: no output

- [ ] **Step 7: Commit**

```bash
git add bin/adapters.sh tests/adapters.sh
git commit -m "feat: adapter loading with JSON manifests and contained identity" -m "Identity is the directory basename, never a manifest field, because dispatch builds a command path from it. Directories are realpath-contained so a symlinked adapter dir cannot escape the root, which a basename check alone does not stop."
```

---

### Task 4: The claude adapter

Wraps existing behavior. No logic is invented here; each subcommand delegates to the script that already does the work.

**Files:**
- Create: `adapters/claude/manifest.json`, `adapters/claude/adapter.sh`, `adapters/claude/facts.md`
- Test: `tests/adapter-claude.sh`

**Interfaces:**
- Consumes: `bin/lib-project.sh` (`canonical_project`), `bin/session-stats.sh`, `bin/slim-transcript.sh`, `bin/prune-self-sessions.sh`, `bin/root-probe.sh`.
- Produces: `adapters/claude/adapter.sh <enumerate|normalize|project|memory-root|stats|slim|is-self|skills-inventory>`.

- [ ] **Step 1: Write the failing test**

Create `tests/adapter-claude.sh`:

```bash
#!/bin/bash
# Contract tests for the claude adapter.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
A="$REPO/adapters/claude/adapter.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/adclaude.XXXXXX")
mkdir -p "$tmp/projects/-tmp-proj-a"
S="$tmp/projects/-tmp-proj-a/s1.jsonl"
printf '%s\n' \
  '{"type":"user","cwd":"/tmp/proj-a","message":{"content":"hello"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}' > "$S"

echo "# claude adapter: project returns the resolved cwd, not the bucket name"
got=$("$A" project "$S")
want=$(cd /tmp && realpath /tmp/proj-a 2>/dev/null || printf '/private/tmp/proj-a')
mkdir -p /tmp/proj-a
assert_eq "$("$A" project "$S")" "$(realpath /tmp/proj-a)" "resolved cwd from the transcript"

echo "# claude adapter: normalize is a copy for this harness"
out="$tmp/norm.jsonl"
"$A" normalize "$S" "$out" && ok "normalize exits 0" || no "normalize exits 0"
assert_eq "$(cmp -s "$S" "$out" && echo same)" "same" "normalize copied the file verbatim"

echo "# claude adapter: normalize leaves no partial output on failure"
"$A" normalize "$tmp/missing.jsonl" "$tmp/partial.jsonl" 2>/dev/null \
  && no "missing input must exit nonzero" || ok "missing input exits nonzero"
[ -e "$tmp/partial.jsonl" ] && no "no partial output" || ok "no partial output"

echo "# claude adapter: memory-root is absolute and canonical"
mr=$("$A" memory-root "$S")
case "$mr" in /*) ok "memory-root is absolute" ;; *) no "memory-root is absolute (got: $mr)" ;; esac

echo "# claude adapter: is-self recognises an autodream worker transcript"
W="$tmp/projects/-tmp-proj-a/worker.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"Session transcript to analyze (literal absolute path): /x"}}' > "$W"
"$A" is-self "$W" && ok "worker transcript is ours" || no "worker transcript is ours"
"$A" is-self "$S" && no "a real session is not ours" || ok "a real session is not ours"

rm -rf "$tmp" /tmp/proj-a
printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/adapter-claude.sh`
Expected: FAIL — `adapters/claude/adapter.sh: No such file or directory`

- [ ] **Step 3: Write the manifest**

Create `adapters/claude/manifest.json`:

```json
{
  "name": "claude",
  "session_roots_default": ["$HOME/.claude/projects"],
  "session_glob": "*.jsonl",
  "engine_bin": "claude",
  "engine_flags_l1": [
    "--print",
    "--permission-mode", "bypassPermissions",
    "--no-session-persistence",
    "--tools", "Read", "Write",
    "--disable-slash-commands",
    "--strict-mcp-config"
  ],
  "l1_model": "claude-haiku-4-5",
  "writes_memory": true
}
```

- [ ] **Step 4: Write the adapter**

Create `adapters/claude/adapter.sh` (mode 755):

```bash
#!/bin/bash
# Claude Code harness adapter. Every subcommand delegates to the script that
# already implements this behavior — nothing new is invented here. This exists
# so run.sh stops knowing which harness it is talking to.
set -u

BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../bin" && pwd)
# shellcheck source=/dev/null
. "$BIN/lib-project.sh"

cmd="${1:-}"; shift 2>/dev/null || true

case "$cmd" in
  enumerate) # $1=root $2=date $3=next-date -> NUL-delimited session paths
    find "$1" -type f -name '*.jsonl' \
         -newermt "$2 00:00:00" ! -newermt "$3 00:00:00" -print0 2>/dev/null
    ;;

  normalize) # $1=in $2=out. A Claude transcript is already a flat turn list.
    [ -r "$1" ] || exit 1
    cp "$1" "$2.tmp" 2>/dev/null || { rm -f "$2.tmp"; exit 1; }
    mv "$2.tmp" "$2" || { rm -f "$2.tmp"; exit 1; }
    ;;

  project) # $1=session -> the session's real working directory
    cwd=$(grep -om1 '"cwd":"[^"]*"' "$1" 2>/dev/null | head -1 | sed 's/^"cwd":"//;s/"$//')
    [ -n "$cwd" ] || exit 1
    realpath "$cwd" 2>/dev/null || exit 1
    ;;

  memory-root) # $1=session -> the Claude root that owns it
    # The session lives at <root>/projects/<bucket>/<file>. Walk up to <root>.
    d=$(cd "$(dirname "$1")/../.." 2>/dev/null && pwd -P) || exit 1
    [ -d "$d" ] || exit 1
    printf '%s' "$d"
    ;;

  stats) exec "$BIN/session-stats.sh" "$1" ;;
  slim)  exec "$BIN/slim-transcript.sh" "$1" "$2" ;;

  is-self) exec "$BIN/prune-self-sessions.sh" --is-self "$1" ;;

  skills-inventory)
    for d in "$HOME"/.claude/skills/*/ "$HOME"/.claude/plugins/*/skills/*/; do
      [ -f "$d/SKILL.md" ] || continue
      printf '%s\n' "$(basename "$d")"
    done
    ;;

  *) printf 'claude adapter: unknown subcommand: %s\n' "$cmd" >&2; exit 2 ;;
esac
```

- [ ] **Step 5: Write facts.md**

Create `adapters/claude/facts.md`:

```markdown
Sessions from this source ran under Claude Code. When you propose a remedy for a
finding whose evidence is a `claude` session, these are the surfaces that exist:

- `sandbox_friction` → a `permissions.allow` entry in `~/.claude/settings.json`.
- `missed_skill` → a trigger phrase in the skill's `SKILL.md` frontmatter
  `description`. Skills live under `~/.claude/skills/` and
  `~/.claude/plugins/*/skills/`.
- `memory_miss` → a pinned entry in the project's `MEMORY.md`.
- `compliance_failure` → cite `~/.claude/CLAUDE.md` or the project `CLAUDE.md`.

This harness has a memory store, so a pin proposed for a `claude` source will be
written.
```

- [ ] **Step 6: Add the `--is-self` flag to the pruner**

`bin/prune-self-sessions.sh` already holds the predicate but exposes it only as a
filter. Add a single-file mode near its argument parsing so the adapter can reuse
the one source of truth rather than copying the marker list:

```bash
  --is-self) # $2=session path; exit 0 if this is one of our own worker transcripts
    is_self_session "$2" && exit 0 || exit 1
    ;;
```

- [ ] **Step 7: Run test to verify it passes**

Run: `chmod +x adapters/claude/adapter.sh && bash tests/adapter-claude.sh`
Expected: `passed: 9   failed: 0`

- [ ] **Step 8: Verify the full suite still passes**

Run: `AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 bash tests/run-all.sh 2>&1 | tail -3`
Expected: `passed: 283   failed: 0`

- [ ] **Step 9: Lint**

Run: `shellcheck --severity=warning adapters/claude/adapter.sh bin/prune-self-sessions.sh && shellcheck --severity=error tests/adapter-claude.sh`
Expected: no output

- [ ] **Step 10: Commit**

```bash
git add adapters/claude tests/adapter-claude.sh bin/prune-self-sessions.sh
git commit -m "feat: claude harness adapter wrapping existing behavior" -m "Every subcommand delegates to the script that already implements it, so this adds a seam without changing what runs. The pruner gains --is-self so the adapter reuses the one self-pollution predicate rather than copying its marker list."
```

---

### Task 5: NUL transport and newline rejection

**Files:**
- Modify: `bin/run.sh` — `scan_roots()` at `bin/run.sh:312-336`
- Test: `tests/run-all.sh` (append a new test function)

**Interfaces:**
- Consumes: `adapter_run <name> enumerate`.
- Produces: `sessions.txt` unchanged in shape (one bare path per line); new counter `sessions_rejected_path`.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-all.sh`, and add its name to the runner list at the bottom of that file:

```bash
test_newline_path_is_rejected_not_split(){
  echo "# enumeration: a path containing a newline is rejected, never split into two"
  local root; root=$(setup_env)
  mk_session "$root" good
  # A file whose name embeds a newline. sessions.txt is line-based and cannot
  # represent it; splitting it would invent a second, nonexistent session.
  local bad; bad=$(printf '%s/projects/proj-a/ba\nd.jsonl' "$root")
  printf '%s\n' '{"type":"user","cwd":"/tmp/proj-a","message":{"content":"x"}}' > "$bad" 2>/dev/null || {
    ok "filesystem refused a newline filename; nothing to reject"; return 0; }
  touch -t "$STAMP" "$bad"
  run_autodream "$root"
  local f="$root/autodream/findings/$DATE"
  assert_eq "$(grep -c . "$f/sessions.txt")" "1" "only the good session is listed"
  assert_grep "$f/run-stats.txt" 'sessions_rejected_path: 1' "the rejection is counted"
  assert_grep "$root/autodream/logs/run-$DATE.log" 'newline' "the log names the character"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 bash tests/run-all.sh 2>&1 | rg -A3 'newline'`
Expected: FAIL — `sessions_rejected_path: 1` not found in `run-stats.txt`

- [ ] **Step 3: Rewrite `scan_roots` to use NUL transport**

Replace the body of `scan_roots()` in `bin/run.sh`:

```bash
scan_roots() {
  : > "$SESSIONS_LIST.raw"
  REJECTED_PATHS=0
  local -a roots
  IFS=: read -ra roots <<< "$SESSION_ROOTS"
  local r sp
  for r in "${roots[@]}"; do
    [ -n "$r" ] || continue
    if [ ! -d "$r" ]; then
      log "WARNING: session root is not a directory (possible ':' in path — SESSION_ROOTS is colon-separated): $r"
      continue
    fi
    # NUL transport removes the whole class of word-splitting bugs on the paths
    # that ARE accepted — spaces, tabs, glob characters. It does not save a path
    # containing a newline, because sessions.txt is line-based and every archived
    # findings dir plus oversized-gate.sh depend on that shape. So the newline is
    # rejected here, before either representation is built.
    while IFS= read -r -d '' sp; do
      case "$sp" in
        *"$NL"*)
          REJECTED_PATHS=$((REJECTED_PATHS + 1))
          log "  skip: session path contains a newline, which a line-based sessions.txt cannot represent: $(printf '%q' "$sp")"
          continue
          ;;
      esac
      printf '%s\n' "$sp" >> "$SESSIONS_LIST.raw"
    done < <(find "$r" -type f -name '*.jsonl' \
                  -newermt "$TARGET_DATE 00:00:00" \
                  ! -newermt "$NEXT_DATE 00:00:00" \
                  -print0 2>/dev/null)
  done
  sort -u "$SESSIONS_LIST.raw" -o "$SESSIONS_LIST.raw"
  RAW=$(wc -l < "$SESSIONS_LIST.raw" | tr -d ' ')
}
```

Add near the top of `bin/run.sh`, beside the other globals:

```bash
NL=$'\n'          # for the newline-in-path check in scan_roots
REJECTED_PATHS=0
```

- [ ] **Step 4: Emit the counter**

In the `run-stats.txt` writer (near `bin/run.sh:986`), add:

```bash
    printf 'sessions_rejected_path: %s\n' "$REJECTED_PATHS"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 bash tests/run-all.sh 2>&1 | tail -3`
Expected: `passed: 286   failed: 0` (283 baseline + 3 new assertions)

- [ ] **Step 6: Lint**

Run: `shellcheck --severity=warning bin/run.sh && shellcheck --severity=error tests/run-all.sh`
Expected: no output

- [ ] **Step 7: Commit**

```bash
git add bin/run.sh tests/run-all.sh
git commit -m "fix: NUL transport for enumeration, and reject newline paths" -m "A path containing a newline currently splits into two sessions, inventing one that does not exist. sessions.txt stays line-based because oversized-gate.sh and every archived findings dir recompute from it, so the newline is rejected at enumeration rather than transported."
```

---

### Task 6: Source sidecar, duplicate paths, hash collisions

**Files:**
- Modify: `bin/run.sh` — the union step after `scan_roots`
- Test: `tests/run-all.sh` (append two test functions)

**Interfaces:**
- Consumes: `adapters_list`, `adapter_run <name> enumerate`.
- Produces: `findings/<date>/sessions-source.txt` as `<hash>\t<source>`; counters `sessions_duplicate_path`, `sessions_hash_collision`, `sessions_by_source`.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-all.sh`:

```bash
test_source_sidecar_is_written(){
  echo "# union: every triaged session gets a source sidecar line keyed by hash"
  local root; root=$(setup_env)
  mk_session "$root" a
  run_autodream "$root"
  local f="$root/autodream/findings/$DATE"
  assert_file "$f/sessions-source.txt" "the sidecar exists"
  local sp h
  sp=$(head -1 "$f/sessions.txt")
  h=$(printf '%s' "$sp" | shasum -a 1 | cut -c1-12)
  assert_grep "$f/sessions-source.txt" "^$h	claude$" "the hash maps to its source"
  assert_grep "$f/run-stats.txt" 'sessions_by_source: claude=1' "per-source counts are recorded"
}

test_hash_stays_sha1_of_the_bare_path(){
  echo "# union: the artifact hash is unchanged, so archived dirs keep working"
  local root; root=$(setup_env)
  mk_session "$root" a
  run_autodream "$root"
  local f="$root/autodream/findings/$DATE"
  local sp h
  sp=$(head -1 "$f/sessions.txt")
  h=$(printf '%s' "$sp" | shasum -a 1 | cut -c1-12)
  assert_file "$f/$h.json" "the findings record is keyed by sha1 of the bare path"
  assert_nogrep "$f/sessions.txt" '	' "sessions.txt holds no tab-delimited fields"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 bash tests/run-all.sh 2>&1 | rg -B1 -A3 'sidecar exists'`
Expected: FAIL — `sessions-source.txt` missing

- [ ] **Step 3: Write the union step**

Add to `bin/run.sh`, called immediately after `scan_roots`:

```bash
# Build the source sidecar and detect the two ways two adapters can land on one
# artifact. The hash formula is deliberately NOT changed to include the source:
# oversized-gate.sh and every archived findings dir recompute sha1(bare path),
# and moving the formula would silently invalidate all of them.
build_source_sidecar() {
  local sidecar="$FINDINGS_DIR/sessions-source.txt"
  local seen="$FINDINGS_DIR/.hash-to-path"
  : > "$sidecar"; : > "$seen"
  DUPLICATE_PATHS=0; HASH_COLLISIONS=0; SESSIONS_BY_SOURCE=""
  local src n sp h prev
  for src in $(adapters_list); do
    n=0
    while IFS= read -r sp; do
      [ -n "$sp" ] || continue
      h=$(printf '%s' "$sp" | shasum -a 1 | cut -c1-12)
      prev=$(awk -F'\t' -v k="$h" '$1==k {print $2; exit}' "$seen")
      if [ -n "$prev" ]; then
        if [ "$prev" = "$sp" ]; then
          # Same path claimed by a second adapter: a misconfiguration worth
          # seeing. Keep the first, since the findings record is already keyed.
          DUPLICATE_PATHS=$((DUPLICATE_PATHS + 1))
          log "  duplicate: $sp claimed by more than one adapter; keeping the first"
        else
          # Two DIFFERENT paths on one truncated hash. There is no sensible
          # winner, so skip both rather than choosing arbitrarily.
          HASH_COLLISIONS=$((HASH_COLLISIONS + 1))
          log "  COLLISION: $h maps to two different sessions; skipping both: $prev / $sp"
          sed -i '' "/^$h	/d" "$sidecar" 2>/dev/null || true
        fi
        continue
      fi
      printf '%s\t%s\n' "$h" "$sp" >> "$seen"
      printf '%s\t%s\n' "$h" "$src" >> "$sidecar"
      n=$((n + 1))
    done < "$SESSIONS_LIST"
    SESSIONS_BY_SOURCE="${SESSIONS_BY_SOURCE:+$SESSIONS_BY_SOURCE,}$src=$n"
  done
  rm -f "$seen"
}
```

- [ ] **Step 4: Emit the counters**

In the `run-stats.txt` writer, add:

```bash
    printf 'sessions_by_source: %s\n' "${SESSIONS_BY_SOURCE:-none}"
    printf 'sessions_duplicate_path: %s\n' "$DUPLICATE_PATHS"
    printf 'sessions_hash_collision: %s\n' "$HASH_COLLISIONS"
    printf 'adapters_enabled: %s\n' "$(adapters_list | tr '\n' ',' | sed 's/,$//')"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 bash tests/run-all.sh 2>&1 | tail -3`
Expected: `passed: 291   failed: 0` (286 + 5 new assertions)

- [ ] **Step 6: Lint**

Run: `shellcheck --severity=warning bin/run.sh && shellcheck --severity=error tests/run-all.sh`
Expected: no output

- [ ] **Step 7: Commit**

```bash
git add bin/run.sh tests/run-all.sh
git commit -m "feat: source sidecar, duplicate-path and hash-collision detection" -m "Source is carried in sessions-source.txt keyed by hash rather than tagged into sessions.txt, because four consumers derive the artifact key from the whole line and archived findings dirs recompute it. Two distinct paths on one truncated hash skip both, since there is no sensible winner."
```

---

### Task 7: The fixture adapter

This is what makes "adding codex later is one directory" checkable rather than aspirational.

**Files:**
- Create: `adapters/_fixture/manifest.json`, `adapters/_fixture/adapter.sh`, `adapters/_fixture/facts.md`
- Test: `tests/adapter-contract.sh`

**Interfaces:**
- Consumes: `bin/adapters.sh`.
- Produces: a synthetic harness exercising every subcommand with no real engine installed.

- [ ] **Step 1: Write the failing test**

Create `tests/adapter-contract.sh`:

```bash
#!/bin/bash
# The adapter contract, exercised against a synthetic harness. If this passes
# with neither claude nor omp installed, the contract is real rather than a
# description of what the claude adapter happens to do.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
A="$REPO/adapters/_fixture/adapter.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/adcontract.XXXXXX")
mkdir -p "$tmp/store" "$tmp/mem"
S="$tmp/store/s1.fixture"
printf '{"cwd":"%s","turns":2}\n' "$tmp" > "$S"

echo "# contract: every required subcommand exists and exits 0 on a valid session"
for c in project memory-root stats skills-inventory; do
  "$A" "$c" "$S" >/dev/null 2>&1 && ok "$c exits 0" || no "$c exits 0"
done

echo "# contract: normalize writes atomically and leaves nothing behind on failure"
"$A" normalize "$S" "$tmp/out.fixture" && ok "normalize exits 0" || no "normalize exits 0"
[ -s "$tmp/out.fixture" ] && ok "normalize wrote output" || no "normalize wrote output"
[ -e "$tmp/out.fixture.tmp" ] && no "no .tmp left behind" || ok "no .tmp left behind"
"$A" normalize "$tmp/nope" "$tmp/bad.fixture" 2>/dev/null \
  && no "bad input exits nonzero" || ok "bad input exits nonzero"
[ -e "$tmp/bad.fixture" ] && no "no partial output on failure" || ok "no partial output on failure"

echo "# contract: project prints an absolute resolved path"
p=$("$A" project "$S")
case "$p" in /*) ok "project is absolute" ;; *) no "project is absolute (got: $p)" ;; esac

echo "# contract: stats is valid JSON with a numeric transcript_bytes"
"$A" stats "$S" | jq -e '.transcript_bytes | numbers' >/dev/null 2>&1 \
  && ok "stats has numeric transcript_bytes" || no "stats has numeric transcript_bytes"

echo "# contract: an unknown subcommand exits 2, never 0"
"$A" not-a-subcommand >/dev/null 2>&1; assert_eq "$?" "2" "unknown subcommand exits 2"

rm -rf "$tmp"
printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/adapter-contract.sh`
Expected: FAIL — `adapters/_fixture/adapter.sh: No such file or directory`

- [ ] **Step 3: Write the fixture manifest**

Create `adapters/_fixture/manifest.json`:

```json
{
  "name": "_fixture",
  "session_roots_default": ["$HOME/.autodream-fixture/store"],
  "session_glob": "*.fixture",
  "engine_bin": "true",
  "engine_flags_l1": [],
  "l1_model": "fixture",
  "writes_memory": false
}
```

- [ ] **Step 4: Write the fixture adapter**

Create `adapters/_fixture/adapter.sh` (mode 755):

```bash
#!/bin/bash
# A synthetic harness whose only purpose is to prove the adapter contract is a
# contract. It is excluded from the default adapter set by its leading
# underscore, so a nightly run never sees it.
#
# Its session format is one JSON object per file with `cwd` and `turns`, which
# resembles neither real harness on purpose: a fixture that mirrored Claude
# would pass by accident.
set -u
BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../bin" && pwd)
# shellcheck source=/dev/null
. "$BIN/lib-project.sh"

cmd="${1:-}"; shift 2>/dev/null || true

case "$cmd" in
  enumerate) find "$1" -type f -name '*.fixture' -print0 2>/dev/null ;;

  normalize)
    [ -r "$1" ] || exit 1
    jq -e . "$1" >/dev/null 2>&1 || exit 1
    cp "$1" "$2.tmp" 2>/dev/null || { rm -f "$2.tmp"; exit 1; }
    mv "$2.tmp" "$2" || { rm -f "$2.tmp"; exit 1; }
    ;;

  project)
    cwd=$(jq -r '.cwd // empty' "$1" 2>/dev/null) || exit 1
    [ -n "$cwd" ] || exit 1
    realpath "$cwd" 2>/dev/null || exit 1
    ;;

  memory-root) exit 0 ;;   # writes_memory:false — empty is legal here and only here

  stats)
    bytes=$(wc -c < "$1" | tr -d ' ')
    turns=$(jq -r '.turns // 0' "$1" 2>/dev/null)
    printf '{"transcript_bytes":%s,"user_message_count":%s,"tool_call_count":0}\n' "$bytes" "$turns"
    ;;

  slim)
    [ -r "$1" ] || exit 1
    cp "$1" "$2.tmp" 2>/dev/null || { rm -f "$2.tmp"; exit 1; }
    mv "$2.tmp" "$2" || { rm -f "$2.tmp"; exit 1; }
    ;;

  is-self) exit 1 ;;                 # the fixture harness never runs autodream
  skills-inventory) printf 'fixture-skill\n' ;;

  *) printf '_fixture adapter: unknown subcommand: %s\n' "$cmd" >&2; exit 2 ;;
esac
```

- [ ] **Step 5: Write facts.md**

Create `adapters/_fixture/facts.md`:

```markdown
A synthetic harness used only by the test suite. It has no memory store, so a
pin proposed for this source is reported and never written.
```

- [ ] **Step 6: Run test to verify it passes**

Run: `chmod +x adapters/_fixture/adapter.sh && bash tests/adapter-contract.sh`
Expected: `passed: 12   failed: 0`

- [ ] **Step 7: Verify the fixture is excluded from the real run**

Run: `AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 bash tests/run-all.sh 2>&1 | rg 'adapters_enabled|passed:' | tail -3`
Expected: `adapters_enabled: claude` and `passed: 291   failed: 0`

- [ ] **Step 8: Lint**

Run: `shellcheck --severity=warning adapters/_fixture/adapter.sh && shellcheck --severity=error tests/adapter-contract.sh`
Expected: no output

- [ ] **Step 9: Commit**

```bash
git add adapters/_fixture tests/adapter-contract.sh
git commit -m "test: a fixture adapter that proves the contract is a contract" -m "Its session format resembles neither real harness on purpose; a fixture that mirrored Claude would pass by accident. Excluded from the default set by its leading underscore, so a nightly run never sees it."
```

---

### Task 8: Wire run.sh through the adapter

The last task, and the one that must change nothing observable.

**Files:**
- Modify: `bin/run.sh` — source the libraries, run preflight, dispatch enumeration and per-session work through `adapter_run`
- Test: `tests/run-all.sh` (append one test function)

**Interfaces:**
- Consumes: everything above.
- Produces: no new external interface. The observable output of a single-harness run is byte-identical to `origin/main`.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-all.sh`:

```bash
test_preflight_blocks_a_run_missing_a_dependency(){
  echo "# preflight: a missing shared dependency stops the run before L1"
  local root; root=$(setup_env)
  mk_session "$root" a
  # An empty PATH entry hides shasum, whose absence silently collapses every
  # session onto one findings filename — the failure preflight exists to catch.
  local empty; empty=$(mktemp -d "${TMPDIR:-/tmp}/nopath.XXXXXX")
  PATH="$empty" run_autodream "$root" 2>/dev/null || true
  local f="$root/autodream/findings/$DATE"
  assert_no_file "$f/sessions.txt" "no enumeration happened"
  assert_grep "$root/autodream/logs/run-$DATE.log" 'preflight' "the log says preflight stopped it"
  rm -rf "$empty"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 bash tests/run-all.sh 2>&1 | rg -A3 'preflight stopped'`
Expected: FAIL — no `preflight` line in the log

- [ ] **Step 3: Source the libraries in run.sh**

Near the top of `bin/run.sh`, after `AUTODREAM_DIR` is resolved and before the config source:

```bash
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib-project.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/adapters.sh"
```

- [ ] **Step 4: Run preflight at the top of `run()`**

Immediately after the log file is opened and before `unassembled_dates`:

```bash
  if ! "$SCRIPT_DIR/preflight.sh" --l2-bin "$CLAUDE_BIN" 2>>"$RUN_LOG"; then
    log "FATAL: preflight failed; see the MISSING lines above. Nothing was enumerated."
    return 1
  fi
```

- [ ] **Step 5: Dispatch enumeration through the adapter**

In `scan_roots()`, replace the inline `find` with the adapter call, keeping the
newline rejection from Task 5 in place:

```bash
    done < <(adapter_run "$src" enumerate "$r" "$TARGET_DATE" "$NEXT_DATE")
```

where `$src` iterates `adapters_list` and each adapter's roots come from
`adapter_manifest_get "$src" '.session_roots_default[]'` unless `SESSION_ROOTS`
overrides them.

- [ ] **Step 6: Run test to verify it passes**

Run: `AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 bash tests/run-all.sh 2>&1 | tail -3`
Expected: `passed: 293   failed: 0` (291 + 2 new assertions)

- [ ] **Step 7: Prove behavior did not change**

Run a real date twice — once from `origin/main`, once from this branch — into
separate `AUTODREAM_DIR`s, then diff the findings dirs:

```bash
git stash && AUTODREAM_DIR=/tmp/ad-before bin/run.sh 2026-08-21 ; git stash pop
AUTODREAM_DIR=/tmp/ad-after bin/run.sh 2026-08-21
diff -r /tmp/ad-before/findings/2026-08-21 /tmp/ad-after/findings/2026-08-21 \
  --exclude='run-stats.txt' --exclude='*.log'
```

Expected: no differences. `run-stats.txt` is excluded because it legitimately
gains the new counters.

- [ ] **Step 8: Lint**

Run: `shellcheck --severity=warning bin/*.sh adapters/*/*.sh && shellcheck --severity=error tests/*.sh`
Expected: no output

- [ ] **Step 9: Commit**

```bash
git add bin/run.sh tests/run-all.sh
git commit -m "feat: dispatch enumeration and per-session work through the adapter" -m "run.sh stops knowing which harness it is talking to. Preflight now runs before anything is enumerated, so a missing shasum stops the run instead of collapsing every session onto one findings filename. A real date run before and after produces byte-identical findings."
```

---

## What this plan deliberately does not do

Three further plans follow, each producing working software on its own:

- **Plan 2 — OMP adapter.** The linearizer written from scratch with its rejection fixtures (malformed JSON, dangling `parentId`, cycle), dual-schema stats, `skills-inventory`. Depends on this plan's contract.
- **Plan 3 — L2 purity and the pin protocol.** `PROMPT.md` rewritten stdout-only, the sentinel grammar, `(source, memory_root, project)` triple validation and expansion, `apply-pin` exit protocol, adapter-owned GC. This is where `STRML/cc-autodream#52` is actually fixed.
- **Plan 4 — Rename and archive.** `STRML/cc-autodream` to `STRML/autodream`, adapter install hooks, archiving `omp-autodream` and `autodream-merge`.

## Self-review notes

- **Spec coverage for this plan's slice:** canonical project identity (Task 1), preflight (Task 2), manifest JSON and identity containment (Task 3), the claude adapter and `facts.md` (Task 4), NUL transport and newline rejection (Task 5), source sidecar plus duplicate and collision detection (Task 6), fixture adapter (Task 7), wiring (Task 8). The spec's L2, pin, GC and rename sections are explicitly deferred to Plans 2–4.
- **Assertion arithmetic:** 283 baseline, +3 (Task 5), +5 (Task 6), +2 (Task 8) = 293 in `run-all.sh`, plus four standalone suites (`lib-project`, `preflight`, `adapters`, `adapter-claude`, `adapter-contract`) run separately.
- **Known gap carried into Plan 2:** `adapter_run` does not yet pass a per-adapter engine or model; nothing in this plan needs it, because the claude adapter's L1 invocation still goes through the existing `run.sh` path. Plan 2 introduces it when a second engine exists.

---

## Superseded by review

**The tab policy in the task bodies above is HISTORICAL and no longer what the code does.**
Those snippets reject the newline alone and accept tabs. The changeset review overturned
that: the L1 fan-out is `xargs -I` over a line-based list, which turns a tab into a space,
deletes a backslash, and dies outright on a quote — taking the whole night's dispatch
rather than one session. Enumeration now refuses all four. The design doc carries the
current rule and the reasoning; `STRML/cc-autodream#54` tracks making the fan-out NUL-safe
so the three non-newline characters can be accepted again.

The task snippets are left as written because they record what was planned, and the
deviations section below is where the plan and the code are reconciled.

## As built — deviations from the plan above

Recorded rather than silently absorbed, because the plan is committed and a
future reader will otherwise trust it over the code.

1. **Tasks 6 and 8 were merged.** The source sidecar can only be built once
   enumeration knows which adapter found which session, so building it first
   from a union list would have been work immediately rewritten.

2. **`stats` takes `<in> <out>`, not `<in>` printing to stdout.** The plan
   invented a signature; `bin/session-stats.sh` already takes two arguments and
   writes a sidecar file. The contract follows the existing script.

3. **`memory-root` walks up to the `projects` directory** rather than taking a
   fixed number of `..` hops. A subagent transcript sits two levels deeper at
   `projects/<bucket>/<session>/subagents/agent-*.jsonl`, and CLAUDE.md is
   explicit that those are legitimate sessions to triage. The plan's fixed hop
   count resolved them to the wrong root, silently.

4. **`adapter_roots` must newline-terminate every line.** `while read` drops a
   final unterminated line, so a `printf '%s'` skipped the only root on a
   single-root host. Enumeration then found nothing and reported it as a quiet
   zero — 155 assertions failed at once and the visible symptom was an artifact
   named `da39a3ee5e6b`, the sha1 of the empty string. Worth naming because the
   failure mode is a plausible-looking zero rather than an error.

5. **The contract test runs against BOTH adapters**, not just the fixture. Same
   assertions, two harnesses. A contract exercised only against the adapter it
   was written beside is a description of that adapter.

6. **`preflight.sh` gained `AUTODREAM_PREFLIGHT_FORCE_MISSING`.** Emptying
   `PATH` to hide one dependency also hides bash's own helpers, so the suite
   could not otherwise exercise a single missing tool. Test-only, unset in every
   real run.

7. **Enumeration falls back to the inline `find` when `adapters/` is absent.**
   The live install symlinks `~/.claude/autodream/*.sh` straight at the working
   tree, so a tree mid-upgrade must degrade rather than lose a night.

8. **The suite baseline was 283, not 279 or 297.** Both earlier figures were
   measured on the wrong branch. Final count after this plan: **294**.

## Verification actually performed

- `tests/run-all.sh`: **294 passed, 0 failed** (283 baseline + 3 + 8).
- Standalone suites: `lib-project` 8/8, `preflight` 11/11, `adapters` 17/17,
  `adapter-claude` 19/19, `adapter-contract` 39/39 across two adapters.
- `shellcheck --severity=warning bin/*.sh adapters/*/*.sh` and
  `--severity=error tests/*.sh` clean.
- The newline test was confirmed genuinely red against `HEAD` before the fix:
  `got [3] want [1]`, one bad path becoming two phantom sessions.
- Real-corpus enumeration for 2026-08-21 across every configured root: 63
  sessions through the old inline `find` and 63 through the claude adapter,
  byte-identical.
