import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const NOW = new Date(2026, 9, 4, 20, 15, 0).getTime()
const FILE = '/Users/x/.claude/autodream/tags.jsonl'

type Machine = {
  /** what is in tags.jsonl when the session starts; absent means no file */
  file?: string
  /** the write fails */
  failWrite?: boolean
  /** the file is there but reading it fails with this (not a missing file) */
  readError?: string
}

const world = (on: On, { file, failWrite = false, readError }: Machine = {}) => {
  mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/Users/x' })

  const writes: { path: string; text: string }[] = []
  const toasts: string[] = []
  let disk = file

  on('session.start', () => ({ cwd: '/x' }))
  on('session.id', () => ({ value: 's1' }))
  on('session.cwd', () => ({ value: '/Users/x/proj' }))
  on('fs.exists', (_$, e) => ({ value: e.path === FILE && (disk !== undefined || readError !== undefined) }))
  on('fs.read', (_$, e) => {
    if (readError !== undefined) return { deny: readError }

    return e.path === FILE && disk !== undefined ? { value: disk } : { deny: `ENOENT ${e.path}` }
  })
  on('fs.write', (_$, e) => {
    if (failWrite) return { deny: 'EACCES' }

    writes.push({ path: e.path, text: e.text })
    disk = e.text

    return { value: undefined }
  })
  on('ui.toast', (_$, e) => {
    toasts.push(e.text)

    return { value: undefined }
  })
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>engine row</Text>
  })

  return { writes, toasts }
}

const start = ($: any) => $.session.start({ cwd: '/x', surface: 'terminal', isInteractive: true })

const user = ($: any, requestId: string, props: Record<string, unknown> = {}) =>
  $.ui.mount({
    plugin: 'autodream-focus',
    surface: 'terminal',
    component: 'UserMessage',
    requestId,
    props: { text: 'why is the build red?', origin: { kind: 'composer' }, isExpanded: false, ...props },
  })

const reply = ($: any, requestId: string, text = 'The lockfile is stale.') =>
  $.ui.mount({
    plugin: 'autodream-focus',
    surface: 'terminal',
    component: 'AssistantMessage',
    requestId,
    props: { text, isFirstOfReply: true },
  })

/** The button's own Box: hidden until hovered, or shown for good once tagged. */
const shown = async (ui: any) => {
  const tree = JSON.stringify(await ui.drawn())

  return tree.includes('"display":"none"') ? 'hover' : 'always'
}

test('a prompt gets a focus button that waits for the pointer, and the engine row stays', async ($, on) => {
  world(on)
  await start($)

  const ui = await user($, 'r1')

  expect(await ui.find({ key: 'focus-press:r1' })).toBeDefined()
  expect(JSON.stringify(await ui.drawn())).toContain('engine row')
  expect(await shown(ui)).toBe('hover')
})

test('a reply gets one too', async ($, on) => {
  world(on)
  await start($)

  expect(await (await reply($, 'r2')).find({ key: 'focus-press:r2' })).toBeDefined()
})

test('pressing the button writes the turn to tags.jsonl, and it stays shown', async ($, on) => {
  const { writes, toasts } = world(on)
  await start($)

  const ui = await user($, 'r1')

  await ui.press({ key: 'focus-press:r1' })

  expect(writes).toHaveLength(1)
  expect(writes[0]?.path).toBe(FILE)
  expect(writes[0]?.text.endsWith('\n')).toBe(true)
  expect(JSON.parse(writes[0]?.text ?? '')).toEqual({
    id: 's1:r1',
    session: 's1',
    uuid: 'r1',
    role: 'user',
    text: 'why is the build red?',
    cwd: '/Users/x/proj',
    taggedAt: new Date(NOW).toISOString(),
  })
  expect(toasts.join(' ')).toContain('Tagged')
  expect(await shown(ui)).toBe('always')
})

test('a reply is tagged with the assistant role', async ($, on) => {
  const { writes } = world(on)
  await start($)

  await (await reply($, 'r2')).press({ key: 'focus-press:r2' })

  expect(JSON.parse(writes[0]?.text ?? '').role).toBe('assistant')
})

