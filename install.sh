#!/bin/bash
# cc-autodream installer.
#
# Symlinks the scripts + prompts from this repo into ~/.claude/autodream/ and (on
# macOS) installs the nightly launchd schedule so overnight runs Just Work.
# Idempotent — safe to re-run.
#
# Usage:
#   ./install.sh                 # symlink into $HOME/.claude/ + schedule nightly job
#   ./install.sh /path/to        # symlink into /path/to/autodream/ instead
#   ./install.sh --no-schedule   # symlink only; don't touch launchd
#   ./install.sh --no-review     # schedule the nightly but not the review triage popup agent
#   ./install.sh --no-skill      # don't link the global /autodream skill into ~/.claude/skills
#   ./install.sh --adapters claude,omp   # harnesses a run scans (names or `all`); written to config
#   ./install.sh --l2-engine omp         # adapter whose engine runs L2; written to config
#   ./install.sh --dry-run       # show every change, make none (no links, config, plist, launchctl)
#   ./install.sh -h|--help

set -eu

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# ----------------------------------------------------------------- arg parsing --
SCHEDULE=1
REVIEW=1
SKILL=1
DRY=0
ADAPTERS_ARG=""
L2_ENGINE_ARG=""
TARGET_PARENT="$HOME/.claude"
while [ "$#" -gt 0 ]; do
  a="$1"; shift
  case "$a" in
    --no-schedule) SCHEDULE=0 ;;
    --no-review) REVIEW=0 ;;
    --no-skill) SKILL=0 ;;
    --dry-run) DRY=1 ;;
    --adapters|--l2-engine)
      [ "$#" -gt 0 ] && [ -n "$1" ] || { echo "install: $a needs a value" >&2; exit 64; }
      case "$a" in --adapters) ADAPTERS_ARG="$1" ;; *) L2_ENGINE_ARG="$1" ;; esac
      shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    -*) echo "install: unknown flag '$a'" >&2; exit 64 ;;
    *) TARGET_PARENT="$a" ;;
  esac
done
TARGET="$TARGET_PARENT/autodream"

# Every adapter name given must be a directory under adapters/ (or `all` for --adapters): a typo
# written into the config would make the nightly enable nothing and refuse to scan.
valid_adapter() { [ -d "$REPO_DIR/adapters/$1" ] && [ -f "$REPO_DIR/adapters/$1/manifest.json" ]; }
if [ -n "$ADAPTERS_ARG" ]; then
  ADAPTERS_ARG=$(printf '%s' "$ADAPTERS_ARG" | tr ' ' ',')
  for _n in $(printf '%s' "$ADAPTERS_ARG" | tr ',' ' '); do
    [ "$_n" = "all" ] && continue
    case "$_n" in *[!a-z0-9_-]*|_*) echo "install: '$_n' is not a valid adapter name" >&2; exit 64 ;; esac
    valid_adapter "$_n" || { echo "install: no adapter '$_n' under $REPO_DIR/adapters" >&2; exit 64; }
  done
fi
if [ -n "$L2_ENGINE_ARG" ]; then
  valid_adapter "$L2_ENGINE_ARG" || { echo "install: no adapter '$L2_ENGINE_ARG' under $REPO_DIR/adapters" >&2; exit 64; }
fi

# Dry run: the same code path, with every write replaced by a line saying what it would do.
# Anything that only READS (the label ownership check, the cmux and claude lookups, the
# validations in link) still runs, so a dry run reports the refusals a real install would hit.
dry() { printf '  [dry-run] %s\n' "$*"; }
# One scratch directory for the generated plists, removed on every exit path.
DRY_SCRATCH=""
if [ "$DRY" = 1 ]; then
  DRY_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/ccad-dry.XXXXXX")
  trap 'rm -rf "$DRY_SCRATCH"' EXIT
fi
if [ "$DRY" = 1 ]; then
  echo "DRY RUN: nothing below is written, linked, loaded or run."
  dry "mkdir -p $TARGET $TARGET_PARENT/dreams $TARGET/findings $TARGET/inbox $TARGET/logs"
else
  mkdir -p "$TARGET" "$TARGET_PARENT/dreams" "$TARGET/findings" "$TARGET/inbox" "$TARGET/logs"
fi

