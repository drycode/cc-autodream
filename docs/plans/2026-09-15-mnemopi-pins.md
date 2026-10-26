# Route autodream memory pins to Mnemopi

Decided in the 2026-09-15 morning triage of the 2026-09-14 report (open question 2).

## Why

Legacy Markdown memory is retired on this host. `autoMemoryEnabled` is false, `cc-simple-memory` is disabled, and the global `CLAUDE.md` calls `MEMORY.md` "a preserved migration source, not an active writer". L2 still pins into `~/.claude/projects/*/memory/MEMORY.md` and the runner still runs `claude-memory gc` over `touched-projects.txt`. A pin written there is read by nothing.

Every harness on the host (Claude Code, OMP, Codex) reads one shared Mnemopi store. That removes the per-root expansion and the per-adapter GC that `docs/design/unify-harness-adapters-2026-08-23.md` specified, and it makes #52 moot.

## Shape

L2 keeps its tools for now. It writes pins to a file, and the runner applies them. Migration step 4 of the adapter design changed only the transport, and has landed: L2 holds Glob and Read, prints the pins in an `AUTODREAM_PINS_BEGIN`/`AUTODREAM_PINS_END` block after the report sentinel, and the runner writes `pins.jsonl` from it. The line format and the runner side stay.

1. L2 writes `<findings-dir>/pins.jsonl`, one JSON object per line:

   ```
   {"project":"-Users-x-repo","title":"one line, at most 150 chars","body":"the full memory","kind":"correction"}
   ```

   `project` is the `project` value of a findings JSON from this run. `kind` is one of `correction`, `preference`, `fact`, `decision`. `body` is at most 4000 chars. No file means no pins.

2. Before each L2 attempt, `run.sh` moves an existing `pins.jsonl` to a unique `pins.jsonl.stale-XXXXXX` made by `mktemp`, so two rebuilds in one second never overwrite each other's leftovers. That file came from an earlier run or a dead attempt, and no complete report from this attempt stands behind it. A failed move clears `PINS_SAFE`, and the run stores no pins.

3. After a complete report, and only when `CONSUME_SAFE=1` and `PINS_SAFE=1`, `run.sh` writes `<findings-dir>/pin-projects.tsv`: one `project<TAB>cwd` row per distinct project in this run's worklist (`sessions.txt`). The rows are computed before the first L1 call and held in the runner's memory until the pins are applied: L1 and L2 both run with the Write tool and `bypassPermissions`, so any file they can reach, including `sessions.txt`, `sessions-source.txt` and findings JSON, could be rewritten before authorization. The project is the directory directly under the session root that holds the session, so nested subagent and workflow agent transcripts count toward their bucket. `cwd` comes from the `project` subcommand of that session's own adapter (looked up in `sessions-source.txt`); a session whose cwd cannot be resolved counts as one more distinct, unusable cwd. Nothing here is read from a findings JSON, because its `session_path` is model output. For a dash bucket (an encoded path), a cwd must also encode (`encode_project`) to that bucket. A slug bucket (`CLAUDE_CODE_PROJECT_DIR_NAME`, such as `STRML-cc-autodream`) skips that check, because no cwd encodes to a slug. Either way, a bucket whose sessions report more than one distinct cwd gets none, and a cwd that fails the checks still counts as one of them. Anything looser would store one project's pin in another project's bank. Then it runs `bin/apply-pins.sh <findings-dir> <date>`. Pins do not depend on the date gate: an old-date rebuild is still a real lesson, and the ledger stops a rerun from writing twice.

4. `bin/apply-pins.sh` validates each line, then calls
   `shared-memory call mnemopi_remember '<json>' --cwd <cwd>` with content `title\n\nbody`, `source: cc-autodream`, `importance: 0.7`, metadata `{kind, project, autodream_date, origin: "cc-autodream"}`, and `bank` set to the `retainBank` that `shared-memory context --cwd <cwd>` reports. The bank has to be named: `mnemopi_remember` resolves it from the payload, then `MNEMOPI_MCP_BANK`, then `default`, and never from `--cwd`, so an unnamed bank puts every pin in the global store. No bank from `context` means the pin fails. A call succeeds only on exit 0 with `status: "stored"` and a string `memory_id`. Each success appends `<sha1 of the canonical pin>\t<memory_id>` to `pins-applied.tsv`. Counters go to `pins-result.txt`. The script always exits 0 after arguments parse, because a pin must never cost a report.

5. Deleted: the `touched-projects.txt` sidecar, the `claude-memory gc` block, `AUTODREAM_GC`, and every `MEMORY.md` write instruction in `PROMPT.md`. L2 may still read legacy `MEMORY.md` files as context.

`SHARED_MEMORY_BIN` overrides the CLI path. The test suite pins it to a mock, so no test can write real memory.

