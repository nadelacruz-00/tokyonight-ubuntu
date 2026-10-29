#!/usr/bin/env bats
# modules/40-shell-theme.sh

bats_require_minimum_version 1.5.0

load ../test_helper
load ../mods_helper

UUID=user-theme@gnome-shell-extensions.gcampax.github.com

setup() {
  mods_setup 40-shell-theme.sh
  stub_enable sudo apt-get
  mkdir -p "$SYS_ROOT/usr/share/gnome-shell/extensions/$UUID"
}

@test "skips with reason when user-theme is missing" {
  rmdir "$SYS_ROOT/usr/share/gnome-shell/extensions/$UUID"
  run_install -y --only shell-theme
  assert_success
  assert_line --regexp '^shell-theme +SKIPPED'
  assert_output --partial "user-theme extension is not installed"
  refute_stub_called apt-get
}

@test "--system installs gnome-shell-extensions via sudo" {
  rmdir "$SYS_ROOT/usr/share/gnome-shell/extensions/$UUID"
  run_install -y --only shell-theme --system
  assert_success
  assert_stub_called sudo
  assert_stub_called apt-get 'install -y gnome-shell-extensions'
  assert_stub_called apt-get 'update$'
  assert_file_exists "$HOME/.local/share/themes/rewaita/gnome-shell/gnome-shell.css"
}

@test "clean HOME apply" {
  run_install -y --only shell-theme
  assert_success
  assert_line --regexp '^shell-theme +CHANGED'
  cmp "$HOME/.local/share/themes/rewaita/gnome-shell/gnome-shell.css" "$TNU_ROOT/assets/rewaita/tokyonight/gnome-shell.css"
  [[ $(dconf_get /org/gnome/shell/extensions/user-theme/name) == "'rewaita'" ]]
  [[ $(dconf_get /org/gnome/shell/enabled-extensions) == "['$UUID']" ]]
  refute_stub_called apt-get
}

@test "enable list gets uuid once" {
  dconf_put /org/gnome/shell/enabled-extensions "['other@x', '$UUID']"
  run_install -y --only shell-theme
  assert_success
  [[ $(dconf_get /org/gnome/shell/enabled-extensions) == "['other@x', '$UUID']" ]]
  run_install -y --only shell-theme
  assert_line --regexp '^shell-theme +OK$'
  [[ $(dconf_get /org/gnome/shell/enabled-extensions) == "['other@x', '$UUID']" ]]
}

@test "second run zero changes" {
  run_install -y --only shell-theme
  run_install -y --only shell-theme
  assert_line --regexp '^shell-theme +OK$'
}

@test "existing user theme css backed up and restored on uninstall" {
  local css="$HOME/.local/share/themes/rewaita/gnome-shell/gnome-shell.css"
  mkdir -p "${css%/*}"
  printf 'mine\n' >"$css"
  dconf_put /org/gnome/shell/enabled-extensions "['other@x']"
  run_install -y --only shell-theme
  assert_success
  run_install -y --uninstall
  assert_success
  [[ $(<"$css") == mine ]]
  [[ $(dconf_get /org/gnome/shell/enabled-extensions) == "['other@x']" ]]
  [[ -z $(dconf_get /org/gnome/shell/extensions/user-theme/name) ]]
}

@test "--variant storm installs storm css" {
  run_install -y --only shell-theme --variant storm
  assert_success
  cmp "$HOME/.local/share/themes/rewaita/gnome-shell/gnome-shell.css" "$TNU_ROOT/assets/rewaita/storm/gnome-shell.css"
}

@test "switching variant then uninstall restores pre-install" {
  run_install -y --only shell-theme
  run_install -y --only shell-theme --variant storm
  assert_success
  cmp "$HOME/.local/share/themes/rewaita/gnome-shell/gnome-shell.css" "$TNU_ROOT/assets/rewaita/storm/gnome-shell.css"
  run_install -y --uninstall
  assert_success
  assert_file_not_exists "$HOME/.local/share/themes/rewaita/gnome-shell/gnome-shell.css"
  assert_dir_not_exists "$HOME/.local/share/themes/rewaita"
  [[ -z $(dconf_get /org/gnome/shell/enabled-extensions) ]]
}