test('pressing a tagged button takes the tag back', async ($, on) => {
  const { writes, toasts } = world(on)
  await start($)

  const ui = await user($, 'r1')

  await ui.press({ key: 'focus-press:r1' })
  await ui.press({ key: 'focus-press:r1' })

  expect(writes.at(-1)?.text).toBe('')
  expect(toasts.at(-1)).toContain('removed')
  expect(await shown(ui)).toBe('hover')
})

test('a tag another session wrote is kept, not overwritten', async ($, on) => {
  const other = JSON.stringify({
    id: 's9:z',
    session: 's9',
    uuid: 'z',
    role: 'user',
    text: 'from another session',
    cwd: '/y',
    day: '2026-10-03',
    taggedAt: '2026-10-03T10:00:00.000Z',
  })
  const { writes } = world(on, { file: `${other}\n` })
  await start($)

  await (await user($, 'r1')).press({ key: 'focus-press:r1' })

  expect(writes[0]?.text.trim().split('\n').map(line => JSON.parse(line).id)).toEqual(['s9:z', 's1:r1'])
})

test('a tag on disk at session start is already lit', async ($, on) => {
  const mine = JSON.stringify({
    id: 's1:r1',
    session: 's1',
    uuid: 'r1',
    role: 'user',
    text: 'why is the build red?',
    cwd: '/x',
    day: '2026-10-03',
    taggedAt: '2026-10-03T10:00:00.000Z',
  })

  world(on, { file: `${mine}\n` })
  await start($)

  expect(await shown(await user($, 'r1'))).toBe('always')
  expect(await shown(await user($, 'r2'))).toBe('hover')
})

test('a notification or a peer message is not the person\'s to tag', async ($, on) => {
  world(on)
  await start($)

  expect(await (await user($, 'n1', { origin: { kind: 'task-notification' } })).find({ key: 'focus-press:n1' })).toBeUndefined()
  expect(await (await user($, 'n2', { origin: { kind: 'peer' } })).find({ key: 'focus-press:n2' })).toBeUndefined()
})

test('a row with no text has nothing to tag', async ($, on) => {
  world(on)
  await start($)

  expect(await (await user($, 'e1', { text: '  ' })).find({ key: 'focus-press:e1' })).toBeUndefined()
})

test('a write that fails says so and does not mark the turn', async ($, on) => {
  const { toasts } = world(on, { failWrite: true })
  await start($)

  const ui = await user($, 'r1')

  await ui.press({ key: 'focus-press:r1' })

  expect(toasts.join(' ')).toContain('Could not save the tag')
  expect(await shown(ui)).toBe('hover')
})

test('a file that is there but will not read is never overwritten', async ($, on) => {
  const { writes, toasts } = world(on, { readError: 'EIO: i/o error' })
  await start($)

  const ui = await user($, 'r1')

  await ui.press({ key: 'focus-press:r1' })

  expect(writes).toHaveLength(0)
  expect(toasts.at(-1)).toContain('nothing was changed')
  expect(await shown(ui)).toBe('hover')
})

test('lines the mod does not understand are written back when it adds a tag', async ($, on) => {
  const foreign = '{"note":"written by hand"}'
  const torn = '{"id":"s9:z","session":"s9"'
  const { writes } = world(on, { file: `${foreign}\n${torn}\n` })
  await start($)

  await (await user($, 'r1')).press({ key: 'focus-press:r1' })

  const lines = writes[0]?.text.trim().split('\n') ?? []

  expect(lines.slice(0, 2)).toEqual([foreign, torn])
  expect(JSON.parse(lines[2] ?? '').id).toBe('s1:r1')
})

test('a long turn is capped so one tag cannot bloat the file', async ($, on) => {
  const { writes } = world(on)
  await start($)

  await (await reply($, 'r3', 'x'.repeat(5_000))).press({ key: 'focus-press:r3' })

  expect(JSON.parse(writes[0]?.text ?? '').text.length).toBeLessThan(2_100)
})
