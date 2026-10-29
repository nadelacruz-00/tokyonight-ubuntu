#!/usr/bin/env bats
# modules/50-wallpaper.sh

bats_require_minimum_version 1.5.0

load ../test_helper
load ../mods_helper

W=/usr/share/backgrounds/osselo-Ask_a_friend.jpg
URI="'file://$W'"

setup() {
  mods_setup 50-wallpaper.sh
  stub_enable sudo apt-get
  mkdir -p "$SYS_ROOT/usr/share/backgrounds"
  : >"$SYS_ROOT$W"
}

@test "skipped when file missing without --system" {
  rm "$SYS_ROOT$W"
  run_install -y --only wallpaper
  assert_success
  assert_line --regexp '^wallpaper +SKIPPED'
  assert_output --partial "$W is missing"
  [[ -z $(dconf_get /org/gnome/desktop/background/picture-uri) ]]
}

@test "--system installs package via sudo" {
  rm "$SYS_ROOT$W"
  run_install -y --only wallpaper --system
  assert_success
  assert_stub_called sudo
  assert_stub_called apt-get 'install -y ubuntu-wallpapers-resolute'
  assert_stub_called apt-get 'update$'
  [[ $(dconf_get /org/gnome/desktop/background/picture-uri) == "$URI" ]]
}

@test "clean HOME apply" {
  run_install -y --only wallpaper
  assert_success
  assert_line --regexp '^wallpaper +CHANGED'
  [[ $(dconf_get /org/gnome/desktop/background/picture-uri) == "$URI" ]]
  [[ $(dconf_get /org/gnome/desktop/background/picture-uri-dark) == "$URI" ]]
  [[ $(dconf_get /org/gnome/desktop/screensaver/picture-uri) == "$URI" ]]
  [[ $(dconf_get /org/gnome/desktop/background/picture-options) == "'zoom'" ]]
  refute_stub_called apt-get
}

@test "second run zero changes" {
  run_install -y --only wallpaper
  run_install -y --only wallpaper
  assert_line --regexp '^wallpaper +OK$'
}

@test "previous wallpaper restored on uninstall" {
  dconf_put /org/gnome/desktop/background/picture-uri "'file:///old.jpg'"
  run_install -y --only wallpaper
  run_install -y --only wallpaper --variant storm
  assert_success
  run_install -y --uninstall
  assert_success
  [[ $(dconf_get /org/gnome/desktop/background/picture-uri) == "'file:///old.jpg'" ]]
  [[ -z $(dconf_get /org/gnome/desktop/background/picture-uri-dark) ]]
  [[ -z $(dconf_get /org/gnome/desktop/background/picture-options) ]]
}
