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

# gvs TEXT...: print gv_str of each TEXT, one per line (texts passed via env).
gvs() {
  local i=0 a
  for a in "$@"; do
    export "GV_$i=$a"
    i=$((i + 1))
  done
  export GV_N=$i
  run --separate-stderr libsh 'for ((i = 0; i < GV_N; i++)); do v="GV_$i"; gv_str "${!v}"; done'
}

@test "gv_str escapes apostrophe and backslash" {
  # GLib's canonical print form (what `dconf read` returns): double quotes when
  # the text contains an apostrophe, else single quotes.
  gvs "Synthwave '84" 'a\b' '' "say \"hi\" it's" "back\\'q" plain
  assert_success
  assert_line --index 0 "\"Synthwave '84\""
  assert_line --index 1 "'a\\\\b'"
  assert_line --index 2 "''"
  assert_line --index 3 "\"say \\\"hi\\\" it's\""
  assert_line --index 4 "\"back\\\\'q\""
  assert_line --index 5 "'plain'"
}

@test "gv_str escapes control and format characters like GLib under LANG=C" {
  export LANG=C LC_ALL=C
  gvs $'tab\there' $'zwj‍x' "Tokyonight Storm 🌪️" $'c\x01' $'nl\n'
  assert_success
  assert_line --index 0 "'tab\\there'"
  assert_line --index 1 "'zwj\\u200dx'"
  assert_line --index 2 "'Tokyonight Storm 🌪️'"
  assert_line --index 3 "'c\\u0001'"
  assert_line --index 4 "'nl\\n'"
}

@test "gv_str value round-trips through dset and replay" {
  dconf_put /org/x/name "'old'"
  export TXT="Synthwave '84"
  run --separate-stderr libsh 'dset /org/x/name "$(gv_str "$TXT")"'
  assert_success
  run dconf_get /org/x/name
  assert_output "\"Synthwave '84\""
  run cut -f4 "$BACKUP/manifest.tsv"
  assert_output "\"Synthwave '84\""
  # Second run: the canonical value already matches, so nothing changes.
  run --separate-stderr libsh 'dset /org/x/name "$(gv_str "$TXT")"; module_changes test'
  assert_output 1
  run grep -c . "$BACKUP/manifest.tsv"
  assert_output 1
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
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

@test "dset records dconf's canonical read-back and replay restores it" {
  dconf_put /org/x/l "['old']"
  export V1="['a','b']" V2="['a', 'b']"
  run --separate-stderr libsh 'dset /org/x/l "$V1"'
  assert_success
  [[ $stderr == *"dconf stores /org/x/l as ['a', 'b']"* ]]
  run cat "$BACKUP/manifest.tsv"
  assert_line --index 0 "$(printf 'dconf\t/org/x/l\t%s\t%s' "['old']" "$V1")"
  assert_line --index 1 "$(printf 'dconf\t/org/x/l\t%s\t%s' "['old']" "$V2")"
  # The canonical spelling compares equal on the next run.
  run --separate-stderr libsh 'dset /org/x/l "$V2"; module_changes test'
  assert_output 1
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  [[ $stderr != *kept* ]]
  run dconf_get /org/x/l
  assert_output "['old']"
}

@test "dset and replay against real dconf on a private bus" {
  if ! PATH=/usr/bin:/bin command -v dconf >/dev/null ||
    ! PATH=/usr/bin:/bin command -v dbus-run-session >/dev/null ||
    ! PATH=/usr/bin:/bin command -v dbus-daemon >/dev/null; then
    skip "real dconf / dbus-run-session not installed"
  fi
  local t="$BATS_TEST_TMPDIR/realhome"
  mkdir -p "$t/run"
  chmod 700 "$t/run"
  cat >"$BATS_TEST_TMPDIR/real.sh" <<'SH'
source "$TNU_ROOT/tests/lib_loader.bash"
k=/org/tokyonight-ubuntu-test/name
l=/org/tokyonight-ubuntu-test/list
dconf write "$k" "'before'"
dset "$k" "$(gv_str "Synthwave '84")"
dset "$k" "$(gv_str "Synthwave '84")"
dset "$l" "['a','b']"
dset "$l" "['a', 'b']"
echo "changes=$(module_changes test)"
echo "now=$(dget "$k")"
echo "nowlist=$(dget "$l")"
backup_replay "$STATE_DIR/backups/$RUN_ID"
echo "after=$(dget "$k")"
echo "list=$(dget "$l")"
SH
  # Private bus, temp HOME and runtime dir: the real session is never touched.
  run --separate-stderr env -u DBUS_SESSION_BUS_ADDRESS HOME="$t" XDG_CONFIG_HOME="$t/.config" \
    XDG_RUNTIME_DIR="$t/run" STATE_DIR="$t/state" PATH=/usr/bin:/bin \
    dbus-run-session -- bash "$BATS_TEST_TMPDIR/real.sh"
  assert_success
  assert_line 'changes=2'
  assert_line "now=\"Synthwave '84\""
  assert_line "nowlist=['a', 'b']"
  assert_line "after='before'"
  assert_line 'list='
  [[ $stderr != *kept* ]]
  assert_file_exists "$t/.config/dconf/user"
}
