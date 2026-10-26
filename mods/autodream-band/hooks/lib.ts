import type { DreamPattern, DreamReport } from '../types'

type Parsed = Omit<DreamReport, 'sections' | 'path'>

const DATED = /^(\d{4}-\d{2}-\d{2})\.md$/

/** A report carries `## Triage decisions` once review.sh or a triage session has worked through its questions. */
export const isTriaged = (text: string): boolean => /^## Triage decisions/m.test(text)

/** The newest YYYY-MM-DD.md among a directory's names; logs and backups are not reports. */
export const latestReport = (names: readonly string[]): string | null =>
  names
    .filter(name => DATED.test(name))
    .sort()
    .pop() ?? null

/** One section's body: the lines after its `## ` heading up to the next one. */
const section = (text: string, heading: RegExp): string | null => {
  const lines = text.split('\n')
  const start = lines.findIndex(line => heading.test(line))

  if (start < 0) return null

  const end = lines.findIndex((line, at) => at > start && /^## /.test(line))

  return lines.slice(start + 1, end < 0 ? undefined : end).join('\n')
}

export const parseReport = (text: string): Parsed | null => {
  const date = /^# Autodream\s*[—-]\s*(\d{4}-\d{2}-\d{2})/m.exec(text)?.[1]

  if (date === undefined) return null

  const marker = /<!--\s*autodream:open-questions=(\d+)\s*-->/.exec(text)?.[1]
  const patterns: DreamPattern[] = []

  for (const chunk of (section(text, /^## Top patterns/) ?? '').split(/^### /m).slice(1)) {
    // Backticks are Markdown in the report and literal noise in a one-line band.
    const title = (chunk.split('\n')[0]?.trim() ?? '').replace(/`/g, '')
    const severity = /\*\*Severity\*\*:\s*(\w+)/i.exec(chunk)?.[1]?.toLowerCase() ?? 'unknown'

    if (title !== '') patterns.push({ title, severity })
  }

  return { date, openQuestions: marker === undefined ? 0 : Number(marker), isTriaged: isTriaged(text), patterns }
}

/** Reports are nightly: a few days old is news, a week old is not. */
export const isFresh = (date: string, nowMs: number, maxDays: number): boolean => {
  const [year = 0, month = 1, day = 1] = date.split('-').map(Number)
  const today = new Date(nowMs)
  const dayMs = 86_400_000
  const age = Math.round(
    (new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime() - new Date(year, month - 1, day).getTime()) / dayMs,
  )

  return age <= maxDays
}

/** PROMPT.md asks for high|medium|low; the shipped example report also uses critical, which is worse than high. */
const WORTH_STOPPING_FOR = ['critical', 'high', 'medium']

/**
 * The band is for reports worth stopping for: open questions, or a pattern of medium or higher severity. A report
 * that has been triaged is done, and one that was dismissed stays dismissed.
 */
export const shouldShow = (report: Parsed, dismissed: string | null): boolean =>
  !report.isTriaged &&
  report.date !== dismissed &&
  (report.openQuestions > 0 || report.patterns.some(pattern => WORTH_STOPPING_FOR.includes(pattern.severity)))

/**
 * The walk-through `review.sh` opens a session for, as a prompt for the session you are in. It mirrors
 * review.sh's system prompt (bin/review.sh) with two differences: the report is read rather than
 * inlined, and this session's own permission mode applies, not bypassPermissions.
 */
export const triagePrompt = (date: string, path: string): string =>
  [
    `You are the morning autodream review partner. Triage the open questions from the ${date} autodream report with me, in this session.`,
    '',
    `Read the report first: ${path}. Keep it in context; do not dump it back to me.`,
    '',
    'Workflow:',
    '1. Restate ONE open question (in order, from the report\'s "Open questions for the user" section), in full, before asking me for any decision. I have not read the report this morning, so a bare label ("now question 2") is never enough. Carry (a) the question in plain words, (b) every motivation behind it: findings, session counts, evidence quotes and report section numbers, and (c) every potential fix, each with its trade-off. Ask for the decision only after (a), (b) and (c) are on screen.',
    '2. Say what you checked or could not check since the report was written, if anything.',
    '3. Recommend one concrete action from (c). Be opinionated; I trust your judgment.',
    '4. Wait for: approve / modify / skip / discuss.',
    `5. If approved: execute it. If modified: incorporate the change, confirm, then execute. If skipped or discussed: log the decision as one line under a "## Triage decisions" section at the bottom of ${path} (create it if absent).`,
    '6. Move to the next question. Do not batch questions.',
    '',
    `When every open question is resolved, write a brief summary under "## Triage decisions" in ${path} and stop.`,
    '',
    'Rules:',
    '- Edits to ~/.claude/CLAUDE.md, ~/.claude/rules/*, ~/.claude/docs/guardrails/* and any other global file need my explicit per-edit approval.',
    '- Be terse everywhere except the question restatement in step 1, which is always complete. One question, one decision, one action, then the next.',
  ].join('\n')

/** One shell word, whatever is in it. */
export const shellQuote = (text: string): string => `'${text.replace(/'/g, "'\\''")}'`

/**
 * What gets typed into the new split: review.sh run inline there, so its triage session fills that split rather than
 * handing off to yet another cmux workspace.
 */
export const triageCommandLine = (script: string, date: string, isForced: boolean): string =>
  `env AUTODREAM_TRIAGE_SURFACE=inline bash ${shellQuote(script)} ${isForced ? '--force ' : ''}${date}`

/** The address of the split `cmux new-split` made, from what it printed: a short ref (surface:7) or a UUID. */
export const surfaceRef = (stdout: string): string | null =>
  /\bsurface:\d+\b/.exec(stdout)?.[0] ?? /\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b/i.exec(stdout)?.[0] ?? null

/** The environment variables review.sh reads for its own locations; the mod reads the same ones. */
export type AutodreamEnv = Partial<Record<'HOME' | 'AUTODREAM_DIR' | 'DREAMS_DIR' | 'CMUX_BIN', string | undefined>>

/**
 * Where autodream's pieces are, resolved the way bin/review.sh resolves them: an exported variable wins, an empty one
 * counts as unset, and the defaults are the ones install.sh and review.sh use. A value set only in
 * `$AUTODREAM_DIR/config` is invisible here, so export it (or set it in Claude Code's environment) to move the mod too.
 */
export const locations = (env: AutodreamEnv) => {
  const home = env.HOME ?? ''

  return {
    dreams: env.DREAMS_DIR || `${home}/.claude/dreams`,
    script: `${env.AUTODREAM_DIR || `${home}/.claude/autodream`}/review.sh`,
    cmux: env.CMUX_BIN || '/Applications/cmux.app/Contents/Resources/bin/cmux',
  }
}

/**
 * The command that opens review.sh's own triage session in a cmux workspace: the surface and focus come from the
 * script's documented environment knobs, so nothing in the user's autodream config has to change.
 */
export const cmuxTriage = (script: string, date: string, isForced: boolean) => ({
  argv: ['bash', script, ...(isForced ? ['--force'] : []), date],
  env: { AUTODREAM_TRIAGE_SURFACE: 'cmux', AUTODREAM_TRIAGE_FOCUS: 'true' },
  script,
})

const WANTED = ['Top patterns', 'Open questions']

/** What the pane draws: the sections that ask something of you, within a Markdown element's limit. */
export const keySections = (text: string, limit: number): string => {
  const kept = text
    .split(/^(?=## )/m)
    .filter(block => WANTED.some(heading => block.startsWith(`## ${heading}`)))
    .join('\n')
    .trim()

  return kept.length <= limit ? kept : `${kept.slice(0, limit - 1)}…`
}
