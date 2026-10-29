#!/usr/bin/env bash
# shellcheck shell=bash
# Module registry and runner.
#   register_module NAME ORDER SYSTEM_ONLY   called by each modules/NN-name.sh
#   run_preflight                            preflight in this shell; exit 3 on failure
#   run_modules / run_status                 every selected module in its own subshell
#   run_uninstall                            replay backups newest first
#   acquire_lock                             flock on $STATE_DIR/lock (fd 9), exit 4 if held
# A module NAME defines NAME_applies (return 0, or print a reason and return 1)
# and NAME_apply, with `-` in NAME spelled `_` (shell-theme -> shell_theme_apply).
# Sourced, never executed; safe to source twice; sets no shell options.
# Globals read: DRY_RUN SYSTEM STRICT VERBOSE PURGE STATE_DIR RUN_DIR TNU_ROOT
# TNU_LOG_FILE BACKUP_TS TNU_SELECTED (array: modules to run, in order).
# run_modules / run_status / run_uninstall report their outcome in TNU_RC
# (0 or 1) and return 0: called in an `if`/`||` context, bash would ignore
# errexit inside the module subshells too, so call them as plain commands.

if ! declare -p TNU_MOD_ORDER >/dev/null 2>&1; then
  declare -gA TNU_MOD_ORDER=() TNU_MOD_SYSTEM=()
fi
_TNU_CHILD=""
TNU_RC=0

