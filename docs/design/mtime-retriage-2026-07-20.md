# Design doc: mtime-aware re-triage vs. the idempotency guard

Issue: [strml/cc-autodream#16](https://github.com/STRML/cc-autodream/issues/16). Design-doc-only
deliverable — no implementation here.

## Problem

Findings are keyed by `sha1(session_path)` inside a date-scoped directory
(`findings/<date>/<hash>.json`; hash computed at `bin/run.sh:202-203, 217, 233`). A session
active across the 03:15 catch-up boundary can keep growing after its findings JSON is written;
the issue's claim is that later launchd triggers reuse the stale snapshot instead of re-triaging.
Noise-gated stubs (`bin/run.sh:264-273`) share the exposure: `dispatch_l1` treats any output with
a `.findings` key — including the gated stub's empty `[]` — as done (`jq -e .findings`, line 241),
so a session that crosses the noise-gate threshold after being gated once is never re-evaluated.

## Constraints

- **The idempotency guard is `bin/run.sh:372-375`**:
  ```
  if [ -s "$REPORT_PATH" ] && [ "${AUTODREAM_FORCE:-0}" != "1" ]; then
    log "report already exists for $TARGET_DATE ($REPORT_PATH); nothing to do ..."
    return 0
  fi
  ```
  It fires *before* enumeration (`find` is line 379), so any date with a report short-circuits in
  well under a millisecond. The comment at lines 368-371 documents this as load-bearing for sleep
  resilience: "makes launchd catch-up/relaunch ... cheap no-ops once the night succeeded." There is
  a dedicated test for exactly this contract — `tests/run-all.sh:409-417` (`test_idempotency_guard`)
  asserts `'already exists'` is logged **and** `assert_no_file` that no L1 work happened. Any option
  that makes the guard conditional changes this test's contract, not just adds a code path.
- **Enumeration is closed-window, not live-tail.** `bin/run.sh:379-382` selects `-newermt
  "$TARGET_DATE 00:00:00" ! -newermt "$NEXT_DATE 00:00:00"` — i.e., mtime in `(TARGET_DATE 00:00,
  NEXT_DATE 00:00]`. For the default "yesterday" path (`TARGET_DATE="${1:-$(date -v-1d +%Y-%m-%d)}"`,
  line 52), that interval's upper bound is already in the past by the time the *first* trigger
  (03:15) fires. A file whose mtime is still advancing at scan time has mtime > `NEXT_DATE 00:00`
  and is **excluded** from that day's window on every subsequent re-run too — its growth doesn't
  make the window stale, it just defers the whole file to the following night's window. Genuine
  "captured once, then grew while the window was still open" staleness only arises when
  `TARGET_DATE` is *today* (an open window) — i.e. `AUTODREAM_FORCE=1`/same-day reprocessing via
  `autodream-now.sh`, not the standard overnight schedule.
- **The stats sidecar already carries `transcript_mtime`.** `bin/session-stats.sh:20-23,101-102`
  stats each `.stats.json` with the transcript's mtime at compute time. `compute_session_stats()`
  (`bin/run.sh:213-228`) runs it **once per run**, before the L1 round loop, and the comment at
  `bin/run.sh:421-422` is explicit that rounds "intentionally" reuse it — sidecars are not
  regenerated between retries.
- Measured on this host: `find ~/.claude/projects -name '*.jsonl'` over the full tree (7,200
  files) takes 0.04-0.17s; `stat -f %m` on ~65 matched files totals ~0.003s; `shasum -a 1` on the
  same set totals ~0.015s. Recent findings dirs show 63-66 findings on active nights
  (`2026-07-16`, `2026-07-17`), 0-4 on quiet ones — matches the brief's 60-70/day estimate.

## Option A — weaken the guard to "skip unless some session's mtime invalidates it"

Cost is not raw compute — a full re-enumeration + mtime-vs-sidecar compare is sub-second (measured
above) even at 4 triggers/day forever. The real cost is **structural**: it turns a documented O(1)
short-circuit into an O(files) operation on every trigger permanently, breaks the explicit
"cheap no-op" contract in `bin/run.sh:368-371` and the `test_idempotency_guard` assertion, and —
per the closed-window finding above — buys almost nothing on the path it changes. The default
"yesterday" schedule's window is always closed by the time any trigger fires, so there is no
session whose mtime can invalidate an already-closed window; the only case Option A actually helps
is same-day/`AUTODREAM_FORCE` reprocessing, a rare, already-manual path. Paying a permanent
complexity + test cost to speed up a rare manual case is a bad trade.

## Option B — restrict re-triage to a single run's rounds

Confirmed useless, matching the issue's own prediction, and for a more specific reason than "mtime
is fixed": it's fixed *by construction* today. `compute_session_stats()` runs once (`bin/run.sh:423`,
before the round loop at 453-468) and is never re-run between rounds (421-422 comment). Detecting
growth within a run would require adding a fresh `stat` per round — but even with that added, the
window is tiny: `AUTODREAM_L1_ROUNDS` defaults to 5, `AUTODREAM_RETRY_WAIT` to 60s (line 466), so a
run's total span is on the order of minutes, not the hours-later 06:15/09:15/12:15 catch-up gap the
issue describes. And catch-up triggers only run L1 at all when the *prior* run left no report — if
the first run succeeded (the guard's precondition), later triggers never re-enter the round loop
regardless of what Option B does inside it. It doesn't reach the failure mode in the issue.

## Option C — separate stale-session trigger, incremental re-aggregation

L1-side this is fine: re-dispatching only stale sessions is cheap and haiku-priced, and the
existing dedup key (`findings/<date>/<hash>.json`) already supports overwriting one session's
findings in place. L2-side "incremental" is not actually available: `prompts/PROMPT.md:18` has L2
`Glob` **every** `*.json` in the date's findings dir on every call, and line 32 says "Write to
`REPORT_PATH`. Overwrite if present (idempotent re-runs are fine)" — there is no diff/patch mode.
A stale-session trigger that wants an updated report has to pay a second **full-price** opus call
identical in shape to the nightly L2 — re-reading every findings JSON for that date and rewriting
the whole report, not just the delta. It also reopens the memory-pin path: `prompts/PROMPT.md:123`
tells the model not to rewrite an existing 📌 pin, but that's a soft instruction, not deterministic
idempotency, so a second L2 pass over an unchanged high-confidence finding risks a near-duplicate
pin. Net: Option C is buildable, but its "incremental" framing is misleading — it's a second full L2
run plus a new trigger plus a new pin-collision risk, for the same boundary sessions Option D shows
are not actually lost.

## Option D — drop the capability

Verified against the code, not just the issue's framing: findings are namespaced by
`findings/<TARGET_DATE>/<hash>.json` (`bin/run.sh:55, 234`), so the guard and the dedup key are both
scoped to *that date's* directory. A session touched again on a later calendar day gets a fresh,
empty findings dir for that later date — `dispatch_l1`'s idempotent check (`jq -e .findings` on
`$FINDINGS_DIR/$hash.json`, line 241) only ever looks inside the *current* date's dir, so the same
file is re-triaged **from scratch** (full transcript, not just the delta) whenever its mtime lands
in a later day's window. Combined with the closed-window property above, the real exposure under
the default schedule is: a session actively growing right at/after the 03:15 scan is excluded from
that day's window entirely and picked up whole the next time its file is touched — turns get
attributed to the wrong day, but every turn still gets analyzed exactly once (or, across a
day-crossing session, potentially twice for the overlapping portion — a duplicate-insight
annoyance, the same shape of cost the `#13` session-branches investigation already accepted for
fork/resume overlap, not data loss). Nothing is silently dropped.

## Recommendation: Option D

Drop the capability. The three build options each pay a real, permanent cost — a broken cheap-no-op
invariant and a failing test (A), no reach into the actual failure window (B), or a second full-price
L2 call plus a new pin-idempotency risk (C) — against a problem that, once the findings directory's
per-date keying is accounted for, is turn-misattribution, not lost analysis, and one the standard
overnight schedule mostly avoids by construction (closed enumeration window). This mirrors the
`#13` investigation's own conclusion on a structurally similar question: don't build detection and
correction machinery for a failure mode whose worst case is "an insight surfaces under the wrong
day's report" rather than "an insight never surfaces."

## Follow-up issue

None. Per Option D, no implementation follow-up is needed. If the exposure profile changes — e.g.
same-day/`AUTODREAM_FORCE` reprocessing becomes a routine (not occasional) workflow, which is the
one path where Option A's benefit would actually materialize — revisit with fresh measurements
against that specific usage pattern rather than the default nightly schedule evaluated here.
