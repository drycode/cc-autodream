import { describe, expect, test } from 'claude-code/testing'

import {
  cmuxTriage,
  isFresh,
  isTriaged,
  keySections,
  latestReport,
  locations,
  parseReport,
  shellQuote,
  shouldShow,
  surfaceRef,
  triageCommandLine,
  triagePrompt,
} from '../hooks/lib'

const REPORT = `# Autodream — 2026-10-01

## Activity snapshot
- 39 sessions across 4 projects.

## Top patterns (ranked)

### Editing files before reading them
- **Category**: read_before_edit
- **Count**: 6
- **Severity**: high
- **Confidence**: high

### Sandbox-denied Bash command, recovered without retry loops
- **Category**: sandbox_friction
- **Severity**: low

## Per-project notes
Long notes that the pane leaves out.

## Memory candidates
- Always Read a file in-session before the first Edit.

## Open questions for the user
1. Should the isekai debate panel stay on Opus?

<!-- autodream:open-questions=1 -->
`

const QUIET = `# Autodream — 2026-09-30

## Top patterns (ranked)
None. All 3 sessions returned empty \`findings\` and none reported an error.

## Open questions for the user
None.

<!-- autodream:open-questions=0 -->
`

describe('parseReport', () => {
  test('reads the date, the open-question count and each pattern with its severity', async () => {
    expect(parseReport(REPORT)).toEqual({
      date: '2026-10-01',
      openQuestions: 1,
      isTriaged: false,
      patterns: [
        { title: 'Editing files before reading them', severity: 'high' },
        { title: 'Sandbox-denied Bash command, recovered without retry loops', severity: 'low' },
      ],
    })
  })

  test('a quiet night has no patterns and no questions', async () => {
    expect(parseReport(QUIET)).toEqual({ date: '2026-09-30', openQuestions: 0, isTriaged: false, patterns: [] })
  })

  test('a report with no marker counts no open questions', async () => {
    expect(parseReport('# Autodream — 2026-09-29\n\n## Top patterns (ranked)\nNone.\n')?.openQuestions).toBe(0)
  })

  test('text that is not a report is null', async () => {
    expect(parseReport('hello')).toBeNull()
  })
})

describe('isTriaged', () => {
  test('a report carries "## Triage decisions" once review.sh or a triage session has worked through it', async () => {
    expect(isTriaged(REPORT)).toBe(false)
    expect(isTriaged(`${REPORT}\n## Triage decisions\n- 1. approved\n`)).toBe(true)
    expect(parseReport(`${REPORT}\n## Triage decisions\n- 1. approved\n`)?.isTriaged).toBe(true)
  })

  test('the words inside another section do not count', async () => {
    expect(isTriaged('# Autodream — 2026-10-01\n\nNo ## Triage decisions yet, see below.\n')).toBe(false)
  })
})

describe('triagePrompt', () => {
  const text = triagePrompt('2026-10-01', '/Users/x/.claude/dreams/2026-10-01.md')

  test('names the report and asks for the same walk-through review.sh runs', async () => {
    expect(text).toContain('2026-10-01')
    expect(text).toContain('/Users/x/.claude/dreams/2026-10-01.md')
    expect(text).toContain('ONE open question')
    expect(text).toContain('approve / modify / skip / discuss')
    expect(text).toContain('## Triage decisions')
  })

  test('keeps review.sh\'s guardrail: global files need per-edit approval', async () => {
    expect(text).toContain('explicit per-edit approval')
  })

  test('says nothing about where memory goes: that is the installation\'s business, not the mod\'s', async () => {
    expect(text).not.toMatch(/MEMORY\.md|Mnemopi|promote\.sh|apply-pins/)
  })
})

describe('locations', () => {
  test('defaults to where install.sh and review.sh put things', async () => {
    expect(locations({ HOME: '/Users/x' })).toEqual({
      dreams: '/Users/x/.claude/dreams',
      script: '/Users/x/.claude/autodream/review.sh',
      cmux: '/Applications/cmux.app/Contents/Resources/bin/cmux',
    })
  })

  test('an exported DREAMS_DIR, AUTODREAM_DIR or CMUX_BIN wins, as it does in review.sh', async () => {
    expect(locations({ HOME: '/Users/x', DREAMS_DIR: '/d', AUTODREAM_DIR: '/a', CMUX_BIN: '/c/cmux' })).toEqual({
      dreams: '/d',
      script: '/a/review.sh',
      cmux: '/c/cmux',
    })
  })

  test('an empty variable counts as unset, like ${VAR:-default}', async () => {
    expect(locations({ HOME: '/Users/x', DREAMS_DIR: '', AUTODREAM_DIR: '', CMUX_BIN: '' }).dreams).toBe('/Users/x/.claude/dreams')
    expect(locations({ HOME: '/Users/x', AUTODREAM_DIR: '' }).script).toBe('/Users/x/.claude/autodream/review.sh')
  })
})