# register_module NAME ORDER SYSTEM_ONLY(0|1)
register_module() {
  local name=${1:-} order=${2:-} sys=${3:-}
  if [[ ! $name =~ ^[a-z][a-z0-9-]*$ ]]; then die "register_module: bad name: $name"; fi
  if [[ ! $order =~ ^[0-9]+$ ]]; then die "register_module: bad ORDER for $name: $order"; fi
  if [[ $sys != 0 && $sys != 1 ]]; then die "register_module: SYSTEM_ONLY must be 0 or 1 for $name"; fi
  if [[ -n ${TNU_MOD_ORDER[$name]+x} ]]; then die "module registered twice: $name"; fi
  TNU_MOD_ORDER[$name]=$((10#$order))
  TNU_MOD_SYSTEM[$name]=$sys
}

module_fn() {
  printf '%s\n' "${1//-/_}"
}

is_module() {
  [[ -n ${1:-} && -n ${TNU_MOD_ORDER[$1]+x} ]]
}

# module_names: registered modules by ORDER, then name.
module_names() {
  local n
  for n in "${!TNU_MOD_ORDER[@]}"; do
    printf '%08d\t%s\n' "${TNU_MOD_ORDER[$n]}" "$n"
  done | LC_ALL=C sort | cut -f2
}

# load_modules DIR: source DIR/[0-9][0-9]-*.sh and check every module's functions.
load_modules() {
  local dir=$1 f n fn
  if [[ ! -d $dir ]]; then die "no modules directory: $dir"; fi
  for f in "$dir"/[0-9][0-9]-*.sh; do
    if [[ ! -f $f ]]; then continue; fi
    # shellcheck source=/dev/null
    source "$f" || die "cannot load module $f"
  done
  for n in "${!TNU_MOD_ORDER[@]}"; do
    fn=$(module_fn "$n")
    if ! declare -F "${fn}_applies" >/dev/null || ! declare -F "${fn}_apply" >/dev/null; then
      die "module $n must define ${fn}_applies and ${fn}_apply"
    fi
  done
}

# run_preflight: the preflight module, in this shell (it exports detection vars).
run_preflight() {
  local MODULE=preflight
  if ! is_module preflight; then die "preflight module missing" 3; fi
  if ! preflight_apply; then
    log_error "preflight failed"
    exit 3
  fi
}

# acquire_lock: hold $STATE_DIR/lock on fd 9 until this process exits.
acquire_lock() {
  (umask 077 && mkdir -p -- "$STATE_DIR") || die "cannot create $STATE_DIR"
  exec 9>>"$STATE_DIR/lock" || die "cannot open $STATE_DIR/lock"
  if ! flock -n 9; then die "another install is running" 4; fi
}

# _tnu_children PID: direct children of PID (from /proc: a kernel interface,
# so not under SYS_ROOT).
_tnu_children() {
  local f line rest pid ppid
  for f in /proc/[0-9]*/stat; do
    { IFS= read -r line <"$f"; } 2>/dev/null || continue
    rest=${line##*) }
    IFS=' ' read -r _ ppid _ <<<"$rest"
    if [[ $ppid == "$1" ]]; then
      pid=${f#/proc/}
      printf '%s\n' "${pid%/stat}"
    fi
  done
}

# _tnu_kill_tree PID: SIGTERM PID and all its descendants (stopped first, so
# none can fork while the tree is walked).
_tnu_kill_tree() {
  local pid=$1 c
  kill -STOP "$pid" 2>/dev/null || return 0
  for c in $(_tnu_children "$pid"); do _tnu_kill_tree "$c"; done
  kill -TERM "$pid" 2>/dev/null || true
  kill -CONT "$pid" 2>/dev/null || true
}

# _tnu_on_signal: INT/TERM handler: stop the running module, exit 130 (the
# lock is released when this process exits).
_tnu_on_signal() {
  trap '' INT TERM
  MODULE="" log_error "interrupted"
  if [[ -n $_TNU_CHILD ]]; then
    _tnu_kill_tree "$_TNU_CHILD"
    wait "$_TNU_CHILD" 2>/dev/null || true
  fi
  exit 130
}

# _tnu_err_trap RC FILE LINE COMMAND: ERR trap body ("MODULE: file:line: command").
_tnu_err_trap() {
  local rc=$1 src=$2 line=$3 cmd=$4
  # Dry-run with an uncached download: not an error (see download_verified).
  if _dry && [[ $rc == "$TNU_DRY_NOT_CACHED" ]]; then return 0; fi
  src=${src#"${TNU_ROOT:-}"/}
  log_error "$src:$line: $cmd (exit $rc)"
}

# _module_body NAME: runs in the module's background subshell.
_module_body() {
  local name=$1 fn
  fn=$(module_fn "$name")
  exec 9>&- # only the parent holds the lock
  set -Eeuo pipefail
  trap - INT TERM
  # shellcheck disable=SC2034 # read by lib/log.sh and note_change
  MODULE=$name
  trap '_tnu_err_trap "$?" "${BASH_SOURCE[0]:-}" "$LINENO" "$BASH_COMMAND"' ERR
  if ! "${fn}_applies" >"$RUN_DIR/reason.$name"; then
    : >"$RUN_DIR/skipped.$name"
    exit 0
  fi
  # Modules keep stdout clean: anything they print goes to stderr.
  "${fn}_apply" >&2
}

_TNU_RES_NAME=()
_TNU_RES_KIND=()
_TNU_RES_INFO=()

_result() {
  _TNU_RES_NAME+=("$1")
  _TNU_RES_KIND+=("$2")
  _TNU_RES_INFO+=("${3:-}")
}

# _first_error FILE NAME: the first "error: " message in FILE, without prefixes.
_first_error() {
  local line
  if [[ -f $1 ]]; then
    while IFS= read -r line; do
      if [[ $line == 'error: '* ]]; then
        line=${line#error: }
        printf '%s\n' "${line#"$2: "}"
        return 0
      fi
    done <"$1"
  fi
  printf 'failed\n'
}

# _run_module NAME CAPTURE(0|1): run NAME in a background subshell (so a
# signal reaches _tnu_on_signal at once) and record OK / CHANGED n / SKIPPED
# reason / FAILED. With CAPTURE=1 its stderr goes to $RUN_DIR/stderr.NAME.
_run_module() {
  local name=$1 capture=$2 rc=0 n reason="" err=$RUN_DIR/stderr.$1
  rm -f -- "$RUN_DIR/skipped.$name" "$RUN_DIR/reason.$name" "$err"
  if ((capture)); then
    _module_body "$name" 2>"$err" &
  else
    _module_body "$name" &
  fi
  _TNU_CHILD=$!
  wait "$_TNU_CHILD" || rc=$?
  _TNU_CHILD=""
  if ((capture)) && [[ ${VERBOSE:-0} == 1 && -f $err ]]; then cat -- "$err" >&2; fi
  if [[ -e $RUN_DIR/skipped.$name ]]; then
    { IFS= read -r reason <"$RUN_DIR/reason.$name"; } 2>/dev/null || true
    _result "$name" SKIPPED "${reason:-not applicable}"
    return 0
  fi
  n=$(module_changes "$name")
  if ((rc == 0)); then
    if ((n == 0)); then _result "$name" OK; else _result "$name" CHANGED "$n"; fi
  elif _dry && ((rc == TNU_DRY_NOT_CACHED)); then
    # The rest of the module could not be previewed without the download.
    _result "$name" CHANGED "$((n + 1))"
  else
    _result "$name" FAILED "$(_first_error "$err" "$name")"
  fi
}

# _summary_line FMT ARGS...: print to stderr and append to the log file.
_summary_line() {
  local IFS=' '
  # shellcheck disable=SC2059 # FMT is always a literal from this file
  printf "$@" >&2
  if [[ -n ${TNU_LOG_FILE:-} ]]; then
    # shellcheck disable=SC2059
    printf "$@" >>"$TNU_LOG_FILE" 2>/dev/null || true
  fi
}

_print_summary() {
  local i kind info title=result
  if _dry; then title="result (dry-run)"; fi
  _summary_line '\n%-14s %s\n' module "$title"
  for i in "${!_TNU_RES_NAME[@]}"; do
    kind=${_TNU_RES_KIND[i]}
    info=${_TNU_RES_INFO[i]}
    case $kind in
      FAILED) info="" ;;
      NOTRUN)
        kind="NOT RUN"
        info="(--strict)"
        ;;
    esac
    _summary_line '%-14s %s\n' "${_TNU_RES_NAME[i]}" "$kind${info:+ $info}"
  done
  if [[ -n ${TNU_LOG_FILE:-} ]]; then _summary_line 'log: %s\n' "$TNU_LOG_FILE"; fi
}

# run_modules: apply (or dry-run) every module in TNU_SELECTED. TNU_RC=1 if
# any module FAILED; with STRICT=1 the rest are not run after a failure.
run_modules() {
  local name failed=0 stop=0
  _result preflight OK
  for name in "${TNU_SELECTED[@]}"; do
    if ((stop)); then
      _result "$name" NOTRUN
      continue
    fi
    if [[ ${TNU_MOD_SYSTEM[$name]} == 1 && ${SYSTEM:-0} != 1 ]]; then
      _result "$name" SKIPPED "needs --system"
      continue
    fi
    log_info "running $name"
    _run_module "$name" 0
    if [[ ${_TNU_RES_KIND[-1]} == FAILED ]]; then
      failed=1
      if [[ ${STRICT:-0} == 1 ]]; then stop=1; fi
    fi
  done
  _print_summary
  TNU_RC=$failed
}

# run_status: dry-run every selected module; print applied / drifted (n) /
# n/a: reason / error: reason to stdout. TNU_RC=1 if any module errored.
run_status() {
  local name state rc=0
  for name in "${TNU_SELECTED[@]}"; do
    if [[ ${TNU_MOD_SYSTEM[$name]} == 1 && ${SYSTEM:-0} != 1 ]]; then
      state="n/a: needs --system"
    else
      _run_module "$name" 1
      case ${_TNU_RES_KIND[-1]} in
        OK) state=applied ;;
        CHANGED) state="drifted (${_TNU_RES_INFO[-1]})" ;;
        SKIPPED) state="n/a: ${_TNU_RES_INFO[-1]}" ;;
        *)
          state="error: ${_TNU_RES_INFO[-1]}"
          rc=1
          ;;
      esac
    fi
    printf '%-14s %s\n' "$name" "$state"
  done
  TNU_RC=$rc
}

