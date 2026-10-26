import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { standIn } from './stand-in'

const BAND = { hasSurvey: false, isWorking: false, maxRows: 6, bodyColumns: 100 } as never
const PANE = { title: 'Autodream', isFocused: true, bodyColumns: 100, placement: 'inline' } as never
const NOW = new Date(2026, 9, 2, 8, 0, 0).getTime()

const BUSY = `# Autodream — 2026-10-01

## Top patterns (ranked)

### Editing files before reading them
- **Severity**: high

## Open questions for the user
1. Keep the panel on Opus?

<!-- autodream:open-questions=1 -->
`

const QUIET = `# Autodream — 2026-10-01

## Top patterns (ranked)

### Sandbox friction
- **Severity**: low

## Open questions for the user
None.

<!-- autodream:open-questions=0 -->
`

const SCRIPT = '/Users/x/.claude/autodream/review.sh'
const CMUX = '/Applications/cmux.app/Contents/Resources/bin/cmux'
const REPORT_PATH = '/Users/x/.claude/dreams/2026-10-01.md'
const WORKSPACE_SAID = 'review.sh: opening 2026-10-01 triage in a new cmux workspace (focus=true)\n'

type Run = { argv: readonly string[]; env?: Record<string, string> }
type Reply = { exitCode: number; stdout: string }

type Machine = {
  /** review.sh is installed */
  hasScript?: boolean
  /** the cmux app is installed */
  hasCmux?: boolean
  /** this session runs inside a cmux surface (CMUX_SURFACE_ID is set) */
  inCmux?: boolean
  /** what `cmux new-split` prints, and what `cmux send` does */
  split?: Reply
  send?: Reply
  /** exported variables beyond HOME, such as DREAMS_DIR, AUTODREAM_DIR or CMUX_BIN */
  env?: Record<string, string>
  /** where review.sh and cmux are on this machine, when not at the defaults */
  scriptAt?: string
  cmuxAt?: string
}

