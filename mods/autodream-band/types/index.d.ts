export type DreamPattern = { title: string; severity: string }

/** The newest autodream report, reduced to what the band and pane show. */
export type DreamReport = {
  /** YYYY-MM-DD, the night the report covers */
  date: string
  /** where the report is on disk, for the triage prompt to point at */
  path: string
  openQuestions: number
  /** true once a triage has logged its decisions into the report */
  isTriaged: boolean
  patterns: DreamPattern[]
  /** the report's key sections as markdown, capped to what a Markdown element draws */
  sections: string
}

declare module 'claude-code' {
  interface PluginState {
    'autodream-band': {
      /** null when there is no report, or it is too old, already triaged or dismissed */
      report: DreamReport | null
      /** the report /dream is showing in its pane */
      viewing: DreamReport | null
      isHidden: boolean
    }
  }
}
