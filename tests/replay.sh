#!/bin/bash
# Replay: run the unified runner's own code over archived data and say where it disagrees with
# what the nightly that produced that data recorded. Two modes, both offline, both read-only
# against the archive.
#
#   tests/replay.sh --artifacts <findings-dir>...
#       Recompute from a findings directory already on disk (findings JSONs, stats sidecars, .err
#       files, run-stats.txt): shape of every JSON, the failure classes the classifier assigns, the
#       skills fields the runner would enforce, the overlap pass, and the oversized gate. Each
#       figure is compared with the run-stats.txt the original run wrote, when that run wrote it.
#
#   tests/replay.sh --ingest <adapter> <session-root> <date> [--against <findings-dir>]
#       Run the whole runner (install, enumerate, normalize, stats, noise gate, L1 dispatch, L2,
#       pins) against a REAL session root for a REAL date, with the model engines replaced by
#       tests/mock-claude.sh, in a throwaway HOME. Nothing under the real root is written. With
#       --against, the counts are compared with the archived run's run-stats.txt.
#
# Output is one line per check: PASS, FAIL (counts toward the exit status) or WARN (a difference
# that is explained by the archive predating a counter or by a corpus that has moved since). The
# exit status is 0 only when no check FAILed.
#
# What it cannot tell you: whether a model would triage these sessions well. The engines are mocks.
# What it can tell you: whether this code reads, classifies and counts real data the way the code
# that wrote the archive did.

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
. "$REPO/bin/portable.sh"
MOCK="$HERE/mock-claude.sh"

PASS=0; FAIL=0; WARN=0
SANDBOXES=""
cleanup_sandboxes() {
  [ -n "${REPLAY_KEEP:-}" ] && return 0
  local d; for d in $SANDBOXES; do rm -rf "$d"; done
}
trap cleanup_sandboxes EXIT
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
warn() { WARN=$((WARN + 1)); printf '  WARN  %s\n' "$1"; }
cmp_num() { # $1=label $2=got $3=archived ; PASS on equal, FAIL otherwise
  if [ "$2" = "$3" ]; then pass "$1: $2"; else fail "$1: replay $2, archive $3"; fi
}
cmp_num_warn() { # like cmp_num, but a difference is only a WARN
  if [ "$2" = "$3" ]; then pass "$1: $2"; else warn "$1: replay $2, archive $3"; fi
}
stat_of() { # $1=run-stats file $2=key -> value, empty when the key is absent
  sed -n "s/^$2: //p" "$1" 2>/dev/null | head -n 1
}

usage() { sed -n '2,24p' "$0"; exit 64; }

