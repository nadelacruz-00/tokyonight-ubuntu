#!/usr/bin/env bash
# shellcheck shell=bash
# gtk: Rewaita-generated GTK 3/4 CSS and the Yaru purple dark defaults.
# Globals read: VARIANT HOME TNU_ROOT.

register_module gtk 30 0

gtk_applies() {
  return 0
}

gtk_apply() {
  local src=$TNU_ROOT/assets/rewaita/$VARIANT
  install_file "$src/gtk4.css" "$HOME/.config/gtk-4.0/gtk.css" 0644
  install_file "$src/gtk3.css" "$HOME/.config/gtk-3.0/gtk.css" 0644
  dset /org/gnome/desktop/interface/color-scheme "'prefer-dark'"
  dset /org/gnome/desktop/interface/accent-color "'purple'"
  dset /org/gnome/desktop/interface/gtk-theme "'Yaru-purple-dark'"
  dset /org/gnome/desktop/interface/icon-theme "'Yaru-purple-dark'"
}
