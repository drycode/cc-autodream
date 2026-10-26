# autodream-band

A Claude Code mod that puts the newest autodream report in front of you, and lets you triage its open questions without
leaving Claude Code. It is optional: the nightly run and `review.sh` work the same with or without it.

When the newest report is a day or two old, is not triaged yet, and has open questions or a medium/high pattern, a band
appears above the prompt:

```
🌙 Autodream 2026-10-01: 2 open questions · top pattern: Editing files before reading them   [Triage] [View] [Dismiss]
```

- **Triage** starts `review.sh` in a fresh Claude session in a cmux split to the right of the current one, so the
  conversation you were in stays about what it was about.
- **View** opens the report's top patterns and open questions in a pane.
- **Dismiss** hides the band for that report, across sessions. The next night's report brings it back.

The band also goes away on its own once the report has a `## Triage decisions` section, which is how a finished triage
ends, and it is re-checked at session start, every 30 minutes and after every turn.

## Install

```bash
claude --plugin-dir /path/to/cc-autodream/mods/autodream-band
```

Or add the folder to `CLAUDE_CODE_PLUGIN_DIRS` to load it in every session.

## `/dream`

| Command | What it does |
| --- | --- |
| `/dream` | Open the newest report's key sections in a pane. |
| `/dream triage` | Run `review.sh` in a cmux split beside this session. |
| `/dream here` | Triage in this session: the same walk-through, one question at a time, under this session's permission mode. |
| `/dream cmux` | Run `review.sh` so it opens its own cmux workspace. |

Add `force` to triage a report that has no open questions or is already triaged, as `review.sh --force` does.

`/dream triage` degrades rather than fails. If the split's address cannot be read from what `cmux new-split` prints, or
the command cannot be sent into it, `review.sh` opens a cmux workspace instead. Outside cmux there is nothing to split, so
it opens the workspace directly. With no cmux or no `review.sh` it triages in the current session.

## Where it looks

The mod reads the variables `bin/review.sh` reads, with the same defaults:

| Variable | Default |
| --- | --- |
| `DREAMS_DIR` | `~/.claude/dreams` |
| `AUTODREAM_DIR` | `~/.claude/autodream` (where `review.sh` is) |
| `CMUX_BIN` | `/Applications/cmux.app/Contents/Resources/bin/cmux` |

A value that lives only in `$AUTODREAM_DIR/config` is invisible to the mod, because the mod cannot source a shell file.
Export it in the environment Claude Code starts from if you moved something there.

## What it depends on in the report

The mod parses the report `prompts/PROMPT.md` tells Layer 2 to write, so these are a contract. If one changes, change
`hooks/lib.ts` and its tests in the same commit.

- The title `# Autodream — YYYY-MM-DD`.
- `## Top patterns`, each pattern a `### <title>` with a `- **Severity**: high|medium|low` line.
- `## Open questions`, ended by `<!-- autodream:open-questions=N -->`. A report with no marker counts as zero questions.
- A `## Triage decisions` heading once a triage has run.

## Tests

```bash
claude plugin validate mods/autodream-band
claude plugin test mods/autodream-band
```

For `tsc -p mods/autodream-band` Claude Code has to have loaded the mod once: it writes the type definitions into
`.claude-plugin/types/`, which is git-ignored. CI does not run these, because they need Claude Code itself.
