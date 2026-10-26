import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { DreamReport } from '../types'
import {
  cmuxTriage,
  isFresh,
  keySections,
  latestReport,
  locations,
  parseReport,
  shouldShow,
  surfaceRef,
  triageCommandLine,
  triagePrompt,
} from './lib'

const PANE = 'dream'

const report = atom({ plugin: 'autodream-band', key: 'report' } as const, null)
const viewing = atom({ plugin: 'autodream-band', key: 'viewing' } as const, null)
const isHidden = atom({ plugin: 'autodream-band', key: 'isHidden' } as const, false)

/** Where the reports, review.sh and cmux are: review.sh's own environment knobs, then its defaults. */
const where = async ($: EngineInterface) => {
  const [HOME, AUTODREAM_DIR, DREAMS_DIR, CMUX_BIN] = await Promise.all([
    $.env.get('HOME'),
    $.env.get('AUTODREAM_DIR'),
    $.env.get('DREAMS_DIR'),
    $.env.get('CMUX_BIN'),
  ])

  return locations({ HOME, AUTODREAM_DIR, DREAMS_DIR, CMUX_BIN })
}

/** The newest report on disk, whether or not the band would show it. */
const load = async ($: EngineInterface): Promise<DreamReport | null> => {
  try {
    const { dreams: dir } = await where($)
    const name = latestReport((await $.fs.list(dir)).map(entry => entry.name))

    if (name === null) return null

    const path = `${dir}/${name}`
    const text = await $.fs.read(path)
    const parsed = typeof text === 'string' ? parseReport(text) : null

    return parsed === null || typeof text !== 'string' ? null : { ...parsed, path, sections: keySections(text, 9_500) }
  } catch {
    return null
  }
}

/** Why there is nothing to show: no report at all, or one the band cannot read (a title it does not recognise). */
const explainNoReport = async ($: EngineInterface): Promise<string> => {
  const { dreams } = await where($)
  const name = await $.fs.list(dreams).then(
    entries => latestReport(entries.map(entry => entry.name)),
    () => null,
  )

  return name === null
    ? `No autodream report found in ${dreams}.`
    : `Found ${dreams}/${name}, but it is not in the format the band reads: it needs a "# Autodream — YYYY-MM-DD" title.`
}

const dismissedDate = async ($: EngineInterface): Promise<string | null> => {
  const date = await $.store.get('dismissed')

  return typeof date === 'string' ? date : null
}

const refresh = async ($: EngineInterface) => {
  const [latest, now, dismissed] = await Promise.all([load($), $.clock.now(), dismissedDate($)])

  await update($, report, () => (latest !== null && isFresh(latest.date, now, 2) && shouldShow(latest, dismissed) ? latest : null))
}

const dismiss = async ($: EngineInterface) => {
  const shown = await read($, report)

  if (shown === null) return

  await $.store.set('dismissed', shown.date)
  await update($, report, () => null)
}

const open = async ($: EngineInterface, latest: DreamReport) => {
  await update($, viewing, () => latest)
  await $.ui.open({ id: PANE, title: 'Autodream', focus: true, closeOnEscape: true })
}

const plural = (n: number, noun: string) => `${n} ${noun}${n === 1 ? '' : 's'}`

/** Whether there is anything for a triage to do: review.sh's own rule, which `force` overrides. */
const nothingToTriage = (latest: DreamReport, isForced: boolean): string | null => {
  if (isForced) return null

  if (latest.isTriaged) return `${latest.date} is already triaged. /dream triage force opens it again.`

  return latest.openQuestions === 0 ? `${latest.date} has no open questions, so there is nothing to triage. /dream triage force starts anyway.` : null
}

/**
 * Starts review.sh's walk-through in this session. The prompt goes from a timer: the call resolves when the new turn
 * starts, and a call begun in a dispatch (a press, a command) is dropped when that dispatch ends.
 */
const triageHere = ($: EngineInterface, latest: DreamReport, isForced: boolean): string => {
  const blocked = nothingToTriage(latest, isForced)

  if (blocked !== null) return blocked

  $.clock.after(100, () => {
    $.prompt.submit({ text: triagePrompt(latest.date, latest.path) }).catch(() => {})
  })

  return `Starting triage of the ${latest.date} report here: one open question at a time.`
}

/** Opens review.sh's own triage session in a cmux workspace and reports what the script said. */
const triageInCmux = async ($: EngineInterface, latest: DreamReport, isForced: boolean): Promise<string> => {
  const { script } = await where($)
  const { argv, env } = cmuxTriage(script, latest.date, isForced)

  if (!(await $.fs.exists(script))) {
    return `autodream's review.sh was not found at ${script}. Install cc-autodream, or use /dream triage to do it in this session.`
  }

  try {
    const { exitCode, stdout, stderr } = await $.process.run(argv, { env, timeoutMs: 20_000 })
    const said = (exitCode === 0 ? stdout : stderr || stdout).trim().slice(0, 400)

    return exitCode === 0 ? said || 'review.sh ran.' : `review.sh exited ${exitCode}: ${said}`
  } catch (cause) {
    return `review.sh could not run: ${cause instanceof Error ? cause.message : String(cause)}`
  }
}

/**
 * The default way to triage: review.sh's own session in a split beside this one, so this conversation stays about
 * what it was about. cmux's `new-split` and `send` default to the surface this session runs in. Every way it can
 * go wrong has a fallback: no readable split address or a failed send opens a cmux workspace instead; outside cmux
 * there is nothing to split, so review.sh opens the workspace itself; no cmux or no review.sh means this session.
 */
