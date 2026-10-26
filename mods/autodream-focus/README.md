# autodream-focus

A Claude Code mod that puts a `+ autodream focus` button at the top right of every prompt and reply. Press it to tag
that turn, and the next nightly autodream run takes a close look at it. It is optional and separate from
`autodream-band`: nothing installs or loads it unless you ask.

```
> why is the build red?                          + autodream focus
  The lockfile is stale. Run npm ci, then ...
```

- The button appears while the pointer is over a row. Press it and it becomes `✓ autodream focus` and stays, so a glance
  down the transcript finds what you marked. Press it again to take the tag back.
- It sits on the right, drawn over the row rather than beside it, so nothing reflows and a narrow split pane loses no
  width.
- Only what you typed gets one (at the terminal or from the phone), plus the assistant's text. A task notification or
  another session's message is not yours to tag.
- Clicks reach the transcript in fullscreen mode (`"tui": "fullscreen"`). On the main screen the rows are already in
  scrollback and cannot be pressed.

## Install

Opt in per session:

```bash
claude --plugin-dir /path/to/cc-autodream/mods/autodream-focus
```

Or add the folder to `CLAUDE_CODE_PLUGIN_DIRS` (colon-separated, next to `autodream-band` if you use it) to load it in
every session. `install.sh` does not touch this mod.

## What a tag does

Pressing the button adds one line to `$AUTODREAM_DIR/tags.jsonl` (default `~/.claude/autodream/tags.jsonl`):

```json
{"id":"<session>:<row>","session":"…","uuid":"<row>","role":"user|assistant","text":"…","cwd":"…","taggedAt":"2026-10-04T22:15:00.000Z"}
```

`text` is the turn, capped at 2,000 characters. `taggedAt` is UTC and the only clock in the line: the mod has no
timezone to speak of, so `bin/vault-notes.sh` decides which local day a tag belongs to. An evening tag is in that day's
report, not the next one's.

`bin/vault-notes.sh` reads that file as a third capture surface, next to `notes.md` and the vault inbox. Each tag that
was made on or before the date being reported, and that no earlier report has read, becomes a `## note: focus-…` block
in `findings/<date>/operator-notes.md`: the quoted turn, the speaker, the project, the session id and the transcript's
path, with an instruction to read the turn in context and report on it. L2 already reads that file and has the Read
tool, so the prompt needed no change.

A tag is consumed only after a complete report, under the same gates as an inbox note (`archive`, not `collect`): a
failed run, or a rebuild of an old date, leaves it pending. Consumed tags (id, report date and `taggedAt`) go in `tags-consumed.txt`, a ledger this script
writes and the mod never does, so a session open at 03:15 cannot race the run. `vault-notes.sh status` shows both counts.

`vault-notes.sh` needs `jq` for this. Without it the tags are reported as `UNREADABLE` in the operator notes and nothing
is consumed.

## Where it looks

| Variable | Default |
| --- | --- |
| `AUTODREAM_DIR` | `~/.claude/autodream` (where `tags.jsonl` is) |
| `AUTODREAM_TAGS_FILE` | `$AUTODREAM_DIR/tags.jsonl` (moves the file itself, as it does for `bin/vault-notes.sh`) |

A value set only in `$AUTODREAM_DIR/config` is invisible to the mod, because the mod cannot source a shell file. Export it
in the environment Claude Code starts from if you moved the install.

## Limits

- Claude Code transcripts only. OMP sessions have no focus button.
- `tags.jsonl` only grows, at most about 2 KB a tag, and Claude Code will not read a file over 4 MiB for a mod. Past
  that the button says it cannot read the file and changes nothing, rather than rewriting it from empty. Prune it by hand
  (and `tags-consumed.txt` with it) long before then.
- Every press rewrites the file from what is on disk, so two open sessions mostly keep each other's tags, but the write
  is not an atomic rename and the gap between its read and its write is not closed.
- Whether a row's id is the transcript's own `uuid` is not guaranteed by the mod API, so a note points at the session
  and quotes the turn instead of relying on the id to find it.

## Tests

```bash
claude plugin validate mods/autodream-focus
claude plugin test mods/autodream-focus
```

The `vault-notes.sh` side is covered by the `test_focus_tag_*` cases in `tests/run-all.sh`. For `tsc -p
mods/autodream-focus` Claude Code has to have loaded the mod once: it writes the type definitions into
`.claude-plugin/types/`, which is git-ignored. CI does not run the mod's tests, because they need Claude Code itself.
