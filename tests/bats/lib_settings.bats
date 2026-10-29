#!/usr/bin/env bats
# shellcheck disable=SC2016 # libsh scripts are single-quoted on purpose

bats_require_minimum_version 1.5.0

load ../test_helper
load ../lib_test_helper

setup() {
  lib_setup
}

K=/org/gnome/desktop/interface/color-scheme

@test "dget prints the value or nothing when unset" {
  dconf_put "$K" "'default'"
  run --separate-stderr libsh "dget $K; dget /org/x/unset"
  assert_success
  assert_output "'default'"
}

@test "dset no-op when equal" {
  dconf_put "$K" "'prefer-dark'"
  : >"$STUB_LOG"
  run --separate-stderr libsh "dset $K \"'prefer-dark'\"; module_changes test"
  assert_success
  assert_output 0
  refute_stub_called dconf write
  assert_dir_not_exists "$STATE_DIR"
}

@test "dset records UNSET then replay resets" {
  run --separate-stderr libsh "dset $K \"'prefer-dark'\"; module_changes test"
  assert_success
  assert_output 1
  assert_stub_called dconf "write $K \\\\'prefer-dark\\\\'$"
  run cat "$BACKUP/manifest.tsv"
  assert_output "$(printf 'dconf\t%s\tUNSET\t%s' "$K" "'prefer-dark'")"
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  assert_stub_called dconf "reset $K$"
  run dconf_get "$K"
  assert_output ""
}

@test "dset records old value then replay restores it" {
  dconf_put "$K" "'default'"
  run --separate-stderr libsh "dset $K \"'prefer-dark'\""
  assert_success
  run dconf_get "$K"
  assert_output "'prefer-dark'"
  run cut -f3 "$BACKUP/manifest.tsv"
  assert_output "'default'"
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  run dconf_get "$K"
  assert_output "'default'"
}

@test "dset twice in one run replays back to the first old value" {
  dconf_put "$K" "'default'"
  run --separate-stderr libsh "dset $K \"'prefer-light'\"; dset $K \"'prefer-dark'\""
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  [[ $stderr != *kept* ]]
  run dconf_get "$K"
  assert_output "'default'"
}

@test "replay keeps setting changed after install" {
  run --separate-stderr libsh "dset $K \"'prefer-dark'\""
  dconf_put "$K" "'prefer-light'"
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  [[ $stderr == *"kept $K (changed since install)"* ]]
  run dconf_get "$K"
  assert_output "'prefer-light'"
}

@test "dset in dry-run notes the change but writes nothing" {
  run --separate-stderr env DRY_RUN=1 bash -c "source \"\$TNU_ROOT/tests/lib_loader.bash\"; dset $K \"'prefer-dark'\"; module_changes test"
  assert_success
  assert_output 1
  refute_stub_called dconf write
  assert_dir_not_exists "$STATE_DIR"
  [[ $stderr == *"[dry-run]"* ]]
}

@test "gv_str escapes apostrophe and backslash" {
  run --separate-stderr libsh "gv_str \"Synthwave '84\"; gv_str 'a\\b'; gv_str ''"
  assert_success
  assert_line --index 0 "'Synthwave \\'84'"
  assert_line --index 1 "'a\\\\b'"
  assert_line --index 2 "''"
}

@test "gv_str value round-trips through dset and replay" {
  dconf_put /org/x/name "'old'"
  run --separate-stderr libsh 'dset /org/x/name "$(gv_str "Synthwave '"'"'84")"'
  assert_success
  run dconf_get /org/x/name
  assert_output "'Synthwave \\'84'"
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  run dconf_get /org/x/name
  assert_output "'old'"
}

@test "no bus uses dbus-run-session" {
  stub_enable dbus-run-session
  export DBUS_SESSION_BUS_ADDRESS=""
  run --separate-stderr libsh "dset $K \"'prefer-dark'\"; dset /org/x/b true"
  assert_success
  assert_stub_called dbus-run-session "-- dconf write $K \\\\'prefer-dark\\\\'$"
  local n
  n=$(grep -c 'no session bus: log out and back in to see changes' <<<"$stderr")
  [[ $n == 1 ]]
  run dconf_get /org/x/b
  assert_output true
}

@test "with a bus dconf is called directly" {
  stub_enable dbus-run-session
  run --separate-stderr libsh "dset $K \"'prefer-dark'\""
  assert_success
  refute_stub_called dbus-run-session
  [[ $stderr != *"no session bus"* ]]
}
