/** A turn the person marked with the focus button, as tags.jsonl holds it; bin/vault-notes.sh reads the same shape. */
export type FocusTag = {
  /** `<session id>:<row id>`, unique across sessions */
  id: string
  session: string
  /** the id Claude Code gave the row when it drew it */
  uuid: string
  role: 'user' | 'assistant'
  /** the turn's text, capped, so the nightly note stands alone */
  text: string
  cwd: string
  /**
   * UTC, ISO 8601. The only clock the file carries: the mod's environment has no timezone, so the report day a tag
   * belongs to is decided by bin/vault-notes.sh, which does.
   */
  taggedAt: string
}

declare module 'claude-code' {
  interface PluginState {
    'autodream-focus': {
      /** ids of the turns tagged so far, read from tags.jsonl at session start and after every press */
      tagged: string[]
    }
  }
}