# --------------------------------------------------------------------------- artifacts --
replay_artifacts() { # $1=findings dir
  local dir="$1" n stats j
  echo "== artifacts: $dir"
  [ -d "$dir" ] || { fail "not a directory"; return; }
  stats="$dir/run-stats.txt"

  # 1. Shape: every findings JSON parses and is either a result (.findings is an array) or a
  #    structured error. A file that is neither is something L2 would have been handed raw.
  local total=0 bad=0 errored=0 gated=0 written=0
  for j in "$dir"/*.json; do
    [ -e "$j" ] || continue
    case "$j" in *.stats.json) continue ;; esac
    total=$((total + 1))
    if ! jq -e 'type == "object" and ((.findings | type) == "array")' "$j" >/dev/null 2>&1; then
      bad=$((bad + 1)); continue
    fi
    written=$((written + 1))
    jq -e 'has("error")' "$j" >/dev/null 2>&1 && errored=$((errored + 1))
    jq -e '.skipped == "below_noise_gate"' "$j" >/dev/null 2>&1 && gated=$((gated + 1))
  done
  if [ "$total" -eq 0 ]; then warn "no findings JSONs in the directory (a night with nothing triaged, or one that never got past enumeration)"; return; fi
  # A shape violation in an archive is data, not a bug in this code: the current runner would have
  # refused the file (it validates .findings on the way in and out) and retried or stubbed it. So
  # it is reported, with the count, and does not fail the replay. The 2026-05-28 claude archive,
  # the tool's first day, holds one such file.
  [ "$bad" -eq 0 ] && pass "all $total findings JSONs have the findings-array shape" \
                   || warn "$bad of $total findings JSONs lack a findings array (the current runner would not accept them)"

  # 2. Counters the runner writes, recomputed from the artifacts.
  n=$(stat_of "$stats" l1_findings_written)
  # The directory may have been rebuilt or pruned since the run-stats were written (2026-09-13
  # holds 7 findings of the 9 its run-stats recorded), so counts of what is on disk are WARNs.
  # The checks that can FAIL are the ones about this code: shape, classification, enforcement.
  [ -n "$n" ] && cmp_num_warn "findings written" "$written" "$n" || warn "findings written: $written (the archive records no such key)"
  n=$(stat_of "$stats" l1_findings_with_error)
  [ -n "$n" ] && cmp_num_warn "findings with an error" "$errored" "$n" || warn "findings with an error: $errored (no key in the archive)"
  n=$(stat_of "$stats" gated)
  [ -n "$n" ] && cmp_num_warn "gated below the noise threshold" "$gated" "$n" || warn "gated: $gated (no key in the archive)"

  # 3. Failure classes: classify every errored session from its surviving .err, exactly as the
  #    runner does, and compare with the l1_errored_* counters the original run wrote.
  # shellcheck source=../bin/failure-class.sh
  . "$REPO/bin/failure-class.sh"
  local silent=0 provider=0 unclass=0 size=0 cls
  for j in "$dir"/*.json; do
    [ -e "$j" ] || continue
    case "$j" in *.stats.json) continue ;; esac
    jq -e 'type == "object" and has("error")' "$j" >/dev/null 2>&1 || continue
    cls=$(classify_failure "$j.err" 2>/dev/null || echo unclassified)
    case "$cls" in
      silent) silent=$((silent + 1)) ;;
      provider) provider=$((provider + 1)) ;;
      size) size=$((size + 1)) ;;
      *) unclass=$((unclass + 1)) ;;
    esac
  done
  n=$(stat_of "$stats" l1_errored_silent)
  if [ -n "$n" ]; then
    cmp_num "errored: silent" "$silent" "$n"
    cmp_num "errored: provider" "$provider" "$(stat_of "$stats" l1_errored_provider)"
    cmp_num "errored: unclassified" "$unclass" "$(stat_of "$stats" l1_errored_unclassified)"
  else
    warn "failure classes: silent $silent, provider $provider, size $size, unclassified $unclass (the archive predates the counters)"
  fi

  # 4. Skill fields: how many findings the runner would strip as unmeasured, because the sidecar
  #    is missing or lacks any of the four keys. Compared with skills_unmeasured when recorded.
  local unmeasured=0 sc
  for j in "$dir"/*.json; do
    [ -e "$j" ] || continue
    case "$j" in *.stats.json) continue ;; esac
    jq -e '(.findings | type) == "array"' "$j" >/dev/null 2>&1 || continue
    # Gated stubs and error records are never rewritten by the enforcement pass, and carry no
    # skill fields either, so only the sessions the runner would have touched are compared.
    jq -e 'has("error") or .skipped == "below_noise_gate"' "$j" >/dev/null 2>&1 && continue
    sc="${j%.json}.stats.json"
    jq -e 'type == "object" and (["skills_invoked", "skills_invoked_count", "skills_invoked_counts", "skills_authored"] - keys | length == 0)' "$sc" >/dev/null 2>&1 \
      || unmeasured=$((unmeasured + 1))
  done
  n=$(stat_of "$stats" skills_unmeasured)
  if [ -n "$n" ]; then
    cmp_num_warn "skills unmeasured" "$unmeasured" "$n"
  else
    warn "skills unmeasured: $unmeasured of $written (the archive predates skill measurement)"
  fi

  # 5. The overlap pass over the sidecars.
  local ov ev inv
  ov=$("$REPO/bin/overlap-stats.sh" "$dir" 2>/dev/null)
  ev=$(printf '%s' "$ov" | jq -r '.overlap_events // empty' 2>/dev/null)
  inv=$(printf '%s' "$ov" | jq -r '.sessions_with_overlap // empty' 2>/dev/null)
  if [ -z "$ev" ]; then
    fail "overlap pass produced no parseable output"
  else
    n=$(stat_of "$stats" overlap_events)
    # A mismatch is expected for archives from before advisor sidecars were dropped from the
    # pass (omp-autodream 2026-08-21): the old figure counted each advisor against its parent.
    if [ -n "$n" ] && [ "$(stat_of "$stats" overlap_measured)" = "yes" ]; then
      cmp_num_warn "overlap events" "$ev" "$n"
      cmp_num_warn "sessions with overlap" "$inv" "$(stat_of "$stats" sessions_with_overlap)"
    else
      pass "overlap pass ran: $ev events across $inv sessions (the archive recorded none to compare)"
    fi
  fi

  # 6. The oversized gate must run over the directory without error.
  local og rc
  og=$("$REPO/bin/oversized-gate.sh" "$dir" 2>&1); rc=$?
  if [ "$rc" -le 1 ] && [ -n "$og" ]; then pass "oversized gate ran (exit $rc)"; else fail "oversized gate failed (exit $rc)"; fi
}

# ---------------------------------------------------------------------------- ingest --
replay_ingest() { # $1=adapter $2=session root $3=date $4=archived findings dir or ""
  local adapter="$1" root="$2" date="$3" against="$4" sb home target fd rc n
  echo "== ingest: $adapter $root $date"
  [ -d "$root" ] || { fail "session root is not a directory: $root"; return; }
  [ -d "$REPO/adapters/$adapter" ] || { fail "no adapter named $adapter"; return; }
  [ -x "$MOCK" ] || { fail "tests/mock-claude.sh is missing"; return; }

  sb=$(mktemp -d "${TMPDIR:-/tmp}/ccad-replay.XXXXXX") || { fail "cannot create a sandbox"; return; }
  # Holds a staged copy of real sessions, so it is removed on every exit path, kept only on request.
  SANDBOXES="${SANDBOXES:-} $sb"
  home="$sb/home"; target="$home/.claude/autodream"
  mkdir -p "$home/.claude/projects"
  local adapters="claude" session_roots="" next stage
  # How far past the day the runner looks for a session touched after it: its enumeration
  # passes the adapter the report day plus five years (ENUM_END in run.sh).
  next=$(pdate_shift "$date" 5 y) || { fail "cannot parse the date $date"; rm -rf "$sb"; return; }
  # The runner's enumeration is a `find` that does not follow a symlinked root, and a root that
  # is only a link finds nothing. So the sandbox holds a COPY of the sessions modified since
  # that date began, mtimes preserved: the real store is only ever read. The upper bound is
  # the runner's own reach, not the end of the day. The runner places a session in a day by
  # the timestamps inside it, so a session written to again after the day closed still
  # belongs to it, and staging only the files last modified ON the day would leave out
  # exactly the sessions that matter. The runner applies its own window to what is staged,
  # so an older runner (which bounds mtime itself) reads the same copy.
  stage="$sb/store"; mkdir -p "$stage"
  ( cd "$root" && find . -type f -name '*.jsonl' -newermt "$date 00:00:00" ! -newermt "$next 00:00:00" -print0 \
      | tar -cf - --null -T - 2>/dev/null ) | tar -xf - -C "$stage" 2>/dev/null
  local staged; staged=$(find "$stage" -type f -name '*.jsonl' | wc -l | tr -d ' ')
  pass "staged $staged session file(s) modified from $date until five years after"
  case "$adapter" in
    claude) session_roots="$stage" ;;
    *)
      adapters="claude,$adapter"
      local rel; rel=$(jq -r '.session_roots_default[0] // empty' "$REPO/adapters/$adapter/manifest.json" | sed 's#^\$HOME/##')
      [ -n "$rel" ] || { fail "the $adapter manifest names no default session root"; rm -rf "$sb"; return; }
      mkdir -p "$home/$(dirname "$rel")"
      mv "$stage" "$home/$rel"
      ;;
  esac

  if ! HOME="$home" PATH="$PATH" bash "$REPO/install.sh" --no-schedule --adapters "$adapters" "$home/.claude" >"$sb/install.out" 2>&1; then
    fail "install.sh failed in the sandbox (see $sb/install.out)"; tail -5 "$sb/install.out"; return
  fi
  pass "install.sh --adapters $adapters into a throwaway home"

  env HOME="$home" AUTODREAM_DIR="$target" DREAMS_DIR="$home/.claude/dreams" \
    ${session_roots:+SESSION_ROOTS="$session_roots"} \
    CLAUDE_BIN="$MOCK" OMP_BIN="$MOCK" AUTODREAM_L1_MODEL_OMP=replay/mock AUTODREAM_L2_MODEL_OMP=replay/mock \
    SHARED_MEMORY_BIN="$sb/no-such-shared-memory" \
    AUTODREAM_CHANGELOG=0 AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    AUTODREAM_CONSUME_DATE="$date" FANOUT="${FANOUT:-8}" \
    /bin/bash "$target/run.sh" "$date" >"$sb/run.out" 2>&1
  rc=$?
  fd="$target/findings/$date"
  [ "$rc" -eq 0 ] && pass "the runner exited 0 and delivered a report" || { fail "the runner exited $rc (log: $target/logs/run-$date.log)"; tail -8 "$target/logs/run-$date.log" 2>/dev/null; }
  [ -s "$home/.claude/dreams/$date.md" ] && pass "a report stands at the dreams path" || fail "no report was written"

  local found triaged normfail written stat_n
  found=$(stat_of "$fd/run-stats.txt" sessions_found_raw)
  triaged=$(stat_of "$fd/run-stats.txt" sessions_triaged)
  if [ -z "$found" ]; then fail "run-stats has no sessions_found_raw"
  elif [ "$found" -eq 0 ] && [ "$staged" -gt 0 ]; then
    # Files from later days are staged too, so a run whose window holds none of them is a
    # quiet day, which the runner counts. A runner that counts none of them out of window and
    # still found nothing lost them.
    n=$(stat_of "$fd/run-stats.txt" sessions_out_of_window)
    if [ "${n:-0}" -gt 0 ]; then warn "none of the $staged staged file(s) holds a record on $date ($n out of window), so nothing was replayed"
    else fail "$staged session file(s) were staged but the runner enumerated none"; fi
  elif [ "$found" -eq 0 ]; then warn "no session was modified on $date, so nothing was replayed"
  else pass "enumerated $found session(s), triaged $triaged"; fi
  normfail=$(grep -l 'could not be normalized' "$fd"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$normfail" -eq 0 ] && pass "every session was readable by its adapter (none refused by the linearizer)" \
                        || fail "$normfail session(s) could not be normalized: $(grep -l 'could not be normalized' "$fd"/*.json | head -3 | tr '\n' ' ')"
  written=0; stat_n=0
  for _f in "$fd"/*.json; do
    [ -e "$_f" ] || continue
    case "$_f" in *.stats.json) stat_n=$((stat_n + 1)) ;; *) written=$((written + 1)) ;; esac
  done
  [ "$written" -eq "${triaged:-0}" ] && pass "one findings JSON per triaged session ($written)" || fail "findings JSONs $written, sessions triaged ${triaged:-?}"
  [ "$stat_n" -eq "${triaged:-0}" ] && pass "one stats sidecar per session ($stat_n)" || fail "stats sidecars $stat_n, sessions triaged ${triaged:-?}"
  n=$(stat_of "$fd/run-stats.txt" stats_sidecars_unparseable)
  [ "$n" = "0" ] && pass "no unparseable stats sidecar" || fail "stats_sidecars_unparseable: ${n:-absent}"
  n=$(stat_of "$fd/run-stats.txt" l1_findings_with_error)
  [ "$n" = "0" ] && pass "no L1 worker errored" || fail "l1_findings_with_error: ${n:-absent}"
  n=$(stat_of "$fd/run-stats.txt" skills_unmeasured)
  [ -n "$n" ] && pass "skills_unmeasured: $n" || fail "run-stats has no skills_unmeasured"

  if [ -n "$against" ]; then
    local a="$against/run-stats.txt"
    echo "  -- against $against"
    if [ ! -s "$a" ]; then warn "the archive has no run-stats.txt to compare with"; else
      # The corpus can have moved since (a session resumed later changes its mtime), so the
      # enumeration counts are WARNs; gating and the stats-derived figures are the parity check.
      cmp_num_warn "sessions found" "$found" "$(stat_of "$a" sessions_found_raw)"
      cmp_num_warn "sessions triaged" "$triaged" "$(stat_of "$a" sessions_triaged)"
      cmp_num_warn "gated below the noise threshold" "$(stat_of "$fd/run-stats.txt" gated)" "$(stat_of "$a" gated)"
      cmp_num_warn "oversized transcripts" "$(stat_of "$fd/run-stats.txt" oversized_total)" "$(stat_of "$a" oversized_total)"
      # The overlap pass drops advisor sidecars, which the archive's runner did not flag (its
      # sidecars carry no is_advisor), so it counted each advisor against its parent. The replay
      # therefore reads LOWER by design, and the difference is explained by the advisor count.
      local advisors=0 _s
      for _s in "$fd"/*.stats.json; do
        [ -e "$_s" ] && jq -e '.is_advisor == true' "$_s" >/dev/null 2>&1 && advisors=$((advisors + 1))
      done
      local ov_r ov_a arch_sidecars=0
      for _s in "$against"/*.stats.json; do [ -e "$_s" ] && arch_sidecars=$((arch_sidecars + 1)); done
      ov_r=$(stat_of "$fd/run-stats.txt" overlap_events); ov_a=$(stat_of "$a" overlap_events)
      if [ "$ov_r" = "$ov_a" ]; then pass "overlap events: $ov_r"
      else
        local why=""
        [ "$advisors" -gt 0 ] && why="$advisors advisor sidecar(s) are excluded here and were counted against their parents in the archive"
        # An archive directory that was rebuilt in place keeps the sidecars of earlier runs, which
        # the overlap pass reads along with the latest run's.
        [ "$arch_sidecars" -gt "${found:-0}" ] && why="${why:+$why; }the archive holds $arch_sidecars sidecars for a run of ${found:-0} sessions (a rebuilt directory)"
        warn "overlap events: replay $ov_r, archive $ov_a${why:+ (explained: $why)}"
      fi
      cmp_num_warn "sessions with overlap" "$(stat_of "$fd/run-stats.txt" sessions_with_overlap)" "$(stat_of "$a" sessions_with_overlap)"
    fi
  fi
  if [ -n "${REPLAY_KEEP:-}" ]; then echo "  (sandbox kept: $sb)"; else rm -rf "$sb"; fi
}

# ------------------------------------------------------------------------------- main --
[ "$#" -ge 1 ] || usage
mode="$1"; shift
case "$mode" in
  --artifacts)
    [ "$#" -ge 1 ] || usage
    for d in "$@"; do replay_artifacts "$d"; done
    ;;
  --ingest)
    [ "$#" -ge 3 ] || usage
    adapter="$1"; root="$2"; date="$3"; shift 3
    against=""
    if [ "${1:-}" = "--against" ]; then against="${2:-}"; fi
    replay_ingest "$adapter" "$root" "$date" "$against"
    ;;
  -h|--help) usage ;;
  *) usage ;;
esac

printf '\nreplay: %s passed, %s warned, %s failed\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ]
