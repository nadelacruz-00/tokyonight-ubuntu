#!/usr/bin/env bash
# shellcheck shell=bash
# Logging: every message goes to stderr and, after log_init FILE, to FILE.
# Colour only when stderr is a TTY and NO_COLOR is unset.
# Sourced, never executed; safe to source twice; sets no shell options.
# Globals read: VERBOSE (debug when 1), MODULE (log context).

: "${TNU_LOG_FILE:=}"

# log_init LOGFILE|-: also append log lines to LOGFILE ("-": stderr only).
log_init() {
  local file=${1:?log_init: LOGFILE or - required}
  if [[ $file == - ]]; then
    TNU_LOG_FILE=""
    return 0
  fi
  mkdir -p -- "$(dirname -- "$file")"
  : >>"$file"
  TNU_LOG_FILE=$file
}

# _log LEVEL COLOUR PREFIX MSG
_log() {
  local level=$1 colour=$2 prefix=$3 msg=$4 ctx=""
  if [[ -n ${MODULE:-} ]]; then ctx="$MODULE: "; fi
  if [[ -t 2 && -z ${NO_COLOR+x} ]]; then
    printf '\033[%sm%s\033[0m%s%s\n' "$colour" "$prefix" "$ctx" "$msg" >&2 || true
  else
    printf '%s%s%s\n' "$prefix" "$ctx" "$msg" >&2 || true
  fi
  if [[ -n $TNU_LOG_FILE ]]; then
    printf '%s %-5s %s%s%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$prefix" "$ctx" "$msg" \
      >>"$TNU_LOG_FILE" 2>/dev/null || true
  fi
}

# Several MSG words are joined with spaces (IFS is $'\n\t' globally).
log_info() {
  local IFS=' '
  _log INFO '1;34' '' "$*"
}
log_warn() {
  local IFS=' '
  _log WARN '1;33' 'warning: ' "$*"
}
log_error() {
  local IFS=' '
  _log ERROR '1;31' 'error: ' "$*"
}
log_dry() {
  local IFS=' '
  _log DRY '1;36' '[dry-run] ' "$*"
}
log_debug() {
  local IFS=' '
  if [[ ${VERBOSE:-0} == 1 ]]; then
    _log DEBUG '2' 'debug: ' "$*"
  fi
}
