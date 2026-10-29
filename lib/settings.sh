#!/usr/bin/env bash
# shellcheck shell=bash
# dconf settings by key path, recorded in the backup manifest so uninstall can
# restore (or reset) them. Values are canonical GVariant literals.
# Without a session bus, dconf runs under `dbus-run-session` and a one-time
# warning says a re-login is needed.
# Sourced, never executed; safe to source twice; sets no shell options.
# Globals read: DBUS_SESSION_BUS_ADDRESS DRY_RUN RUN_DIR.

: "${_TNU_NOBUS_WARNED:=0}"

# Warn once per run; the marker in RUN_DIR also covers subshells such as $(dget ...).
_nobus_warn_once() {
  local marker=""
  if [[ -n ${RUN_DIR:-} && -d $RUN_DIR ]]; then marker=$RUN_DIR/.nobus-warned; fi
  if [[ $_TNU_NOBUS_WARNED == 1 || (-n $marker && -e $marker) ]]; then return 0; fi
  _TNU_NOBUS_WARNED=1
  if [[ -n $marker ]]; then : >"$marker" || true; fi
  log_warn "no session bus: log out and back in to see changes"
}

# _dconf ARGS...: dconf, under a private bus when there is no session bus.
_dconf() {
  if [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} ]]; then
    _nobus_warn_once
    dbus-run-session -- dconf "$@"
  else
    dconf "$@"
  fi
}

# dconf_run ARGS...: a changing dconf call (write/reset) that honours dry-run.
dconf_run() {
  if _dry; then
    log_dry "dconf $(_quote_cmd "$@")"
    return 0
  fi
  _dconf "$@"
}

_dconf_key() {
  if [[ $1 != /?* || $1 == */ || $1 == *[$'\t\n ']* ]]; then die "bad dconf key: $1"; fi
}

# dget KEY: print KEY's value, or nothing when unset.
dget() {
  _dconf_key "$1"
  _dconf read "$1"
}

# dset KEY VALUE: set KEY to the GVariant literal VALUE unless it already is.
dset() {
  local key=$1 value=$2 cur
  _dconf_key "$key"
  if [[ -z $value ]]; then die "dset: empty value for $key"; fi
  cur=$(dget "$key") || die "cannot read $key"
  if [[ $cur == "$value" ]]; then
    log_debug "unchanged $key"
    return 0
  fi
  backup_record dconf "$key" "${cur:-UNSET}" "$value"
  dconf_run write "$key" "$value" || die "dconf write failed for $key"
  note_change "set $key $value"
  if ! _dry; then log_info "set $key = $value"; fi
}

# gv_str TEXT: TEXT as a GVariant string literal ('...', with \ and ' escaped).
gv_str() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\'/\\\'}
  printf "'%s'\n" "$s"
}
