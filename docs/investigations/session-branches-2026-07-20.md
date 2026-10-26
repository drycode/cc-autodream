# Session branches investigation — 2026-07-20

Spike for issue #13. Decision doc only, no code changes.

## Question

Do resumed/forked Claude Code sessions in `~/.claude/projects/*/` produce overlapping
transcript files within a single day's window that autodream double-counts?

## Method

1. Enumerated real (non-subagent) transcripts from the last 7 days:
   `find ~/.claude/projects -name '*.jsonl' -mtime -7 | grep -v '/subagents/'` → **103 files**
   across 17 project directories, 10 of which had more than one file in the window
   (max 41, in `cc-autodream` itself).
2. For every within-project-directory pair (cross-project pairs can't be forks —
   **1099 pairs** across the 10 multi-file groups), computed common-prefix overlap
   two ways:
   - **Strict**: parse each line as JSON, strip only the per-file `sessionId` field
     (the one field that legitimately differs between a session and its fork/resume
     of the same content), then compare lines for exact equality from the top down.
     `pct = common_prefix_lines / min(lines_a, lines_b) * 100`.
   - **Loose (sanity check)**: same idea but reduced to just `(type, message.content)`
     for `user`/`assistant` lines only, ignoring `uuid`/`parentUuid`/`timestamp` — in
     case a fork regenerates message uuids and the strict check would miss it.
3. Checked whether any candidate pair shares a `sessionId` value inside the JSONL
   lines themselves (as opposed to matching on the file's own id).
4. Checked all 103 files for `type: bridge-session` / any `forkSessionId` /
   `originalSessionId` / `parentSessionId` / `resumeSessionId` field — none exist in
   the schema; the only related field is `bridgeSessionId` (Claude Code's cloud
   session-bridge feature, unrelated to file-level forking).
5. Measured timestamp span (first vs. last `timestamp` field) for all 103 sampled
   files, to separately size the multi-day-resume case.

## Findings

**Prefix overlap: zero pairs, both methods, at any threshold down to 10%.**
Strict (sessionId-stripped, full-line) comparison: **0 of 1099** within-project pairs
had >10% of the shorter file's lines as a common prefix; **0** matched at the >80%
threshold specified in the task. The loose content-only check found **10** pairs
above 5%, but every one of them was a false positive from shared boilerplate: tiny
2–3-message sessions that only ran `/clear` and then stopped, matching the identical
`<local-command-caveat>` + `/clear` preamble that *any* session opening with `/clear`
produces — not shared conversation history with a real session. No pair in the
loose check corresponded to a genuine fork/resume relationship.

**Session-id sharing: not applicable.** No pairs cleared the >10% overlap bar in the
strict check, so the "do candidate pairs share a `sessionId` field" check (step 3)
had no candidates to test. Separately, no transcript in the sample contains a
`sessionId` value inside its lines other than its own filename's id — consistent
with the spec's expectation that `--resume` appends to the same file/id rather than
producing a second file.

**Multi-day spans: common.** 12 of 103 files (11.7%) span more than 24 hours from
first to last timestamped line — the longest is 1158 hours (`91ecdfb5…jsonl`, a
personal-finance project touched sporadically over ~48 days via repeated
`--resume`). These are all single files with one session id; they are long-lived
*resumed* sessions, not duplicates. They matter for the deferred `active_minutes`
metric (a naive first-to-last-timestamp duration would wildly overstate active time
for these) but are orthogonal to the double-counting question this spike answers.

**No fork-lineage field exists in the schema.** Confirmed by field grep across all
103 files: no `forkSessionId`/`originalSessionId`/`parentSessionId`/
`resumeSessionId`. `bridge-session` lines (`bridgeSessionId: "cse_…"`) are Claude
Code's mobile/cloud sync bridge, unrelated to on-disk file forking. This validates
the spec's assumption that any join, if one were needed, has to be content-based —
there is no cheap id-based shortcut.

## The still-growing-at-scan-time hazard

The proposed dedup shape (from the spec) is: find overlapping pairs, keep the
longer file, drop the shorter as a duplicate branch. If autodream's nightly scan
runs while a session is still actively being appended to, "longer at scan time"
is not the same as "the branch the user kept using." A user could abandon branch A
(now static, arbitrarily long) and be actively extending branch B (short at scan
time, growing) — length-based dedup would keep the abandoned branch and silently
drop the live one's findings for that day. Because L1 triage runs once per day per
file, a wrongly-dropped session's insights for that day are gone, not deferred —
there's no later day where they get picked up as "missed." This is a silent,
hard-to-detect data-loss mode, and it would only ever trigger on the exact case
(active concurrent branch pair) that this investigation found zero evidence of.

## Recommendation: don't dedup

No implementation. The empirical base rate in a representative 7-day, 103-file,
1099-pair sample is **zero** overlapping transcript pairs, using a comparison
method specifically built to survive the one field (`sessionId`) that's expected to
legitimately differ across a fork. The cost-benefit is asymmetric:

- **Cost of not deduping**: if a fork/duplicate ever does occur, its shared
  conversation prefix gets triaged twice by L1 (haiku, cheap, one findings JSON
  each) and the same insight may appear twice in one day's report — an annoyance,
  not a correctness bug.
- **Cost of deduping wrong**: a still-growing-branch race (above) can silently
  drop an entire session's findings for a day, with no signal that it happened.

Building and maintaining prefix-overlap detection to solve a problem with zero
observed instances, when the failure mode of getting it wrong is worse than the
problem it solves, isn't justified. **No follow-up implementation issue is
needed.** If this changes — e.g. someone starts using `claude --fork-session` or
equivalent heavily and a future spot-check finds real overlapping pairs — re-run
this same method (script is disposable, not checked in) against a fresh sample
before building anything.