describe('cmuxTriage', () => {
  test('runs review.sh with the cmux surface and focus, for the report\'s date', async () => {
    expect(cmuxTriage('/Users/x/.claude/autodream/review.sh', '2026-10-01', false)).toEqual({
      argv: ['bash', '/Users/x/.claude/autodream/review.sh', '2026-10-01'],
      env: { AUTODREAM_TRIAGE_SURFACE: 'cmux', AUTODREAM_TRIAGE_FOCUS: 'true' },
      script: '/Users/x/.claude/autodream/review.sh',
    })
  })

  test('force is passed through, so a report with nothing to triage still opens', async () => {
    expect(cmuxTriage('/s/review.sh', '2026-10-01', true).argv).toEqual(['bash', '/s/review.sh', '--force', '2026-10-01'])
  })
})

describe('side-window triage', () => {
  test('shellQuote keeps a path with spaces or quotes as one word', async () => {
    expect(shellQuote('/Users/x/My Files/review.sh')).toBe("'/Users/x/My Files/review.sh'")
    expect(shellQuote("/it's/here")).toBe("'/it'\\''s/here'")
  })

  test('the line sent to the new split runs review.sh inline there, for the report\'s date', async () => {
    expect(triageCommandLine('/Users/x/.claude/autodream/review.sh', '2026-10-01', false)).toBe(
      "env AUTODREAM_TRIAGE_SURFACE=inline bash '/Users/x/.claude/autodream/review.sh' 2026-10-01",
    )
    expect(triageCommandLine('/s.sh', '2026-10-01', true)).toBe("env AUTODREAM_TRIAGE_SURFACE=inline bash '/s.sh' --force 2026-10-01")
  })

  test('surfaceRef reads the new split\'s address from what cmux printed: a short ref or a UUID', async () => {
    expect(surfaceRef('OK surface:7 workspace:2\n')).toBe('surface:7')
    expect(surfaceRef('created F916A89A-73D3-407C-B2BC-678CBB8D87F2\n')).toBe('F916A89A-73D3-407C-B2BC-678CBB8D87F2')
  })

  test('surfaceRef answers null when nothing in the output can address a surface', async () => {
    expect(surfaceRef('OK\n')).toBeNull()
    expect(surfaceRef('')).toBeNull()
    expect(surfaceRef('error: no workspace')).toBeNull()
  })
})

describe('parseReport titles', () => {
  test('drops Markdown backticks from a pattern title: they are noise in a one-line band', async () => {
    const parsed = parseReport('# Autodream — 2026-10-02\n\n## Top patterns (ranked)\n\n### Sandbox blocks git checkouts and `gh` authentication\n- **Severity**: high\n')

    expect(parsed?.patterns[0]?.title).toBe('Sandbox blocks git checkouts and gh authentication')
  })
})

describe('latestReport', () => {
  test('picks the newest dated report and ignores everything else', async () => {
    expect(latestReport(['switchyard-dreamer.log', '2026-09-30.md', '2026-10-01.md', 'notes.md', '2026-10-01.md.bak'])).toBe('2026-10-01.md')
  })

  test('none when no file is a dated report', async () => {
    expect(latestReport(['notes.md'])).toBeNull()
  })
})

describe('isFresh', () => {
  const now = new Date(2026, 9, 2, 8, 0, 0).getTime()

  test('last night and the night before are fresh; a week-old report is not', async () => {
    expect(isFresh('2026-10-01', now, 2)).toBe(true)
    expect(isFresh('2026-09-30', now, 2)).toBe(true)
    expect(isFresh('2026-09-25', now, 2)).toBe(false)
  })
})

describe('shouldShow', () => {
  const report = (over = {}) => ({ date: '2026-10-01', openQuestions: 0, isTriaged: false, patterns: [], ...over })

  test('open questions earn the band', async () => {
    expect(shouldShow(report({ openQuestions: 2 }), null)).toBe(true)
  })

  test('a medium or higher pattern earns it, critical included; a low one does not', async () => {
    expect(shouldShow(report({ patterns: [{ title: 'x', severity: 'medium' }] }), null)).toBe(true)
    expect(shouldShow(report({ patterns: [{ title: 'x', severity: 'critical' }] }), null)).toBe(true)
    expect(shouldShow(report({ patterns: [{ title: 'x', severity: 'low' }] }), null)).toBe(false)
  })

  test('a dismissed report stays dismissed', async () => {
    expect(shouldShow(report({ openQuestions: 2 }), '2026-10-01')).toBe(false)
    expect(shouldShow(report({ openQuestions: 2 }), '2026-09-30')).toBe(true)
  })

  test('a report that has been triaged is done: it stops asking', async () => {
    expect(shouldShow(report({ openQuestions: 2, isTriaged: true }), null)).toBe(false)
    expect(shouldShow(report({ patterns: [{ title: 'x', severity: 'high' }], isTriaged: true }), null)).toBe(false)
  })
})

describe('keySections', () => {
  test('keeps the patterns and questions, and drops the rest', async () => {
    const text = keySections(REPORT, 10_000)

    expect(text).toContain('## Top patterns')
    expect(text).toContain('## Open questions')
    expect(text).not.toContain('## Memory candidates')
    expect(text).not.toContain('Per-project notes')
  })

  test('is capped to what a Markdown element draws', async () => {
    expect(keySections(`## Top patterns\n${'x'.repeat(30_000)}`, 10_000).length).toBeLessThanOrEqual(10_000)
  })
})
