#!/usr/bin/env bats
# modules/80-osk.sh

bats_require_minimum_version 1.5.0

load ../test_helper

K=/org/gnome/shell/extensions/gjsosk
UUID=gjsosk-theme-sync@nadelacruz-00.github.io

setup() {
  setup_sandbox
  export NO_COLOR=1 TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  EXT="$XDG_DATA_HOME/gnome-shell/extensions/$UUID"
  STATE="$XDG_STATE_HOME/tokyonight-ubuntu"
  mkdir -p "$SYS_ROOT/usr/share/gnome-shell/extensions/gjsosk@vishram1123.com"
  stub_enable sudo
}

with_cache() { # with_cache KEYMAP
  mkdir -p "$XDG_CACHE_HOME/gjs-osk/keycodes"
  cp "$TNU_ROOT/tests/fixtures/osk/$1.json" "$XDG_CACHE_HOME/gjs-osk/keycodes/$1.json"
}

make_erhai() {
  mkdir -p "$SYS_ROOT/usr/share/gnome-shell/theme/erhai"
  : >"$SYS_ROOT/usr/share/gnome-shell/theme/erhai/gnome-shell-theme.gresource"
}

@test "skipped without gjsosk" {
  rm -rf "$SYS_ROOT/usr/share/gnome-shell/extensions/gjsosk@vishram1123.com"
  run_install -y --only osk
  assert_success
  assert_line --regexp '^osk +SKIPPED'
  assert_dir_not_exists "$EXT"
}

@test "installs extension and enables it" {
  run_install -y --only osk
  assert_success
  assert_file_exists "$EXT/extension.js"
  assert_file_exists "$EXT/metadata.json"
  assert_file_exists "$EXT/palette.js"
  assert_output --partial "log out and back in to load new extensions"
  assert_equal "$(dconf_get /org/gnome/shell/enabled-extensions)" "['$UUID']"
  # the extension dir is recorded so uninstall can remove it
  run grep -F "dir"$'\t'"$EXT" "$STATE"/backups/*/manifest.tsv
  assert_success
}

@test "writes sizing keys and never default-monitor" {
  run_install -y --only osk
  assert_success
  assert_equal "$(dconf_get $K/landscape-width-percent)" 48
  assert_equal "$(dconf_get $K/landscape-height-percent)" 28
  assert_equal "$(dconf_get $K/portrait-width-percent)" 100
  assert_equal "$(dconf_get $K/portrait-height-percent)" 35
  assert_equal "$(dconf_get $K/outer-spacing-px)" 6
  assert_equal "$(dconf_get $K/border-spacing-px)" 2
  assert_equal "$(dconf_get $K/font-size-px)" 16
  assert_equal "$(dconf_get $K/font-bold)" true
  assert_equal "$(dconf_get $K/round-key-corners)" false
  assert_equal "$(dconf_get $K/show-icons)" false
  assert_equal "$(dconf_get $K/system-accent-col)" false
  refute_stub_called dconf 'write [^ ]*default-monitor'
}

@test "missing keycode cache warns and still succeeds" {
  run_install -y --only osk
  assert_success
  assert_output --partial "open the on-screen keyboard once, then re-run to apply the split layout"
  assert_file_exists "$EXT/extension.js"
  assert_equal "$(dconf_get $K/custom-layout)" ""
  assert_equal "$(dconf_get $K/layout-landscape)" ""
}

@test "layouts index points at split entry" {
  dconf_put /org/gnome/desktop/input-sources/sources "[('xkb', 'us+colemak')]"
  with_cache us+colemak
  run_install -y --only osk
  assert_success
  refute_output --partial "open the on-screen keyboard"
  assert_equal "$(dconf_get $K/layout-landscape)" 10
  assert_equal "$(dconf_get $K/layout-portrait)" 11
  local lit
  lit=$(dconf_get $K/custom-layout)
  run python3 -I -c '
import json, sys
sys.path.insert(0, sys.argv[1] + "/helpers")
import osk_layouts as o
items = json.loads(o.parse_gv_string(sys.argv[2]))
print(json.loads(items[10 - o.NUM_BUILTIN])[-1]["name"], json.loads(items[11 - o.NUM_BUILTIN])[-1]["name"])
' "$TNU_ROOT" "$lit"
  assert_output "gboard-qwerty-split gboard-qwerty-portrait"
}

@test "defaults to the us keymap without input sources" {
  with_cache us
  run_install -y --only osk
  assert_success
  assert_equal "$(dconf_get $K/layout-landscape)" 10
}

@test "re-run keeps one copy of gboard layouts" {
  local mine='["[[{\"key\":\"ESC\"}],{\"name\":\"mine\"}]"]'
  dconf_put /org/gnome/desktop/input-sources/sources "[('xkb', 'us+colemak')]"
  with_cache us+colemak
  dconf_put $K/custom-layout "'${mine//\\/\\\\}'"
  run_install -y --only osk
  assert_success
  assert_equal "$(dconf_get $K/layout-landscape)" 11
  local snap="$BATS_TEST_TMPDIR/db"
  cp "$STUB_STATE/dconf.tsv" "$snap"
  run_install -y --only osk
  assert_success
  assert_line --regexp '^osk +OK$'
  run diff "$snap" "$STUB_STATE/dconf.tsv"
  assert_success
  run grep -o 'gboard-qwerty-split' <<<"$(dconf_get $K/custom-layout)"
  assert_equal "${#lines[@]}" 1
  assert_equal "$(dconf_get $K/layout-landscape)" 11
  assert_equal "$(dconf_get $K/layout-portrait)" 12
}

@test "split-flush only with --system on erhai" {
  local sbin="$SYS_ROOT/usr/local/sbin/gjsosk-split-flush"
  local apt="$SYS_ROOT/etc/apt/apt.conf.d/99erhai-gjsosk-split-flush"
  # erhai without --system, and --system without erhai: nothing
  make_erhai
  run_install -y --only osk
  assert_success
  assert_file_not_exists "$sbin"
  rm -rf "$SYS_ROOT/usr/share/gnome-shell/theme"
  run_install -y --only osk --system
  assert_success
  assert_file_not_exists "$sbin"
  refute_stub_called sudo '(-- )?(install|env)'
  # erhai with --system: installed, recorded, reapplied
  make_erhai
  run_install -y --only osk --system
  assert_success
  assert_file_exists "$sbin"
  assert_file_exists "$apt"
  assert_equal "$(stat -c %a "$sbin")" 755
  assert_equal "$(stat -c %a "$apt")" 644
  run grep -F "sysfile"$'\t'"$sbin"$'\t' "$STATE"/backups/*/manifest.tsv
  assert_success
  run grep -F "sysfile"$'\t'"$apt"$'\t' "$STATE"/backups/*/manifest.tsv
  assert_success
  assert_stub_called sudo '.*gjsosk-split-flush reapply'
  # re-run converges
  run_install -y --only osk --system
  assert_success
  assert_line --regexp '^osk +OK$'
}

@test "uninstall --system removes split-flush files" {
  make_erhai
  run_install -y --only osk --system
  assert_success
  run_install -y --uninstall --system
  assert_success
  assert_file_not_exists "$SYS_ROOT/usr/local/sbin/gjsosk-split-flush"
  assert_file_not_exists "$SYS_ROOT/etc/apt/apt.conf.d/99erhai-gjsosk-split-flush"
  assert_dir_not_exists "$EXT"
}
