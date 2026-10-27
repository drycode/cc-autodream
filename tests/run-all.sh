#!/bin/bash
# Integration tests for cc-autodream's bin/run.sh.
#
# Drives the real run.sh end-to-end against a mock claude binary and fixture
# session files, then asserts on the output tree. No network, no model calls.
# macOS only (BSD `date`/`touch`), like the rest of the project.
#
# Usage:  tests/run-all.sh
# Exit:   0 if every assertion passes, 1 otherwise.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$REPO/bin/portable.sh"
# shellcheck source=/dev/null
. "$HERE/lib-tmp.sh"; suite_tmp runall
RUN="$REPO/bin/run.sh"
MOCK="$HERE/mock-claude.sh"
# run.sh puts ~/.local/bin on PATH, where the real shared-memory CLI lives, so a
# test whose L2 emits pins would store them in the developer's real Mnemopi.
# Point every run at a path that does not exist; the pin tests override it with
# tests/mock-shared-memory.sh.
export SHARED_MEMORY_BIN="$HERE/no-such-shared-memory"
DATE=2020-01-02          # fixed target date; sessions are touched into this day
STAMP=202001021200       # touch -t form of DATE at noon

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_file(){     [ -f "$1" ] && ok "$2" || no "$2 (missing: $1)"; }
assert_no_file(){  [ ! -e "$1" ] && ok "$2" || no "$2 (unexpected: $1)"; }
assert_nonempty(){ [ -s "$1" ] && ok "$2" || no "$2 (empty/missing: $1)"; }
assert_grep(){     grep -q "$2" "$1" 2>/dev/null && ok "$3" || no "$3 (no /$2/ in $1)"; }
assert_nogrep(){   grep -q "$2" "$1" 2>/dev/null && no "$3 (/$2/ unexpectedly in $1)" || ok "$3"; }
# Same as assert_grep but against captured stdout rather than a file, for helpers whose
# contract is what they print (citation-check writes KEY: VALUE lines to stdout so the
# caller decides where they land).
assert_grep_str(){ printf '%s\n' "$1" | grep -q "$2" 2>/dev/null && ok "$3" || no "$3 (no /$2/ in output)"; }
assert_eq(){       [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

# ---- Report citation integrity ----
# L2 cites sessions by their 12-hex findings hash. On 2026-08-18 it attached a real,
# correctly-analysed Bitwarden finding (which lives in 6f38f3cbed43) to 47eba605cf1e —
# a DIFFERENT session in the same project, and one that was noise-gated, so its findings
# record is an empty stub the aggregator never had content for. A gated stub still
# carries `project`, which is what makes the wrong hash look plausible. 10 of 11
# citations that night were sound, so this is a per-citation defect, not a broken
# report: the counters make it measurable instead of a thing a human happens to notice.
mk_report(){ # $1=path $2..=cited hashes
  local r="$1"; shift
  mkdir -p "$(dirname "$r")"
  { printf '# Autodream — fixture\n\n## Top patterns\n'
    for h in "$@"; do printf -- '- `%s` (example) did a thing\n' "$h"; done
    printf '\n<!-- autodream:open-questions=0 -->\n'
  } > "$r"
}
mk_findings(){ # $1=dir $2=hash $3=gated|real
  mkdir -p "$1"
  if [ "$3" = "gated" ]; then
    printf '{"session_path":"/x/%s.jsonl","skipped":"below_noise_gate","findings":[],"project":"-p"}\n' "$2" > "$1/$2.json"
  else
    printf '{"session_path":"/x/%s.jsonl","project":"-p","findings":[{"severity":"high","category":"x","summary":"s"}]}\n' "$2" > "$1/$2.json"
  fi
}

test_citation_check_resolves(){
  echo "# citations: every cited hash is resolved against the findings dir"
  local CC="$REPO/bin/citation-check.sh"
  [ -x "$CC" ] || { no "citation-check executable"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "  skip - jq not available"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mk_findings "$root/f" aaaaaaaaaaaa real
  mk_findings "$root/f" bbbbbbbbbbbb real
  mk_report "$root/r.md" aaaaaaaaaaaa bbbbbbbbbbbb
  local out; out=$("$CC" "$root/r.md" "$root/f") || no "citation-check exited non-zero on a clean report"
  assert_grep_str "$out" 'citations_total: 2'      "counts every cited hash"
  assert_grep_str "$out" 'citations_unresolved: 0' "no unresolved citations"
  assert_grep_str "$out" 'citations_to_gated: 0'   "no citations to gated stubs"
  rm -rf "$root"
}

test_citation_check_flags_gated_and_missing(){
  echo "# citations: a gated stub and an unknown hash are both counted, and named"
  local CC="$REPO/bin/citation-check.sh"
  [ -x "$CC" ] || { no "citation-check executable"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "  skip - jq not available"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mk_findings "$root/f" aaaaaaaaaaaa real
  mk_findings "$root/f" 47eba605cf1e gated
  # cccccccccccc has no findings record at all — a hash the aggregator invented.
  mk_report "$root/r.md" aaaaaaaaaaaa 47eba605cf1e cccccccccccc
  local out; out=$("$CC" "$root/r.md" "$root/f") || no "citation-check exited non-zero"
  assert_grep_str "$out" 'citations_total: 3'      "counts every cited hash"
  assert_grep_str "$out" 'citations_unresolved: 1' "counts the invented hash"
  assert_grep_str "$out" 'citations_to_gated: 1'   "counts the gated stub"
  # Naming them is the point: a count alone cannot be chased down next morning.
  assert_grep_str "$out" '47eba605cf1e' "names the gated citation"
  assert_grep_str "$out" 'cccccccccccc' "names the unresolved citation"
  rm -rf "$root"
}

test_citation_counters_in_run_stats(){
  echo "# citations: the counters land in run-stats.txt, after L2 has written the report"
  local root; root=$(setup_env)
  mk_session "$root" s1
  run_dream "$root"
  local rs; rs="$(fdir "$root")/run-stats.txt"
  assert_grep "$rs" 'citations_total:'      "run-stats carries the citation total"
  assert_grep "$rs" 'citations_unresolved:' "run-stats carries the unresolved count"
  assert_grep "$rs" 'citations_to_gated:'   "run-stats carries the gated count"
  rm -rf "$root"
}

test_citation_check_counts_bare_hashes(){
  echo "# citations: bare (un-backticked) hashes are citations too"
  local CC="$REPO/bin/citation-check.sh"
  [ -x "$CC" ] || { no "citation-check executable"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "  skip - jq not available"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mk_findings "$root/f" aaaaaaaaaaaa real
  mk_findings "$root/f" 47eba605cf1e gated
  # The real 2026-08-18 pre-fix report wrote them exactly like this — a parenthesised
  # comma list, no backticks. Anchoring only on backticks scored that report
  # citations_total: 0, which is a false all-clear: the one output this check exists to
  # prevent. A stray hex token is allowed to surface as unresolved; a missed citation is not.
  mkdir -p "$root"
  { printf '# Autodream — fixture\n\n'
    printf -- '- Four findings (aaaaaaaaaaaa, 47eba605cf1e, dddddddddddd) flag the same thing\n'
    printf '\n<!-- autodream:open-questions=0 -->\n'
  } > "$root/bare.md"
  local out; out=$("$CC" "$root/bare.md" "$root/f") || no "citation-check exited non-zero"
  assert_grep_str "$out" 'citations_total: 3'    "counts bare hashes"
  assert_grep_str "$out" 'citations_to_gated: 1' "classifies a bare gated citation"
  assert_grep_str "$out" 'citations_unresolved: 1' "classifies a bare unknown citation"

  # A 40-char commit SHA contains 12-hex runs but is not a citation: the neighbouring
  # characters are hex, so boundary matching must not split it.
  { printf '# Autodream — fixture\n\nSee commit 3f6b1a92c4de77081b2e5c9a0d4f8e6b71c25a93 for context\n'
    printf '\n<!-- autodream:open-questions=0 -->\n'
  } > "$root/sha.md"
  out=$("$CC" "$root/sha.md" "$root/f") || no "citation-check exited non-zero"
  assert_grep_str "$out" 'citations_total: 0' "does not mistake a long SHA for citations"
  rm -rf "$root"
}
test_citation_check_resolves_session_id_tail(){
  echo "# citations: a hash that is an omp session UUID tail resolves, not 'unresolved'"
  local CC="$REPO/bin/citation-check.sh"
  [ -x "$CC" ] || { no "citation-check executable"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "  skip - jq not available"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$root/f"
  # An OMP session filename ends in a UUID whose tail is 12 hex characters, so L2 cites
  # omp sessions by that tail instead of the findings hash — observed on 2026-08-18,
  # where `87b5b1392572` was the tail of .../2026-08-18T15-43-51-432Z_01a0158b-1488-7000-bf4a-87b5b1392572.jsonl.
  # That is a real citation to a real triaged session; reporting it as unresolved would
  # train the reader to ignore the counter.
  printf '{"session_path":"/s/2026-08-18T15-43-51-432Z_01a0158b-1488-7000-bf4a-87b5b1392572.jsonl","project":"-p","findings":[]}\n' > "$root/f/aaaaaaaaaaaa.json"
  mk_report "$root/r.md" 87b5b1392572
  local out; out=$("$CC" "$root/r.md" "$root/f") || no "citation-check exited non-zero"
  assert_grep_str "$out" 'citations_total: 1'              "counts the citation"
  assert_grep_str "$out" 'citations_unresolved: 0'         "a session-id tail is not unresolved"
  assert_grep_str "$out" 'citations_resolved_by_path: 1'   "and it is reported as resolved by session path"
  rm -rf "$root"
}

# Fresh sandbox: projects/ (session inputs) + autodream/ (prompts + state) + dreams/.
setup_env(){
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$root/projects/proj-a" "$root/autodream" "$root/dreams" "$root/cap"
  cp "$REPO/prompts/SESSION_TRIAGE.md" "$root/autodream/SESSION_TRIAGE.md"
  cp "$REPO/prompts/PROMPT.md"         "$root/autodream/PROMPT.md"
  cp "$REPO/prompts/L2_SYSTEM.txt"     "$root/autodream/L2_SYSTEM.txt"  # install.sh links it too
  printf '%s' "$root"
}
mk_session(){ # $1=root $2=name
  # Two real user turns (no timestamps -> duration_minutes 0, uncomputable and
  # so exempt from the duration gate rule) so this fixture clears the noise
  # gate's default AUTODREAM_MIN_USER_TURNS=2 floor and every existing test
  # that expects real L1 triage keeps getting it.
  local f="$1/projects/proj-a/$2.jsonl"
  printf '%s\n' \
    '{"type":"user","cwd":"/tmp/proj-a","message":{"content":"start the task"}}' \
    '{"type":"user","message":{"content":"keep going"}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}' \
    > "$f"
  touch -t "$STAMP" "$f"
}
mk_trivial_session(){ # $1=root $2=name — single user turn, no tool calls: below the noise gate
  local f="$1/projects/proj-a/$2.jsonl"
  printf '{"type":"user","message":{"content":"quick question"}}\n' > "$f"
  touch -t "$STAMP" "$f"
}
mk_short_duration_session(){ # $1=root $2=name — 2 user turns, 5s apart: gates on duration alone
  local f="$1/projects/proj-a/$2.jsonl"
  printf '%s\n' \
    '{"type":"user","timestamp":"2020-01-02T12:00:00Z","message":{"content":"quick check"}}' \
    '{"type":"user","timestamp":"2020-01-02T12:00:05Z","message":{"content":"thanks bye"}}' \
    > "$f"
  touch -t "$STAMP" "$f"
}
mk_subagent_session(){ # $1=root $2=name — isSidechain + >=5 tool calls: carve-out, never gated
  local f="$1/projects/proj-a/$2.jsonl"
  printf '%s\n' \
    '{"type":"user","isSidechain":true,"timestamp":"2020-01-02T12:00:00Z","message":{"content":"subagent task"}}' \
    '{"type":"assistant","isSidechain":true,"timestamp":"2020-01-02T12:00:05Z","message":{"content":[{"type":"tool_use","name":"Read"},{"type":"tool_use","name":"Write"},{"type":"tool_use","name":"Bash"},{"type":"tool_use","name":"Grep"},{"type":"tool_use","name":"Edit"}]}}' \
    > "$f"
  touch -t "$STAMP" "$f"
}
mk_timed_session(){ # $1=root $2=name $3.. = ISO8601 timestamps, one user turn each (#14 overlap fixtures)
  local root="$1" name="$2"; shift 2
  local f="$root/projects/proj-a/$name.jsonl" ts
  : > "$f"
  for ts in "$@"; do
    printf '{"type":"user","timestamp":"%s","message":{"content":"turn"}}\n' "$ts" >> "$f"
  done
  touch -t "$STAMP" "$f"
}
hash_of(){ printf '%s' "$1" | shasum -a 1 | cut -c1-12; }
run_dream(){ # $1=root ; inherits MOCK_MODE/MOCK_CAPTURE_DIR/FANOUT + changelog knobs from env
  # Changelog check defaults OFF so the suite never touches the network; the dedicated
  # changelog test exports AUTODREAM_CHANGELOG=1 with a local CHANGELOG_REMOTE.
  # Retry/network knobs forced fast+offline so the suite never sleeps or hits the net.
  # AUTODREAM_CONFIG is pinned into the sandbox so the HOST's own
  # ~/.claude/autodream/config can never leak in. run.sh started sourcing that file so
  # AUTODREAM_VAULT_DIR could reach the nightly run; without this pin a developer whose
  # config points at a real Obsidian vault would have the suite writing into it.
  # Individual tests override this by exporting AUTODREAM_CONFIG before calling.
  # The worker failure path probes the network with a real curl, so every test with a failing
  # worker would make real outbound calls at 5s apiece. Default every run to a curl that
  # reports a reachable host; the tests that care about an outage set TEST_CURL_SHIMMED=1 and
  # put their own shim on PATH first.
  if [ -z "${TEST_CURL_SHIMMED:-}" ]; then
    mkdir -p "$1/shim-default"
    printf '#!/bin/bash\nprintf %s "200"\n' "'%s'" > "$1/shim-default/curl"
    chmod +x "$1/shim-default/curl"
    PATH="$1/shim-default:$PATH"
  fi
  AUTODREAM_CHANGELOG="${AUTODREAM_CHANGELOG:-0}" CLAUDE_BIN="$MOCK" \
  AUTODREAM_CONFIG="${AUTODREAM_CONFIG:-$1/autodream/config}" \
  AUTODREAM_CONSUME_DATE="${AUTODREAM_CONSUME_DATE:-$DATE}" \
  AUTODREAM_NETCHECK="${AUTODREAM_NETCHECK:-0}" AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS="${AUTODREAM_L1_ROUNDS:-2}" \
  PROJECTS_DIR="$1/projects" AUTODREAM_DIR="$1/autodream" DREAMS_DIR="$1/dreams" \
  /bin/bash "$RUN" "$DATE" > "$1/run.out" 2>&1
  # The run's own exit code, captured while $? still holds it: an unattended run has no other
  # signal for "delivered nothing", so the exit code is part of the contract.
  printf '%s' "$?" > "$1/run.exit"
  # An unattended run logs to its file rather than through a pipe, so that stdout carries
  # only a pointer now. Fold the real log in, so every assertion below still reads what a
  # nightly run actually recorded rather than what a tty run happens to echo.
  cat "$1/autodream/logs/run-$DATE.log" >> "$1/run.out" 2>/dev/null || true
}
# Same run, but piped into a reader that closes immediately, so any write run.sh makes to
# stdout lands on a dead pipe. This is the shape of the real 2026-08-02 failure.
run_dream_broken_pipe(){ # $1=root
  AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
  AUTODREAM_CONFIG="$1/autodream/config" \
  AUTODREAM_CONSUME_DATE="$DATE" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$1/projects" AUTODREAM_DIR="$1/autodream" DREAMS_DIR="$1/dreams" \
  /bin/bash "$RUN" "$DATE" 2>&1 | true
  cat "$1/autodream/logs/run-$DATE.log" > "$1/run.out" 2>/dev/null || true
}
fdir(){ printf '%s' "$1/autodream/findings/$DATE"; }   # findings dir for a root

# ---------------------------------------------------------------------------

# ---- Operator notes: notes.md + vault inbox merged into operator-notes.md ----------
# The seam under test is that PROMPT.md reads exactly ONE file. Every assertion here is
# about that file's contents and about what leaves the inbox, because the two ways this
# feature fails silently are (a) a surface not reaching the model and (b) a note being
# archived before it was read.

mk_vault_note(){ # $1=root $2=name $3=body [$4=expires]
  local d="$1/vault/inbox"; mkdir -p "$d"
  {
    if [ -n "${4:-}" ]; then printf -- '---\nexpires: %s\n---\n' "$4"; fi
    printf '%s\n' "$3"
  } > "$d/$2.md"
}
vault_run(){ # $1=root — a run with the vault surface enabled
  AUTODREAM_VAULT_DIR="$1/vault" run_dream "$1"
}

test_notes_no_surfaces(){
  echo "# operator notes: no notes.md and no vault -> the file still exists, saying so"
  local root; root=$(setup_env); mk_session "$root" s1
  run_dream "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_file "$f" "operator-notes.md is written even with nothing to report"
  assert_grep "$f" "active: 0" "header reports zero active notes"
  assert_grep "$f" "No active operator notes" "body says there are no notes"
  rm -rf "$root"
}

test_notes_from_notes_file(){
  echo "# operator notes: notes.md lines reach the merged file verbatim"
  local root; root=$(setup_env); mk_session "$root" s1
  printf -- '- [2020-01-01] check whether /graphify is used\n' > "$root/autodream/notes.md"
  run_dream "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "check whether /graphify is used" "the note text is present"
  assert_grep "$f" "active: 1" "the line note is counted active"
  rm -rf "$root"
}

test_notes_from_vault_inbox(){
  echo "# operator notes: a vault inbox file becomes a note block"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" idea-from-phone "look at how often the retry budget fires"
  vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "note: idea-from-phone" "the inbox file is titled by its filename"
  assert_grep "$f" "how often the retry budget fires" "the inbox note body is present"
  assert_grep "$f" "active: 1" "the inbox note is counted active"
  assert_nogrep "$f" "^expires:" "frontmatter is stripped from the body"
  rm -rf "$root"
}

test_notes_vault_expired_dropped(){
  echo "# operator notes: an expired vault note is dropped from the merged file but still archived"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" stale "this stopped mattering" 2020-01-01
  vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_nogrep "$f" "this stopped mattering" "expired note body is not shown to the model"
  assert_grep "$f" "expired-and-dropped: 1" "the expired note is counted in the header"
  assert_no_file "$root/vault/inbox/stale.md" "an expired note still leaves the inbox"
  rm -rf "$root"
}

test_notes_vault_archived_after_report(){
  echo "# operator notes: a consumed vault note moves to processed/<date>/"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" done-with-this "some note"
  vault_run "$root"
  assert_no_file "$root/vault/inbox/done-with-this.md" "the note left the inbox"
  assert_file "$root/vault/processed/$DATE/done-with-this.md" "the note landed in processed/<date>/"
  rm -rf "$root"
}

test_notes_vault_not_archived_without_report(){
  echo "# operator notes: a failed L2 (no report) leaves the note in the inbox"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" keep-me "must survive a failed run"
  # l2_fail makes the aggregator write nothing; the archive step is gated on a
  # non-empty report precisely so an unread note is never thrown away.
  export MOCK_MODE=l2_fail AUTODREAM_L2_ATTEMPTS=1
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_L2_ATTEMPTS
  assert_file "$root/vault/inbox/keep-me.md" "the note stayed in the inbox after a failed run"
  assert_no_file "$root/vault/processed/$DATE/keep-me.md" "the note was not archived"
  rm -rf "$root"
}

test_notes_vault_report_published(){
  echo "# operator notes: the report is copied into the vault for phone reading"
  local root; root=$(setup_env); mk_session "$root" s1
  vault_run "$root"
  assert_nonempty "$root/vault/reports/$DATE.md" "the report was published into the vault"
  rm -rf "$root"
}

test_notes_vault_unreadable_note_stays(){
  echo "# operator notes: an empty (unsynced) note is reported, not silently skipped"
  local root; root=$(setup_env); mk_session "$root" s1
  mkdir -p "$root/vault/inbox"; : > "$root/vault/inbox/not-synced.md"
  AUTODREAM_ICLOUD_WAIT=0 vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "unreadable: 1" "the unreadable note is counted"
  assert_grep "$f" "not-synced.md — UNREADABLE" "the unreadable note is named for the model"
  assert_file "$root/vault/inbox/not-synced.md" "an unread note is left in the inbox to retry"
  rm -rf "$root"
}

# ---- Config file: run.sh sources it, but the environment still wins ----------------
# run.sh ignored ~/.claude/autodream/config until AUTODREAM_VAULT_DIR needed to reach the
# nightly run. The env-wins half is the part worth pinning: the config uses plain
# KEY=value, so a naive `.` would let the file override a caller who deliberately
# exported something.

test_config_file_sourced(){
  echo "# config: AUTODREAM_VAULT_DIR set only in the config file reaches the run"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" from-config "config-sourced vault"
  printf 'AUTODREAM_VAULT_DIR=%s/vault\n' "$root" > "$root/autodream/config"
  run_dream "$root"
  assert_grep "$(fdir "$root")/operator-notes.md" "config-sourced vault" "the config-only vault path was used"
  rm -rf "$root"
}

test_config_env_wins_over_config(){
  echo "# config: an exported AUTODREAM_VAULT_DIR beats the config file's value"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" real "the env-chosen vault"
  mkdir -p "$root/decoy/inbox"
  printf 'the config-chosen vault\n' > "$root/decoy/inbox/decoy.md"
  printf 'AUTODREAM_VAULT_DIR=%s/decoy\n' "$root" > "$root/autodream/config"
  vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep   "$f" "the env-chosen vault"    "the environment's vault was read"
  assert_nogrep "$f" "the config-chosen vault" "the config's vault was overridden"
  rm -rf "$root"
}

# ---- Regressions from the PR #37 review -------------------------------------------
# Every one of these had a reproducer in the review and no test. They are grouped here
# rather than merged into the tests above because each pins a specific way the feature
# lost the user's input silently.

test_notes_header_only_file_does_not_abort(){
  echo "# regression: a notes.md with no '- [' lines must not abort collect"
  local root; root=$(setup_env); mk_session "$root" s1
  # Exactly what autodream-note.sh leaves once the user deletes the notes a report told
  # them were addressed. `grep -c` prints 0 AND exits 1, so a `|| echo 0` fallback made
  # the count "0\n0" and the arithmetic killed the whole collect under set -e.
  printf '# Operator notes for autodream\n\nFree-text notes.\n\n' > "$root/autodream/notes.md"
  mk_vault_note "$root" survives "this note must still reach the model"
  vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_file "$f" "operator-notes.md was still written"
  assert_grep "$f" "active: 1" "the vault note was still counted"
  assert_grep "$f" "this note must still reach the model" "the vault note still reached the model"
  rm -rf "$root"
}

test_notes_icloud_placeholder_is_counted(){
  echo "# regression: an iCloud placeholder is a missed note, not a clean zero"
  local root; root=$(setup_env); mk_session "$root" s1
  # An evicted note is NOT a zero-byte .md — the real file is gone and only the
  # dot-prefixed placeholder remains, so the '*.md' walk matched nothing at all.
  mkdir -p "$root/vault/inbox"; : > "$root/vault/inbox/.from-phone.md.icloud"
  AUTODREAM_ICLOUD_WAIT=0 vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "unreadable: 1" "the evicted note is counted, not reported as zero"
  assert_grep "$f" "from-phone.md — UNREADABLE" "it is named so the user knows what was missed"
  assert_file "$root/vault/inbox/.from-phone.md.icloud" "the placeholder stays for the next run"
  rm -rf "$root"
}

test_notes_placeholder_and_real_file_counted_once(){
  echo "# regression: a materialised note with a leftover placeholder is not double-counted"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" both "the real content"
  : > "$root/vault/inbox/.both.md.icloud"
  AUTODREAM_ICLOUD_WAIT=0 vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "active: 1" "counted as one active note"
  assert_grep "$f" "unreadable: 0" "not also counted as unreadable"
  rm -rf "$root"
}

test_notes_expiry_uses_report_date(){
  echo "# regression: expiry is judged against the reported date, not today"
  local root; root=$(setup_env); mk_session "$root" s1
  # Expires long after the date being reported on ($DATE) but long before today, so a
  # wall-clock comparison drops and archives a note that was active for this window.
  mk_vault_note "$root" still-active "active during the reported window" 2020-06-01
  vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "active during the reported window" "the note is still shown to the model"
  assert_grep "$f" "expired-and-dropped: 0" "it is not counted as expired"
  rm -rf "$root"
}

# ---- Focus tags: turns marked with the focus button in mods/autodream-focus ------------------
# tags.jsonl has one writer (the mod) and tags-consumed.txt has one (vault-notes.sh), so a
# tag is pending until a report has read it. The ways this fails silently are a tag that
# never reaches L2, one consumed before any report was written, one lost to a torn line
# in the file, and one swallowed because jq is missing.

focus_at(){ # $1=local day $2=local time — the UTC taggedAt the mod would write for that LOCAL moment
  TZ=UTC pdate_fmt_epoch "$(pdate_epoch "$1 $2:00")" +%Y-%m-%dT%H:%M:%S.000Z
}
mk_focus_tag(){ # $1=root $2=session $3=row $4=local day $5=text [$6=local time, default 12:00] — one line, as the mod writes it
  # The mod writes only a UTC timestamp, so the fixture states the LOCAL moment it stands for.
  jq -cn --arg s "$2" --arg r "$3" --arg a "$(focus_at "$4" "${6:-12:00}")" --arg t "$5" \
    '{id:($s+":"+$r),session:$s,uuid:$r,role:"assistant",text:$t,cwd:"/tmp/proj-a",taggedAt:$a}' \
    >> "$1/autodream/tags.jsonl"
}
focus_collect(){ # $1=root $2=date — vault-notes.sh straight, with no run around it
  mkdir -p "$1/autodream/findings/$2"
  AUTODREAM_DIR="$1/autodream" AUTODREAM_CONFIG=/nonexistent PROJECTS_DIR="$1/projects" \
    /bin/bash "$REPO/bin/vault-notes.sh" collect "$1/autodream/findings/$2" >/dev/null
}

test_focus_tag_reaches_the_report_and_is_consumed(){
  echo "# focus tags: a tag made on the reported day reaches L2 and is consumed after the report"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_focus_tag "$root" s1 row-1 "$DATE" $'first line\nsecond line'
  local before; before=$(shasum "$root/autodream/tags.jsonl")
  run_dream "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "note: focus-s1-row-1" "the tag is a note block of its own"
  assert_grep "$f" "tagged: 1" "the header counts it"
  assert_grep "$f" "^> second line" "the turn is quoted line by line"
  assert_grep "$f" "Transcript: $root/projects/proj-a/s1.jsonl" "L2 is told where the session's transcript is"
  assert_grep "$root/autodream/tags-consumed.txt" "^s1:row-1	$DATE	$(focus_at "$DATE" 12:00)\$" "the ledger records the id, the report date and the tag's own time"
  assert_eq "$(shasum "$root/autodream/tags.jsonl")" "$before" "tags.jsonl is the mod's file and was not touched"
  rm -rf "$root"
}

test_focus_tag_is_held_for_its_day(){
  echo "# focus tags: a tag made after the reported day waits for that day's report"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_focus_tag "$root" s1 later 2020-01-03 "made the day after"
  run_dream "$root"
  assert_nogrep "$(fdir "$root")/operator-notes.md" "made the day after" "a later day's tag is not in this report"
  assert_no_file "$root/autodream/tags-consumed.txt" "and it is not consumed"
  rm -rf "$root"
}

test_focus_tag_day_is_the_local_day(){
  echo "# focus tags: the day a tag belongs to is the local day, not the UTC day"
  local root; root=$(setup_env); mk_session "$root" s1
  # 23:30 in New York on DATE is 04:30Z the next day. Judged by its UTC date it would wait a
  # night, and evening is exactly when the day is being reviewed.
  export TZ=America/New_York
  mk_focus_tag "$root" s1 evening "$DATE" "made at half past eleven" 23:30
  mk_focus_tag "$root" s1 after 2020-01-03 "made just after midnight" 00:30
  focus_collect "$root" "$DATE"
  unset TZ
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "made at half past eleven" "an evening tag belongs to the day it was made"
  assert_nogrep "$f" "made just after midnight" "one made after local midnight belongs to the next"
  assert_grep "$f" "^- \[$DATE\]" "the note is dated by the local day"
  rm -rf "$root"
}

test_focus_tag_not_consumed_without_report(){
  echo "# focus tags: a failed L2 leaves the tag pending"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_focus_tag "$root" s1 row-1 "$DATE" "must survive a failed run"
  export MOCK_MODE=l2_fail AUTODREAM_L2_ATTEMPTS=1
  run_dream "$root"
  unset MOCK_MODE AUTODREAM_L2_ATTEMPTS
  assert_grep "$(fdir "$root")/operator-notes.md" "must survive a failed run" "L2 was offered the tag"
  assert_no_file "$root/autodream/tags-consumed.txt" "nothing was recorded as read"
  rm -rf "$root"
}

test_focus_tag_pending_set(){
  echo "# focus tags: torn lines and consumed ids are skipped, the rest are kept"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_focus_tag "$root" s1 old "$DATE" "already read"
  printf '{"id":"torn\n' >> "$root/autodream/tags.jsonl"
  mk_focus_tag "$root" s1 fresh "$DATE" "still owed"
  printf 's1:old\t2019-12-31\t%s\n' "$(focus_at "$DATE" 12:00)" > "$root/autodream/tags-consumed.txt"
  focus_collect "$root" "$DATE"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "still owed" "the pending tag is read"
  assert_nogrep "$f" "already read" "a consumed tag is not offered again"
  assert_grep "$f" "tagged: 1" "only the pending one is counted"
  assert_eq "$(cat "$(fdir "$root")/vault-tags-manifest.txt")" "s1:fresh	$(focus_at "$DATE" 12:00)" "the manifest holds exactly what was read"
  rm -rf "$root"
}

test_focus_tag_retag_after_consume_is_offered_again(){
  echo "# focus tags: a consumed tag that is untagged and tagged again is a new tag"
  local root; root=$(setup_env); mk_session "$root" s1
  # The ledger has the first tag of this row (made 11:00, read by an earlier report). The user
  # untagged it and tagged the same turn again at 12:00: same id, new taggedAt.
  printf 's1:row-1\t2019-12-31\t%s\n' "$(focus_at "$DATE" 11:00)" > "$root/autodream/tags-consumed.txt"
  mk_focus_tag "$root" s1 row-1 "$DATE" "tagged a second time"
  focus_collect "$root" "$DATE"
  assert_grep "$(fdir "$root")/operator-notes.md" "tagged a second time" "the second tag is offered"
  rm -rf "$root"
}

test_focus_tag_forced_rebuild_keeps_its_tags(){
  echo "# focus tags: rebuilding a report date re-offers the tags that report consumed"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_focus_tag "$root" s1 row-1 "$DATE" "read by the report being rebuilt"
  printf 's1:row-1\t%s\t%s\n' "$DATE" "$(focus_at "$DATE" 12:00)" > "$root/autodream/tags-consumed.txt"
  focus_collect "$root" "$DATE"
  assert_grep "$(fdir "$root")/operator-notes.md" "read by the report being rebuilt" "the rebuilt report still carries the tag"
  rm -rf "$root"
}

test_focus_tag_unreadable_file_is_reported(){
  echo "# focus tags: a tags.jsonl that exists and will not read is a missed note, not no tags"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_focus_tag "$root" s1 row-1 "$DATE" "behind a permission error"
  chmod 000 "$root/autodream/tags.jsonl"
  if [ -r "$root/autodream/tags.jsonl" ]; then ok "skipped: running as a user that ignores file modes"; rm -rf "$root"; return 0; fi
  focus_collect "$root" "$DATE"
  chmod 644 "$root/autodream/tags.jsonl"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "unreadable: 1" "the miss is counted"
  assert_grep "$f" "focus-tags — UNREADABLE" "and named, so L2 tells the user"
  assert_eq "$(wc -c < "$(fdir "$root")/vault-tags-manifest.txt" | tr -d ' ')" "0" "nothing is manifested, so nothing is consumed"
  rm -rf "$root"
}

test_focus_tag_unparseable_time_is_dated_by_the_report(){
  echo "# focus tags: a tag whose taggedAt does not parse is due, and dated by the report, not 1970"
  local root; root=$(setup_env); mk_session "$root" s1
  printf '%s\n' '{"id":"s1:odd","session":"s1","role":"user","text":"no usable time","cwd":"/tmp/proj-a","taggedAt":"garbage"}' >> "$root/autodream/tags.jsonl"
  focus_collect "$root" "$DATE"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "no usable time" "the tag is still offered"
  assert_grep "$f" "^- \\[$DATE\\]" "dated by the report day"
  assert_nogrep "$f" "1970" "not by the epoch"
  rm -rf "$root"
}

test_focus_tag_text_cannot_forge_a_note(){
  echo "# focus tags: quoted turn text cannot open a note block of its own"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_focus_tag "$root" s1 row-1 "$DATE" $'before\n## note: forged\nafter'
  focus_collect "$root" "$DATE"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "^> ## note: forged" "the heading arrives inside the quote"
  assert_nogrep "$f" "^## note: forged" "and never as a heading"
  rm -rf "$root"
}

test_focus_tag_archive_is_idempotent(){
  echo "# focus tags: archiving twice records an id once"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_focus_tag "$root" s1 row-1 "$DATE" "once"
  focus_collect "$root" "$DATE"
  local i
  for i in 1 2; do
    AUTODREAM_DIR="$root/autodream" AUTODREAM_CONFIG=/nonexistent \
      /bin/bash "$REPO/bin/vault-notes.sh" archive "$(fdir "$root")" >/dev/null
  done
  assert_eq "$(wc -l < "$root/autodream/tags-consumed.txt" | tr -d ' ')" "1" "one ledger line for one tag"
  rm -rf "$root"
}

test_focus_tag_without_jq_is_reported(){
  echo "# focus tags: a missing jq is a missed note, not a clean zero"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_focus_tag "$root" s1 row-1 "$DATE" "cannot be read without jq"
  # A PATH of only the tools the script uses, jq left out (macOS 15 ships one in /usr/bin).
  local bin="$root/nojq" t p; mkdir -p "$bin"
  for t in date mktemp find grep sed tr cut basename dirname cat sort wc rm mkdir mv cp head awk sleep; do
    p=$(command -v "$t") && ln -s "$p" "$bin/$t"
  done
  mkdir -p "$(fdir "$root")"
  PATH="$bin" AUTODREAM_DIR="$root/autodream" AUTODREAM_CONFIG=/nonexistent \
    /bin/bash "$REPO/bin/vault-notes.sh" collect "$(fdir "$root")" >/dev/null
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "unreadable: 1" "the miss is counted"
  assert_grep "$f" "focus-tags — UNREADABLE" "and named, so L2 tells the user"
  assert_nogrep "$f" "cannot be read without jq" "the turn text is not pretended to have been read"
  assert_eq "$(wc -c < "$(fdir "$root")/vault-tags-manifest.txt" | tr -d ' ')" "0" "nothing is manifested, so nothing is consumed"
  rm -rf "$root"
}

test_force_rebuild_failed_l2_does_not_consume(){
  echo "# regression: a stale report must not satisfy the consume gate under --force"
  local root; root=$(setup_env); mk_session "$root" s1
  vault_run "$root"                                    # first run succeeds, leaves a report
  mk_vault_note "$root" written-later "must survive the failed rebuild"
  # Rebuild with an L2 that writes nothing. The old report is still on disk, and it used
  # to satisfy both the retry loop's break and the consume gate, so this note was
  # archived having been read by nothing.
  export MOCK_MODE=l2_fail AUTODREAM_FORCE=1 AUTODREAM_L2_ATTEMPTS=1
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_FORCE AUTODREAM_L2_ATTEMPTS
  assert_file "$root/vault/inbox/written-later.md" "the note stayed in the inbox"
  assert_no_file "$root/vault/processed/$DATE/written-later.md" "the note was not archived"
  ls "$root/dreams/$DATE.md.stale-"* >/dev/null 2>&1 \
    && ok "the previous report was preserved, not destroyed" \
    || no "the previous report was not preserved"
  rm -rf "$root"
}

test_unmovable_stale_report_disarms_consuming(){
  echo "# regression: if the stale report cannot be moved aside, nothing may be consumed"
  local root; root=$(setup_env); mk_session "$root" s1
  vault_run "$root"                                    # first run leaves a report
  mk_vault_note "$root" must-survive "the mv failed, so this must not be archived"
  # Make the move fail the way it would in practice: the destination directory is not
  # writable, so the old report stays at $REPORT_PATH. Without the disarm this is the
  # original hole reopened — the retry loop and the consume gate both see the old file.
  chmod 555 "$root/dreams"
  export MOCK_MODE=l2_fail AUTODREAM_FORCE=1 AUTODREAM_L2_ATTEMPTS=1
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_FORCE AUTODREAM_L2_ATTEMPTS
  chmod 755 "$root/dreams"
  assert_file "$root/vault/inbox/must-survive.md" "the note stayed in the inbox"
  assert_no_file "$root/vault/processed/$DATE/must-survive.md" "the note was not archived"
  assert_grep "$root/run.out" "will NOT archive notes" "the run says why consuming was disarmed"
  rm -rf "$root"
}

test_partial_report_does_not_consume(){
  echo "# regression: a truncated report must not satisfy the retry break or the consume gate"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" survives-truncation "a half-written report must not consume this"
  # l2_partial writes a non-empty report with no open-questions marker — what a mid-write
  # kill leaves. `-s` alone cannot tell it from a good report.
  export MOCK_MODE=l2_partial AUTODREAM_L2_ATTEMPTS=2
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_L2_ATTEMPTS
  assert_file "$root/vault/inbox/survives-truncation.md" "the note stayed in the inbox"
  assert_no_file "$root/vault/processed/$DATE/survives-truncation.md" "the note was not archived"
  assert_grep "$root/run.out" "no open-questions marker" "the run names the reason"
  # It must also have RETRIED rather than accepting the partial file on attempt 1.
  assert_grep "$root/run.out" "L2 aggregation attempt 2" "a truncated report triggers a retry"
  rm -rf "$root"
}

test_partial_report_does_not_block_retry(){
  echo "# regression: a truncated report must not satisfy the idempotency guard forever"
  local root; root=$(setup_env); mk_session "$root" s1
  # Every attempt dies mid-write. Without the move-aside, the next launchd catch-up
  # trigger sees a non-empty file, says "nothing to do", and the half-written report
  # becomes the permanent output for the date.
  export MOCK_MODE=l2_partial AUTODREAM_L2_ATTEMPTS=1
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_L2_ATTEMPTS
  assert_no_file "$root/dreams/$DATE.md" "the truncated report was moved off the report path"
  ls "$root/dreams/$DATE.md.partial-"* >/dev/null 2>&1 \
    && ok "it was preserved as .partial-<epoch>, not deleted" \
    || no "the partial report was lost"
  # The next trigger must actually re-run rather than no-op on the leftover.
  vault_run "$root"
  assert_nonempty "$root/dreams/$DATE.md" "a later trigger produced a real report"
  assert_grep "$root/dreams/$DATE.md" "autodream:open-questions=" "and it is a complete one"
  rm -rf "$root"
}

test_unassembled_dates_are_surfaced(){
  echo "# a date triaged but never assembled must be named, not left for someone to find"
  local root; root=$(setup_env); mk_session "$root" s1
  local prior="$root/autodream/findings/2020-01-01"
  mkdir -p "$prior"
  printf '{"findings":[]}\n' > "$prior/abc123def456.json"
  printf '{"transcript_bytes":10}\n' > "$prior/abc123def456.stats.json"
  # A second dir holding only a sidecar: never triaged, so nothing to assemble.
  mkdir -p "$root/autodream/findings/2020-01-03"
  printf '{"transcript_bytes":10}\n' > "$root/autodream/findings/2020-01-03/dead.stats.json"
  run_dream "$root"
  assert_grep "$root/run.out" "findings but no complete report: 2020-01-01" "the log names the abandoned date"
  assert_grep "$(fdir "$root")/run-stats.txt" "unassembled_dates: 2020-01-01" "and the stat carries it into the next report"
  assert_nogrep "$(fdir "$root")/run-stats.txt" "2020-01-03" "a sidecar-only dir was never triaged and is not a failure"
  rm -rf "$root"
}

test_unassembled_ignores_a_finished_date(){
  echo "# a date with a complete report is not an abandoned one"
  local root; root=$(setup_env); mk_session "$root" s1
  local prior="$root/autodream/findings/2020-01-01"
  mkdir -p "$prior" "$root/dreams"
  printf '{"findings":[]}\n' > "$prior/abc123def456.json"
  printf '# report\n\nautodream:open-questions=0\n' > "$root/dreams/2020-01-01.md"
  run_dream "$root"
  assert_grep "$(fdir "$root")/run-stats.txt" "unassembled_dates: *$" "the finished date is not listed"
  # A truncated report is not a finished one, and must come back onto the list. The epoch
  # is pinned to this fixture's date so the marker is REQUIRED here: that is the contract
  # under test, and leaving it at the default would exempt every 2020 fixture date.
  printf '# report with no marker\n' > "$root/dreams/2020-01-01.md"
  rm -f "$root/dreams/$DATE.md"
  AUTODREAM_MARKER_EPOCH=2020-01-01 run_dream "$root"
  assert_grep "$(fdir "$root")/run-stats.txt" "unassembled_dates: 2020-01-01" "but a marker-less one is"
  rm -rf "$root"
}

test_pre_marker_report_is_not_abandoned(){
  echo "# a report written before the marker contract is complete, not abandoned"
  local root; root=$(setup_env); mk_session "$root" s1
  local prior="$root/autodream/findings/2020-01-01"
  mkdir -p "$prior" "$root/dreams"
  printf '{"findings":[]}\n' > "$prior/abc123def456.json"
  # Real report, real content, no marker - exactly the six reports sitting in
  # ~/.claude/dreams on this host, which the check called abandoned every single night.
  printf '# Autodream - 2020-01-01\n\nreal content\n\n## Open questions\nNone.\n' > "$root/dreams/2020-01-01.md"
  AUTODREAM_MARKER_EPOCH=2020-06-01 run_dream "$root"
  assert_grep "$(fdir "$root")/run-stats.txt" "unassembled_dates: *$" "a pre-epoch report is not called abandoned"
  assert_nogrep "$root/run.out" "findings but no complete report" "and no warning is logged for it"
  assert_grep "$(fdir "$root")/run-stats.txt" "legacy_marker_reports: 2020-01-01" \
    "it is counted separately, so the exemption is visible rather than silent"
  rm -rf "$root"
}

test_missing_report_still_abandoned_before_epoch(){
  echo "# the exemption is for unmarked reports only, never for a missing one"
  local root; root=$(setup_env); mk_session "$root" s1
  local prior="$root/autodream/findings/2020-01-01"
  mkdir -p "$prior" "$root/dreams"
  printf '{"findings":[]}\n' > "$prior/abc123def456.json"
  # No report at all, and an epoch that would exempt an unmarked one. Findings with no
  # report is the real failure the scan exists to catch; the epoch must not swallow it.
  AUTODREAM_MARKER_EPOCH=2020-06-01 run_dream "$root"
  assert_grep "$(fdir "$root")/run-stats.txt" "unassembled_dates: 2020-01-01" \
    "a date with findings and no report is still abandoned"
  rm -rf "$root"
}

test_dead_stdout_does_not_kill_the_run(){
  echo "# regression: losing the log reader must cost the run its output, not its life"
  local root; root=$(setup_env); mk_session "$root" s1
  # Three runs died this way on 2026-08-02: tee was killed, the next log line SIGPIPEd the
  # run, and everything after L2 — the retry loop, the move-aside, the consume gate — was
  # never reached. No error line said so, because saying so was the thing that died.
  run_dream_broken_pipe "$root"
  assert_grep "$root/dreams/$DATE.md" "autodream:open-questions=" "the run finished and wrote a complete report"
  assert_grep "$root/run.out" "autodream end" "and its log reached the end on disk"
  rm -rf "$root"
}

test_complete_report_retires_partials(){
  echo "# a complete report supersedes the partials left by the nights that failed"
  local root; root=$(setup_env); mk_session "$root" s1
  # Two failed nights, so the second run has to retire a partial it did not itself create.
  export MOCK_MODE=l2_partial AUTODREAM_L2_ATTEMPTS=1
  vault_run "$root"
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_L2_ATTEMPTS
  ls "$root/dreams/$DATE.md.partial-"* >/dev/null 2>&1 \
    && ok "the failed nights left partials behind" \
    || no "setup failed: no partial report to retire"
  vault_run "$root"                                   # the night that finally works
  assert_grep "$root/dreams/$DATE.md" "autodream:open-questions=" "a complete report landed"
  ls "$root/dreams/$DATE.md.partial-"* >/dev/null 2>&1 \
    && no "partials survived the complete report that supersedes them" \
    || ok "every partial for the date was discarded"
  rm -rf "$root"
}

test_no_sessions_stub_carries_marker(){
  echo "# the no-sessions stub is a complete report and must carry the marker"
  local root; root=$(setup_env)     # no sessions at all
  run_dream "$root"
  assert_grep "$root/dreams/$DATE.md" "autodream:open-questions=" "the stub carries the marker"
  rm -rf "$root"
}

test_partial_report_keeps_previous(){
  echo "# regression: a truncated rebuild must not discard the previous good report"
  local root; root=$(setup_env); mk_session "$root" s1
  vault_run "$root"                                   # a good report lands
  export MOCK_MODE=l2_partial AUTODREAM_FORCE=1 AUTODREAM_L2_ATTEMPTS=1
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_FORCE AUTODREAM_L2_ATTEMPTS
  ls "$root/dreams/$DATE.md.stale-"* >/dev/null 2>&1 \
    && ok "the previous good report was kept" \
    || no "the previous good report was discarded for a truncated one"
  rm -rf "$root"
}

test_old_date_reprocess_does_not_consume(){
  echo "# regression: reprocessing an old date must not consume today's pending input"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" todays-note "written this morning"
  # TARGET_DATE is not the date a normal nightly run would process.
  AUTODREAM_CONSUME_DATE=2099-01-01 vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "written this morning" "the note is still collected as context for L2"
  assert_file "$root/vault/inbox/todays-note.md" "but it is NOT archived out of the inbox"
  assert_nonempty "$root/vault/reports/$DATE.md" "publishing still happens (it consumes nothing)"
  rm -rf "$root"
}

test_config_unbound_var_does_not_kill_run(){
  echo "# regression: a typo'd variable in the config must warn, not kill the run"
  local root; root=$(setup_env); mk_session "$root" s1
  # AUTODREAM_HOME does not exist; under `set -u` this used to abort bash outright,
  # before the log file or log() existed, so the night produced nothing and said nothing.
  printf 'X_CREDS_FILE=$AUTODREAM_HOME/x-credentials\nAUTODREAM_VAULT_DIR=%s/vault\n' "$root" > "$root/autodream/config"
  mk_vault_note "$root" survives-typo "the run must still happen"
  run_dream "$root"
  assert_nonempty "$root/dreams/$DATE.md" "the run still produced a report"
  assert_grep "$root/run.out" "unbound variable" "the bad config key is named in a warning"
  assert_grep "$(fdir "$root")/operator-notes.md" "the run must still happen" \
    "keys after the bad line still took effect"
  rm -rf "$root"
}

test_session_stats(){
  echo "# deterministic session stats pre-pass acceptance fixtures"
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  local fixture out

  fixture="$root/carriers.jsonl"; out="$root/carriers.stats.json"
  printf '%s\n' \
    '{"type":"user","message":{"role":"user","content":"human question"}}' \
    '{"type":"assistant","message":{"model":"claude-haiku","content":[{"type":"tool_use","name":"Read"}]}}' \
    '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"a","content":"result"}]}}' \
    'not json' \
    '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b","content":"result"}]}}' > "$fixture"
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -r 'keys | sort | join(",")' "$out")" \
    "compliance_markers,duration_minutes,isSidechain,models_used,skills_authored,skills_invoked,skills_invoked_count,skills_invoked_counts,tool_call_count,tools_used,transcript_bytes,transcript_mtime,turn_count,user_message_count,user_turn_timestamps" \
    "stats output has exactly the specified fields"
  assert_eq "$(jq -r '.user_turn_timestamps | length' "$out")" "0" "no timestamped user turns in this fixture -> empty user_turn_timestamps"
  assert_eq "$(jq -r .user_message_count "$out")" "1" "tool_result carriers are excluded from user message count"
  assert_eq "$(jq -r .turn_count "$out")" "4" "turn count includes tool_result carriers"

  fixture="$root/timestamps.jsonl"; out="$root/timestamps.stats.json"
  printf '%s\n' \
    '{"type":"user","timestamp":"2026-07-20T10:00:00.500Z","message":{"content":"start"}}' \
    '{"type":"system","message":{"content":"no timestamp needed"}}' \
    '{"type":"assistant","message":{"model":"claude-opus","content":"middle"}}' \
    '{"type":"progress","timestamp":"2026-07-20T10:01:00.250Z"}' \
    '{"type":"assistant","timestamp":"2026-07-20T10:02:30.750Z","message":{"model":"<synthetic>","content":"end"}}' > "$fixture"
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -r .duration_minutes "$out")" "2.5" "duration uses available fractional timestamps"
  assert_eq "$(jq -r .models_used[0] "$out")" "claude-opus" "synthetic model is dropped"
  assert_eq "$(jq -r '.user_turn_timestamps | join(",")' "$out")" "1784541600" "user_turn_timestamps holds only the (fractional-second-truncated) real user turn's epoch"

  fixture="$root/markers.jsonl"; out="$root/markers.stats.json"
  printf '%s\n' \
    '{"type":"user","message":{"content":"user pasted RETRY-BUDGET: not a marker"}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","content":"payload RETRY-BUDGET: not a marker"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"RETRY-BUDGET: real"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"DELEGATED: scout — find X\nthe report said DELEGATED: quoted mid-line\n```\nDELEGATED: fenced example\nDIRECT-OK: fenced example\n```\nDIRECT-OK: tiny-edit — one-line fix"}]}}' \
    '{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"DELEGATED: harvester — sidechain worker line"}]}}' > "$fixture"
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -r '.compliance_markers["RETRY-BUDGET"]' "$out")" "1" "only assistant text counts RETRY-BUDGET"
  assert_eq "$(jq -r '.compliance_markers["DELEGATED"]' "$out")" "1" "DELEGATED counts line-start only (mid-line, fenced, sidechain excluded)"
  assert_eq "$(jq -r '.compliance_markers["DIRECT-OK"]' "$out")" "1" "DIRECT-OK counts line-start only (fenced excluded)"
  assert_eq "$(jq -r '.compliance_markers | keys | sort | join(",")' "$out")" \
    "DELEGATED,DIRECT-OK,FETCH-PIVOT,RETRY-BUDGET" "compliance_markers carries all four keys"

  fixture="$root/text-image.jsonl"; out="$root/text-image.stats.json"
  printf '%s\n' \
    '{"type":"user","message":{"content":[{"type":"text","text":"caption"},{"type":"image","source":{"type":"base64","data":"abc"}}]}}' > "$fixture"
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -r .user_message_count "$out")" "1" "text plus image human turn counts"

  fixture="$root/sidechain.jsonl"; out="$root/sidechain.stats.json"
  printf '%s\n' \
    '{"type":"user","isSidechain":true,"message":{"content":"subagent task"}}' \
    '{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku","content":[{"type":"tool_use","name":"Write"},{"type":"tool_use","name":"Bash"},{"type":"tool_use","name":"Read"}]}}' \
    '{"type":"user","isSidechain":true,"message":{"content":[{"type":"tool_result","content":"one"}]}}' \
    '{"type":"user","isSidechain":true,"message":{"content":[{"type":"tool_result","content":"two"}]}}' \
    '{"type":"user","isSidechain":true,"message":{"content":[{"type":"tool_result","content":"three"}]}}' > "$fixture"
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -r .user_message_count "$out")" "1" "sidechain has one human message"
  assert_eq "$(jq -r .turn_count "$out")" "5" "sidechain turn count includes carriers"
  assert_eq "$(jq -r .tool_call_count "$out")" "3" "sidechain tool calls are counted mechanically"
  assert_eq "$(jq -r '.tools_used | join(",")' "$out")" "Bash,Read,Write" "sidechain tools are sorted and unique"
  assert_eq "$(jq -r .isSidechain "$out")" "true" "sidechain marker is copied"
  rm -rf "$root"
}

test_happy(){
  echo "# happy path"
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_file    "$(fdir "$root")/$h.json"     "L1 wrote findings JSON"
  assert_file    "$(fdir "$root")/$h.stats.json" "mechanical stats sidecar written"
  assert_eq      "$(jq -r .tool_call_count "$(fdir "$root")/$h.stats.json")" "1" "sidecar has plausible tool_call_count"
  assert_no_file "$(fdir "$root")/$h.json.err" "no .err on success"
  assert_file    "$root/dreams/$DATE.md"       "L2 wrote the report"
  rm -rf "$root"
}

test_unreadable(){
  echo "# unreadable session (validated before dispatch)"
  local root; root=$(setup_env); mk_session "$root" sess1
  chmod 000 "$root/projects/proj-a/sess1.jsonl"
  run_dream "$root"
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_file    "$(fdir "$root")/$h.json"     "unreadable -> structured error JSON written"
  assert_grep    "$(fdir "$root")/$h.json"     'not readable at dispatch' "error JSON states the reason"
  assert_no_file "$(fdir "$root")/$h.json.err" "no .err (structured record instead of a loop)"
  chmod 644 "$root/projects/proj-a/sess1.jsonl"; rm -rf "$root"
}

test_incomplete(){
  echo "# incomplete worker run (no JSON written)"
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=l1_incomplete; run_dream "$root"; unset MOCK_MODE
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # After the 2026-06-11 self-audit fix: on the FINAL retry round, a worker
  # that produced no output gets a metadata-only stub so the session is
  # visible to L1_ERRORED and the L2 aggregator instead of becoming a silent
  # .err. Earlier rounds still left the slot absent so retries could fire.
  assert_file     "$(fdir "$root")/$h.json"     "final-round stub written (no longer a silent failure)"
  assert_grep     "$(fdir "$root")/$h.json"     'worker exited without findings JSON' "stub carries the failure reason"
  # Whitespace-tolerant: the project-field normalization pass rewrites this stub via
  # json.dump (it has a real session_path + no project), reformatting "findings":[] →
  # "findings": []. The assertion is about the empty array, not its exact spacing.
  assert_grep     "$(fdir "$root")/$h.json"     '"findings": *\[\]'                   "stub has an empty findings array (counted by L1_ERRORED via the error key)"
  assert_nonempty "$(fdir "$root")/$h.json.err" ".err is still non-empty (per-round diagnostics)"
  assert_grep     "$(fdir "$root")/$h.json.err" 'incomplete run' ".err carries a diagnostic"
  assert_file     "$root/dreams/$DATE.md"       "L2 still produced the report"
  rm -rf "$root"
}

test_self_audit_stats(){
  echo "# run-stats.txt self-audit telemetry is written"
  local root; root=$(setup_env); mk_session "$root" real1
  local sf="$root/projects/proj-a/selfworker.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"SESSION_PATH=/x/y.jsonl"}}\n{"type":"assistant"}\n' > "$sf"
  touch -t "$STAMP" "$sf"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_file  "$stats" "run-stats.txt written"
  assert_grep  "$stats" 'self_sessions_excluded: 1' "stats record the excluded self-session"
  assert_grep  "$stats" 'sessions_triaged: 1'        "stats record the triaged count"
  assert_grep  "$stats" 'l1_findings_with_error: 0'  "stats record the in-band error count"
  # 2026-06-11 self-audit fix: vs.-raw denominator + cache-disambiguating fields.
  assert_grep  "$stats" 'sessions_dropped_after_failures: 0'   "no dropped sessions on a clean happy-path run"
  assert_grep  "$stats" 'l1_sessions_already_done_at_start: 0' "no precached findings on a fresh run"
  assert_grep  "$stats" 'l1_sessions_freshly_processed: 1'     "the one session was freshly processed this run"
  # #38: the key is always emitted, even with no bookmark credentials anywhere near the
  # sandbox, so a consumer never has to tell "absent" from "the walk did not run".
  assert_grep  "$stats" 'x_queryid_source: not_attempted'      "the queryId source is recorded even when the walk never ran"
  rm -rf "$root"
}

test_self_audit_stats_failure_denominator(){
  echo "# self-audit stats: dropped-after-failures is nonzero when a worker dies"
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=l1_incomplete; run_dream "$root"; unset MOCK_MODE
  local stats="$(fdir "$root")/run-stats.txt"
  assert_file  "$stats" "run-stats.txt written"
  # After the fix, even a stubbed final-round failure is counted: the stub
  # carries an "error" key so it lands in l1_findings_with_error, AND the
  # vs.-raw denominator stays accurate. Reporting zero would hide a session that
  # never produced real findings.
  assert_grep  "$stats" 'l1_findings_with_error: 1' "stats surface the failed session via the error key"
  rm -rf "$root"
}

test_self_audit_stats_precached_disambiguation(){
  echo "# self-audit stats: precached findings counted so fast elapsed isn't 'impossible'"
  local root; root=$(setup_env); mk_session "$root" sess1
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # Pre-seed a valid findings JSON so dispatcher's idempotency skips the worker.
  mkdir -p "$(fdir "$root")"; printf '{"session_path":"CACHED","findings":[]}' > "$(fdir "$root")/$h.json"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep  "$stats" 'l1_sessions_already_done_at_start: 1' "precached session counted as already done"
  assert_grep  "$stats" 'l1_sessions_freshly_processed: 0'     "no fresh work this run"
  rm -rf "$root"
}

test_idempotent(){
  echo "# idempotent (pre-existing VALID findings JSON is not re-run)"
  local root; root=$(setup_env); mk_session "$root" sess1
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # A valid findings record (has a top-level findings key) marks a completed
  # triage; the run must leave it untouched. Sentinel lives in session_path.
  mkdir -p "$(fdir "$root")"
  printf '{"session_path":"SENTINEL","findings":[]}' > "$(fdir "$root")/$h.json"
  run_dream "$root"
  assert_eq "$(jq -r .session_path "$(fdir "$root")/$h.json")" "SENTINEL" "valid findings JSON left untouched"
  rm -rf "$root"
}

test_revalidates_garbage(){
  echo "# a non-empty but malformed findings JSON is re-dispatched, not counted as done"
  local root; root=$(setup_env); mk_session "$root" sess1
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # Old contract treated any non-empty file as done; new contract re-runs a
  # record that lacks a valid top-level findings key (a worker that emitted
  # garbage). The mock worker overwrites it with a well-formed record.
  mkdir -p "$(fdir "$root")"; printf 'GARBAGE{not json' > "$(fdir "$root")/$h.json"
  run_dream "$root"
  assert_eq "$(jq -e 'has("findings")' "$(fdir "$root")/$h.json" 2>/dev/null)" "true" "garbage findings JSON re-dispatched and replaced"
  rm -rf "$root"
}

test_no_sessions(){
  echo "# no sessions for the date"
  local root; root=$(setup_env)   # no mk_session
  run_dream "$root"
  assert_file "$root/dreams/$DATE.md" "stub report written"
  assert_grep "$root/dreams/$DATE.md" 'No sessions were triaged' "stub report has the no-sessions notice"
  # The stub is harness-neutral now, and it distinguishes "nothing was there"
  # from "everything was refused" — a night where every path was unrepresentable
  # used to read identically to a quiet one.
  assert_grep "$root/dreams/$DATE.md" 'No session files were modified' "a genuinely empty night says so"
  assert_file "$(fdir "$root")/run-stats.txt" "run-stats is written even with zero sessions"
  rm -rf "$root"
}

# ---- L2 runs on the CLI default model unless deliberately pinned ------------
# This was pinned to claude-opus-4-7 by a date cutoff whose other branch had been
# unreachable since 2026-06-21, so the nightly quietly aggregated on a model two
# generations old and nothing said so. The assertion that matters is the ABSENCE
# of the flag: a comment claiming "no --model" is not a check, and the mock
# records the real argv.
test_l2_uses_the_default_model(){
  echo "# L2: no --model is passed unless AUTODREAM_L2_MODEL is set"
  local root; root=$(setup_env); mk_session "$root" sess1
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap"; run_dream "$root"; unset FANOUT MOCK_CAPTURE_DIR
  local cap="$root/cap/l2-args.txt"
  assert_file "$cap" "captured the L2 argv"
  if grep -qx -- '--model' "$cap"; then
    no "no --model flag is passed by default (found one)"
  else
    ok "no --model flag is passed by default"
  fi
  # The call still has to be well-formed, or "no --model" would be satisfied by a
  # run that never reached claude at all.
  assert_grep "$cap" '^[-][-]print$' "and the L2 call is otherwise intact"
  assert_nonempty "$root/dreams/$DATE.md" "and the report still lands"
  rm -rf "$root"
}

test_l2_model_pin_is_honoured(){
  echo "# L2: AUTODREAM_L2_MODEL still pins a model when set"
  local root; root=$(setup_env); mk_session "$root" sess1
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap" AUTODREAM_L2_MODEL="claude-test-model"
  run_dream "$root"
  unset FANOUT MOCK_CAPTURE_DIR AUTODREAM_L2_MODEL
  local cap="$root/cap/l2-args.txt"
  assert_grep "$cap" '^[-][-]model$' "the pin puts --model back"
  assert_grep "$cap" '^claude-test-model$' "with the requested value"
  # The run-stats key exists because the CLI falls back SILENTLY on an
  # unrecognised model, so the artifact has to say what was asked for.
  assert_grep "$root/autodream/findings/$DATE/run-stats.txt" '^l2_model: claude-test-model' \
    "and run-stats records the pin"
  rm -rf "$root"
}

test_framing(){
  echo "# prompt framing regression (literal paths, no \$VAR, blank separator)"
  local root; root=$(setup_env); mk_session "$root" sess1
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap"; run_dream "$root"; unset FANOUT MOCK_CAPTURE_DIR
  local cap="$root/cap/l1-stdin.txt"
  assert_file "$cap" "captured the L1 prompt"
  local l1 l2 l3 l4
  l1=$(sed -n '1p' "$cap"); l2=$(sed -n '2p' "$cap"); l3=$(sed -n '3p' "$cap"); l4=$(sed -n '4p' "$cap")
  case "$l1" in "Session transcript to analyze (literal absolute path): /"*) ok "line 1 = literal session path" ;; *) no "line 1 framing (got [$l1])" ;; esac
  case "$l2" in "Write your findings JSON to this literal absolute path: /"*) ok "line 2 = literal output path" ;; *) no "line 2 framing (got [$l2])" ;; esac
  assert_eq "$l3" "" "line 3 = blank separator (doc not glued onto the path)"
  case "$l4" in "# Session Triage"*) ok "line 4 = SESSION_TRIAGE.md begins" ;; *) no "line 4 doc start (got [$l4])" ;; esac
  local doc_line stats_line
  doc_line=$(grep -n '^## Output schema' "$cap" | head -n 1 | cut -d: -f1)
  stats_line=$(grep -n '^## Precomputed session stats' "$cap" | head -n 1 | cut -d: -f1)
  [ -n "$doc_line" ] && [ -n "$stats_line" ] && [ "$stats_line" -gt "$doc_line" ] \
    && ok "precomputed stats block follows the full SESSION_TRIAGE.md body" \
    || no "precomputed stats block follows the full SESSION_TRIAGE.md body"
  assert_grep "$cap" '"tool_call_count": 1' "captured L1 prompt contains the sidecar JSON"
  if printf '%s\n%s\n' "$l1" "$l2" | grep -qE 'SESSION_PATH=|OUTPUT_PATH=|[$]SESSION_PATH|[$]OUTPUT_PATH'; then
    no "no legacy KEY=value / \$VAR framing in the inlined header"
  else
    ok "no legacy KEY=value / \$VAR framing in the inlined header"
  fi
  assert_grep "$root/cap/l1-args.txt" 'not shell variables' "system prompt forbids shell-variable treatment"
  rm -rf "$root"
}

test_l1_engine_comes_from_the_adapter(){
  echo "# the L1 worker is started from the adapter's l1-argv, with the adapter's model and environment"
  local root; root=$(setup_env); mk_session "$root" sess1
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap"; run_dream "$root"; unset FANOUT MOCK_CAPTURE_DIR
  local args="$root/cap/l1-args.txt"
  assert_file "$args" "captured the L1 argv"
  assert_eq "$(sed -n '/^--model$/{n;p;}' "$args")" "claude-haiku-5-5" "the manifest's default model is used"
  assert_grep "$args" '^--no-session-persistence$' "the adapter's flags are present"
  assert_grep "$root/cap/l1-env.txt" '^CLAUDE_CODE_DISABLE_CLAUDE_MDS=1$' "the adapter's l1-env reaches the worker"
  rm -rf "$root"

  root=$(setup_env); mk_session "$root" sess1
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap" AUTODREAM_L1_MODEL=generic/override; run_dream "$root"
  unset FANOUT MOCK_CAPTURE_DIR AUTODREAM_L1_MODEL
  assert_eq "$(sed -n '/^--model$/{n;p;}' "$root/cap/l1-args.txt")" "generic/override" "AUTODREAM_L1_MODEL overrides the default"
  rm -rf "$root"

  root=$(setup_env); mk_session "$root" sess1
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap" AUTODREAM_L1_MODEL=generic/override AUTODREAM_L1_MODEL_CLAUDE=per/adapter; run_dream "$root"
  unset FANOUT MOCK_CAPTURE_DIR AUTODREAM_L1_MODEL AUTODREAM_L1_MODEL_CLAUDE
  assert_eq "$(sed -n '/^--model$/{n;p;}' "$root/cap/l1-args.txt")" "per/adapter" "the per-adapter override beats the generic one"
  rm -rf "$root"
}

test_l1_engine_cannot_be_redirected_by_a_worker(){
  echo "# a worker that rewrites sessions-source.txt cannot change which engine the next worker runs"
  local root; root=$(setup_env); mk_session "$root" sess1; mk_session "$root" sess2
  local h1 h2
  h1=$(hash_of "$root/projects/proj-a/sess1.jsonl"); h2=$(hash_of "$root/projects/proj-a/sess2.jsonl")
  export FANOUT=1 MOCK_MODE=l1_rewrite_source; run_dream "$root"; unset FANOUT MOCK_MODE
  local fd; fd=$(fdir "$root")
  assert_grep "$fd/sessions-source.txt" '	evil$' "precondition: the hostile worker really did rewrite the file"
  assert_nogrep "$fd/$h1.json" '"error"' "the first session was triaged"
  assert_nogrep "$fd/$h2.json" '"error"' "the second session still ran on the real engine, not the rewritten one"
  rm -rf "$root"
}

test_l1_session_with_no_resolvable_engine_is_an_error_record(){
  echo "# a session whose adapter yields no model gets a structured error, and the run still reports"
  local root; root=$(setup_env); mk_session "$root" sess1
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # A claude adapter with no l1_model anywhere: no manifest default, no override.
  local ad="$root/adapters"; cp -R "$REPO/adapters" "$ad"
  jq 'del(.l1_model)' "$ad/claude/manifest.json" > "$ad/claude/manifest.json.new" && mv "$ad/claude/manifest.json.new" "$ad/claude/manifest.json"
  export ADAPTERS_ROOT="$ad"; run_dream "$root"; unset ADAPTERS_ROOT
  local fd; fd=$(fdir "$root")
  assert_grep "$fd/$h.json" 'no L1 engine for this session' "the session carries a deterministic error record"
  assert_grep "$fd/run-stats.txt" 'l1_findings_with_error: 1' "and it is counted"
  assert_file "$root/dreams/$DATE.md" "the run still produced a report"
  rm -rf "$root"
}

test_worker_failure_records_exit_code_and_stdout(){
  echo "# a failed worker's .err carries its exit code and its stdout, not just 'Working...'"
  local root; root=$(setup_env); mk_session "$root" sess1
  local shim; shim=$(shim_curl "$root" 200)   # network is fine; the worker is not
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  export MOCK_MODE=l1_noisy_fail
  TEST_CURL_SHIMMED=1   PATH="$shim:$PATH" AUTODREAM_L1_ROUNDS=1 run_dream "$root"
  unset MOCK_MODE
  local err="$(fdir "$root")/$h.json.err"
  assert_grep    "$err" 'worker exit code: 7'          ".err records the worker's exit code"
  assert_grep    "$err" 'rate_limit_exceeded'          ".err carries the stdout that explains the failure"
  assert_nogrep  "$err" 'no route to api'              "a reachable host is not reported as an outage"
  assert_no_file "$(fdir "$root")/$h.json.out"         "the stdout capture is cleaned up"
  rm -rf "$root"
}

test_malformed_worker_output_is_a_failure_with_its_evidence(){
  echo "# non-empty output that is not findings JSON must fail loudly, keeping the diagnostics"
  local root; root=$(setup_env); mk_session "$root" sess1
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  export MOCK_MODE=l1_malformed
  AUTODREAM_L1_ROUNDS=1 run_dream "$root"
  unset MOCK_MODE
  assert_file    "$(fdir "$root")/$h.json.err" "the .err survives instead of being deleted as a success"
  assert_grep    "$(fdir "$root")/$h.json.err" 'no usable .findings key' ".err says why the output was rejected"
  assert_grep    "$(fdir "$root")/$h.json.err" 'this is not json at all' ".err keeps what the worker actually wrote"
  assert_nogrep  "$(fdir "$root")/$h.json" 'this is not json at all' "the malformed file never reaches L2"
  rm -rf "$root"
}

test_findings_must_be_an_array_not_merely_present(){
  echo "# .findings that is a string or object is not a result, and must not reach L2"
  local root; root=$(setup_env); mk_session "$root" sess1
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  export MOCK_MODE=l1_wrongtype
  AUTODREAM_L1_ROUNDS=1 run_dream "$root"
  unset MOCK_MODE
  assert_file   "$(fdir "$root")/$h.json.err" "the schema-invalid write is treated as a failure"
  assert_grep   "$(fdir "$root")/$h.json.err" 'no usable .findings key' ".err says why it was rejected"
  assert_nogrep "$(fdir "$root")/$h.json" 'oops' "the schema-invalid file never reaches L2"
  rm -rf "$root"
}

test_stale_wrongtype_findings_is_redispatched(){
  echo "# a stale schema-invalid findings file from a prior run must be re-run, not skipped"
  local root; root=$(setup_env); mk_session "$root" sess1
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # Seed the exact shape a previous run could have left: .findings present but a string.
  # The dispatcher guard said "done" and exited, while l1_missing_count said "missing",
  # so nothing ever rewrote it and L2 aggregated it anyway. Three sites answer this
  # question and all three must agree.
  mkdir -p "$(fdir "$root")"
  printf '{"session_path":"STALE","findings":"oops"}' > "$(fdir "$root")/$h.json"
  run_dream "$root"
  assert_nogrep "$(fdir "$root")/$h.json" 'oops'  "the stale invalid file was replaced, not skipped"
  assert_eq "$(jq -r '.findings | type' "$(fdir "$root")/$h.json")" "array" "the rewritten file has a real findings array"
  rm -rf "$root"
}

test_failure_class_found_through_an_old_install(){
  echo "# an install made before failure-class.sh existed still finds it through the runner symlink (Codex review of b19ec84)"
  local root; root=$(setup_env); mk_session "$root" sess1
  # install.sh links each script by name, so an install from before this PR has every
  # link except failure-class.sh. Updating the checkout must not break its nightly.
  local f; for f in "$REPO"/bin/*.sh; do
    case "$f" in */failure-class.sh) continue ;; esac
    ln -sf "$f" "$root/autodream/$(basename "$f")"
  done
  AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
  AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
  /bin/bash "$root/autodream/run.sh" "$DATE" > "$root/run.out" 2>&1
  assert_nogrep "$root/run.out" 'required failure classifier not found' "run.sh finds the classifier next to the file its link points at"
  assert_file "$root/dreams/$DATE.md" "and the run still produces a report"
  local gate_out; gate_out=$(AUTODREAM_DIR="$root/autodream" bash "$root/autodream/oversized-gate.sh" "$(fdir "$root")" 2>&1)
  printf '%s' "$gate_out" > "$root/gate.out"
  assert_nogrep "$root/gate.out" 'required failure classifier not found' "oversized-gate.sh finds it the same way"
  rm -rf "$root"
}

test_failure_class_provider_matrix(){
  echo "# failure-class.sh: every 5xx and auth-error wording is provider, not size"
  local dir; dir=$(mktemp -d)
  # shellcheck source=../bin/failure-class.sh
  . "$REPO/bin/failure-class.sh"
  local n=0 line want got
  while IFS='|' read -r want line; do
    n=$((n + 1))
    printf 'worker exit code: 1 after 9s\n--- worker stdout, last 40 lines ---\n%s\n' "$line" > "$dir/$n.err"
    got=$(classify_failure "$dir/$n.err")
    assert_eq "$got" "$want" "[$line] is $want"
  done <<'EOF'
provider|error: HTTP 520 from upstream
provider|503 Service Unavailable
provider|auth error: token expired
provider|Authentication failed for provider deepseek
provider|401 Unauthorized
provider|provider overload, retry later
provider|HTTP 5xx from upstream
provider|rate-limited by provider
provider|Too Many Requests
provider|error: invalid-api-key
provider|unauthorised
provider|status 500 from provider
provider|HTTP/1.1 502 Bad Gateway
size|context-length exceeded
size|context length exceeded (HTTP 500)
size|HTTP 500 prompt-too-long
size|HTTP 500 token-limit exceeded
size|HTTP 500 context-limit exceeded
size|HTTP 500 context_window exceeded
size|HTTP 500 maximum tokens exceeded
provider|HTTP status code was 500
provider|upstream returned 5xx
provider|authorization failed
provider|authorisation error
size|HTTP 500 maximum input length exceeded
size|HTTP 500 input too long
size|read 5200 bytes then exited
size|read 520 bytes then exited
size|worker timed out after 600s
EOF

  # A refusal the worker printed only on stderr is its own output too. omp's stderr lands
  # at the top of the .err, before the exit-code line (Codex review of b19ec84).
  printf '401 Unauthorized\nworker exit code: 1 after 9s\n--- worker stdout, last 40 lines ---\ndone\n' > "$dir/stderr.err"
  assert_eq "$(classify_failure "$dir/stderr.err")" "provider" "a refusal on the worker's stderr is provider"
  # The exit-code line itself is ours, not the worker's: its seconds must not read as a 5xx.
  printf 'worker exit code: 1 after 503s\n--- worker stdout, last 40 lines ---\ndone\n' > "$dir/elapsed.err"
  assert_eq "$(classify_failure "$dir/elapsed.err")" "size" "the elapsed seconds on the exit-code line are not a status code"
  # A worker's own "--- " separator is not one of run.sh's section markers; what follows it
  # is still the worker's stdout (Codex review of 7eda1a8).
  printf 'worker exit code: 1 after 9s\n--- worker stdout, last 40 lines ---\n--- retrying ---\n401 Unauthorized\n' > "$dir/separator.err"
  assert_eq "$(classify_failure "$dir/separator.err")" "provider" "a worker-printed --- line does not end its stdout section"
  # Lines run.sh itself writes are not the worker's output. The session path sits before the
  # exit-code line, so a path with "quota" or "error-500" in it must not make a failure
  # provider (Codex review of 7eda1a8).
  printf 'Working...\nworker produced no findings JSON for /tmp/quota-budget/error-500.jsonl (incomplete run: omp exited without writing output)\nworker exit code: 1 after 9s\n--- worker stdout, last 40 lines ---\ndone\n' > "$dir/path.err"
  assert_eq "$(classify_failure "$dir/path.err")" "size" "a session path run.sh records is not read as a provider refusal"
  # The malformed-output branch dumps up to 2000 bytes of the worker's findings JSON, often
  # with no trailing newline, so the session line lands on the same line as the dump.
  printf 'worker wrote output with no usable .findings key; treating as a failure\n{"note":"HTTP 500 quota"}worker produced no findings JSON for /tmp/s.jsonl (incomplete run: omp exited without writing output)\nworker exit code: 1 after 9s\n--- worker stdout, last 40 lines ---\ndone\n' > "$dir/dump.err"
  assert_eq "$(classify_failure "$dir/dump.err")" "size" "the dumped findings JSON is not read as a provider refusal"
  # run.sh's own network note can follow the stdout section directly when no omp log was touched.
  printf 'worker exit code: 1 after 9s\n--- worker stdout, last 40 lines ---\ndone\nno route to api.anthropic.com when this worker failed (curl http_code=503)\n' > "$dir/netnote.err"
  assert_eq "$(classify_failure "$dir/netnote.err")" "size" "run.sh's network note after the stdout section is not worker output"
  rm -rf "$dir"
}

test_oversized_gate_context_overflow(){
  echo "# oversized gate (#12 measurement): a context overflow counts as size, not provider"
  local root; root=$(setup_env); mk_session "$root" sess1
  export AUTODREAM_SLIM_BYTES=100 MOCK_MODE=l1_context_overflow AUTODREAM_L1_ROUNDS=1
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES MOCK_MODE AUTODREAM_L1_ROUNDS
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'oversized_errored: 1' "the context overflow is still an oversized error"
  assert_grep "$stats" 'oversized_errored_provider: 0' "a size signature overrides the provider wording"
  assert_grep "$stats" 'oversized_errored_unclassified: 0' "the captured context overflow is classified"
  assert_grep "$stats" 'l1_errored_provider: 0' "the all-session classifier does not call it provider"
  assert_grep "$stats" 'l1_errored_unclassified: 0' "the all-session classifier recognizes it as size"
  rm -rf "$root"
}

test_oversized_gate_errored_noisy(){
  echo "# oversized gate (#12 measurement): a provider refusal is excluded from the size share"
  local root; root=$(setup_env); mk_session "$root" sess1
  export AUTODREAM_SLIM_BYTES=100 MOCK_MODE=l1_noisy_fail AUTODREAM_L1_ROUNDS=1
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES MOCK_MODE AUTODREAM_L1_ROUNDS
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'oversized_errored: 1'        "the noisy failure is still an oversized error"
  assert_grep "$stats" 'oversized_errored_provider: 1' "the 429 is classified as an oversized provider failure"
  assert_grep "$stats" 'l1_errored_provider: 1'        "the all-session classifier also counts the provider failure"
  rm -rf "$root"
}

test_oversized_gate_errored_silent(){
  echo "# oversized gate (#12 measurement): an exit-0, empty-stdout worker death is counted as silent"
  local root; root=$(setup_env); mk_session "$root" sess1
  export AUTODREAM_SLIM_BYTES=100 MOCK_MODE=l1_silent AUTODREAM_L1_ROUNDS=1
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES MOCK_MODE AUTODREAM_L1_ROUNDS
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'oversized_errored: 1'        "the silent death still leaves an error stub"
  assert_grep "$stats" 'oversized_errored_silent: 1' "and is counted as silent, apart from size failures"
  assert_grep "$stats" 'l1_errored_silent: 1'         "the all-session classifier also counts the silent death"
  rm -rf "$root"
}

test_oversized_gate_script_context_overflow(){
  echo "# oversized-gate.sh: a context overflow opens the size gate"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  export AUTODREAM_SLIM_BYTES=100 MOCK_MODE=l1_context_overflow AUTODREAM_L1_ROUNDS=1
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES MOCK_MODE AUTODREAM_L1_ROUNDS
  local out; out=$(AUTODREAM_SLIM_BYTES=100 bash "$GATE" "$(fdir "$root")" 2>&1)
  printf '%s' "$out" > "$root/gate.out"
  assert_grep "$root/gate.out" 'GATE OPEN' "one context overflow in one measured session opens the gate"
  assert_grep "$root/gate.out" 'Size-attributable: 1 errored of 1' "the context overflow remains in the size numerator"
  rm -rf "$root"
}

test_oversized_gate_script_err_without_exit_code(){
  echo "# oversized-gate.sh: an .err from before exit-code capture is unclassified"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  export AUTODREAM_SLIM_BYTES=100 MOCK_MODE=l1_noisy_fail AUTODREAM_L1_ROUNDS=1
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES MOCK_MODE AUTODREAM_L1_ROUNDS
  local fd; fd=$(fdir "$root")
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  grep -v '^worker exit code:' "$fd/$h.json.err" > "$fd/$h.json.err.tmp" && mv "$fd/$h.json.err.tmp" "$fd/$h.json.err"
  local out; out=$(AUTODREAM_SLIM_BYTES=100 bash "$GATE" "$fd" 2>&1)
  printf '%s' "$out" > "$root/gate.out"
  assert_grep "$root/gate.out" '1 unclassified' "an .err without an exit-code line is unclassified"
  assert_nogrep "$root/gate.out" 'GATE OPEN' "the legacy .err does not open the gate"
  assert_nogrep "$root/gate.out" 'GATE CLOSED' "the legacy .err does not close the gate"
  rm -rf "$root"
}

test_oversized_gate_script_missing_err(){
  echo "# oversized-gate.sh: an error stub whose .err is gone is unclassified and excluded"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  local fd; fd=$(fdir "$root")
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  mkdir -p "$fd"
  printf '{"session_path":"%s","error":"legacy failure","findings":[]}\n' \
    "$root/projects/proj-a/sess1.jsonl" > "$fd/$h.json"
  export AUTODREAM_SLIM_BYTES=100
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES
  assert_grep "$fd/run-stats.txt" 'oversized_errored_unclassified: 1' "run.sh classifies a missing .err as unclassified"
  assert_grep "$fd/run-stats.txt" 'l1_errored_unclassified: 1' "the all-session classifier also counts the legacy stub"
  local out; out=$(AUTODREAM_SLIM_BYTES=100 bash "$GATE" "$fd" 2>&1)
  printf '%s' "$out" > "$root/gate.out"
  assert_grep   "$root/gate.out" '1 unclassified' "the missing .err is reported as unclassified"
  assert_grep   "$root/gate.out" 'measured nothing about size' "a legacy-only window has no size evidence"
  assert_nogrep "$root/gate.out" 'GATE OPEN' "an unclassified failure does not open the gate"
  assert_nogrep "$root/gate.out" 'GATE CLOSED' "an unclassified failure does not close the gate"
  rm -rf "$root"
}

test_oversized_gate_script_mixed_size_and_provider(){
  echo "# oversized-gate.sh: one size failure plus one provider failure measures 1 of 1"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  local size_root provider_root
  size_root=$(setup_env); mk_session "$size_root" size1
  provider_root=$(setup_env); mk_session "$provider_root" provider1
  export AUTODREAM_SLIM_BYTES=100 MOCK_MODE=l1_context_overflow AUTODREAM_L1_ROUNDS=1
  run_dream "$size_root"
  export MOCK_MODE=l1_noisy_fail
  run_dream "$provider_root"
  unset AUTODREAM_SLIM_BYTES MOCK_MODE AUTODREAM_L1_ROUNDS
  local out; out=$(AUTODREAM_SLIM_BYTES=100 bash "$GATE" "$(fdir "$size_root")" "$(fdir "$provider_root")" 2>&1)
  printf '%s' "$out" > "$size_root/gate.out"
  assert_grep "$size_root/gate.out" 'Size-attributable: 1 errored of 1' "the provider failure leaves both sides of the share"
  assert_grep "$size_root/gate.out" 'GATE OPEN' "the remaining 1-of-1 size share opens the gate"
  rm -rf "$size_root" "$provider_root"
}

test_oversized_gate_script_silent(){
  echo "# oversized-gate.sh: a window whose only failures are silent worker deaths measures nothing about size"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  export AUTODREAM_SLIM_BYTES=100 MOCK_MODE=l1_silent AUTODREAM_L1_ROUNDS=1
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES MOCK_MODE AUTODREAM_L1_ROUNDS
  local out; out=$(AUTODREAM_SLIM_BYTES=100 bash "$GATE" "$(fdir "$root")" 2>&1)
  printf '%s' "$out" > "$root/gate.out"
  assert_grep   "$root/gate.out" '1 silent'                     "the silent death is reported, not hidden"
  assert_grep   "$root/gate.out" 'measured nothing about size'   "an all-silent window has nothing to judge size by"
  assert_nogrep "$root/gate.out" 'GATE OPEN'                     "and must not open the gate"
  assert_nogrep "$root/gate.out" 'GATE CLOSED'                   "or close it"
  rm -rf "$root"
}

test_oversized_gate_script_stdout_section_boundary(){
  echo "# oversized-gate.sh: provider text in the appended omp log cannot override a size diagnosis"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  export AUTODREAM_SLIM_BYTES=100 MOCK_MODE=l1_context_overflow AUTODREAM_L1_ROUNDS=1
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES MOCK_MODE AUTODREAM_L1_ROUNDS
  local fd; fd=$(fdir "$root")
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  printf '%s\n' '--- an omp log touched during this round, may belong to a sibling worker: fixture ---' \
    'provider error: 429 rate_limit_exceeded' >> "$fd/$h.json.err"
  local out; out=$(AUTODREAM_SLIM_BYTES=100 bash "$GATE" "$fd" 2>&1)
  printf '%s' "$out" > "$root/gate.out"
  assert_grep "$root/gate.out" 'GATE OPEN' "the stdout context signature keeps the failure in the size share"
  assert_grep "$root/gate.out" '0 provider' "the sibling omp-log 429 is outside the classification section"
  rm -rf "$root"
}

test_oversized_gate_script_unmeasurable_only(){
  echo "# oversized-gate.sh: a date whose sessions could not be sized is not a measured window (Codex review of cdfdf3b)"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  local root; root=$(mktemp -d)
  # A listed transcript that no longer exists and no sidecar: nothing can size it.
  local d="$root/2020-01-05"; mkdir -p "$d"
  printf '%s\n' "$root/gone/sess1.jsonl" > "$d/sessions.txt"
  local out; out=$(AUTODREAM_SLIM_BYTES=100 bash "$GATE" "$d" 2>&1)
  printf '%s' "$out" > "$root/gate.out"
  assert_nogrep "$root/gate.out" 'No oversized transcripts' "zero sized sessions is not a result about size"
  assert_grep   "$root/gate.out" 'No date in this window could be measured' "it says no date was measurable"
  rm -rf "$root"
}

test_a_nested_error_key_is_not_a_failed_triage(){
  echo "# only a top-level error key marks a failed triage, not any text that contains one"
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=l1_nested_error AUTODREAM_SLIM_BYTES=10; run_dream "$root"; unset MOCK_MODE AUTODREAM_SLIM_BYTES
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'l1_findings_with_error: 0'  "a successful file with a nested error key is not counted as errored"
  assert_grep "$stats" 'oversized_errored: 0'       "nor as an oversized failure"
  assert_grep "$stats" 'oversized_total: 1'         "precondition: the session really was oversized"
  rm -rf "$root"
}

test_l1_hang_is_bounded(){
  echo "# a hung L1 worker is killed with its process group instead of wedging the run"
  # The 2026-08-19 and 2026-08-22 runs each sat for days with every xargs -P slot
  # held by a worker that never exited: no error, no report. Nothing failed, the
  # run simply stopped, and launchd would not start a replacement while the label
  # was still running, so the catch-up triggers were suppressed too.
  if [ -z "$(command -v timeout || command -v gtimeout)" ]; then
    echo "  skip - no timeout binary (brew install coreutils)"; return 0
  fi
  local root; root=$(setup_env); mk_session "$root" sess1
  local pidfile="$root/hang-pids.txt"; : > "$pidfile"
  export MOCK_MODE=l1_hang MOCK_HANG_PIDS="$pidfile" AUTODREAM_L1_TIMEOUT=3 AUTODREAM_L1_ROUNDS=1
  run_dream "$root"
  unset MOCK_MODE MOCK_HANG_PIDS AUTODREAM_L1_TIMEOUT AUTODREAM_L1_ROUNDS

  assert_grep "$root/run.out" 'l1 timeout' "run logged the bound it was using"
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_grep "$(fdir "$root")/$h.json.err" 'exceeded AUTODREAM_L1_TIMEOUT' \
    "the timeout is named in the errlog, not left as a generic empty-output failure"
  assert_grep "$(fdir "$root")/run-stats.txt" 'l1_timed_out: 1' \
    "run-stats counts the timed-out worker"
  # The run has to REACH L2 at all. That is the whole regression: before the
  # timeout, control never returned from dispatch_l1.
  assert_file "$root/dreams/$DATE.md" "run completed and produced a report despite the hang"

  # The mock's child proves the signal reached the process group. A kill aimed at
  # the worker alone would leave it alive and reparented to init, which is how 57
  # node_repl and mnemopi_embed orphans accumulated on the real host.
  # kill -0 succeeds on a zombie, and a child whose parent just died sits as one
  # until init reaps it. Checking once immediately would fail a correct kill on
  # timing alone, so give each pid a bounded grace before calling it leaked.
  local leaked=0 p i
  while read -r p; do
    [ -n "$p" ] || continue
    for i in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$p" 2>/dev/null || break
      sleep 0.5
    done
    kill -0 "$p" 2>/dev/null && { leaked=$((leaked + 1)); kill -9 "$p" 2>/dev/null; }
  done < "$pidfile"
  assert_eq "$leaked" "0" "the hung worker's child was reaped with the group, not orphaned"
  rm -rf "$root"
}

test_intrinsic_124_is_not_a_timeout(){
  echo "# a worker that exits 124 or 137 on its own is not recorded as a timeout"
  # GNU timeout propagates the exit status of the child, so a worker that exits 124
  # by itself, or that the OOM killer SIGKILLs, reaches the caller looking identical
  # to a fired deadline. Only the elapsed interval separates them, and it has to be
  # measured from the launch of timeout rather than from the top of the worker, or
  # preprocessing time closes the gap on a short bound.
  if [ -z "$(command -v timeout || command -v gtimeout)" ]; then
    echo "  skip - no timeout binary (brew install coreutils)"; return 0
  fi
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=l1_exit124 AUTODREAM_L1_TIMEOUT=900 AUTODREAM_L1_ROUNDS=1
  run_dream "$root"
  unset MOCK_MODE AUTODREAM_L1_TIMEOUT AUTODREAM_L1_ROUNDS

  assert_grep "$(fdir "$root")/run-stats.txt" 'l1_timed_out: 0' \
    "an intrinsic 124 well inside the bound is not counted as a timeout"
  local h errf; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  errf="$(fdir "$root")/$h.json.err"
  if grep -q 'exceeded AUTODREAM_L1_TIMEOUT' "$errf" 2>/dev/null; then
    no "the errlog claims a timeout that never happened"
  else
    ok "the errlog does not claim a timeout that never happened"
  fi
  rm -rf "$root"
}

test_l1_timeout_must_be_positive(){
  echo "# a zero or non-numeric L1 timeout is refused at startup, not at 03:15"
  # GNU timeout reads 0 as "no timeout", so an unvalidated 0 restores the wedge
  # while the startup log still claims a bound is in force.
  local root; root=$(setup_env); mk_session "$root" sess1
  export AUTODREAM_L1_TIMEOUT=0; run_dream "$root"; unset AUTODREAM_L1_TIMEOUT
  assert_grep "$root/run.out" 'must be greater than 0' "zero timeout is rejected with a reason"
  assert_no_file "$root/dreams/$DATE.md" "the run refuses to start rather than running unbounded"

  local root2; root2=$(setup_env); mk_session "$root2" sess1
  export AUTODREAM_L1_TIMEOUT=abc; run_dream "$root2"; unset AUTODREAM_L1_TIMEOUT
  assert_grep "$root2/run.out" 'must be a positive integer' "a non-numeric timeout is rejected"
  rm -rf "$root" "$root2"
}

test_l1_warmup_timeout_must_be_positive(){
  echo "# a zero or non-numeric warmup timeout is refused at startup (Codex review of #25)"
  # The warmup runs ahead of every recovery path, so a 0 that GNU timeout reads as
  # "no deadline" can wedge the run before the network wait, retries or breaker.
  local root; root=$(setup_env); mk_session "$root" sess1
  export AUTODREAM_L1_WARMUP_TIMEOUT=0; run_dream "$root"; unset AUTODREAM_L1_WARMUP_TIMEOUT
  assert_grep "$root/run.out" 'AUTODREAM_L1_WARMUP_TIMEOUT must be greater than 0' "zero warmup timeout is rejected with a reason"
  assert_no_file "$root/dreams/$DATE.md" "the run refuses to start rather than risk an unbounded warmup"

  local root2; root2=$(setup_env); mk_session "$root2" sess1
  export AUTODREAM_L1_WARMUP_TIMEOUT=abc; run_dream "$root2"; unset AUTODREAM_L1_WARMUP_TIMEOUT
  assert_grep "$root2/run.out" 'AUTODREAM_L1_WARMUP_TIMEOUT must be a positive integer' "a non-numeric warmup timeout is rejected"
  rm -rf "$root" "$root2"
}

test_warmup_can_be_disabled(){
  echo "# AUTODREAM_L1_WARMUP=0 skips the call and says so rather than reporting a pass"
  local root; root=$(setup_env); mk_session "$root" sess1
  AUTODREAM_L1_WARMUP=0 run_dream "$root"
  # 'skipped' and 'ok' must never be the same token: a self-audit reading l1_warmup has
  # to be able to tell a warmup that passed from one that never ran.
  assert_grep   "$(fdir "$root")/run-stats.txt" 'l1_warmup: skipped' "a disabled warmup is recorded as skipped"
  assert_nogrep "$root/run.out" 'L1 auth warmup'                     "and nothing is dispatched for it"
  assert_file   "$root/dreams/$DATE.md"                              "the run still completes normally"
  rm -rf "$root"
}

test_warmup_diagnostic_stdout_is_a_failure_not_ok(){
  echo "# a warmup that exits 0 with a diagnostic instead of the reply is a failure (debate review of e95e2f2)"
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=warmup_diag
  AUTODREAM_L1_ROUNDS=1 run_dream "$root"
  unset MOCK_MODE
  assert_grep "$(fdir "$root")/run-stats.txt" 'l1_warmup: failed' "non-empty stdout that is not the reply records failed"
  rm -rf "$root"
}

test_warmup_empty_stdout_is_a_failure_not_ok(){
  echo "# the warmup must not read omp's stderr chatter as a successful reply"
  local root; root=$(setup_env); mk_session "$root" sess1
  # l1_incomplete writes nothing to stdout. omp prints 'Working...' on stderr on every run,
  # so a warmup that captured 2>&1 saw non-empty output and recorded `ok` for precisely the
  # exit-0/empty-stdout failure it was added to expose.
  export MOCK_MODE=l1_incomplete
  AUTODREAM_L1_ROUNDS=1 run_dream "$root"
  unset MOCK_MODE
  assert_nogrep "$(fdir "$root")/run-stats.txt" 'l1_warmup: ok' "an empty-stdout warmup is never recorded as ok"
  rm -rf "$root"
}

test_warmup_runs_before_the_fanout(){
  echo "# the auth warmup is one serial call that lands before round 1 dispatches"
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  # Ordering is the whole feature. A warmup that runs alongside the fanout refreshes
  # nothing, because the workers it was meant to protect are already racing it.
  local warm round
  warm=$(grep -n 'L1 auth warmup' "$root/run.out" | head -1 | cut -d: -f1)
  round=$(grep -n 'L1 triage round 1/' "$root/run.out" | head -1 | cut -d: -f1)
  assert_grep "$root/run.out" 'L1 auth warmup'          "the warmup is logged"
  [ -n "$warm" ] && [ -n "$round" ] && [ "$warm" -lt "$round" ] \
    && ok "the warmup completes before the first round dispatches" \
    || no "the warmup completes before the first round dispatches (warmup line $warm, round line $round)"
  assert_grep "$(fdir "$root")/run-stats.txt" 'l1_warmup: ok' "run-stats records the warmup result"
  rm -rf "$root"
}

test_breaker_needs_two_barren_rounds_not_one(){
  echo "# a round that recovered sessions must not be counted barren by the round after it"
  local root; root=$(setup_env)
  mk_session "$root" sess1; mk_session "$root" sess2; mk_session "$root" sess3
  mkdir -p "$root/mockstate"
  # Exactly one session ever succeeds: round 1 goes 3 missing -> 2, rounds 2+ recover none.
  # The first version of the breaker compared each round's ending count against the PREVIOUS
  # round's ending count, so round 2 alone (2 == 2) tripped it and logged that rounds 1 and 2
  # both recovered nothing — false, round 1 recovered one. The streak must reach 2, so the
  # earliest honest trip is round 3.
  export MOCK_MODE=l1_partial_then_stall MOCK_STATE_DIR="$root/mockstate"
  AUTODREAM_L1_ROUNDS=5 run_dream "$root"
  unset MOCK_MODE MOCK_STATE_DIR

  assert_grep   "$root/run.out" 'L1 triage round 3/5' "round 3 still runs — round 2 alone cannot trip the breaker"
  assert_nogrep  "$root/run.out" 'rounds 1 and 2 both recovered nothing' "the breaker never claims a productive round was barren"
  assert_grep   "$(fdir "$root")/run-stats.txt" 'l1_breaker_fired: yes' "it does still fire once two rounds really are barren"
  assert_grep   "$(fdir "$root")/run-stats.txt" 'l1_missing_after_retries: 0' "the stub round still lands"
  rm -rf "$root"
}

test_a_deterministic_failure_trips_the_breaker(){
  echo "# two rounds recovering nothing cut the retry budget instead of spending all five"
  local root; root=$(setup_env); mk_session "$root" sess1
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # l1_incomplete never writes output, so every round fails identically — the 2026-09-05
  # through 2026-09-10 shape, where five rounds bought sixteen empty stubs and the stats
  # they left read as a healthy retry loop.
  export MOCK_MODE=l1_incomplete
  AUTODREAM_L1_ROUNDS=5 run_dream "$root"
  unset MOCK_MODE
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep   "$root/run.out" 'L1 circuit breaker'      "the breaker announces itself"
  assert_grep   "$stats" 'l1_breaker_fired: yes'          "run-stats records that the budget was cut"
  assert_grep   "$root/run.out" 'L1 triage round 2/5'     "round 2 still runs (one bad round proves nothing)"
  assert_nogrep "$root/run.out" 'L1 triage round 3/5'     "rounds 3 and 4 are skipped"
  assert_nogrep "$root/run.out" 'L1 triage round 4/5'     "no further retry round is dispatched"
  # The stub round is not optional. Without it the slot stays empty, which the deferral
  # logic reads as a dead network rather than a dead worker.
  assert_file   "$(fdir "$root")/$h.json"                 "the stub round still writes the metadata stub"
  assert_grep   "$stats" 'l1_missing_after_retries: 0'    "no session is left in a missing state"
  assert_grep   "$stats" 'network_deferred: no'           "a deterministic worker failure is not an outage"
  rm -rf "$root"
}

test_a_flaky_worker_does_not_trip_the_breaker(){
  echo "# a worker that recovers on retry must keep its retry budget"
  local root; root=$(setup_env); mk_session "$root" sess1
  # l1_flaky fails the first dispatch per session and succeeds on the second. Round 2
  # recovers the session, so the breaker's two-rounds-of-no-progress condition is never
  # met — this is the case the retry loop exists for and the breaker must not steal.
  export MOCK_MODE=l1_flaky
  AUTODREAM_L1_ROUNDS=5 run_dream "$root"
  unset MOCK_MODE
  assert_grep   "$(fdir "$root")/run-stats.txt" 'l1_breaker_fired: no' "the breaker stays out of a recovering run"
  assert_nogrep "$root/run.out" 'L1 circuit breaker'                   "and never announces itself"
  assert_file   "$root/dreams/$DATE.md"                                "the run produces its report"
  rm -rf "$root"
}

test_warmup_works_for_an_adapter_with_no_environment(){
  echo "# an adapter whose l1-env prints nothing still gets its warmup (an empty array under set -u on bash 3.2)"
  local root; root=$(setup_env); mk_session "$root" sess1
  # The claude adapter with an EMPTY l1-env, which is what omp's is. run.sh runs under /bin/bash 3.2
  # with set -u, where expanding an empty array is an unbound-variable error: the warmup pipeline
  # aborted before timeout started, recorded l1_warmup: failed and blamed the provider.
  local ad="$root/adapters"; cp -R "$REPO/adapters" "$ad"
  python3 - "$ad/claude/adapter.sh" <<'PY'
import sys,re
p=sys.argv[1]
t=open(p).read()
t=re.sub(r"  l1-env\) .*?\n    ;;\n","  l1-env) : ;;\n",t,count=1,flags=re.S)
open(p,"w").write(t)
PY
  [ -z "$("$ad/claude/adapter.sh" l1-env)" ] || { no "precondition: the test adapter has an empty l1-env"; rm -rf "$root"; return; }
  export ADAPTERS_ROOT="$ad"; run_dream "$root"; unset ADAPTERS_ROOT
  assert_grep "$(fdir "$root")/run-stats.txt" 'l1_warmup: ok' "the warmup ran and succeeded"
  assert_nogrep "$root/run.out" 'warmup FAILED' "and no failure was logged"
  rm -rf "$root"
}

shim_curl(){ # $1=sandbox root, $2=http_code to report
  mkdir -p "$1/shim"
  printf '#!/bin/bash\nprintf %s "%s"\n' "'%s'" "$2" > "$1/shim/curl"
  chmod +x "$1/shim/curl"
  printf '%s' "$1/shim"
}

test_net_up_survives_a_curl_that_stalls_after_the_reply(){
  echo "# a curl held in close() after the reply arrived still counts as reachable (cutover 2026-10-03: a network filter stalled the socket close for seconds)"
  local root tb t0 t1 rc
  root=$(setup_env)
  tb=$(command -v timeout || command -v gtimeout || true)
  if [ -z "$tb" ]; then ok "skipped: no timeout binary on this host"; rm -rf "$root"; return 0; fi
  mkdir -p "$root/stall"
  # A curl that writes the status line to the -D file the way a real reply does, then hangs.
  printf '%s\n' '#!/bin/bash' 'while [ $# -gt 0 ]; do [ "$1" = -D ] && printf "HTTP/2 404\r\n\r\n" > "$2"; shift; done' 'sleep 30' > "$root/stall/curl"
  chmod +x "$root/stall/curl"
  sed -n '/^net_up() {/,/^}/p' "$REPO/bin/run.sh" > "$root/net_up.sh"
  t0=$(date +%s)
  PATH="$root/stall:$PATH" TIMEOUT_BIN="$tb" AUTODREAM_NETUP_LIMIT=2 bash -c ". \"$root/net_up.sh\"; net_up https://api.anthropic.com/"; rc=$?
  t1=$(date +%s)
  assert_eq "$rc" "0" "a reply that arrived before the stall is read as reachable"
  if [ $((t1 - t0)) -lt 12 ]; then ok "and the probe is bounded ($((t1 - t0))s)"; else no "the probe was not bounded ($((t1 - t0))s)"; fi
  # A curl that never got any reply is still down.
  printf '%s\n' '#!/bin/bash' 'sleep 30' > "$root/stall/curl"
  PATH="$root/stall:$PATH" TIMEOUT_BIN="$tb" AUTODREAM_NETUP_LIMIT=2 bash -c ". \"$root/net_up.sh\"; net_up https://api.anthropic.com/"; rc=$?
  assert_eq "$rc" "1" "a stall with no reply at all is still down"
  rm -rf "$root"
}

# A curl that records the URL it was asked for and answers like a reachable host, or never
# answers when $3 is "hang".
shim_curl_logging(){ # $1=sandbox root $2=log file $3=reply|hang
  mkdir -p "$1/logshim"
  printf '%s\n' '#!/bin/bash' 'for a in "$@"; do case "$a" in https://*|http://*) printf "%s\n" "$a" >> "'"$2"'" ;; esac; done' \
    "$( [ "$3" = hang ] && echo 'sleep 30' || echo 'printf 200' )" > "$1/logshim/curl"
  chmod +x "$1/logshim/curl"
  printf '%s' "$1/logshim"
}

test_net_up_probes_the_host_it_is_given(){
  echo "# net_up probes the URL a layer's provider owns, not a hard-coded api.anthropic.com (issue 109)"
  local root shim log rc
  root=$(setup_env); log="$root/curl.log"; shim=$(shim_curl_logging "$root" "$log" reply)
  sed -n '/^net_up() {/,/^}/p' "$REPO/bin/run.sh" > "$root/net_up.sh"
  PATH="$shim:$PATH" bash -c ". \"$root/net_up.sh\"; net_up -l 2 https://api.deepseek.com/"; rc=$?
  assert_eq "$rc" "0" "a reply from the layer's own host is up"
  assert_grep   "$log" 'api.deepseek.com' "the probe went to the provider the layer calls"
  assert_nogrep "$log" 'api.anthropic.com' "and not to anthropic"
  rm -rf "$root"
}

test_wait_for_network_cap_bounds_the_probe(){
  echo "# the cap bounds the probe too: a hung probe cannot run past what is left of it (issue 110)"
  local root shim tb t0 t1 rc
  root=$(setup_env); shim=$(shim_curl_logging "$root" "$root/curl.log" hang)
  tb=$(command -v timeout || command -v gtimeout || true)
  if [ -z "$tb" ]; then ok "skipped: no timeout binary on this host"; rm -rf "$root"; return 0; fi
  { sed -n '/^net_up() {/,/^}/p' "$REPO/bin/run.sh"; sed -n '/^wait_for_network() {/,/^}/p' "$REPO/bin/run.sh"; } > "$root/wfn.sh"
  t0=$(date +%s)
  PATH="$shim:$PATH" TIMEOUT_BIN="$tb" AUTODREAM_NETCHECK_CAP=2 AUTODREAM_NETUP_LIMIT=20 NET_DOWN_SECONDS=0 \
    bash -c 'log(){ :; }; . "'"$root"'/wfn.sh"; wait_for_network https://api.deepseek.com/'; rc=$?
  t1=$(date +%s)
  assert_eq "$rc" "1" "a host that never answers is given up on"
  if [ $((t1 - t0)) -le 6 ]; then ok "inside the cap, not the probe limit ($((t1 - t0))s for a 2s cap)"; else no "the wait ran $((t1 - t0))s against a 2s cap"; fi
  # Six dead providers against a 2s cap. A probe past the cap is clamped to 1s, so a loop that keeps
  # probing after the cap is spent runs about 2s + 5 x 1s (7s or more, plus timeout grace), while one
  # that stops at the cap runs about 2s. A ceiling of 4s sits between them by more than the 1s
  # granularity of date +%s, so load can move either reading by a second without flipping the verdict.
  t0=$(date +%s)
  PATH="$shim:$PATH" TIMEOUT_BIN="$tb" AUTODREAM_NETCHECK_CAP=2 AUTODREAM_NETUP_LIMIT=20 NET_DOWN_SECONDS=0 \
    bash -c 'log(){ :; }; . "'"$root"'/wfn.sh"; wait_for_network "$(printf "%s\n" https://a.invalid/ https://b.invalid/ https://c.invalid/ https://d.invalid/ https://e.invalid/ https://f.invalid/)"'; rc=$?
  t1=$(date +%s)
  assert_eq "$rc" "1" "several hosts that never answer are given up on"
  if [ $((t1 - t0)) -le 4 ]; then ok "and the cap covers every probe in the pass ($((t1 - t0))s for a 2s cap)"; else no "six dead hosts ran $((t1 - t0))s against a 2s cap"; fi
  rm -rf "$root"
}

test_network_down_defers_the_date(){
  echo "# a round that cannot be dispatched defers the date instead of reporting on a short corpus"
  local root; root=$(setup_env); mk_session "$root" sess1
  local shim; shim=$(shim_curl "$root" 000)
  # CAP=0 makes wait_for_network give up on its first check, so the test never sleeps.
  TEST_CURL_SHIMMED=1   PATH="$shim:$PATH" AUTODREAM_NETCHECK=1 AUTODREAM_NETCHECK_CAP=0 run_dream "$root"
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_eq      "$(cat "$root/run.exit")" "1"         "a deferred run exits non-zero"
  assert_no_file "$root/dreams/$DATE.md"               "no report is written from a dead-network run"
  assert_no_file "$(fdir "$root")/$h.json"             "no worker was dispatched at all"
  assert_grep    "$(fdir "$root")/run-stats.txt" 'network_deferred: yes' "run-stats records the deferral"
  assert_grep    "$root/run.out" 'Deferring'           "the log says the date was deferred"
  rm -rf "$root"
}

test_oversized_gate_script_deferred(){
  echo "# oversized-gate.sh: a network-deferred date is excluded, never read as a clean 0%"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  local shim; shim=$(shim_curl "$root" 000)
  TEST_CURL_SHIMMED=1 PATH="$shim:$PATH" AUTODREAM_SLIM_BYTES=100 AUTODREAM_NETCHECK=1 AUTODREAM_NETCHECK_CAP=0 run_dream "$root"
  local fd; fd=$(fdir "$root")
  assert_grep "$fd/run-stats.txt" 'network_deferred: yes' "precondition: the run really deferred"
  local out; out=$(AUTODREAM_SLIM_BYTES=100 bash "$GATE" "$fd" 2>&1)
  printf '%s' "$out" > "$root/gate.out"
  assert_grep   "$root/gate.out" 'network-deferred run, excluded' "the deferred date is named and excluded"
  assert_nogrep "$root/gate.out" 'GATE CLOSED'                    "a date where no worker ran must not close the gate"
  # Every date excluded is not the same as nothing oversized (Auditor verification of 6ca1584).
  # A dir with no sessions.txt is the other way a date drops out, so the window holds both.
  local empty="$root/2020-01-03"; mkdir -p "$empty"
  out=$(AUTODREAM_SLIM_BYTES=100 bash "$GATE" "$fd" "$empty" 2>&1)
  printf '%s' "$out" > "$root/gate.out"
  assert_nogrep "$root/gate.out" 'No oversized transcripts' "an all-excluded window does not claim nothing was oversized"
  assert_grep   "$root/gate.out" 'No date in this window could be measured' "it says no date was measurable"
  rm -rf "$root"
}

test_route_lost_after_the_precheck_still_defers(){
  echo "# a route lost AFTER the pre-dispatch check must defer, not publish a short corpus"
  local root; root=$(setup_env); mk_session "$root" sess1
  local shim; shim=$(shim_curl "$root" 000)
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # NETCHECK=0 skips the pre-dispatch check, which is precisely the gap: the check only
  # proves the route was up when the round started. The worker then fails while the
  # failure-path probe sees no route — the round-5 shape from 2026-09-04.
  # ROUNDS=1 means this is also the final round, where the stub used to be written.
  export MOCK_MODE=l1_incomplete
  TEST_CURL_SHIMMED=1   PATH="$shim:$PATH" AUTODREAM_NETCHECK=0 AUTODREAM_SLIM_BYTES=10 AUTODREAM_L1_ROUNDS=1 run_dream "$root"
  unset MOCK_MODE
  local stats="$(fdir "$root")/run-stats.txt"
  # No stub. A stub carries a .findings key, and jq -e counts an empty array as present,
  # so writing one marks the session done: MISSING hits zero, the run stops deferring, and
  # the next run skips the session forever because its slot is filled.
  assert_no_file "$(fdir "$root")/$h.json"   "no findings stub is written for a network-down failure"
  assert_no_file "$root/dreams/$DATE.md"     "no report is published on an outage-short corpus"
  assert_eq      "$(cat "$root/run.exit")" "1" "the run exits non-zero"
  assert_grep    "$stats" 'network_deferred: yes'   "run-stats records the post-dispatch deferral"
  assert_grep    "$stats" 'oversized_errored: 0'    "an unstubbed session cannot reach the oversized-error counter"
  assert_grep    "$(fdir "$root")/$h.json.err" 'no route to api.anthropic.com' ".err names the real cause"
  # Ledger carries hash + round + verdict so a later round can overrule an earlier one.
  assert_grep    "$(fdir "$root")/l1-netdown.txt" "^$h 1 true\$" "the ledger records the round and the verdict"
  rm -rf "$root"
}

test_missing_curl_is_not_read_as_an_outage(){
  echo "# a host without curl must not have every failure classified as a network outage"
  local root; root=$(setup_env); mk_session "$root" sess1
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # An empty shim dir placed FIRST on PATH cannot hide curl, so hide it by pointing PATH
  # at a dir holding only the binaries run.sh needs. Simpler and more honest: a curl that
  # does not exist is simulated by a shim that exits 127 the way a missing command does.
  mkdir -p "$root/nocurl"
  printf '#!/bin/bash\nexit 127\n' > "$root/nocurl/curl"; chmod +x "$root/nocurl/curl"
  export MOCK_MODE=l1_incomplete
  TEST_CURL_SHIMMED=1   PATH="$root/nocurl:$PATH" AUTODREAM_NETCHECK=0 AUTODREAM_SLIM_BYTES=10 AUTODREAM_L1_ROUNDS=1 run_dream "$root"
  unset MOCK_MODE
  # A curl that cannot run answers nothing. Classifying that as an outage would defer
  # every date forever on a machine without curl, so the failure stays unclassified: no
  # ledger entry, no deferral, and the .err says why rather than leaving it to inference.
  assert_grep    "$(fdir "$root")/$h.json.err" 'curl could not be run here' ".err says the check could not answer"
  assert_nogrep  "$(fdir "$root")/l1-netdown.txt" "^$h " "an unclassifiable failure is never ledgered as an outage"
  assert_grep    "$(fdir "$root")/run-stats.txt" 'network_deferred: no' "and it does not defer the date"
  rm -rf "$root"
}

test_a_transient_outage_is_ridden_out_not_deferred(){
  echo "# a network blip in one round must burn a retry, not defer the whole date"
  local root; root=$(setup_env); mk_session "$root" sess1
  # A curl that reports no route on its first call and a reachable host afterwards. The
  # first version of this fix broke out of the retry loop the moment any worker failed
  # with a network flavour, which threw the retry budget away: one transient DNS timeout
  # deferred the date for three hours instead of succeeding on round 2.
  mkdir -p "$root/shim"
  printf '#!/bin/bash\nc="$root/shim/n"\nn=$(cat "$c" 2>/dev/null || echo 0)\necho $((n+1)) > "$c"\nif [ "$n" -lt 1 ]; then printf %s "000"; else printf %s "200"; fi\n' "'%s'" "'%s'" \
    | sed "s|\$root|$root|g" > "$root/shim/curl"
  chmod +x "$root/shim/curl"
  # l1_flaky fails the first dispatch per session and succeeds on the retry, so round 1
  # fails while curl says no route and round 2 succeeds while it says 200.
  export MOCK_MODE=l1_flaky
  TEST_CURL_SHIMMED=1 PATH="$root/shim:$PATH" AUTODREAM_NETCHECK=0 AUTODREAM_L1_ROUNDS=2 run_dream "$root"
  unset MOCK_MODE
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_file "$(fdir "$root")/$h.json"  "the retry succeeded rather than being cut short"
  assert_file "$root/dreams/$DATE.md"    "a recovered run still publishes its report"
  assert_grep "$(fdir "$root")/run-stats.txt" 'network_deferred: no' "a blip that recovered is not a deferral"
  rm -rf "$root"
}

test_no_curl_does_not_defer_a_healthy_run(){
  echo "# a host without curl must not defer every run for 1800s of unanswerable checks"
  local root; root=$(setup_env); mk_session "$root" sess1
  # net_up ran curl unconditionally and read its empty output as "no route", so a machine
  # without curl looped to the full cap and deferred a run that was working fine. The
  # worker-failure path grew the command -v guard first; net_up did not have it.
  mkdir -p "$root/shim"
  printf '#!/bin/bash\nexit 127\n' > "$root/shim/curl"; chmod +x "$root/shim/curl"
  # NETCHECK=1 with a tiny cap: if the guard is missing this defers, and fast.
  TEST_CURL_SHIMMED=1 PATH="$root/shim:$PATH" AUTODREAM_NETCHECK=1 AUTODREAM_NETCHECK_CAP=0 run_dream "$root"
  assert_file "$root/dreams/$DATE.md" "the run completed instead of deferring on an unrunnable check"
  assert_grep "$(fdir "$root")/run-stats.txt" 'network_deferred: no' "an unanswerable check is not an outage"
  rm -rf "$root"
}

test_unexecutable_curl_is_not_read_as_an_outage(){
  echo "# a curl that exists but cannot be executed (exit 126) is unclassifiable, not down"
  local root; root=$(setup_env); mk_session "$root" sess1
  mkdir -p "$root/shim"
  # Return 126 directly. Some shells skip a non-executable PATH entry and run the next
  # curl, which made this offline fixture depend on whether the host network was up.
  printf '#!/bin/bash\nexit 126\n' > "$root/shim/curl"; chmod 755 "$root/shim/curl"
  TEST_CURL_SHIMMED=1 PATH="$root/shim:$PATH" AUTODREAM_NETCHECK=1 AUTODREAM_NETCHECK_CAP=0 run_dream "$root"
  assert_file "$root/dreams/$DATE.md" "the run completed rather than deferring on an unrunnable curl"
  assert_grep "$(fdir "$root")/run-stats.txt" 'network_deferred: no' "126 is treated the same as 127"
  rm -rf "$root"
}

test_provider_refusal_defers_without_a_stub(){
  echo "# a provider refusal on a reachable network defers the date and leaves no stub (Z.ai 1113, 2026-10-01 and 10-02)"
  local root; root=$(setup_env); mk_session "$root" sess1
  local shim; shim=$(shim_curl "$root" 200)
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # The route is up, so netdown is false. Without the provider carve-out the final round
  # wrote a stub, MISSING hit zero, L2 published an empty report, and every later run
  # skipped the session because its slot was filled.
  export MOCK_MODE=l1_provider_refusal
  TEST_CURL_SHIMMED=1   PATH="$shim:$PATH" AUTODREAM_NETCHECK=0 AUTODREAM_SLIM_BYTES=10 AUTODREAM_L1_ROUNDS=1 run_dream "$root"
  unset MOCK_MODE
  local stats="$(fdir "$root")/run-stats.txt"
  assert_no_file "$(fdir "$root")/$h.json"   "no findings stub is written for a provider refusal"
  assert_no_file "$root/dreams/$DATE.md"     "no report is published on a corpus the provider refused"
  assert_eq      "$(cat "$root/run.exit")" "1" "the run exits non-zero"
  assert_grep    "$stats" 'network_deferred: yes' "run-stats records the deferral"
  assert_grep    "$(fdir "$root")/$h.json.err" 'provider refusal when this worker failed' ".err names the cause"
  assert_grep    "$(fdir "$root")/l1-netdown.txt" "^$h 1 provider\$" "the ledger records the round and the verdict"
  rm -rf "$root"
}

test_provider_402_and_missing_curl_still_defer(){
  echo "# DeepSeek's 402 Insufficient Balance defers the date, with or without curl"
  local root h shim stats
  root=$(setup_env); mk_session "$root" sess1
  h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  shim=$(shim_curl "$root" 200)
  export MOCK_MODE=l1_provider_402
  TEST_CURL_SHIMMED=1   PATH="$shim:$PATH" AUTODREAM_NETCHECK=0 AUTODREAM_SLIM_BYTES=10 AUTODREAM_L1_ROUNDS=1 run_dream "$root"
  unset MOCK_MODE
  assert_no_file "$(fdir "$root")/$h.json" "a 402 balance refusal leaves no stub even though classify_failure has no 402 pattern"
  assert_grep    "$(fdir "$root")/l1-netdown.txt" "^$h 1 provider\$" "the ledger records the verdict"
  rm -rf "$root"
  # A host without curl: netdown stays unknown, and the permanent check must still run.
  root=$(setup_env); mk_session "$root" sess1
  h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  mkdir -p "$root/nocurl"
  printf '#!/bin/bash\nexit 127\n' > "$root/nocurl/curl"; chmod +x "$root/nocurl/curl"
  export MOCK_MODE=l1_provider_refusal
  TEST_CURL_SHIMMED=1   PATH="$root/nocurl:$PATH" AUTODREAM_NETCHECK=0 AUTODREAM_SLIM_BYTES=10 AUTODREAM_L1_ROUNDS=1 run_dream "$root"
  unset MOCK_MODE
  assert_no_file "$(fdir "$root")/$h.json" "a permanent refusal leaves no stub when curl cannot answer"
  rm -rf "$root"
  # Talking about balances is not a refusal: the match needs an error-shaped line.
  root=$(setup_env)
  printf 'worker said: the invoice shows insufficient balance for the Q3 ledger\nworker exit code: 1 after 3s\n' > "$root/talk.err"
  if bash -c ". \"$REPO/bin/failure-class.sh\"; provider_is_permanent \"$root/talk.err\""; then
    no "a transcript that mentions insufficient balance was read as a permanent refusal"
  else
    ok "a transcript that mentions insufficient balance is not a permanent refusal"
  fi
  rm -rf "$root"
}

test_rounds_used_counts_rounds_that_dispatched(){
  echo "# a round that deferred before dispatching must not be counted as a round used"
  local root; root=$(setup_env); mk_session "$root" sess1
  local shim; shim=$(shim_curl "$root" 000)
  TEST_CURL_SHIMMED=1 PATH="$shim:$PATH" AUTODREAM_NETCHECK=1 AUTODREAM_NETCHECK_CAP=0 run_dream "$root"
  assert_grep "$(fdir "$root")/run-stats.txt" 'l1_rounds_used: 0' "zero rounds dispatched is reported as zero"
  # And the L2-scoped keys exist even though the run returned before the aggregator.
  assert_grep "$(fdir "$root")/run-stats.txt" 'network_deferred_l2: no'      "the L2 keys are written on the L1-deferral path too"
  assert_grep "$(fdir "$root")/run-stats.txt" 'network_down_seconds_l2: 0'   "an L2 that never ran waited zero seconds"
  rm -rf "$root"
}

test_changelog(){
  echo "# upstream changelog window (offline, local fixture remote)"
  command -v git >/dev/null 2>&1 || { echo "  skip - git not available"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1

  # Build a local 'remote' for anthropics/claude-code: one CHANGELOG commit dated
  # inside the target day [2020-01-02, 2020-01-03), one dated a month later (out of window).
  local up="$root/upstream"; mkdir -p "$up"
  ( cd "$up" && git init -q && git config user.email t@t.invalid && git config user.name t
    printf '# Changelog\n\n## 2.1.999\n\n- In-window mock feature\n' > CHANGELOG.md
    git add CHANGELOG.md
    GIT_AUTHOR_DATE="2020-01-02T12:00:00" GIT_COMMITTER_DATE="2020-01-02T12:00:00" \
      git commit -q -m 'release 2.1.999'
    printf '# Changelog\n\n## 2.2.0\n\n- Out-of-window mock feature\n\n## 2.1.999\n\n- In-window mock feature\n' > CHANGELOG.md
    git add CHANGELOG.md
    GIT_AUTHOR_DATE="2020-02-01T12:00:00" GIT_COMMITTER_DATE="2020-02-01T12:00:00" \
      git commit -q -m 'release 2.2.0' )

  export AUTODREAM_CHANGELOG=1 CHANGELOG_REMOTE="$up" CLAUDE_CODE_REPO="$root/cache/cc"
  run_dream "$root"
  unset AUTODREAM_CHANGELOG CHANGELOG_REMOTE CLAUDE_CODE_REPO

  local cw="$(fdir "$root")/changelog-window.md"
  assert_file   "$cw" "changelog-window.md written"
  assert_grep   "$cw" '2.1.999'              "captures the in-window release"
  assert_grep   "$cw" 'In-window mock'       "captures the in-window bullet"
  assert_nogrep "$cw" '2.2.0'                "excludes the out-of-window release"
  rm -rf "$root"
}

test_changelog_multi_source(){
  echo "# multi-source changelog: per-harness sections, isolated failures, no log leakage"
  command -v git >/dev/null 2>&1 || { echo "  skip - git not available"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1

  # Two local fixture 'remotes'. The second keeps its changelog at a NESTED path, which is
  # the OMP shape — a monorepo with no root CHANGELOG — and the reason path is per-source.
  local a="$root/up-a"; mkdir -p "$a"
  ( cd "$a" && git init -q && git config user.email t@t.invalid && git config user.name t
    printf '# Changelog\n\n## 9.9.9\n\n- Alpha in-window\n' > CHANGELOG.md
    git add CHANGELOG.md
    GIT_AUTHOR_DATE="2020-01-02T12:00:00" GIT_COMMITTER_DATE="2020-01-02T12:00:00" \
      git commit -q -m 'alpha release' )

  local b="$root/up-b"; mkdir -p "$b/packages/coding-agent"
  ( cd "$b" && git init -q && git config user.email t@t.invalid && git config user.name t
    printf '# Changelog\n\n## 8.8.8\n\n- Beta in-window\n' > packages/coding-agent/CHANGELOG.md
    git add packages/coding-agent/CHANGELOG.md
    GIT_AUTHOR_DATE="2020-01-02T12:00:00" GIT_COMMITTER_DATE="2020-01-02T12:00:00" \
      git commit -q -m 'beta release' )

  # Third source points at a path that is not a repo: its clone must fail into its own
  # section without costing the other two theirs.
  export AUTODREAM_CHANGELOG=1
  export AUTODREAM_CHANGELOG_SOURCES="Alpha|$a|CHANGELOG.md|$root/cache/a;Beta|$b|packages/coding-agent/CHANGELOG.md|$root/cache/b;Ghost|$root/nope.git|CHANGELOG.md|$root/cache/ghost"
  run_dream "$root"
  unset AUTODREAM_CHANGELOG AUTODREAM_CHANGELOG_SOURCES

  local cw="$(fdir "$root")/changelog-window.md"
  assert_file   "$cw" "changelog-window.md written"
  assert_grep   "$cw" '^## Alpha'            "the first harness gets its own section"
  assert_grep   "$cw" '^## Beta'             "the second harness gets its own section"
  assert_grep   "$cw" '^## Ghost'            "an unreachable harness still gets a section"
  assert_grep   "$cw" 'Alpha in-window'      "the first harness's entry is captured"
  assert_grep   "$cw" 'Beta in-window'       "a nested changelog path is captured"
  assert_grep   "$cw" 'Git clone failed'     "the unreachable harness reports its failure"
  # The bug this pins: log() writes to stdout, so building the file inside a redirected
  # block files the runner's own progress lines as upstream release notes.
  assert_nogrep "$cw" 'changelog\['          "no runner log lines leak into the report input"
  assert_nogrep "$cw" 'cloning'              "no clone progress leaks into the report input"
  rm -rf "$root"
}

test_changelog_refuses_foreign_cache_dir(){
  echo "# a configured cache path that is a real non-git directory is never deleted (debate review of e95e2f2)"
  command -v git >/dev/null 2>&1 || { echo "  skip - git not available"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  local a="$root/up-a"; mkdir -p "$a"
  ( cd "$a" && git init -q && git config user.email t@t.invalid && git config user.name t
    printf '# Changelog\n\n## 9.9.9\n\n- Alpha in-window\n' > CHANGELOG.md
    git add CHANGELOG.md
    GIT_AUTHOR_DATE="2020-01-02T12:00:00" GIT_COMMITTER_DATE="2020-01-02T12:00:00" \
      git commit -q -m 'alpha release' )
  local precious="$root/precious"; mkdir -p "$precious"; printf 'keep me\n' > "$precious/notes.txt"

  # A second foreign dir reached through `..` from inside the cache prefix: it must not
  # count as a cache path just because the string starts with one.
  local sneaky="$root/sneaky"; mkdir -p "$sneaky"; printf 'keep me too\n' > "$sneaky/notes.txt"
  local ad; ad=$(cd "$root/autodream" 2>/dev/null && pwd) || ad="$root/autodream"
  # The cache dir must exist, or `cache/..` never resolves and rm -rf is a silent no-op
  # whether or not the guard is there, which is how the first version of this check passed
  # with the guard removed.
  mkdir -p "$ad/cache"
  # A third foreign dir reached through a symlink inside the cache: the path string has no
  # `..` and starts with the cache prefix, but rm -rf follows the intermediate link
  # (Codex review of 0129fc0).
  local linked="$root/linked"; mkdir -p "$linked/old-repo"; printf 'keep me three\n' > "$linked/old-repo/notes.txt"
  ln -s "$linked" "$ad/cache/link"

  export AUTODREAM_CHANGELOG=1 AUTODREAM_CHANGELOG_MAX_LINES=abc
  export AUTODREAM_CHANGELOG_SOURCES="Alpha|$a|CHANGELOG.md|$root/cache/a;Typo|$a|CHANGELOG.md|$precious;Dots|$a|CHANGELOG.md|$ad/cache/../../sneaky;Link|$a|CHANGELOG.md|$ad/cache/link/old-repo"
  run_dream "$root"
  unset AUTODREAM_CHANGELOG AUTODREAM_CHANGELOG_SOURCES AUTODREAM_CHANGELOG_MAX_LINES

  local cw="$(fdir "$root")/changelog-window.md"
  assert_file "$precious/notes.txt"          "the non-git directory and its contents survive"
  assert_file "$sneaky/notes.txt"            "a path that climbs out of the cache with .. is not treated as the cache"
  assert_file "$linked/old-repo/notes.txt"   "a path through a symlink inside the cache is not treated as the cache"
  assert_grep "$cw" 'is a non-empty directory that is not a git clone' "its section says why it was skipped"
  assert_grep "$cw" 'Alpha in-window'        "the other source is unaffected"
  assert_grep "$root/run.out" 'AUTODREAM_CHANGELOG_MAX_LINES=.abc. is not a positive integer; using 400' "a non-numeric cap falls back to the default instead of disabling it"

  # Second run reuses the fixture remote $a, so $root is removed only after it.
  local root2; root2=$(setup_env); mk_session "$root2" sess1
  export AUTODREAM_CHANGELOG=1 AUTODREAM_CHANGELOG_MAX_LINES=00
  export AUTODREAM_CHANGELOG_SOURCES="Alpha|$a|CHANGELOG.md|$root2/cache/a"
  run_dream "$root2"
  unset AUTODREAM_CHANGELOG AUTODREAM_CHANGELOG_SOURCES AUTODREAM_CHANGELOG_MAX_LINES
  assert_grep "$root2/run.out" 'AUTODREAM_CHANGELOG_MAX_LINES=.00. is not a positive integer; using 400' "a zero written as 00 is refused like 0"
  assert_grep "$(fdir "$root2")/changelog-window.md" 'Alpha in-window' "and the section still carries its content"
  rm -rf "$root2" "$root"
}

test_changelog_single_remote_suppresses_defaults(){
  echo "# CHANGELOG_REMOTE selects one source and suppresses the default three"
  command -v git >/dev/null 2>&1 || { echo "  skip - git not available"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  local up="$root/upstream"; mkdir -p "$up"
  ( cd "$up" && git init -q && git config user.email t@t.invalid && git config user.name t
    printf '# Changelog\n\n## 7.7.7\n\n- Solo in-window\n' > CHANGELOG.md
    git add CHANGELOG.md
    GIT_AUTHOR_DATE="2020-01-02T12:00:00" GIT_COMMITTER_DATE="2020-01-02T12:00:00" \
      git commit -q -m 'solo release' )

  export AUTODREAM_CHANGELOG=1 CHANGELOG_REMOTE="$up" CLAUDE_CODE_REPO="$root/cache/cc"
  run_dream "$root"
  unset AUTODREAM_CHANGELOG CHANGELOG_REMOTE CLAUDE_CODE_REPO

  local cw="$(fdir "$root")/changelog-window.md"
  assert_grep   "$cw" 'Solo in-window' "the named remote is read"
  # Load-bearing: without the suppression the suite would clone three real remotes, and
  # the promise that it never touches the network would break silently.
  assert_nogrep "$cw" '^## Codex'      "the Codex default is suppressed"
  assert_nogrep "$cw" '^## OMP'        "the OMP default is suppressed"
  rm -rf "$root"
}

test_changelog_dedupe_is_scoped_to_the_release(){
  echo "# changelog dedupe: repeated headings and bullets across releases survive, a re-inserted release does not"
  command -v git >/dev/null 2>&1 || { echo "  skip - git not available"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  local up="$root/upstream"; mkdir -p "$up"
  ( cd "$up" && git init -q && git config user.email t@t.invalid && git config user.name t
    printf '# Changelog\n\n## [2.0.0]\n\n### Fixed\n\n- Fixed a crash\n' > CHANGELOG.md
    git add CHANGELOG.md
    GIT_AUTHOR_DATE="2020-01-02T10:00:00" GIT_COMMITTER_DATE="2020-01-02T10:00:00" git commit -q -m 'chore: 2.0.0'
    # Edited again in the same window: 2.0.0 is re-inserted by the second diff.
    printf '# Changelog\n\n## [2.0.0]\n\n### Fixed\n\n- Fixed a crash\n- Fixed a hang\n' > CHANGELOG.md
    git add CHANGELOG.md
    GIT_AUTHOR_DATE="2020-01-02T11:00:00" GIT_COMMITTER_DATE="2020-01-02T11:00:00" git commit -q -m 'chore: 2.0.0 again'
    # A second release with the SAME heading and the SAME bullet text.
    printf '# Changelog\n\n## [2.1.0]\n\n### Fixed\n\n- Fixed a crash\n\n## [2.0.0]\n\n### Fixed\n\n- Fixed a crash\n- Fixed a hang\n' > CHANGELOG.md
    git add CHANGELOG.md
    GIT_AUTHOR_DATE="2020-01-02T12:00:00" GIT_COMMITTER_DATE="2020-01-02T12:00:00" git commit -q -m 'chore: 2.1.0' )
  export AUTODREAM_CHANGELOG=1 CHANGELOG_REMOTE="$up" CLAUDE_CODE_REPO="$root/cache/cc"
  run_dream "$root"
  unset AUTODREAM_CHANGELOG CHANGELOG_REMOTE CLAUDE_CODE_REPO
  local cw="$(fdir "$root")/changelog-window.md"
  assert_eq "$(grep -c '^## \[2.0.0\]' "$cw")" "1" "a release re-inserted by later commits is listed once"
  assert_eq "$(grep -c '^- Fixed a crash$' "$cw")" "2" "the same bullet under two different releases is kept under both"
  assert_eq "$(grep -c '^### Fixed$' "$cw")" "2" "the same sub-heading under two different releases is kept under both"
  assert_eq "$(grep -c '^- Fixed a hang$' "$cw")" "1" "a bullet repeated within one release is listed once"
  rm -rf "$root"
}

test_changelog_survives_a_force_pushed_remote(){
  echo "# a cache follows a remote whose history was rewritten (the OMP fork is rebased on every sync)"
  command -v git >/dev/null 2>&1 || { echo "  skip - git not available"; return 0; }
  # The cache must live inside the install's cache dir: only a cache this install owns follows a
  # rewritten remote, and a repo outside it keeps the conservative pull.
  local root; root=$(setup_env); mk_session "$root" sess1
  local up="$root/upstream"; mkdir -p "$up"
  ( cd "$up" && git init -q && git config user.email t@t.invalid && git config user.name t
    printf '# Changelog\n\n## [1.0.0]\n\n- First history\n' > CHANGELOG.md
    git add CHANGELOG.md
    GIT_AUTHOR_DATE="2020-01-02T10:00:00" GIT_COMMITTER_DATE="2020-01-02T10:00:00" git commit -q -m 'chore: first' )
  export AUTODREAM_CHANGELOG=1 CHANGELOG_REMOTE="$up" CLAUDE_CODE_REPO="$root/autodream/cache/cc"
  run_dream "$root"
  # Rewrite the history: a different root commit on the same branch, so the cache cannot
  # fast-forward to it.
  local br; br=$(git -C "$up" symbolic-ref --short HEAD)
  ( cd "$up" && git checkout -q --orphan rewritten && git rm -q -rf . >/dev/null 2>&1
    printf '# Changelog\n\n## [1.0.1]\n\n- Rewritten history\n' > CHANGELOG.md
    git add CHANGELOG.md
    GIT_AUTHOR_DATE="2020-01-02T10:30:00" GIT_COMMITTER_DATE="2020-01-02T10:30:00" git commit -q -m 'chore: rewritten'
    git branch -q -M "$br" )
  AUTODREAM_FORCE=1 run_dream "$root"
  unset AUTODREAM_CHANGELOG CHANGELOG_REMOTE CLAUDE_CODE_REPO
  local cw="$(fdir "$root")/changelog-window.md"
  assert_grep   "$cw" 'Rewritten history' "the second run reads the rewritten history"
  assert_nogrep "$cw" 'pull failed'       "and does not report a failed pull"
  rm -rf "$root"
}

test_autodream_now_from_a_checkout_uses_the_default_install(){
  echo "# autodream-now.sh run from the repo must not adopt bin/ as its install dir"
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$T/home/.claude/autodream"
  local out
  out=$(HOME="$T/home" bash "$REPO/bin/autodream-now.sh" 2020-01-02 --dry-run 2>&1)
  if printf '%s' "$out" | grep -q "$T/home/.claude/autodream/"; then
    ok "the dry run targets the default install dir"
  else
    no "the dry run targets the default install dir (got: $(printf '%s' "$out" | head -2))"
  fi
  if [ -d "$REPO/bin/logs" ]; then
    no "autodream-now.sh created bin/logs inside the checkout"
  else
    ok "nothing was created inside the repo's bin/"
  fi
  rm -rf "$T"
}

test_prune_helper(){
  echo "# prune-self-sessions helper: list / filter / delete"
  local PR="$REPO/bin/prune-self-sessions.sh"
  [ -x "$PR" ] || { no "prune helper executable"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$root/projects/-Users-x"
  local self="$root/projects/-Users-x/self.jsonl" real="$root/projects/-Users-x/real.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"Session transcript to analyze (literal absolute path): /x"}}\n' > "$self"
  printf '{"type":"user","message":{"role":"user","content":"fix the bug in foo.ts"}}\n' > "$real"

  local out; out=$(PROJECTS_DIR="$root/projects" "$PR")
  case "$out" in *self.jsonl*) ok "list includes the self session" ;; *) no "list includes the self session (got [$out])" ;; esac
  case "$out" in *real.jsonl*) no "list must exclude the real session" ;; *) ok "list excludes the real session" ;; esac

  printf '%s\n%s\n' "$self" "$real" | "$PR" --filter > "$root/filtered.txt"
  assert_grep   "$root/filtered.txt" 'real.jsonl' "filter keeps the real session"
  assert_nogrep "$root/filtered.txt" 'self.jsonl' "filter drops the self session"

  PROJECTS_DIR="$root/projects" "$PR" --delete >/dev/null
  assert_no_file "$self" "self session deleted"
  assert_file    "$real" "real session kept"
  rm -rf "$root"
}

test_self_session_excluded(){
  echo "# autodream's own transcripts are excluded from triage"
  local root; root=$(setup_env); mk_session "$root" real1
  local sf="$root/projects/proj-a/selfworker.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"SESSION_PATH=/Users/x/.claude/projects/foo/bar.jsonl"}}\n{"type":"assistant"}\n' > "$sf"
  touch -t "$STAMP" "$sf"
  run_dream "$root"
  local hr hs; hr=$(hash_of "$root/projects/proj-a/real1.jsonl"); hs=$(hash_of "$sf")
  assert_file    "$(fdir "$root")/$hr.json" "real session triaged"
  assert_no_file "$(fdir "$root")/$hs.json" "self-session excluded (no findings JSON)"
  assert_grep    "$root/run.out" 'excluded 1 autodream-own' "run log reports the exclusion"
  rm -rf "$root"
}

test_skip_empty_sessions(){
  echo "# 0-turn shell sessions are skipped before fanout"
  local root; root=$(setup_env); mk_session "$root" real1
  # an auto-opened/aborted shell: a single ai-title line, no user turn at all
  local empty="$root/projects/proj-a/shell.jsonl"
  printf '{"type":"ai-title","title":"some tab title"}\n' > "$empty"
  touch -t "$STAMP" "$empty"
  run_dream "$root"
  local hr he; hr=$(hash_of "$root/projects/proj-a/real1.jsonl"); he=$(hash_of "$empty")
  assert_file    "$(fdir "$root")/$hr.json" "real session triaged"
  assert_no_file "$(fdir "$root")/$he.json" "empty shell skipped (no findings JSON)"
  assert_grep    "$(fdir "$root")/run-stats.txt" 'sessions_skipped_empty: 1' "stats record the empty skip"
  assert_grep    "$(fdir "$root")/run-stats.txt" 'sessions_triaged: 1'        "stats record one triaged"
  assert_grep    "$root/run.out" 'skipped 1 empty' "run log reports the empty skip"
  rm -rf "$root"
}

test_skip_empty_disabled(){
  echo "# AUTODREAM_SKIP_EMPTY=0 keeps 0-turn shells in the triage set"
  local root; root=$(setup_env)
  local empty="$root/projects/proj-a/shell.jsonl"
  printf '{"type":"ai-title","title":"some tab title"}\n' > "$empty"
  touch -t "$STAMP" "$empty"
  export AUTODREAM_SKIP_EMPTY=0; run_dream "$root"; unset AUTODREAM_SKIP_EMPTY
  assert_grep "$(fdir "$root")/run-stats.txt" 'sessions_skipped_empty: 0' "no skips when disabled"
  assert_grep "$(fdir "$root")/run-stats.txt" 'sessions_triaged: 1'        "shell still triaged when disabled"
  rm -rf "$root"
}

test_l1_retry(){
  echo "# L1 retries a flaky session and completes it on a later round"
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=l1_flaky AUTODREAM_L1_ROUNDS=3; run_dream "$root"; unset MOCK_MODE AUTODREAM_L1_ROUNDS
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_file "$(fdir "$root")/$h.json"  "flaky session produced findings on retry"
  assert_grep "$root/run.out" 'round 2'  "a second L1 round ran"
  assert_file "$root/dreams/$DATE.md"    "report still produced"
  rm -rf "$root"
}

test_idempotency_guard(){
  echo "# existing report short-circuits the run (launchd catch-up no-op)"
  local root; root=$(setup_env); mk_session "$root" sess1
  printf 'SENTINEL REPORT' > "$root/dreams/$DATE.md"
  run_dream "$root"
  assert_eq   "$(cat "$root/dreams/$DATE.md")" "SENTINEL REPORT" "existing report left untouched"
  assert_grep "$root/run.out" 'already exists' "run logged the skip"
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_no_file "$(fdir "$root")/$h.json" "no L1 work done when report already exists"
  rm -rf "$root"
}

test_idempotency_guard_needs_a_complete_report(){
  echo "# a marker-less report at the path is not done: the guard rebuilds it (#111)"
  local root; root=$(setup_env); mk_session "$root" sess1
  # AUTODREAM_MARKER_EPOCH at the fixture date makes DATE a day whose report must carry the
  # marker. Without it DATE predates the default epoch and an unmarked report is a legacy one.
  printf '# Autodream\n\nhalf a report, killed before the marker\n' > "$root/dreams/$DATE.md"
  AUTODREAM_MARKER_EPOCH="$DATE" run_dream "$root"
  assert_grep "$root/run.out" 'lacks the open-questions marker' "run logged why the guard did not skip"
  assert_nogrep "$root/run.out" 'nothing to do' "the guard did not treat the partial as done"
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_file "$(fdir "$root")/$h.json" "L1 ran for the date"
  assert_grep "$root/dreams/$DATE.md" 'autodream:open-questions=' "the rebuilt report carries the marker"
  assert_nogrep "$root/dreams/$DATE.md" 'half a report' "the partial was replaced"
  # A complete report is still a no-op under the same epoch.
  printf 'DONE REPORT\n<!-- autodream:open-questions=0 -->\n' > "$root/dreams/$DATE.md"
  AUTODREAM_MARKER_EPOCH="$DATE" run_dream "$root"
  assert_grep "$root/dreams/$DATE.md" 'DONE REPORT' "a complete report is left untouched"
  assert_grep "$root/run.out" 'nothing to do' "and the guard skipped"
  rm -rf "$root"
}

lock_dir(){ printf '%s' "$1/autodream/locks/run-$DATE.lock"; }   # the per-date run lock for a root
mk_lock(){ # $1=root $2=pid -> a lock directory held by that pid (with its real start time when ps can say)
  local d; d=$(lock_dir "$1"); mkdir -p "$d"
  printf '%s\n' "$2" > "$d/pid"
  ps -o lstart= -p "$2" 2>/dev/null | tr -s ' ' > "$d/start" || true
}

test_run_lock_is_per_date_and_live_holders_win(){
  echo "# a second run for a date does not start while a live run holds the date's lock (#55)"
  local root; root=$(setup_env); mk_session "$root" sess1
  sleep 120 & local holder=$!
  mk_lock "$root" "$holder"
  run_dream "$root"
  local rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  assert_grep "$root/run.out" 'holds the lock' "the run said another run holds the lock"
  assert_no_file "$(fdir "$root")/sessions.txt" "it did not touch the findings dir"
  assert_no_file "$root/dreams/$DATE.md" "and wrote no report"
  assert_eq "$(cat "$(lock_dir "$root")/pid")" "$holder" "the holder's lock was left alone"
  rm -rf "$root"
}

test_run_lock_is_reclaimed_from_a_dead_holder(){
  echo "# a lock left by a killed run is reclaimed, and the run releases its own lock"
  local root; root=$(setup_env); mk_session "$root" sess1
  true & local dead=$!; wait "$dead" 2>/dev/null
  mk_lock "$root" "$dead"
  run_dream "$root"
  assert_nogrep "$root/run.out" 'holds the lock' "a dead holder does not block the run"
  assert_file "$root/dreams/$DATE.md" "the run produced its report"
  assert_no_file "$(lock_dir "$root")" "and released the lock when it finished"
  # An unrelated live process that reuses the pid is not the holder: the start time differs.
  if [ -n "$(ps -o lstart= -p $$ 2>/dev/null)" ]; then
    sleep 120 & local other=$!
    mk_lock "$root" "$other"; printf 'Mon Jan  1 00:00:00 1990\n' > "$(lock_dir "$root")/start"
    rm -f "$root/dreams/$DATE.md"
    run_dream "$root"
    kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
    assert_nogrep "$root/run.out" 'holds the lock' "a live pid with a different start time is a stale lock"
    assert_file "$root/dreams/$DATE.md" "and the run went ahead"
  fi
  rm -rf "$root"
}

test_killed_run_temps_are_swept_at_the_start_of_the_next_run(){
  echo "# a temp left by a killed adapter is removed by the next run, and nothing else is (#57)"
  local root; root=$(setup_env); mk_session "$root" sess1
  local fd; fd=$(fdir "$root"); mkdir -p "$fd"
  printf 'partial' > "$fd/0123456789ab.stats.json.tmp.Ab12Cd"
  printf 'partial' > "$fd/0123456789ab.slim.jsonl.tmp.Zz9Yx8"
  printf 'partial' > "$fd/0123456789ab.slim.jsonl.pre.jsonl"
  printf '{"keep":1}\n' > "$fd/0123456789ab.tmp.json"
  run_dream "$root"
  assert_no_file "$fd/0123456789ab.stats.json.tmp.Ab12Cd" "the stats temp is gone"
  assert_no_file "$fd/0123456789ab.slim.jsonl.tmp.Zz9Yx8" "the slim temp is gone"
  assert_no_file "$fd/0123456789ab.slim.jsonl.pre.jsonl" "slim's own .pre.jsonl is gone"
  assert_file "$fd/0123456789ab.tmp.json" "a file that only looks similar is left alone"
  assert_grep "$root/run.out" 'removed 3 temp file' "the log counts what it removed"
  rm -rf "$root"
}

test_normalize_project(){
  echo "# project field is normalized deterministically from the session path"
  command -v python3 >/dev/null 2>&1 || { echo "  skip - python3 not available"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=l1_badproject; run_dream "$root"; unset MOCK_MODE
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  local fj="$(fdir "$root")/$h.json"
  assert_file   "$fj" "findings JSON written"
  assert_nogrep "$fj" 'WRONG-PROJECT'     "model's wrong project value was overwritten"
  assert_grep   "$fj" '"project": "proj-a"' "project normalized to the session dir basename"
  assert_grep   "$root/run.out" 'normalized project field' "run log reports normalization"
  # l1_badproject emits the pre-pilot JSON shape (no facet fields) — the report
  # landing proves L2 still accepts legacy findings.
  assert_file   "$root/dreams/$DATE.md" "L2 completed on facet-free legacy findings"
  rm -rf "$root"
}

test_slim_transcript(){
  echo "# slim-transcript bounds an oversized transcript"
  local SL="$REPO/bin/slim-transcript.sh"
  [ -x "$SL" ] || { no "slim-transcript executable"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  local big="$root/big.jsonl" out="$root/slim.jsonl"
  # 3000 lines × ~3000 chars ≈ 9 MB
  awk 'BEGIN{ b=""; for(i=0;i<3000;i++) b=b "x"; for(n=0;n<3000;n++) print "{\"n\":" n ",\"blob\":\"" b "\"}" }' > "$big"
  "$SL" "$big" "$out"
  local osz; osz=$(wc -c < "$out" | tr -d ' ')
  [ "$osz" -lt 300000 ] && ok "slimmed far below original ($osz bytes < 300k, orig ~9M)" || no "slim output too big ($osz)"
  assert_grep "$out" 'elided by autodream'     "elides the middle"
  assert_grep "$out" 'slimmed this transcript' "appends the slim note"
  rm -rf "$root"
}

test_facet_fields_plumbed(){
  echo "# pilot facet fields flow L1 -> findings JSON -> L2 input"
  # Plumbing only: the L2 mock ignores findings content, so assertions stop at
  # the findings JSON L2 reads. Behavioral quality is the production pilot's job.
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local h j; h=$(hash_of "$root/projects/proj-a/sess1.jsonl"); j="$(fdir "$root")/$h.json"
  assert_eq "$(jq -r .outcome "$j")"                          "fully_achieved" "outcome facet present in findings JSON"
  assert_eq "$(jq -r .satisfaction_signals.satisfied "$j")"   "1"              "satisfaction_signals present"
  assert_eq "$(jq -e 'has("underlying_goal")' "$j")"          "true"           "underlying_goal key present (null allowed)"
  assert_eq "$(jq -r '.instructions_given[0]' "$j")"          "always run tests after edits" "instructions_given present"
  assert_file "$root/dreams/$DATE.md" "L2 run completed with facet-bearing findings as input"
  rm -rf "$root"
}

test_noise_gate_trivial(){
  echo "# noise gate: a trivial (1-user-turn) session is stubbed, not sent to the model"
  local root; root=$(setup_env)
  mk_session "$root" real1
  mk_trivial_session "$root" trivial1
  export MOCK_CALL_LOG="$root/calls.log"
  run_dream "$root"
  unset MOCK_CALL_LOG
  local hr ht
  hr=$(hash_of "$root/projects/proj-a/real1.jsonl")
  ht=$(hash_of "$root/projects/proj-a/trivial1.jsonl")
  assert_file    "$(fdir "$root")/$ht.json"     "gated session still got a findings JSON (the stub)"
  # Whitespace-tolerant like test_incomplete: the project-field normalization
  # pass rewrites this stub via json.dump (it has a real session_path + no
  # project), reformatting "skipped":"below_noise_gate" -> "skipped": "..." etc.
  assert_grep    "$(fdir "$root")/$ht.json"     '"skipped": *"below_noise_gate"' "gated stub carries the skip reason"
  assert_grep    "$(fdir "$root")/$ht.json"     '"findings": *\[\]'              "gated stub has an empty findings array"
  assert_no_file "$(fdir "$root")/$ht.json.err" "no .err for a gated session (clean skip, not a failure)"
  assert_grep    "$root/calls.log" "$hr" "model was called for the real session"
  assert_nogrep  "$root/calls.log" "$ht" "model was NOT called for the gated session"
  rm -rf "$root"
}

test_noise_gate_short_duration(){
  echo "# noise gate: duration alone gates even with enough user turns"
  local root; root=$(setup_env)
  mk_short_duration_session "$root" short1
  run_dream "$root"
  local h; h=$(hash_of "$root/projects/proj-a/short1.jsonl")
  assert_grep "$(fdir "$root")/$h.json" '"skipped": *"below_noise_gate"' "short-duration session gated despite 2 user turns"
  rm -rf "$root"
}

test_noise_gate_subagent_carveout(){
  echo "# noise gate: subagent / high-tool-count sessions are never gated"
  local root; root=$(setup_env)
  mk_subagent_session "$root" subagent1
  run_dream "$root"
  local h; h=$(hash_of "$root/projects/proj-a/subagent1.jsonl")
  assert_nogrep "$(fdir "$root")/$h.json" 'below_noise_gate' "subagent session was not gated"
  assert_grep   "$(fdir "$root")/$h.json" 'fully_achieved'    "subagent session got real findings from the model"
  rm -rf "$root"
}

test_noise_gate_stats(){
  echo "# noise gate: gated count in run-stats.txt; precache count stays truthful alongside gating"
  local root; root=$(setup_env)
  mk_session "$root" real1
  mk_trivial_session "$root" trivial1
  mk_session "$root" cached1
  local hc; hc=$(hash_of "$root/projects/proj-a/cached1.jsonl")
  mkdir -p "$(fdir "$root")"
  printf '{"session_path":"CACHED","findings":[]}' > "$(fdir "$root")/$hc.json"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'gated: 1'                        "gated count recorded"
  assert_grep "$stats" 'sessions_triaged: 3'              "all three sessions counted as triaged"
  assert_grep "$stats" 'l1_sessions_already_done_at_start: 1' "precache count unaffected by gating (only cached1 was precached)"
  local ht; ht=$(hash_of "$root/projects/proj-a/trivial1.jsonl")
  assert_grep "$(fdir "$root")/$ht.json" 'below_noise_gate' "gated session got the stub"
  rm -rf "$root"
}

test_noise_gate_env_override(){
  echo "# noise gate: AUTODREAM_MIN_USER_TURNS override changes the threshold"
  local root; root=$(setup_env)
  mk_trivial_session "$root" trivial1
  export AUTODREAM_MIN_USER_TURNS=1
  run_dream "$root"
  unset AUTODREAM_MIN_USER_TURNS
  local h; h=$(hash_of "$root/projects/proj-a/trivial1.jsonl")
  assert_nogrep "$(fdir "$root")/$h.json" 'below_noise_gate' "lowering the threshold keeps the 1-turn session out of the gate"
  rm -rf "$root"
}

test_oversized_gate_zero(){
  echo "# oversized gate (#12 measurement): both keys present at 0 on a normal run"
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'oversized_total: 0'   "no oversized sessions under the default threshold"
  assert_grep "$stats" 'oversized_errored: 0' "no oversized-errored sessions under the default threshold"
  rm -rf "$root"
}

test_oversized_gate_total(){
  echo "# oversized gate (#12 measurement): a session over a lowered AUTODREAM_SLIM_BYTES counts as oversized"
  local root; root=$(setup_env); mk_session "$root" sess1
  # mk_session's fixture is 205 bytes; a threshold of 100 puts it over the line
  # without needing a multi-KB fixture. slim-transcript.sh also fires at this
  # size (harmless — the mock still writes findings regardless of readpath).
  export AUTODREAM_SLIM_BYTES=100
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'oversized_total: 1'   "one session counted as oversized"
  assert_grep "$stats" 'oversized_errored: 0' "the oversized session still triaged cleanly (no error key)"
  rm -rf "$root"
}

test_oversized_gate_errored(){
  echo "# oversized gate (#12 measurement): an oversized session that still errors is paired correctly"
  local root; root=$(setup_env); mk_session "$root" sess1
  # Force the final-round metadata stub (carries a top-level "error" key) on an
  # oversized session, and verify oversized_errored pairs the right hash's
  # stats sidecar to the right findings JSON (not just a raw count).
  export AUTODREAM_SLIM_BYTES=100 MOCK_MODE=l1_incomplete AUTODREAM_L1_ROUNDS=1
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES MOCK_MODE AUTODREAM_L1_ROUNDS
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'oversized_total: 1'   "the incomplete session still counted as oversized"
  assert_grep "$stats" 'oversized_errored: 1' "its final-round error stub is paired and counted"
  rm -rf "$root"
}

test_stats_sidecar_ok(){
  echo "# sidecar health (#27): a normal run reports zero unparseable sidecars"
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'stats_sidecars_unparseable: 0' "healthy sidecars report a real zero"
  rm -rf "$root"
}

test_stats_sidecar_missing_counted(){
  echo "# sidecar health (#27): a session-stats.sh that never runs is counted, not silently absorbed"
  local root; root=$(setup_env)
  mk_session "$root" sess1
  mk_session "$root" sess2
  # compute_session_stats deletes and regenerates every sidecar each run, so the
  # only way to force the broken-sidecar path is to break the generator itself.
  export AUTODREAM_STATS_BIN="$root/does-not-exist.sh"
  run_dream "$root"
  unset AUTODREAM_STATS_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'stats_sidecars_unparseable: 2' "both missing sidecars counted"
  rm -rf "$root"
}

test_stats_sidecar_missing_keeps_oversized_count(){
  echo "# sidecar health (#27): an oversized session does NOT vanish from oversized_total when its sidecar is missing"
  local root; root=$(setup_env); mk_session "$root" sess1
  # This is the issue's exact reproduction: a genuinely oversized session whose
  # sidecar never got written used to drop straight out of oversized_total, the
  # counter that gates #12, with nothing recording that it happened.
  export AUTODREAM_SLIM_BYTES=100 AUTODREAM_STATS_BIN="$root/does-not-exist.sh"
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES AUTODREAM_STATS_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'oversized_total: 1'            "oversized session still counted via the live-size fallback"
  assert_grep "$stats" 'stats_sidecars_unparseable: 1' "and the sidecar failure is recorded alongside it"
  rm -rf "$root"
}

test_stats_sidecar_malformed_counted(){
  echo "# sidecar health (#27): a sidecar that is a valid object but has no usable transcript_bytes is counted"
  local root; root=$(setup_env); mk_session "$root" sess1
  # compute_session_stats only validates `type == "object"`, so this stub survives
  # generation intact and breaks at read time instead — the quieter of the two paths.
  local stub="$root/stats-no-bytes.sh"
  printf '%s\n' '#!/bin/bash' 'printf %s "{\"user_message_count\":5,\"tool_call_count\":9}" > "$2"' > "$stub"
  chmod +x "$stub"
  export AUTODREAM_SLIM_BYTES=100 AUTODREAM_STATS_BIN="$stub"
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES AUTODREAM_STATS_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'stats_sidecars_unparseable: 1' "missing transcript_bytes counts as unparseable"
  assert_grep "$stats" 'oversized_total: 1'            "oversized session still counted via the live-size fallback"
  rm -rf "$root"
}

test_stats_sidecar_non_numeric_counted(){
  echo "# sidecar health (#27): a non-numeric transcript_bytes is counted, not clamped to 0 in silence"
  local root; root=$(setup_env); mk_session "$root" sess1
  local stub="$root/stats-bad-bytes.sh"
  printf '%s\n' '#!/bin/bash' 'printf %s "{\"transcript_bytes\":\"lots\"}" > "$2"' > "$stub"
  export AUTODREAM_STATS_BIN="$stub"
  chmod +x "$stub"
  run_dream "$root"
  unset AUTODREAM_STATS_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'stats_sidecars_unparseable: 1' "a string transcript_bytes is not a measurement"
  rm -rf "$root"
}

test_runner_provenance(){
  echo "# runner provenance (#29): run-stats.txt records which code produced it"
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  # The suite runs run.sh from the repo checkout, so HEAD resolves and the stamp must be
  # the real short SHA rather than the "unknown" degradation path.
  local head; head=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)
  assert_grep "$stats" "runner_commit: $head" "stamps the commit the runner was checked out at"
  assert_grep "$stats" 'runner_dirty: \(yes\|no\)' "records whether the tree had uncommitted changes"
  assert_grep "$root/run.out" "runner: $head" "run log names the runner up front"
  rm -rf "$root"
}

test_runner_provenance_no_git(){
  echo "# runner provenance (#29): a non-git install degrades to unknown, never fails the run"
  local root; root=$(setup_env); mk_session "$root" sess1
  # Copy the scripts out of the repo so SCRIPT_DIR resolves somewhere with no git
  # history at all — the tarball-install case, which must still produce a report.
  local bin="$root/bin"; mkdir -p "$bin"
  cp "$REPO"/bin/*.sh "$bin/"
  AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
  bash "$bin/run.sh" "$DATE" > "$root/run.out" 2>&1
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'runner_commit: unknown' "no git history degrades to unknown"
  assert_grep "$stats" 'runner_dirty: no'       "dirty is not claimed when the commit is unknown"
  assert_file "$root/dreams/$DATE.md"           "the run still produced a report"
  rm -rf "$root"
}

test_runner_provenance_through_symlink(){
  echo "# runner provenance (#29): the installed symlink layout still stamps the repo's sha"
  local root; root=$(setup_env); mk_session "$root" sess1
  # Reproduce what install.sh actually leaves on disk, which is what the earlier tests
  # missed: ~/.claude/autodream is a REAL directory holding one symlink per script, not a
  # symlink to the checkout. `cd "$(dirname "$0")"` therefore lands in a directory with no
  # .git, and provenance has to follow the file's own link to find the working tree.
  # Six production runs through 2026-08-03 stamped "unknown" against a clean checkout.
  local f; for f in "$REPO"/bin/*.sh; do ln -sf "$f" "$root/autodream/$(basename "$f")"; done
  AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
  AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
  /bin/bash "$root/autodream/run.sh" "$DATE" > "$root/run.out" 2>&1
  local head; head=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" "runner_commit: $head" "a symlinked runner reports the checkout it points at"
  assert_file "$root/dreams/$DATE.md"          "the run still produced a report"
  rm -rf "$root"
}

test_runner_provenance_relative_symlink(){
  echo "# runner provenance (#29): a symlink with a relative target still finds the checkout"
  command -v python3 >/dev/null 2>&1 || { echo "  skip - python3 not available"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  # install.sh writes absolute targets, so nothing in production exercises the walk's
  # relative-target branch. A hand-rolled install (ln -s ../../git/oss/cc-autodream/bin/…)
  # produces one, and a target resolved against $PWD instead of the link's own directory
  # silently lands nowhere.
  # Both sides must be physical paths before relpath: on macOS $TMPDIR sits under /var,
  # which is itself a link to /private/var, so a relative path computed from the logical
  # name walks up through a directory that does not exist and the link is born broken.
  local phys_ad phys_bin rel
  phys_ad=$(cd "$root/autodream" && pwd -P)
  phys_bin=$(cd "$REPO/bin" && pwd -P)
  rel=$(python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1],sys.argv[2]))' "$phys_bin" "$phys_ad")
  local f; for f in "$REPO"/bin/*.sh; do ln -sf "$rel/$(basename "$f")" "$root/autodream/$(basename "$f")"; done
  AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
  AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
  /bin/bash "$root/autodream/run.sh" "$DATE" > "$root/run.out" 2>&1
  local head; head=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)
  assert_grep "$(fdir "$root")/run-stats.txt" "runner_commit: $head" "a relative link target resolves against the link's own dir"
  assert_file "$root/dreams/$DATE.md" "the run still produced a report"
  rm -rf "$root"
}

test_runner_provenance_unresolvable_chain(){
  echo "# runner provenance (#29): a chain past the hop cap says unknown, never a wrong sha"
  local root; root=$(setup_env); mk_session "$root" sess1
  local f; for f in "$REPO"/bin/*.sh; do ln -sf "$f" "$root/autodream/$(basename "$f")"; done
  # A chain longer than the cap leaves the walk holding a path that is still a symlink.
  # Resolving it anyway would stamp the sha of whatever checkout that truncated path sits
  # in — here, this very repo, which is exactly the plausible-but-wrong answer #29 exists
  # to rule out. 12 hops clears the cap of 8 while staying under macOS's ELOOP limit of 16,
  # so bash still executes the script and only the provenance field degrades.
  local prev="$REPO/bin/run.sh" i
  for i in $(seq 1 12); do
    ln -sf "$prev" "$root/autodream/hop-$i.sh"
    prev="$root/autodream/hop-$i.sh"
  done
  ln -sf "$prev" "$root/autodream/run.sh"
  AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
  AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
  /bin/bash "$root/autodream/run.sh" "$DATE" > "$root/run.out" 2>&1
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'runner_commit: unknown' "an unresolved chain degrades instead of guessing"
  assert_grep "$stats" 'runner_dirty: no'       "dirty is not claimed when the commit is unknown"
  assert_file "$root/dreams/$DATE.md"           "the run still produced a report"
  rm -rf "$root"
}

test_oversized_gate_script(){
  echo "# oversized-gate.sh (#29): recomputes the #12 window from artifacts, including dates whose run-stats.txt lacks the keys"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  export AUTODREAM_SLIM_BYTES=100
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES
  local fd; fd=$(fdir "$root")
  # Strip the keys to simulate a pre-#25 runner: the script must still recover the
  # numbers from the sidecars, which is the whole point of it existing.
  grep -v '^oversized_' "$fd/run-stats.txt" > "$fd/run-stats.tmp" && mv "$fd/run-stats.tmp" "$fd/run-stats.txt"
  assert_nogrep "$fd/run-stats.txt" 'oversized_total' "precondition: the keys really are gone"
  local out; out=$(AUTODREAM_SLIM_BYTES=100 bash "$GATE" "$fd" 2>&1)
  printf '%s' "$out" > "$root/gate.out"
  assert_grep "$root/gate.out" 'GATE CLOSED'  "a clean window reports the gate closed"
  assert_grep "$root/gate.out" '1 oversized'  "recovered the oversized count without run-stats.txt"
  assert_grep "$root/gate.out" 'rule of three' "quotes the upper bound rather than implying 0% is certain"
  rm -rf "$root"
}

test_oversized_gate_script_open(){
  echo "# oversized-gate.sh (#29): an errored oversized session pushes the window over the threshold"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  export AUTODREAM_SLIM_BYTES=100 MOCK_MODE=l1_incomplete AUTODREAM_L1_ROUNDS=1
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES MOCK_MODE AUTODREAM_L1_ROUNDS
  local out; out=$(AUTODREAM_SLIM_BYTES=100 bash "$GATE" "$(fdir "$root")" 2>&1)
  printf '%s' "$out" > "$root/gate.out"
  assert_grep "$root/gate.out" 'GATE OPEN'    "1 of 1 errored is 100%, well over the 5% threshold"
  rm -rf "$root"
}

test_oversized_gate_script_empty(){
  echo "# oversized-gate.sh (#29): an empty window is not reported as a measured 0%"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local out; out=$(bash "$GATE" "$(fdir "$root")" 2>&1)
  printf '%s' "$out" > "$root/gate.out"
  assert_grep  "$root/gate.out" 'nothing to measure' "no oversized sessions is not evidence either way"
  assert_nogrep "$root/gate.out" 'GATE CLOSED'       "and must not be reported as a closed gate"
  rm -rf "$root"
}

test_oversized_gate_script_args(){
  echo "# oversized-gate.sh (#29): argument validation, including the --days spin found in review"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  # `--days` with no value left $# at 1 while `shift 2` refused to shift, looping forever.
  # A hang in a nightly-adjacent script is worse than a wrong number, so it gets a test.
  # These are the only assertions in the suite that need GNU `timeout`. Stock macOS has
  # neither name; homebrew coreutils installs `gtimeout`, and `timeout` too if its gnubin
  # is on PATH. Resolve whichever exists and say so plainly when neither does — without
  # this, all four assertions come back as exit 127 and read like real regressions.
  local TO=""
  command -v timeout  >/dev/null 2>&1 && TO=timeout
  [ -n "$TO" ] || { command -v gtimeout >/dev/null 2>&1 && TO=gtimeout; }
  [ -n "$TO" ] || { no "oversized-gate arg tests need GNU timeout (brew install coreutils)"; return 0; }
  local out rc
  out=$( { "$TO" 10 bash "$GATE" --days; } 2>&1 ); rc=$?
  assert_eq "$rc" "2" "--days with no value exits 2 instead of hanging (124 would be the hang)"
  out=$( { "$TO" 10 bash "$GATE" --days abc; } 2>&1 ); rc=$?
  assert_eq "$rc" "2" "--days with a non-integer exits 2"
  out=$( { "$TO" 10 bash "$GATE" --days 0; } 2>&1 ); rc=$?
  assert_eq "$rc" "2" "--days 0 exits 2"
  out=$( { "$TO" 10 bash "$GATE" --bogus; } 2>&1 ); rc=$?
  assert_eq "$rc" "2" "an unknown option exits 2 rather than being read as a findings dir"
}

test_notify_count(){
  echo "# notify.sh counts from the open-questions marker, falling back to shape for older reports"
  local NOTIFY="$REPO/bin/notify.sh"
  [ -x "$NOTIFY" ] || { no "notify.sh executable"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  # Pre-seed an executable stub at the branded-notifier path so the test neither
  # bootstraps a real app bundle nor posts a real banner. OSA backup off for the same
  # reason; SUBL points at true so no editor opens.
  mkdir -p "$root/cc-autodream.app/Contents/MacOS"
  printf '#!/bin/sh\nexit 0\n' > "$root/cc-autodream.app/Contents/MacOS/terminal-notifier"
  chmod +x "$root/cc-autodream.app/Contents/MacOS/terminal-notifier"
  run_notify(){
    AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 SUBL=/usr/bin/true \
      "$NOTIFY" "$1" > "$root/notify.out" 2>&1
  }
  mk_report(){ # $1=date, stdin=Open questions section body
    local f="$root/$1.md"
    { printf '# Autodream — %s\n\n## Open questions for the user\n' "$1"; cat; printf '\n## Trailing section\n'; } > "$f"
    printf '%s' "$f"
  }

  # --- marker is authoritative, even when the section's shape says otherwise ---
  # This is the real 2026-07-24 shape: one numbered question, then a "dropped by the
  # gate" list. The old counter scored 6 here; the marker says 1.
  local f
  f=$(mk_report 2020-02-01 <<'EOF'
**One question survived the triviality gate.**

1. **A real question** — should we do the thing?

Other findings dropped by the gate:
- Pattern 1 already addressed on disk.
- Pattern 2 settled last week.
- Pattern 3 below threshold.
- Pattern 4 quarantined.

<!-- autodream:open-questions=1 -->
EOF
)
  run_notify "$f"
  assert_grep "$root/inbox/2020-02-01-open-questions.md" '^# 1 open question$' "marker wins over the 6 list lines in the section"

  # --- marker of 0 must stay silent even though the section has prose and bullets ---
  f=$(mk_report 2020-02-02 <<'EOF'
None that clear the triviality gate this run.

- Pattern 1 was already fixed on disk.
- Pattern 2 is under a standing moratorium.

<!-- autodream:open-questions=0 -->
EOF
)
  run_notify "$f"
  assert_no_file "$root/inbox/2020-02-02-open-questions.md" "marker=0 writes no inbox file despite a non-empty section"
  assert_grep "$root/notify.out" '0 open questions' "marker=0 reports zero"

  # --- no marker (pre-contract report): numbered items win over their sub-bullets ---
  f=$(mk_report 2020-02-03 <<'EOF'
1. First question?
   - supporting detail
   - more detail
2. Second question?
   - supporting detail
EOF
)
  run_notify "$f"
  assert_grep "$root/inbox/2020-02-03-open-questions.md" '^# 2 open questions$' "no marker: 2 items, not 5 list lines"

  # --- no marker: bold topic titles beat the bullets underneath them ---
  f=$(mk_report 2020-02-04 <<'EOF'
**Scrape skill guardrail**
- Update step 3?
- Add a step-6 check?

**TLS-bypass rule**
- Add a rule?
- Where should it live?
EOF
)
  run_notify "$f"
  assert_grep "$root/inbox/2020-02-04-open-questions.md" '^# 2 open questions$' "no marker: 2 titles, not 4 bullets"

  # --- no marker: plain bullets are the questions ---
  f=$(mk_report 2020-02-05 <<'EOF'
- Raise the fanout?
- Drop the cache?
EOF
)
  run_notify "$f"
  assert_grep "$root/inbox/2020-02-05-open-questions.md" '^# 2 open questions$' "no marker: plain bullets counted"

  # --- no marker: bare prose still pops, since a non-empty section has something to say ---
  f=$(mk_report 2020-02-06 <<'EOF'
Should the fanout be raised to 12 given the recent session volume?
EOF
)
  run_notify "$f"
  assert_grep "$root/inbox/2020-02-06-open-questions.md" '^# 1 open question$' "no marker: prose falls back to 1"

  # --- no marker: a "None ..." lead-in is zero, not a prose question ---
  # Without this case the prose tier turns every quiet pre-marker night into a false pop.
  f=$(mk_report 2020-02-07 <<'EOF'
None that clear the triviality gate this run.
EOF
)
  run_notify "$f"
  assert_no_file "$root/inbox/2020-02-07-open-questions.md" "no marker: a None lead-in stays silent"

  # --- genuinely empty section stays a quiet no-op ---
  f=$(mk_report 2020-02-08 </dev/null)
  run_notify "$f"
  assert_no_file "$root/inbox/2020-02-08-open-questions.md" "empty section writes nothing"
  assert_grep "$root/notify.out" '0 open questions' "empty section reports zero"

  rm -rf "$root"
}

test_notify_open_command(){
  echo "# notify.sh opens the inbox via AUTODREAM_OPEN (multi-word commands, deprecated SUBL alias)"
  local NOTIFY="$REPO/bin/notify.sh"
  [ -x "$NOTIFY" ] || { no "notify.sh executable"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$root/cc-autodream.app/Contents/MacOS"
  printf '#!/bin/sh\nexit 0\n' > "$root/cc-autodream.app/Contents/MacOS/terminal-notifier"
  chmod +x "$root/cc-autodream.app/Contents/MacOS/terminal-notifier"
  # A recorder standing in for an editor: logs every argument it was handed, one per
  # line, so the test can prove word-splitting and quoting rather than just exit status.
  printf '#!/bin/sh\nfor a in "$@"; do echo "$a"; done >> "%s/opened.log"\n' "$root" > "$root/fake-editor"
  chmod +x "$root/fake-editor"

  printf '# Autodream — 2020-03-01\n\n## Open questions for the user\n1. A question?\n\n<!-- autodream:open-questions=1 -->\n' \
    > "$root/2020-03-01.md"

  # single-word command
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 AUTODREAM_OPEN="$root/fake-editor" \
    "$NOTIFY" "$root/2020-03-01.md" > "$root/notify.out" 2>&1
  assert_grep "$root/opened.log" "2020-03-01-open-questions.md" "AUTODREAM_OPEN received the inbox path"
  assert_grep "$root/notify.out" 'opened .* with:' "log names the command it opened with"

  # multi-word command: the flag and the path must arrive as separate arguments
  : > "$root/opened.log"
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 AUTODREAM_OPEN="$root/fake-editor --flag" \
    "$NOTIFY" "$root/2020-03-01.md" > "$root/notify.out" 2>&1
  assert_grep "$root/opened.log" '^--flag$'    "multi-word command word-splits into its own argument"
  assert_eq "$(wc -l < "$root/opened.log" | tr -d ' ')" "2" "exactly two arguments: the flag and the path"

  # a path with a space must stay ONE argument, not split by sh -c
  : > "$root/opened.log"
  mkdir -p "$root/dir with space"
  printf '# Autodream — 2020-03-02\n\n## Open questions for the user\n1. A question?\n\n<!-- autodream:open-questions=1 -->\n' \
    > "$root/dir with space/2020-03-02.md"
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 AUTODREAM_OPEN="$root/fake-editor" \
    "$NOTIFY" "$root/dir with space/2020-03-02.md" > "$root/notify.out" 2>&1
  assert_eq "$(wc -l < "$root/opened.log" | tr -d ' ')" "1" "a spaced path arrives as a single argument"

  # SUBL still honored as the deprecated alias, so existing setups keep working
  : > "$root/opened.log"
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 SUBL="$root/fake-editor" \
    "$NOTIFY" "$root/2020-03-01.md" > "$root/notify.out" 2>&1
  assert_grep "$root/opened.log" "2020-03-01-open-questions.md" "deprecated SUBL alias still opens the file"

  # AUTODREAM_OPEN wins when both are set
  : > "$root/opened.log"
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 \
    AUTODREAM_OPEN="$root/fake-editor --winner" SUBL=/usr/bin/false \
    "$NOTIFY" "$root/2020-03-01.md" > "$root/notify.out" 2>&1
  assert_grep "$root/opened.log" '^--winner$' "AUTODREAM_OPEN takes precedence over SUBL"

  # a broken open command must not fail the run — the inbox file is the durable output
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 AUTODREAM_OPEN="$root/does-not-exist" \
    "$NOTIFY" "$root/2020-03-01.md" > "$root/notify.out" 2>&1
  assert_eq "$?" "0" "a failing open command still exits 0"
  assert_grep "$root/notify.out" 'failed to open' "and says so instead of pretending it opened"
  assert_file "$root/inbox/2020-03-01-open-questions.md" "inbox file written regardless"

  rm -rf "$root"
}

test_notify_dryrun(){
  echo "# notify.sh dry run reports the count without writing, posting, or opening anything"
  local NOTIFY="$REPO/bin/notify.sh"
  [ -x "$NOTIFY" ] || { no "notify.sh executable"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  # Deliberately NO stub notifier here. That is the whole point: a real sweep pointed
  # AUTODREAM_DIR at a temp dir and assumed that was enough, but with no branded bundle
  # present the resolution falls through to a system terminal-notifier and posts for
  # real. Dry run has to be safe without any stubbing at all.
  printf '#!/bin/sh\necho "$@" >> "%s/opened.log"\n' "$root" > "$root/fake-editor"
  chmod +x "$root/fake-editor"
  printf '# Autodream — 2020-04-01\n\n## Open questions for the user\n1. One?\n2. Two?\n\n<!-- autodream:open-questions=2 -->\n' \
    > "$root/2020-04-01.md"

  local out; out=$(AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_DRYRUN=1 AUTODREAM_OPEN="$root/fake-editor" \
    "$NOTIFY" "$root/2020-04-01.md" 2>&1)
  printf '%s' "$out" > "$root/dry.out"
  assert_grep    "$root/dry.out" 'dry run'          "says it was a dry run"
  assert_grep    "$root/dry.out" '2 open questions' "still reports the real count"
  assert_no_file "$root/inbox/2020-04-01-open-questions.md" "dry run writes no inbox file"
  assert_no_file "$root/opened.log"                 "dry run opens nothing"

  # And the same report without the flag DOES do the work, so the guard isn't just off.
  # NOW seed the stub notifier: this call reaches the posting code, and without a stub at
  # the branded path the resolution falls through to a system terminal-notifier and fires
  # a real banner. That is the very accident this feature exists to prevent, and writing
  # the test without the stub reproduced it — the suite posted a live notification for a
  # fixture dated 2020-04-01. The dry-run assertions above stay stub-free on purpose.
  mkdir -p "$root/cc-autodream.app/Contents/MacOS"
  printf '#!/bin/sh\nexit 0\n' > "$root/cc-autodream.app/Contents/MacOS/terminal-notifier"
  chmod +x "$root/cc-autodream.app/Contents/MacOS/terminal-notifier"
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 AUTODREAM_OPEN="$root/fake-editor" \
    "$NOTIFY" "$root/2020-04-01.md" > "$root/wet.out" 2>&1
  assert_file "$root/inbox/2020-04-01-open-questions.md" "without the flag the inbox file is written"
  assert_file "$root/opened.log"                         "without the flag the open command runs"

  # A zero-question report is quiet either way, and must not claim to be a dry run.
  printf '# Autodream — 2020-04-02\n\n## Open questions for the user\nNone that clear the gate.\n\n<!-- autodream:open-questions=0 -->\n' \
    > "$root/2020-04-02.md"
  out=$(AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_DRYRUN=1 "$NOTIFY" "$root/2020-04-02.md" 2>&1)
  printf '%s' "$out" > "$root/dry0.out"
  assert_grep   "$root/dry0.out" '0 open questions' "zero-count report still reports zero"
  assert_nogrep "$root/dry0.out" 'dry run'          "the zero path exits before the dry-run notice"

  rm -rf "$root"
}

test_runner_dirty_ignores_untracked(){
  echo "# runner_dirty (#29 follow-up): an untracked scratch file is not a dirty runner"
  local root; root=$(setup_env); mk_session "$root" sess1
  # A clean checkout with a stray untracked file reported runner_dirty: yes on the first
  # production run. Only tracked modifications mean "code that exists in nobody's history".
  local repo="$root/repo"; mkdir -p "$repo"
  cp -R "$REPO/bin" "$repo/bin"; cp -R "$REPO/prompts" "$repo/prompts"
  git -C "$repo" init -q 2>/dev/null
  git -C "$repo" add -A 2>/dev/null
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
  printf 'scratch\n' > "$repo/untracked-scratch.txt"
  AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
  bash "$repo/bin/run.sh" "$DATE" > "$root/run.out" 2>&1
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'runner_dirty: no' "an untracked file alone does not mark the runner dirty"

  # A tracked modification still does.
  printf '\n# tracked edit\n' >> "$repo/bin/session-stats.sh"
  rm -rf "$(fdir "$root")" "$root/dreams/$DATE.md"
  AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
  bash "$repo/bin/run.sh" "$DATE" > "$root/run2.out" 2>&1
  assert_grep "$(fdir "$root")/run-stats.txt" 'runner_dirty: yes' "a tracked modification still marks the runner dirty"
  rm -rf "$root"
}

test_overlap_pair(){
  echo "# overlap (#14): two alternating-close sessions count as ONE pair regardless of qualifying turn-pairs"
  local root; root=$(setup_env)
  # A: 10:00, 10:20   B: 10:05, 10:25 — every A/B turn combo is within 30 min
  # (A0-B0=5m, A0-B1=25m, A1-B0=15m, A1-B1=5m), so four turn-pairs qualify but
  # the {A,B} pair must be counted exactly once.
  mk_timed_session "$root" sessA "2020-01-02T12:00:00Z" "2020-01-02T12:20:00Z"
  mk_timed_session "$root" sessB "2020-01-02T12:05:00Z" "2020-01-02T12:25:00Z"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: yes'     "a real overlap measurement happened"
  assert_grep "$stats" 'overlap_events: 1'         "exactly one distinct pair counted"
  assert_grep "$stats" 'sessions_with_overlap: 2'  "both sessions counted as involved"
  rm -rf "$root"
}

test_overlap_triple(){
  echo "# overlap (#14): three pairwise-overlapping sessions -> 3 pairs, 3 sessions"
  local root; root=$(setup_env)
  # A@10:00, B@10:10, C@10:20 — every pair (A-B=10m, B-C=10m, A-C=20m) is within 30 min.
  mk_timed_session "$root" sessA "2020-01-02T12:00:00Z"
  mk_timed_session "$root" sessB "2020-01-02T12:10:00Z"
  mk_timed_session "$root" sessC "2020-01-02T12:20:00Z"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: yes'     "a real overlap measurement happened"
  assert_grep "$stats" 'overlap_events: 3'         "all three pairs counted"
  assert_grep "$stats" 'sessions_with_overlap: 3'  "all three sessions counted as involved"
  rm -rf "$root"
}

test_overlap_drops_advisor_sidecars(){
  echo "# overlap: an advisor sidecar inherits its parent's turns, so it is not paired (omp-autodream #16)"
  local d; d=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  # parent@10:00 and other@10:10 genuinely overlap. The advisor carries the parent's timestamps,
  # so counting it pairs it with both: 3 sessions and 3 events instead of 2 and 1.
  printf '{"user_turn_timestamps":[1784541600]}\n' > "$d/parent.stats.json"
  printf '{"user_turn_timestamps":[1784542200]}\n' > "$d/other.stats.json"
  printf '{"is_advisor":true,"user_turn_timestamps":[1784541600]}\n' > "$d/adv.stats.json"
  local out; out=$(bash "$REPO/bin/overlap-stats.sh" "$d")
  assert_eq "$(printf '%s' "$out" | jq -r .sessions_with_overlap)" "2" "the advisor is not counted as an overlapping session"
  assert_eq "$(printf '%s' "$out" | jq -r .overlap_events)" "1" "and forms no pairs"
  # A sidecar with no is_advisor field (every Claude sidecar, and every pre-2026-08-21 one) is kept:
  # the parent and other fixtures above omit it. An explicit false is kept too, which this adds.
  printf '{"is_advisor":false,"user_turn_timestamps":[1784541900]}\n' > "$d/third.stats.json"
  out=$(bash "$REPO/bin/overlap-stats.sh" "$d")
  assert_eq "$(printf '%s' "$out" | jq -r .sessions_with_overlap)" "3" "is_advisor false is kept"
  rm -rf "$d"
}

test_overlap_drops_nested_sidecars(){
  echo "# overlap: a nested worker overlaps its parent by construction, so it is not paired (#79)"
  local d; d=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  printf '{"user_turn_timestamps":[1784541600]}\n' > "$d/parent.stats.json"
  printf '{"user_turn_timestamps":[1784542200]}\n' > "$d/other.stats.json"
  printf '{"isSidechain":true,"user_turn_timestamps":[1784541660]}\n' > "$d/claudeworker.stats.json"
  printf '{"nested":true,"user_turn_timestamps":[1784541720]}\n' > "$d/ompchild.stats.json"
  local out; out=$(bash "$REPO/bin/overlap-stats.sh" "$d")
  assert_eq "$(printf '%s' "$out" | jq -r .sessions_with_overlap)" "2" "a sidechain and a nested session are not counted as overlapping"
  assert_eq "$(printf '%s' "$out" | jq -r .overlap_events)" "1" "and form no pairs"
  rm -rf "$d"
}

# One parent with a three-worker fanout (one worker two directories deeper, under a
# workflow), one lone top-level session, and one gated top-level session.
mk_fanout_fixture(){ # $1=root
  local root="$1" b="$1/projects/proj-a" f i
  mk_timed_session "$root" parent1 "2020-01-02T12:00:00Z" "2020-01-02T12:20:00Z"
  mk_timed_session "$root" lone1   "2020-01-02T15:00:00Z" "2020-01-02T15:20:00Z"
  mk_trivial_session "$root" gated1
  mkdir -p "$b/parent1/subagents/workflows/wf_x"
  for f in "$b/parent1/subagents/agent-a.jsonl" "$b/parent1/subagents/agent-b.jsonl" "$b/parent1/subagents/workflows/wf_x/agent-c.jsonl"; do
    i=${f##*/}
    printf '%s\n' \
      '{"type":"user","isSidechain":true,"timestamp":"2020-01-02T12:05:00Z","message":{"content":"worker task"}}' \
      '{"type":"assistant","isSidechain":true,"timestamp":"2020-01-02T12:05:05Z","message":{"content":[{"type":"tool_use","name":"Read"}]}}' > "$f"
    touch -t "$STAMP" "$f"
  done
  # A fanout whose parent file is gone still groups, under the path that file would have had.
  # 09:05Z is still 2020-01-02 in local time from UTC-5 to UTC+11, which a report day needs: the day
  # is local midnight to local midnight, and 18:05Z was already the next day in Hong Kong, Tokyo and
  # Sydney, so the window dropped these workers there. It stays hours away from the other sessions.
  mkdir -p "$b/orphan1/subagents"
  for f in "$b/orphan1/subagents/agent-x.jsonl" "$b/orphan1/subagents/agent-y.jsonl"; do
    printf '%s\n' \
      '{"type":"user","isSidechain":true,"timestamp":"2020-01-02T09:05:00Z","message":{"content":"worker task"}}' \
      '{"type":"assistant","isSidechain":true,"timestamp":"2020-01-02T09:05:05Z","message":{"content":[{"type":"tool_use","name":"Read"}]}}' > "$f"
    touch -t "$STAMP" "$f"
  done
}

test_fanout_stats(){
  echo "# activity snapshot: nested workers are counted apart from top-level sessions (#79)"
  local root; root=$(setup_env)
  mk_fanout_fixture "$root"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'sessions_top_level: 2'  "the two ungated top-level sessions"
  assert_grep "$stats" 'sessions_nested: 5'     "three workers under a parent, at both nesting depths, and two under a missing one"
  assert_grep "$stats" 'fanout_parents: 2'      "the workers belong to two parents, one of them gone"
  assert_grep "$stats" 'largest_fanout: 3'      "the fanout is three workers wide"
  # The workers' own timestamps (12:05) sit inside the parent's, and the lone session is hours away:
  # no cross-session concurrency, so the fanout must not read as multi-clauding.
  assert_grep "$stats" 'sessions_with_overlap: 0' "a fanout is not multi-clauding"
  local rows; rows=$(cat "$(fdir "$root")/fanouts.tsv" 2>/dev/null)
  assert_eq "$(printf '%s\n' "$rows" | grep -c .)" "5" "fanouts.tsv names each worker"
  assert_grep_str "$rows" "$(hash_of "$root/projects/proj-a/parent1/subagents/agent-a.jsonl")" "a worker is named by its findings hash"
  local ph; ph=$(hash_of "$root/projects/proj-a/parent1.jsonl")
  assert_eq "$(cut -f2 "$(fdir "$root")/fanouts.tsv" | sort | uniq -c | awk '{print $1}' | sort -n | tr '\n' ' ')" "2 3 " "workers group two and three to a parent"
  assert_eq "$(grep -c "$ph" "$(fdir "$root")/fanouts.tsv")" "3" "the three workers name the parent file as their parent"
  assert_eq "$(grep -c "$(hash_of "$root/projects/proj-a/orphan1.jsonl")" "$(fdir "$root")/fanouts.tsv")" "2" "and the two orphans name the path their parent would have had"
  assert_eq "$(cut -f1 "$(fdir "$root")/fanouts.tsv" | grep -c "$ph")" "0" "the parent is not a worker row"
  rm -rf "$root"
}

test_overlap_none(){
  echo "# overlap (#14): sessions more than 30 minutes apart -> both stats 0, keys still present"
  local root; root=$(setup_env)
  mk_timed_session "$root" sessA "2020-01-02T12:00:00Z"
  mk_timed_session "$root" sessB "2020-01-02T13:00:00Z"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  # This is the genuine-zero case (#26): the pass DID run, it just found nothing to
  # pair. overlap_measured must positively say so — that's the whole point of the fix,
  # distinguishing this from a pass that never ran.
  assert_grep "$stats" 'overlap_measured: yes'     "genuine zero overlap is still a real measurement"
  assert_grep "$stats" 'overlap_events: 0'         "no pairs when sessions are far apart"
  assert_grep "$stats" 'sessions_with_overlap: 0'  "no sessions involved when sessions are far apart"
  rm -rf "$root"
}

test_overlap_not_measured_missing_bin(){
  echo "# overlap (#26): AUTODREAM_OVERLAP_BIN pointed at a nonexistent path -> not measured, counts still 0"
  local root; root=$(setup_env)
  mk_timed_session "$root" sessA "2020-01-02T12:00:00Z"
  mk_timed_session "$root" sessB "2020-01-02T12:05:00Z"
  export AUTODREAM_OVERLAP_BIN="$root/does-not-exist.sh"; run_dream "$root"; unset AUTODREAM_OVERLAP_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: no'      "missing overlap-stats.sh binary is not a measurement"
  assert_grep "$stats" 'overlap_events: 0'          "count key still present at 0"
  assert_grep "$stats" 'sessions_with_overlap: 0'   "count key still present at 0"
  rm -rf "$root"
}

test_overlap_not_measured_empty_output(){
  echo "# overlap (#26): overlap-stats.sh stub that prints nothing -> not measured"
  local root; root=$(setup_env)
  mk_timed_session "$root" sessA "2020-01-02T12:00:00Z"
  mk_timed_session "$root" sessB "2020-01-02T12:05:00Z"
  local stub="$root/overlap-empty.sh"
  printf '#!/bin/bash\nexit 0\n' > "$stub"
  chmod +x "$stub"
  export AUTODREAM_OVERLAP_BIN="$stub"; run_dream "$root"; unset AUTODREAM_OVERLAP_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: no'      "empty overlap-stats.sh output is not a measurement"
  assert_grep "$stats" 'overlap_events: 0'          "count key still present at 0"
  assert_grep "$stats" 'sessions_with_overlap: 0'   "count key still present at 0"
  rm -rf "$root"
}

test_overlap_not_measured_malformed_output(){
  echo "# overlap (#26): overlap-stats.sh stub that prints non-JSON -> not measured"
  local root; root=$(setup_env)
  mk_timed_session "$root" sessA "2020-01-02T12:00:00Z"
  mk_timed_session "$root" sessB "2020-01-02T12:05:00Z"
  local stub="$root/overlap-malformed.sh"
  printf '#!/bin/bash\necho "not json at all"\n' > "$stub"
  chmod +x "$stub"
  export AUTODREAM_OVERLAP_BIN="$stub"; run_dream "$root"; unset AUTODREAM_OVERLAP_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: no'      "malformed overlap-stats.sh output is not a measurement"
  assert_grep "$stats" 'overlap_events: 0'          "count key still present at 0"
  assert_grep "$stats" 'sessions_with_overlap: 0'   "count key still present at 0"
  rm -rf "$root"
}

# ---------------------------------------------------------------------------

[ -x "$RUN" ]  || { echo "FATAL: $RUN not executable"; exit 1; }
[ -x "$MOCK" ] || { echo "FATAL: $MOCK not executable"; exit 1; }

echo "cc-autodream integration tests (mock claude)"
echo
test_happy
test_session_stats
test_unreadable
test_incomplete
test_idempotent
test_revalidates_garbage
test_no_sessions
test_l2_uses_the_default_model
test_l2_model_pin_is_honoured
test_framing
test_l1_engine_comes_from_the_adapter
test_l1_engine_cannot_be_redirected_by_a_worker
test_l1_session_with_no_resolvable_engine_is_an_error_record
test_worker_failure_records_exit_code_and_stdout
test_malformed_worker_output_is_a_failure_with_its_evidence
test_findings_must_be_an_array_not_merely_present
test_stale_wrongtype_findings_is_redispatched
test_failure_class_found_through_an_old_install
test_failure_class_provider_matrix
test_oversized_gate_context_overflow
test_oversized_gate_errored_noisy
test_oversized_gate_errored_silent
test_oversized_gate_script_context_overflow
test_oversized_gate_script_err_without_exit_code
test_oversized_gate_script_missing_err
test_oversized_gate_script_mixed_size_and_provider
test_oversized_gate_script_silent
test_oversized_gate_script_stdout_section_boundary
test_oversized_gate_script_unmeasurable_only
test_a_nested_error_key_is_not_a_failed_triage
test_l1_hang_is_bounded
test_intrinsic_124_is_not_a_timeout
test_l1_timeout_must_be_positive
test_l1_warmup_timeout_must_be_positive
test_warmup_can_be_disabled
test_warmup_diagnostic_stdout_is_a_failure_not_ok
test_warmup_empty_stdout_is_a_failure_not_ok
test_warmup_runs_before_the_fanout
test_breaker_needs_two_barren_rounds_not_one
test_a_deterministic_failure_trips_the_breaker
test_a_flaky_worker_does_not_trip_the_breaker
test_warmup_works_for_an_adapter_with_no_environment
test_net_up_survives_a_curl_that_stalls_after_the_reply
test_net_up_probes_the_host_it_is_given
test_wait_for_network_cap_bounds_the_probe
test_network_down_defers_the_date
test_oversized_gate_script_deferred
test_route_lost_after_the_precheck_still_defers
test_missing_curl_is_not_read_as_an_outage
test_a_transient_outage_is_ridden_out_not_deferred
test_no_curl_does_not_defer_a_healthy_run
test_unexecutable_curl_is_not_read_as_an_outage
test_provider_refusal_defers_without_a_stub
test_provider_402_and_missing_curl_still_defer
test_rounds_used_counts_rounds_that_dispatched
test_changelog
test_changelog_multi_source
test_changelog_refuses_foreign_cache_dir
test_changelog_single_remote_suppresses_defaults
test_changelog_dedupe_is_scoped_to_the_release
test_changelog_survives_a_force_pushed_remote
test_prune_helper
test_autodream_now_from_a_checkout_uses_the_default_install
test_self_session_excluded
test_skip_empty_sessions
test_skip_empty_disabled
test_l1_retry
test_idempotency_guard
test_idempotency_guard_needs_a_complete_report
test_run_lock_is_per_date_and_live_holders_win
test_run_lock_is_reclaimed_from_a_dead_holder
test_killed_run_temps_are_swept_at_the_start_of_the_next_run
test_self_audit_stats
test_self_audit_stats_failure_denominator
test_self_audit_stats_precached_disambiguation
test_normalize_project
test_citation_check_resolves
test_citation_check_flags_gated_and_missing
test_citation_counters_in_run_stats
test_citation_check_counts_bare_hashes
test_citation_check_resolves_session_id_tail
test_slim_transcript
test_facet_fields_plumbed
test_noise_gate_trivial
test_noise_gate_short_duration
test_noise_gate_subagent_carveout
test_noise_gate_stats
test_noise_gate_env_override
test_oversized_gate_zero
test_oversized_gate_total
test_oversized_gate_errored
test_stats_sidecar_ok
test_stats_sidecar_missing_counted
test_stats_sidecar_missing_keeps_oversized_count
test_stats_sidecar_malformed_counted
test_stats_sidecar_non_numeric_counted
test_runner_provenance
test_runner_provenance_no_git
test_runner_provenance_through_symlink
test_runner_provenance_relative_symlink
test_runner_provenance_unresolvable_chain
test_oversized_gate_script
test_oversized_gate_script_open
test_oversized_gate_script_empty
test_oversized_gate_script_args
test_notify_count
test_notify_open_command
test_notify_dryrun
test_runner_dirty_ignores_untracked
test_overlap_pair
test_overlap_triple
test_overlap_none
test_overlap_drops_advisor_sidecars
test_overlap_drops_nested_sidecars
test_fanout_stats
test_overlap_not_measured_missing_bin
test_overlap_not_measured_empty_output
test_overlap_not_measured_malformed_output
test_notes_no_surfaces
test_notes_from_notes_file
test_notes_from_vault_inbox
test_notes_vault_expired_dropped
test_notes_vault_archived_after_report
test_notes_vault_not_archived_without_report
test_notes_vault_report_published
test_notes_vault_unreadable_note_stays
test_config_file_sourced
test_config_env_wins_over_config
test_notes_header_only_file_does_not_abort
test_notes_icloud_placeholder_is_counted
test_notes_placeholder_and_real_file_counted_once
test_notes_expiry_uses_report_date
test_focus_tag_reaches_the_report_and_is_consumed
test_focus_tag_is_held_for_its_day
test_focus_tag_day_is_the_local_day
test_focus_tag_not_consumed_without_report
test_focus_tag_pending_set
test_focus_tag_retag_after_consume_is_offered_again
test_focus_tag_forced_rebuild_keeps_its_tags
test_focus_tag_unreadable_file_is_reported
test_focus_tag_unparseable_time_is_dated_by_the_report
test_focus_tag_text_cannot_forge_a_note
test_focus_tag_archive_is_idempotent
test_focus_tag_without_jq_is_reported
test_force_rebuild_failed_l2_does_not_consume
test_unmovable_stale_report_disarms_consuming
test_partial_report_does_not_consume
test_partial_report_keeps_previous
test_partial_report_does_not_block_retry
test_complete_report_retires_partials
test_dead_stdout_does_not_kill_the_run
test_unassembled_dates_are_surfaced
test_unassembled_ignores_a_finished_date
test_pre_marker_report_is_not_abandoned
test_missing_report_still_abandoned_before_epoch
test_no_sessions_stub_carries_marker
test_old_date_reprocess_does_not_consume
test_config_unbound_var_does_not_kill_run
# ---- Multi-root session scanning (SESSION_ROOTS) + root-probe ----

# A run that scans more than one projects dir: primary + one alt, both holding sessions
# touched into the target day. Works by NOT exporting PROJECTS_DIR (so autodetect runs)
# and overriding HOME into the sandbox so root-probe discovers the sandbox's claude dirs
# rather than the host's.
run_dream_autodetect(){ # $1=root — like run_dream but with HOME inside the sandbox, no PROJECTS_DIR
  AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
  AUTODREAM_CONFIG="$1/autodream/config" \
  AUTODREAM_CONSUME_DATE="$DATE" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  HOME="$1/home" AUTODREAM_DIR="$1/autodream" DREAMS_DIR="$1/dreams" \
  /bin/bash "$RUN" "$DATE" > "$1/run.out" 2>&1
  cat "$1/autodream/logs/run-$DATE.log" >> "$1/run.out" 2>/dev/null || true
}
setup_env_altroot(){ # like setup_env, but with HOME inside the sandbox (no $1/projects); echoes the root
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$root/home/.claude/projects/proj-a" \
           "$root/home/.claude-ds4/projects/proj-a" \
           "$root/autodream" "$root/dreams" "$root/cap"
  cp "$REPO/prompts/SESSION_TRIAGE.md" "$root/autodream/SESSION_TRIAGE.md"
  cp "$REPO/prompts/PROMPT.md"         "$root/autodream/PROMPT.md"
  cp "$REPO/prompts/L2_SYSTEM.txt"     "$root/autodream/L2_SYSTEM.txt"  # install.sh links it too
  printf '%s' "$root"
}
mk_session_in(){ # $1=dir $2=name
  local f="$1/$2.jsonl"
  printf '%s\n' \
    '{"type":"user","cwd":"/tmp/proj-a","message":{"content":"start the task"}}' \
    '{"type":"user","message":{"content":"keep going"}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}' \
    > "$f"
  touch -t "$STAMP" "$f"
}

# Mark an alt root as decided-index so probe_roots scans it.
decide_index(){ # $1=root-dir — writes $AUTODREAM_DIR/root-choices.conf
  mkdir -p "$1/autodream"
  printf '%s=index\n' "$2" >> "$1/autodream/root-choices.conf"
}

test_multiroot_triages_alt_root(){
  echo "# multi-root: sessions in a second (decided) claude dir get triaged too"
  local root; root=$(setup_env_altroot)
  decide_index "$root" "$root/home/.claude-ds4/projects"
  mk_session_in "$root/home/.claude/projects/proj-a" s1
  mk_session_in "$root/home/.claude-ds4/projects/proj-a" s2
  run_dream_autodetect "$root"
  local fdir="$root/autodream/findings/$DATE"
  assert_grep "$root/run.out" "session roots:" "probe_roots logged the resolved roots"
  assert_file "$fdir/$(printf '%s' "$root/home/.claude/projects/proj-a/s1.jsonl" | shasum | cut -c1-12).json" "primary-root session has a findings JSON"
  assert_file "$fdir/$(printf '%s' "$root/home/.claude-ds4/projects/proj-a/s2.jsonl" | shasum | cut -c1-12).json" "decided alt-root session has a findings JSON"
  assert_grep "$root/autodream/findings/$DATE/sessions.txt.raw" "$root/home/.claude/projects/proj-a/s1.jsonl" "primary session enumerated"
  assert_grep "$root/autodream/findings/$DATE/sessions.txt.raw" "$root/home/.claude-ds4/projects/proj-a/s2.jsonl" "decided alt session enumerated"
  assert_grep "$root/autodream/findings/$DATE/run-stats.txt" "session_roots: 2" "run-stats reports 2 roots scanned"
  # A decided-index root is not flagged.
  assert_nogrep "$root/autodream/findings/$DATE/unindexed-roots.txt" "$root/home/.claude-ds4/projects" "a decided-index root is not flagged"
  rm -rf "$root"
}

test_multiroot_heldout_and_dedup(){
  echo "# multi-root: undecided dirs are held out (flagged, not triaged); a file reachable via symlink from two roots is triaged once"
  local root; root=$(setup_env_altroot)
  decide_index "$root" "$root/home/.claude-ds4/projects"
  # An undecided third dir (present, no choice recorded).
  mkdir -p "$root/home/.claude-sigint/projects/proj-a"
  mk_session_in "$root/home/.claude-sigint/projects/proj-a" s9
  mk_session_in "$root/home/.claude/projects/proj-a" s1
  # The same transcript reachable from both decided roots: a symlink in the alt root
  # pointing at the primary's file. `find -type f` follows the link and reports the
  # target path, so the two roots yield the SAME path and sort -u must collapse it.
  mk_session_in "$root/home/.claude/projects/proj-a" s2
  ln -s "$root/home/.claude/projects/proj-a/s2.jsonl" "$root/home/.claude-ds4/projects/proj-a/s2.jsonl"
  run_dream_autodetect "$root"
  local fdir="$root/autodream/findings/$DATE"
  # Held-out: sigint is flagged and its session is NOT triaged.
  assert_grep "$fdir/unindexed-roots.txt" "$root/home/.claude-sigint/projects" "the undecided sigint dir is flagged"
  assert_nogrep "$fdir/sessions.txt.raw" "$root/home/.claude-sigint/projects/proj-a/s9.jsonl" "the undecided sigint session is NOT triaged"
  # Dedup: the symlinked path appears exactly once in sessions.txt.raw.
  local n; n=$(grep -c "$root/home/.claude/projects/proj-a/s2.jsonl" "$fdir/sessions.txt.raw")
  assert_eq "$n" "1" "the symlinked path appears once in sessions.txt.raw"
  local p; p=$(printf '%s' "$root/home/.claude/projects/proj-a/s2.jsonl" | shasum | cut -c1-12)
  assert_file "$fdir/$p.json" "the one overlapping session has a findings JSON"
  rm -rf "$root"
}

test_multiroot_flags_unindexed(){
  echo "# multi-root: claude dirs that exist but are not indexed are flagged for the report"
  local root; root=$(setup_env_altroot)
  # Third dir, present, not indexed, not in root-choices.conf.
  mkdir -p "$root/home/.claude-sigint/projects/proj-a"
  : > "$root/home/.claude-sigint/projects/proj-a/s9.jsonl"; touch -t "$STAMP" "$root/home/.claude-sigint/projects/proj-a/s9.jsonl"
  mk_session_in "$root/home/.claude/projects/proj-a" s1
  # The ds4 dir (from setup) is also present and undecided.
  mk_session_in "$root/home/.claude-ds4/projects/proj-a" s2
  run_dream_autodetect "$root"
  local flag="$root/autodream/findings/$DATE/unindexed-roots.txt"
  assert_file "$flag" "unindexed-roots.txt written"
  assert_grep "$flag" "$root/home/.claude-sigint/projects" "the sigint dir is named"
  assert_grep "$flag" "$root/home/.claude-ds4/projects" "the ds4 dir is named too"
  assert_nogrep "$flag" "$root/home/.claude/projects" "the primary dir is never flagged"
  # Neither undecided dir is triaged — they're held out until decided.
  assert_nogrep "$root/autodream/findings/$DATE/sessions.txt.raw" "$root/home/.claude-sigint/projects/proj-a/s9.jsonl" "sigint session is not triaged"
  assert_nogrep "$root/autodream/findings/$DATE/sessions.txt.raw" "$root/home/.claude-ds4/projects/proj-a/s2.jsonl" "ds4 session is not triaged"
  rm -rf "$root"
}

# ---- root-probe.sh unit tests (no run.sh) ----
rp(){ AUTODREAM_DIR="$T/ad" HOME="$T/home" "$REPO/bin/root-probe.sh" "$@"; }

test_rootprobe_remembers_choice(){
  echo "# root-probe: --default-index records the choice once and stops re-asking"
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$T/home/.claude/projects" "$T/home/.claude-ds4/projects" "$T/ad"
  rp --default-index >/dev/null 2>&1
  assert_grep "$T/ad/root-choices.conf" "$T/home/.claude-ds4/projects=index" "unasked alt root recorded as index"
  # Second invocation with a NEW unasked dir: only the new one gets a line.
  mkdir -p "$T/home/.claude-sigint/projects"
  rp --default-index >/dev/null 2>&1
  local n; n=$(grep -c '^.*=index' "$T/ad/root-choices.conf")
  assert_eq "$n" "2" "second run records only the newly-unasked root"
  assert_nogrep "$T/ad/root-choices.conf" "$T/home/.claude-sigint/projects=ignore" "new root not ignored"
  rm -rf "$T"
}

test_rootprobe_no_write_mode_flags_but_does_not_write(){
  echo "# root-probe: nightly mode (no --ask/--default-index) flags but never writes choices"
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$T/home/.claude/projects" "$T/home/.claude-ds4/projects" "$T/ad"
  rp --unindexed >/dev/null 2>&1 || true
  assert_no_file "$T/ad/root-choices.conf" "no choice file written by a nightly-mode run"
  rm -rf "$T"
}

test_rootprobe_empty_home(){
  echo "# root-probe: a machine with no claude dirs at all must not abort (empty roots, set -u)"
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$T/home" "$T/ad"
  # Capture the exit code before any `|| true` swallows it.
  local out rc
  out=$(HOME="$T/home" AUTODREAM_DIR="$T/ad" "$REPO/bin/root-probe.sh" --list 2>&1)
  rc=$?
  assert_eq "$rc" "0" "root-probe --list exits 0 with no claude dirs (got $rc)"
  local n; n=$(printf '%s\n' "$out" | grep -c .)
  assert_eq "$n" "0" "no roots are listed (got $n)"
  out=$(HOME="$T/home" AUTODREAM_DIR="$T/ad" "$REPO/bin/root-probe.sh" --consolidated 2>&1)
  rc=$?
  assert_eq "$rc" "0" "root-probe --consolidated exits 0 with no claude dirs (got $rc)"
  rm -rf "$T"
}

# ---- Enumeration transport: a path a line-based artifact cannot hold ----------
# sessions.txt is line-delimited and STAYS that way: the hash assignment in l1_missing_count() and :540 key
# each artifact by sha1 of the whole line, oversized-gate.sh's hash recomputation recomputes
# that same hash from the file, and every archived findings dir depends on it.
# So a path containing a newline cannot be represented, and today it is worse
# than unrepresentable — `find` writes it as two lines and the runner invents a
# second session that does not exist. Reject it at enumeration instead.
test_newline_path_is_rejected_not_split(){
  echo "# enumeration: a path containing a newline is rejected, never split into two"
  local root; root=$(setup_env)
  mk_session "$root" good
  # Some filesystems refuse a newline in a name; if this one does, there is
  # nothing to reject and the test says so rather than passing vacuously.
  local bad; bad=$(printf '%s/projects/proj-a/ba\nd.jsonl' "$root")
  if ! printf '%s\n' '{"type":"user","cwd":"/tmp/proj-a","message":{"content":"x"}}' > "$bad" 2>/dev/null; then
    ok "the filesystem refuses newline filenames; nothing to reject here"
    rm -rf "$root"; return 0
  fi
  touch -t "$STAMP" "$bad"
  run_dream "$root"
  local f; f=$(fdir "$root")
  assert_eq "$(grep -c . "$f/sessions.txt.raw")" "1" "only the representable session is enumerated"
  assert_grep "$f/run-stats.txt" 'sessions_rejected_path: 1' "the rejection is counted in run-stats"
  assert_grep "$root/run.out" 'cannot carry' "the log says why the path was refused"
  rm -rf "$root"
}

# ---- Adapter-aware enumeration: source provenance and the artifact contract ----
# Source is carried in a sidecar keyed by the artifact hash, NOT tagged into
# sessions.txt. Four consumers derive the artifact key or a filesystem path from
# a whole line of that file, so adding a field to it would silently invalidate
# every archived findings dir along with bin/oversized-gate.sh.
test_source_sidecar_is_written(){
  echo "# union: every enumerated session gets a source sidecar line keyed by hash"
  local root; root=$(setup_env)
  mk_session "$root" a
  run_dream "$root"
  local f; f=$(fdir "$root")
  assert_file "$f/sessions-source.txt" "the sidecar exists"
  local sp h
  sp=$(head -1 "$f/sessions.txt")
  h=$(printf '%s' "$sp" | shasum -a 1 | cut -c1-12)
  assert_grep "$f/sessions-source.txt" "^$h	claude$" "the hash maps to its source"
  assert_grep "$f/run-stats.txt" 'sessions_by_source: claude=' "per-source counts are recorded"
  assert_grep "$f/run-stats.txt" 'adapters_enabled: claude' "the enabled adapter set is recorded"
  rm -rf "$root"
}

test_artifact_hash_contract_is_unchanged(){
  echo "# union: the artifact key is still sha1 of the bare path, so archived dirs keep working"
  local root; root=$(setup_env)
  mk_session "$root" a
  run_dream "$root"
  local f; f=$(fdir "$root")
  local sp h
  sp=$(head -1 "$f/sessions.txt")
  h=$(printf '%s' "$sp" | shasum -a 1 | cut -c1-12)
  assert_file "$f/$h.json" "the findings record is keyed by sha1 of the bare path"
  # A tab in sessions.txt would mean the line stopped being a bare path, which is
  # the change that breaks oversized-gate.sh's hash recomputation and every archived dir.
  assert_nogrep "$f/sessions.txt" '	' "sessions.txt carries no tab-delimited fields"
  rm -rf "$root"
}

test_preflight_stops_a_run_missing_a_dependency(){
  echo "# preflight: a missing shared dependency stops the run before anything is enumerated"
  local root; root=$(setup_env)
  mk_session "$root" a
  # An empty PATH dir hides shasum, whose absence silently empties the artifact
  # hash so every session in the night targets one findings filename.
  local empty; empty=$(mktemp -d "${TMPDIR:-/tmp}/nopath.XXXXXX")
  PATH="$empty:/usr/bin:/bin" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK"     AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE"     AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1     AUTODREAM_PREFLIGHT_FORCE_MISSING=shasum     PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams"     /bin/bash "$RUN" "$DATE" > "$root/run.out" 2>&1 || true
  cat "$root/autodream/logs/run-$DATE.log" >> "$root/run.out" 2>/dev/null || true
  assert_no_file "$(fdir "$root")/sessions.txt" "nothing was enumerated"
  assert_grep "$root/run.out" 'preflight' "the log says preflight stopped it"
  rm -rf "$root" "$empty"
}

# ---- The installed tree must actually contain the adapter runtime ----------
# install.sh has an EXPLICIT link list. The first version of the adapter change
# added four new runtime files and none of them to that list, so every
# documented nightly install would have silently taken the legacy enumeration
# path with no preflight — while still printing adapters_enabled: claude. It
# ships broken to the only place that matters and reports success, which is the
# exact failure shape this repo already has a memory note about.
test_install_deploys_the_adapter_runtime(){
  # SIDE EFFECT, deliberate and pre-existing: install.sh's chmod +x step runs
  # `chmod +x "$REPO_DIR/bin/"*.sh`, so this test makes every bin script
  # executable in the working tree. That is the repo's own convention, but it
  # means a `git stash` taken across a suite run can refuse to pop on a bare
  # mode change. Restore with `git checkout -- bin/` if that happens.
  echo "# install: the adapter runtime is installed, not just committed"
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$T/home"
  HOME="$T/home" AUTODREAM_DIR="$T/home/.claude/autodream" \
    bash "$REPO/install.sh" --no-schedule > "$T/install.out" 2>&1 || true
  local target="$T/home/.claude/autodream"
  assert_file "$target/lib-project.sh" "lib-project.sh is installed"
  assert_file "$target/adapters.sh"    "adapters.sh is installed"
  assert_file "$target/preflight.sh"   "preflight.sh is installed"
  assert_file "$target/session-window.sh" "session-window.sh is installed"
  assert_file "$target/chunk-transcript.sh" "chunk-transcript.sh is installed"
  assert_file "$target/merge-chunks.sh"     "merge-chunks.sh is installed"
  case "$(printf '{"findings":[]}' > "$T/ck.json"; bash "$target/merge-chunks.sh" --check "$T/ck.json" && echo usable)" in
    usable) ok "the installed merge helper answers through its link" ;;
    *) no "the installed merge helper answers through its link" ;;
  esac
  # Through the symlink, from outside the checkout: the runner finds it in the install dir.
  case "$(bash "$target/session-window.sh" bounds 2020-01-02 2020-01-03 2>/dev/null)" in
    [0-9]*" "[0-9]*) ok "the installed window helper answers" ;;
    *) no "the installed window helper answers" ;;
  esac
  [ -e "$target/adapters/claude/adapter.sh" ] \
    && ok "the adapters tree is reachable from the install target" \
    || no "the adapters tree is reachable from the install target"
  # And the installed runner must resolve its adapters through the FLAT layout,
  # where adapters/ sits beside adapters.sh rather than one level up.
  local got
  got=$(cd "$target" && bash -c '. ./adapters.sh; adapters_list' 2>/dev/null)
  assert_eq "$got" "$(printf 'claude\nomp')" "the installed runner resolves the claude and omp adapters"
  # Resolving the adapter is not the same as being able to RUN it. The installed
  # adapter finds its helper scripts through a relative path, so exercise a
  # subcommand that actually shells out to one rather than stopping at discovery.
  # The omp adapter keeps its helpers beside itself (linearize.sh, stats.sh), so it must
  # work through the installed symlink too, not only from the repo.
  local osess="$T/o.jsonl"
  printf '%s\n%s\n%s\n' '{"type":"title","title":"t","v":1}' \
    '{"type":"session","id":"01a00000-0000-7000-8000-000000000001","cwd":"/tmp"}' \
    '{"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":"x"}}' > "$osess"
  if "$target/adapters/omp/adapter.sh" normalize "$osess" "$T/o.norm" 2>/dev/null && [ -s "$T/o.norm" ]; then
    ok "an installed omp adapter reaches its linearizer"
  else
    no "an installed omp adapter reaches its linearizer"
  fi
  local sess="$T/s.jsonl" out="$T/s.stats.json"
  mkdir -p "$T/proj"
  printf '%s\n' "{\"type\":\"user\",\"cwd\":\"$T/proj\",\"message\":{\"content\":\"x\"}}" > "$sess"
  if "$target/adapters/claude/adapter.sh" stats "$sess" "$out" 2>/dev/null && [ -s "$out" ]; then
    ok "an installed adapter subcommand reaches its helper scripts"
  else
    no "an installed adapter subcommand reaches its helper scripts"
  fi
  assert_eq "$("$target/adapters/claude/adapter.sh" project "$sess" 2>/dev/null)" \
            "$(cd "$T/proj" && pwd -P)" "the installed adapter resolves a project cwd"
  rm -rf "$T"
}

# ---- Characters the line-based artifacts cannot carry, and the ones the fan-out now does ----
# The L1 fan-out used to read sessions.txt through `xargs -I {}`: a tab became a space, a
# backslash was deleted, and a quote killed the whole dispatch with "unterminated quote" (#54).
# It is NUL-delimited now, so backslash and quotes are triaged like any path. A tab stays
# refused (the TSV artifacts carry columns), and so does a newline.
test_unusual_session_paths_are_triaged_or_refused(){
  echo "# fan-out: quote, backslash and apostrophe paths are triaged; a tab path is refused; the run completes"
  local root; root=$(setup_env)
  mk_session "$root" good
  local carried=0 refused=0 p bad
  local -a okbads=( 'back\slash' 'quo"te' "it's" 'ha#sh&amp' )
  local -a hashes=()
  for bad in "${okbads[@]}"; do
    p="$root/projects/proj-a/$bad.jsonl"
    cp "$root/projects/proj-a/good.jsonl" "$p" 2>/dev/null || continue
    touch -t "$STAMP" "$p" 2>/dev/null || continue
    carried=$((carried + 1)); hashes+=( "$(hash_of "$p")" )
  done
  p="$root/projects/proj-a/$(printf 'ta\tb').jsonl"
  if cp "$root/projects/proj-a/good.jsonl" "$p" 2>/dev/null && touch -t "$STAMP" "$p" 2>/dev/null; then refused=1; fi
  if [ "$carried" -eq 0 ]; then ok "the filesystem refuses these names; nothing to test"; rm -rf "$root"; return 0; fi
  run_dream "$root"
  local f; f=$(fdir "$root")
  assert_eq "$(grep -c . "$f/sessions.txt.raw")" "$((carried + 1))" "every carriable session is enumerated, the tab one is not"
  assert_grep "$f/run-stats.txt" "sessions_rejected_path: $refused" "only the tab path is refused and counted"
  local h
  for h in "${hashes[@]}"; do
    assert_nonempty "$f/$h.json" "a path with a quote, backslash or apostrophe got its findings JSON ($h)"
    jq -e '.findings | arrays' "$f/$h.json" >/dev/null 2>&1 && ok "and it is valid JSON with a findings array" || no "and it is valid JSON with a findings array ($h)"
  done
  assert_grep "$f/run-stats.txt" "l1_missing_after_retries: 0" "no session was left untriaged"
  assert_nonempty "$root/dreams/$DATE.md" "the run produced a report"
  rm -rf "$root"
}

test_failure_stub_for_a_quoted_path_is_valid_json(){
  echo "# fan-out: the metadata stub for a worker that wrote nothing carries a quote/backslash path as valid JSON (#54)"
  local root; root=$(setup_env)
  local p="$root/projects/proj-a/qu\"o\\te.jsonl"
  mk_session "$root" good
  cp "$root/projects/proj-a/good.jsonl" "$p" 2>/dev/null || { ok "the filesystem refuses the name; nothing to test"; rm -rf "$root"; return 0; }
  touch -t "$STAMP" "$p"
  export MOCK_MODE=l1_incomplete; run_dream "$root"; unset MOCK_MODE
  local fj; fj="$(fdir "$root")/$(hash_of "$p").json"
  assert_eq "$(jq -r '.session_path' "$fj" 2>/dev/null)" "$p" "the stub parses and names the exact path"
  assert_grep "$fj" 'worker exited without findings JSON' "and it is the failure stub"
  rm -rf "$root"
}

# ---- A failing enumerator must abort, not report over an unread corpus -------
# This is the test whose ABSENCE let 306 assertions pass over a broken fix. The
# runner staged enumeration to a file and checked its exit status, but the
# enumerate_for wrapper ended in a literal `return 0`, so the check received
# success every time. Nothing exercised an adapter whose enumerate fails, so
# nothing noticed. A run that cannot read its corpus must fail loudly rather
# than finalise a cheerful "no sessions" report.
test_failing_enumerator_aborts_the_run(){
  echo "# enumeration: an adapter whose enumerate fails costs its root, not the night"
  local root; root=$(setup_env)
  mk_session "$root" a
  # A private adapters tree holding one adapter that always fails to enumerate.
  local ad="$root/adapters"; mkdir -p "$ad/claude"
  printf '{"name":"claude","engine_bin":"true"}\n' > "$ad/claude/manifest.json"
  printf '#!/bin/bash\ncase "${1:-}" in enumerate) exit 3 ;; *) exit 2 ;; esac\n' > "$ad/claude/adapter.sh"
  chmod +x "$ad/claude/adapter.sh"
  ADAPTERS_ROOT="$ad" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    /bin/bash "$RUN" "$DATE" > "$root/run.out" 2>&1
  local rc=$?
  cat "$root/autodream/logs/run-$DATE.log" >> "$root/run.out" 2>/dev/null || true
  # The run completes rather than aborting: on a single-root host — the default
  # install — "enumerator exited nonzero and returned nothing" is also the shape of
  # a quiet date plus a transient find error, so aborting would cost a night whose
  # honest answer is the empty-night stub. roots_failed counts it, and the stub
  # says the store was not fully read rather than claiming no files were modified.
  assert_eq "$rc" "0" "the run completes rather than losing the night"
  assert_grep "$root/run.out" 'contributes NO sessions' "the log names the enumeration failure"
  assert_grep "$root/autodream/findings/$DATE/run-stats.txt" '^roots_failed: 1$' \
    "roots_failed records it"
  assert_grep "$root/dreams/$DATE.md" 'did not read the whole store' \
    "the report refuses to call this an empty night"
  assert_nogrep "$root/dreams/$DATE.md" 'No session files were modified' \
    "and does not state the claim it cannot support"
  rm -rf "$root"
}

# ---- One bad root must not take the night with it --------------------------
# find exits 1 for ANY unreadable directory in the walk, match or no match —
# verified on this host: an unreadable sibling makes it exit 1 both with and
# without matches, and exit 0 without one. A secondary root legitimately matches
# nothing on a given date, so treating "nonzero exit, no output" as fatal for the
# whole run meant one permission-denied directory under a quiet secondary root
# killed a night on which the primary had a full corpus — and killed it
# invisibly, because run() returned before notify.sh and no findings JSONs
# existed for unassembled_dates() to see.
test_one_failed_root_does_not_kill_the_night(){
  echo "# roots: one root that fails to enumerate does not discard the roots that worked"
  local root; root=$(setup_env)
  mk_session "$root" a
  # A second root that exists, holds no matching file, and contains a directory
  # find cannot read. That combination is exit 1 with empty output.
  local bad="$root/badroot"; mkdir -p "$bad/locked"
  chmod 000 "$bad/locked"
  SESSION_ROOTS="$root/projects:$bad" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    /bin/bash "$RUN" "$DATE" > "$root/run.out" 2>&1
  local rc=$?
  chmod 755 "$bad/locked"
  cat "$root/autodream/logs/run-$DATE.log" >> "$root/run.out" 2>/dev/null || true
  assert_eq "$rc" "0" "the run survives one failed root"
  assert_nonempty "$root/dreams/$DATE.md" "the healthy root's corpus still produced a report"
  assert_grep "$root/run.out" 'contributes NO sessions' "the failed root is named in the log"
  assert_grep "$root/autodream/findings/$DATE/run-stats.txt" '^roots_failed: 1$' \
    "roots_failed counts it, so a shrinking corpus is visible rather than silent"
  rm -rf "$root"
}

# ---- A corpus that exists but yields nothing is not an empty night ----------
# COUNT=0 has three distinct causes and they used to read identically: no files
# at all, every file an autodream worker transcript, or every file an empty
# shell. The stub said "No session files were modified" for all three, and the
# zero-session run-stats omitted the two counters that would have said otherwise.
test_all_excluded_corpus_says_so(){
  echo "# zero sessions: an all-excluded corpus reports why, not 'nothing was modified'"
  local root; root=$(setup_env)
  # One autodream worker transcript, nothing else. RAW is 1, COUNT is 0.
  local f="$root/projects/proj-a/worker.jsonl"
  printf '%s\n' '{"type":"user","message":{"content":"Session transcript to analyze (literal absolute path): /x"}}' > "$f"
  touch -t "$STAMP" "$f"
  run_dream "$root"
  local d; d=$(fdir "$root")
  assert_file "$d/run-stats.txt" "run-stats is written for a zero-session night"
  assert_grep "$d/run-stats.txt" 'self_sessions_excluded: 1' "the self-exclusion is counted"
  assert_grep "$d/run-stats.txt" 'sessions_found_raw: 1' "the raw count shows a file WAS there"
  assert_nogrep "$root/dreams/$DATE.md" 'No session files were modified' "the stub does not claim an empty night"
  assert_grep "$root/dreams/$DATE.md" 'autodream-own' "the stub names why nothing was triaged"
  rm -rf "$root"
}

# ---- A PARTIAL enumeration must not throw away the corpus it did read -------
# The existing failing-enumerator test uses an adapter that returns NOTHING, so
# it would pass under the old fatal-on-any-nonzero code too — it could not tell
# the regression from the fix. This one is the actual case: BSD find exits 1 when
# one subdirectory is unreadable or vanishes mid-walk WHILE still printing every
# other match. Treating that as fatal produced no report on a night the old code
# reported in full, which is worse than the silent zero the check exists to catch.
test_partial_enumeration_keeps_what_it_read(){
  echo "# enumeration: an enumerator that returns data AND fails continues, loudly"
  local root; root=$(setup_env)
  mk_session "$root" a
  local sess="$root/projects/proj-a/a.jsonl"
  local ad="$root/adapters"; mkdir -p "$ad/claude"
  printf '{"name":"claude","engine_bin":"true"}\n' > "$ad/claude/manifest.json"
  # Emits one real NUL-delimited path, then exits nonzero — exactly find's shape.
  { printf '#!/bin/bash\n'
    printf 'case "${1:-}" in\n'
    printf '  enumerate) printf "%%s\\0" "%s"; exit 1 ;;\n' "$sess"
    printf '  project) printf "/tmp/proj-a" ;;\n'
    printf '  normalize|slim) cp "$2" "$3" ;;\n'
    printf '  stats) "%s/bin/session-stats.sh" "$2" "$3" ;;\n' "$REPO"
    printf '  is-self) exit 1 ;;\n'
    printf '  *) exit 2 ;;\n'
    printf 'esac\n'
  } > "$ad/claude/adapter.sh"
  chmod +x "$ad/claude/adapter.sh"
  ADAPTERS_ROOT="$ad" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    /bin/bash "$RUN" "$DATE" > "$root/run.out" 2>&1
  local rc=$?
  cat "$root/autodream/logs/run-$DATE.log" >> "$root/run.out" 2>/dev/null || true
  local d; d=$(fdir "$root")
  assert_eq "$rc" "0" "the run completes despite the enumerator failing"
  assert_grep "$root/run.out" 'INCOMPLETE' "the log warns the corpus may be short"
  assert_grep "$d/run-stats.txt" 'roots_partially_enumerated: 1' "the partial walk is counted"
  assert_grep "$d/sessions.txt.raw" 'a.jsonl' "the path it DID return was kept"
  assert_nonempty "$root/dreams/$DATE.md" "a report is still produced"
  rm -rf "$root"
}

# ---- Every configured root unreachable is a failure, not a quiet night ------
# scan_roots warned and skipped a non-directory root, so a broken SESSION_ROOTS
# or a vanished store produced RAW=0 with every shortfall counter at 0 and a
# stub saying no files were modified. A fresh host with NO roots configured is a
# different thing and must stay legitimate.
test_all_roots_unavailable_fails(){
  echo "# roots: all configured roots unreachable fails rather than reporting empty"
  local root; root=$(setup_env)
  mk_session "$root" a
  SESSION_ROOTS="$root/does-not-exist-a:$root/does-not-exist-b" \
    AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    /bin/bash "$RUN" "$DATE" > "$root/run.out" 2>&1
  local rc=$?
  cat "$root/autodream/logs/run-$DATE.log" >> "$root/run.out" 2>/dev/null || true
  assert_eq "$rc" "1" "the run fails when no configured root is reachable"
  assert_grep "$root/run.out" 'all .* configured session root' "the log names the cause"
  assert_no_file "$root/dreams/$DATE.md" "no empty-night report is written"
  rm -rf "$root"
}

# ---- A fresh host with no store is a quiet night, not a failure -------------
# probe_roots falls back to $HOME/.claude/projects when discovery finds nothing.
# The all-roots-unavailable fatal counted that fallback as a configured root and
# aborted, so a machine that has simply never run Claude Code failed instead of
# reporting an empty night. The fatal must fire only on roots someone actually
# asked for.
test_fresh_host_with_no_store_is_not_a_failure(){
  echo "# roots: a fresh host with no session store reports empty, it does not fail"
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$T/home" "$T/autodream" "$T/dreams"
  cp "$REPO/prompts/SESSION_TRIAGE.md" "$T/autodream/SESSION_TRIAGE.md"
  cp "$REPO/prompts/PROMPT.md"         "$T/autodream/PROMPT.md"
  cp "$REPO/prompts/L2_SYSTEM.txt"     "$T/autodream/L2_SYSTEM.txt"  # install.sh links it too
  # No SESSION_ROOTS, no PROJECTS_DIR, and a HOME with no .claude at all.
  HOME="$T/home" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$T/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    AUTODREAM_DIR="$T/autodream" DREAMS_DIR="$T/dreams" \
    /bin/bash "$RUN" "$DATE" > "$T/run.out" 2>&1
  local rc=$?
  cat "$T/autodream/logs/run-$DATE.log" >> "$T/run.out" 2>/dev/null || true
  assert_eq "$rc" "0" "a fresh host exits 0"
  assert_nonempty "$T/dreams/$DATE.md" "a fresh host still gets a report"
  assert_nogrep "$T/run.out" 'configured session root' "no all-roots-unavailable fatal fires"
  rm -rf "$T"
}

# ---- A fatal must not vandalise a date that already succeeded ---------------
# fatal_exit truncates run-stats.txt and posts a FAILED banner. AUTODREAM_FORCE
# bypasses the idempotency guard by design — it is the documented
# `autodream-now.sh <date> --force` path — so any fatal under it would overwrite
# that date's full L1/L2 telemetry with a five-line stub and announce a failure
# for a night whose report is sitting right there. unassembled_dates() would not
# catch it either, because the report exists.
test_fatal_does_not_clobber_a_complete_date(){
  echo "# fatal: a forced rerun that dies leaves the completed date's stats alone"
  local root; root=$(setup_env)
  mk_session "$root" a
  local env_common=(AUTODREAM_CHANGELOG=0 AUTODREAM_NETCHECK=0
                    AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1)
  # A good night first.
  env "${env_common[@]}" CLAUDE_BIN="$MOCK" AUTODREAM_CONFIG="$root/autodream/config" \
    AUTODREAM_CONSUME_DATE="$DATE" PROJECTS_DIR="$root/projects" \
    AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    /bin/bash "$RUN" "$DATE" > "$root/run1.out" 2>&1
  assert_nonempty "$root/dreams/$DATE.md" "the first run produced a report"
  local before; before=$(wc -l < "$root/autodream/findings/$DATE/run-stats.txt" | tr -d ' ')
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/notify-args.txt"\n' "$root" \
    > "$root/autodream/notify.sh"
  chmod +x "$root/autodream/notify.sh"
  # Now force a rerun that dies: every configured root unavailable.
  env "${env_common[@]}" CLAUDE_BIN="$MOCK" AUTODREAM_CONFIG="$root/autodream/config" \
    AUTODREAM_CONSUME_DATE="$DATE" AUTODREAM_FORCE=1 \
    SESSION_ROOTS="$root/gone-a:$root/gone-b" \
    AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    /bin/bash "$RUN" "$DATE" > "$root/run2.out" 2>&1
  local after; after=$(wc -l < "$root/autodream/findings/$DATE/run-stats.txt" | tr -d ' ')
  assert_eq "$after" "$before" "the completed date's run-stats.txt is untouched"
  assert_grep "$root/autodream/findings/$DATE/run-stats.txt" '^sessions_triaged: [1-9]' \
    "and still carries the real triage count, not a stub zero"
  # The banner MUST still fire. An earlier version of this test asserted the
  # opposite and passed, which is how the guard came to suppress it: the run-stats
  # write is what must not clobber a complete date, and the banner got taken down
  # with it by being inside the same `return`. This branch is reachable only under
  # AUTODREAM_FORCE, i.e. `autodream-now.sh <date> --force`, which runs detached
  # under launchd — where a silent death leaves the operator polling
  # dreams/<date>.md, finding the OLD report, and reading the failed rebuild as a
  # success.
  assert_file "$root/notify-args.txt" \
    "a failed --force rebuild still posts a banner even though the date has a report"
  assert_grep "$root/notify-args.txt" '[-][-]failure' "and posts it in failure mode"
  assert_grep "$root/notify-args.txt" 'existing report' \
    "and says the standing report is the OLD one, not this run's output"
  rm -rf "$root"
}

# ---- A total outage must leave a trace ------------------------------------
# adapters/claude/adapter.sh losing its exec bit is a mundane accident — a
# tarball copy, a restrictive umask, core.fileMode=false — and _adapter_ok
# demands -x. The loader then accepts nothing, scan_roots goes fatal, and run()
# returns ~600 lines before notify.sh with no findings JSON and no run-stats.txt.
# A host that reported fine last night reports nothing, every night, and the only
# record is a log line nobody reads.
test_no_usable_adapter_leaves_a_trace(){
  echo "# adapters: a total outage writes a fatal marker the next night can see"
  local root; root=$(setup_env)
  mk_session "$root" a
  local ad="$root/adapters"; mkdir -p "$ad/claude"
  printf '{"name":"claude","engine_bin":"true"}\n' > "$ad/claude/manifest.json"
  cp "$REPO/adapters/claude/adapter.sh" "$ad/claude/adapter.sh"
  chmod -x "$ad/claude/adapter.sh"          # the whole trigger
  # A notify.sh that records how it was called. fatal_exit gates on -x, so without
  # one installed the failure-notification step is skipped and unobservable.
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/notify-args.txt"\n' "$root" \
    > "$root/autodream/notify.sh"
  chmod +x "$root/autodream/notify.sh"
  ADAPTERS_ROOT="$ad" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    /bin/bash "$RUN" "$DATE" > "$root/run.out" 2>&1
  local rc=$?
  assert_eq "$rc" "1" "the run still refuses to scan"
  assert_grep "$root/autodream/findings/$DATE/run-stats.txt" '^fatal: ' \
    "a fatal marker is left behind rather than nothing at all"
  # The marker alone is not enough for a PERSISTENT cause. A lost exec bit repeats
  # every night, so no later run ever succeeds to read the marker and report it —
  # the surface that works tonight is the banner. The stub records its arguments.
  assert_file "$root/notify-args.txt" "notify.sh was invoked on the fatal path"
  # Bracket the dashes. assert_grep takes (file, pattern, message) and passes the
  # pattern straight to grep, so a literal `--failure` reads as end-of-options and
  # an inserted `--` becomes the pattern — which is what the first version did.
  assert_grep "$root/notify-args.txt" '[-][-]failure' "and invoked in failure mode"
  assert_grep "$root/notify-args.txt" "$DATE" "naming the date that died"
  # And the next night must surface it. Run a LATER date and check it names this one.
  local later=2020-01-03
  mk_session_dated "$root" b "$later" 2>/dev/null || true
  chmod +x "$ad/claude/adapter.sh"
  ADAPTERS_ROOT="$ad" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$later" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    bash "$RUN" "$later" > "$root/run2.out" 2>&1
  cat "$root/autodream/logs/run-$later.log" >> "$root/run2.out" 2>/dev/null || true
  assert_grep "$root/run2.out" "$DATE" "the next night's run names the date that died"
  rm -rf "$root"
}

# ---- The adapter set is resolved once, not once per caller ------------------
# The first attempt at this was a memoised enabled_adapters that every caller
# invoked as $(enabled_adapters), so the cache assignment died with the subshell
# and the loader re-ran on every call — the exact trap adapters.sh's header
# documents.
#
# What this test pins is the user-visible shape: the not-adapter-aware warning
# appears once. It does NOT discriminate against that subshell bug — checked, by
# restoring the broken memo and re-running, and it still passed. The bug is a
# repeated INVOCATION, and the second invocation happens on a path whose warning
# does not reach the log a second time, so no assertion over log content can see
# it. Measuring it needs the function instrumented, which a test cannot do to a
# script it invokes rather than sources; it was measured that way by hand
# instead — 2 invocations before the fix, 1 after.
#
# Left in because the warning multiplying IS worth pinning, and said plainly so
# the next reader does not mistake this for coverage of the subshell trap.
test_enabled_adapters_resolves_once(){
  echo "# adapters: an accepted but not enabled adapter warns once per run, not once per caller"
  local root; root=$(setup_env)
  mk_session "$root" a
  local ad="$root/adapters"
  mkdir -p "$ad/claude" "$ad/other"
  printf '{"name":"claude","engine_bin":"true"}\n' > "$ad/claude/manifest.json"
  cp "$REPO/adapters/claude/adapter.sh" "$ad/claude/adapter.sh"
  chmod +x "$ad/claude/adapter.sh"
  printf '{"name":"other","engine_bin":"true"}\n' > "$ad/other/manifest.json"
  printf '#!/bin/bash\nexit 2\n' > "$ad/other/adapter.sh"; chmod +x "$ad/other/adapter.sh"
  ADAPTERS_ROOT="$ad" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    /bin/bash "$RUN" "$DATE" > "$root/run.out" 2>&1
  cat "$root/autodream/logs/run-$DATE.log" >> "$root/run.out" 2>/dev/null || true
  local n
  n=$(grep -c "is accepted but not enabled" "$root/run.out" 2>/dev/null || true)
  n=${n:-0}
  assert_eq "$n" "1" "the not-enabled warning is emitted exactly once"
  assert_nonempty "$root/dreams/$DATE.md" "the run still produced a report"
  rm -rf "$root"
}

# ---- omp sessions through the adapter seam --------------------------------------------------
# An omp session is an append-only tree, so the worker has to read the linearized live branch,
# the stats come from the omp record shapes, and none of it may be switched on for a host that
# did not ask (AUTODREAM_ADAPTERS).
mk_omp_session(){ # $1=root $2=name [$3=cwd]  -> path on stdout; abandoned branch written first
  local d="$1/home/.omp/agent/sessions/proj-o" f cwd="${3:-/tmp/proj-o}"
  mkdir -p "$d"; f="$d/2020-01-02T10-00-00-000Z_$2.jsonl"
  {
    printf '%s\n' '{"type":"title","title":"t","v":1}'
    printf '{"type":"session","id":"01a00000-0000-7000-8000-000000000001","cwd":"%s","timestamp":"2020-01-02T10:00:00.000Z"}\n' "$cwd"
    printf '%s\n' '{"type":"message","id":"u1","parentId":null,"timestamp":"2020-01-02T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"start the omp task"}]}}'
    printf '%s\n' '{"type":"message","id":"ax","parentId":"u1","timestamp":"2020-01-02T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"ABANDONED_BRANCH_MARKER"}]}}'
    printf '%s\n' '{"type":"message","id":"a1","parentId":"u1","timestamp":"2020-01-02T10:00:03.000Z","message":{"role":"assistant","content":[{"type":"text","text":"LIVE_BRANCH_MARKER"}]}}'
    printf '%s\n' '{"type":"message","id":"u2","parentId":"a1","timestamp":"2020-01-02T10:05:04.000Z","message":{"role":"user","content":[{"type":"text","text":"keep going"}]}}'
    printf '%s\n' '{"type":"message","id":"a2","parentId":"u2","timestamp":"2020-01-02T10:05:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}'
  } > "$f"
  touch -t "$STAMP" "$f"
  printf '%s' "$f"
}
run_dream_omp(){ # $1=root ; claude + omp enabled, a sandbox HOME, both engines are the mock
  # omp sessions are pinned to the omp engine, so the omp tests below exercise that engine. With
  # claude enabled first the run's reviewer would be claude; a test about the reviewer exports
  # AUTODREAM_L1_ENGINE_OMP= (empty) to clear the pin.
  mkdir -p "$1/home"
  HOME="$1/home" AUTODREAM_ADAPTERS="${AUTODREAM_ADAPTERS:-claude,omp}" AUTODREAM_L1_MODEL_OMP="${TEST_OMP_L1_MODEL-omp/test-model}" \
    AUTODREAM_L1_ENGINE_OMP="${AUTODREAM_L1_ENGINE_OMP-omp}" \
    AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" OMP_BIN="${TEST_OMP_BIN:-$MOCK}" \
    AUTODREAM_CONFIG="$1/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK="${AUTODREAM_NETCHECK:-0}" AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    PROJECTS_DIR="$1/projects" AUTODREAM_DIR="$1/autodream" DREAMS_DIR="$1/dreams" \
    /bin/bash "$RUN" "$DATE" > "$1/run.out" 2>&1
  cat "$1/autodream/logs/run-$DATE.log" >> "$1/run.out" 2>/dev/null || true
}

test_l1_precheck_probes_the_l1_provider(){
  echo "# an omp L1 on deepseek is gated on deepseek reachability, not anthropic (issue 109)"
  local root shim log; root=$(setup_env); mk_session "$root" sess1; mk_omp_session "$root" cccc >/dev/null
  log="$root/curl.log"; shim=$(shim_curl_logging "$root" "$log" reply)
  TEST_CURL_SHIMMED=1 PATH="$shim:$PATH" AUTODREAM_ADAPTERS=omp TEST_OMP_L1_MODEL=deepseek/test-flash AUTODREAM_NETCHECK=1 run_dream_omp "$root"
  assert_grep "$log" 'api.deepseek.com' "the pre-dispatch check probed the L1 provider"
  assert_eq "$(head -n 1 "$log" 2>/dev/null)" "https://api.deepseek.com/" "and probed it first"
  rm -rf "$root"
}

test_worker_failure_probe_names_the_l1_provider(){
  echo "# a worker that fails on a dead deepseek route says so, and probes deepseek (issue 109)"
  local root shim log h o; root=$(setup_env); o=$(mk_omp_session "$root" dddd); h=$(hash_of "$o")
  log="$root/curl.log"; mkdir -p "$root/dead"
  printf '%s\n' '#!/bin/bash' 'for a in "$@"; do case "$a" in https://*) printf "%s\n" "$a" >> "'"$log"'" ;; esac; done' 'printf 000; exit 6' > "$root/dead/curl"
  chmod +x "$root/dead/curl"
  export MOCK_MODE=l1_incomplete
  TEST_CURL_SHIMMED=1 PATH="$root/dead:$PATH" AUTODREAM_ADAPTERS=omp TEST_OMP_L1_MODEL=deepseek/test-flash run_dream_omp "$root"
  unset MOCK_MODE
  assert_grep "$log" 'api.deepseek.com' "the failure probe went to the L1 provider"
  assert_nogrep "$log" 'api.anthropic.com' "not to anthropic"
  assert_grep "$(fdir "$root")/$h.json.err" 'no route to api.deepseek.com' ".err names the host that was down"
  rm -rf "$root"
}

test_one_dead_provider_does_not_hold_back_the_others(){
  echo "# a dead deepseek route does not defer a run whose claude sessions never touch it (review of PR 124)"
  local root log; root=$(setup_env); mk_session "$root" sess1; mk_omp_session "$root" eeee >/dev/null
  log="$root/curl.log"; mkdir -p "$root/half"
  printf '%s\n' '#!/bin/bash' 'for a in "$@"; do case "$a" in https://*) u="$a"; printf "%s\n" "$a" >> "'"$log"'" ;; esac; done' \
    'case "$u" in *deepseek*) printf 000; exit 6 ;; *) printf 200 ;; esac' > "$root/half/curl"
  chmod +x "$root/half/curl"
  TEST_CURL_SHIMMED=1 PATH="$root/half:$PATH" AUTODREAM_ADAPTERS=claude,omp TEST_OMP_L1_MODEL=deepseek/test-flash \
    AUTODREAM_NETCHECK=1 AUTODREAM_NETCHECK_CAP=0 run_dream_omp "$root"
  assert_grep   "$log" 'api.anthropic.com' "the gate asked claude's host"
  assert_nogrep "$root/run.out" 'not dispatched' "the round was dispatched anyway, because claude's host answers"
  assert_grep   "$(fdir "$root")/run-stats.txt" 'network_deferred: no' "and the date was not deferred"
  rm -rf "$root"
}

test_omp_adapter_is_opt_in(){
  echo "# an accepted omp adapter is not enabled unless the host asks for it"
  local root; root=$(setup_env); mk_session "$root" sess1
  local o; o=$(mk_omp_session "$root" aaaa)
  AUTODREAM_ADAPTERS=claude run_dream_omp "$root"
  local fd; fd=$(fdir "$root")
  assert_grep   "$fd/run-stats.txt" 'adapters_enabled: claude$' "only claude is enabled by default"
  assert_nogrep "$fd/sessions.txt" 'proj-o' "the omp session is not enumerated"
  assert_grep   "$root/run.out" "adapter 'omp' is accepted but not enabled" "and the log says why"
  rm -rf "$root"
}

test_omp_session_is_linearized_for_the_worker(){
  echo "# an enabled omp adapter: the worker reads the live branch, stats come from omp records"
  local root; root=$(setup_env); mk_session "$root" sess1
  local o; o=$(mk_omp_session "$root" bbbb); local h; h=$(hash_of "$o")
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap"; run_dream_omp "$root"; unset FANOUT MOCK_CAPTURE_DIR
  local fd; fd=$(fdir "$root")
  assert_grep   "$fd/run-stats.txt" 'adapters_enabled: claude,omp' "both adapters are recorded as enabled"
  assert_grep   "$fd/sessions-source.txt" "^$h	omp$" "the omp session's provenance is omp"
  assert_file   "$root/cap/l1-read-$h.txt" "the omp worker was started"
  assert_grep   "$root/cap/l1-read-$h.txt" 'LIVE_BRANCH_MARKER' "it read the live branch"
  assert_nogrep "$root/cap/l1-read-$h.txt" 'ABANDONED_BRANCH_MARKER' "and never the abandoned one"
  assert_grep   "$fd/$h.stats.json" '"user_message_count"' "the stats sidecar came from the omp stats script"
  assert_nogrep "$fd/$h.json" '"error"' "the session was triaged"
  assert_nogrep "$fd/$h.json" 'norm.jsonl' "the findings name the real session, not the temporary copy"
  assert_no_file "$fd/$h.norm.jsonl" "the normalized copy is removed"
  assert_grep   "$root/cap/l1-args-$h.txt" '^omp/test-model$' "the omp worker ran the omp adapter's model"
  assert_grep   "$root/cap/l1-args-$h.txt" '^--allow-home$' "and the omp adapter's own flags"
  rm -rf "$root"
}

# An omp binary that records every call and fails, so a test can prove the omp engine never ran.
mk_omp_tripwire(){ # $1=root -> path on stdout; calls land in $1/omp-calls.log
  printf '%s\n' '#!/bin/bash' "printf '%s\n' \"\$*\" >> '$1/omp-calls.log'" 'exit 7' > "$1/omp-tripwire"
  chmod +x "$1/omp-tripwire"
  printf '%s' "$1/omp-tripwire"
}

test_omp_sessions_run_on_another_adapters_engine(){
  echo "# AUTODREAM_L1_ENGINE_OMP=claude: the claude engine reads omp sessions, and omp never runs"
  local root o h fd trip; root=$(setup_env); mk_session "$root" sess1
  o=$(mk_omp_session "$root" ffff); h=$(hash_of "$o"); trip=$(mk_omp_tripwire "$root")
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap" AUTODREAM_L1_ENGINE_OMP=claude
  TEST_OMP_BIN="$trip" TEST_OMP_L1_MODEL=claude-test-model run_dream_omp "$root"
  unset FANOUT MOCK_CAPTURE_DIR AUTODREAM_L1_ENGINE_OMP
  fd=$(fdir "$root")
  assert_grep    "$fd/sessions-source.txt" "^$h	omp$" "the session is still the omp adapter's"
  assert_grep    "$root/cap/l1-read-$h.txt" 'LIVE_BRANCH_MARKER' "the omp adapter still linearized it"
  assert_grep    "$root/cap/l1-args-$h.txt" '^claude-test-model$' "the worker ran the configured model"
  assert_grep    "$root/cap/l1-args-$h.txt" '^--no-session-persistence$' "with the claude engine's flags"
  assert_nogrep  "$root/cap/l1-args-$h.txt" '^--allow-home$' "and not the omp engine's"
  assert_nogrep  "$fd/$h.json" '"error"' "the session was triaged"
  assert_grep    "$fd/run-stats.txt" '^l1_engine_omp: claude$' "run-stats names the engine"
  assert_grep    "$root/run.out" 'L1 model for omp: claude-test-model (on the claude engine)' "and so does the log"
  assert_no_file "$root/omp-calls.log" "the omp binary was never called"
  rm -rf "$root"
}

test_the_runs_reviewer_reviews_every_source_by_default(){
  echo "# no L1 engine chosen: the L2 engine reviews every source's sessions, and omp never runs"
  local root o h fd trip; root=$(setup_env); mk_session "$root" sess1
  o=$(mk_omp_session "$root" rrrr); h=$(hash_of "$o"); trip=$(mk_omp_tripwire "$root")
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap" AUTODREAM_L1_ENGINE_OMP=
  TEST_OMP_BIN="$trip" TEST_OMP_L1_MODEL= run_dream_omp "$root"
  unset FANOUT MOCK_CAPTURE_DIR AUTODREAM_L1_ENGINE_OMP
  fd=$(fdir "$root")
  assert_grep    "$fd/run-stats.txt" '^l2_engine: claude$' "claude, the first enabled adapter, is the run's reviewer"
  assert_grep    "$fd/run-stats.txt" '^l1_engine_omp: claude$' "and reviews the omp sessions"
  assert_grep    "$root/cap/l1-args-$h.txt" '^claude-haiku-5-5$' "with the reviewer's default model, not omp's"
  assert_grep    "$root/cap/l1-read-$h.txt" 'LIVE_BRANCH_MARKER' "while the omp adapter still linearized the session"
  assert_no_file "$root/omp-calls.log" "the omp binary was never called"
  rm -rf "$root"
  echo "# AUTODREAM_L2_ENGINE picks the reviewer for both passes, whatever the adapter order"
  root=$(setup_env); mk_session "$root" sess1
  o=$(mk_omp_session "$root" ssss); h=$(hash_of "$o"); trip=$(mk_omp_tripwire "$root")
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap" AUTODREAM_L1_ENGINE_OMP= AUTODREAM_ADAPTERS=omp,claude AUTODREAM_L2_ENGINE=claude
  TEST_OMP_BIN="$trip" TEST_OMP_L1_MODEL= run_dream_omp "$root"
  unset FANOUT MOCK_CAPTURE_DIR AUTODREAM_L1_ENGINE_OMP AUTODREAM_ADAPTERS AUTODREAM_L2_ENGINE
  fd=$(fdir "$root")
  assert_grep    "$fd/run-stats.txt" '^l1_engine_omp: claude$' "omp, though enabled first, is reviewed by the L2 engine"
  assert_no_file "$root/omp-calls.log" "and the omp binary was never called"
  rm -rf "$root"
  echo "# AUTODREAM_L1_ENGINE picks one L1 engine for every source, claude sessions included"
  local c hc; root=$(setup_env); mk_session "$root" sess1; c="$root/projects/proj-a/sess1.jsonl"; hc=$(hash_of "$c")
  o=$(mk_omp_session "$root" tttt); h=$(hash_of "$o")
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap" AUTODREAM_L1_ENGINE_OMP= AUTODREAM_L1_ENGINE=omp
  TEST_OMP_L1_MODEL= AUTODREAM_L1_MODEL=omp/test-model run_dream_omp "$root"
  unset FANOUT MOCK_CAPTURE_DIR AUTODREAM_L1_ENGINE_OMP AUTODREAM_L1_ENGINE
  fd=$(fdir "$root")
  assert_grep "$fd/run-stats.txt" '^l1_engine_claude: omp$' "the claude sessions are reviewed by omp"
  assert_grep "$fd/run-stats.txt" '^l1_engine_omp: omp$' "and so are the omp sessions"
  assert_grep "$root/cap/l1-args-$hc.txt" '^--allow-home$' "with the omp engine's flags"
  assert_grep "$fd/run-stats.txt" '^l2_engine: claude$' "while the summary stays on the L2 engine"
  rm -rf "$root"
}

test_an_unusable_l1_engine_override_fails_closed(){
  echo "# an L1 engine override that names no accepted adapter: no model call at all, not the omp engine"
  local root o h fd trip; root=$(setup_env); mk_session "$root" sess1
  o=$(mk_omp_session "$root" gggg); h=$(hash_of "$o"); trip=$(mk_omp_tripwire "$root")
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap" AUTODREAM_L1_ENGINE_OMP=nonesuch
  TEST_OMP_BIN="$trip" run_dream_omp "$root"
  unset FANOUT MOCK_CAPTURE_DIR AUTODREAM_L1_ENGINE_OMP
  fd=$(fdir "$root")
  assert_no_file "$root/cap/l1-args-$h.txt" "no worker started for the omp session"
  assert_grep    "$fd/$h.json" 'no L1 engine for this session' "it got the deterministic error record"
  assert_grep    "$root/run.out" 'names no accepted adapter' "the log says why"
  assert_grep    "$fd/run-stats.txt" '^l1_engine_omp: none$' "run-stats shows no engine"
  assert_no_file "$root/omp-calls.log" "the omp binary was never called"
  rm -rf "$root"
}

test_omp_session_roots_come_from_the_host_setting(){
  echo "# AUTODREAM_SESSION_ROOTS_OMP replaces the omp manifest's default roots"
  local root o alt fd; root=$(setup_env); mk_session "$root" sess1
  mk_omp_session "$root" jjjj >/dev/null
  o=$(mk_omp_session "$root" kkkk); alt="$root/store/sessions/proj-alt"; mkdir -p "$alt"
  mv "$o" "$alt/"
  AUTODREAM_SESSION_ROOTS_OMP="$root/elsewhere:$root/store/sessions" run_dream_omp "$root"
  fd=$(fdir "$root")
  assert_grep   "$fd/sessions.txt" 'store/sessions/proj-alt/.*_kkkk.jsonl' "a session under the configured root is enumerated"
  assert_nogrep "$fd/sessions.txt" '_jjjj.jsonl' "the manifest's default root is not"
  rm -rf "$root"
}

test_l1_provenance_and_served_models_are_recorded(){
  echo "# who each engine runs as, and which model answered each call, reach the log and run-stats"
  local root fd; root=$(setup_env); mk_session "$root" sess1; mk_session "$root" sess2
  run_dream "$root"
  fd=$(fdir "$root")
  assert_grep "$root/run.out" 'login for the claude engine: provider=firstParty auth=claude.ai plan=max account=test@example.com' "the log names the provider, sign-in, plan and account"
  assert_grep "$fd/run-stats.txt" '^login_claude: provider=firstParty auth=claude.ai plan=max account=test@example.com$' "and so does run-stats"
  assert_grep "$fd/run-stats.txt" '^l1_served_models: claude-haiku-5-5=2$' "each call is counted under the model that answered it"
  assert_grep "$fd/run-stats.txt" '^l1_served_mismatch: 0$' "none was answered by another model"
  assert_grep "$fd/run-stats.txt" '^l1_cost_usd_estimate: 0.0250$' "and the engine's cost estimates are summed"
  rm -rf "$root"
}

test_an_engine_failing_its_login_requirement_is_handed_nothing(){
  echo "# AUTODREAM_REQUIRE_LOGIN: a summary engine whose login does not match stops the run before it starts"
  local root fd h o; root=$(setup_env); mk_session "$root" sess1
  AUTODREAM_REQUIRE_LOGIN="provider=firstParty plan=pro" MOCK_CALL_LOG="$root/calls.log" run_dream "$root"
  assert_no_file "$root/calls.log" "no worker started"
  assert_grep "$root/run.out" 'the claude engine, which writes the summary, fails AUTODREAM_REQUIRE_LOGIN (plan is max, not pro). Refusing to start.' "the log says which requirement failed"
  assert_nogrep "$root/run.exit" '^0$' "and the run fails"
  rm -rf "$root"
  echo "# an L1 engine whose login does not match is handed no transcript, while the others run"
  root=$(setup_env); mk_session "$root" sess1; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  o=$(mk_omp_session "$root" uuuu)
  AUTODREAM_REQUIRE_LOGIN="provider=firstParty" run_dream_omp "$root"
  fd=$(fdir "$root")
  assert_grep   "$root/run.out" 'login for the omp engine: provider=unknown auth=unknown plan=unknown account=unknown' "omp reports no login, so every field is unknown"
  assert_grep   "$root/run.out" 'the omp engine fails AUTODREAM_REQUIRE_LOGIN (provider is unknown, not firstParty)' "and fails the requirement"
  assert_grep   "$fd/$(hash_of "$o").json" 'no L1 engine for this session' "its session gets the deterministic error record"
  assert_grep   "$fd/$h.json" 'always run tests after edits' "while the claude session is triaged"
  assert_grep   "$fd/run-stats.txt" '^login_omp: provider=unknown auth=unknown plan=unknown account=unknown$' "run-stats records both logins"
  rm -rf "$root"
  echo "# a met requirement triages as usual, and a requirement on an unknown key fails closed"
  root=$(setup_env); mk_session "$root" sess1; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  AUTODREAM_REQUIRE_LOGIN="provider=firstParty auth=claude.ai plan=max account=test@example.com" run_dream "$root"
  assert_grep "$(fdir "$root")/$h.json" 'always run tests after edits' "a matching login triages the session"
  rm -rf "$root"
  root=$(setup_env); mk_session "$root" sess1
  AUTODREAM_REQUIRE_LOGIN="region=us" MOCK_CALL_LOG="$root/calls.log" run_dream "$root"
  assert_no_file "$root/calls.log" "an unknown key starts no worker"
  assert_grep "$root/run.out" 'region=us is not a provider, auth, plan or account requirement' "and says why"
  rm -rf "$root"
}

test_a_call_answered_by_another_model_loses_its_findings(){
  echo "# AUTODREAM_L1_REQUIRE_SERVED=1: findings from a call another model answered never reach L2"
  local root fd h; root=$(setup_env); mk_session "$root" sess1
  h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  AUTODREAM_L1_REQUIRE_SERVED=1 MOCK_SERVED_MODEL=claude-other-model run_dream "$root"
  fd=$(fdir "$root")
  assert_grep   "$fd/l1-served.tsv" "^$h	claude	claude-haiku-5-5	claude-other-model	" "the call is recorded under the model that answered it"
  assert_grep   "$fd/run-stats.txt" '^l1_served_mismatch: [1-9]' "and counted as a mismatch"
  assert_nogrep "$fd/$h.json" 'always run tests after edits' "the substituted model's findings are gone"
  if grep -qs 'answered by \[claude-other-model\], not the requested model \[claude-haiku-5-5\]' "$fd/$h.json" "$fd/$h.json.err"; then
    ok "the failure names both models"
  else no "the failure names both models"; fi
  rm -rf "$root"
  echo "# without the setting a mismatch is recorded and the findings are kept"
  root=$(setup_env); mk_session "$root" sess1; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  MOCK_SERVED_MODEL=claude-other-model run_dream "$root"
  fd=$(fdir "$root")
  assert_grep "$fd/$h.json" 'always run tests after edits' "the findings are kept"
  assert_grep "$fd/run-stats.txt" '^l1_served_mismatch: 1$' "and the mismatch is counted"
  rm -rf "$root"
}

test_omp_stats_describe_the_live_branch_only(){
  echo "# omp stats are computed on the live branch, so abandoned turns cannot lift a session past the noise gate"
  local root; root=$(setup_env); mk_session "$root" sess1
  local o; o=$(mk_omp_session "$root" dddd); local h; h=$(hash_of "$o")
  # Two real user turns on the live branch in mk_omp_session; add an abandoned user turn.
  local tmp; tmp=$(mktemp "$root/o.XXXXXX")
  { sed '/"id":"ax"/q' "$o"
    printf '%s\n' '{"type":"message","id":"ux","parentId":"ax","timestamp":"2020-01-02T10:00:02.500Z","message":{"role":"user","content":[{"type":"text","text":"abandoned user turn"}]}}'
    sed '1,/"id":"ax"/d' "$o"; } > "$tmp" && mv "$tmp" "$o"; touch -t "$STAMP" "$o"
  run_dream_omp "$root"
  local fd; fd=$(fdir "$root")
  assert_eq "$(jq -r .user_message_count "$fd/$h.stats.json")" "2" "the abandoned user turn is not counted"
  assert_no_file "$fd/$h.statsin.jsonl" "the temporary linearized copy is removed"
  rm -rf "$root"
}

test_omp_nested_child_is_a_sidechain_of_its_bucket(){
  echo "# an omp advisor child: grouped under its bucket, exempt from the noise gate, no human turns (#114)"
  local root; root=$(setup_env); mk_session "$root" sess1
  local o; o=$(mk_omp_session "$root" nnnn)
  local cdir="${o%.jsonl}" adv h ph
  mkdir -p "$cdir"; adv="$cdir/__advisor.jsonl"
  { printf '%s\n' '{"type":"title","title":"t","v":1}'
    printf '%s\n' '{"type":"session","id":"01a00000-0000-7000-8000-000000000002","cwd":"/tmp/proj-o","timestamp":"2020-01-02T10:00:00.000Z"}'
    printf '%s\n' '{"type":"message","id":"u1","parentId":null,"timestamp":"2020-01-02T10:00:01.000Z","message":{"role":"user","attribution":"agent","content":[{"type":"text","text":"Session update from the parent"}]}}'
    printf '%s\n' '{"type":"message","id":"a1","parentId":"u1","timestamp":"2020-01-02T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"noted"}]}}'
  } > "$adv"
  touch -t "$STAMP" "$adv"
  h=$(hash_of "$adv"); ph=$(hash_of "$o")
  run_dream_omp "$root"
  local fd; fd=$(fdir "$root")
  assert_eq "$(jq -r '"\(.user_message_count) \(.isSidechain) \(.nested)"' "$fd/$h.stats.json")" "0 true true" "the advisor reads no human turns and is a nested sidechain"
  assert_nogrep "$fd/$h.json" 'below_noise_gate' "so the noise gate does not skip it"
  assert_eq "$(jq -r .project "$fd/$h.json")" "proj-o" "its project is the bucket, not the parent's timestamped stem"
  assert_eq "$(jq -r .project "$fd/$ph.json")" "proj-o" "the same bucket as its parent"
  rm -rf "$root"
}

test_omp_session_that_cannot_be_linearized_is_an_error_record(){
  echo "# an omp tree the linearizer refuses is a deterministic error record, never a worker run"
  local root; root=$(setup_env); mk_session "$root" sess1
  local o; o=$(mk_omp_session "$root" cccc); local h; h=$(hash_of "$o")
  printf '%s\n' '{"type":"message","id":"u2","parentId":"u1","message":{"role":"user","content":[]}}' >> "$o"   # duplicate id
  touch -t "$STAMP" "$o"
  export FANOUT=1 MOCK_CALL_LOG="$root/calls.log"; run_dream_omp "$root"; unset FANOUT MOCK_CALL_LOG
  local fd; fd=$(fdir "$root")
  assert_grep   "$fd/$h.json" 'could not be normalized by the omp adapter' "the session carries a structured error"
  assert_grep   "$fd/$h.json" 'linearize:' "and the linearizer's reason is in the record"
  assert_nogrep "$root/calls.log" "$h" "no worker was started for it"
  assert_file   "$root/dreams/$DATE.md" "the run still reports"
  rm -rf "$root"
}

test_l2_gets_the_skills_inventory_and_per_source_facts(){
  echo "# L2 reads a skills inventory and the facts of every harness that contributed sessions"
  local root; root=$(setup_env); mk_session "$root" sess1
  mkdir -p "$root/home/.claude/skills/alpha" "$root/home/.claude/skills/beta"
  printf -- '---\nname: alpha\n---\n' > "$root/home/.claude/skills/alpha/SKILL.md"
  printf -- '---\nname: beta\n---\n' > "$root/home/.claude/skills/beta/SKILL.md"
  run_dream_omp "$root"   # both adapters enabled, but only a claude session exists
  local fd; fd=$(fdir "$root")
  assert_grep   "$fd/skills-inventory.txt" '^# skills-inventory.txt' "the inventory is written with its header"
  assert_grep   "$fd/skills-inventory.txt" '^alpha' "an installed skill is listed"
  assert_grep   "$fd/skills-inventory.txt" '^beta' "and the other one"
  assert_grep   "$fd/adapter-facts.md" '^## Source: claude$' "the contributing source has a facts section"
  assert_grep   "$fd/adapter-facts.md" 'permissions.allow' "carrying that harness's remedy surfaces"
  assert_nogrep "$fd/adapter-facts.md" 'Oh My Pi' "a source that contributed nothing is absent"
  rm -rf "$root"

  root=$(setup_env); mk_session "$root" sess1; mk_omp_session "$root" eeee >/dev/null
  run_dream_omp "$root"
  fd=$(fdir "$root")
  assert_grep   "$fd/adapter-facts.md" '^## Source: omp$' "a second harness that contributed gets its own section"
  assert_grep   "$fd/adapter-facts.md" '^## Source: claude$' "alongside the first"
  rm -rf "$root"
}

test_unavailable_skills_inventory_says_so(){
  echo "# when no adapter can list skills the file says unavailable instead of claiming none are installed"
  local root; root=$(setup_env); mk_session "$root" sess1
  local ad="$root/adapters"; cp -R "$REPO/adapters" "$ad"
  # claude's skills-inventory subcommand fails
  sed -i.bak 's|^  skills-inventory)$|  skills-inventory)\n    exit 1|' "$ad/claude/adapter.sh"; rm -f "$ad/claude/adapter.sh.bak"
  export ADAPTERS_ROOT="$ad"; AUTODREAM_ADAPTERS=claude run_dream_omp "$root"; unset ADAPTERS_ROOT
  assert_grep "$(fdir "$root")/skills-inventory.txt" '^# skills-inventory.txt unavailable' "the sentinel line is written"
  rm -rf "$root"
}

test_harness_addendum_reaches_only_that_harnesss_workers(){
  echo "# an adapter's triage.md is appended for its own sessions only; claude workers get the document unchanged"
  local root; root=$(setup_env); mk_session "$root" sess1
  local o; o=$(mk_omp_session "$root" ffff)
  local hc ho; hc=$(hash_of "$root/projects/proj-a/sess1.jsonl"); ho=$(hash_of "$o")
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap"; run_dream_omp "$root"; unset FANOUT MOCK_CAPTURE_DIR
  assert_grep   "$root/cap/l1-stdin-$ho.txt" '^## Harness addendum: OMP transcripts' "the omp worker got the omp addendum"
  assert_grep   "$root/cap/l1-stdin-$ho.txt" 'RESTRICTED SCHEMA: advisor sidecars' "including the advisor rules"
  assert_grep   "$root/cap/l1-stdin-$ho.txt" '^# Session Triage' "after the shared document"
  assert_nogrep "$root/cap/l1-stdin-$hc.txt" 'Harness addendum' "the claude worker got no addendum"
  python3 - "$root/cap/l1-stdin-$hc.txt" "$REPO/prompts/SESSION_TRIAGE.md" <<'PY' && ok "and its prompt is exactly SESSION_TRIAGE.md plus the stats block" || no "and its prompt is exactly SESSION_TRIAGE.md plus the stats block"
import sys
got = open(sys.argv[1]).read()
doc = open(sys.argv[2]).read()
i = got.index(doc)                      # the shared document is present verbatim
rest = got[i + len(doc):].strip()
sys.exit(0 if rest == "" or rest.startswith("## Precomputed session stats") else 1)
PY
  rm -rf "$root"
}

test_l2_is_read_only_and_the_runner_writes_the_report(){
  echo "# L2 holds Glob and Read only; the report is written by the runner from stdout"
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_CAPTURE_DIR="$root/cap"; run_dream "$root"; unset MOCK_CAPTURE_DIR
  assert_grep   "$root/cap/l2-args.txt" '^Glob$' "L2 is given the Glob tool"
  assert_grep   "$root/cap/l2-args.txt" '^Read$' "and Read"
  assert_nogrep "$root/cap/l2-args.txt" '^Write$' "and not Write"
  assert_nogrep "$root/cap/l2-args.txt" '^Edit$' "and not Edit"
  assert_grep   "$root/cap/l2-stdin.txt" 'Report destination' "the prompt names the destination, it does not ask for a write"
  assert_nogrep "$root/dreams/$DATE.md" 'AUTODREAM_REPORT_END' "the sentinel is stripped from the report"
  assert_grep   "$root/dreams/$DATE.md" 'open-questions=0' "the report body is intact"
  assert_grep   "$root/run.out" 'report: ' "the lines after the sentinel reach the run log"
  rm -rf "$root"
}

test_l2_report_with_a_marker_but_no_sentinel_is_not_delivered(){
  echo "# a complete-looking report with no sentinel is a degraded capture: moved aside, date retried"
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=l2_partial_marker AUTODREAM_L2_ATTEMPTS=1; run_dream "$root"; unset MOCK_MODE AUTODREAM_L2_ATTEMPTS
  assert_no_file "$root/dreams/$DATE.md" "no report stands at the live path"
  local n; n=$(find "$root/dreams" -maxdepth 1 -name "$DATE.md.partial-*" | wc -l | tr -d ' ')
  assert_eq "$n" "1" "the capture was kept as a partial"
  assert_grep "$root/run.out" 'no AUTODREAM_REPORT_END sentinel' "the log says why"
  assert_eq "$(cat "$root/run.exit")" "1" "a night that delivered nothing exits non-zero even though the aggregator exited 0"
  rm -rf "$root"
}

test_pin_block_must_follow_the_sentinel_and_be_closed(){
  echo "# pins come only from a closed block after the last sentinel"
  local root
  # unterminated block: nothing stored
  root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=pins_unterminated; run_dream "$root"; unset MOCK_MODE
  assert_no_file "$(fdir "$root")/pins.jsonl" "an unterminated pin block proposes nothing"
  rm -rf "$root"
  # a block quoted inside the report body: nothing stored
  root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=pins_in_body; run_dream "$root"; unset MOCK_MODE
  assert_no_file "$(fdir "$root")/pins.jsonl" "a pin block quoted in the report body is not a block"
  assert_file   "$root/dreams/$DATE.md" "while the report itself was delivered"
  rm -rf "$root"
  # a well-formed block: the runner writes pins.jsonl
  root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=pins; run_dream "$root"; unset MOCK_MODE
  assert_eq "$(wc -l < "$(fdir "$root")/pins.jsonl" | tr -d ' ')" "1" "a closed block after the sentinel becomes pins.jsonl, written by the runner"
  rm -rf "$root"
}

test_dream_triage_is_opt_in_and_leaves_l2_alone(){
  echo "# dream triage: off by default; on, it runs last on L2's engine and cannot disturb the night"
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_CAPTURE_DIR="$root/cap"; run_dream "$root"; unset MOCK_CAPTURE_DIR
  assert_no_file "$root/dreams/$DATE.triage.md" "default: no triage file"
  assert_no_file "$root/cap/triage-stdin.txt" "default: no extra model call"
  assert_nogrep "$root/run.out" 'dream triage' "default: the log does not mention it"
  rm -rf "$root"

  root=$(setup_env); mk_session "$root" sess1
  export MOCK_CAPTURE_DIR="$root/cap" AUTODREAM_TRIAGE=1; run_dream "$root"; unset MOCK_CAPTURE_DIR AUTODREAM_TRIAGE
  assert_grep "$root/dreams/$DATE.triage.md" '^# Dream triage' "AUTODREAM_TRIAGE=1 writes dreams/DATE.triage.md"
  assert_grep "$root/cap/triage-stdin.txt" '^# Dream triage worker' "through the triage prompt"
  assert_grep "$root/cap/triage-args.txt" '^Glob$' "on the read-only L2 engine arguments"
  assert_grep "$root/cap/l2-stdin.txt" 'Report destination' "L2's own captured prompt is still L2's"
  assert_nogrep "$root/cap/l2-stdin.txt" 'Dream triage worker' "and carries no triage text"
  assert_grep "$root/cap/l2-args.txt" '^Read$' "L2's captured arguments are still L2's"
  assert_eq "$(cat "$root/run.exit")" "0" "the run still exits 0"
  assert_file "$root/dreams/$DATE.md" "and the report is there"
  assert_grep "$root/autodream/findings/$DATE/triage/grounding.json" '"claims"' "grounding.json was written"
  rm -rf "$root"

  root=$(setup_env); mk_session "$root" sess1
  export AUTODREAM_TRIAGE=1 MOCK_TRIAGE_MODE=fail; run_dream "$root"; unset AUTODREAM_TRIAGE MOCK_TRIAGE_MODE
  assert_eq "$(cat "$root/run.exit")" "0" "a failed triage call does not fail the run"
  assert_grep "$root/run.out" "dream triage produced no worklist" "and the log says so"
  assert_file "$root/dreams/$DATE.md" "the report still ships"
  rm -rf "$root"

  root=$(setup_env); mk_session "$root" sess1
  export AUTODREAM_TRIAGE=1 MOCK_MODE=l2_fail AUTODREAM_L2_ATTEMPTS=1 MOCK_CAPTURE_DIR="$root/cap"; run_dream "$root"
  unset AUTODREAM_TRIAGE MOCK_MODE AUTODREAM_L2_ATTEMPTS MOCK_CAPTURE_DIR
  assert_no_file "$root/cap/triage-stdin.txt" "no report was delivered, so no triage call was made"
  rm -rf "$root"
}

test_l2_engine_comes_from_an_adapter(){
  echo "# the L2 engine is an adapter: default the first enabled one, AUTODREAM_L2_ENGINE picks another"
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_CAPTURE_DIR="$root/cap"; run_dream "$root"; unset MOCK_CAPTURE_DIR
  assert_grep "$(fdir "$root")/run-stats.txt" '^l2_engine: claude$' "default: the first enabled adapter"
  assert_grep "$(fdir "$root")/run-stats.txt" '^l2_model: default$' "claude names no L2 model, so the CLI default runs"
  assert_grep "$(fdir "$root")/run-stats.txt" '^l1_model_claude: claude-haiku-5-5$' "run-stats records each adapter's L1 model"
  assert_nogrep "$root/cap/l2-args.txt" '^--model$' "no --model reached the claude engine"
  rm -rf "$root"

  root=$(setup_env); mk_session "$root" sess1
  export MOCK_CAPTURE_DIR="$root/cap" AUTODREAM_L2_ENGINE=omp AUTODREAM_L2_MODEL_OMP=omp/l2-model AUTODREAM_L2_MODEL=generic/ignored
  run_dream_omp "$root"; unset MOCK_CAPTURE_DIR AUTODREAM_L2_ENGINE AUTODREAM_L2_MODEL_OMP AUTODREAM_L2_MODEL
  local fd; fd=$(fdir "$root")
  assert_grep "$fd/run-stats.txt" '^l2_engine: omp$' "AUTODREAM_L2_ENGINE selects the engine"
  assert_grep "$fd/run-stats.txt" '^l2_model: omp/l2-model$' "the per-adapter model beats the generic one"
  assert_grep "$root/cap/l2-args.txt" '^--allow-home$' "the omp adapter's own flags reached L2"
  assert_grep "$root/cap/l2-args.txt" '^--tools=Glob,Read$' "and its read-only tool grant"
  assert_grep "$root/cap/l2-args.txt" '^omp/l2-model$' "and the model"
  assert_file "$root/dreams/$DATE.md" "the report was delivered through the omp engine"
  rm -rf "$root"

  root=$(setup_env); mk_session "$root" sess1
  AUTODREAM_L2_ENGINE=nonesuch run_dream "$root"
  assert_grep   "$root/run.out" 'AUTODREAM_L2_ENGINE=nonesuch is not an accepted adapter' "an unknown engine is refused"
  assert_no_file "$root/dreams/$DATE.md" "and no report is produced"
  rm -rf "$root"

  # an engine that cannot print a command is refused before L1 as well
  root=$(setup_env); mk_session "$root" sess1
  local ad="$root/adapters"; cp -R "$REPO/adapters" "$ad"
  jq 'del(.l2_model)' "$ad/omp/manifest.json" > "$ad/omp/manifest.json.new" && mv "$ad/omp/manifest.json.new" "$ad/omp/manifest.json"
  export ADAPTERS_ROOT="$ad" AUTODREAM_L2_ENGINE=omp; run_dream_omp "$root"; unset ADAPTERS_ROOT AUTODREAM_L2_ENGINE
  assert_grep   "$root/run.out" 'omp adapter cannot produce an L2 command' "omp with no model resolved is refused"
  assert_no_file "$(fdir "$root")/$(hash_of "$root/projects/proj-a/sess1.jsonl").json" "before any worker ran"
  rm -rf "$root"
}

test_config_written_by_install_enables_adapters_and_l2_engine(){
  echo "# AUTODREAM_ADAPTERS and AUTODREAM_L2_ENGINE set in the config reach the run"
  local root; root=$(setup_env); mk_session "$root" sess1; mk_omp_session "$root" gggg >/dev/null
  printf '# adapters (managed by install.sh)\nAUTODREAM_ADAPTERS=claude,omp\nAUTODREAM_L2_ENGINE=omp\nAUTODREAM_L2_MODEL_OMP=omp/cfg-model\n' > "$root/autodream/config"
  mkdir -p "$root/home"
  HOME="$root/home" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" OMP_BIN="$MOCK" AUTODREAM_L1_MODEL_OMP=omp/test-model \
    AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    /bin/bash "$RUN" "$DATE" > "$root/run.out" 2>&1
  local fd; fd=$(fdir "$root")
  assert_grep "$fd/run-stats.txt" 'adapters_enabled: claude,omp' "the config enabled both harnesses"
  assert_grep "$fd/run-stats.txt" '^l2_engine: omp$' "and chose the omp engine for L2"
  assert_grep "$fd/run-stats.txt" '^l2_model: omp/cfg-model$' "with the model from the config"
  rm -rf "$root"
}

test_replay_harness_works_on_synthetic_data(){
  echo "# tests/replay.sh: artifacts mode flags a corrupt findings JSON, ingest mode replays a real-shaped root"
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local fd out; fd=$(fdir "$root")
  out=$(bash "$REPO/tests/replay.sh" --artifacts "$fd" 2>&1); local rc=$?
  assert_eq "$rc" "0" "artifacts mode passes on a healthy findings directory"
  printf '%s' "$out" > "$root/replay.out"
  assert_grep "$root/replay.out" 'PASS  all 1 findings JSONs have the findings-array shape' "and says what it checked"
  printf 'not json' > "$fd/$(hash_of "$root/projects/proj-a/sess1.jsonl").json"
  out=$(bash "$REPO/tests/replay.sh" --artifacts "$fd" 2>&1); rc=$?
  printf '%s' "$out" > "$root/replay.out"
  assert_eq "$rc" "0" "a corrupt findings JSON is reported but is archive data, not a replay failure"
  assert_grep "$root/replay.out" 'WARN  1 of 1 findings JSONs lack a findings array' "and counted"
  out=$(bash "$REPO/tests/replay.sh" --artifacts "$root/nonexistent" 2>&1); rc=$?
  assert_eq "$rc" "1" "a directory that does not exist fails"
  out=$(bash "$REPO/tests/replay.sh" --ingest claude "$root/projects" "$DATE" 2>&1); rc=$?
  printf '%s' "$out" > "$root/replay.out"
  assert_eq "$rc" "0" "ingest mode runs the whole runner over a session root with the mock engines"
  assert_grep "$root/replay.out" 'enumerated 1 session(s), triaged 1' "and finds the session"
  out=$(bash "$REPO/tests/replay.sh" --ingest claude "$root/projects" 2001-01-01 2>&1); rc=$?
  printf '%s' "$out" > "$root/replay.out"
  assert_grep "$root/replay.out" 'nothing was replayed' "a date with no sessions is reported, not passed silently"
  rm -rf "$root"
}

test_skill_fields_dropped_without_a_sidecar(){
  echo "# a session with no stats sidecar keeps no worker-written skill fields (Codex review of 0129fc0)"
  local root; root=$(setup_env); mk_session "$root" sess1
  # mock-claude writes skills_invoked:[] itself. With no sidecar to overwrite it, that list
  # is the model's guess, and L2 would rank it as a mechanical count.
  export AUTODREAM_STATS_BIN="$root/does-not-exist.sh"
  run_dream "$root"
  unset AUTODREAM_STATS_BIN
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  local fj="$(fdir "$root")/$h.json"
  assert_eq "$(jq -r 'has("skills_invoked") or has("skills_invoked_count") or has("skills_invoked_counts") or has("skills_authored")' "$fj")" "false" \
    "the unmeasured skill fields are removed rather than believed"
  assert_eq "$(jq -r '.findings | type' "$fj")" "array" "the rest of the findings JSON survives"
  # Absence alone cannot say why: gated stubs and older findings carry no skill fields
  # either. The runner records the count (Codex review of 1ee66e4).
  assert_grep "$(fdir "$root")/run-stats.txt" 'skills_unmeasured: 1' "run-stats counts the session whose skills went unmeasured"
  rm -rf "$root"
}

test_skill_fields_dropped_with_a_partial_sidecar(){
  echo "# a sidecar missing any of the four skill keys is unmeasured, not half-enforced (Codex review of 33bf9b1)"
  local root; root=$(setup_env); mk_session "$root" sess1
  # skills_invoked present, skills_invoked_count(s) and skills_authored absent: copying the
  # one key and keeping the worker's other three would rank guesses as counts.
  local stub="$root/stats-partial.sh"
  printf '%s\n' '#!/bin/bash' 'printf %s "{\"transcript_bytes\":10,\"user_message_count\":5,\"tool_call_count\":9,\"skills_invoked\":[\"x\"]}" > "$2"' > "$stub"
  chmod +x "$stub"
  export AUTODREAM_STATS_BIN="$stub"
  run_dream "$root"
  unset AUTODREAM_STATS_BIN
  local fj; fj="$(fdir "$root")/$(hash_of "$root/projects/proj-a/sess1.jsonl").json"
  assert_eq "$(jq -r 'has("skills_invoked") or has("skills_invoked_count") or has("skills_invoked_counts") or has("skills_authored")' "$fj")" "false" \
    "every skill field is removed when the sidecar lacks any of them"
  assert_grep "$(fdir "$root")/run-stats.txt" 'skills_unmeasured: 1' "and the session is counted as unmeasured"
  assert_nogrep "$root/run.out" 'with no sidecar' "the log does not claim the sidecar was missing"
  rm -rf "$root"
}

test_builtin_slash_commands_are_not_skill_invocations(){
  echo "# a session that only ran /clear and /model invoked no skill"
  local f="$TMPDIR/cc-builtin.$$.jsonl" out="$TMPDIR/cc-builtin.$$.out"
  printf '%s\n' \
    '{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}' \
    '{"type":"user","message":{"content":"<command-name>/model</command-name>"}}' \
    '{"type":"user","message":{"content":"<command-name>/triage</command-name>"}}' > "$f"
  "$REPO/bin/session-stats.sh" "$f" "$out"
  assert_eq "$(jq -r '.skills_invoked | join(",")' "$out")" "triage" "only the real skill is counted"
  rm -f "$f" "$out" 2>/dev/null || true
}

test_skill_fields_are_enforced_from_the_sidecar(){
  echo "# a worker that ignores the precomputed skill stats gets overwritten, not believed"
  local root; root=$(setup_env)
  # A session that really did invoke skills. mock-claude always writes skills_invoked:[]
  # (see write_findings), the worker behaviour behind the 2026-09-04 "zero skills across
  # 3,988 tool calls" claim. The runner must not take it.
  local f="$root/projects/proj-a/sess1.jsonl"
  printf '%s\n' \
    '{"type":"user","cwd":"/tmp/proj-a","message":{"content":"<command-name>/triage</command-name>"}}' \
    '{"type":"user","message":{"content":"keep going"}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"triage"}},{"type":"tool_use","name":"Skill","input":{"skill":"deslop"}},{"type":"tool_use","name":"Write","input":{"file_path":"/h/.claude/skills/fresh/SKILL.md"}}]}}' \
    > "$f"
  touch -t "$STAMP" "$f"
  run_dream "$root"
  local h; h=$(hash_of "$f")
  assert_eq "$(jq -r '.skills_invoked | join(",")' "$(fdir "$root")/$h.json")" "deslop,triage" \
    "the findings JSON carries the measured skills, not the worker's empty list"
  assert_eq "$(jq -r '.skills_invoked_counts.triage' "$(fdir "$root")/$h.json")" "2" \
    "per-skill counts survive into the findings so top-5-by-count can be ranked"
  assert_eq "$(jq -r '.skills_invoked_count' "$(fdir "$root")/$h.json")" "3" \
    "the total counts invocations, not distinct skills"
  assert_eq "$(jq -r '.skills_authored | join(",")' "$(fdir "$root")/$h.json")" "fresh" \
    "authoring a skill is not invoking one"
  assert_grep "$(fdir "$root")/run-stats.txt" 'skills_enforcement_failed: 0' "no rewrite failed"
  assert_grep "$(fdir "$root")/run-stats.txt" 'skills_unmeasured: 0' "a run with every sidecar present records zero unmeasured, not nothing"
  rm -rf "$root"
}

# ---- Upgrade lag: run.sh is a symlink, the libraries are not there yet -------
# The live install symlinks each script individually into ~/.claude/autodream, so
# merging a branch changes run.sh the instant it lands while lib-project.sh,
# adapters.sh, preflight.sh and adapters/ only appear when install.sh is re-run.
# Every other test invokes $REPO/bin/run.sh directly, where the libraries sit
# right beside it, so 358 green assertions all ran with them present and none of
# them exercised the shape the nightly actually has.
test_upgrade_lag_install_still_produces_a_report(){
  echo "# upgrade lag: run.sh symlinked into an install dir with no libraries still reports"
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$T/home/.claude/projects/proj-a" "$T/autodream" "$T/dreams"
  cp "$REPO/prompts/SESSION_TRIAGE.md" "$T/autodream/SESSION_TRIAGE.md"
  cp "$REPO/prompts/PROMPT.md"         "$T/autodream/PROMPT.md"
  cp "$REPO/prompts/L2_SYSTEM.txt"     "$T/autodream/L2_SYSTEM.txt"  # install.sh links it too
  # Exactly what a pre-adapter install left behind: the helper scripts, and
  # run.sh as a symlink into the repo. Deliberately NOT lib-project.sh,
  # adapters.sh, preflight.sh or adapters/.
  local h
  for h in prune-self-sessions.sh root-probe.sh slim-transcript.sh session-stats.sh \
           overlap-stats.sh vault-notes.sh x-bookmarks.sh notify.sh; do
    [ -f "$REPO/bin/$h" ] && ln -s "$REPO/bin/$h" "$T/autodream/$h"
  done
  ln -s "$REPO/bin/run.sh" "$T/autodream/run.sh"
  mk_session_in "$T/home/.claude/projects/proj-a" s1
  HOME="$T/home" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$T/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 AUTODREAM_L1_CHUNK_BYTES=300000 \
    AUTODREAM_DIR="$T/autodream" DREAMS_DIR="$T/dreams" \
    bash "$T/autodream/run.sh" "$DATE" > "$T/run.out" 2>&1
  local rc=$?
  cat "$T/autodream/logs/run-$DATE.log" >> "$T/run.out" 2>/dev/null || true
  assert_eq "$rc" "0" "a symlinked runner with no installed libraries exits 0"
  assert_nogrep "$T/run.out" 'session_hash: command not found' "session_hash resolved"
  # The helper is not in the install dir yet (install.sh has not run again), and the window is
  # still on: the runner finds session-window.sh in the checkout its symlink points into.
  assert_grep "$T/autodream/findings/$DATE/run-stats.txt" 'session_window: on$' "the window is on although the install has no helper link yet"
  assert_grep "$T/autodream/findings/$DATE/run-stats.txt" 'l1_chunk_bytes: 300000$' "and so is chunked triage, found in the checkout the same way"
  assert_nonempty "$T/dreams/$DATE.md" "the upgrade-lag install still produced a report"
  rm -rf "$T"
}

# ---- Forced hash collision: the branch four review rounds kept touching -----
# A natural 48-bit collision cannot be produced in a test, so the hash is stubbed:
# a fake `shasum` returning a constant makes every session collide. Without this,
# every assertion passes whether the collision handling works or not — which is
# exactly what happened while this branch was patched across four review rounds.
#
# The stub goes in $HOME/.local/bin and run_dream_collision puts that directory first on
# PATH, because run.sh appends its own fixed list after the caller's PATH. A stub that is not
# first on PATH is simply not seen: the first version of this test put it in a temp dir
# behind the system one and silently measured nothing.
collision_sandbox(){ # -> a root whose HOME holds a constant-hash shasum stub
  local root; root=$(setup_env)
  mkdir -p "$root/home/.local/bin"
  printf '#!/bin/bash\ncat >/dev/null 2>&1\nprintf "%%s  -\\n" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"\n' \
    > "$root/home/.local/bin/shasum"
  chmod +x "$root/home/.local/bin/shasum"
  printf '%s' "$root"
}
run_dream_collision(){ # $1=root
  # run.sh appends to the caller's PATH, so the constant-hash stub has to be first on it.
  PATH="$1/home/.local/bin:$PATH" HOME="$1/home" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$1/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    PROJECTS_DIR="$1/projects" AUTODREAM_DIR="$1/autodream" DREAMS_DIR="$1/dreams" \
    /bin/bash "$RUN" "$DATE" > "$1/run.out" 2>&1
  local rc=$?
  cat "$1/autodream/logs/run-$DATE.log" >> "$1/run.out" 2>/dev/null || true
  return $rc
}

test_forced_hash_collision_drops_both(){
  echo "# collision: two paths on one hash drop BOTH and never reach dispatch"
  local root; root=$(collision_sandbox)
  mk_session "$root" one
  mk_session "$root" two
  run_dream_collision "$root"
  local rc=$?
  local d; d=$(fdir "$root")
  assert_eq "$rc" "0" "a handled collision is not a run failure"
  assert_grep "$root/run.out" 'COLLISION' "the collision is detected and logged"
  # The design requires this explicitly: neither session may reach the artifact
  # they would have shared. Asserting the counters without asserting this would
  # have let the drop be bookkeeping only.
  assert_no_file "$d/aaaaaaaaaaaa.json" "the shared artifact is never written"
  assert_no_file "$d/aaaaaaaaaaaa.stats.json" "nor its stats sidecar"
  assert_grep "$d/run-stats.txt" 'sessions_found_raw: 2' "RAW still reports what was ENUMERATED"
  assert_grep "$d/run-stats.txt" 'sessions_dropped_to_collision: 2' "both dropped paths are counted"
  assert_grep "$d/run-stats.txt" 'self_sessions_excluded: 0' "collided files are NOT called autodream-own"
  assert_grep "$d/run-stats.txt" 'sessions_hash_collision: 1' "the collision is counted"
  # BOTH paths gone. This is the assertion that would have caught the branch
  # logging "skipping both" while skipping neither.
  assert_eq "$(grep -c . "$d/sessions.txt.raw" 2>/dev/null || true)" "0" \
    "both colliding paths are removed from the worklist"
  assert_eq "$(grep -c . "$d/sessions-source.txt" 2>/dev/null || true)" "0" \
    "no provenance row survives for a dropped session"
  rm -rf "$root"
}

test_collision_worklist_failure_aborts(){
  echo "# collision: a worklist rewrite that cannot happen fails closed"
  local root; root=$(collision_sandbox)
  mk_session "$root" one
  mk_session "$root" two
  # A grep that answers the membership probe normally so detection still runs,
  # then fails hard on the -vxF worklist rewrite — the path that must abort
  # rather than dispatch two sessions onto one artifact.
  { printf '#!/bin/bash\n'
    printf 'for a in "$@"; do case "$a" in -vxF) exit 2 ;; esac; done\n'
    printf 'exec /usr/bin/grep "$@"\n'
  } > "$root/home/.local/bin/grep"
  chmod +x "$root/home/.local/bin/grep"
  run_dream_collision "$root"
  local rc=$?
  assert_eq "$rc" "1" "the run fails closed when the worklist cannot be rewritten"
  assert_grep "$root/run.out" 'refusing to dispatch two sessions onto one artifact' \
    "the log says why it refused"
  assert_no_file "$root/dreams/$DATE.md" "no report is produced over a corrupted worklist"
  rm -rf "$root"
}

test_collision_membership_probe_failure_aborts(){
  echo "# collision: a failing membership probe fails closed, it does not skip the row"
  local root; root=$(collision_sandbox)
  mk_session "$root" one
  mk_session "$root" two
  # Fail ONLY the -qxF membership probe. The previous fixture failed the -vxF
  # rewrite instead, so reverting the probe to `|| continue` would have left the
  # whole suite green — a fail-open on the way IN to the check that fails closed
  # on the way out.
  { printf '#!/bin/bash\n'
    printf 'for a in "$@"; do case "$a" in -qxF) exit 2 ;; esac; done\n'
    printf 'exec /usr/bin/grep "$@"\n'
  } > "$root/home/.local/bin/grep"
  chmod +x "$root/home/.local/bin/grep"
  run_dream_collision "$root"
  local rc=$?
  assert_eq "$rc" "1" "the run fails closed when the membership probe errors"
  assert_grep "$root/run.out" 'refusing to build provenance over an unreadable list' \
    "the log names the unreadable worklist"
  assert_no_file "$root/dreams/$DATE.md" "no report is produced"
  rm -rf "$root"
}

test_three_way_collision_counts_paths_not_lines(){
  echo "# collision: three paths on one hash count as three drops, not four"
  local root; root=$(collision_sandbox)
  mk_session "$root" one
  mk_session "$root" two
  mk_session "$root" three
  run_dream_collision "$root"
  local d; d=$(fdir "$root")
  # The earlier path is re-appended for every LATER collision, so the drop file
  # reads A,B,A,C for three paths. Counting lines reported four drops for three.
  assert_grep "$d/run-stats.txt" 'sessions_dropped_to_collision: 3' "three paths count as three"
  assert_grep "$d/run-stats.txt" 'sessions_found_raw: 3' "and all three were enumerated"
  # Deliberate drops are not failures and are not autodream-own.
  assert_grep "$d/run-stats.txt" 'self_sessions_excluded: 0' "collision drops are not charged to self-exclusion"
  rm -rf "$root"
}

# A MIXED run — some collide, one survives — is the case that reaches the normal
# run-stats writer. The all-collide fixtures above take the zero-session path,
# which emits a reduced key set, so neither of them can prove that the normal
# writer carries the collision keys or that deliberate drops stay out of the
# failure denominator.
test_mixed_collision_run_attributes_correctly(){
  echo "# collision: a mixed run keeps drops out of the failure count"
  local root; root=$(collision_sandbox)
  mk_session "$root" one
  mk_session "$root" two
  mk_session "$root" solo
  # Collide everything EXCEPT the path containing "solo", which keeps its real
  # hash and survives to be triaged normally.
  { printf '#!/bin/bash\n'
    printf 'in=$(cat)\n'
    printf 'case "$in" in\n'
    printf '  *solo*) printf "%%s  -\\n" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;\n'
    printf '  *) printf "%%s  -\\n" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;\n'
    printf 'esac\n'
  } > "$root/home/.local/bin/shasum"
  chmod +x "$root/home/.local/bin/shasum"
  run_dream_collision "$root"
  local rc=$?
  local d; d=$(fdir "$root")
  assert_eq "$rc" "0" "the run completes with one surviving session"
  assert_grep "$d/run-stats.txt" 'sessions_found_raw: 3' "all three were enumerated"
  assert_grep "$d/run-stats.txt" 'sessions_triaged: 1' "one survived to triage"
  # The keys that existed only in the zero-session writer until now.
  assert_grep "$d/run-stats.txt" 'sessions_dropped_to_collision: 2' "the normal writer carries the collision count"
  assert_grep "$d/run-stats.txt" 'sidecar_stale_rows: 0' "and the stale-row count"
  # The attribution that was wrong: deliberate drops are neither self-sessions
  # nor failures.
  assert_grep "$d/run-stats.txt" 'self_sessions_excluded: 0' "drops are not autodream-own"
  assert_grep "$d/run-stats.txt" 'sessions_dropped_after_failures: 0' "drops are not failures"
  rm -rf "$root"
}

test_persistent_sidecar_failure_counts_rows_not_attempts(){
  echo "# collision: a persistently unwritable sidecar counts ROWS, not attempts"
  local root; root=$(collision_sandbox)
  mk_session "$root" one
  mk_session "$root" two
  # Fail only the sidecar rewrite (-v "^<hash>\t"), leaving the worklist filter
  # (-vxF) and the membership probe (-qxF) working. One provenance row is then
  # permanently stale. Counting ATTEMPTS reported 3 for it: one at detection plus
  # the same hash seen once per dropped path.
  { printf '#!/bin/bash\n'
    printf 'prev=""\n'
    printf 'for a in "$@"; do\n'
    printf '  if [ "$prev" = "-v" ]; then case "$a" in ^*) exit 2 ;; esac; fi\n'
    printf '  prev="$a"\n'
    printf 'done\n'
    printf 'exec /usr/bin/grep "$@"\n'
  } > "$root/home/.local/bin/grep"
  chmod +x "$root/home/.local/bin/grep"
  run_dream_collision "$root" || true
  local d; d=$(fdir "$root")
  assert_grep "$d/run-stats.txt" 'sidecar_stale_rows: 1' "one stale ROW is reported, not three attempts"
  assert_grep "$d/run-stats.txt" 'sessions_dropped_to_collision: 2' "the drop count is unaffected"
  rm -rf "$root"
}

test_unwritable_collision_index_fails_closed(){
  echo "# collision: an unwritable bookkeeping file stops the run, it does not detect blind"
  local root; root=$(collision_sandbox)
  mk_session "$root" one
  mk_session "$root" two
  # The findings dir exists but cannot be written into. The invariant under test
  # is that this stops the run rather than proceeding blind: if the collision
  # index cannot be written, every path looks unseen, no collision is ever
  # DETECTED, and both sessions reach dispatch onto one artifact.
  #
  # In practice an unwritable findings dir is caught one layer earlier, when
  # enumeration cannot be staged, so the assertion is on the invariant (fail
  # closed, say so, write nothing) rather than on which guard fires. The
  # bookkeeping guard covers the narrower case where the dir is writable but
  # those specific files are not.
  local d="$root/autodream/findings/$DATE"
  mkdir -p "$d"; chmod 500 "$d"
  run_dream_collision "$root"
  local rc=$?
  chmod 700 "$d" 2>/dev/null || true
  assert_eq "$rc" "1" "the run fails closed when the findings dir cannot be written"
  assert_grep "$root/run.out" 'FATAL' "the log says it stopped rather than continuing"
  assert_no_file "$root/dreams/$DATE.md" "no report is produced"
  rm -rf "$root"
}

test_broken_shasum_never_collapses_sessions(){
  echo "# hash: a shasum that fails at runtime must not send every session to one artifact"
  local root; root=$(collision_sandbox)
  mk_session "$root" one
  mk_session "$root" two
  # Preflight only checks that shasum EXISTS. This one exists and fails, which
  # used to yield an empty hash — and an empty hash means every session in the
  # night targets ".json", the silent overwrite reached from the other direction.
  printf '#!/bin/bash\nexit 3\n' > "$root/home/.local/bin/shasum"
  chmod +x "$root/home/.local/bin/shasum"
  run_dream_collision "$root" || true
  local d; d=$(fdir "$root")
  assert_no_file "$d/.json" "no artifact is written under an empty hash"
  # Whatever else happens, two sessions must never share one findings record.
  local n; n=$(find "$d" -maxdepth 1 -name '*.json' ! -name '*.stats.json' 2>/dev/null | wc -l | tr -d ' ')
  [ "${n:-0}" -le 2 ] && ok "no more than one record per session" || no "no more than one record per session (got $n)"
  rm -rf "$root"
}

# ---- Memory pins go to Mnemopi ----
# Rows R1-R11 of the failure matrix in docs/plans/2026-09-15-mnemopi-pins.md.
# apply-pins.sh's own rows live in tests/apply-pins.sh.
#
# Sessions go in the bucket Claude would use for their cwd, because run.sh refuses a cwd
# that does not encode to the bucket its session is stored in. lib-project.sh is the one
# encoder, so the fixtures use it rather than a second copy of the rule.
# shellcheck source=/dev/null
. "$REPO/bin/lib-project.sh"
mk_session_with_cwd(){ # $1=root $2=name $3=cwd [$4=bucket, default: the cwd's own]
  local b="${4:-$(encode_project "$3")}"
  mkdir -p "$1/projects/$b"
  local f="$1/projects/$b/$2.jsonl"
  printf '%s\n' \
    "{\"type\":\"user\",\"cwd\":\"$3\",\"message\":{\"content\":\"start the task\"}}" \
    '{"type":"user","message":{"content":"keep going"}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}' \
    > "$f"
  touch -t "$STAMP" "$f"
}
pins_run(){ # $1=root ; the mock CLI logs each call to $1/sm-calls.jsonl
  SHARED_MEMORY_BIN="$HERE/mock-shared-memory.sh" MOCK_SM_LOG="$1/sm-calls.jsonl" run_dream "$1"
}
sm_calls(){ if [ -f "$1/sm-calls.jsonl" ]; then wc -l < "$1/sm-calls.jsonl" | tr -d ' '; else echo 0; fi; }

test_normalize_project_survives_non_object_findings(){
  echo "# project normalization: a findings file that is valid JSON but not an object does not stop the rest (#73)"
  command -v python3 >/dev/null 2>&1 || { echo "  skip - python3 not available"; return 0; }
  # run.sh's own validation drops a non-object before this pass, so the pass is run on its
  # own: the python body is cut out of run.sh, and a regression in it shows here.
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  awk "/SESSION_ROWS=\"\\\$SESSION_ROWS\" python3 - /{f=1; next} /^PY\$/{f=0} f" "$RUN" > "$root/normalize.py"
  assert_nonempty "$root/normalize.py" "the normalization python was found in run.sh"
  # Names sort a.json < b.json < c.json < d.json; the pass walks them in that order.
  printf '[]' > "$root/a.json"; printf 'null' > "$root/b.json"
  printf '"text"' > "$root/c.json"
  printf '{"project":"WRONG","findings":[]}' > "$root/d.json"
  local out rc
  out=$(SESSION_ROWS=$'a\tproj-a\nb\tproj-a\nc\tproj-a\nd\tproj-a' python3 "$root/normalize.py" "$root" 2>&1); rc=$?
  assert_eq "$rc" "0" "the pass exits 0 over non-object findings"
  assert_eq "$(jq -r .project "$root/d.json")" "proj-a" "the object after the non-objects was normalized"
  assert_eq "$(cat "$root/a.json")" "[]" "an array findings file is left alone"
  rm -rf "$root"
}

test_nested_session_roots_name_the_inner_bucket(){
  echo "# session roots: with nested roots the project is the bucket under the longest root (#73)"
  local root; root=$(setup_env); mkdir -p "$root/work"
  local cwd b; cwd=$(cd "$root/work" && pwd -P); b=$(encode_project "$cwd")
  # setup_env's projects/ is not a root here; the corpus root holds a projects/ root inside it.
  mkdir -p "$root/corpus/projects/$b"
  mk_session_with_cwd "$root" s1 "$cwd"
  mv "$root/projects/$b/s1.jsonl" "$root/corpus/projects/$b/s1.jsonl"
  export MOCK_MODE=pins MOCK_PIN_PROJECT="$b" SESSION_ROOTS="$root/corpus:$root/corpus/projects"
  SHARED_MEMORY_BIN="$HERE/mock-shared-memory.sh" MOCK_SM_LOG="$root/sm-calls.jsonl" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 \
    AUTODREAM_L1_ROUNDS=2 AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" /bin/bash "$RUN" "$DATE" > "$root/run.out" 2>&1
  unset MOCK_MODE MOCK_PIN_PROJECT SESSION_ROOTS
  cat "$root/autodream/logs/run-$DATE.log" >> "$root/run.out" 2>/dev/null || true
  local d; d=$(fdir "$root")
  assert_grep "$d/pin-projects.tsv" "^$b"$'\t'"$cwd\$" "the project is the bucket, not the inner root's own name"
  assert_nogrep "$d/pin-projects.tsv" '^projects'$'\t' "no project named after the inner root"
  assert_eq "$(sm_calls "$root")" "1" "the pin for the bucket was stored"
  rm -rf "$root"
}

test_pins_applied_after_complete_report(){
  echo "# pins: a complete report's pins.jsonl reaches Mnemopi, scoped to the project's cwd"
  local root; root=$(setup_env); mkdir -p "$root/work"
  local cwd; cwd=$(cd "$root/work" && pwd -P)
  mk_session_with_cwd "$root" s1 "$cwd"
  local b; b=$(encode_project "$cwd")
  export MOCK_MODE=pins MOCK_PIN_PROJECT="$b"; pins_run "$root"; unset MOCK_MODE MOCK_PIN_PROJECT
  local d; d=$(fdir "$root")
  assert_eq "$(sm_calls "$root")" "1" "one remember call"
  assert_eq "$(jq -r .cwd "$root/sm-calls.jsonl" 2>/dev/null)" "$cwd" "scoped to the session's working directory"
  assert_grep "$d/pin-projects.tsv" "^$b"$'\t'"$cwd\$" "pin-projects.tsv pairs the bucket with its cwd"
  assert_nonempty "$d/pins-applied.tsv" "the ledger records the stored pin"
  assert_grep "$root/run.out" 'memory pins:' "the run log reports the pin counts"
  # The pins and their authorization list land before the report does (issue 72), so a complete
  # report on disk always has them beside it.
  if [ "$d/pins.jsonl" -nt "$root/dreams/$DATE.md" ]; then no "pins.jsonl was written before the report"; else ok "pins.jsonl was written before the report"; fi
  rm -rf "$root"
}

test_pins_not_applied_after_truncated_report(){
  echo "# pins: a truncated report's pins are never stored"
  local root; root=$(setup_env); mkdir -p "$root/work"
  mk_session_with_cwd "$root" s1 "$(cd "$root/work" && pwd -P)"
  export MOCK_MODE=pins_partial AUTODREAM_L2_ATTEMPTS=1; pins_run "$root"; unset MOCK_MODE AUTODREAM_L2_ATTEMPTS
  assert_eq "$(sm_calls "$root")" "0" "no remember call"
  assert_no_file "$(fdir "$root")/pins-applied.tsv" "no ledger"
  rm -rf "$root"
}

test_pins_stale_file_is_moved_aside(){
  echo "# pins: a forced rebuild never stores the previous run's pins.jsonl"
  local root; root=$(setup_env); mkdir -p "$root/work"
  mk_session_with_cwd "$root" s1 "$(cd "$root/work" && pwd -P)"
  local d="$root/autodream/findings/$DATE"; mkdir -p "$d"
  printf '{"project":"proj-a","title":"old","body":"old pin","kind":"correction"}\n' > "$d/pins.jsonl"
  printf '# old\n<!-- autodream:open-questions=0 -->\n' > "$root/dreams/$DATE.md"
  export MOCK_MODE=l1_badproject AUTODREAM_FORCE=1; pins_run "$root"; unset MOCK_MODE AUTODREAM_FORCE
  assert_eq "$(sm_calls "$root")" "0" "the old pin was not stored"
  assert_no_file "$d/pins.jsonl" "nothing left at the live pins path"
  local n; n=$(find "$d" -maxdepth 1 -name 'pins.jsonl.stale-*' | wc -l | tr -d ' ')
  assert_eq "$n" "1" "the old pins.jsonl was moved aside"
  rm -rf "$root"
}

test_pins_tab_in_cwd_never_splits_the_row(){
  echo "# pins: a working directory containing a tab never splits a pin-projects.tsv row"
  local root; root=$(setup_env)
  local dir="$root/wo"$'\t'"rk"; mkdir -p "$dir"
  local tabcwd; tabcwd=$(cd "$dir" && pwd -P)
  # The bucket really is the tab cwd's own (the tab encodes to a dash), so the bucket check
  # passes and only the tab guard stands between this row and a split.
  local b; b=$(encode_project "$tabcwd"); mkdir -p "$root/projects/$b"
  local f="$root/projects/$b/s1.jsonl"
  {
    jq -cn --arg c "$tabcwd" '{type:"user",cwd:$c,message:{content:"start the task"}}'
    printf '%s\n' '{"type":"user","message":{"content":"keep going"}}' \
      '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}'
  } > "$f"
  touch -t "$STAMP" "$f"
  export MOCK_MODE=pins MOCK_PIN_PROJECT="$b"; pins_run "$root"; unset MOCK_MODE MOCK_PIN_PROJECT
  local d; d=$(fdir "$root")
  assert_file "$d/pin-projects.tsv" "pin-projects.tsv was written"
  assert_eq "$(awk -F'\t' 'NF != 2' "$d/pin-projects.tsv" 2>/dev/null | wc -l | tr -d ' ')" "0" "every row has exactly two fields"
  assert_eq "$(sm_calls "$root")" "0" "no remember call for a project with no usable cwd"
  rm -rf "$root"
}

test_pins_failed_authorization_rebuild_stores_nothing(){
  echo "# pins: a failed pin-projects.tsv rebuild never falls back to an old one"
  local root; root=$(setup_env); mkdir -p "$root/work"
  local cwd; cwd=$(cd "$root/work" && pwd -P)
  mk_session_with_cwd "$root" s1 "$cwd"
  local d="$root/autodream/findings/$DATE"
  # A directory where the temp file goes makes the rebuild's redirect fail.
  mkdir -p "$d/pin-projects.tsv.tmp"
  local b; b=$(encode_project "$cwd")
  printf '%s\t%s\n' "$b" "$cwd" > "$d/pin-projects.tsv"
  export MOCK_MODE=pins MOCK_PIN_PROJECT="$b"; pins_run "$root"; unset MOCK_MODE MOCK_PIN_PROJECT
  assert_eq "$(sm_calls "$root")" "0" "no remember call"
  assert_no_file "$d/pin-projects.tsv" "the old authorization list is gone"
  assert_grep "$root/run.out" 'could not write pin-projects.tsv' "the run log says why"
  rm -rf "$root"
}

test_pins_forged_session_path_authorizes_nothing(){
  echo "# pins: an L1 session_path naming another project's session authorizes no pin there"
  local root; root=$(setup_env); mkdir -p "$root/work-a" "$root/work-b"
  local ca cb; ca=$(cd "$root/work-a" && pwd -P); cb=$(cd "$root/work-b" && pwd -P)
  local ba bb; ba=$(encode_project "$ca"); bb=$(encode_project "$cb")
  mk_session_with_cwd "$root" s1 "$ca"
  # work-b's session exists and is readable, but its mtime is outside the target date,
  # so the run never triages it. Only a forged session_path can point at it.
  mkdir -p "$root/projects/$bb"
  local other="$root/projects/$bb/other.jsonl"
  printf '{"type":"user","cwd":"%s","message":{"content":"x"}}\n' "$cb" > "$other"
  export MOCK_MODE=pins_forged MOCK_FORGED_SESSION="$other" MOCK_PIN_PROJECT="$bb"
  pins_run "$root"
  unset MOCK_MODE MOCK_FORGED_SESSION MOCK_PIN_PROJECT
  local d; d=$(fdir "$root")
  assert_eq "$(sm_calls "$root")" "0" "no memory stored for the untriaged project"
  assert_nogrep "$d/pin-projects.tsv" "^$bb" "the untriaged project is not on the authorization list"
  assert_grep   "$d/pin-projects.tsv" "^$ba" "the triaged project is"
  rm -rf "$root"
}

test_pins_subagent_sessions_keep_their_project(){
  echo "# pins: subagent transcripts belong to their own project, not a shared 'subagents' bucket"
  local root; root=$(setup_env); mkdir -p "$root/work-a" "$root/work-b"
  local p dir agent_b=""
  for p in a b; do
    dir="$root/projects/$(encode_project "$(cd "$root/work-$p" && pwd -P)")/uuid-$p/subagents"; mkdir -p "$dir"
    printf '%s\n' \
      "{\"type\":\"user\",\"cwd\":\"$(cd "$root/work-$p" && pwd -P)\",\"message\":{\"content\":\"start the task\"}}" \
      '{"type":"user","message":{"content":"keep going"}}' \
      '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}' > "$dir/agent-$p.jsonl"
    touch -t "$STAMP" "$dir/agent-$p.jsonl"
    agent_b="$dir/agent-$p.jsonl"
  done
  local bb; bb=$(encode_project "$(cd "$root/work-b" && pwd -P)")
  export MOCK_MODE=pins MOCK_PIN_PROJECT="$bb"; pins_run "$root"; unset MOCK_MODE MOCK_PIN_PROJECT
  local d; d=$(fdir "$root")
  assert_eq "$(sm_calls "$root")" "1" "the proj-b pin was stored"
  assert_eq "$(jq -r .cwd "$root/sm-calls.jsonl" 2>/dev/null)" "$(cd "$root/work-b" && pwd -P)" "in proj-b's working directory"
  assert_nogrep "$d/pin-projects.tsv" '^subagents' "no shared subagents row on the authorization list"
  assert_eq "$(jq -r .project "$d/$(hash_of "$agent_b").json" 2>/dev/null)" "$bb" "findings normalization names the real project too"
  rm -rf "$root"
}

test_pins_cwd_outside_its_bucket_authorizes_nothing(){
  echo "# pins: a session whose cwd does not encode to its bucket gives that project no cwd"
  local root; root=$(setup_env); mkdir -p "$root/work-a" "$root/work-b"
  local ca cb; ca=$(cd "$root/work-a" && pwd -P); cb=$(cd "$root/work-b" && pwd -P)
  local ba; ba=$(encode_project "$ca")
  # Stored under work-a's bucket, but the transcript says it ran in work-b.
  mk_session_with_cwd "$root" s1 "$cb" "$ba"
  export MOCK_MODE=pins MOCK_PIN_PROJECT="$ba"; pins_run "$root"; unset MOCK_MODE MOCK_PIN_PROJECT
  local d; d=$(fdir "$root")
  assert_eq "$(sm_calls "$root")" "0" "no memory for work-a's project stored in work-b's bank"
  assert_grep "$d/pin-projects.tsv" "^$ba"$'\t'"\$" "the bucket is listed with no cwd"
  rm -rf "$root"
}

test_pins_colliding_cwds_authorize_nothing(){
  echo "# pins: two working directories that encode to one bucket give it no cwd"
  local root; root=$(setup_env); mkdir -p "$root/a_b" "$root/a-b"
  local c1 c2; c1=$(cd "$root/a_b" && pwd -P); c2=$(cd "$root/a-b" && pwd -P)
  local b; b=$(encode_project "$c1")
  assert_eq "$(encode_project "$c2")" "$b" "the fixture really collides"
  mk_session_with_cwd "$root" s1 "$c1"
  mk_session_with_cwd "$root" s2 "$c2"
  export MOCK_MODE=pins MOCK_PIN_PROJECT="$b"; pins_run "$root"; unset MOCK_MODE MOCK_PIN_PROJECT
  local d; d=$(fdir "$root")
  assert_eq "$(sm_calls "$root")" "0" "no memory stored in either directory's bank"
  assert_grep "$d/pin-projects.tsv" "^$b"$'\t'"\$" "the bucket is listed with no cwd"
  rm -rf "$root"
}

test_pins_custom_slug_bucket_keeps_its_cwd(){
  echo "# pins: a CLAUDE_CODE_PROJECT_DIR_NAME slug bucket keeps its cwd"
  local root; root=$(setup_env); mkdir -p "$root/work"
  local cwd; cwd=$(cd "$root/work" && pwd -P)
  # Slug buckets (owner-repo) override cwd encoding, so no cwd ever encodes to them. On
  # this host they are the main Rush and STRML repos, 68 of 359 buckets in ~/.claude.
  mk_session_with_cwd "$root" s1 "$cwd" "STRML-demo"
  export MOCK_MODE=pins MOCK_PIN_PROJECT=STRML-demo; pins_run "$root"; unset MOCK_MODE MOCK_PIN_PROJECT
  assert_eq "$(sm_calls "$root")" "1" "the pin for the slug bucket was stored"
  assert_eq "$(jq -r .cwd "$root/sm-calls.jsonl" 2>/dev/null)" "$cwd" "in the session's working directory"
  rm -rf "$root"
}

test_pins_invalid_cwd_still_counts_toward_a_collision(){
  echo "# pins: an unusable cwd in a bucket still makes that bucket ambiguous"
  local root; root=$(setup_env)
  local tabdir="$root/a"$'\t'"b" okdir="$root/a-b"; mkdir -p "$tabdir" "$okdir"
  local tabcwd okcwd; tabcwd=$(cd "$tabdir" && pwd -P); okcwd=$(cd "$okdir" && pwd -P)
  local b; b=$(encode_project "$okcwd")
  assert_eq "$(encode_project "$tabcwd")" "$b" "the fixture really collides"
  mkdir -p "$root/projects/$b"
  {
    jq -cn --arg c "$tabcwd" '{type:"user",cwd:$c,message:{content:"start the task"}}'
    printf '%s\n' '{"type":"user","message":{"content":"keep going"}}' \
      '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}'
  } > "$root/projects/$b/s1.jsonl"
  touch -t "$STAMP" "$root/projects/$b/s1.jsonl"
  mk_session_with_cwd "$root" s2 "$okcwd"
  export MOCK_MODE=pins MOCK_PIN_PROJECT="$b"; pins_run "$root"; unset MOCK_MODE MOCK_PIN_PROJECT
  assert_eq "$(sm_calls "$root")" "0" "no memory stored in the one usable cwd of an ambiguous bucket"
  rm -rf "$root"
}

test_pins_unresolvable_cwd_still_counts_toward_a_collision(){
  echo "# pins: a session whose cwd no longer resolves still makes its bucket ambiguous"
  local root; root=$(setup_env); mkdir -p "$root/a_b" "$root/a-b"
  local gone ok; gone=$(cd "$root/a_b" && pwd -P); ok=$(cd "$root/a-b" && pwd -P)
  local b; b=$(encode_project "$ok")
  assert_eq "$(encode_project "$gone")" "$b" "the fixture really collides"
  mk_session_with_cwd "$root" s1 "$gone"
  mk_session_with_cwd "$root" s2 "$ok"
  # A removed worktree: the adapter cannot resolve this session's cwd any more, which
  # was true of 8 of the 48 sessions on 2026-09-14.
  rmdir "$gone"
  export MOCK_MODE=pins MOCK_PIN_PROJECT="$b"; pins_run "$root"; unset MOCK_MODE MOCK_PIN_PROJECT
  local d; d=$(fdir "$root")
  assert_eq "$(sm_calls "$root")" "0" "no memory stored in the one cwd that still resolves"
  assert_grep "$d/pin-projects.tsv" "^$b"$'\t'"\$" "the bucket is listed with no cwd"
  rm -rf "$root"
}

test_pins_applied_before_notify(){
  echo "# pins: pins are stored before notify.sh runs, so a notify step that never returns cannot lose them"
  local root; root=$(setup_env); mkdir -p "$root/work"
  local cwd; cwd=$(cd "$root/work" && pwd -P)
  mk_session_with_cwd "$root" s1 "$cwd"
  local d; d=$(fdir "$root")
  # AUTODREAM_OPEN runs synchronously inside notify.sh, so a blocking editor command holds
  # the run there. This stand-in records whether the pin was already stored when it ran.
  printf '#!/bin/bash\n[ -s "%s/pins-applied.tsv" ] && touch "%s/notify-saw-pins"\nexit 0\n' "$d" "$root" > "$root/autodream/notify.sh"
  chmod +x "$root/autodream/notify.sh"
  export MOCK_MODE=pins MOCK_PIN_PROJECT="$(encode_project "$cwd")"; pins_run "$root"; unset MOCK_MODE MOCK_PIN_PROJECT
  assert_eq "$(sm_calls "$root")" "1" "one remember call"
  assert_file "$root/notify-saw-pins" "the pin was already stored when notify.sh ran"
  rm -rf "$root"
}

test_streak_update_runs_before_steps_that_can_hang(){
  echo "# a hung notify.sh or apply-pins.sh cannot skip the question streak update (#77)"
  local root; root=$(setup_env); mkdir -p "$root/work"
  local cwd; cwd=$(cd "$root/work" && pwd -P)
  mk_session_with_cwd "$root" s1 "$cwd"
  # Each step appends its name to one log. The steps that call user commands or the store
  # (notify.sh, shared-memory) must come after the streak update, so a hang in either leaves
  # the streak counted.
  printf '#!/bin/bash\necho streaks >> "%s/order.log"\n' "$root" > "$root/autodream/question-streaks.sh"
  printf '#!/bin/bash\necho notify >> "%s/order.log"\n' "$root" > "$root/autodream/notify.sh"
  printf '#!/bin/bash\necho pins >> "%s/order.log"\nexec bash "%s/mock-shared-memory.sh" "$@"\n' "$root" "$HERE" > "$root/sm.sh"
  chmod +x "$root/autodream/question-streaks.sh" "$root/autodream/notify.sh" "$root/sm.sh"
  export MOCK_MODE=pins MOCK_PIN_PROJECT="$(encode_project "$cwd")"
  SHARED_MEMORY_BIN="$root/sm.sh" MOCK_SM_LOG="$root/sm-calls.jsonl" run_dream "$root"
  unset MOCK_MODE MOCK_PIN_PROJECT
  assert_eq "$(sed -n 1p "$root/order.log" 2>/dev/null)" "streaks" "the streak update ran first"
  assert_grep "$root/order.log" '^pins$' "a pin was stored"
  assert_grep "$root/order.log" '^notify$' "notify.sh ran"
  rm -rf "$root"
}

test_pins_ledger_wiped_by_a_worker_stores_nothing_twice(){
  echo "# pins: a worker that empties pins-applied.tsv cannot make a rebuild store a pin twice (#76)"
  local root; root=$(setup_env); mkdir -p "$root/work"
  local cwd; cwd=$(cd "$root/work" && pwd -P)
  mk_session_with_cwd "$root" s1 "$cwd"
  local b; b=$(encode_project "$cwd")
  export MOCK_MODE=pins MOCK_PIN_PROJECT="$b"; pins_run "$root"; unset MOCK_MODE
  assert_eq "$(sm_calls "$root")" "1" "the first run stores the pin"
  # Forced rebuild: the previous report moves aside, L2 proposes the same pin again, and the
  # worker empties the ledger while it runs. The runner's snapshot, taken before any model
  # ran, puts it back before the pins are applied.
  # The first run's findings go, or L1 treats the sessions as done and never starts a worker.
  find "$(fdir "$root")" -maxdepth 1 -name '*.json' -exec rm -f {} +
  export MOCK_MODE=pins_ledger_wipe AUTODREAM_FORCE=1; pins_run "$root"; unset MOCK_MODE AUTODREAM_FORCE MOCK_PIN_PROJECT
  assert_eq "$(sm_calls "$root")" "1" "the rebuild stored nothing a second time"
  assert_eq "$(wc -l < "$(fdir "$root")/pins-applied.tsv" | tr -d ' ')" "1" "the ledger row is back"
  rm -rf "$root"
}

# A night's findings dir as an earlier run left it: one pin, its authorization row, a complete report.
# $1=root $2=date $3=result-file body ("" = no pins-result.txt, so the pin step never finished)
mk_stranded_pins(){
  local root=$1 d=$2 result=${3:-} dir="$1/autodream/findings/$2"
  mkdir -p "$dir" "$root/work-$2"
  printf '{"project":"proj-%s","title":"Stranded","body":"Body","kind":"correction"}\n' "$d" > "$dir/pins.jsonl"
  printf 'proj-%s\t%s\n' "$d" "$(cd "$root/work-$d" && pwd -P)" > "$dir/pin-projects.tsv"
  [ -z "$result" ] || printf '%s\n' "$result" > "$dir/pins-result.txt"
  # Report written after the pins, the order run.sh now keeps.
  sleep 1
  printf '# report\n<!-- autodream:open-questions=0 -->\n' > "$root/dreams/$d.md"
}

test_pins_sweep_applies_pins_a_killed_run_never_reached(){
  echo "# pins: a complete report whose pin step never ran gets its pins applied by the next run (#72)"
  local root; root=$(setup_env)
  mk_stranded_pins "$root" "$DATE" ""
  pins_run "$root"
  assert_grep "$root/run.out" 'nothing to do' "the guard still skips the finished date"
  assert_eq "$(sm_calls "$root")" "1" "the stranded pin was stored"
  assert_grep "$root/autodream/findings/$DATE/pins-result.txt" '^pins_applied: 1$' "the result file records it"
  pins_run "$root"
  assert_eq "$(sm_calls "$root")" "1" "a later run does not store it again"
  rm -rf "$root"
}

test_pins_sweep_retries_failed_pins_on_an_earlier_date(){
  echo "# pins: a failed pin from an earlier night is retried by a later run (#69)"
  local root; root=$(setup_env); mk_session "$root" sess1
  mk_stranded_pins "$root" 2019-12-31 $'pins_total: 1\npins_applied: 0\npins_failed: 1\npins_cli_missing: 0\npins_unreadable: 0'
  pins_run "$root"
  assert_eq "$(sm_calls "$root")" "1" "the earlier date's pin was stored"
  assert_grep "$root/autodream/findings/2019-12-31/pins-result.txt" '^pins_applied: 1$' "its counters now say applied"
  assert_grep "$root/run.out" 'pin sweep' "the run log names the sweep"
  rm -rf "$root"
}

test_pins_sweep_leaves_what_it_must(){
  echo "# pins: the sweep skips settled dates, dates with no authorization list, and dates without a complete report"
  local root; root=$(setup_env); mk_session "$root" sess1
  mk_stranded_pins "$root" 2019-12-29 $'pins_total: 1\npins_applied: 1\npins_failed: 0\npins_cli_missing: 0\npins_unreadable: 0'
  mk_stranded_pins "$root" 2019-12-30 ""
  rm -f "$root/autodream/findings/2019-12-30/pin-projects.tsv"
  mk_stranded_pins "$root" 2019-12-31 ""
  printf '# half a report\n' > "$root/dreams/2019-12-31.md"
  pins_run "$root"
  assert_eq "$(sm_calls "$root")" "0" "nothing was stored"
  assert_grep "$root/run.out" '2019-12-30.*no pin-projects.tsv' "the date with no authorization list is named"
  rm -rf "$root"
}

test_pins_sweep_respects_a_live_run_and_a_stale_result(){
  echo "# pins: the sweep leaves a date a live run owns, and applies pins newer than their result file"
  local root; root=$(setup_env); mk_session "$root" sess1
  local clean=$'pins_total: 1\npins_applied: 1\npins_failed: 0\npins_cli_missing: 0\npins_unreadable: 0'
  mk_stranded_pins "$root" 2019-12-30 ""
  mkdir -p "$root/autodream/locks/run-2019-12-30.lock"; printf '%s\n' "$$" > "$root/autodream/locks/run-2019-12-30.lock/pid"
  # A forced rebuild replaced these pins after the settled result was written, then died.
  mk_stranded_pins "$root" 2019-12-31 "$clean"
  sleep 1; touch "$root/autodream/findings/2019-12-31/pins.jsonl"; sleep 1; touch "$root/dreams/2019-12-31.md"
  pins_run "$root"
  assert_eq "$(sm_calls "$root")" "1" "one pin stored: the rebuilt date's, not the locked date's"
  assert_eq "$(jq -r .payload.metadata.project "$root/sm-calls.jsonl" 2>/dev/null)" "proj-2019-12-31" "it is the date with the stale result"
  assert_grep "$root/run.out" '2019-12-30 has a run in flight' "the locked date is named"
  rm -rf "$root"
}

test_pins_bucket_named_subagents_is_a_project(){
  echo "# pins: a session directly inside a bucket named 'subagents' belongs to that bucket"
  local root; root=$(setup_env); mkdir -p "$root/work"
  local cwd; cwd=$(cd "$root/work" && pwd -P)
  # A CLAUDE_CODE_PROJECT_DIR_NAME slug can be any name, including "subagents". The project
  # is the directory directly under the session root, whatever it is called.
  mk_session_with_cwd "$root" s1 "$cwd" "subagents"
  export MOCK_MODE=pins MOCK_PIN_PROJECT=subagents; pins_run "$root"; unset MOCK_MODE MOCK_PIN_PROJECT
  local d; d=$(fdir "$root")
  assert_eq "$(sm_calls "$root")" "1" "the pin for the 'subagents' bucket was stored"
  assert_eq "$(jq -r .cwd "$root/sm-calls.jsonl" 2>/dev/null)" "$cwd" "in the session's working directory"
  assert_eq "$(jq -r .project "$d/$(hash_of "$root/projects/subagents/s1.jsonl").json" 2>/dev/null)" "subagents" "findings normalization keeps the bucket name"
  rm -rf "$root"

  echo "# pins: a workflow agent transcript nested under subagents/workflows/ belongs to its bucket"
  root=$(setup_env); mkdir -p "$root/work"
  cwd=$(cd "$root/work" && pwd -P)
  local b; b=$(encode_project "$cwd")
  # Claude Code writes workflow agents one level deeper than plain subagents:
  # <bucket>/<session>/subagents/workflows/wf_<id>/agent-*.jsonl (65 such files on this host).
  local wf="$root/projects/$b/uuid-1/subagents/workflows/wf_abc"; mkdir -p "$wf"
  printf '%s\n' \
    "{\"type\":\"user\",\"cwd\":\"$cwd\",\"message\":{\"content\":\"start the task\"}}" \
    '{"type":"user","message":{"content":"keep going"}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}' > "$wf/agent-1.jsonl"
  touch -t "$STAMP" "$wf/agent-1.jsonl"
  export MOCK_MODE=pins MOCK_PIN_PROJECT="$b"; pins_run "$root"; unset MOCK_MODE MOCK_PIN_PROJECT
  d=$(fdir "$root")
  assert_eq "$(sm_calls "$root")" "1" "the pin for the workflow agent's bucket was stored"
  assert_eq "$(jq -r .project "$d/$(hash_of "$wf/agent-1.jsonl").json" 2>/dev/null)" "$b" "findings normalization names the bucket"
  rm -rf "$root"
}

test_pins_failed_move_aside_leaves_no_temp_file(){
  echo "# pins: a pins.jsonl that cannot be moved aside leaves no empty stale file behind"
  local root; root=$(setup_env); mkdir -p "$root/work"
  mk_session_with_cwd "$root" s1 "$(cd "$root/work" && pwd -P)"
  local d="$root/autodream/findings/$DATE"
  # A directory at the pins path: mv cannot put it over the mktemp file. L2's Write tool can
  # make this by writing any path under pins.jsonl/.
  mkdir -p "$d/pins.jsonl/sub"
  printf '# old\n<!-- autodream:open-questions=0 -->\n' > "$root/dreams/$DATE.md"
  export MOCK_MODE=l1_badproject AUTODREAM_FORCE=1; pins_run "$root"; unset MOCK_MODE AUTODREAM_FORCE
  local n; n=$(find "$d" -maxdepth 1 -name 'pins.jsonl.stale-*' | wc -l | tr -d ' ')
  assert_eq "$n" "0" "no empty stale file left behind"
  assert_grep "$root/run.out" 'could not move an earlier pins.jsonl aside' "the run log says the move failed"
  assert_eq "$(sm_calls "$root")" "0" "nothing stored"
  rm -rf "$root"
}

pins_tamper_case(){ # $1=mock mode that appends an unscanned session to the worklist files
  local root; root=$(setup_env); mkdir -p "$root/work-a" "$root/work-b"
  local ca cb; ca=$(cd "$root/work-a" && pwd -P); cb=$(cd "$root/work-b" && pwd -P)
  local bb; bb=$(encode_project "$cb")
  mk_session_with_cwd "$root" s1 "$ca"
  # A real session in another project, never enumerated (its mtime is outside the date).
  mkdir -p "$root/projects/$bb"
  local other="$root/projects/$bb/other.jsonl"
  printf '{"type":"user","cwd":"%s","message":{"content":"x"}}\n' "$cb" > "$other"
  export MOCK_MODE="$1" MOCK_FORGED_SESSION="$other" MOCK_PIN_PROJECT="$bb"
  pins_run "$root"
  unset MOCK_MODE MOCK_FORGED_SESSION MOCK_PIN_PROJECT
  assert_eq "$(sm_calls "$root")" "0" "no memory stored for a session the runner never enumerated ($1)"
  assert_nogrep "$(fdir "$root")/pin-projects.tsv" "^$bb" "the injected project is not authorized ($1)"
  rm -rf "$root"
}

test_pins_l2_cannot_widen_the_worklist(){
  echo "# pins: L2 appending a session to sessions.txt authorizes no pin for it"
  pins_tamper_case pins_tamper
}

test_pins_l1_cannot_widen_the_worklist(){
  echo "# pins: L1 appending a session to sessions.txt authorizes no pin for it"
  pins_tamper_case pins_tamper_l1
}

test_no_markdown_memory_writer_remains(){
  echo "# pins: the MEMORY.md writer and the claude-memory GC are gone"
  assert_nogrep "$REPO/prompts/PROMPT.md" 'touched-projects' "PROMPT.md has no touched-projects sidecar"
  assert_nogrep "$REPO/prompts/PROMPT.md" 'MAY edit the relevant project' "PROMPT.md does not tell L2 to edit MEMORY.md"
  assert_grep   "$REPO/prompts/PROMPT.md" 'AUTODREAM_PINS_BEGIN' "PROMPT.md tells L2 to print a pin block"
  assert_nogrep "$REPO/prompts/PROMPT.md" 'one Write call' "and not to write a pins file itself"
  assert_nogrep "$RUN" 'claude-memory' "run.sh no longer runs claude-memory"
  assert_nogrep "$RUN" 'touched-projects' "run.sh no longer reads touched-projects"
  # The pin block follows the report sentinel: a capture cut off before the sentinel is
  # retried whole, so a pin can never be stored for a report that was never delivered.
  local sentinel_step pin_step
  sentinel_step=$(grep -n 'Print the complete report to stdout, then a line containing exactly' "$REPO/prompts/PROMPT.md" | head -1 | cut -d: -f1)
  pin_step=$(grep -n 'print `AUTODREAM_PINS_BEGIN`' "$REPO/prompts/PROMPT.md" | head -1 | cut -d: -f1)
  if [ -n "$pin_step" ] && [ -n "$sentinel_step" ] && [ "$sentinel_step" -lt "$pin_step" ]; then
    ok "PROMPT.md prints the pin block after the report sentinel"
  else
    no "PROMPT.md prints the pin block after the report sentinel (sentinel step line [$sentinel_step], pin step line [$pin_step])"
  fi
  # L2 exits before any pin is applied, and the runner can still refuse one, so the report
  # may only say a pin was proposed.
  assert_nogrep "$REPO/prompts/PROMPT.md" 'stored by the runner after this report' "PROMPT.md does not tell the report to call a pin stored"
  assert_grep   "$REPO/prompts/PROMPT.md" 'Pin proposed' "PROMPT.md marks pins as proposed"
}

# ---- run the new tests ----
test_pins_applied_after_complete_report
test_normalize_project_survives_non_object_findings
test_nested_session_roots_name_the_inner_bucket
test_pins_not_applied_after_truncated_report
test_pins_stale_file_is_moved_aside
test_pins_tab_in_cwd_never_splits_the_row
test_pins_failed_authorization_rebuild_stores_nothing
test_pins_forged_session_path_authorizes_nothing
test_pins_subagent_sessions_keep_their_project
test_pins_cwd_outside_its_bucket_authorizes_nothing
test_pins_colliding_cwds_authorize_nothing
test_pins_custom_slug_bucket_keeps_its_cwd
test_pins_invalid_cwd_still_counts_toward_a_collision
test_pins_unresolvable_cwd_still_counts_toward_a_collision
test_pins_applied_before_notify
test_pins_sweep_applies_pins_a_killed_run_never_reached
test_pins_sweep_retries_failed_pins_on_an_earlier_date
test_pins_sweep_leaves_what_it_must
test_pins_sweep_respects_a_live_run_and_a_stale_result
test_streak_update_runs_before_steps_that_can_hang
test_pins_ledger_wiped_by_a_worker_stores_nothing_twice
test_pins_bucket_named_subagents_is_a_project
test_pins_failed_move_aside_leaves_no_temp_file
test_pins_l2_cannot_widen_the_worklist
test_pins_l1_cannot_widen_the_worklist
test_no_markdown_memory_writer_remains
test_multiroot_triages_alt_root
test_multiroot_heldout_and_dedup
test_multiroot_flags_unindexed
test_rootprobe_remembers_choice
test_rootprobe_no_write_mode_flags_but_does_not_write
test_rootprobe_empty_home
test_newline_path_is_rejected_not_split
test_source_sidecar_is_written
test_artifact_hash_contract_is_unchanged
test_preflight_stops_a_run_missing_a_dependency
test_install_deploys_the_adapter_runtime
test_unusual_session_paths_are_triaged_or_refused
test_failure_stub_for_a_quoted_path_is_valid_json
test_failing_enumerator_aborts_the_run
test_one_failed_root_does_not_kill_the_night
test_enabled_adapters_resolves_once
test_l2_gets_the_skills_inventory_and_per_source_facts
test_unavailable_skills_inventory_says_so
test_harness_addendum_reaches_only_that_harnesss_workers
test_l2_is_read_only_and_the_runner_writes_the_report
test_l2_report_with_a_marker_but_no_sentinel_is_not_delivered
test_pin_block_must_follow_the_sentinel_and_be_closed
test_dream_triage_is_opt_in_and_leaves_l2_alone
test_l2_engine_comes_from_an_adapter
test_config_written_by_install_enables_adapters_and_l2_engine
test_replay_harness_works_on_synthetic_data
test_skill_fields_dropped_without_a_sidecar
test_skill_fields_dropped_with_a_partial_sidecar
test_skill_fields_are_enforced_from_the_sidecar
test_builtin_slash_commands_are_not_skill_invocations
test_omp_adapter_is_opt_in
test_l1_precheck_probes_the_l1_provider
test_worker_failure_probe_names_the_l1_provider
test_one_dead_provider_does_not_hold_back_the_others
test_omp_session_is_linearized_for_the_worker
test_omp_sessions_run_on_another_adapters_engine
test_the_runs_reviewer_reviews_every_source_by_default
test_an_unusable_l1_engine_override_fails_closed
test_omp_session_roots_come_from_the_host_setting
test_l1_provenance_and_served_models_are_recorded
test_an_engine_failing_its_login_requirement_is_handed_nothing
test_a_call_answered_by_another_model_loses_its_findings
test_omp_nested_child_is_a_sidechain_of_its_bucket
test_omp_session_that_cannot_be_linearized_is_an_error_record
test_omp_stats_describe_the_live_branch_only
test_no_usable_adapter_leaves_a_trace
test_fatal_does_not_clobber_a_complete_date
test_partial_enumeration_keeps_what_it_read
test_all_roots_unavailable_fails
test_fresh_host_with_no_store_is_not_a_failure
test_upgrade_lag_install_still_produces_a_report
test_forced_hash_collision_drops_both
test_collision_worklist_failure_aborts
test_collision_membership_probe_failure_aborts
test_three_way_collision_counts_paths_not_lines
test_mixed_collision_run_attributes_correctly
test_persistent_sidecar_failure_counts_rows_not_attempts
test_unwritable_collision_index_fails_closed
test_broken_shasum_never_collapses_sessions
test_all_excluded_corpus_says_so

# ---- Report-day window: a session is placed by what is IN it, not by its file mtime -----
# Issue #113. Enumeration used to be `-newermt DAY ! -newermt NEXT`, so a session written to
# again after its day closed (a resumed one) vanished from every later rebuild of that day.
# The adapter's find is now a lower bound only (run.sh passes it a far upper date) and
# bin/session-window.sh keeps the files with a record inside the day. The expected sets below
# are worked out from the fixtures, not read back from the code.
LATE=202001051200    # touch -t form: three days after DATE, so a find with an upper bound drops it

mk_win_session(){ # $1=root $2=name $3=touch-t stamp $4.. = ISO timestamps, one user turn each -> path
  local root="$1" name="$2" stamp="$3"; shift 3
  local f="$root/projects/proj-a/$name.jsonl" ts first=1
  : > "$f"
  for ts in "$@"; do
    if [ "$first" = 1 ]; then
      printf '{"type":"user","cwd":"/tmp/proj-a","timestamp":"%s","message":{"content":"%s %s"}}\n' "$ts" "$name" "$ts" >> "$f"; first=0
    else
      printf '{"type":"user","timestamp":"%s","message":{"content":"%s %s"}}\n' "$ts" "$name" "$ts" >> "$f"
    fi
  done
  touch -t "$stamp" "$f"
  printf '%s' "$f"
}
in_list(){ grep -qxF "$2" "$1" 2>/dev/null; } # $1=sessions.txt $2=path

test_window_places_a_session_by_its_records_not_its_mtime(){
  echo "# window: a session belongs to the day its records say, whatever its mtime (#113)"
  local root; root=$(setup_env)
  local late_in fresh_old late_next torn noclock_in noclock_late
  late_in=$(mk_win_session "$root" late-in "$LATE" 2020-01-02T12:00:00Z 2020-01-02T12:10:00Z)        # touched after the day, records inside it
  fresh_old=$(mk_win_session "$root" fresh-old "$STAMP" 2019-12-31T12:00:00Z 2019-12-31T12:10:00Z)    # touched inside the day, records from before it
  late_next=$(mk_win_session "$root" late-next "$LATE" 2020-01-03T12:00:00Z 2020-01-03T12:10:00Z)    # belongs to the next day
  torn=$(mk_win_session "$root" torn "$LATE" 2020-01-02T12:00:00Z 2020-01-02T12:10:00Z)
  { printf 'not json at all\n{"type":"user","timestamp":\n'; } >> "$torn"; touch -t "$LATE" "$torn"
  mk_session "$root" noclock-in; noclock_in="$root/projects/proj-a/noclock-in.jsonl"                   # no clock, mtime inside the day
  mk_session "$root" noclock-late; noclock_late="$root/projects/proj-a/noclock-late.jsonl"; touch -t "$LATE" "$noclock_late"
  export FANOUT=1 MOCK_CALL_LOG="$root/calls.log"; run_dream "$root"; unset FANOUT MOCK_CALL_LOG
  local fd; fd=$(fdir "$root")
  in_list "$fd/sessions.txt" "$late_in"     && ok "a session touched after the day, with a record inside it, is enumerated" || no "a session touched after the day, with a record inside it, is enumerated"
  in_list "$fd/sessions.txt" "$torn"        && ok "so is one whose transcript carries torn lines (they neither crash nor decide)" || no "so is one whose transcript carries torn lines"
  in_list "$fd/sessions.txt" "$noclock_in"  && ok "a file with no clock is placed by its mtime: inside the day -> enumerated" || no "a file with no clock is placed by its mtime: inside the day -> enumerated"
  in_list "$fd/sessions.txt" "$fresh_old"   && no "a file touched inside the day whose records are older is not enumerated" || ok "a file touched inside the day whose records are older is not enumerated"
  in_list "$fd/sessions.txt" "$late_next"   && no "a session whose records are all on the next day is not enumerated" || ok "a session whose records are all on the next day is not enumerated"
  in_list "$fd/sessions.txt" "$noclock_late" && no "a file with no clock, modified after the day, is not enumerated" || ok "a file with no clock, modified after the day, is not enumerated"
  assert_eq "$(wc -l < "$fd/sessions.txt" | tr -d ' ')" "3" "exactly the three sessions with a place in the day"
  assert_grep "$fd/run-stats.txt" 'sessions_out_of_window: 3$' "the three left out are counted, so they cannot read as a quiet night"
  assert_grep "$fd/run-stats.txt" 'session_window: on$' "the window is recorded as in force"
  assert_grep "$fd/run-stats.txt" 'sessions_triaged: 3$' "and three sessions were triaged"
  local p h
  for p in "$late_in" "$torn" "$noclock_in"; do
    h=$(hash_of "$p")
    assert_eq "$(jq -r '.findings | type' "$fd/$h.json" 2>/dev/null)" "array" "$(basename "$p") has a findings record"
  done
  for p in "$fresh_old" "$late_next" "$noclock_late"; do
    h=$(hash_of "$p")
    assert_no_file "$fd/$h.json" "$(basename "$p") has none"
    assert_nogrep "$root/calls.log" "$h" "and no worker was started for $(basename "$p")"
  done
  assert_grep "$root/run.out" 'out of window' "the log counts the files left out"
  assert_eq "$(cat "$root/run.exit")" "0" "the run exits 0"
  assert_nonempty "$root/dreams/$DATE.md" "and wrote its report"
  rm -rf "$root"
}

test_window_cuts_a_multi_day_session_to_the_report_day(){
  echo "# window: stats and the L1 read of a multi-day session cover the report day only"
  local root; root=$(setup_env)
  local f="$root/projects/proj-a/multi.jsonl"
  {
    printf '%s\n' '{"type":"user","cwd":"/tmp/proj-a","timestamp":"2020-01-01T12:00:00Z","message":{"content":"DAY-BEFORE-ONE"}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2020-01-01T12:01:00Z","message":{"content":[{"type":"tool_use","name":"Read"}]}}'
    printf '%s\n' '{"type":"user","timestamp":"2020-01-02T12:00:00Z","message":{"content":"TODAY-ONE"}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2020-01-02T12:05:00Z","message":{"content":[{"type":"tool_use","name":"Bash"}]}}'
    printf '%s\n' '{"type":"user","timestamp":"2020-01-02T12:30:00Z","message":{"content":"TODAY-TWO"}}'
    printf '%s\n' '{"type":"user","timestamp":"2020-01-03T12:00:00Z","message":{"content":"DAY-AFTER-ONE"}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2020-01-03T12:01:00Z","message":{"content":[{"type":"tool_use","name":"Edit"}]}}'
  } > "$f"; touch -t "$LATE" "$f"
  local whole; whole=$(mk_win_session "$root" wholeday "$STAMP" 2020-01-02T12:00:00Z 2020-01-02T12:20:00Z)
  local hm hw; hm=$(hash_of "$f"); hw=$(hash_of "$whole")
  export FANOUT=1 MOCK_MODE=l1_badproject MOCK_CAPTURE_DIR="$root/cap"; run_dream "$root"; unset FANOUT MOCK_MODE MOCK_CAPTURE_DIR
  local fd; fd=$(fdir "$root")
  assert_eq "$(jq -r .user_message_count "$fd/$hm.stats.json")" "2" "stats count the two user turns of the day, not the four of the file"
  assert_eq "$(jq -r .duration_minutes "$fd/$hm.stats.json")" "30" "the duration is the day's 30 minutes, not two days"
  assert_eq "$(jq -r .tool_call_count "$fd/$hm.stats.json")" "1" "and the one tool call of the day"
  assert_eq "$(jq -r .transcript_mtime "$fd/$hm.stats.json")" "$(pstat_mtime "$f")" "the sidecar carries the session's own mtime, not the moment it was cut"
  assert_grep   "$root/cap/l1-read-$hm.txt" 'TODAY-ONE' "the worker read the day's first turn"
  assert_grep   "$root/cap/l1-read-$hm.txt" 'TODAY-TWO' "and its last"
  assert_nogrep "$root/cap/l1-read-$hm.txt" 'DAY-BEFORE-ONE' "and nothing from the day before"
  assert_nogrep "$root/cap/l1-read-$hm.txt" 'DAY-AFTER-ONE' "and nothing from the day after"
  assert_grep   "$root/cap/l1-stdin-$hm.txt" '## Report day' "the worker is told it holds a slice"
  assert_grep   "$root/cap/l1-stdin-$hm.txt" 'recorded on 2020-01-02' "and which day"
  assert_eq "$(jq -r .session_path "$fd/$hm.json")" "$f" "the findings name the real session, not the temporary slice"
  if cmp -s "$whole" "$root/cap/l1-read-$hw.txt"; then ok "a session wholly inside the day is read byte for byte, as before"; else no "a session wholly inside the day is read byte for byte, as before"; fi
  assert_nogrep "$root/cap/l1-stdin-$hw.txt" '## Report day' "and its prompt carries no slice note"
  assert_grep "$fd/run-stats.txt" 'sessions_windowed: 1$' "one of the two triaged sessions spilled outside the day"
  assert_eq "$(ls "$fd" | grep -c '\.day\.jsonl$\|\.statsday\.jsonl$')" "0" "no temporary slice is left in the findings dir"
  rm -rf "$root"
}

test_window_off_restores_mtime_enumeration(){
  echo "# window: AUTODREAM_WINDOW=0 places a session by its file mtime alone, as before"
  local root; root=$(setup_env)
  local late_in fresh_old multi
  late_in=$(mk_win_session "$root" late-in "$LATE" 2020-01-02T12:00:00Z 2020-01-02T12:10:00Z)
  fresh_old=$(mk_win_session "$root" fresh-old "$STAMP" 2019-12-31T12:00:00Z 2019-12-31T12:10:00Z)
  multi=$(mk_win_session "$root" multi "$STAMP" 2019-12-31T12:00:00Z 2020-01-02T12:10:00Z 2020-01-04T12:00:00Z)
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap" AUTODREAM_WINDOW=0; run_dream "$root"; unset FANOUT MOCK_CAPTURE_DIR AUTODREAM_WINDOW
  local fd; fd=$(fdir "$root")
  in_list "$fd/sessions.txt" "$fresh_old" && ok "a file touched inside the day is enumerated whatever its records say" || no "a file touched inside the day is enumerated whatever its records say"
  in_list "$fd/sessions.txt" "$late_in"   && no "a file touched after the day is not enumerated (the old bounded find)" || ok "a file touched after the day is not enumerated (the old bounded find)"
  assert_grep "$fd/run-stats.txt" 'session_window: off$' "run-stats says the window was off"
  assert_grep "$fd/run-stats.txt" 'sessions_out_of_window: 0$' "so nothing is counted out of window"
  assert_grep "$fd/run-stats.txt" 'sessions_windowed: 0$' "and no session is cut"
  local hm; hm=$(hash_of "$multi")
  if cmp -s "$multi" "$root/cap/l1-read-$hm.txt"; then ok "a multi-day session is read whole"; else no "a multi-day session is read whole"; fi
  assert_nogrep "$root/cap/l1-stdin-$hm.txt" '## Report day' "with no slice note"
  assert_grep "$root/run.out" 'scanning for sessions modified between' "and the log keeps the old scan line"
  rm -rf "$root"
}

test_window_degrades_when_the_helper_is_absent(){
  echo "# window: an install without session-window.sh keeps the bounded enumeration and still reports"
  local root; root=$(setup_env)
  local inst="$root/inst"; mkdir -p "$inst/bin"
  cp -R "$REPO/adapters" "$inst/adapters"
  local b; for b in "$REPO"/bin/*.sh; do [ "$(basename "$b")" = session-window.sh ] || cp "$b" "$inst/bin/"; done
  local late_in; late_in=$(mk_win_session "$root" late-in "$LATE" 2020-01-02T12:00:00Z 2020-01-02T12:10:00Z)
  mk_session "$root" s1
  mkdir -p "$root/shim-default"; printf '#!/bin/bash\nprintf %s "200"\n' "'%s'" > "$root/shim-default/curl"; chmod +x "$root/shim-default/curl"
  PATH="$root/shim-default:$PATH" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" AUTODREAM_CONFIG="$root/autodream/config" \
    AUTODREAM_CONSUME_DATE="$DATE" AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    /bin/bash "$inst/bin/run.sh" "$DATE" > "$root/run.out" 2>&1
  local rc=$?
  cat "$root/autodream/logs/run-$DATE.log" >> "$root/run.out" 2>/dev/null || true
  local fd; fd=$(fdir "$root")
  assert_eq "$rc" "0" "the run exits 0"
  assert_grep "$fd/run-stats.txt" 'session_window: off$' "the window is recorded as off"
  in_list "$fd/sessions.txt" "$late_in" && no "the bounded find ran: a file touched after the day is not enumerated" || ok "the bounded find ran: a file touched after the day is not enumerated"
  in_list "$fd/sessions.txt" "$root/projects/proj-a/s1.jsonl" && ok "and a file touched inside the day is" || no "and a file touched inside the day is"
  assert_nonempty "$root/dreams/$DATE.md" "the night still produced its report"
  rm -rf "$root"
}

test_a_missing_l2_prompt_stops_the_run_before_l1(){
  echo "# L2 prompt: an install with no prompts/L2_SYSTEM.txt anywhere refuses to start, claude engine included"
  local root; root=$(setup_env)
  local inst="$root/inst"; mkdir -p "$inst/bin"
  cp -R "$REPO/adapters" "$inst/adapters"
  cp "$REPO"/bin/*.sh "$inst/bin/"
  rm -f "$root/autodream/L2_SYSTEM.txt"   # no AUTODREAM_DIR copy, and the copied tree has no prompts/ beside bin/
  mk_session "$root" s1
  mkdir -p "$root/shim-default"; printf '#!/bin/bash\nprintf %s "200"\n' "'%s'" > "$root/shim-default/curl"; chmod +x "$root/shim-default/curl"
  PATH="$root/shim-default:$PATH" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" AUTODREAM_CONFIG="$root/autodream/config" \
    AUTODREAM_CONSUME_DATE="$DATE" AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    /bin/bash "$inst/bin/run.sh" "$DATE" > "$root/run.out" 2>&1
  local rc=$?
  cat "$root/autodream/logs/run-$DATE.log" >> "$root/run.out" 2>/dev/null || true
  [ "$rc" -ne 0 ] && ok "the run exits non-zero" || no "the run exits non-zero (got $rc)"
  assert_grep "$root/run.out" 'L2_SYSTEM.txt' "the log names the missing prompt"
  assert_grep "$root/run.out" 'Refusing to start' "and says it refused to start"
  assert_nogrep "$root/run.out" 'L1 triage round' "no L1 round started, so nothing was paid for"
  assert_no_file "$root/dreams/$DATE.md" "and no report was written"
  rm -rf "$root"
}

test_window_is_dst_correct_end_to_end(){
  echo "# window: the report day is local midnight to local midnight on a 23-hour DST day (America/New_York 2020-03-08)"
  local DATE=2020-03-08 root; root=$(setup_env)
  # EST until 02:00, EDT after: local midnight is 05:00Z, the next one 04:00Z. A record at
  # 04:30Z on 03-09 is 00:30 EDT on 03-09, so it is NOT in the report day, and a 24-hour
  # window (end 05:00Z) would take it.
  local in edge
  in=$(mk_win_session "$root" in "$LATE" 2020-03-08T15:00:00Z 2020-03-08T15:10:00Z)
  edge=$(mk_win_session "$root" edge "$LATE" 2020-03-09T04:30:00Z 2020-03-09T04:40:00Z)
  TZ=America/New_York touch -t 202003091200 "$in" "$edge"
  TZ=America/New_York run_dream "$root"
  local fd; fd=$(fdir "$root")
  in_list "$fd/sessions.txt" "$in"   && ok "a record at 11:00 EDT on the day is inside it" || no "a record at 11:00 EDT on the day is inside it"
  in_list "$fd/sessions.txt" "$edge" && no "a record at 00:30 EDT the next morning is outside it (a 24h window would take it)" || ok "a record at 00:30 EDT the next morning is outside it (a 24h window would take it)"
  assert_grep "$fd/run-stats.txt" 'sessions_out_of_window: 1$' "and is counted out of window"
  rm -rf "$root"
}

test_rebuild_keeps_a_session_touched_after_its_day_and_retries_its_stale_err(){
  echo "# #113: a rebuild keeps a session touched after its window, and its stale .err is retried, not stranded"
  local root; root=$(setup_env)
  local late; late=$(mk_win_session "$root" late "$LATE" 2020-01-02T12:00:00Z 2020-01-02T12:10:00Z)
  mk_session "$root" ok1
  local h; h=$(hash_of "$late"); local fd; fd=$(fdir "$root")
  # What the aborted run left: a worker's .err and no findings JSON for the session.
  mkdir -p "$fd"
  printf 'worker produced no findings JSON for %s (incomplete run: the engine exited without writing output)\nworker exit code: 1 after 3s\n' "$late" > "$fd/$h.json.err"
  # No report exists and nothing is forced: the ordinary catch-up run for a missed date.
  run_dream "$root"
  in_list "$fd/sessions.txt" "$late" && ok "(a) the session touched after its day is enumerated again" || no "(a) the session touched after its day is enumerated again"
  assert_eq "$(jq -r '.findings | type' "$fd/$h.json" 2>/dev/null)" "array" "(b) it was retried: its findings JSON now exists"
  assert_no_file "$fd/$h.json.err" "(b) and the stale .err is gone"
  assert_grep "$fd/run-stats.txt" 'l1_missing_after_retries: 0$' "nothing is missing after retries"
  assert_grep "$fd/run-stats.txt" 'l1_err_files: 0$' "no .err file is left"
  assert_grep "$fd/run-stats.txt" 'l1_err_files_orphaned: 0$' "and none is stranded"
  # The rebuild of a day that already has a report, the exact case in the issue: the session
  # is touched again after the first report was written, then the date is rebuilt.
  local before; before=$(wc -l < "$fd/sessions.txt" | tr -d ' ')
  touch -t 202001090900 "$late"
  AUTODREAM_FORCE=1 run_dream "$root"
  in_list "$fd/sessions.txt" "$late" && ok "a forced rebuild still enumerates it after a further touch" || no "a forced rebuild still enumerates it after a further touch"
  assert_eq "$(wc -l < "$fd/sessions.txt" | tr -d ' ')" "$before" "the rebuilt corpus is the same size as the original's"
  rm -rf "$root"
}

test_rebuild_of_an_omp_parent_touched_after_its_day_keeps_it_beside_its_advisor(){
  echo "# #113 as reported: an omp parent touched after its day is enumerated again beside its untouched advisor sidecar"
  local root; root=$(setup_env); mk_session "$root" sess1
  local o; o=$(mk_omp_session "$root" parent1); local h; h=$(hash_of "$o")
  touch -t "$LATE" "$o"
  # The advisor sidecar keeps the parent's name as its directory and is not touched again.
  local adir="${o%.jsonl}"; mkdir -p "$adir"
  local adv="$adir/__advisor.jsonl"
  { printf '{"type":"title","title":"adv","v":1}\n'
    printf '{"type":"session","id":"01a00000-0000-7000-8000-0000000000aa","cwd":"/tmp/proj-o","timestamp":"2020-01-02T10:00:00.000Z"}\n'
    printf '{"type":"message","id":"v1","parentId":null,"timestamp":"2020-01-02T10:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"transcript excerpt"}]}}\n'
    printf '{"type":"message","id":"v2","parentId":"v1","timestamp":"2020-01-02T10:01:30.000Z","message":{"role":"user","content":[{"type":"text","text":"more of it"}]}}\n'
    printf '{"type":"message","id":"v3","parentId":"v2","timestamp":"2020-01-02T10:02:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"advisor note"}]}}\n'
  } > "$adv"; touch -t "$STAMP" "$adv"
  local fd; fd=$(fdir "$root"); mkdir -p "$fd"
  printf 'worker produced no findings JSON for %s (incomplete run: the engine exited without writing output)\n' "$o" > "$fd/$h.json.err"
  run_dream_omp "$root"
  in_list "$fd/sessions.txt" "$o"   && ok "the parent touched after its day is in the corpus" || no "the parent touched after its day is in the corpus"
  in_list "$fd/sessions.txt" "$adv" && ok "and so is its advisor sidecar, so the report no longer holds the advisor without its parent" || no "and so is its advisor sidecar"
  assert_eq "$(jq -r '.findings | type' "$fd/$h.json" 2>/dev/null)" "array" "the parent's stale failure was retried and has a findings record"
  assert_nogrep "$fd/$h.json" 'could not be normalized' "and the omp session was not refused"
  assert_no_file "$fd/$h.json.err" "its .err is gone"
  assert_grep "$fd/run-stats.txt" 'l1_missing_after_retries: 0$' "nothing is missing"
  rm -rf "$root"
}

test_stale_err_with_no_session_in_the_worklist_is_reported_not_silent(){
  echo "# #113: a .err whose session is not in tonight's worklist is counted and named, not left to read as tonight's failure"
  local root; root=$(setup_env); mk_session "$root" s1
  local fd; fd=$(fdir "$root"); mkdir -p "$fd"
  printf 'worker produced no findings JSON for /gone/session.jsonl (incomplete run)\n' > "$fd/deadbeef0001.json.err"
  run_dream "$root"
  assert_grep "$fd/run-stats.txt" 'l1_err_files: 1$' "the file is counted, as before"
  assert_grep "$fd/run-stats.txt" 'l1_err_files_orphaned: 1$' "and counted as one nothing will retry"
  assert_grep "$root/run.out" 'nothing will retry them: deadbeef0001' "and the log names it"
  assert_grep "$fd/run-stats.txt" 'l1_missing_after_retries: 0$' "it does not make a finished corpus read as missing"
  rm -rf "$root"
}

test_stale_err_is_counted_on_a_night_with_no_session_too(){
  echo "# #113: the early exit for a night with nothing to triage still counts the stale failures in the directory"
  local root; root=$(setup_env)
  mk_win_session "$root" next "$LATE" 2020-01-03T12:00:00Z 2020-01-03T12:10:00Z >/dev/null
  local fd; fd=$(fdir "$root"); mkdir -p "$fd"
  printf 'worker produced no findings JSON for /gone/session.jsonl (incomplete run)\n' > "$fd/deadbeef0002.json.err"
  run_dream "$root"
  assert_grep "$fd/run-stats.txt" 'sessions_triaged: 0$' "nothing was triaged"
  assert_grep "$fd/run-stats.txt" 'l1_err_files: 1$' "the stale .err is counted, not reported as 0"
  assert_grep "$fd/run-stats.txt" 'l1_err_files_orphaned: 1$' "and counted as one nothing will retry"
  assert_grep "$root/run.out" 'nothing will retry them: deadbeef0002' "and the log names it"
  rm -rf "$root"
}

test_findings_outside_the_worklist_are_set_aside_not_deleted(){
  echo "# window: a findings JSON for a session this run no longer places in the day is counted, named and set aside where L2 does not read it (#56)"
  local root; root=$(setup_env)
  # TWO sessions in the worklist: session_hash prints no trailing newline, and a list of hashes
  # run together matches nothing, which made every findings JSON read as outside the worklist.
  mk_win_session "$root" inday "$STAMP" 2020-01-02T12:00:00Z 2020-01-02T12:10:00Z >/dev/null
  mk_win_session "$root" inday2 "$STAMP" 2020-01-02T13:00:00Z 2020-01-02T13:10:00Z >/dev/null
  local fd; fd=$(fdir "$root"); mkdir -p "$fd"
  # What an earlier mtime-only run left for a session that belongs to another day, and a stale
  # failure for a session that is gone.
  printf '{"session_path":"/elsewhere/old.jsonl","findings":[]}\n' > "$fd/0123456789ab.json"
  printf 'worker produced no findings JSON for /gone/two.jsonl (incomplete run)\n' > "$fd/deadbeef0003.json.err"
  run_dream "$root"
  assert_grep "$fd/run-stats.txt" 'sessions_triaged: 2$' "both sessions are in the worklist"
  assert_grep "$fd/run-stats.txt" 'l1_findings_outside_worklist: 1$' "only the leftover findings JSON is counted, not the two this run wrote"
  assert_grep "$fd/run-stats.txt" 'l1_err_files_orphaned: 1$' "and only the stale .err"
  assert_grep "$root/run.out" '0123456789ab' "the log names the leftover"
  assert_grep "$fd/run-stats.txt" 'l1_findings_written: 2$' "the set-aside JSON is not counted as a finished triage"
  assert_no_file "$fd/0123456789ab.json" "it is no longer where L2 globs for findings"
  assert_file "$fd/outside-worklist/0123456789ab.json" "and it is set aside, not deleted"
  # A later rebuild whose worklist owns the session again gets its findings back before L1,
  # so the rerun does not triage it twice.
  local h1; h1=$(hash_of "$root/projects/proj-a/inday.jsonl")
  mv "$fd/$h1.json" "$fd/outside-worklist/$h1.json"
  printf '{"session_path":"x","findings":[],"marker":"kept-from-first-run"}\n' > "$fd/outside-worklist/$h1.json"
  rm -f "$root/dreams/$DATE.md"
  AUTODREAM_FORCE=1 run_dream "$root"
  assert_grep "$fd/$h1.json" 'kept-from-first-run' "a set-aside JSON whose session is back in the worklist is restored and not re-triaged"
  assert_no_file "$fd/outside-worklist/$h1.json" "and leaves the quarantine"
  rm -rf "$root"
  root=$(setup_env); mk_session "$root" s1; fd=$(fdir "$root")
  run_dream "$root"
  assert_grep "$fd/run-stats.txt" 'l1_findings_outside_worklist: 0$' "a clean night reports none outside its worklist"
  rm -rf "$root"
}

test_a_night_of_only_out_of_window_files_says_so(){
  echo "# window: when every modified file is outside the day the stub says that, not 'no session files were modified'"
  local root; root=$(setup_env)
  mk_win_session "$root" next "$LATE" 2020-01-03T12:00:00Z 2020-01-03T12:10:00Z >/dev/null
  run_dream "$root"
  local fd; fd=$(fdir "$root")
  assert_grep   "$root/dreams/$DATE.md" 'No session had a record inside this day' "the report says no session had a record in the day"
  assert_nogrep "$root/dreams/$DATE.md" 'No session files were modified' "and does not claim nothing was modified"
  assert_grep   "$fd/run-stats.txt" 'sessions_out_of_window: 1$' "the file is counted"
  assert_grep   "$fd/run-stats.txt" 'sessions_triaged: 0$' "nothing was triaged"
  rm -rf "$root"
}

# ---- Report-day window on omp: cut the live chain AFTER it is linearized ---------------
mk_omp_multiday(){ # $1=root $2=name -> path. Live chain u1 a1 u2 a2 u3 a3 u4 a4 over three days; ax is an abandoned branch ON the report day
  local d="$1/home/.omp/agent/sessions/proj-o" f
  mkdir -p "$d"; f="$d/2020-01-01T10-00-00-000Z_$2.jsonl"
  local msg='"message":{"role":"%s","content":[{"type":"text","text":"%s"}]}'
  {
    printf '%s\n' '{"type":"title","title":"t","v":1}'
    printf '{"type":"session","id":"01a00000-0000-7000-8000-000000000002","cwd":"/tmp/proj-o","timestamp":"2020-01-01T10:00:00.000Z"}\n'
    printf '{"type":"message","id":"u1","parentId":null,"timestamp":"2020-01-01T12:00:00.000Z",'"$msg"'}\n' user DAY1_USER
    printf '{"type":"message","id":"a1","parentId":"u1","timestamp":"2020-01-01T12:00:05.000Z",'"$msg"'}\n' assistant DAY1_ASSISTANT
    printf '{"type":"message","id":"ax","parentId":"u1","timestamp":"2020-01-02T12:00:02.000Z",'"$msg"'}\n' assistant ABANDONED_BRANCH_MARKER
    printf '{"type":"message","id":"u2","parentId":"a1","timestamp":"2020-01-02T12:00:00.000Z",'"$msg"'}\n' user DAY2_USER_A
    printf '{"type":"message","id":"a2","parentId":"u2","timestamp":"2020-01-02T12:00:30.000Z",'"$msg"'}\n' assistant DAY2_ASSISTANT_A
    printf '{"type":"message","id":"u3","parentId":"a2","timestamp":"2020-01-02T12:30:00.000Z",'"$msg"'}\n' user DAY2_USER_B
    printf '{"type":"message","id":"a3","parentId":"u3","timestamp":"2020-01-02T12:30:05.000Z",'"$msg"'}\n' assistant DAY2_ASSISTANT_B
    printf '{"type":"message","id":"u4","parentId":"a3","timestamp":"2020-01-03T12:00:00.000Z",'"$msg"'}\n' user DAY3_USER
    printf '{"type":"message","id":"a4","parentId":"u4","timestamp":"2020-01-03T12:00:05.000Z",'"$msg"'}\n' assistant DAY3_ASSISTANT
  } > "$f"
  touch -t "$LATE" "$f"
  printf '%s' "$f"
}

test_window_omp_cuts_the_live_chain_after_linearizing(){
  echo "# window (omp): the live chain is cut to the day after it is linearized; the session is not refused"
  local root; root=$(setup_env); mk_session "$root" sess1
  local o; o=$(mk_omp_multiday "$root" multi); local h; h=$(hash_of "$o")
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap" MOCK_CALL_LOG="$root/calls.log"; run_dream_omp "$root"; unset FANOUT MOCK_CAPTURE_DIR MOCK_CALL_LOG
  local fd; fd=$(fdir "$root"); local rd="$root/cap/l1-read-$h.txt"
  in_list "$fd/sessions.txt" "$o" && ok "an omp session touched after the day, with entries inside it, is enumerated" || no "an omp session touched after the day, with entries inside it, is enumerated"
  assert_nogrep "$fd/$h.json" 'could not be normalized' "it was not refused by the linearizer (a cut of the raw tree would have left a dangling parentId)"
  assert_file "$rd" "the omp worker ran"
  assert_eq "$(head -n 1 "$rd" | jq -r .type)" "autodream_meta" "what it read opens with the session header"
  assert_grep   "$rd" 'DAY2_USER_A' "it holds the day's entries"
  assert_grep   "$rd" 'DAY2_ASSISTANT_B' "through the last one of the day"
  assert_nogrep "$rd" 'DAY1_' "none from the day before"
  assert_nogrep "$rd" 'DAY3_' "none from the day after"
  assert_nogrep "$rd" 'ABANDONED_BRANCH_MARKER' "and not the abandoned branch, though its entry is timestamped inside the day"
  assert_eq "$(jq -s '[.[] | select(.type == "message")] | map(.id) | join(",")' "$rd")" '"u2,a2,u3,a3"' "the kept entries are the live chain's run for the day, in order"
  assert_eq "$(jq -s '[.[] | select(.type == "message")] as $m | [range(1; $m | length) | select($m[.].parentId != $m[. - 1].id)] | length' "$rd")" "0" "each entry points at the one before it: the slice is one unbroken chain"
  assert_eq "$(jq -s '[.[] | select(.type == "message")][0].parentId' "$rd")" "null" "which starts at a root, so no parentId in it is dangling"
  assert_eq "$(jq -r .user_message_count "$fd/$h.stats.json")" "2" "omp stats count the day's two user turns, not the chain's four"
  assert_grep "$fd/run-stats.txt" 'sessions_windowed: 1$' "one session was cut"
  assert_eq "$(ls "$fd" | grep -c '\.day\.jsonl$\|\.statsday\.jsonl$\|\.norm\.jsonl$\|\.statsin\.jsonl$')" "0" "no temporary copy is left behind"
  rm -rf "$root"
}

test_window_omp_session_active_only_on_an_abandoned_branch_is_gated_not_refused(){
  echo "# window (omp): a session whose only entries inside the day are on an abandoned branch is gated, not refused or read whole"
  local root; root=$(setup_env); mk_session "$root" sess1
  local d="$root/home/.omp/agent/sessions/proj-o" f; mkdir -p "$d"; f="$d/2020-01-01T10-00-00-000Z_aband.jsonl"
  local msg='"message":{"role":"%s","content":[{"type":"text","text":"%s"}]}'
  {
    printf '%s\n' '{"type":"title","title":"t","v":1}'
    printf '{"type":"session","id":"01a00000-0000-7000-8000-000000000003","cwd":"/tmp/proj-o","timestamp":"2020-01-01T10:00:00.000Z"}\n'
    printf '{"type":"message","id":"u1","parentId":null,"timestamp":"2020-01-01T12:00:00.000Z",'"$msg"'}\n' user DAY1_USER
    printf '{"type":"message","id":"a1","parentId":"u1","timestamp":"2020-01-01T12:00:05.000Z",'"$msg"'}\n' assistant DAY1_ASSISTANT
    printf '{"type":"message","id":"ax","parentId":"u1","timestamp":"2020-01-02T12:00:00.000Z",'"$msg"'}\n' user ABANDONED_ONLY
    printf '{"type":"message","id":"u2","parentId":"a1","timestamp":"2020-01-03T12:00:00.000Z",'"$msg"'}\n' user DAY3_USER
  } > "$f"; touch -t "$LATE" "$f"
  local h; h=$(hash_of "$f")
  export FANOUT=1 MOCK_CALL_LOG="$root/calls.log"; run_dream_omp "$root"; unset FANOUT MOCK_CALL_LOG
  local fd; fd=$(fdir "$root")
  in_list "$fd/sessions.txt" "$f" && ok "it is enumerated: the raw file has an entry inside the day" || no "it is enumerated: the raw file has an entry inside the day"
  assert_grep   "$fd/$h.json" 'below_noise_gate' "the live chain has nothing in the day, so it is gated"
  assert_nogrep "$fd/$h.json" 'could not be normalized' "and not refused"
  assert_nogrep "$root/calls.log" "$h" "no worker read it"
  assert_eq "$(jq -r .user_message_count "$fd/$h.stats.json")" "0" "its stats say no user turns that day"
  rm -rf "$root"
}

test_window_places_a_session_by_its_records_not_its_mtime
test_window_cuts_a_multi_day_session_to_the_report_day
test_window_off_restores_mtime_enumeration
test_window_degrades_when_the_helper_is_absent
test_a_missing_l2_prompt_stops_the_run_before_l1
test_window_is_dst_correct_end_to_end
test_rebuild_keeps_a_session_touched_after_its_day_and_retries_its_stale_err
test_rebuild_of_an_omp_parent_touched_after_its_day_keeps_it_beside_its_advisor
test_stale_err_with_no_session_in_the_worklist_is_reported_not_silent
test_stale_err_is_counted_on_a_night_with_no_session_too
test_findings_outside_the_worklist_are_set_aside_not_deleted
test_a_night_of_only_out_of_window_files_says_so
test_window_omp_cuts_the_live_chain_after_linearizing
test_window_omp_session_active_only_on_an_abandoned_branch_is_gated_not_refused

test_leftover_counts_hold_with_several_sessions_in_the_worklist(){
  echo "# leftovers: the worklist hashes are one per line, so a findings JSON the worklist owns is never counted as foreign"
  local root; root=$(setup_env)
  mk_session "$root" s1; mk_session "$root" s2; mk_session "$root" s3
  local fd; fd=$(fdir "$root"); mkdir -p "$fd"
  # Two leftovers the worklist does not own: a findings JSON and an .err with no findings JSON.
  printf '{"session_path":"/gone/a.jsonl","findings":[]}' > "$fd/deadbeef0001.json"
  printf 'worker produced no findings JSON for /gone/b.jsonl\n' > "$fd/deadbeef0002.json.err"
  run_dream "$root"
  assert_grep "$fd/run-stats.txt" 'sessions_triaged: 3$' "three sessions were triaged"
  assert_grep "$fd/run-stats.txt" 'l1_findings_outside_worklist: 1$' "exactly the one foreign findings JSON is counted, not the three the worklist owns"
  assert_grep "$fd/run-stats.txt" 'l1_err_files_orphaned: 1$' "and exactly the one orphan .err"
  assert_file "$fd/outside-worklist/deadbeef0001.json" "the foreign findings JSON is set aside, so L2 does not read it"
  rm -rf "$root"
}

test_leftover_counts_hold_with_several_sessions_in_the_worklist

# ---- Chunked triage: a transcript too big for one worker is read in chunks ---------------
# One worker per chunk, then a mechanical merge into the one findings JSON per session that L2
# already reads. The expected counts below come from the fixtures and from what the mock engine
# was actually handed (MOCK_CAPTURE_DIR keeps every transcript a worker read), not from the code
# under test. SLIM_BYTES and CHUNK_BYTES are set tiny so a fixture of a few KB behaves like a
# multi-MB session.
mk_chunky(){ # $1=root $2=name $3=turns -> path. Turn-NNN user records among bookkeeping and hook noise
  local f="$1/projects/proj-a/$2.jsonl" i m s
  : > "$f"
  for i in $(seq 1 "$3"); do
    m=$((i / 2)); s=$(( (i % 2) * 30 ))
    printf '{"type":"mode","mode":"auto","timestamp":"2020-01-02T12:%02d:%02d.000Z"}\n' "$m" "$s" >> "$f"
    printf '{"type":"attachment","timestamp":"2020-01-02T12:%02d:%02d.000Z","attachment":{"type":"hook_success","stdout":"HOOKNOISE-%03d"}}\n' "$m" "$s" "$i" >> "$f"
    printf '{"parentUuid":"p%d","type":"user","cwd":"/tmp/proj-a","uuid":"u%d","timestamp":"2020-01-02T12:%02d:%02d.000Z","message":{"role":"user","content":"turn-%03d some user words to give the line a body"}}\n' "$i" "$i" "$m" "$s" "$i" >> "$f"
    printf '{"parentUuid":"u%d","type":"assistant","uuid":"a%d","timestamp":"2020-01-02T12:%02d:%02d.500Z","message":{"role":"assistant","content":[{"type":"text","text":"reply-%03d and some assistant words"}]}}\n' "$i" "$i" "$m" "$s" "$i" >> "$f"
  done
  touch -t "$STAMP" "$f"
  printf '%s' "$f"
}
chunk_reads(){ ls "$1"/cap/l1-read-*.chunkout.txt 2>/dev/null; }   # what each chunk worker was handed
nreads(){ chunk_reads "$1" | wc -l | tr -d ' '; }
turn_stats(){ # distinct turn markers handed to chunk workers / the most times any one marker was handed
  chunk_reads "$1" | xargs cat 2>/dev/null | grep -o 'turn-[0-9][0-9][0-9]' | sort | uniq -c | awk '{ d++; if ($1 > m) m = $1 } END { printf "%d/%d", d, m }'
}
run_chunked(){ # $1=root ; env for the run is set by the caller
  export FANOUT=1 AUTODREAM_SLIM_BYTES=3000 MOCK_CAPTURE_DIR="$1/cap"
  # A subshell, so the knob cannot outlive the call. `VAR=x run_chunked` plus an `export VAR`
  # in this function leaves VAR set afterwards on bash 5 (bash 3.2 restores it), and the next
  # test then inherited a stale CHUNK_BYTES and never chunked. Linux CI runs bash 5.
  ( export AUTODREAM_L1_CHUNK_BYTES="${AUTODREAM_L1_CHUNK_BYTES:-3000}"; run_dream "$1" )
  unset FANOUT AUTODREAM_SLIM_BYTES MOCK_CAPTURE_DIR
}

test_chunking_reads_the_whole_conversation_in_chunks(){
  echo "# chunking: an oversized transcript is read in full, in chunks, and merged into one findings JSON"
  local root; root=$(setup_env)
  local f; f=$(mk_chunky "$root" big 60); local h; h=$(hash_of "$f"); local fd; fd=$(fdir "$root")
  export MOCK_MODE=chunked MOCK_CALL_LOG="$root/calls.log"; run_chunked "$root"; unset MOCK_MODE MOCK_CALL_LOG
  local n; n=$(nreads "$root")
  [ "$n" -ge 3 ] && ok "the 60-turn transcript was split into $n chunks (at least 3)" || no "the 60-turn transcript was split into chunks (got $n)"
  assert_eq "$(wc -l < "$root/calls.log" | tr -d ' ')" "$n" "one engine call per chunk, and no call for the whole transcript"
  assert_eq "$(turn_stats "$root")" "60/1" "every one of the 60 turns was handed to a chunk worker, exactly once"
  assert_eq "$(chunk_reads "$root" | xargs cat | grep -c 'HOOKNOISE\|"type":"mode"')" "0" "and none of the hook or bookkeeping noise was"
  local big=0 r; for r in $(chunk_reads "$root"); do [ "$(wc -c < "$r" | tr -d ' ')" -gt 3600 ] && big=1; done
  assert_eq "$big" "0" "no chunk is much past the 3000-byte limit (a line is never split to fit)"
  assert_eq "$(jq -r .session_path "$fd/$h.json")" "$f" "the merged findings name the real session, not a chunk file"
  assert_eq "$(jq -r .meta.chunks "$fd/$h.json")" "$n" "meta records the chunk count"
  assert_eq "$(jq -r .meta.chunks_elided "$fd/$h.json")" "0" "and that none were elided"
  assert_eq "$(jq -r .underlying_goal "$fd/$h.json")" "goal-1" "the goal is the first chunk's"
  assert_eq "$(jq -r .outcome "$fd/$h.json")" "fully_achieved" "the outcome is the last chunk's (only it says fully_achieved)"
  assert_eq "$(jq -r '[.findings[] | select(.what | startswith("finding-from-chunk-"))] | length' "$fd/$h.json")" "$n" "every chunk's own finding is in the merge"
  assert_eq "$(jq -r '[.findings[] | select(.what == "shared across chunks")] | length' "$fd/$h.json")" "1" "a finding every chunk reported appears once"
  assert_eq "$(jq -r '.findings | map(.chunk) | max' "$fd/$h.json")" "$n" "findings are tagged with their chunk"
  local last; last=$(ls "$root"/cap/l1-stdin-*.chunkout.txt | sort | tail -1)
  assert_grep "$last" "chunk $n of $n of ONE session" "each chunk worker is told which chunk it holds"
  assert_grep "$last" 'Precomputed session stats' "and still gets the session stats"
  assert_eq "$(awk '/^## Chunk note/ {c = NR} /^## Precomputed session stats/ {s = NR} END {print (c > 0 && s > c) ? "ok" : "bad"}' "$last")" "ok" "after the chunk note, so the stats block stays last as the triage prompt says"
  assert_no_file "$fd/.chunks/$h" "no chunk scratch is left once the session is done"
  assert_eq "$(ls -A "$fd" | grep -c '^\.chunks$\|\.chunkout$')" "0" "and no chunk directory or chunk answer is in the findings directory"
  assert_grep "$fd/run-stats.txt" "l1_chunk_bytes: 3000\$" "run-stats records the setting in force"
  assert_grep "$fd/run-stats.txt" "l1_chunked_sessions: 1\$" "one chunked session"
  assert_grep "$fd/run-stats.txt" "l1_chunks: $n\$" "the chunk workers it needed"
  assert_grep "$fd/run-stats.txt" "l1_chunk_calls: $n\$" "and the engine calls actually made"
  assert_grep "$fd/run-stats.txt" 'l1_chunks_elided: 0$' "none elided"
  assert_grep "$fd/run-stats.txt" 'l1_missing_after_retries: 0$' "nothing is missing"
  assert_eq "$(jq -r '.findings | type' "$fd/$h.json")" "array" "and the merged file is an ordinary findings JSON"
  rm -rf "$root"
}

test_chunking_leaves_a_transcript_that_fits_alone(){
  echo "# chunking: a transcript that fits in one worker is read by one worker, exactly as before"
  local root; root=$(setup_env)
  local f; f=$(mk_chunky "$root" fits 8); local h; h=$(hash_of "$f"); local fd; fd=$(fdir "$root")
  export MOCK_MODE=chunked MOCK_CALL_LOG="$root/calls.log"
  AUTODREAM_L1_CHUNK_BYTES=300000 run_chunked "$root"; unset MOCK_MODE MOCK_CALL_LOG
  assert_eq "$(wc -l < "$root/calls.log" | tr -d ' ')" "1" "one engine call"
  assert_eq "$(nreads "$root")" "0" "and it was not a chunk"
  assert_nogrep "$root/cap/l1-stdin-$h.txt" 'Chunk note' "its prompt carries no chunk note"
  assert_grep "$fd/run-stats.txt" 'l1_chunked_sessions: 0$' "run-stats counts no chunked session"
  assert_grep "$fd/run-stats.txt" 'l1_chunk_calls: 0$' "and no chunk call"
  assert_nogrep "$root/cap/l1-read-$h.txt" 'HOOKNOISE' "it was slimmed with the bookkeeping dropped, so it reads as the conversation"
  assert_grep "$root/cap/l1-read-$h.txt" 'turn-008' "and holds every turn"
  assert_eq "$(jq -r 'has("meta")' "$fd/$h.json")" "false" "the findings carry no chunk meta"
  rm -rf "$root"
}

test_chunk_cap_drops_the_middle_and_counts_it(){
  echo "# chunking: over AUTODREAM_L1_MAX_CHUNKS the middle is dropped, and said so everywhere"
  local root; root=$(setup_env)
  local f; f=$(mk_chunky "$root" big 60); local h; h=$(hash_of "$f"); local fd; fd=$(fdir "$root")
  export MOCK_MODE=chunked AUTODREAM_L1_MAX_CHUNKS=2; run_chunked "$root"; unset MOCK_MODE AUTODREAM_L1_MAX_CHUNKS
  assert_eq "$(nreads "$root")" "2" "only 2 chunks were read"
  local e; e=$(jq -r .meta.chunks_elided "$fd/$h.json")
  [ "$e" -ge 1 ] && ok "and the merged findings say $e were elided" || no "and the merged findings say some were elided (got $e)"
  assert_grep "$fd/run-stats.txt" "l1_chunks_elided: $e\$" "run-stats counts them: a degraded read cannot pass as a complete one"
  assert_grep "$fd/run-stats.txt" 'l1_chunks: 2$' "and the chunk workers"
  local first last; first=$(ls "$root"/cap/l1-read-*.chunkout.txt | sort | head -1); last=$(ls "$root"/cap/l1-read-*.chunkout.txt | sort | tail -1)
  assert_grep "$first" 'turn-001' "the kept head holds the start of the session"
  assert_grep "$last" 'turn-060' "the kept tail holds the end of it"
  assert_nogrep "$first" 'turn-060' "and the head does not reach the end"
  assert_grep "$root/cap/l1-stdin-$(basename "$first" | sed 's/^l1-read-//; s/\.txt$//').txt" "$e chunks from the middle of the session were omitted" "the worker is told what was omitted"
  rm -rf "$root"
}

test_chunk_cap_of_one_reads_one_chunk_never_the_whole_transcript(){
  echo "# chunking: AUTODREAM_L1_MAX_CHUNKS=1 is a bounded read of the first chunk, never the whole slim"
  local root; root=$(setup_env)
  local f; f=$(mk_chunky "$root" big 60); local h; h=$(hash_of "$f"); local fd; fd=$(fdir "$root")
  export MOCK_MODE=chunked AUTODREAM_L1_MAX_CHUNKS=1 MOCK_TRANSCRIPT_LOG="$root/sizes.log"; run_chunked "$root"; unset MOCK_MODE AUTODREAM_L1_MAX_CHUNKS MOCK_TRANSCRIPT_LOG
  assert_eq "$(wc -l < "$root/sizes.log" | tr -d ' ')" "1" "one engine call"
  local sz; sz=$(cut -f2 "$root/sizes.log" | head -1)
  [ "$sz" -le 3600 ] && ok "it was handed $sz bytes, one chunk, not the whole slim" || no "it was handed $sz bytes, more than one chunk"
  assert_eq "$(jq -r .meta.chunks "$fd/$h.json")" "1" "the findings say one chunk"
  [ "$(jq -r .meta.chunks_elided "$fd/$h.json")" -ge 1 ] && ok "and that the rest were elided" || no "and that the rest were elided"
  rm -rf "$root"
}

test_chunking_off_is_the_old_behaviour(){
  echo "# chunking: AUTODREAM_L1_CHUNK_BYTES=0 reads an oversized transcript exactly the old way, the head/tail slim"
  local root; root=$(setup_env)
  local f; f=$(mk_chunky "$root" big 60); local h; h=$(hash_of "$f"); local fd; fd=$(fdir "$root")
  export MOCK_CALL_LOG="$root/calls.log"
  mkdir -p "$fd"; printf 'x\n' > "$fd/deadbeefdead.slim.jsonl"
  AUTODREAM_SLIM_HEAD=10 AUTODREAM_SLIM_TAIL=6 AUTODREAM_L1_CHUNK_BYTES=0 run_chunked "$root"; unset MOCK_CALL_LOG
  assert_eq "$(wc -l < "$root/calls.log" | tr -d ' ')" "1" "one engine call"
  rm -f "$root/plain.slim"
  AUTODREAM_SLIM_HEAD=10 AUTODREAM_SLIM_TAIL=6 "$REPO/bin/slim-transcript.sh" "$f" "$root/plain.slim" >/dev/null 2>&1
  if cmp -s "$root/plain.slim" "$root/cap/l1-read-$h.txt"; then ok "what the worker read is exactly what the slimmer writes with no mode set"; else no "what the worker read is exactly what the slimmer writes with no mode set"; fi
  assert_grep "$root/cap/l1-read-$h.txt" 'lines elided by autodream for size' "with the elision marker and the head/tail view"
  assert_grep "$root/cap/l1-read-$h.txt" 'HOOKNOISE' "the bookkeeping is still in it (the reshape is part of the chunked mode)"
  assert_nogrep "$root/cap/l1-stdin-$h.txt" 'Chunk note' "no chunk note"
  assert_eq "$(nreads "$root")" "0" "no chunk worker"
  assert_grep "$fd/run-stats.txt" 'l1_chunk_bytes: 0$' "run-stats says chunking is off"
  assert_grep "$fd/run-stats.txt" 'l1_chunk_calls: 0$' "and made no chunk call"
  assert_no_file "$fd/.chunks" "and no chunk directory exists"
  assert_no_file "$fd/l1-chunks.txt" "nor a chunk ledger"
  assert_file "$fd/deadbeefdead.slim.jsonl" "and the post-round cleanup of transcript copies is part of the gated behaviour, so it did not run"
  assert_eq "$(jq -r 'has("meta")' "$fd/$h.json")" "false" "the findings carry no chunk meta"
  rm -rf "$root"
}

test_chunking_is_off_when_the_knob_is_unset(){
  echo "# chunking: with AUTODREAM_L1_CHUNK_BYTES unset, an oversized session is read exactly as with it set to 0"
  local root0 rootu; root0=$(setup_env); rootu=$(setup_env)
  local f0 fu h0 hu
  f0=$(mk_chunky "$root0" big 60); h0=$(hash_of "$f0")
  fu=$(mk_chunky "$rootu" big 60); hu=$(hash_of "$fu")
  ( export FANOUT=1 AUTODREAM_SLIM_BYTES=3000 AUTODREAM_SLIM_HEAD=10 AUTODREAM_SLIM_TAIL=6 MOCK_CAPTURE_DIR="$root0/cap" AUTODREAM_L1_CHUNK_BYTES=0
    run_dream "$root0" )
  ( unset AUTODREAM_L1_CHUNK_BYTES AUTODREAM_L1_MAX_CHUNKS
    export FANOUT=1 AUTODREAM_SLIM_BYTES=3000 AUTODREAM_SLIM_HEAD=10 AUTODREAM_SLIM_TAIL=6 MOCK_CAPTURE_DIR="$rootu/cap"
    run_dream "$rootu" )
  local fd0 fdu; fd0=$(fdir "$root0"); fdu=$(fdir "$rootu")
  assert_grep "$fdu/run-stats.txt" 'l1_chunk_bytes: 0$' "unset means off: run-stats says 0"
  assert_grep "$rootu/cap/l1-read-$hu.txt" 'lines elided by autodream for size' "the worker read the head/tail slim"
  if cmp -s "$root0/cap/l1-read-$h0.txt" "$rootu/cap/l1-read-$hu.txt"; then ok "the transcript the worker read is byte for byte the one read with the knob at 0"; else no "the transcript the worker read is byte for byte the one read with the knob at 0"; fi
  sed "s#$root0#R#g; s#$h0#H#g" "$root0/cap/l1-stdin-$h0.txt" > "$rootu/p0.txt"
  sed "s#$rootu#R#g; s#$hu#H#g" "$rootu/cap/l1-stdin-$hu.txt" > "$rootu/pu.txt"
  diff "$rootu/p0.txt" "$rootu/pu.txt" > "$rootu/prompt.diff" 2>&1; if [ ! -s "$rootu/prompt.diff" ]; then ok "and so is the prompt it was given"; else no "and so is the prompt it was given ($(head -c 300 "$rootu/prompt.diff"))"; fi
  assert_eq "$(jq -S 'del(.session_path)' "$fdu/$hu.json" | sed "s#$hu#H#g")" "$(jq -S 'del(.session_path)' "$fd0/$h0.json" | sed "s#$h0#H#g")" "and so is the findings JSON"
  assert_no_file "$fdu/.chunks" "no chunk directory"
  rm -rf "$root0" "$rootu"
}

test_noise_gate_knobs_are_validated(){
  echo "# noise gate: a non-numeric floor refuses to start instead of gating nothing"
  local root; root=$(setup_env); mk_session "$root" s1
  AUTODREAM_MIN_USER_TURNS=two run_dream "$root"
  assert_eq "$(cat "$root/run.exit")" "1" "a non-numeric AUTODREAM_MIN_USER_TURNS refuses to start"
  assert_grep "$root/run.out" 'AUTODREAM_MIN_USER_TURNS must be a non-negative integer' "and says why"
  AUTODREAM_MIN_MINUTES=1m run_dream "$root"
  assert_eq "$(cat "$root/run.exit")" "1" "and so does a non-numeric AUTODREAM_MIN_MINUTES"
  AUTODREAM_MIN_USER_TURNS=0 AUTODREAM_MIN_MINUTES=0 run_dream "$root"
  assert_eq "$(cat "$root/run.exit")" "0" "0 is valid for both"
  rm -rf "$root"
}

test_chunk_knobs_are_validated(){
  echo "# chunking: its knobs are validated at startup, in the house style"
  local root; root=$(setup_env); mk_session "$root" s1
  AUTODREAM_L1_CHUNK_BYTES=abc run_dream "$root"
  assert_eq "$(cat "$root/run.exit")" "1" "a non-numeric AUTODREAM_L1_CHUNK_BYTES refuses to start"
  assert_grep "$root/run.out" 'AUTODREAM_L1_CHUNK_BYTES must be a non-negative integer' "and says why"
  AUTODREAM_L1_MAX_CHUNKS=0 run_dream "$root"
  assert_eq "$(cat "$root/run.exit")" "1" "AUTODREAM_L1_MAX_CHUNKS=0 refuses to start"
  AUTODREAM_L1_MAX_CHUNKS=abc run_dream "$root"
  assert_eq "$(cat "$root/run.exit")" "1" "and so does a non-numeric one"
  AUTODREAM_L1_CHUNK_BYTES=0 run_dream "$root"
  assert_eq "$(cat "$root/run.exit")" "0" "AUTODREAM_L1_CHUNK_BYTES=0 is valid: it is the off switch"
  assert_grep "$(fdir "$root")/run-stats.txt" 'l1_chunk_bytes: 0$' "and run-stats says off"
  rm -rf "$root"
  root=$(setup_env); mk_session "$root" s1
  AUTODREAM_L1_CHUNK_BYTES=0300000 AUTODREAM_L1_MAX_CHUNKS=08 run_dream "$root"
  assert_eq "$(cat "$root/run.exit")" "0" "leading zeros are decimal, not an invalid octal (0300000 and 08)"
  assert_grep "$(fdir "$root")/run-stats.txt" 'l1_chunk_bytes: 300000$' "0300000 is 300000"
  assert_grep "$(fdir "$root")/run-stats.txt" 'l1_max_chunks: 8$' "and 08 is 8"
  rm -rf "$root"
}

test_chunking_degrades_when_the_helpers_are_absent(){
  echo "# chunking: an install whose helpers are not there reads the old way, loudly"
  local root; root=$(setup_env)
  local inst="$root/inst"; mkdir -p "$inst/bin"
  cp -R "$REPO/adapters" "$inst/adapters"
  local b; for b in "$REPO"/bin/*.sh; do case "$(basename "$b")" in chunk-transcript.sh|merge-chunks.sh) ;; *) cp "$b" "$inst/bin/" ;; esac; done
  local f; f=$(mk_chunky "$root" big 60); local h; h=$(hash_of "$f"); local fd; fd=$(fdir "$root")
  mkdir -p "$root/shim-default"; printf '#!/bin/bash\nprintf %s "200"\n' "'%s'" > "$root/shim-default/curl"; chmod +x "$root/shim-default/curl"
  PATH="$root/shim-default:$PATH" FANOUT=1 AUTODREAM_SLIM_BYTES=3000 AUTODREAM_L1_CHUNK_BYTES=2000 AUTODREAM_SLIM_HEAD=10 AUTODREAM_SLIM_TAIL=6 MOCK_CAPTURE_DIR="$root/cap" \
    AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" AUTODREAM_CONFIG="$root/autodream/config" \
    AUTODREAM_CONSUME_DATE="$DATE" AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    /bin/bash "$inst/bin/run.sh" "$DATE" > "$root/run.out" 2>&1
  local rc=$?
  cat "$root/autodream/logs/run-$DATE.log" >> "$root/run.out" 2>/dev/null || true
  assert_eq "$rc" "0" "the run exits 0"
  assert_grep "$root/run.out" 'chunk-transcript.sh or merge-chunks.sh was not found' "and the log says chunking is configured but could not run"
  assert_grep "$fd/run-stats.txt" 'l1_chunk_bytes: 0$' "run-stats records chunking as off"
  assert_eq "$(nreads "$root")" "0" "no chunk worker ran"
  assert_grep "$root/cap/l1-read-$h.txt" 'lines elided by autodream for size' "the transcript was read the old way, head and tail"
  rm -rf "$root"
}

test_a_failed_chunker_never_hands_a_worker_the_whole_slim(){
  echo "# chunking: when the chunker fails, the worker reads the capped head/tail slim, never the uncapped one"
  local root; root=$(setup_env)
  local inst="$root/inst"; mkdir -p "$inst/bin"
  cp -R "$REPO/adapters" "$inst/adapters"
  local b; for b in "$REPO"/bin/*.sh; do cp "$b" "$inst/bin/"; done
  printf '#!/bin/bash\nexit 2\n' > "$inst/bin/chunk-transcript.sh"; chmod +x "$inst/bin/chunk-transcript.sh"
  local f; f=$(mk_chunky "$root" big 60); local h; h=$(hash_of "$f"); local fd; fd=$(fdir "$root")
  mkdir -p "$root/shim-default"; printf '#!/bin/bash\nprintf %s "200"\n' "'%s'" > "$root/shim-default/curl"; chmod +x "$root/shim-default/curl"
  # AUTODREAM_SLIM_FULL=1 and RESHAPE=1 are exported on purpose: a mode a caller has set must not
  # leak into the fallback and turn the capped slim into the whole transcript.
  PATH="$root/shim-default:$PATH" FANOUT=1 AUTODREAM_SLIM_BYTES=3000 AUTODREAM_L1_CHUNK_BYTES=2000 AUTODREAM_SLIM_HEAD=10 AUTODREAM_SLIM_TAIL=6 \
    AUTODREAM_SLIM_FULL=1 AUTODREAM_SLIM_RESHAPE=1 \
    MOCK_CAPTURE_DIR="$root/cap" MOCK_TRANSCRIPT_LOG="$root/sizes.log" \
    AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" AUTODREAM_CONFIG="$root/autodream/config" \
    AUTODREAM_CONSUME_DATE="$DATE" AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    /bin/bash "$inst/bin/run.sh" "$DATE" > "$root/run.out" 2>&1
  cat "$root/autodream/logs/run-$DATE.log" >> "$root/run.out" 2>/dev/null || true
  assert_grep "$root/run.out" "chunker failed for $f" "the log names the failed chunker"
  assert_eq "$(wc -l < "$root/sizes.log" | tr -d ' ')" "1" "one engine call for the session"
  assert_grep "$root/cap/l1-read-$h.txt" 'lines elided by autodream for size' "it was handed the capped head/tail slim"
  assert_nogrep "$root/cap/l1-read-$h.txt" 'turn-030' "not the whole conversation"
  assert_eq "$(jq -r '.findings | type' "$fd/$h.json")" "array" "and the session was triaged"
  assert_grep "$fd/run-stats.txt" 'l1_chunked_sessions: 0$' "run-stats counts no chunked session"
  rm -rf "$root"
}

test_a_failed_chunker_on_a_transcript_that_was_never_slimmed_is_still_bounded(){
  echo "# chunking: a transcript under the slim threshold but over the chunk size, with a failed chunker, is still read bounded"
  local root; root=$(setup_env)
  local inst="$root/inst"; mkdir -p "$inst/bin"
  cp -R "$REPO/adapters" "$inst/adapters"
  local b; for b in "$REPO"/bin/*.sh; do cp "$b" "$inst/bin/"; done
  printf '#!/bin/bash\nexit 2\n' > "$inst/bin/chunk-transcript.sh"; chmod +x "$inst/bin/chunk-transcript.sh"
  local f; f=$(mk_chunky "$root" big 60); local h; h=$(hash_of "$f"); local fd; fd=$(fdir "$root")
  mkdir -p "$root/shim-default"; printf '#!/bin/bash\nprintf %s "200"\n' "'%s'" > "$root/shim-default/curl"; chmod +x "$root/shim-default/curl"
  PATH="$root/shim-default:$PATH" FANOUT=1 AUTODREAM_SLIM_BYTES=1000000 AUTODREAM_L1_CHUNK_BYTES=2000 AUTODREAM_SLIM_HEAD=10 AUTODREAM_SLIM_TAIL=6 \
    MOCK_CAPTURE_DIR="$root/cap" MOCK_TRANSCRIPT_LOG="$root/sizes.log" \
    AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" AUTODREAM_CONFIG="$root/autodream/config" \
    AUTODREAM_CONSUME_DATE="$DATE" AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    /bin/bash "$inst/bin/run.sh" "$DATE" > "$root/run.out" 2>&1
  cat "$root/autodream/logs/run-$DATE.log" >> "$root/run.out" 2>/dev/null || true
  assert_grep "$root/run.out" "chunker failed for $f" "the log names the failed chunker"
  assert_eq "$(wc -l < "$root/sizes.log" | tr -d ' ')" "1" "one engine call for the session"
  assert_grep "$root/cap/l1-read-$h.txt" 'lines elided by autodream for size' "it was handed the capped head/tail slim"
  assert_nogrep "$root/cap/l1-read-$h.txt" 'turn-030' "not the whole conversation"
  assert_eq "$(jq -r '.findings | type' "$fd/$h.json")" "array" "and the session was triaged"
  assert_grep "$fd/run-stats.txt" 'l1_chunked_sessions: 0$' "run-stats counts no chunked session"
  rm -rf "$root"
}

test_a_chunk_that_fails_is_retried_alone_and_finished_chunks_are_reused(){
  echo "# chunking: a chunk failure blocks the merge, only that chunk is redone, and finished ones are reused"
  local root; root=$(setup_env)
  local f; f=$(mk_chunky "$root" big 60); local h; h=$(hash_of "$f"); local fd; fd=$(fdir "$root")
  export MOCK_MODE=chunked MOCK_CALL_LOG="$root/calls.log" MOCK_FAIL_CHUNK=2 MOCK_FAIL_ONCE=1 AUTODREAM_L1_ROUNDS=2
  run_chunked "$root"; unset MOCK_MODE MOCK_CALL_LOG MOCK_FAIL_CHUNK MOCK_FAIL_ONCE AUTODREAM_L1_ROUNDS
  local n; n=$(jq -r .meta.chunks "$fd/$h.json" 2>/dev/null)
  [ "${n:-0}" -ge 3 ] && ok "round 2 finished the session ($n chunks)" || no "round 2 finished the session (got [$n])"
  assert_eq "$(wc -l < "$root/calls.log" | tr -d ' ')" "$((n + 1))" "$n chunks plus the one retry: only chunk 2 was called twice"
  assert_eq "$(grep -c '^01-' <(sed 's#.*/##' "$root/calls.log"))" "1" "chunk 1 was called once (round 2 reused its answer)"
  assert_eq "$(grep -c '^02-' <(sed 's#.*/##' "$root/calls.log"))" "2" "chunk 2 twice"
  assert_grep "$root/run.out" "reuse: chunk 1/$n of $f" "the log says it reused a finished chunk"
  assert_grep "$fd/run-stats.txt" "l1_chunk_calls: $((n + 1))\$" "run-stats counts the retry"
  assert_grep "$fd/run-stats.txt" "l1_chunks: $n\$" "and the chunks the session needed"
  assert_no_file "$fd/$h.json.err" "the failure's .err is gone once the session finished"
  assert_no_file "$fd/.chunks/$h" "and so is the chunk scratch"
  rm -rf "$root"
}

test_a_cached_chunk_answer_is_not_reused_after_the_instructions_or_the_session_change(){
  echo "# chunking: a finished chunk answer is reused only under the same prompt, stats block and chunk note"
  local scenario
  for scenario in prompt stats cap; do
    local root; root=$(setup_env)
    local f; f=$(mk_chunky "$root" big 60); local h; h=$(hash_of "$f"); local fd; fd=$(fdir "$root")
    # Run 1: a permanent refusal on chunk 2 defers the date and leaves chunk 1's answer behind.
    export MOCK_MODE=chunked MOCK_CALL_LOG="$root/calls1.log" MOCK_FAIL_CHUNK=2 MOCK_FAIL_KIND=refusal AUTODREAM_L1_ROUNDS=1
    run_chunked "$root"; unset MOCK_MODE MOCK_CALL_LOG MOCK_FAIL_CHUNK MOCK_FAIL_KIND AUTODREAM_L1_ROUNDS
    assert_eq "$(ls "$fd/.chunks/$h"/01-*.chunkout 2>/dev/null | wc -l | tr -d ' ')" "1" "[$scenario] run 1 left chunk 1's answer behind"
    case "$scenario" in
      prompt) printf '\nA changed instruction.\n' >> "$root/autodream/SESSION_TRIAGE.md" ;;
      stats)  # the session gained a turn between runs, so its stats block differs
        printf '{"parentUuid":"u60","type":"user","cwd":"/tmp/proj-a","uuid":"u61","timestamp":"2020-01-02T12:31:00.000Z","message":{"role":"user","content":"turn-061 one more"}}\n' >> "$f"
        touch -t "$STAMP" "$f" ;;
      cap)    # chunk 1 keeps its text but is now chunk 1 of 2 with the middle omitted
        export AUTODREAM_L1_MAX_CHUNKS=2 ;;
    esac
    export MOCK_MODE=chunked MOCK_CALL_LOG="$root/calls2.log" AUTODREAM_L1_ROUNDS=1
    run_chunked "$root"; unset MOCK_MODE MOCK_CALL_LOG AUTODREAM_L1_ROUNDS AUTODREAM_L1_MAX_CHUNKS
    assert_eq "$(grep -c '^01-' <(sed 's#.*/##' "$root/calls2.log"))" "1" "[$scenario] chunk 1 was called again, not served from the old answer"
    assert_nogrep "$root/run.out" "reuse: chunk 1/" "[$scenario] and the log does not say it reused it"
    assert_eq "$(jq -r 'has("error")' "$fd/$h.json" 2>/dev/null)" "false" "[$scenario] the session finished"
    rm -rf "$root"
  done
}

test_a_bad_chunk_answer_is_never_merged_around(){
  echo "# chunking: an error, partial or malformed chunk answer blocks the merge and is redone alone"
  local kind
  for kind in error nofindings typed two; do
    local root; root=$(setup_env)
    local f; f=$(mk_chunky "$root" big 60); local h; h=$(hash_of "$f"); local fd; fd=$(fdir "$root")
    export MOCK_MODE=chunked MOCK_CALL_LOG="$root/calls.log" MOCK_BAD_CHUNK=2 MOCK_BAD_KIND="$kind" AUTODREAM_L1_ROUNDS=1
    run_chunked "$root"; unset MOCK_MODE MOCK_CALL_LOG MOCK_BAD_CHUNK MOCK_BAD_KIND AUTODREAM_L1_ROUNDS
    # One round, so that round is the last: the session gets the honest stub, never a merge of
    # the chunks that did answer.
    assert_eq "$(jq -r 'has("error")' "$fd/$h.json")" "true" "[$kind] after the only round the session carries the error stub"
    assert_eq "$(jq -r '[.findings[]?] | length' "$fd/$h.json")" "0" "[$kind] and none of the other chunks' findings were published"
    assert_eq "$(jq -r 'has("underlying_goal")' "$fd/$h.json")" "false" "[$kind] it is not a merge of the chunks that answered"
    assert_grep "$fd/$h.json.err" 'no usable .findings key' "[$kind] the .err says the answer was refused"
    rm -rf "$root"
    root=$(setup_env)
    f=$(mk_chunky "$root" big 60); h=$(hash_of "$f"); fd=$(fdir "$root")
    export MOCK_MODE=chunked MOCK_CALL_LOG="$root/calls.log" MOCK_BAD_CHUNK=2 MOCK_BAD_KIND="$kind" AUTODREAM_L1_ROUNDS=2
    run_chunked "$root"; unset MOCK_MODE MOCK_CALL_LOG MOCK_BAD_CHUNK MOCK_BAD_KIND AUTODREAM_L1_ROUNDS
    local n; n=$(jq -r .meta.chunks "$fd/$h.json" 2>/dev/null)
    assert_eq "$(jq -r 'has("error")' "$fd/$h.json")" "false" "[$kind] with a second round the session is merged properly"
    assert_eq "$(wc -l < "$root/calls.log" | tr -d ' ')" "$((n + 1))" "[$kind] and only chunk 2 was redone"
    assert_eq "$(jq -r '[.findings[] | select(.what | startswith("finding-from-chunk-"))] | length' "$fd/$h.json")" "$n" "[$kind] every chunk's finding is in the merge, none twice"
    rm -rf "$root"
  done
}

test_a_chunk_failure_is_classified_like_any_worker_failure(){
  echo "# chunking: a chunk failure leaves the same evidence and the same classification as a whole-session one"
  # shellcheck source=../bin/failure-class.sh
  . "$REPO/bin/failure-class.sh"
  local kind want root f h fd
  for kind in silent:silent noisy:provider context:size; do
    want=${kind#*:}; kind=${kind%%:*}
    root=$(setup_env); f=$(mk_chunky "$root" big 60); h=$(hash_of "$f"); fd=$(fdir "$root")
    export MOCK_MODE=chunked MOCK_FAIL_CHUNK=2 MOCK_FAIL_KIND="$kind" AUTODREAM_L1_ROUNDS=1
    run_chunked "$root"; unset MOCK_MODE MOCK_FAIL_CHUNK MOCK_FAIL_KIND AUTODREAM_L1_ROUNDS
    assert_eq "$(classify_failure "$fd/$h.json.err")" "$want" "[$kind] chunk 2 failing is classified $want"
    assert_grep "$fd/$h.json.err" "worker produced no findings JSON for chunk 2/" "[$kind] the .err names the chunk that failed"
    assert_grep "$fd/$h.json.err" '^worker exit code: ' "[$kind] with the exit code line the classifier reads"
    assert_eq "$(jq -r 'has("error")' "$fd/$h.json")" "true" "[$kind] the last round writes the session-level stub"
    assert_eq "$(jq -r .meta.chunks "$fd/$h.json")" "$(awk 'END {print $2}' "$fd/l1-chunks.txt")" "[$kind] and the stub says how many chunks the session had"
    rm -rf "$root"
  done
}

test_a_provider_refusal_on_a_chunk_defers_the_date_and_stops_the_other_chunks(){
  echo "# chunking: a permanent provider refusal on a chunk defers the date like any worker, and no stub, no further calls"
  local root; root=$(setup_env)
  local f; f=$(mk_chunky "$root" big 60); local h; h=$(hash_of "$f"); local fd; fd=$(fdir "$root")
  mk_session "$root" other
  export MOCK_MODE=chunked MOCK_CALL_LOG="$root/calls.log" MOCK_FAIL_CHUNK=2 MOCK_FAIL_KIND=refusal AUTODREAM_L1_ROUNDS=2
  run_chunked "$root"; unset MOCK_MODE MOCK_CALL_LOG MOCK_FAIL_CHUNK MOCK_FAIL_KIND AUTODREAM_L1_ROUNDS
  assert_grep "$fd/l1-netdown.txt" "^$h [12] provider\$" "the failure is ledgered as a provider refusal"
  assert_no_file "$fd/$h.json" "no stub: the session is left for a later run"
  assert_eq "$(grep -c '^0[3-9]-' <(sed 's#.*/##' "$root/calls.log"))" "0" "no chunk after the refused one was called, in either round"
  assert_eq "$(cat "$root/run.exit")" "1" "the date is deferred, so the run exits non-zero"
  assert_no_file "$root/dreams/$DATE.md" "and writes no report from a short corpus"
  assert_grep "$fd/run-stats.txt" 'network_deferred: yes' "run-stats says it was deferred"
  assert_eq "$(ls "$fd/.chunks/$h"/01-*.chunkout 2>/dev/null | wc -l | tr -d ' ')" "1" "the answer chunk 1 gave is kept for the next run"
  rm -rf "$root"
}

test_chunk_files_are_never_mistaken_for_findings(){
  echo "# chunking: chunk outputs left on disk are invisible to every consumer of the findings directory"
  local root; root=$(setup_env)
  local f; f=$(mk_chunky "$root" big 60); local h; h=$(hash_of "$f"); local fd; fd=$(fdir "$root")
  mk_session "$root" other; local ho; ho=$(hash_of "$root/projects/proj-a/other.jsonl")
  export MOCK_MODE=chunked MOCK_FAIL_CHUNK=2 MOCK_FAIL_KIND=refusal AUTODREAM_L1_ROUNDS=1
  run_chunked "$root"; unset MOCK_MODE MOCK_FAIL_CHUNK MOCK_FAIL_KIND AUTODREAM_L1_ROUNDS
  # The state a killed or deferred run leaves: finished chunk answers, a failed chunk's .err/.out.
  assert_eq "$(ls "$fd/.chunks/$h" | grep -c '\.chunkout$')" "1" "(a finished chunk answer is on disk)"
  assert_eq "$(find "$fd" -type f -name '*.json' ! -name '*.stats.json' | wc -l | tr -d ' ')" "1" "the recursive findings count sees only the other session's findings JSON"
  assert_eq "$(find "$fd" -maxdepth 1 -type f -name '*.json' ! -name '*.stats.json' | wc -l | tr -d ' ')" "1" "and so does the flat one"
  assert_eq "$(ls "$fd"/*.json.err 2>/dev/null | wc -l | tr -d ' ')" "1" "the failed session's own .err is the one error file (chunk errs live under .chunks)"
  assert_grep "$fd/run-stats.txt" 'l1_findings_written: 1$' "run-stats counts one findings JSON"
  local out; out=$(bash "$REPO/tests/replay.sh" --artifacts "$fd" 2>&1); local rc=$?
  assert_eq "$rc" "0" "replay --artifacts passes over the directory"
  printf '%s' "$out" > "$root/replay.out"
  assert_grep "$root/replay.out" 'all 1 findings JSONs have the findings-array shape' "and counts one findings JSON, not the chunk answers"
  out=$(bash "$REPO/bin/oversized-gate.sh" "$fd" 2>&1); rc=$?
  assert_eq "$rc" "0" "oversized-gate runs"
  # A chunk directory no session in tonight's worklist owns (a killed run of a session that is gone).
  mkdir -p "$fd/.chunks/deadbeef0000"
  printf '{"findings":[]}' > "$fd/.chunks/deadbeef0000/01-aaaaaaaaaaaa.chunkout"
  printf 'worker exit code: 1 after 3s\n' > "$fd/.chunks/deadbeef0000/01.err"
  # The next run, no longer failing, reuses chunk 1 and finishes.
  export MOCK_MODE=chunked; AUTODREAM_FORCE=1 run_chunked "$root"; unset MOCK_MODE
  assert_eq "$(jq -r '.findings | type' "$fd/$h.json")" "array" "the retry run finishes the session"
  assert_no_file "$fd/.chunks/$h" "and its own chunk directory is gone"
  assert_file "$fd/.chunks/deadbeef0000/01-aaaaaaaaaaaa.chunkout" "(the foreign one is still there: nothing that scans the directory touched it)"
  assert_grep "$fd/run-stats.txt" 'l1_findings_outside_worklist: 0$' "a chunk answer does not read as a findings JSON outside the worklist"
  assert_grep "$fd/run-stats.txt" 'l1_err_files_orphaned: 0$' "and a chunk .err does not read as an orphan"
  assert_grep "$fd/run-stats.txt" "l1_findings_written: 2\$" "and only the two sessions have findings"
  rm -rf "$root"
}

test_the_circuit_breaker_counts_finished_chunks_as_progress(){
  echo "# chunking: a round that finishes chunks but no whole session is progress, not a barren round"
  local root; root=$(setup_env)
  local f; f=$(mk_chunky "$root" big 60); local h; h=$(hash_of "$f"); local fd; fd=$(fdir "$root")
  # Chunk 3 always fails. Round 1 finishes every other chunk (progress), rounds 2 and 3 finish
  # nothing new, so the breaker fires after round 3. Counting sessions alone it would have fired
  # after round 2, having called round 1 barren while it did most of the work.
  export MOCK_MODE=chunked MOCK_FAIL_CHUNK=3 MOCK_FAIL_KIND=silent AUTODREAM_L1_ROUNDS=5
  run_chunked "$root"; unset MOCK_MODE MOCK_FAIL_CHUNK MOCK_FAIL_KIND AUTODREAM_L1_ROUNDS
  assert_grep "$root/run.out" 'circuit breaker: 2 consecutive rounds recovered nothing.*as of round 3' "the breaker fired after round 3, not round 2"
  assert_grep "$fd/run-stats.txt" 'l1_breaker_fired: yes' "and run-stats says it fired"
  assert_eq "$(jq -r 'has("error")' "$fd/$h.json")" "true" "the stub round still ran, so the session is visible and not an empty slot"
  rm -rf "$root"
}

test_chunk_inputs_are_private_and_removed(){
  echo "# chunking: chunk inputs are transcript text, so they are private and never survive the round"
  local root; root=$(setup_env)
  local f; f=$(mk_chunky "$root" big 60); local h; h=$(hash_of "$f"); local fd; fd=$(fdir "$root")
  mk_session "$root" other
  # What a worker killed mid-round leaves behind: transcript copies no worker is going to remove.
  mkdir -p "$fd"
  printf 'leftover transcript text\n' > "$fd/deadbeefdead.slim.jsonl"; printf 'x\n' > "$fd/deadbeefdead.day.jsonl"; printf 'x\n' > "$fd/deadbeefdead.norm.jsonl"
  export MOCK_MODE=chunked MOCK_FAIL_CHUNK=2 MOCK_FAIL_KIND=refusal AUTODREAM_L1_ROUNDS=1
  ( umask 022; run_chunked "$root" ); unset MOCK_MODE MOCK_FAIL_CHUNK MOCK_FAIL_KIND AUTODREAM_L1_ROUNDS
  assert_no_file "$fd/.chunks/$h/in" "the chunk inputs are removed after the round, even though the session is still pending"
  assert_eq "$(ls "$fd" | grep -c '\.slim\.jsonl$\|\.day\.jsonl$\|\.norm\.jsonl$')" "0" "and so are the slim and the other transcript copies, including ones a killed worker left"
  rm -rf "$root"
}

# ---- Chunking on omp: chunk the linearized copy AFTER the day cut ----------------------------
mk_omp_long(){ # $1=root $2=name $3=pairs on DATE -> path. One day-1 pair and one day-3 pair frame the DATE entries
  local d="$1/home/.omp/agent/sessions/proj-o" f i prev="a0" m s
  mkdir -p "$d"; f="$d/2020-01-01T10-00-00-000Z_$2.jsonl"
  local msg='"message":{"role":"%s","content":[{"type":"text","text":"%s"}]}'
  {
    printf '%s\n' '{"type":"title","title":"t","v":1}'
    printf '{"type":"session","id":"01a00000-0000-7000-8000-000000000004","cwd":"/tmp/proj-o","timestamp":"2020-01-01T10:00:00.000Z"}\n'
    printf '{"type":"message","id":"a0","parentId":null,"timestamp":"2020-01-01T12:00:00.000Z",'"$msg"'}\n' user DAY1_ENTRY
    for i in $(seq 1 "$3"); do
      m=$((i / 2)); s=$(( (i % 2) * 30 ))
      printf '{"type":"message","id":"u%d","parentId":"%s","timestamp":"2020-01-02T12:%02d:%02d.000Z",'"$msg"'}\n' "$i" "$prev" "$m" "$s" user "turn-$(printf '%03d' "$i") user words for the line to have a body" 
      printf '{"type":"message","id":"a%d","parentId":"u%d","timestamp":"2020-01-02T12:%02d:%02d.500Z",'"$msg"'}\n' "$i" "$i" "$m" "$s" assistant "reply-$(printf '%03d' "$i") assistant words"
      prev="a$i"
    done
    printf '{"type":"message","id":"z1","parentId":"%s","timestamp":"2020-01-03T12:00:00.000Z",'"$msg"'}\n' "$prev" user DAY3_ENTRY
  } > "$f"
  touch -t "$LATE" "$f"
  printf '%s' "$f"
}

test_chunking_an_omp_session_cuts_the_day_then_chunks_the_live_chain(){
  echo "# chunking (omp): the linearized copy is cut to the day first and the day is what is chunked"
  local root; root=$(setup_env); mk_session "$root" sess1
  local o; o=$(mk_omp_long "$root" long 40); local h; h=$(hash_of "$o"); local fd; fd=$(fdir "$root")
  export FANOUT=1 MOCK_MODE=chunked MOCK_CAPTURE_DIR="$root/cap" AUTODREAM_SLIM_BYTES=3000 AUTODREAM_L1_CHUNK_BYTES=2500
  run_dream_omp "$root"; unset FANOUT MOCK_MODE MOCK_CAPTURE_DIR AUTODREAM_SLIM_BYTES AUTODREAM_L1_CHUNK_BYTES
  local n; n=$(nreads "$root")
  [ "$n" -ge 2 ] && ok "the omp session was split into $n chunks" || no "the omp session was split into chunks (got $n)"
  assert_nogrep "$fd/$h.json" 'could not be normalized' "it was not refused by the linearizer"
  assert_eq "$(chunk_reads "$root" | xargs cat | grep -c 'DAY1_ENTRY\|DAY3_ENTRY')" "0" "no chunk holds an entry from another day"
  assert_eq "$(turn_stats "$root")" "40/1" "the 40 turns of the day are in exactly one chunk each"
  assert_eq "$(head -n 1 "$(chunk_reads "$root" | sort | head -1)" | jq -r .type)" "autodream_meta" "the first chunk opens with the session header"
  assert_eq "$(jq -r .meta.chunks "$fd/$h.json")" "$n" "the merged findings record the chunk count"
  assert_eq "$(jq -r .session_path "$fd/$h.json")" "$o" "and name the real session"
  assert_grep "$fd/sessions-source.txt" "^$h	omp$" "it is an omp session"
  assert_grep "$fd/run-stats.txt" 'l1_chunked_sessions: 1$' "run-stats counts it"
  rm -rf "$root"
}

test_chunking_reads_the_whole_conversation_in_chunks
test_chunking_leaves_a_transcript_that_fits_alone
test_chunk_cap_drops_the_middle_and_counts_it
test_chunk_cap_of_one_reads_one_chunk_never_the_whole_transcript
test_chunking_off_is_the_old_behaviour
test_chunking_is_off_when_the_knob_is_unset
test_chunk_knobs_are_validated
test_noise_gate_knobs_are_validated
test_chunking_degrades_when_the_helpers_are_absent
test_a_failed_chunker_never_hands_a_worker_the_whole_slim
test_a_failed_chunker_on_a_transcript_that_was_never_slimmed_is_still_bounded
test_a_chunk_that_fails_is_retried_alone_and_finished_chunks_are_reused
test_a_cached_chunk_answer_is_not_reused_after_the_instructions_or_the_session_change
test_a_bad_chunk_answer_is_never_merged_around
test_a_chunk_failure_is_classified_like_any_worker_failure
test_a_provider_refusal_on_a_chunk_defers_the_date_and_stops_the_other_chunks
test_chunk_files_are_never_mistaken_for_findings
test_the_circuit_breaker_counts_finished_chunks_as_progress
test_chunk_inputs_are_private_and_removed
test_chunking_an_omp_session_cuts_the_day_then_chunks_the_live_chain

# ---- The unit suites, run here and not only in CI ---------------------------
# CLAUDE.md tells contributors "run tests/run-all.sh after any run.sh/prompt
# change", and these five were wired into the workflow only — so a local pre-push
# run skipped adapter containment, the manifest-name check and the entire
# contract suite, which is the gap the CI step's own comment says it closes.
# Their counts fold into the totals below, so a red unit suite fails this script.
echo
echo "===== unit suites ====="
# The suites that drive launchd need plutil and launchctl, so they run on macOS only (CI runs
# them in launchd.yml, when a launchd file changes).
_suites="portable lib-project preflight adapters adapter-claude adapter-omp adapter-contract slim-transcript session-window merge-chunks chunk-transcript apply-pins review-skip review-cmux notes-path tmp-cleanup dream-triage cookie-cadence x-bookmarks prune-worktrees triage-candidates pending-triage report-format l2-prompt"
[ "$(uname -s)" = Darwin ] && _suites="$_suites scheduler-label autodream-now install-review-agent install-dry-run install-dir install-skill"
for _suite in $_suites; do
  _out=$(bash "$HERE/$_suite.sh" 2>&1)
  _rc=$?
  _p=$(printf '%s\n' "$_out" | sed -n 's/^passed: *\([0-9][0-9]*\).*/\1/p' | tail -1)
  _f=$(printf '%s\n' "$_out" | sed -n 's/.*failed: *\([0-9][0-9]*\).*/\1/p' | tail -1)
  pass=$((pass + ${_p:-0}))
  fail=$((fail + ${_f:-0}))
  if [ "$_rc" -ne 0 ] || [ "${_f:-0}" -ne 0 ]; then
    printf '  FAIL - unit suite %s\n' "$_suite"
    printf '%s\n' "$_out" | grep 'FAIL' | head -5
    # A suite that dies before printing a total reports no failures at all, so
    # count one rather than letting a crash read as green.
    [ -n "$_f" ] && [ "$_f" -ne 0 ] || fail=$((fail + 1))
  else
    printf '  ok   - unit suite %-18s (%s assertions)\n' "$_suite" "${_p:-0}"
  fi
done

streak_rows(){ awk '!/^#/ && NF' "$1" 2>/dev/null | wc -l | tr -d ' '; }

test_question_streaks_state_lives_with_the_install(){
  echo "# question streaks: the store is the install's, one file holds the watermark, clear takes the lock"
  local root; root=$(setup_env)
  local QS="$REPO/bin/question-streaks.sh"
  [ -x "$QS" ] || { no "question-streaks.sh executable"; return 0; }
  mkdir -p "$root/home"
  : > "$root/autodream/config"
  local f; for f in "$REPO"/bin/*.sh; do ln -sf "$f" "$root/autodream/$(basename "$f")"; done
  printf 'abc123def456\t2\t2019-12-30\t2019-12-31\tStale question?\n' > "$root/autodream/question-streaks.tsv"

  # Run with no AUTODREAM_DIR at all, the documented no-environment invocation. The helper
  # used to fall back to ~/.claude/autodream and never see this install's store.
  local out
  out=$(env -u AUTODREAM_DIR -u AUTODREAM_QUESTION_STATE HOME="$root/home" bash "$root/autodream/question-streaks.sh" status 2>&1)
  case "$out" in *"Stale question?"*) ok "status run through the install link reads the install's store" ;; *) no "status run through the install link reads the install's store (got: $out)" ;; esac

  # A night with no sessions writes a question-free report and must clear that store. This
  # run.sh takes its install dir from AUTODREAM_DIR (default ~/.claude/autodream) rather than
  # from its own location, so the sandbox install is named explicitly. When the value comes
  # from that default instead, it is not exported on the early path, which is why both call
  # sites pass it to the helper.
  env HOME="$root/home" AUTODREAM_DIR="$root/autodream" AUTODREAM_CHANGELOG=0 AUTODREAM_GC=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_NOTIFY_DRYRUN=1 \
    PROJECTS_DIR="$root/projects" DREAMS_DIR="$root/dreams" \
    /bin/bash "$root/autodream/run.sh" "$DATE" > "$root/run.out" 2>&1
  assert_file "$root/dreams/$DATE.md" "precondition: the empty night wrote its report"
  assert_eq "$(streak_rows "$root/autodream/question-streaks.tsv")" "0" "the empty night clears the install's streak store"

  # Clearing the board must not erase the watermark: rebuilding an older report afterwards
  # would otherwise re-enter history as a new night and grow a false streak.
  local st="$root/w.tsv"; : > "$st"
  qsw(){ AUTODREAM_QUESTION_STATE="$st" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" "$@" 2>&1; }
  printf '## Open questions for the user\n\n1. **Recurring?** body\n\n<!-- autodream:open-questions=1 -->\n' > "$root/2026-03-01.md"
  printf '## Open questions for the user\n\nNone.\n\n<!-- autodream:open-questions=0 -->\n' > "$root/2026-03-02.md"
  qsw update "$root/2026-03-01.md" >/dev/null
  qsw update "$root/2026-03-02.md" >/dev/null
  out=$(qsw update "$root/2026-03-01.md")
  case "$out" in *"older than the last counted report"*) ok "an older rebuild after a cleared board is still refused" ;; *) no "an older rebuild after a cleared board is still refused (got: $out)" ;; esac
  assert_eq "$(streak_rows "$st")" "0" "and the cleared board stays clear"
  # One file, one write. The watermark used to live beside the state, and three reviews in
  # a row found an order of writes between the two files that let history back in.
  assert_eq "$(head -1 "$st")" "$(printf '#last\t2026-03-02')" "the watermark is the first line of the state file"
  assert_no_file "$st.last" "and no second watermark file is written"

  # clear takes the same lock as update, or an update that already read the old state puts
  # the cleared streak back when it writes.
  printf 'k\t1\t2026-03-03\t2026-03-03\tHeld?\n' > "$st"
  mkdir "$st.lock"
  AUTODREAM_QUESTION_STATE="$st" bash "$QS" clear all >/dev/null 2>&1; local rc=$?
  rmdir "$st.lock" 2>/dev/null
  assert_eq "$rc" "1" "clear fails while an update holds the lock"
  assert_eq "$(streak_rows "$st")" "1" "and leaves the state for that update"

  # An EMPTY board is not a reason to skip the lock: an update holding it may be about to
  # write the first streak, which clear would then report as cleared (Codex review of 4eea84d).
  : > "$st"
  mkdir "$st.lock"
  AUTODREAM_QUESTION_STATE="$st" bash "$QS" clear all >/dev/null 2>&1; rc=$?
  rmdir "$st.lock" 2>/dev/null
  assert_eq "$rc" "1" "clear on an empty board still waits for the lock and fails while it is held"

  # A state file that exists but cannot be read is not an empty board. Reading it as empty
  # restarts every streak and drops the watermark with it. Write-only, so a write would land.
  local st2="$root/w2.tsv"; : > "$st2"
  qs2(){ AUTODREAM_QUESTION_STATE="$st2" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" "$@" 2>&1; }
  printf '## Open questions for the user\n\n1. **Recurring?** body\n\n<!-- autodream:open-questions=1 -->\n' > "$root/2026-03-04.md"
  qs2 update "$root/2026-03-01.md" >/dev/null
  cp "$st2" "$root/w2.before"
  chmod 200 "$st2"
  qs2 update "$root/2026-03-04.md" >/dev/null
  chmod 644 "$st2"
  if cmp -s "$st2" "$root/w2.before"; then ok "an unreadable state file refuses the update instead of restarting every streak"; else no "an unreadable state file refuses the update instead of restarting every streak"; fi

  # A state directory that cannot take a temp file leaves the state as it was.
  mkdir -p "$root/ro"; local st3="$root/ro/w3.tsv"
  AUTODREAM_QUESTION_STATE="$st3" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" update "$root/2026-03-01.md" >/dev/null 2>&1
  cp "$st3" "$root/w3.before"
  chmod 500 "$root/ro"
  AUTODREAM_QUESTION_STATE="$st3" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" update "$root/2026-03-04.md" >/dev/null 2>&1
  chmod 700 "$root/ro"
  if cmp -s "$st3" "$root/w3.before"; then ok "a state directory that refuses a temp file leaves state untouched"; else no "a state directory that refuses a temp file leaves state untouched"; fi

  # clear all forgets the streaks and keeps the watermark, so an older rebuild afterwards is
  # still refused. status never prints the watermark line as a streak.
  local st6="$root/w6.tsv"; : > "$st6"
  qs6(){ AUTODREAM_QUESTION_STATE="$st6" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" "$@" 2>&1; }
  qs6 update "$root/2026-03-04.md" >/dev/null
  out=$(qs6 status)
  case "$out" in *"#last"*) no "status does not print the watermark line (got: $out)" ;; *"Recurring?"*) ok "status does not print the watermark line" ;; *) no "status does not print the watermark line (got: $out)" ;; esac
  qs6 clear all >/dev/null
  assert_eq "$(head -1 "$st6")" "$(printf '#last\t2026-03-04')" "clear all keeps the watermark"
  out=$(qs6 update "$root/2026-03-01.md")
  case "$out" in *"older than the last counted report"*) ok "and an older rebuild after clear all is refused" ;; *) no "and an older rebuild after clear all is refused (got: $out)" ;; esac

  # A state path whose directory does not exist yet. The lock lives beside the state, so
  # the directory has to exist before the lock is taken, or every update reads as a held
  # lock and exits without ever creating the state (Codex review of b72f0e4).
  local nested="$root/new/nested/question-streaks.tsv"
  AUTODREAM_QUESTION_STATE="$nested" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" update "$root/2026-03-04.md" >/dev/null 2>&1
  assert_eq "$(streak_rows "$nested")" "1" "the first update on a new state directory creates the state"

  # The final rename can fail. The whole state is one temp file renamed into place, so a
  # failed rename leaves the old file whole: board and watermark together.
  local st4="$root/w4.tsv"; : > "$st4"
  mkdir -p "$root/failmv"
  printf '#!/bin/sh\nexit 1\n' > "$root/failmv/mv"; chmod +x "$root/failmv/mv"
  printf '## Open questions for the user\n\n1. **Another?** body\n\n<!-- autodream:open-questions=1 -->\n' > "$root/2026-03-03.md"
  AUTODREAM_QUESTION_STATE="$st4" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" update "$root/2026-03-01.md" >/dev/null 2>&1
  cp "$st4" "$root/w4.before"
  PATH="$root/failmv:$PATH" AUTODREAM_QUESTION_STATE="$st4" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" update "$root/2026-03-02.md" >/dev/null 2>&1
  if cmp -s "$st4" "$root/w4.before"; then ok "a failed watermark move on a question-free report leaves the board as it was"; else no "a failed watermark move on a question-free report leaves the board as it was"; fi
  PATH="$root/failmv:$PATH" AUTODREAM_QUESTION_STATE="$st4" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" update "$root/2026-03-03.md" >/dev/null 2>&1
  if cmp -s "$st4" "$root/w4.before"; then ok "a failed watermark move on a report with questions leaves the board as it was"; else no "a failed watermark move on a report with questions leaves the board as it was"; fi
  rm -rf "$root"
}

test_question_streaks(){
  echo "# question streaks: count repeats across reports and escalate the stale ones"
  local root; root=$(setup_env)
  local QS="$REPO/bin/question-streaks.sh"
  [ -x "$QS" ] || { no "question-streaks.sh executable"; return 0; }
  local st="$root/streaks.tsv"; : > "$st"
  local out
  qs(){ AUTODREAM_QUESTION_STATE="$st" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" "$@" 2>&1; }

  mk_report(){ # $1=date  $2..=bold titles
    local d="$1"; shift
    { printf '## Open questions for the user\n\n'
      local i=1
      for t in "$@"; do printf '%d. **%s** body text that is rewritten every night\n' "$i" "$t"; i=$(( i + 1 )); done
      printf '\n<!-- autodream:open-questions=%d -->\n' "$#"
    } > "$root/$d.md"
  }

  # The real shape this was built from: the title is byte-identical night to night while
  # the body prose is rewritten, so an exact key on the title is enough.
  mk_report 2026-01-01 "Fix the X bookmarks walker, or turn the feature off?" "Something else?"
  mk_report 2026-01-02 "Fix the X bookmarks walker, or turn the feature off?"
  mk_report 2026-01-03 "Fix the X bookmarks walker, or turn the feature off?"

  out=$(qs update "$root/2026-01-01.md")
  assert_eq "$(printf '%s' "$out" | grep -c 'past 3 consecutive')" "1" "night 1 reports its count"
  case "$out" in *"0 at or past"*) ok "night 1 escalates nothing" ;; *) no "night 1 escalates nothing (got: $out)" ;; esac

  out=$(qs update "$root/2026-01-02.md")
  case "$out" in *"0 at or past"*) ok "night 2 still escalates nothing" ;; *) no "night 2 still escalates nothing" ;; esac
  # The question that vanished must stop counting rather than linger forever.
  assert_eq "$(grep -c 'Something else' "$st")" "0" "a question absent from a later report is dropped"

  out=$(qs update "$root/2026-01-03.md")
  case "$out" in
    *"3 consecutive reports"*) ok "night 3 escalates the repeated question" ;;
    *) no "night 3 escalates the repeated question (got: $out)" ;;
  esac
  case "$out" in *"Fix the X bookmarks walker"*) ok "the escalation names the question" ;; *) no "the escalation names the question" ;; esac

  # Streaks count consecutive REPORTS, not calendar days — a night that produced no report
  # must not reset one, since surviving failing nights is the whole point.
  mk_report 2026-01-09 "Fix the X bookmarks walker, or turn the feature off?"
  out=$(qs update "$root/2026-01-09.md")
  case "$out" in *"4 consecutive reports"*) ok "a date gap does not reset the streak" ;; *) no "a date gap does not reset the streak (got: $out)" ;; esac

  # A report with genuinely zero questions clears the board.
  printf '## Open questions for the user\n\nNone.\n\n<!-- autodream:open-questions=0 -->\n' > "$root/2026-01-10.md"
  qs update "$root/2026-01-10.md" >/dev/null
  # wc -l, not `grep -c . || echo 0`: grep -c prints 0 AND exits 1 on no match, so the
  # fallback fires too and the value is "0\n0". That trap is documented in this repo and
  # it still caught this test on the first run.
  assert_eq "$(streak_rows "$st")" "0" "a question-free report clears every streak"

  # A marker that promises questions while none parse means the format moved. That must be
  # reported, never silently counted as zero — the quiet version would freeze every streak
  # at its last value and the escalation would never fire again.
  printf '## Open questions for the user\n\n1. no bold title here?\n\n<!-- autodream:open-questions=1 -->\n' > "$root/2026-01-11.md"
  out=$(qs update "$root/2026-01-11.md")
  case "$out" in *"title format changed"*) ok "a changed title format warns instead of counting zero" ;; *) no "a changed title format warns instead of counting zero (got: $out)" ;; esac

  rm -rf "$root"
}

test_question_streaks_reruns_and_mismatch(){
  echo "# question streaks: reruns, backwards rebuilds, count mismatch, clear failure"
  local root; root=$(setup_env)
  local QS="$REPO/bin/question-streaks.sh"
  [ -x "$QS" ] || { no "question-streaks.sh executable"; return 0; }
  local st="$root/streaks.tsv"; : > "$st"
  local out
  qs(){ AUTODREAM_QUESTION_STATE="$st" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" "$@" 2>&1; }
  mk(){ # $1=date $2=marker $3..=titles
    local d="$1" m="$2"; shift 2
    { printf '## Open questions for the user\n\n'
      local i=1
      for t in "$@"; do printf '%d. **%s** nightly-rewritten body\n' "$i" "$t"; i=$(( i + 1 )); done
      printf '\n<!-- autodream:open-questions=%d -->\n' "$m"
    } > "$root/$d.md"
  }

  mk 2026-02-01 1 "Recurring question?"
  mk 2026-02-02 1 "Recurring question?"
  qs update "$root/2026-02-01.md" >/dev/null
  qs update "$root/2026-02-02.md" >/dev/null
  assert_eq "$(awk -F'\t' '!/^#/ {print $2}' "$st")" "2" "two distinct reports count two"

  # AUTODREAM_FORCE=1 rebuilds the same report. Counting it again would manufacture an
  # escalation out of a rerun.
  qs update "$root/2026-02-02.md" >/dev/null
  assert_eq "$(awk -F'\t' '!/^#/ {print $2}' "$st")" "2" "rebuilding the same report does not advance the streak"

  # A rebuild of an OLDER date must not rewrite live state with history: 02-01 does not
  # know about anything that happened on 02-02.
  out=$(qs update "$root/2026-02-01.md")
  case "$out" in *"older than the last counted report"*) ok "an older rebuild is refused" ;; *) no "an older rebuild is refused (got: $out)" ;; esac
  assert_eq "$(awk -F'\t' '!/^#/ {print $4}' "$st")" "2026-02-02" "and the live last-seen date is untouched"

  # The marker is the report's own count. Disagreement means questions parsed as nothing;
  # touching state would silently drop a streak or freeze them all.
  mk 2026-02-03 2 "Recurring question?"   # marker says 2, only 1 bold title present
  out=$(qs update "$root/2026-02-03.md")
  case "$out" in *"but 1 parsed"*) ok "a parsed-vs-marker mismatch warns" ;; *) no "a parsed-vs-marker mismatch warns (got: $out)" ;; esac
  assert_eq "$(awk -F'\t' '!/^#/ {print $2}' "$st")" "2" "and refuses to change state"

  # A report with no count marker is incomplete: an L2 run truncated before the Open
  # questions section, left in place when run.sh could not move it aside. Parsing it as
  # zero questions cleared every streak and advanced the watermark (Codex review of b72f0e4).
  printf '# Autodream\n\n## Activity snapshot\n- 7 sessions\n' > "$root/2026-02-05.md"
  printf '## Open questions for the user\n\n1. **Recurring question?** body cut off mid-' > "$root/2026-02-06.md"
  cp "$st" "$root/st.before"
  out=$(qs update "$root/2026-02-05.md")
  case "$out" in *"no open-questions marker"*) ok "a report truncated before its questions is refused as incomplete" ;; *) no "a report truncated before its questions is refused as incomplete (got: $out)" ;; esac
  if cmp -s "$st" "$root/st.before"; then ok "and does not clear the board"; else no "and does not clear the board"; fi
  qs update "$root/2026-02-06.md" >/dev/null
  if cmp -s "$st" "$root/st.before"; then ok "a report truncated after a question title is refused too"; else no "a report truncated after a question title is refused too"; fi

  # clear with a key no streak carries printed "cleared" and exited 0, so a mistyped key left
  # the streak escalating after the operator was told it was forgotten (#32).
  local krc
  out=$(qs clear deadbeef0000); krc=$?
  assert_eq "$krc" "1" "clear with an unknown key fails"
  case "$out" in *"no streak with key deadbeef0000"*) ok "and names the key it could not find" ;; *) no "and names the key it could not find (got: $out)" ;; esac
  if cmp -s "$st" "$root/st.before"; then ok "and leaves the state untouched"; else no "and leaves the state untouched"; fi
  # Keys are hex, so a key can be all digits. awk compares two numeric-looking strings as
  # numbers, so `clear 89709551468` matched the row `089709551468` and cleared the wrong
  # streak (Codex review of omp-autodream 5f7ddaa). Keys compare as strings.
  printf '#last\t2026-02-02\n089709551468\t2\t2026-02-01\t2026-02-02\tDigits only?\n' > "$root/num.tsv"
  cp "$root/num.tsv" "$root/num.before"
  AUTODREAM_QUESTION_STATE="$root/num.tsv" bash "$QS" clear 89709551468 >/dev/null 2>&1; krc=$?
  assert_eq "$krc" "1" "clear with a key that only equals a row key numerically fails"
  if cmp -s "$root/num.tsv" "$root/num.before"; then ok "and does not clear the numerically equal streak"; else no "and does not clear the numerically equal streak"; fi
  # awk -v also decodes backslash escapes, so `\060...` became `0...` and matched a real key
  # (Codex review of omp-autodream b67c2f1). A key is 12 lowercase hex characters; anything
  # else is refused before awk sees it.
  printf '#last\t2026-02-02\n080dd5de4c18\t2\t2026-02-01\t2026-02-02\tEscaped?\n' > "$root/esc.tsv"
  cp "$root/esc.tsv" "$root/esc.before"
  out=$(AUTODREAM_QUESTION_STATE="$root/esc.tsv" bash "$QS" clear '\06080dd5de4c18' 2>&1); krc=$?
  assert_eq "$krc" "1" "clear with an escaped key that decodes to a real key fails"
  case "$out" in *"not a streak key"*) ok "and says it is not a streak key" ;; *) no "and says it is not a streak key (got: $out)" ;; esac
  if cmp -s "$root/esc.tsv" "$root/esc.before"; then ok "and does not clear the streak the escape decodes to"; else no "and does not clear the streak the escape decodes to"; fi

  # clear must not claim success it did not achieve.
  chmod 500 "$root" 2>/dev/null
  out=$(AUTODREAM_QUESTION_STATE="$root/nope/state.tsv" bash "$QS" clear all 2>&1); local rc=$?
  chmod 700 "$root" 2>/dev/null
  assert_eq "$rc" "0" "clear on a missing state file is a no-op, not an error"

  rm -rf "$root"
}

test_question_streaks
test_question_streaks_reruns_and_mismatch
test_question_streaks_state_lives_with_the_install

# ---- L2 attempt diagnostics (issue 42): a signal-shaped L2 death leaves evidence ----
# Exit 143 on the aggregator was seen on 2026-08-01, 08-31, 09-02, 09-04, 09-19 and 10-02 with
# nothing in the log to say who sent the TERM. A 143, 137 or 124 now writes
# findings/<date>/l2-attempt-N.diag. The probes must never fail or stall the run.
diag_of(){ printf '%s' "$(fdir "$1")/l2-attempt-$2.diag"; }
diag_litter(){ ls "$(fdir "$1")" 2>/dev/null | grep -c 'l2-attempt' || true; }

test_l2_diag_written_on_exit_143(){
  echo "# L2 diag: an attempt that exits 143 writes l2-attempt-N.diag for every attempt"
  local root; root=$(setup_env); mk_session "$root" s1
  export MOCK_MODE=l2_exit143 AUTODREAM_L2_ATTEMPTS=2
  run_dream "$root"
  unset MOCK_MODE AUTODREAM_L2_ATTEMPTS
  local d1; d1=$(diag_of "$root" 1)
  assert_file "$d1" "attempt 1 left a diag file"
  assert_file "$(diag_of "$root" 2)" "attempt 2 left its own diag file"
  assert_grep "$d1" '^exit_code: 143$' "the diag records exit 143"
  assert_grep "$d1" '^attempt: 1/2$' "the diag names the attempt"
  assert_grep "$d1" '^start_epoch: [0-9][0-9]*$' "the diag records the start time"
  assert_grep "$d1" '^end_epoch: [0-9][0-9]*$' "the diag records the end time"
  assert_grep "$d1" '^elapsed_seconds: [0-9][0-9]*$' "the diag records the elapsed time"
  assert_grep "$d1" '^runner_timeout_fired: no' "the diag says the runner applied no timeout"
  assert_grep "$d1" '^runner_survived: yes' "the diag notes the runner outlived the attempt"
  assert_grep "$d1" '^worker_pid: [0-9][0-9]*$' "the diag records the worker pid"
  assert_grep "$d1" '^runner_pid: [0-9][0-9]*$' "the diag records the runner pid"
  assert_grep "$d1" '^## parent chain at start' "the diag has the parent chain"
  assert_grep "$d1" "run.sh" "the parent chain names the runner's command line"
  assert_grep "$d1" '^launchd_label:' "the diag records the launchd label slot"
  assert_grep "$d1" '^## load average at start' "the diag has load at start"
  assert_grep "$d1" '^## load average at end' "the diag has load at end"
  assert_grep "$d1" '^## memory pressure at start' "the diag has memory pressure at start"
  assert_grep "$d1" '^## memory pressure at end' "the diag has memory pressure at end"
  assert_grep "$d1" '^## sleep and wake times' "the diag has the kernel sleep and wake times"
  assert_grep "$d1" '^## other autodream or claude processes at end' "the diag lists other autodream or claude processes"
  assert_grep "$root/run.out" "L2 done in" "the run reached its normal L2 summary"
  assert_eq "$(ls "$(fdir "$root")" | grep -c 'l2-attempt.*start' || true)" "0" "no start snapshot is left beside the diag"
  rm -rf "$root"
}

test_l2_diag_written_on_exit_137(){
  echo "# L2 diag: exit 137 (SIGKILL) is recorded too"
  local root; root=$(setup_env); mk_session "$root" s1
  export MOCK_MODE=l2_exit137 AUTODREAM_L2_ATTEMPTS=1
  run_dream "$root"
  unset MOCK_MODE AUTODREAM_L2_ATTEMPTS
  assert_grep "$(diag_of "$root" 1)" '^exit_code: 137$' "the diag records exit 137"
  rm -rf "$root"
}

test_l2_diag_absent_on_other_outcomes(){
  echo "# L2 diag: a good attempt and a plain failure (exit 1) write no diag"
  local root; root=$(setup_env); mk_session "$root" s1
  run_dream "$root"
  assert_no_file "$(diag_of "$root" 1)" "a delivered report leaves no diag"
  assert_eq "$(diag_litter "$root")" "0" "and no leftover start snapshot"
  rm -rf "$root"
  root=$(setup_env); mk_session "$root" s1
  export MOCK_MODE=l2_fail AUTODREAM_L2_ATTEMPTS=1
  run_dream "$root"
  unset MOCK_MODE AUTODREAM_L2_ATTEMPTS
  assert_no_file "$(diag_of "$root" 1)" "exit 1 is not a signal death and leaves no diag"
  assert_eq "$(diag_litter "$root")" "0" "and no leftover start snapshot"
  rm -rf "$root"
}

test_l2_diag_probes_never_fail_or_stall_the_run(){
  echo "# L2 diag: broken and hanging probes cannot fail the run or hold it"
  local root; root=$(setup_env); mk_session "$root" s1
  mkdir -p "$root/shim-diag"
  # launchctl hangs, the rest fail outright. AUTODREAM_LAUNCHD_LABEL makes the label non-empty so the
  # per-label launchctl probe runs too (macOS resets XPC_SERVICE_NAME to 0 in a child).
  printf '#!/bin/bash\nexec sleep 60\n' > "$root/shim-diag/launchctl"
  for c in ps uptime vm_stat sysctl pmset; do printf '#!/bin/bash\nexit 1\n' > "$root/shim-diag/$c"; done
  chmod +x "$root/shim-diag"/*
  local t0 t1; t0=$(date +%s)
  export MOCK_MODE=l2_exit143 AUTODREAM_L2_ATTEMPTS=1 AUTODREAM_LAUNCHD_LABEL=com.example.autodream
  PATH="$root/shim-diag:$PATH" run_dream "$root"
  unset MOCK_MODE AUTODREAM_L2_ATTEMPTS AUTODREAM_LAUNCHD_LABEL
  t1=$(date +%s)
  assert_file "$(diag_of "$root" 1)" "the diag is still written with every probe broken"
  assert_grep "$(diag_of "$root" 1)" '^exit_code: 143$' "and its own fields stand"
  assert_grep "$(diag_of "$root" 1)" 'abandoned' "the hung probe is named as abandoned in the diag"
  assert_grep "$(diag_of "$root" 1)" '^launchd_label: com.example.autodream$' "the label override reaches the diag"
  assert_grep "$root/run.out" "L2 done in" "the run completed"
  [ $((t1 - t0)) -lt 40 ] && ok "a hung launchctl was bounded (run took $((t1 - t0))s)" || no "a hung launchctl held the run for $((t1 - t0))s"
  rm -rf "$root"
}

test_l2_diag_long_command_lines_keep_the_sections_intact(){
  echo "# L2 diag: a huge parent command line cannot swallow the next section's heading"
  local root; root=$(setup_env); mk_session "$root" s1
  mkdir -p "$root/shim-diag"
  # A real claude launch carries a very long argv. The shim answers every ps with one 9000-byte
  # line and no trailing newline.
  printf '#!/bin/bash\nhead -c 9000 /dev/zero | tr "\\0" x\n' > "$root/shim-diag/ps"
  chmod +x "$root/shim-diag/ps"
  export MOCK_MODE=l2_exit143 AUTODREAM_L2_ATTEMPTS=1
  PATH="$root/shim-diag:$PATH" run_dream "$root"
  unset MOCK_MODE AUTODREAM_L2_ATTEMPTS
  assert_grep "$(diag_of "$root" 1)" '^## load average at start' "the heading after the parent chain starts its own line"
  assert_grep "$(diag_of "$root" 1)" '^## other autodream or claude processes at end' "and so does the last section"
  rm -rf "$root"
}

test_prune_worktrees_wiring(){
  echo "# prune: run.sh calls the helper only when roots are set, records the summary, and survives a failing helper"
  local keep; keep=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")   # outlives the per-run roots below
  local stub="$keep/prune-stub.sh" calls="$keep/prune-calls" root
  printf '#!/bin/bash\necho "$1" >> "%s"\necho "prune: removed=2 kept=1 skipped=0"\n' "$calls" > "$stub"
  chmod +x "$stub"
  export AUTODREAM_PRUNE_BIN="$stub"

  root=$(setup_env); mk_session "$root" s1
  run_dream "$root"
  assert_no_file "$calls" "roots unset: the helper is not called"
  assert_grep "$(fdir "$root")/run-stats.txt" "worktree_prune: prune: not configured" "roots unset: run-stats says not configured"
  rm -rf "$root"

  root=$(setup_env); mk_session "$root" s1
  export AUTODREAM_PRUNE_ROOTS="$root/repos"
  run_dream "$root"
  assert_grep "$calls" "findings/$DATE" "roots set: the helper gets the findings dir"
  assert_grep "$(fdir "$root")/run-stats.txt" "worktree_prune: prune: removed=2 kept=1 skipped=0" "roots set: run-stats carries the summary"
  rm -rf "$root"

  root=$(setup_env); mk_session "$root" s1
  printf '#!/bin/bash\nexit 1\n' > "$stub"
  run_dream "$root"
  assert_nonempty "$root/dreams/$DATE.md" "a failing helper does not cost the report"
  assert_grep "$(fdir "$root")/run-stats.txt" "worktree_prune: prune: failed" "a failing helper is recorded as failed"
  unset AUTODREAM_PRUNE_BIN AUTODREAM_PRUNE_ROOTS
  rm -rf "$root" "$keep"
}

test_prune_worktrees_wiring
test_l2_diag_written_on_exit_143
test_l2_diag_written_on_exit_137
test_l2_diag_long_command_lines_keep_the_sections_intact
test_l2_diag_absent_on_other_outcomes
test_l2_diag_probes_never_fail_or_stall_the_run

echo
echo "----------------------------------------"
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
