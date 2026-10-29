#!/usr/bin/env bats
# modules/20-rewaita.sh

bats_require_minimum_version 1.5.0

load ../test_helper
load ../mods_helper

APP=io.github.swordpuffin.rewaita

setup() {
  mods_setup 20-rewaita.sh
  stub_enable flatpak apt-get sudo
  PREFS="$HOME/.var/app/$APP/data/prefs.json"
}

pref() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])' "$PREFS" "$1"; }

@test "skips with reason when flatpak is missing" {
  stub_disable flatpak
  run_install -y --only rewaita
  assert_success
  assert_line --regexp '^rewaita +SKIPPED'
  assert_output --partial "flatpak is not installed"
  refute_stub_called apt-get
}

@test "--system installs flatpak via sudo apt-get" {
  stub_disable flatpak
  run_install -y --only rewaita --system
  # The stub is absent for the whole run, so later flatpak calls cannot succeed.
  assert_stub_called sudo
  assert_stub_called apt-get 'install -y flatpak'
  assert_stub_called apt-get 'update$'
}

@test "rewaita skipped offline" {
  run_install -y --only rewaita --offline
  assert_success
  assert_line --regexp '^rewaita +SKIPPED'
  assert_output --partial "offline"
  refute_stub_called flatpak
}

@test "clean HOME apply" {
  LANG=C LC_ALL=C run_install -y --only rewaita
  assert_success
  assert_line --regexp '^rewaita +CHANGED'
  assert_stub_called flatpak 'remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo'
  assert_stub_called flatpak "install --user -y --noninteractive flathub $APP"
  refute_stub_called apt-get
  [[ $(pref dark-theme) == "Tokyonight 🗼.css" ]]
  [[ $(pref light-theme) == "Tokyonight 🗼.css" ]]
  [[ $(pref window-controls) == mint ]]
  [[ $(pref accent) == "'blue'" ]]
  [[ $(pref modify-gtk3-theme) == True ]]
  [[ $(pref modify-gnome-shell) == True ]]
}

@test "second run zero changes" {
  run_install -y --only rewaita
  run_install -y --only rewaita
  assert_success
  assert_line --regexp '^rewaita +OK$'
}

@test "rewaita prefs keeps unknown keys" {
  mkdir -p "${PREFS%/*}"
  printf '{"zoom": 3, "dark-theme": "Other.css"}\n' >"$PREFS"
  : >"$STUB_STATE/flatpak/$APP"
  run_install -y --only rewaita
  assert_success
  [[ $(pref zoom) == 3 ]]
  [[ $(pref dark-theme) == "Tokyonight 🗼.css" ]]
  refute_stub_called flatpak '^install'
  run_install -y --uninstall
  assert_success
  [[ $(pref dark-theme) == "Other.css" ]]
}

@test "--variant storm writes storm prefs name" {
  LANG=C LC_ALL=C run_install -y --only rewaita --variant storm
  assert_success
  [[ $(pref dark-theme) == "Tokyonight Storm 🌪️.css" ]]
  [[ $(pref light-theme) == "Tokyonight 🗼.css" ]]
}

@test "switching variant then uninstall restores pre-install" {
  run_install -y --only rewaita
  run_install -y --only rewaita --variant storm
  assert_success
  [[ $(pref dark-theme) == "Tokyonight Storm 🌪️.css" ]]
  run_install -y --uninstall
  assert_success
  assert_file_not_exists "$PREFS"
  assert_dir_not_exists "$HOME/.var"
  # The flatpak stays without --purge.
  refute_stub_called flatpak '^uninstall'
}

@test "edited prefs are kept on uninstall" {
  run_install -y --only rewaita
  printf '{"mine": 1}\n' >"$PREFS"
  run_install -y --uninstall
  assert_success
  assert_output --partial "kept"
  [[ $(pref mine) == 1 ]]
}

@test "rewaita purge uninstalls flatpak" {
  run_install -y --only rewaita
  run_install -y --uninstall --purge
  assert_success
  assert_stub_called flatpak "uninstall --user -y .*$APP"
  assert_file_not_exists "$PREFS"
}

@test "dry-run changes nothing but reports prefs" {
  local snap="$BATS_TEST_TMPDIR/snap"
  tree_snapshot "$HOME" >"$snap"
  run_install -y --only rewaita --dry-run
  assert_success
  assert_tree_unchanged "$snap" "$HOME"
  refute_stub_called flatpak '^install'
}

@test "the pkg flatpak row is written before the install (a failed install stays purgeable)" {
  STUB_FLATPAK_INSTALL_FAIL=1 run_install -y --only rewaita
  assert_failure 1
  run grep -F $'pkg\tflatpak\t'"$APP" "$XDG_STATE_HOME"/tokyonight-ubuntu/backups/*/manifest.tsv
  assert_success
}