# run_uninstall: replay BACKUP_TS, or every backup newest first, with PURGE.
# A fully replayed backup moves to backups/.restored/; the first one with rows
# still pending is left in place and stops the run (older backups would
# otherwise see our newer values as user edits), with TNU_RC=1.
run_uninstall() {
  local d ts restored=$STATE_DIR/backups/.restored
  local -a dirs=()
  TNU_RC=0
  if [[ -n ${BACKUP_TS:-} ]]; then
    dirs=("$STATE_DIR/backups/$BACKUP_TS")
  else
    mapfile -t dirs < <(backup_list)
  fi
  if ((${#dirs[@]} == 0)); then
    log_info "nothing to uninstall"
    return 0
  fi
  for d in "${dirs[@]}"; do
    ts=${d##*/}
    log_info "restoring backup $ts"
    if ! backup_replay "$d" "${PURGE:-0}"; then
      log_error "backup $ts is not fully restored: the rows warned about above are pending"
      if [[ ${SYSTEM:-0} != 1 ]]; then log_error "rerun with --uninstall --system to undo root changes"; fi
      # shellcheck disable=SC2034 # read by install.sh
      TNU_RC=1
      return 0
    fi
    if _dry; then continue; fi
    (umask 077 && mkdir -p -- "$restored") || die "cannot create $restored"
    mv -T -- "$d" "$restored/$ts" || die "cannot move $d to $restored"
    log_info "restored backup $ts"
  done
}
