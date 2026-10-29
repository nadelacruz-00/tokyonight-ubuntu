#!/usr/bin/env bash
# shellcheck shell=bash
# preflight: refuse root, check the platform, tools and free space, then
# detect the environment (lib/detect.sh). Always runs, in the main shell.
# --force turns OS / architecture / desktop failures into warnings; root and
# a missing python3 are never allowed. --uninstall only warns about the
# platform (undoing must work after an OS upgrade); --uninstall and --status
# download nothing and write little, so they skip the curl and free-space checks.
# Globals read: TNU_EUID (test override of EUID) FORCE MODE SYS_ROOT HOME
# XDG_CURRENT_DESKTOP DBUS_SESSION_BUS_ADDRESS.

register_module preflight 0 0

TNU_MIN_FREE_KB=204800

# _os_release_field FILE KEY: KEY's value from an os-release file, unquoted.
_os_release_field() {
  local k v
  while IFS='=' read -r k v || [[ -n $k ]]; do
    if [[ $k == "$2" ]]; then
      v=${v#[\"\']}
      printf '%s\n' "${v%[\"\']}"
      return 0
    fi
  done <"$1"
}

# _soft_fail MSG: an error, or only a warning with --force or --uninstall. Sets _pf_fail.
_soft_fail() {
  if [[ ${FORCE:-0} == 1 ]]; then
    log_warn "$1 (continuing: --force)"
  elif [[ ${MODE:-apply} == uninstall ]]; then
    log_warn "$1 (continuing: uninstall)"
  else
    log_error "$1 (use --force to try anyway)"
    _pf_fail=1
  fi
}

_preflight_platform() {
  local osr id ver arch desk
  osr=$(sys_path /etc/os-release)
  if [[ ! -r $osr ]]; then osr=$(sys_path /usr/lib/os-release); fi
  if [[ -r $osr ]]; then
    id=$(_os_release_field "$osr" ID)
    ver=$(_os_release_field "$osr" VERSION_ID)
  fi
  if [[ ${id:-} != ubuntu || ${ver:-} != 26.04 ]]; then
    _soft_fail "unsupported OS: ${id:-unknown} ${ver:-} (needs Ubuntu 26.04)"
  fi
  arch=$(uname -m 2>/dev/null) || arch=unknown
  if [[ $arch != aarch64 ]]; then _soft_fail "unsupported architecture: $arch (needs aarch64)"; fi
  desk=${XDG_CURRENT_DESKTOP:-}
  if [[ -n $desk ]]; then
    if [[ ":$desk:" != *:GNOME:* ]]; then _soft_fail "unsupported desktop: $desk (needs GNOME)"; fi
  elif ! have_cmd gnome-shell && [[ ! -x $(sys_path /usr/bin/gnome-shell) ]]; then
    _soft_fail "no desktop session and gnome-shell is not installed (needs GNOME)"
  fi
}

# _preflight_light: uninstall/status mode (no downloads, no space check).
_preflight_light() {
  [[ ${MODE:-apply} == uninstall || ${MODE:-apply} == status ]]
}

_preflight_tools() {
  local c missing=() need=(dconf sha256sum install flock)
  if ! _preflight_light; then need+=(curl df); fi
  for c in "${need[@]}"; do
    if ! have_cmd "$c"; then missing+=("$c"); fi
  done
  if [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} ]] && ! have_cmd dbus-run-session; then
    missing+=(dbus-run-session)
  fi
  if ((${#missing[@]})); then
    local IFS=' '
    log_error "missing required commands: ${missing[*]}"
    _pf_fail=1
  fi
}

_preflight_space() {
  local out avail
  if ! out=$(df -Pk -- "$HOME" 2>/dev/null); then
    log_error "cannot check free space in $HOME"
    _pf_fail=1
    return 0
  fi
  IFS=' ' read -r _ _ _ avail _ <<<"${out##*$'\n'}"
  if [[ ! $avail =~ ^[0-9]+$ ]]; then
    log_error "cannot check free space in $HOME"
    _pf_fail=1
  elif ((avail < TNU_MIN_FREE_KB)); then
    log_error "only $((avail / 1024)) MB free in $HOME (needs $((TNU_MIN_FREE_KB / 1024)) MB)"
    _pf_fail=1
  fi
}

preflight_applies() {
  return 0
}

preflight_apply() {
  local euid=${TNU_EUID:-$EUID}
  _pf_fail=0
  if [[ $euid == 0 ]]; then
    log_error "do not run as root: run as your user (--system uses sudo for the root parts)"
    return 1
  fi
  if ! have_cmd python3; then
    log_error "python3 is required"
    return 1
  fi
  if [[ -z ${HOME:-} || $HOME != /* || ! -d $HOME ]]; then
    log_error "HOME is not an existing absolute directory: ${HOME:-unset}"
    return 1
  fi
  _preflight_platform
  _preflight_tools
  if ! _preflight_light; then _preflight_space; fi
  if ((_pf_fail)); then return 1; fi
  detect_env
}
