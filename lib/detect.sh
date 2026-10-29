#!/usr/bin/env bash
# shellcheck shell=bash
# Environment detection: sets and exports IS_ERHAI HAS_ZSH HAS_BASH_RC
# HAS_PTYXIS HAS_FLATPAK HAS_ZELLIJ HAS_LIG HAS_GJSOSK HAS_USER_THEME
# HAS_SESSION_BUS (each 0 or 1).
# Sourced, never executed; safe to source twice; sets no shell options.
# Globals read: HOME XDG_DATA_HOME SYS_ROOT DBUS_SESSION_BUS_ADDRESS.

# _flag CMD...: print 1 when CMD succeeds, else 0.
_flag() {
  if "$@"; then echo 1; else echo 0; fi
}

# _has_extension UUID: UUID is installed system-wide or for this user.
_has_extension() {
  local uuid=$1
  [[ -d $(sys_path /usr/share/gnome-shell/extensions)/$uuid ||
  -d ${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/$uuid ]]
}

_is_erhai() {
  if [[ -f $(sys_path /usr/share/gnome-shell/theme/erhai/gnome-shell-theme.gresource) ]]; then
    return 0
  fi
  have_cmd dpkg-query && dpkg-query -W oneplus-erhai-desktop >/dev/null 2>&1
}

_has_session_bus() {
  [[ -n ${DBUS_SESSION_BUS_ADDRESS:-} ]]
}

# detect_env: set and export the detection variables.
detect_env() {
  IS_ERHAI=$(_flag _is_erhai)
  HAS_ZSH=$(_flag have_cmd zsh)
  HAS_BASH_RC=$(_flag test -f "$HOME/.bashrc")
  HAS_PTYXIS=$(_flag have_cmd ptyxis)
  HAS_FLATPAK=$(_flag have_cmd flatpak)
  HAS_ZELLIJ=$(_flag have_cmd zellij)
  HAS_LIG=$(_flag have_cmd lig)
  HAS_GJSOSK=$(_flag _has_extension gjsosk@vishram1123.com)
  HAS_USER_THEME=$(_flag _has_extension user-theme@gnome-shell-extensions.gcampax.github.com)
  HAS_SESSION_BUS=$(_flag _has_session_bus)
  export IS_ERHAI HAS_ZSH HAS_BASH_RC HAS_PTYXIS HAS_FLATPAK HAS_ZELLIJ HAS_LIG \
    HAS_GJSOSK HAS_USER_THEME HAS_SESSION_BUS
  log_debug "detected: erhai=$IS_ERHAI zsh=$HAS_ZSH bashrc=$HAS_BASH_RC ptyxis=$HAS_PTYXIS" \
    "flatpak=$HAS_FLATPAK zellij=$HAS_ZELLIJ lig=$HAS_LIG gjsosk=$HAS_GJSOSK" \
    "user-theme=$HAS_USER_THEME session-bus=$HAS_SESSION_BUS"
}