link() {
  local src="$1" dst="$2"
  # Never create a dangling symlink. A link pointing at a file the checked-out tree
  # does not have looks installed and silently does nothing at 03:15 — that is the
  # overlap-stats.sh failure from 2026-07-24, and it cost a night of data before
  # anyone noticed. Say so loudly and leave the old link alone instead.
  if [ ! -e "$src" ]; then
    echo "  WARNING: skipping $dst — source missing: $src" >&2
    return 0
  fi
  # A real DIRECTORY at $dst is the case this guard used to miss, and adapters/
  # is the first directory this script links. Without it `ln -s` silently creates
  # $dst/<basename> — a nested adapters/adapters — while printing the same
  # success line, after which the loader finds an empty directory, rejects the
  # nested link on containment, and every nightly run fails.
  if [ "$DRY" = 1 ]; then
    if [ -d "$dst" ] && [ ! -L "$dst" ] && [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
      echo "  ERROR: $dst is a non-empty real directory; refusing to install over it." >&2
      return 1
    fi
    dry "link $dst -> $src"
    return 0
  fi
  if [ -L "$dst" ] || [ -f "$dst" ]; then
    rm -f "$dst"
  elif [ -d "$dst" ]; then
    if [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
      # A hard failure, not a warning. Warning and returning 0 reported a
      # successful install while leaving adapters_root() pointed at a directory
      # the loader accepts nothing from — which takes the "loader accepted no
      # adapters" fatal on every nightly run afterward. A total outage behind one
      # line of install output is the exact shape this whole change is built to
      # refuse.
      echo "  ERROR: $dst is a non-empty real directory; refusing to install over it." >&2
      echo "         Move or remove it, then re-run install.sh." >&2
      return 1
    fi
    rmdir "$dst" 2>/dev/null || {
      # return 1, like the non-empty branch above and for the same reason: warning
      # and continuing reports a successful install while adapters_root() resolves
      # to a directory the loader accepts nothing from, which is the "loader
      # accepted no adapters" fatal on every nightly run afterward.
      echo "  ERROR: could not remove existing directory $dst; refusing to continue." >&2
      return 1
    }
  fi
  ln -s "$src" "$dst" || return 1
  echo "  $dst -> $src"
}

echo "Installing cc-autodream into $TARGET"
link "$REPO_DIR/bin/run.sh"             "$TARGET/run.sh"
link "$REPO_DIR/bin/autodream-now.sh"   "$TARGET/autodream-now.sh"
link "$REPO_DIR/bin/autodream-note.sh"  "$TARGET/autodream-note.sh"
link "$REPO_DIR/bin/review.sh"          "$TARGET/review.sh"
link "$REPO_DIR/bin/notify.sh"          "$TARGET/notify.sh"
link "$REPO_DIR/bin/make-notifier.sh"   "$TARGET/make-notifier.sh"
link "$REPO_DIR/bin/prune-self-sessions.sh" "$TARGET/prune-self-sessions.sh"
link "$REPO_DIR/bin/slim-transcript.sh"     "$TARGET/slim-transcript.sh"
link "$REPO_DIR/bin/session-stats.sh"        "$TARGET/session-stats.sh"
link "$REPO_DIR/bin/session-window.sh"       "$TARGET/session-window.sh"
link "$REPO_DIR/bin/chunk-transcript.sh"      "$TARGET/chunk-transcript.sh"
link "$REPO_DIR/bin/merge-chunks.sh"           "$TARGET/merge-chunks.sh"
link "$REPO_DIR/bin/overlap-stats.sh"        "$TARGET/overlap-stats.sh"
link "$REPO_DIR/bin/scheduler-label.sh"      "$TARGET/scheduler-label.sh"
link "$REPO_DIR/bin/oversized-gate.sh"       "$TARGET/oversized-gate.sh"
link "$REPO_DIR/bin/failure-class.sh"        "$TARGET/failure-class.sh"
link "$REPO_DIR/bin/portable.sh"             "$TARGET/portable.sh"
link "$REPO_DIR/bin/citation-check.sh"       "$TARGET/citation-check.sh"
link "$REPO_DIR/bin/triage-dream.sh"         "$TARGET/triage-dream.sh"
link "$REPO_DIR/bin/dream-grounding.sh"      "$TARGET/dream-grounding.sh"
link "$REPO_DIR/bin/cookie-cadence.sh"       "$TARGET/cookie-cadence.sh"
link "$REPO_DIR/bin/vault-notes.sh"          "$TARGET/vault-notes.sh"
link "$REPO_DIR/bin/x-bookmarks.sh"          "$TARGET/x-bookmarks.sh"
link "$REPO_DIR/bin/prune-worktrees.sh"      "$TARGET/prune-worktrees.sh"
link "$REPO_DIR/bin/triage-candidates.sh"    "$TARGET/triage-candidates.sh"
link "$REPO_DIR/bin/question-streaks.sh"     "$TARGET/question-streaks.sh"
link "$REPO_DIR/bin/apply-pins.sh"           "$TARGET/apply-pins.sh"
link "$REPO_DIR/bin/root-probe.sh"           "$TARGET/root-probe.sh"
link "$REPO_DIR/bin/lib-project.sh"           "$TARGET/lib-project.sh"
link "$REPO_DIR/bin/lib-install-dir.sh"       "$TARGET/lib-install-dir.sh"
link "$REPO_DIR/bin/adapters.sh"              "$TARGET/adapters.sh"
link "$REPO_DIR/bin/preflight.sh"             "$TARGET/preflight.sh"
link "$REPO_DIR/bin/report-format.sh"          "$TARGET/report-format.sh"
link "$REPO_DIR/bin/l2-prompt.sh"              "$TARGET/l2-prompt.sh"
link "$REPO_DIR/bin/pending-triage.sh"        "$TARGET/pending-triage.sh"
# The adapters TREE, not individual files: run.sh resolves adapters/<name>/adapter.sh
# relative to the script dir, so the whole directory has to be reachable from the
# install target. Without this the installed runner silently takes the legacy inline
# enumeration path and gets no preflight, while still reporting adapters_enabled.
link "$REPO_DIR/adapters"                     "$TARGET/adapters"
link "$REPO_DIR/prompts/PROMPT.md"      "$TARGET/PROMPT.md"
link "$REPO_DIR/prompts/SESSION_TRIAGE.md" "$TARGET/SESSION_TRIAGE.md"
link "$REPO_DIR/prompts/TRIAGE_DREAM.md"   "$TARGET/TRIAGE_DREAM.md"
link "$REPO_DIR/prompts/L2_SYSTEM.txt"      "$TARGET/L2_SYSTEM.txt"

# The global /autodream skill. A skill nobody asked for must not fail the install, so a
# directory already sitting at the link's place (the user's own /autodream) is reported and left.
# Claude Code reads ~/.claude/skills, and the skill calls the scripts at ~/.claude/autodream unless
# AUTODREAM_DIR says otherwise. A custom install dir would leave a skill that cannot find them,
# so it is linked only when AUTODREAM_SKILLS_DIR says where the user wants it.
if [ "$SKILL" = 1 ] && [ -z "${AUTODREAM_SKILLS_DIR:-}" ] && [ "$(printf '%s' "$TARGET_PARENT" | sed 's:/*$::')" != "$HOME/.claude" ]; then
  echo "  /autodream skill not linked: $TARGET_PARENT is not ~/.claude. Set AUTODREAM_SKILLS_DIR to link it, and export AUTODREAM_DIR=$TARGET."
elif [ "$SKILL" = 1 ]; then
  SKILLS_DIR="${AUTODREAM_SKILLS_DIR:-$HOME/.claude/skills}"
  if [ "$DRY" = 1 ]; then dry "mkdir -p $SKILLS_DIR"; else mkdir -p "$SKILLS_DIR"; fi
  # A skill the user already has at this name (their own link or directory) is theirs: only an
  # earlier link to this repo's skill is replaced.
  if { [ -e "$SKILLS_DIR/autodream" ] || [ -L "$SKILLS_DIR/autodream" ]; } \
     && [ "$(readlink "$SKILLS_DIR/autodream" 2>/dev/null)" != "$REPO_DIR/skills/autodream" ]; then
    echo "  /autodream skill not linked: $SKILLS_DIR/autodream already exists and is not this repo's. Move it, then re-run install.sh." >&2
  else
    link "$REPO_DIR/skills/autodream" "$SKILLS_DIR/autodream" || echo "  WARNING: /autodream skill not linked (see above); re-run after moving $SKILLS_DIR/autodream" >&2
  fi
fi

if [ "$DRY" = 1 ]; then dry "chmod +x bin/*.sh adapters/*/adapter.sh"; else
chmod +x "$REPO_DIR/bin/"*.sh
# The adapters too. _adapter_ok requires -x on adapter.sh, and the loader treats a
# non-executable adapter as a REFUSAL rather than as "adapters absent" — so a
# distribution path that loses the exec bit (a zip, a restrictive umask) turns
# into a hard FATAL nightly with no report instead of a degraded run.
chmod +x "$REPO_DIR/adapters/"*/adapter.sh 2>/dev/null || true
fi

# --------------------------------------------------- session roots --
# autodream scans every $HOME/.claude*/projects dir that has a session store. At
# install time we detect them, ask about the ones the user hasn't decided on yet, and
# record the decision in root-choices.conf so the nightly run stays unattended. On a
# non-TTY install (CI, an automated shell), unasked roots default to indexed so the
# install silently covers everything; the log line says what was chosen. The
# SESSION_ROOTS line below is the managed section run.sh sources.
if [ "$DRY" = 1 ]; then
  dry "root-probe --default-index, then rewrite the managed SESSION_ROOTS section of $TARGET/config"
elif [ -x "$TARGET/root-probe.sh" ]; then
  CONFIG="$TARGET/config"
  if [ -t 1 ]; then
    AUTODREAM_DIR="$TARGET" "$TARGET/root-probe.sh" --ask
  else
    echo "  non-interactive install: indexing any unasked Claude folders (edit root-choices.conf to change)"
    AUTODREAM_DIR="$TARGET" "$TARGET/root-probe.sh" --default-index
  fi
  # Insert/replace the managed section. A prior line (or lines) under the marker is
  # removed so re-installs converge instead of stacking SESSION_ROOTS definitions.
  if [ -f "$CONFIG" ]; then
    awk '
      /^# claude-folder-indexing/{skip=1; next}
      skip && /^SESSION_ROOTS=/{next}
      skip && /^[^#]/{skip=0}
      {print}
    ' "$CONFIG" > "$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  fi
  { echo; AUTODREAM_DIR="$TARGET" "$TARGET/root-probe.sh" --write-config; } >> "$CONFIG"
  echo "  session roots written to $CONFIG (see root-choices.conf to adjust)"
fi

# Build the rebranded "cc-autodream" notifier bundle so open-questions banners show up
# under that name instead of "terminal-notifier". No-op if terminal-notifier isn't
# installed (notify.sh falls back to plain terminal-notifier / an osascript banner) or
# if the bundle already exists. notify.sh also bootstraps this on first run.
if [ "$DRY" = 1 ]; then dry "build the notifier bundle (make-notifier.sh)"; else
AUTODREAM_DIR="$TARGET" "$REPO_DIR/bin/make-notifier.sh" || true
fi

# --------------------------------------------------- adapters and L2 engine --
# A managed section of the config, replaced in place so a re-install converges. Absent flags leave
# the section alone: re-running the installer must not silently drop a host's choice. run.sh
# sources the config with the caller's environment winning, so a variable exported by a caller
# still beats these.
if [ -n "$ADAPTERS_ARG" ] || [ -n "$L2_ENGINE_ARG" ]; then
  CONFIG="$TARGET/config"
  # The key whose flag is absent keeps its present value: re-running with one flag must not drop
  # the host's other choice.
  if [ -f "$CONFIG" ]; then
    [ -n "$ADAPTERS_ARG" ] || ADAPTERS_ARG=$(sed -n 's/^AUTODREAM_ADAPTERS=//p' "$CONFIG" | tail -n 1)
    [ -n "$L2_ENGINE_ARG" ] || L2_ENGINE_ARG=$(sed -n 's/^AUTODREAM_L2_ENGINE=//p' "$CONFIG" | tail -n 1)
  fi
  if [ "$DRY" = 1 ]; then
    dry "write to $CONFIG: ${ADAPTERS_ARG:+AUTODREAM_ADAPTERS=$ADAPTERS_ARG }${L2_ENGINE_ARG:+AUTODREAM_L2_ENGINE=$L2_ENGINE_ARG}"
  else
    touch "$CONFIG"
    awk '
      /^# adapters \(managed by install.sh\)/{skip=1; next}
      skip && /^(AUTODREAM_ADAPTERS|AUTODREAM_L2_ENGINE)=/{next}
      skip && /^[^#]/{skip=0}
      {print}
    ' "$CONFIG" > "$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
    {
      echo
      echo "# adapters (managed by install.sh)"
      [ -n "$ADAPTERS_ARG" ] && echo "AUTODREAM_ADAPTERS=$ADAPTERS_ARG"
      [ -n "$L2_ENGINE_ARG" ] && echo "AUTODREAM_L2_ENGINE=$L2_ENGINE_ARG"
    } >> "$CONFIG"
    echo "  adapters written to $CONFIG"
  fi
fi

# --------------------------------------------------- nightly launchd schedule --
# Builds and bootstraps a LaunchAgent that runs run.sh on several morning triggers
# (catch-up for a Mac asleep at 03:15; the idempotency guard no-ops all but the
# first to complete). Everything is auto-detected — no REPLACE_WITH_USERNAME edit.
# launchctl, or a line saying what it would have been asked to do.
lctl() {
  if [ "$DRY" = 1 ]; then dry "launchctl $*"; return 0; fi
  launchctl "$@"
}
# In a dry run, show the plist that would be installed and where.
show_plist() { # $1=generated file
  [ "$DRY" = 1 ] || return 0
  dry "would write $real_la_dir/$(basename "$1"):"
  sed 's/^/        /' "$1"
}

# A directory under a temp location belongs to the shell that ran the installer: a tool shim (cmux
# puts one ahead of PATH in every terminal it opens), a per-session scratch dir. It is gone by the
# time launchd runs the job, so a PATH entry or a CLAUDE_BIN taken from one rots the schedule with
# no error. AUTODREAM_EPHEMERAL_DIRS replaces the colon-separated prefix list; set but empty turns
# the check off (the test suites build their fake tools under TMPDIR).
ephemeral_dir() { # $1=dir -> 0 when it lives under a temp location
  local d p pr list
  list="${AUTODREAM_EPHEMERAL_DIRS-${TMPDIR:-}:/tmp:/private/tmp:/var/folders:/private/var/folders}"
  [ -n "$list" ] || return 1
  d=$(cd "$1" 2>/dev/null && pwd -P) || d="$1"
  local IFS=:
  for p in $list; do
    [ -n "$p" ] || continue
    pr=$(cd "$p" 2>/dev/null && pwd -P) || pr="$p"
    [ -n "${pr%/}" ] || continue
    case "$d/" in "${pr%/}"/*) return 0 ;; esac
  done
  return 1
}

# A value from the install's config, resolved the way run.sh resolves it: by sourcing the file, so
# `export KEY=value`, quotes and later assignments all read as they will at run time.
cfg_get() { # $1=variable name
  [ -f "$TARGET/config" ] || return 0
  bash -c 'unset "$2"; . "$1" >/dev/null 2>&1; v="$2"; printf "%s" "${!v:-}"' _ "$TARGET/config" "$1"
}

# The directories of the CLIs the nightly runs, one per line: every enabled adapter's, and the L2
# engine's (a host can scan claude and run L2 on omp). launchd starts the job with no login shell,
# so a CLI that lives outside the usual dirs (omp in ~/.bun/bin) is unreachable unless its directory
# is in the plist PATH. <NAME>_BIN from the config, when it names an executable, wins over the PATH
# lookup, as the adapters resolve it at run time; the installer's own environment does not count,
# because launchd will not carry it.
adapter_bin_dirs() { # $1=PATH to search
  local list="$ADAPTERS_ARG" l2="$L2_ENGINE_ARG" a m
  [ -n "$list" ] || list=$(cfg_get AUTODREAM_ADAPTERS)
  [ -n "$l2" ] || l2=$(cfg_get AUTODREAM_L2_ENGINE)
  list=$(printf '%s' "${list:-claude}" | tr -d "\"'" | tr ',' ' ')
  for a in $list; do
    if [ "$a" = all ]; then
      for m in "$REPO_DIR"/adapters/*/manifest.json; do
        [ -e "$m" ] || continue
        adapter_bin_dirs_one "$(basename "$(dirname "$m")")" "$1"
      done
    else
      adapter_bin_dirs_one "$a" "$1"
    fi
  done
  [ -z "$l2" ] || adapter_bin_dirs_one "$(printf '%s' "$l2" | tr -d "\"'")" "$1"
}
adapter_bin_dirs_one() { # $1=adapter name  $2=PATH to search
  local m="$REPO_DIR/adapters/$1/manifest.json" bin var override="" b
  # The name reaches an indirect expansion below; the same character set the --adapters
  # flag enforces keeps a hand-edited config from putting anything else there.
  case "$1" in ""|_*|*[!a-z0-9_-]*) return 0 ;; esac
  [ -f "$m" ] || return 0
  bin=$(sed -n 's/.*"engine_bin"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$m" | head -n 1)
  [ -n "$bin" ] || return 0
  var="$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')_BIN"
  override=$(cfg_get "$var")
  if [ -n "$override" ] && [ -f "$override" ] && [ -x "$override" ] && [ "${override#/}" != "$override" ] \
     && ! ephemeral_dir "$(dirname "$override")"; then
    dirname "$override"; return 0
  fi
  b=$(PATH="$2" command -v "$bin" 2>/dev/null) || return 0
  case "$b" in /*) dirname "$b" ;; esac
}

install_schedule() {
  local la_dir="$HOME/Library/LaunchAgents" real_la_dir
  real_la_dir="$la_dir"
  if [ "$DRY" = 1 ]; then
    # Generate and lint the plists in a scratch dir, so the dry run shows exactly what would be
    # written without touching the real LaunchAgents directory. The ownership check below still
    # reads the real one.
    la_dir="$DRY_SCRATCH"
  else
    mkdir -p "$la_dir"
  fi

  # Which label this install owns. scheduler-label.sh reuses our own prior label when
  # there is one (so a re-install stays idempotent), never adopts a plist that runs
  # someone else's run.sh, and exits 3 rather than overwrite a foreign job holding our
  # default name. Matching on the string "run.sh" alone took over another install's job
  # and left it dead for 18 days (omp-autodream#14, https://github.com/STRML/cc-autodream/issues/60).
  local label="" rc=0
  label="$("$REPO_DIR/bin/scheduler-label.sh" "$TARGET")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  Skipping the schedule. Fix the conflict above, or re-run with --no-schedule." >&2
    return "$rc"
  fi

  # launchd agents start with a minimal PATH; seed it with the dirs of the tools
  # the pipeline shells out to (claude, git, bash) plus the usual suspects.
  local path_dirs="" tool b d CLAUDE_BIN_ABS="" clean_path="" skipped_dirs="" old_ifs="$IFS"
  # Resolve every tool against PATH minus the temp-dir entries, so neither the plist PATH nor
  # the pinned CLAUDE_BIN can come from a shim that will not exist at 03:15.
  IFS=:
  for d in $PATH; do
    [ -n "$d" ] || continue
    if ephemeral_dir "$d"; then skipped_dirs="${skipped_dirs:+$skipped_dirs }$d"
    else clean_path="${clean_path:+$clean_path:}$d"; fi
  done
  IFS="$old_ifs"
  [ -z "$skipped_dirs" ] || echo "  note: ignoring PATH entries under a temp directory (launchd will not have them): $skipped_dirs"
  for tool in claude git bash; do
    if b="$(PATH="$clean_path" command -v "$tool" 2>/dev/null)"; then
      if [ "$tool" = "claude" ] && [ -n "$b" ]; then
        # review.sh preflights the EXACT binary path (it aborts if CLAUDE_BIN is not -x), and its
        # default $HOME/.local/bin/claude is wrong when claude lives elsewhere. Remember the real
        # one so the review LaunchAgent can pin it in its env.
        CLAUDE_BIN_ABS="$b"
      fi
      d="$(cd "$(dirname "$b")" && pwd)"
      case ":$path_dirs:" in *":$d:"*) ;; *) path_dirs="${path_dirs:+$path_dirs:}$d" ;; esac
    fi
  done
  # The CLI of every enabled adapter too, not only claude's: omp lives in ~/.bun/bin on a bun install.
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    d="$(cd "$d" 2>/dev/null && pwd)" || continue
    case ":$path_dirs:" in *":$d:"*) ;; *) path_dirs="${path_dirs:+$path_dirs:}$d" ;; esac
  done < <(adapter_bin_dirs "$clean_path")
  local path_val="${path_dirs:+$path_dirs:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  local target_plist="$la_dir/$label.plist"
  local domain
  domain="gui/$(id -u)"

  cat > "$target_plist" <<PLIST || { echo "  ERROR: could not write $target_plist" >&2; return 1; }
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$TARGET/run.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>15</integer></dict>
        <dict><key>Hour</key><integer>6</integer><key>Minute</key><integer>15</integer></dict>
        <dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>15</integer></dict>
        <dict><key>Hour</key><integer>12</integer><key>Minute</key><integer>15</integer></dict>
    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$path_val</string>
        <key>HOME</key><string>$HOME</string>
        <key>AUTODREAM_DIR</key><string>$TARGET</string>
        <key>DREAMS_DIR</key><string>$TARGET_PARENT/dreams</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$TARGET/logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$TARGET/logs/launchd.err.log</string>
</dict>
</plist>
PLIST

  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$target_plist" >/dev/null || {
      echo "  ! generated plist failed plutil lint: $target_plist" >&2
      return 1
    }
  fi
  show_plist "$target_plist"

  # Clear any prior instance, then bootstrap. RunAtLoad is false, so this arms the
  # schedule without firing a run now.
  lctl bootout   "$domain/$label" 2>/dev/null || true
  # Guarded explicitly rather than left to `set -e`: the caller invokes this function as
  # `install_schedule || rc=$?` to catch the exit-3 refusal, and that form disables errexit
  # for the whole body. An unguarded failure here would print "scheduled:" over a job
  # that was never bootstrapped.
  lctl bootstrap "$domain" "$target_plist" || {
    echo "  ERROR: launchctl bootstrap failed for $label ($target_plist)" >&2
    return 1
  }
  echo "  scheduled: $label  (daily 03:15/06:15/09:15/12:15)  -> $target_plist"

  # ---- Review triage LaunchAgent ----
  # Runs review.sh on several morning triggers (catch-up for the same reason as
  # run.sh: a slow run that lands its report after 08:00 still gets its triage
  # popup at the next trigger). review.sh's same-day launch marker (bound to the
  # report content digest) dedups the triggers, so at most one workspace opens
  # per report. Env must carry AUTODREAM_TRIAGE_SURFACE=cmux — the whole point
  # is the popup opening in its own cmux workspace rather than inline in a
  # headless shell.
  #
  # The report to triage is yesterday's (the date run.sh targeted: $DREAMS_DIR/
  # $(date -v-1d).md). review.sh with no date picks the newest report in the dir
  # — which at 08:00 is NOT necessarily yesterday's, it's whatever is newest, so
  # a still-running overnight report sets up the job to triage an OLDER one.
  # Pass yesterday's date explicitly (evaluated at fire time, not install time:
  # the \$(...) is escaped so the plist bakes the expression, not a frozen
  # date). review.sh fails fast with "no autodream report found" if yesterday's
  # hasn't landed yet — a scheduled job must not silently triage the wrong day.
  # The review job MUST have cmux or the whole point (the popup) is moot, and a
  # headless inline fallback would silently run claude with no terminal. Skip
  # provisioning unless cmux resolves at runtime the same way review.sh does:
  # a config-file CMUX_BIN first, then PATH, then review.sh's default /Applicat-
  # ions path (macOS GUI installs typically put cmux there and NOT on PATH, so
  # a PATH-only check would wrongly skip).
  #
  # NOTE: the resolved cmux absolute path IS passed through as CMUX_BIN so the
  # scheduled job resolves the same binary install.sh accepted — the launchd
  # env's PATH is fixed and a non-default cmux (e.g. ~/bin/cmux) would
  # otherwise pass the install check but be unfindable at runtime.
  local cfg_cmux="" cfg_claude="" cfg_review=""
  if [ -f "$TARGET/config" ]; then
    cfg_review=$( autodream_cfg_scope=${TARGET}/config; bash -c 'unset AUTODREAM_REVIEW_AGENT; . "$1" >/dev/null 2>&1; printf "%s" "${AUTODREAM_REVIEW_AGENT:-}"' _ "$autodream_cfg_scope" )
    cfg_review=${cfg_review//\"/}
    # Read CMUX_BIN and CLAUDE_BIN with the SAME semantics review.sh uses at
    # runtime (it sources this config as Bash): a subshell apply handles $HOME/~
    # expansion and quotes correctly. A sed/raw-read would grab literal quote
    # characters from `CMUX_BIN="$HOME/bin/cmux"` and fail the -x test, wrongly
    # skipping (and unloading) the review agent for a perfectly valid config.
    cfg_cmux=$( autodream_cfg_scope=${TARGET}/config; bash -c 'unset CMUX_BIN; . "$1" >/dev/null 2>&1; printf "%s" "${CMUX_BIN:-}"' _ "$autodream_cfg_scope" )
    cfg_cmux=${cfg_cmux//\"/}
    cfg_claude=$( autodream_cfg_scope=${TARGET}/config; bash -c 'unset CLAUDE_BIN; . "$1" >/dev/null 2>&1; printf "%s" "${CLAUDE_BIN:-}"' _ "$autodream_cfg_scope" )
    cfg_claude=${cfg_claude//\"/}
  fi
  CMUX_DEFAULT="${AUTODREAM_CMUX_DEFAULT:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
  CMUX_FOUND=""
  { [ -n "$cfg_cmux" ] && [ -x "$cfg_cmux" ]; } && CMUX_FOUND="$cfg_cmux"
  { [ -z "$CMUX_FOUND" ] && PATH="$clean_path" command -v cmux >/dev/null 2>&1; } && CMUX_FOUND=$(PATH="$clean_path" command -v cmux)
  { [ -z "$CMUX_FOUND" ] && [ -x "$CMUX_DEFAULT" ]; } && CMUX_FOUND="$CMUX_DEFAULT"
  # launchd runs the job with no working directory, so a relative CMUX_BIN that
  # passed `-x` here (it resolved against the installer's cwd) would fail at
  # runtime — every trigger hits the headless-fail branch. Refuse relative.
  if [ -n "$CMUX_FOUND" ] && [ "${CMUX_FOUND#/}" = "$CMUX_FOUND" ]; then
    echo "  ! cmux at $CMUX_FOUND is relative; review LaunchAgent needs an absolute path" >&2
    CMUX_FOUND=""
  fi
  # XML-escape the value before embedding in the plist: a path containing & or
  # < breaks the <string> element and plutil/launchctl reject the job.
  CMUX_FOUND_XML=$(printf '%s' "${CMUX_FOUND:-}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  # Effective CLAUDE_BIN for the scheduled job: a config-set value wins (the
  # user explicitly chose a wrapper/custom claude — env must not override it at
  # runtime, review.sh restores env over config), else fall back to the
  # PATH-discovered binary. Require a regular executable FILE (-f AND -x): a
  # directory passes -x but `exec <dir>` fails immediately, confirming a dead
  # workspace (auditor 7.2/7.3).
  # The first USABLE candidate, config first: a config value that points at nothing must not
  # disable the agent while a working claude is on PATH.
  local eff_claude="" cand
  for cand in "$cfg_claude" "$CLAUDE_BIN_ABS"; do
    if [ -n "$cand" ] && [ -f "$cand" ] && [ -x "$cand" ]; then eff_claude="$cand"; break; fi
  done
  # --no-review, or AUTODREAM_REVIEW_AGENT=0 in the environment or the config, opts out of the popup
  # agent. The flag is per run, like --no-schedule; the variable is what makes it stick across
  # re-installs, which would otherwise provision the agent again.
  local review_off=""
  if [ "$REVIEW" = 0 ]; then review_off="--no-review"
  else
    case "${AUTODREAM_REVIEW_AGENT-$cfg_review}" in
      0|no|off|false|NO|OFF|FALSE) review_off="AUTODREAM_REVIEW_AGENT=${AUTODREAM_REVIEW_AGENT-$cfg_review}" ;;
    esac
  fi
  if [ -z "$eff_claude" ] && [ -z "$review_off" ]; then
    echo "  ! claude binary not usable (config [${cfg_claude}], PATH [${CLAUDE_BIN_ABS}]); review LaunchAgent will abort every trigger"
  fi
  CLAUDE_BIN_XML=$(printf '%s' "$eff_claude" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  local review_label="${label}-review"
  if [ -n "$review_off" ] || [ -z "$CMUX_FOUND" ] || [ -z "$eff_claude" ]; then
    if [ -n "$review_off" ]; then
      echo "  review LaunchAgent not provisioned ($review_off)"
    elif [ -z "$CMUX_FOUND" ]; then
      echo "  ! cmux not found (config CMUX_BIN, PATH, or $CMUX_DEFAULT); skipping review LaunchAgent"
    else
      echo "  ! claude binary not usable; skipping review LaunchAgent"
    fi
    # Unload any previously-provisioned review job even though we're skipping —
    # a machine that had cmux/claude at install and lost one would otherwise
    # keep the stale scheduled service firing a failing trigger forever.
    lctl bootout "$domain/$review_label" 2>/dev/null || true
    # Unloading is not enough: launchd loads every plist in LaunchAgents at login, so a plist left
    # on disk brings the failing job back at the next login.
    if [ "$DRY" = 1 ]; then
      [ -e "$real_la_dir/$review_label.plist" ] && dry "rm $real_la_dir/$review_label.plist"
      :
    else
      rm -f "$la_dir/$review_label.plist"
    fi
    return 0
  fi
  local review_plist="$la_dir/$review_label.plist"
  cat > "$review_plist" <<PLIST || { echo "  ERROR: could not write $review_plist" >&2; return 1; }
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$review_label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>exec "\$1" "\$(date -v-1d +%Y-%m-%d)"</string>
        <string>triage</string>
        <string>$TARGET/review.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Hour</key><integer>8</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>15</integer></dict>
        <dict><key>Hour</key><integer>12</integer><key>Minute</key><integer>15</integer></dict>
        <dict><key>Hour</key><integer>15</integer><key>Minute</key><integer>30</integer></dict>
        <dict><key>Hour</key><integer>18</integer><key>Minute</key><integer>15</integer></dict>
    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$path_val</string>
        <key>HOME</key><string>$HOME</string>
        <key>AUTODREAM_DIR</key><string>$TARGET</string>
        <key>DREAMS_DIR</key><string>$TARGET_PARENT/dreams</string>
        <key>AUTODREAM_TRIAGE_SURFACE</key><string>cmux</string>
        <key>CMUX_BIN</key><string>${CMUX_FOUND_XML}</string>
        <key>CLAUDE_BIN</key><string>${CLAUDE_BIN_XML}</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$TARGET/logs/review-launch.out.log</string>
    <key>StandardErrorPath</key>
    <string>$TARGET/logs/review-launch.err.log</string>
</dict>
</plist>
PLIST

  # The two shell-command substitutions in ProgramArguments must survive the
  # heredoc LITERALLY (evaluated at fire time, not install time): the target
  # path as \$1 and yesterday's date as \$(date ...). If the escaping regressed
  # and one of them got pre-expanded, the plist carries the frozen value — fail
  # the install loudly rather than provisioning a job that fires the wrong path
  # or a wrong date.
  grep -qF '$(date -v-1d +%Y-%m-%d)' "$review_plist" || {
    echo "  ! review plist lost the fire-time date expression; aborting" >&2
    return 1
  }
  grep -qF 'exec "$1"' "$review_plist" || {
    echo "  ! review plist lost the argv path reference; aborting" >&2
    return 1
  }

  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$review_plist" >/dev/null || {
      echo "  ! generated review plist failed plutil lint: $review_plist" >&2
      return 1
    }
  fi
  show_plist "$review_plist"
  lctl bootout   "$domain/$review_label" 2>/dev/null || true
  lctl bootstrap "$domain" "$review_plist" || {
    echo "  ERROR: launchctl bootstrap failed for $review_label ($review_plist)" >&2
    return 1
  }
  echo "  scheduled: $review_label  (daily 08:00/09:15/12:15/15:30/18:15)  -> $review_plist"
  return 0
}

echo
if [ "$SCHEDULE" = 1 ] && command -v launchctl >/dev/null 2>&1; then
  echo "Installing nightly schedule (launchd):"
  # Only the REFUSAL (exit 3) is survivable: a foreign job holds our label, the symlinks
  # are installed and the run still works by hand. Every other non-zero return is a real
  # scheduling failure (a plist that fails plutil -lint, a bootstrap that did not take);
  # swallowing those would report "everything is in place" over exactly the
  # silent-broken-schedule state that cost 18 days to notice.
  schedule_rc=0
  install_schedule || schedule_rc=$?
  if [ "$schedule_rc" -eq 3 ]; then
    echo "  Schedule not installed: another install holds our label. Everything else is in place." >&2
  elif [ "$schedule_rc" -ne 0 ]; then
    echo "  Schedule FAILED (exit $schedule_rc). The symlinks are installed; the schedule is not." >&2
    exit "$schedule_rc"
  fi
  # Only advise the wake schedule when there is a job to wake for.
  if [ "$schedule_rc" -eq 0 ]; then
    echo
    echo "  Guarantee the Mac is awake for the 03:15 trigger (launchd won't wake it):"
    echo "    sudo pmset repeat wake MTWRFSU 03:10:00"
  fi
elif [ "$SCHEDULE" = 1 ]; then
  echo "Skipping schedule: launchctl not found (not macOS?). See launchd/ for the template."
else
  echo "Skipping schedule (--no-schedule). See launchd/com.user.autodream.plist.example to add one."
fi

echo
echo "Installed. Try:"
echo "  $TARGET/run.sh \$(date -v-1d +%Y-%m-%d)   # process yesterday"
echo "  $TARGET/review.sh                        # triage the latest report"
