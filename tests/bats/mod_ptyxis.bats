#!/usr/bin/env bats
# modules/60-ptyxis.sh

bats_require_minimum_version 1.5.0

load ../test_helper

P=/org/gnome/Ptyxis

setup() {
  setup_sandbox
  export NO_COLOR=1 TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  stub_enable ptyxis
}

@test "skipped without ptyxis" {
  stub_disable ptyxis
  run_install -y --only ptyxis
  assert_success
  assert_line --regexp '^ptyxis +SKIPPED'
  assert_equal "$(dconf_get $P/font-name)" ""
}

@test "creates profile with fresh 32-hex uuid when none" {
  run_install -y --only ptyxis
  assert_success
  assert_line --regexp '^ptyxis +CHANGED'
  local u
  u=$(dconf_get $P/default-profile-uuid)
  [[ $u =~ ^\'[0-9a-f]{32}\'$ ]]
  u=${u//\'/}
  assert_equal "$(dconf_get $P/profile-uuids)" "['$u']"
  assert_equal "$(dconf_get $P/Profiles/$u/label)" "'Tokyo Night'"
  assert_equal "$(dconf_get $P/Profiles/$u/palette)" "'Tokyo Night'"
  assert_equal "$(dconf_get $P/font-name)" "'JetBrainsMono Nerd Font 10'"
  assert_equal "$(dconf_get $P/use-system-font)" "false"
  assert_equal "$(dconf_get $P/interface-style)" "'dark'"
}

@test "reuses existing default profile, no new uuid" {
  local u
  u=$(printf '01234567%.0s' 1 2 3 4)
  dconf_put $P/default-profile-uuid "'$u'"
  dconf_put $P/profile-uuids "['$u']"
  dconf_put $P/Profiles/$u/label "'Mine'"
  run_install -y --only ptyxis
  assert_success
  assert_equal "$(dconf_get $P/default-profile-uuid)" "'$u'"
  assert_equal "$(dconf_get $P/profile-uuids)" "['$u']"
  assert_equal "$(dconf_get $P/Profiles/$u/label)" "'Mine'"
  assert_equal "$(dconf_get $P/Profiles/$u/palette)" "'Tokyo Night'"
  # exactly one profile directory was touched
  run grep -c "^$P/Profiles/" "$STUB_STATE/dconf.tsv"
  assert_output 2
}

@test "falls back to the first listed profile when no default is set" {
  local a b
  a=$(printf 'a%.0s' {1..32})
  b=$(printf 'b%.0s' {1..32})
  dconf_put $P/profile-uuids "['$a', '$b']"
  run_install -y --only ptyxis
  assert_success
  assert_equal "$(dconf_get $P/Profiles/$a/palette)" "'Tokyo Night'"
  assert_equal "$(dconf_get $P/Profiles/$b/palette)" ""
  assert_equal "$(dconf_get $P/default-profile-uuid)" ""
}

@test "storm palette name" {
  run_install -y --only ptyxis --variant storm
  assert_success
  local u
  u=$(dconf_get $P/default-profile-uuid)
  u=${u//\'/}
  assert_equal "$(dconf_get $P/Profiles/$u/palette)" "'Tokyo Night Storm'"
}

@test "second run zero changes" {
  run_install -y --only ptyxis
  assert_success
  local snap="$BATS_TEST_TMPDIR/db"
  cp "$STUB_STATE/dconf.tsv" "$snap"
  run_install -y --only ptyxis
  assert_success
  assert_line --regexp '^ptyxis +OK$'
  run diff "$snap" "$STUB_STATE/dconf.tsv"
  assert_success
}

@test "dry-run changes nothing" {
  run_install -y --only ptyxis --dry-run
  assert_success
  assert_equal "$(dconf_get $P/font-name)" ""
}

@test "uninstall resets created keys to UNSET" {
  run_install -y --only ptyxis
  assert_success
  run_install -y --uninstall
  assert_success
  run grep -c "^$P" "$STUB_STATE/dconf.tsv"
  assert_output 0
}