const world = (
  on: On,
  reports: Record<string, string>,
  {
    hasScript = true,
    hasCmux = true,
    inCmux = true,
    split = { exitCode: 0, stdout: 'OK surface:7 workspace:2\n' },
    send = { exitCode: 0, stdout: '' },
    env = {},
    scriptAt = SCRIPT,
    cmuxAt = CMUX,
  }: Machine = {},
) => {
  const clock = mock.clock(on, { now: NOW })
  const sent: string[] = []
  const runs: Run[] = []
  const listed: string[] = []

  mock.env(on, { HOME: '/Users/x', ...env, ...(inCmux ? { CMUX_SURFACE_ID: 'F916A89A-73D3-407C-B2BC-678CBB8D87F2' } : {}) })
  mock.store(on)

  on('session.start', () => ({ cwd: '/x' }))
  on('command.register', (_$, e) => ({ value: { command: e.name } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.close', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))
  on('turn.complete', () => ({ text: '' }))
  on('prompt.submit', (_$, e) => {
    sent.push(e.text)

    return { text: e.text }
  })
  on('fs.exists', (_$, e) => ({ value: (hasScript && e.path === scriptAt) || (hasCmux && e.path === cmuxAt) }))
  on('process.run', (_$, e) => {
    runs.push({ argv: e.argv, env: e.init?.env })

    // cmux answers new-split and send; anything else (review.sh itself) says it opened a workspace
    const reply: Reply =
      e.argv[0] === cmuxAt ? (e.argv[1] === 'new-split' ? split : e.argv[1] === 'send' ? send : { exitCode: 0, stdout: '' }) : { exitCode: 0, stdout: WORKSPACE_SAID }

    return { value: { exitCode: reply.exitCode, stdout: reply.stdout, stderr: reply.exitCode === 0 ? '' : 'cmux: failed', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>engine band</Text>
  })
  on('fs.list', (_$, e) => {
    listed.push(e.path)

    return { value: Object.keys(reports).map(name => ({ name, kind: 'file', size: 1, mtimeMs: 0, isLink: false })) }
  })
  on('fs.read', (_$, e) => {
    const text = reports[e.path.split('/').pop() ?? '']

    return text === undefined ? { deny: `ENOENT ${e.path}` } : { value: text }
  })

  // The mod sends a triage prompt from a timer, outside the press that asked for it, so tests let the timer fire.
  return { sent, runs, listed, clock, landed: () => clock.advance(100) }
}

const start = ($: any) => $.session.start({ cwd: '/x', surface: 'terminal', isInteractive: true })
const band = ($: any) => $.ui.mount({ plugin: 'autodream-band', surface: 'terminal', component: 'AbovePrompt', props: BAND })
const run = ($: any, args = '') =>
  $.command.run({ command: 'dream', args, origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 120 } })
const pane = ($: any) => $.ui.mount({ plugin: 'autodream-band', surface: 'terminal', component: 'Pane', requestId: 'dream', props: PANE })

test('the band appears when last night\'s report has an open question', async ($, on) => {
  world(on, { '2026-10-01.md': BUSY })
  await start($)

  const text = (await (await band($)).find({ key: 'band' }))?.text

  expect(text).toContain('2026-10-01')
  expect(text).toContain('1 open question')
  expect(text).toContain('Editing files before reading them')
})

test('the band is one row: the summary truncates instead of wrapping around the buttons', async ($, on) => {
  world(on, { '2026-10-01.md': BUSY.replace('Editing files before reading them', `${'A very long pattern title '.repeat(12)}`) })
  await start($)

  const ui = await band($)
  const summary = await ui.find({ type: 'Text', text: /Autodream 2026-10-01/ })

  expect(summary?.props?.wrap).toBe('truncate-end')
  // the buttons are in the band row, not beneath the summary
  expect(await ui.find({ key: 'triage' })).toBeDefined()
  expect(await ui.find({ key: 'view' })).toBeDefined()
  expect(await ui.find({ key: 'dismiss' })).toBeDefined()
})

test('a quiet report leaves the band to the engine', async ($, on) => {
  world(on, { '2026-10-01.md': QUIET })
  await start($)

  const ui = await band($)

  expect(await ui.find({ key: 'band' })).toBeUndefined()
  expect(await ui.find({ text: 'engine band' })).toBeDefined()
})

test('a report from a week ago is not news', async ($, on) => {
  world(on, { '2026-09-24.md': BUSY.replace('2026-10-01', '2026-09-24') })
  await start($)

  expect(await (await band($)).find({ key: 'band' })).toBeUndefined()
})

test('Dismiss hides the band now and for every later session until the next report', async ($, on) => {
  world(on, { '2026-10-01.md': BUSY })
  await start($)

  await (await band($)).press({ key: 'dismiss' })

  expect(await (await band($)).find({ key: 'band' })).toBeUndefined()

  await start($)

  expect(await (await band($)).find({ key: 'band' })).toBeUndefined()
})

test('/dream opens the report even when the band is quiet', async ($, on) => {
  world(on, { '2026-10-01.md': QUIET })
  await start($)

  const reply = await run($)
  const ui = await $.ui.mount({ plugin: 'autodream-band', surface: 'terminal', component: 'Pane', requestId: 'dream', props: PANE })

  expect(reply.text).toContain('2026-10-01')
  expect((await ui.find({ type: 'Markdown' }))?.text).toContain('Sandbox friction')
})

const SPLIT_LINE = `env AUTODREAM_TRIAGE_SURFACE=inline bash '${SCRIPT}' 2026-10-01`

test('Triage on the band opens review.sh in a split beside this session and sends nothing here', async ($, on) => {
  const { sent, runs, landed } = world(on, { '2026-10-01.md': BUSY })
  await start($)

  await (await band($)).press({ key: 'triage' })
  await landed()

  expect(runs.map(one => one.argv)).toEqual([
    [CMUX, 'new-split', 'right', '--focus', 'true'],
    // cmux reads a backslash-n in the text as Enter
    [CMUX, 'send', '--surface', 'surface:7', '--', `${SPLIT_LINE}\\n`],
  ])
  expect(sent).toEqual([])
})

test('Triage here on the pane starts the walk-through in this session, naming the report', async ($, on) => {
  const { sent, runs, landed } = world(on, { '2026-10-01.md': BUSY })
  await start($)
  await run($)

  await (await pane($)).press({ key: 'here' })
  await landed()

  expect(runs).toEqual([])
  expect(sent).toHaveLength(1)
  expect(sent[0]).toContain('2026-10-01')
  expect(sent[0]).toContain(REPORT_PATH)
  expect(sent[0]).toContain('ONE open question')
})

test('a triaged report no longer asks for attention, even with open questions in it', async ($, on) => {
  world(on, { '2026-10-01.md': `${BUSY}\n## Triage decisions\n- 1. approved\n` })
  await start($)

  expect(await (await band($)).find({ key: 'band' })).toBeUndefined()
})

test('the band clears on the turn that finishes the triage', async ($, on) => {
  const reports = { '2026-10-01.md': BUSY }

  world(on, reports)
  await start($)
  expect(await (await band($)).find({ key: 'band' })).toBeDefined()

  // the triage session logs its decisions into the report, then its turn ends
  reports['2026-10-01.md'] = `${BUSY}\n## Triage decisions\n- 1. approved\n`
  await $.turn.complete({ answer: 'done', durationMs: 1000, isAborted: false, turnId: 't', reason: 'answer' })

  expect(await (await band($)).find({ key: 'band' })).toBeUndefined()
})

test('/dream here starts it in this session; with nothing to triage it says so unless forced', async ($, on) => {
  const { sent, runs, landed } = world(on, { '2026-10-01.md': QUIET })
  await start($)

  expect((await run($, 'here')).text).toContain('no open questions')
  await landed()
  expect(sent).toEqual([])

  expect((await run($, 'here force')).text).toContain('Starting')
  await landed()
  expect(sent).toHaveLength(1)
  expect(runs).toEqual([])
})

test('/dream triage opens the side window, and with nothing to triage it says so unless forced', async ($, on) => {
  const { runs } = world(on, { '2026-10-01.md': QUIET })
  await start($)

  expect((await run($, 'triage')).text).toContain('no open questions')
  expect(runs).toEqual([])

  const forced = await run($, 'triage force')

  expect(forced.text).toContain('split')
  expect(runs[1]?.argv.at(-1)).toBe(`env AUTODREAM_TRIAGE_SURFACE=inline bash '${SCRIPT}' --force 2026-10-01\\n`)
})

test('outside cmux there is no pane to split, so review.sh opens its own cmux workspace', async ($, on) => {
  const { runs } = world(on, { '2026-10-01.md': BUSY }, { inCmux: false })
  await start($)

  const reply = await run($, 'triage')

  expect(runs.map(one => one.argv)).toEqual([['bash', SCRIPT, '2026-10-01']])
  expect(reply.text).toContain('new cmux workspace')
})

test('a split whose address cannot be read falls back to the workspace, and sends no command into the void', async ($, on) => {
  const { runs } = world(on, { '2026-10-01.md': BUSY }, { split: { exitCode: 0, stdout: 'OK\n' } })
  await start($)

  const reply = await run($, 'triage')

  expect(runs.map(one => one.argv[1])).toEqual(['new-split', SCRIPT])
  expect(reply.text).toContain('workspace')
})

test('a split that cannot be sent to falls back to the workspace too', async ($, on) => {
  const { runs } = world(on, { '2026-10-01.md': BUSY }, { send: { exitCode: 1, stdout: '' } })
  await start($)

  const reply = await run($, 'triage')

  expect(runs.map(one => one.argv[1])).toEqual(['new-split', 'send', SCRIPT])
  expect(reply.text).toContain('workspace')
})

test('a failed split falls back to the workspace', async ($, on) => {
  const { runs } = world(on, { '2026-10-01.md': BUSY }, { split: { exitCode: 1, stdout: '' } })
  await start($)

  expect((await run($, 'triage')).text).toContain('workspace')
  expect(runs.map(one => one.argv[1])).toEqual(['new-split', SCRIPT])
})

test('with no cmux at all it triages in this session instead', async ($, on) => {
  const { sent, runs, landed } = world(on, { '2026-10-01.md': BUSY }, { hasCmux: false })
  await start($)

  const reply = await run($, 'triage')
  await landed()

  expect(runs).toEqual([])
  expect(sent).toHaveLength(1)
  expect(reply.text).toContain('this session')
})

test('/dream triage will not reopen a report that is already triaged unless forced', async ($, on) => {
  const { sent, landed } = world(on, { '2026-10-01.md': `${BUSY}\n## Triage decisions\n- 1. approved\n` })
  await start($)

  expect((await run($, 'triage')).text).toContain('already triaged')
  await landed()
  expect(sent).toEqual([])
})

test('/dream cmux runs review.sh for that date in its own cmux workspace', async ($, on) => {
  const { runs } = world(on, { '2026-10-01.md': BUSY })
  await start($)

  const reply = await run($, 'cmux')

  expect(runs).toHaveLength(1)
  expect(runs[0]?.argv).toEqual(['bash', SCRIPT, '2026-10-01'])
  expect(runs[0]?.env).toMatchObject({ AUTODREAM_TRIAGE_SURFACE: 'cmux', AUTODREAM_TRIAGE_FOCUS: 'true' })
  expect(reply.text).toContain('opening 2026-10-01 triage in a new cmux workspace')
})

test('/dream cmux says so when autodream is not installed, and runs nothing', async ($, on) => {
  const { runs } = world(on, { '2026-10-01.md': BUSY }, { hasScript: false })
  await start($)

  expect((await run($, 'cmux')).text).toContain('review.sh')
  expect(runs).toEqual([])
})

test('the pane offers both ways to triage while there is something to triage', async ($, on) => {
  world(on, { '2026-10-01.md': BUSY })
  await start($)
  await run($)

  const ui = await pane($)

  expect(await ui.find({ key: 'triage' })).toBeDefined()
  expect(await ui.find({ key: 'here' })).toBeDefined()
})

test('the pane offers neither once the report is triaged', async ($, on) => {
  world(on, { '2026-10-01.md': `${BUSY}\n## Triage decisions\n- 1. approved\n` })
  await start($)
  await run($)

  const ui = await pane($)

  expect(await ui.find({ key: 'triage' })).toBeUndefined()
  expect(await ui.find({ key: 'here' })).toBeUndefined()
})

test('/dream says so when there is no report', async ($, on) => {
  world(on, {})
  await start($)

  expect((await run($)).text).toContain('No autodream report')
})

test('reports are read from DREAMS_DIR when it is exported, and a missing report names that directory', async ($, on) => {
  const { sent, listed, landed } = world(on, { '2026-10-01.md': BUSY }, { env: { DREAMS_DIR: '/data/dreams' } })
  await start($)

  expect(listed).toEqual(['/data/dreams'])

  await run($, 'here')
  await landed()

  expect(sent[0]).toContain('/data/dreams/2026-10-01.md')
})

test('with no report, /dream names the directory it looked in', async ($, on) => {
  world(on, {}, { env: { DREAMS_DIR: '/data/dreams' } })
  await start($)

  expect((await run($)).text).toContain('/data/dreams')
})

test('a report the band cannot read is called that, not "no report"', async ($, on) => {
  world(on, { '2026-10-01.md': '# Dream report — 2026-10-01\n\nsome other format\n' })
  await start($)

  const text = (await run($)).text

  expect(text).toContain('2026-10-01.md')
  expect(text).toContain('not in the format')
})

test('review.sh and cmux are found where AUTODREAM_DIR and CMUX_BIN point', async ($, on) => {
  const { runs } = world(
    on,
    { '2026-10-01.md': BUSY },
    { env: { AUTODREAM_DIR: '/opt/ad', CMUX_BIN: '/usr/local/bin/cmux' }, scriptAt: '/opt/ad/review.sh', cmuxAt: '/usr/local/bin/cmux' },
  )
  await start($)

  await run($, 'triage')

  expect(runs.map(one => one.argv)).toEqual([
    ['/usr/local/bin/cmux', 'new-split', 'right', '--focus', 'true'],
    ['/usr/local/bin/cmux', 'send', '--surface', 'surface:7', '--', "env AUTODREAM_TRIAGE_SURFACE=inline bash '/opt/ad/review.sh' 2026-10-01\\n"],
  ])
})

for (const tier of ['append', 'prepend'] as const) {
  test(`the band shares the slot with another plugin's row, and keeps the engine's (${tier})`, { plugins: [standIn(tier)] }, async ($, on) => {
    world(on, { '2026-10-01.md': BUSY })
    await start($)

    const ui = await band($)

    expect(await ui.find({ key: 'band' })).toBeDefined()
    expect(await ui.find({ text: 'stand-in row' })).toBeDefined()
    expect(await ui.find({ text: 'engine band' })).toBeDefined()
  })
}
