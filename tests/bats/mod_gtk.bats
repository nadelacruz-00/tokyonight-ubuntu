#!/usr/bin/env bats
# modules/30-gtk.sh

bats_require_minimum_version 1.5.0

load ../test_helper
load ../mods_helper

setup() { mods_setup 30-gtk.sh; }

@test "clean HOME apply" {
  run_install -y --only gtk
  assert_success
  assert_line --regexp '^gtk +CHANGED'
  cmp "$HOME/.config/gtk-4.0/gtk.css" "$TNU_ROOT/assets/rewaita/tokyonight/gtk4.css"
  cmp "$HOME/.config/gtk-3.0/gtk.css" "$TNU_ROOT/assets/rewaita/tokyonight/gtk3.css"
  [[ $(stat -c %a "$HOME/.config/gtk-4.0/gtk.css") == 644 ]]
  [[ $(dconf_get /org/gnome/desktop/interface/color-scheme) == "'prefer-dark'" ]]
  [[ $(dconf_get /org/gnome/desktop/interface/accent-color) == "'purple'" ]]
  [[ $(dconf_get /org/gnome/desktop/interface/gtk-theme) == "'Yaru-purple-dark'" ]]
  [[ $(dconf_get /org/gnome/desktop/interface/icon-theme) == "'Yaru-purple-dark'" ]]
}

@test "second run zero changes" {
  run_install -y --only gtk
  run_install -y --only gtk
  assert_success
  assert_line --regexp '^gtk +OK$'
}

@test "existing user gtk.css backed up and restored on uninstall" {
  mkdir -p "$HOME/.config/gtk-4.0"
  printf 'mine\n' >"$HOME/.config/gtk-4.0/gtk.css"
  dconf_put /org/gnome/desktop/interface/gtk-theme "'Adwaita'"
  run_install -y --only gtk
  assert_success
  run_install -y --uninstall
  assert_success
  [[ $(<"$HOME/.config/gtk-4.0/gtk.css") == mine ]]
  assert_file_not_exists "$HOME/.config/gtk-3.0/gtk.css"
  [[ $(dconf_get /org/gnome/desktop/interface/gtk-theme) == "'Adwaita'" ]]
  [[ -z $(dconf_get /org/gnome/desktop/interface/accent-color) ]]
}

@test "--variant storm installs storm css" {
  run_install -y --only gtk --variant storm
  assert_success
  cmp "$HOME/.config/gtk-4.0/gtk.css" "$TNU_ROOT/assets/rewaita/storm/gtk4.css"
  cmp "$HOME/.config/gtk-3.0/gtk.css" "$TNU_ROOT/assets/rewaita/storm/gtk3.css"
}

@test "switching variant then uninstall restores pre-install" {
  mkdir -p "$HOME/.config/gtk-3.0"
  printf 'mine3\n' >"$HOME/.config/gtk-3.0/gtk.css"
  local snap="$BATS_TEST_TMPDIR/snap"
  tree_snapshot "$HOME" >"$snap"
  run_install -y --only gtk
  run_install -y --only gtk --variant storm
  assert_success
  cmp "$HOME/.config/gtk-4.0/gtk.css" "$TNU_ROOT/assets/rewaita/storm/gtk4.css"
  run_install -y --uninstall
  assert_success
  [[ $(<"$HOME/.config/gtk-3.0/gtk.css") == mine3 ]]
  assert_file_not_exists "$HOME/.config/gtk-4.0/gtk.css"
  [[ -z $(dconf_get /org/gnome/desktop/interface/color-scheme) ]]
}