Known limit: the ledger stops the same pin text from landing twice. Reworded pins from a forced rebuild do land twice. Mnemopi's own review pass owns consolidation, as `claude-memory gc` did before.

## Failure matrix

Each row is a test in `tests/apply-pins.sh` (A) or `tests/run-all.sh` (R).

| state or input | what the operation does | how it can fail | what the caller is told |
| --- | --- | --- | --- |
| A1 no `pins.jsonl` | nothing | none | `pins_total: 0`, no call, no ledger |
| A2 `shared-memory` not found | applies nothing, leaves `pins.jsonl` | none | `pins_cli_missing: 1`, `pins_applied: 0`, no ledger |
| A3 one valid pin | one remember call with resolved `--cwd` | none | `pins_applied: 1`, ledger row holds the memory id |
| A4 rerun over the same pins | skips ledgered pins | double write | `pins_duplicate: 1`, no second call |
| A5 unparseable line among valid ones | skips it, applies the rest | one bad line stops all | `pins_invalid: 1`, the valid pin applied |
| A6 schema violations (no title, blank body, unknown kind, title over 150, newline in title) | skips each | a bad pin written | `pins_invalid: 5`, no call |
| A7 blank lines | ignored | counted as invalid | not in `pins_total` |
| A8 project not in this run | skips | memory for a project the run never saw | `pins_rejected_project: 1`, no call |
| A9 project seen, cwd empty or missing dir | skips | memory scoped to the wrong project | `pins_no_cwd: 2`, no call |
| A10 `pin-projects.tsv` missing | rejects every pin | writes without authorization | `pins_rejected_project` counts all |
| A11 CLI exits nonzero | no ledger row | failure recorded as applied | `pins_failed: 1`; the next run retries and applies it: `sweep_stranded_pins` reruns any date in the trailing week whose counters show failed pins |
| A12 CLI exits 0 with non-JSON output | no ledger row | garbage read as success | `pins_failed: 1` |
| A13 quotes, backslash, `$(...)`, newline in body | passed through as JSON data | shell injection or mangled text | payload content byte-identical, no command ran |
| A14 no arguments | usage | runs against `$PWD` | exit 2 |
| A21 store commits but its journal append fails (`mutation_committed_journal_incomplete`, a `memory_id`, exit 1) | counted as applied and ledgered, warning logged | read as failed, so every rerun stores the memory again | `pins_applied: 1`, ledger row, no second store on rerun |
| A23 store call exits nonzero but prints `stored` with a `memory_id` | pin fails, no ledger row | a failed write is ledgered as applied and never retried | `pins_failed: 1`; only `mutation_committed_journal_incomplete` may pair a nonzero exit with a stored memory |
| A22 `shared-memory context` exits nonzero but prints a bank | pin fails before any store | the `jq` stage's status hides the failure and the pin goes to that bank | `pins_failed: 1`, no call |
| A24 `pins.jsonl` exists but cannot be read (no read permission, or a directory) | applies nothing, leaves the file | the failed open reads as an empty file and the run reports no pins proposed | `pins_unreadable: 1`, no call |
| A15 store succeeds, ledger append fails | no applied count | counted as applied, silently stored again next run | `pins_unledgered: 1`, memory id in the run log |
| A16 result file cannot be written, an old one exists | old counters removed first | the run log repeats an earlier run's counts | no stale `pins-result.txt`, exit 3, so the run log says the counters are unavailable |
| A17 `shasum` exists but fails at runtime | pin fails before any store | empty hash ledgered, every later pin read as a duplicate | `pins_failed` for each, no call, no ledger row |
| A18 `shared-memory context` names no bank | pin fails before any store | memory lands in the global `default` bank instead of the project's | `pins_failed: 1`, no call |
| A19 store reports `stored` with an empty `memory_id` | no ledger row | an id-less row is ledgered as applied and blocks every retry | `pins_failed: 1` |
| A20 `pins-applied.tsv` exists but is unreadable | pin fails before any store | an unreadable ledger reads as "not stored" and the pin is stored again | `pins_failed: 1`, no call |
| A25 a pin tags a `harness` (`claude`, `omp`, `codex`) | stored as `metadata.harness`; an unknown, null or array value is invalid | an array passes a subsequence `index` check and is stored as the tag | `pins_invalid` counts the bad tags |
| A26 `shared-memory` without the harness gate and a tagged pin | holds the tagged pin, stores the untagged ones | the tag is stored where nothing filters on it | `pins_unsupported_harness: 1`; no ledger row, so a later run applies it |
| A27 a rebuild resolves the project to another bank | stores the pin there, since the ledger hash includes the bank | skipped as a duplicate of a pin stored in a different bank | `pins_applied: 1` |
| A28 `pins-result.txt` cannot be cleared | stores nothing | the run log reads an earlier run's counters | exit 3 |
| R1 complete report plus pins | pins applied after the report | pins before report | ledger present, log line |
| R2 truncated report plus pins | not applied | pins from a dead L2 | no call, no ledger |
| R3 forced rebuild with an old `pins.jsonl`, new L2 writes none | old file moved aside, nothing applied | old pins applied again | `pins.jsonl.stale-*` exists, no call |
| R4 prompt text | no `MEMORY.md` write or `touched-projects` directive | the old writer comes back | grep assertion |
| R5 runner text | no `claude-memory` or `touched-projects` | the old GC comes back | grep assertion |
| R6 session cwd contains a tab | that project gets an empty cwd | the TSV row splits and a different directory is used | every `pin-projects.tsv` row has two fields |
| R7 `pin-projects.tsv` rebuild fails, an old one exists | old file removed, pins skipped | stale authorization list reused | no call, no `pin-projects.tsv`, log line |
| R9 two projects whose only sessions are subagent transcripts | each keeps its own project name | both collapse to `subagents`, one cwd wins, a pin lands in the other project | the pin is stored in its own project's cwd, findings JSON names the real project |
| R10 a session's recorded cwd does not encode to the bucket it is stored in | that project gets no cwd | a pin for the bucket's project lands in another project's bank | no call, empty cwd column |
| R11 two different cwds encode to the same bucket | that project gets no cwd | one cwd wins and the other project's pins land in its bank | no call, empty cwd column |
| R12 bucket is a `CLAUDE_CODE_PROJECT_DIR_NAME` slug (`owner-repo`), not an encoded path | the encode check is skipped; the one-cwd rule still applies | every pin for the owner's main repos is refused (68 of 359 buckets on this host) | the pin is stored in the session's cwd |
| R13 one session's cwd is unusable (tab or newline, or does not encode to a dash bucket), another's is valid | the unusable cwd still counts as a distinct cwd | the valid one wins and a pin lands in a directory that only shares the bucket | no call |
| R18 one session's cwd no longer resolves (a removed worktree) or has no source adapter, and another session in the bucket resolves | the unresolved session counts as a distinct, unusable cwd | the resolved cwd wins, and a pin from the other directory lands in its bank | no call, empty cwd column |
| R19 `notify.sh` never returns (a blocking `AUTODREAM_OPEN` command) | pins are applied right after the report is complete, before notify | the run is killed in notify, the next run skips the date, and the pins are never stored | the pin is already ledgered when `notify.sh` runs |
| R20 a bucket is literally named `subagents` (a `CLAUDE_CODE_PROJECT_DIR_NAME` slug) | the project is the directory directly under the session root, at any depth (also covers `<bucket>/<session>/subagents/workflows/wf_*/agent-*.jsonl`) | the project becomes an ancestor or `wf_*` directory's name and the pin is refused or misattributed | the pin is stored, findings JSON names the bucket |
| R21 an earlier `pins.jsonl` cannot be moved aside (a directory) | the empty `mktemp` file is removed, pins are skipped | one empty `pins.jsonl.stale-*` file leaks per L2 attempt | no `pins.jsonl.stale-*` file, log line, no call |
| R14 L2 is killed between writing pins and writing the report | pins are written first, so no complete report exists and the next attempt moves them aside | a complete report says "Pinned" with no pins behind it, and the idempotency guard never retries | prompt test: the pins step precedes the report step |
| R15 L2 (Write and Edit tools) appends an unscanned session to `sessions.txt`, `sessions-source.txt` and findings | the authorization list is computed from the worklist the runner held in memory before L1 ran | an injected model widens the authorization list to any real project on disk | no call, injected project absent from `pin-projects.tsv` |
| R16 L1 does the same tampering | same | same | same |
| R17 the report describes a pin the runner later refuses or fails | the prompt says "Pin proposed", never stored | the report claims memory that does not exist | prompt test |
| R8 L1 writes a `session_path` naming an untriaged project's session | the authorization list comes from `sessions.txt`, not findings JSON | a model-written path authorizes memory for a project the run never saw | no call, that project absent from `pin-projects.tsv` |
| R18 a worker empties `pins-applied.tsv` before a forced rebuild applies its pins | the runner restores the ledger it held before any model ran | the rebuild stores every pin again | no second call, the ledger row is back |
| R19 the run dies after the report lands and before the pin step (no `pins-result.txt`) | the next run's sweep applies the pins from disk | a complete report whose pins are never stored, and the idempotency guard skips the date | the pin is stored, `pins-result.txt` records it |
| R20 a date in the trailing week has failed or held pins | the sweep reruns `apply-pins.sh` for it; the ledger blocks duplicates | a store that was down one night strands that night's pins | `pins_applied` in that date's counters |
