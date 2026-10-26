import { expect, test } from 'claude-code/testing'

import type { FocusTag } from '../types'
import { clip, parseFile, serializeFile, tagId, tagsFile, toggleTag } from '../hooks/focus-lib'

const TAG: FocusTag = {
  id: 's1:r1',
  session: 's1',
  uuid: 'r1',
  role: 'assistant',
  text: 'first line\nsecond line with "quotes"',
  cwd: '/Users/x/proj',
  taggedAt: '2026-10-04T18:00:00.000Z',
}

const EMPTY = { tags: [], others: [] }

test('a tag with a multi-line text survives a round trip on one line', () => {
  const text = serializeFile({ tags: [TAG], others: [] })

  expect(text.split('\n').filter(Boolean)).toHaveLength(1)
  expect(parseFile(text)).toEqual({ tags: [TAG], others: [] })
})

test('an empty file serializes to an empty file', () => {
  expect(serializeFile(EMPTY)).toBe('')
})

test('torn, foreign and incomplete lines are not tags, and they are kept as they stood', () => {
  const torn = '{"id":"s1:r1","session":"s1"'
  const foreign = '{"note":"written by hand"}'
  const badRole = JSON.stringify({ ...TAG, id: 's1:bad-role', role: 'system' })
  const text = [torn, 'not json at all', '[1,2,3]', 'null', foreign, badRole, JSON.stringify(TAG), ''].join('\n')

  expect(parseFile(text)).toEqual({ tags: [TAG], others: [torn, 'not json at all', '[1,2,3]', 'null', foreign, badRole] })
})

test('a rewrite hands back every line it did not understand', () => {
  const foreign = '{"note":"written by hand","future":true}'
  const { file } = toggleTag(parseFile(`${foreign}\n`), TAG)
  const again = parseFile(serializeFile(file))

  expect(again.others).toEqual([foreign])
  expect(again.tags).toEqual([TAG])
})

test('a field this version does not know survives a rewrite of its tag', () => {
  const line = JSON.stringify({ ...TAG, label: 'from a later version' })
  const { file } = toggleTag(parseFile(line), { ...TAG, id: 's1:r2', uuid: 'r2' })

  expect(parseFile(serializeFile(file)).tags[0]).toEqual({ ...TAG, label: 'from a later version' })
})

test('a tag without a cwd is read with an empty one', () => {
  const { cwd: _cwd, ...rest } = TAG

  expect(parseFile(JSON.stringify(rest)).tags[0]?.cwd).toBe('')
})

test('toggling adds an untagged turn and removes a tagged one', () => {
  const added = toggleTag(EMPTY, TAG)

  expect(added).toEqual({ file: { tags: [TAG], others: [] }, isTagged: true })
  expect(toggleTag(added.file, TAG)).toEqual({ file: EMPTY, isTagged: false })
})

test('toggling one turn leaves the others alone', () => {
  const other = { ...TAG, id: 's1:r2', uuid: 'r2' }

  expect(toggleTag({ tags: [TAG, other], others: [] }, TAG).file.tags).toEqual([other])
})

test('the same row id in two sessions is two tags', () => {
  expect(tagId('s1', 'r1')).not.toBe(tagId('s2', 'r1'))
})

test('clip leaves short text alone and marks a cut', () => {
  expect(clip('short', 10)).toBe('short')
  expect(clip('abcdefghij', 4)).toBe('abcd…')
})

test('the tags file is next to the rest of autodream, and AUTODREAM_DIR moves it', () => {
  expect(tagsFile({ HOME: '/Users/x' })).toBe('/Users/x/.claude/autodream/tags.jsonl')
  expect(tagsFile({ HOME: '/Users/x', AUTODREAM_DIR: '/opt/ad' })).toBe('/opt/ad/tags.jsonl')
  expect(tagsFile({ HOME: '/Users/x', AUTODREAM_DIR: '' })).toBe('/Users/x/.claude/autodream/tags.jsonl')
})

test('AUTODREAM_TAGS_FILE moves the tags file, as it moves the one bin/vault-notes.sh reads', () => {
  expect(tagsFile({ HOME: '/Users/x', AUTODREAM_DIR: '/opt/ad', AUTODREAM_TAGS_FILE: '/elsewhere/t.jsonl' })).toBe('/elsewhere/t.jsonl')
  expect(tagsFile({ HOME: '/Users/x', AUTODREAM_TAGS_FILE: '' })).toBe('/Users/x/.claude/autodream/tags.jsonl')
})
