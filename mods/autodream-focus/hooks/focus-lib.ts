import type { FocusTag } from '../types'

/** A tagged turn is a pointer plus enough of its text for the nightly note to stand alone. */
export const TEXT_CAP = 2_000

const ROLES: readonly string[] = ['user', 'assistant']

/**
 * Where the tags are, resolved the way bin/vault-notes.sh resolves them: an exported AUTODREAM_TAGS_FILE wins, else AUTODREAM_DIR (an empty
 * one counts as unset) plus tags.jsonl. A value set only in `$AUTODREAM_DIR/config` is invisible here; export it to move the mod too.
 */
export const tagsFile = (env: {
  HOME?: string | undefined
  AUTODREAM_DIR?: string | undefined
  AUTODREAM_TAGS_FILE?: string | undefined
}): string => env.AUTODREAM_TAGS_FILE || `${env.AUTODREAM_DIR || `${env.HOME ?? ''}/.claude/autodream`}/tags.jsonl`

/** One turn, across sessions: the id Claude Code gives the row, under the session that holds it. */
export const tagId = (session: string, uuid: string): string => `${session}:${uuid}`

export const clip = (text: string, max: number): string => (text.length <= max ? text : `${text.slice(0, max)}…`)

const isString = (value: unknown): value is string => typeof value === 'string'

/** One line of tags.jsonl as a tag, or null when it is not one this mod can read. */
const parseTag = (line: string): FocusTag | null => {
  let raw: unknown

  try {
    raw = JSON.parse(line)
  } catch {
    return null
  }

  if (typeof raw !== 'object' || raw === null) return null

  const { id, session, uuid, role, text, cwd, taggedAt } = raw as Record<string, unknown>

  if (!isString(id) || !isString(session) || !isString(uuid) || !isString(role) || !ROLES.includes(role)) return null
  if (!isString(text) || !isString(taggedAt)) return null

  // Fields this version does not know ride along, so a rewrite does not strip what a later version added.
  return { ...raw, id, session, uuid, role: role as FocusTag['role'], text, cwd: isString(cwd) ? cwd : '', taggedAt }
}

/**
 * What tags.jsonl holds: the tags this mod reads, and every other non-blank line as it stood. A rewrite has to hand
 * those back, because they are somebody's (a hand edit, a field a later version added, a line torn by a crash), and
 * bin/vault-notes.sh skips what it cannot read anyway.
 */
export type TagFile = { tags: FocusTag[]; others: string[] }

export const parseFile = (text: string): TagFile => {
  const file: TagFile = { tags: [], others: [] }

  for (const line of text.split('\n')) {
    if (line.trim() === '') continue

    const tag = parseTag(line)

    if (tag === null) file.others.push(line)
    else file.tags.push(tag)
  }

  return file
}

/** JSON.stringify keeps each tag on one line, newlines in the text included. */
export const serializeFile = ({ tags, others }: TagFile): string => {
  const lines = [...others, ...tags.map(tag => JSON.stringify(tag))]

  return lines.length === 0 ? '' : `${lines.join('\n')}\n`
}

/** The button is a toggle: a second press on a tagged turn takes the tag back. */
export const toggleTag = (file: TagFile, tag: FocusTag): { file: TagFile; isTagged: boolean } =>
  file.tags.some(existing => existing.id === tag.id)
    ? { file: { ...file, tags: file.tags.filter(existing => existing.id !== tag.id) }, isTagged: false }
    : { file: { ...file, tags: [...file.tags, tag] }, isTagged: true }