const triageBeside = async ($: EngineInterface, latest: DreamReport, isForced: boolean): Promise<string> => {
  const blocked = nothingToTriage(latest, isForced)

  if (blocked !== null) return blocked

  const { script, cmux } = await where($)

  if (!(await $.fs.exists(cmux))) {
    return `cmux was not found, so triage runs in this session. ${triageHere($, latest, isForced)}`
  }

  if (!(await $.fs.exists(script))) {
    return `autodream's review.sh was not found at ${script}, so triage runs in this session. ${triageHere($, latest, isForced)}`
  }

  const surface = await $.env.get('CMUX_SURFACE_ID')

  if (surface === undefined || surface === '') return triageInCmux($, latest, isForced)

  try {
    const made = await $.process.run([cmux, 'new-split', 'right', '--focus', 'true'], { timeoutMs: 15_000 })
    const ref = made.exitCode === 0 ? surfaceRef(made.stdout) : null

    if (ref !== null) {
      // cmux reads a backslash-n in the text as Enter.
      const typed = await $.process.run([cmux, 'send', '--surface', ref, '--', `${triageCommandLine(script, latest.date, isForced)}\\n`], {
        timeoutMs: 15_000,
      })

      if (typed.exitCode === 0) return `Opened the ${latest.date} triage in a split to the right: a fresh session with the report preloaded.`
    }
  } catch {
    // fall through to the workspace
  }

  const said = await triageInCmux($, latest, isForced)

  return `Could not open a split beside this session, so ${said.charAt(0).toLowerCase()}${said.slice(1)}`
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'dream',
      description: 'Read the newest autodream report; /dream triage opens its open questions in a split beside this session',
      argumentHint: '[triage|here|cmux] [force]',
    })
    await refresh($)
    // A session can outlive the night; check again for a fresh report.
    $.clock.every(30 * 60_000, () => refresh($))

    return next(e)
  })

  // A triage ends by logging its decisions into the report; the turn that ends it clears the band.
  on('turn.complete', async ($, e, next) => {
    await refresh($)

    return next(e)
  })

  on('command.run', { command: 'dream' }, async ($, e) => {
    const [action = '', ...flags] = e.args.trim().split(/\s+/)
    const latest = await load($)

    if (latest === null) return { text: await explainNoReport($) }

    const isForced = flags.includes('force')

    if (action === 'triage') return { text: await triageBeside($, latest, isForced) }

    if (action === 'here') return { text: triageHere($, latest, isForced) }

    if (action === 'cmux') return { text: await triageInCmux($, latest, isForced) }

    await open($, latest)

    return {
      text: `Autodream ${latest.date}: ${plural(latest.openQuestions, 'open question')}, ${plural(latest.patterns.length, 'pattern')}${latest.isTriaged ? ', triaged' : ''}. Opened in the pane.`,
    }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Markdown, Text } = $.ui.resolve(e)
    const shown = await read($, viewing)

    if (shown === null) return <Text dimColor>No report loaded.</Text>

    const canTriage = !shown.isTriaged && shown.openQuestions > 0

    return (
      <Box flexDirection="column">
        <Markdown text={shown.sections === '' ? `No patterns or questions in the ${shown.date} report.` : shown.sections} />
        {shown.isTriaged && <Text dimColor>Triaged: decisions are logged at the bottom of the report.</Text>}
        <Box gap={2}>
          {canTriage && (
            <Button
              key="triage"
              label="Triage in a side window"
              variant="primary"
              hotkey="t"
              onPress={async () => $.ui.toast(await triageBeside($, shown, false))}
            />
          )}
          {canTriage && <Button key="here" label="Triage here" hotkey="h" onPress={() => $.ui.toast(triageHere($, shown, false))} />}
          <Button key="close" label="Close" role="dismiss" hotkey="c" onPress={() => $.ui.close({ id: PANE })} />
        </Box>
      </Box>
    )
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const shown = await read($, report)

    if (e.props.hasSurvey || shown === null || (await read($, isHidden))) return next(e)

    const { Box, Button, Text } = $.ui.resolve(e)
    const top = shown.patterns[0]
    const parts = [
      ...(shown.openQuestions > 0 ? [plural(shown.openQuestions, 'open question')] : []),
      ...(top === undefined ? [] : [`top pattern: ${top.title}`]),
    ]
    // Other plugins and the engine draw in this slot too: stack under them rather than replace them.
    const beneath = await next(e)

    return (
      <Box flexDirection="column">
        {beneath}
        {/* One row: the summary takes what room the buttons leave and ends in an ellipsis rather than wrapping around them. */}
        <Box key="band" gap={1}>
          <Box flexGrow={1} flexShrink={1}>
            <Text dimColor wrap="truncate-end">{`🌙 Autodream ${shown.date}: ${parts.join(' · ')}`}</Text>
          </Box>
          <Box flexShrink={0} gap={1}>
            {shown.openQuestions > 0 && (
              <Button key="triage" label="Triage" variant="primary" onPress={async () => $.ui.toast(await triageBeside($, shown, false))} />
            )}
            <Button key="view" label="View" onPress={() => open($, shown)} />
            <Button key="dismiss" label="Dismiss" dimColor onPress={() => dismiss($)} />
          </Box>
        </Box>
      </Box>
    )
  })
}
