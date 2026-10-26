---
name: autodream
description: Run an autodream now and triage the open questions earlier dreams left unanswered. Use when the user types /autodream, asks to force a dream, or asks what autodream issues are still open.
---

# autodream

Start a dream, then work through the open questions that earlier dreams raised and nobody answered.

`AUTODREAM_DIR` is the install dir (default `~/.claude/autodream`). Every script below lives there.

## Steps

1. Print the state of the queue. The first line of your reply is the output of this command, verbatim:

   ```bash
   "${AUTODREAM_DIR:-$HOME/.claude/autodream}/pending-triage.sh" --summary
   ```

   It prints either `now triaging N issues from dates A to B` or `no issues to address!`.

2. Start a dream in the background, so the newest report is on its way while you triage. It returns at once because launchd owns the run.

   - `/autodream` runs yesterday's dream. A finished report makes this a no-op.
   - `/autodream today` runs today so far and rebuilds it: `autodream-now.sh "$(date +%Y-%m-%d)" --force`.
   - `/autodream force` rebuilds yesterday: `autodream-now.sh --force`.

   ```bash
   "${AUTODREAM_DIR:-$HOME/.claude/autodream}/autodream-now.sh"
   ```

   Do not wait for it. Say in one line that a dream is running and where its report will land (`dreams/<date>.md`).

   `autodream-now.sh` hands the run to launchd, so it only works on macOS. Elsewhere, skip this step and say so. When you passed `force` or `today`, the report for that date is being rebuilt: leave that date out of the walk below and say it will show up on the next `/autodream`.

3. If step 1 said `no issues to address!`, stop here.

4. Otherwise recommend a yolo session in one sentence, then carry on without waiting for an answer. Triage executes the fixes you approve, so permission prompts interrupt every question. A session started with `claude --dangerously-skip-permissions` walks the queue without them. Skip the recommendation when this session already runs in bypass mode.

5. List the pending reports, oldest first:

   ```bash
   "${AUTODREAM_DIR:-$HOME/.claude/autodream}/pending-triage.sh" --list
   ```

   Each line is `date`, tab, open-question count, tab, report path. A count of `?` means the report does not say how many questions it holds: read its Open questions section and count them yourself. Read one report at a time and keep it out of the reply.

6. Walk its open questions, one per turn:

   1. Restate ONE open question in full before asking for any decision. The user has not read the report, so a bare label ("now question 2") is never enough. Carry (a) the question in plain words, (b) every motivation behind it: findings, session counts, evidence quotes and report section numbers, and (c) every potential fix, each with its trade-off.
   2. Say what you checked since the report was written, or could not check.
   3. Recommend one concrete action from (c). Be opinionated.
   4. Wait for approve, modify, skip or discuss.
   5. If approved, execute it. If modified, incorporate the change, confirm, then execute. If skipped or discussed, log the decision as one line.
   6. Log every decision as one bullet line (starting with `- `) under a `## Triage in progress` heading at the bottom of that report (create it if absent). Questions already logged there are done: skip them when you resume a report.

7. When the last question of a report is resolved, rename its heading to `## Triage decisions` and add a short summary under it. That heading is what marks a report as addressed, so never write it earlier: a session that stops half way would hide the questions still open. Then move to the next date. When the last one is done, say `all caught up`.

## Rules

- A fix belongs to the repository or file the question is about, which is often not the project this session is in. Work out the target from the question, run the fix there, and do not change the current project for another project's question. When you cannot reach the target, show the fix and say where to apply it.
- Edits to `~/.claude/CLAUDE.md`, `~/.claude/rules/*`, `~/.claude/docs/guardrails/*` and any other global file need the user's explicit per-edit approval.
- Be terse everywhere except the question restatement, which is always complete.
- The newest dream may finish while you triage. Run `--summary` again at the end and say so if it added questions.
