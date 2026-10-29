#!/usr/bin/env bash
# shellcheck shell=bash
# shell-theme: the "rewaita" GNOME Shell theme, selected via User Themes.
# Needs the user-theme extension (or --system, which installs it with apt).
# Globals read: HAS_USER_THEME SYSTEM VARIANT HOME TNU_ROOT.

register_module shell-theme 40 0

_UT_UUID=user-theme@gnome-shell-extensions.gcampax.github.com

shell_theme_applies() {
  if [[ ${HAS_USER_THEME:-0} != 1 && ${SYSTEM:-0} != 1 ]]; then
    echo "user-theme extension is not installed (use --system to install it)"
    return 1
  fi
}

shell_theme_apply() {
  if [[ ${HAS_USER_THEME:-0} != 1 ]]; then
    apt_install gnome-shell-extensions
    note_change "apt-get install gnome-shell-extensions"
  fi
  install_file "$TNU_ROOT/assets/rewaita/$VARIANT/gnome-shell.css" \
    "${XDG_DATA_HOME:-$HOME/.local/share}/themes/rewaita/gnome-shell/gnome-shell.css"
  ext_enable "$_UT_UUID"
  dset /org/gnome/shell/extensions/user-theme/name "'rewaita'"
}
