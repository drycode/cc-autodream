#!/bin/bash
# Portable date and stat, for the BSD tools on macOS and the GNU ones on Linux.
#
# Sourced, never executed. The scripts and tests used `date -v`, `date -j -f` and `stat -f`
# directly, which is why the whole suite needed a macOS runner. Every caller goes through
# these functions now, so the pure-logic suites run on Linux. Each tool is detected on its
# own (a Mac with coreutils' gnubin on PATH has a GNU date and a BSD stat).
#
# Dates are strict on purpose: GNU `date -d` accepts "tomorrow" and "last friday", BSD
# `date -j -f %Y-%m-%d` does not, and a caller that is handed garbage must fail the same
# way on both.

_p_is_date() { case "$1" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;; *) return 1 ;; esac; }
_p_is_stamp() { case "$1" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) return 0 ;; *) return 1 ;; esac; }
_p_is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

if date --version >/dev/null 2>&1; then _P_GNU_DATE=1; else _P_GNU_DATE=0; fi
if stat --version >/dev/null 2>&1; then _P_GNU_STAT=1; else _P_GNU_STAT=0; fi

# -> yesterday, local time, YYYY-MM-DD
pdate_yesterday() {
  if [ "$_P_GNU_DATE" = 1 ]; then date -d yesterday +%Y-%m-%d; else date -v-1d +%Y-%m-%d; fi
}

# $1=YYYY-MM-DD $2=signed whole number $3=d|y -> the shifted date, exit 1 on anything else
pdate_shift() {
  _p_is_date "${1:-}" || return 1
  case "${2:-}" in [+-][0-9]*|[0-9]*) ;; *) return 1 ;; esac
  local n="$2" unit="${3:-}" sign="+"
  case "$n" in -*) sign="-"; n="${n#-}" ;; +*) n="${n#+}" ;; esac
  _p_is_int "$n" || return 1
  case "$unit" in d|y) ;; *) return 1 ;; esac
  if [ "$_P_GNU_DATE" = 1 ]; then
    local word=days; [ "$unit" = y ] && word=years
    date -d "$1 $sign$n $word" +%Y-%m-%d 2>/dev/null
  else
    date -j -f %Y-%m-%d -v"$sign$n$unit" "$1" +%Y-%m-%d 2>/dev/null
  fi
}

# $1="YYYY-MM-DD HH:MM:SS" (local) -> epoch seconds, exit 1 when it does not parse.
# A bare YYYY-MM-DD is midnight.
pdate_epoch() {
  local s="${1:-}"
  _p_is_date "$s" && s="$s 00:00:00"
  _p_is_stamp "$s" || return 1
  if [ "$_P_GNU_DATE" = 1 ]; then date -d "$s" +%s 2>/dev/null
  else date -j -f '%Y-%m-%d %H:%M:%S' "$s" +%s 2>/dev/null; fi
}

# $1=epoch $2=+FORMAT -> the epoch formatted in local time (TZ=UTC pdate_fmt_epoch for UTC)
pdate_fmt_epoch() {
  _p_is_int "${1:-}" || return 1
  if [ "$_P_GNU_DATE" = 1 ]; then date -d "@$1" "${2:-+%Y-%m-%d}" 2>/dev/null
  else date -r "$1" "${2:-+%Y-%m-%d}" 2>/dev/null; fi
}

# $1=file -> mtime, epoch seconds
pstat_mtime() {
  if [ "$_P_GNU_STAT" = 1 ]; then stat -c %Y "$1" 2>/dev/null; else stat -f %m "$1" 2>/dev/null; fi
}

# $1=file -> permission bits in octal, no leading zeros (600, 755)
pstat_mode() {
  if [ "$_P_GNU_STAT" = 1 ]; then stat -c %a "$1" 2>/dev/null; else stat -f %Lp "$1" 2>/dev/null; fi
}

# $1=seconds, rest=command -> runs it bounded: timeout, gtimeout, or a watchdog that kills the child
tmo() {
  local s=$1 pid wd rc; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; return $?
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"; return $?; fi
  "$@" & pid=$!
  ( sleep "$s"; pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 & wd=$!
  wait "$pid"; rc=$?
  kill "$wd" 2>/dev/null
  wait "$wd" 2>/dev/null
  return $rc
}

# $1=repo dir -> owner/repo from a github.com origin URL, empty otherwise
repo_slug() {
  local url
  url=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || return 0
  case "$url" in
    *github.com[:/]*) url=${url#*github.com[:/]}; url=${url%.git}; printf '%s' "$url" ;;
  esac
}
