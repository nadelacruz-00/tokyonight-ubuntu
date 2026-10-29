#!/usr/bin/env bash
# shellcheck shell=bash
# wallpaper: the Ubuntu 26.04 "Ask a friend" wallpaper for desktop and lock screen.
# Needs the file (ubuntu-wallpapers-resolute) or --system to install it.
# Globals read: SYSTEM SYS_ROOT.

register_module wallpaper 50 0

_WALL=/usr/share/backgrounds/osselo-Ask_a_friend.jpg

wallpaper_applies() {
  if [[ ! -e $(sys_path "$_WALL") && ${SYSTEM:-0} != 1 ]]; then
    echo "$_WALL is missing (use --system to install ubuntu-wallpapers-resolute)"
    return 1
  fi
}

wallpaper_apply() {
  local uri
  if [[ ! -e $(sys_path "$_WALL") ]]; then
    apt_install ubuntu-wallpapers-resolute
    note_change "apt-get install ubuntu-wallpapers-resolute"
  fi
  uri=$(gv_str "file://$_WALL")
  dset /org/gnome/desktop/background/picture-uri "$uri"
  dset /org/gnome/desktop/background/picture-uri-dark "$uri"
  dset /org/gnome/desktop/screensaver/picture-uri "$uri"
  dset /org/gnome/desktop/background/picture-options "'zoom'"
}
