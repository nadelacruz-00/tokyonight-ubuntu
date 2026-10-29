#!/usr/bin/env bats
# shellcheck disable=SC2016 # libsh scripts are single-quoted on purpose
# lib/edit.sh (marked blocks, single lines, their replay) and ext_enable.

bats_require_minimum_version 1.5.0

load ../test_helper
load ../lib_test_helper

setup() {
  lib_setup
  BEGIN='# >>> tokyonight-ubuntu >>>'
  END='# <<< tokyonight-ubuntu <<<'
}

@test "block_upsert creates file and records CREATED=1" {
  run --separate-stderr libsh 'printf "eval x\n" | block_upsert "$HOME/.zshrc"; module_changes test'
  assert_success
  assert_output 1
  run cat "$HOME/.zshrc"
  assert_output "$(printf '%s\neval x\n%s' "$BEGIN" "$END")"
  run cat "$BACKUP/manifest.tsv"
  assert_output "$(printf 'block\t%s\t1' "$HOME/.zshrc")"
}

@test "block_upsert replaces existing block in place" {
  printf 'before\n%s\nold\n%s\nafter\n' "$BEGIN" "$END" >"$HOME/.zshrc"
  chmod 600 "$HOME/.zshrc"
  run --separate-stderr libsh 'printf "new 1\nnew 2\n" | block_upsert "$HOME/.zshrc"'
  assert_success
  run cat "$HOME/.zshrc"
  assert_output "$(printf 'before\n%s\nnew 1\nnew 2\n%s\nafter' "$BEGIN" "$END")"
  [[ $(stat -c %a "$HOME/.zshrc") == 600 ]]
  assert_file_contains "$BACKUP/manifest.tsv" "$(printf '^block\t.*\t0$')"
}

@test "block_upsert second run no change" {
  run --separate-stderr libsh 'printf "body\n" | block_upsert "$HOME/.zshrc"'
  assert_success
  local before
  before=$(sha256sum <"$HOME/.zshrc")
  run --separate-stderr libsh 'RUN_ID=second RUN_DIR=$BATS_TEST_TMPDIR/run2; mkdir "$RUN_DIR"
    printf "body\n" | block_upsert "$HOME/.zshrc"; module_changes test >&2
    DRY_RUN=1; printf "body\n" | block_upsert "$HOME/.zshrc"; module_changes test'
  assert_success
  assert_output 0
  [[ $(sha256sum <"$HOME/.zshrc") == "$before" ]]
  assert_dir_not_exists "$STATE_DIR/backups/second"
}

@test "block_upsert in dry-run counts the change but writes nothing" {
  run --separate-stderr libsh 'DRY_RUN=1; printf "body\n" | block_upsert "$HOME/.config/new/rc"; module_changes test'
  assert_success
  assert_output 1
  assert_dir_not_exists "$HOME/.config"
  assert_dir_not_exists "$STATE_DIR"
}

@test "uninstall removes block and deletes file it created when only block remained" {
  run --separate-stderr libsh 'printf "body\n" | block_upsert "$HOME/.config/tnu dir/rc"'
  assert_success
  assert_file_exists "$HOME/.config/tnu dir/rc"
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  assert_file_not_exists "$HOME/.config/tnu dir/rc"
  # The parent dirs it created are gone too.
  assert_dir_not_exists "$HOME/.config"
}

@test "uninstall removes block from a pre-existing file byte-for-byte" {
  printf 'line 1\nline 2' >"$HOME/.bashrc"
  local orig
  orig=$(sha256sum <"$HOME/.bashrc")
  run --separate-stderr libsh 'printf "v1\n" | block_upsert "$HOME/.bashrc"'
  run --separate-stderr libsh 'RUN_ID=second; printf "v2\n" | block_upsert "$HOME/.bashrc"'
  assert_file_contains "$HOME/.bashrc" '^v2$'
  run --separate-stderr libsh 'for d in $(backup_list); do backup_replay "$d"; done'
  assert_success
  [[ $(sha256sum <"$HOME/.bashrc") == "$orig" ]]
}

@test "created file with user lines added is kept on uninstall" {
  run --separate-stderr libsh 'printf "body\n" | block_upsert "$HOME/.zshrc"'
  printf 'user line\n' >>"$HOME/.zshrc"
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  run cat "$HOME/.zshrc"
  assert_output "user line"
}

@test "block_upsert edits a symlink's target and keeps the link" {
  mkdir -p "$HOME/dotfiles"
  printf 'mine\n' >"$HOME/dotfiles/zshrc"
  ln -s dotfiles/zshrc "$HOME/.zshrc"
  run --separate-stderr libsh 'printf "body\n" | block_upsert "$HOME/.zshrc"'
  assert_success
  [[ -L $HOME/.zshrc ]]
  assert_file_contains "$HOME/dotfiles/zshrc" '^body$'
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  [[ -L $HOME/.zshrc ]]
  run cat "$HOME/dotfiles/zshrc"
  assert_output "mine"
}

@test "set_line replaces only uncommented key" {
  printf '# theme "old"\ntheme "dracula"\nkeybinds {}\n' >"$HOME/config.kdl"
  run --separate-stderr libsh 'set_line "$HOME/config.kdl" "^theme\\s+\"" "theme \"tokyo-night-storm\""; module_changes test'
  assert_success
  assert_output 1
  run cat "$HOME/config.kdl"
  assert_output "$(printf '# theme "old"\ntheme "tokyo-night-storm"\nkeybinds {}')"
  run --separate-stderr libsh 'RUN_ID=second RUN_DIR=$BATS_TEST_TMPDIR/run2; mkdir "$RUN_DIR"
    set_line "$HOME/config.kdl" "^theme\\s+\"" "theme \"tokyo-night-storm\""; module_changes test'
  assert_output 0
  assert_dir_not_exists "$STATE_DIR/backups/second"
}

@test "uninstall restores old line" {
  printf 'a = 1\n[ui]\ntheme = "x"\n\n[other]\ntheme = "keep"\n' >"$HOME/config.toml"
  local orig
  orig=$(sha256sum <"$HOME/config.toml")
  run --separate-stderr libsh 'set_line "$HOME/config.toml" "^theme\\s*=" "theme = \"tokyonight\"" ui'
  assert_success
  assert_file_contains "$HOME/config.toml" '^theme = "tokyonight"$'
  assert_file_contains "$HOME/config.toml" '^theme = "keep"$'
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  [[ $(sha256sum <"$HOME/config.toml") == "$orig" ]]
}

@test "uninstall removes an added line and keeps a user-changed one" {
  printf '[ui]\nfoo = 1\n' >"$HOME/a.toml"
  printf 'theme "x"\n' >"$HOME/b.kdl"
  run --separate-stderr libsh 'set_line "$HOME/a.toml" "^theme\\s*=" "theme = \"tokyonight\"" ui
    set_line "$HOME/b.kdl" "^theme\\s+\"" "theme \"tokyo-night-storm\""'
  assert_success
  assert_file_contains "$HOME/a.toml" '^theme = "tokyonight"$'
  printf 'theme "mine"\n' >"$HOME/b.kdl"
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  [[ $stderr == *"kept $HOME/b.kdl (changed since install)"* ]]
  run cat "$HOME/a.toml"
  assert_output "$(printf '[ui]\nfoo = 1')"
  run cat "$HOME/b.kdl"
  assert_output 'theme "mine"'
}

@test "set_line round-trips tabs and backslashes through the manifest" {
  printf 'theme\t"a\\\\b"\n' >"$HOME/t.kdl"
  local orig
  orig=$(sha256sum <"$HOME/t.kdl")
  run --separate-stderr libsh 'set_line "$HOME/t.kdl" "^theme\\s" "theme	\"c\\\\d\""'
  assert_success
  assert_file_contains "$HOME/t.kdl" "$(printf '^theme\t"c\\\\\\\\d"$')"
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  [[ $(sha256sum <"$HOME/t.kdl") == "$orig" ]]
}

@test "set_line on a missing file creates it and uninstall removes it" {
  run --separate-stderr libsh 'set_line "$HOME/.config/lig/config.toml" "^theme\\s*=" "theme = \"tokyonight\"" ui'
  assert_success
  run cat "$HOME/.config/lig/config.toml"
  assert_output "$(printf '[ui]\ntheme = "tokyonight"')"
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  assert_dir_not_exists "$HOME/.config"
}

@test "CRLF file keeps CRLF" {
  printf 'a\r\ntheme = "x"\r\n' >"$HOME/crlf.toml"
  local orig
  orig=$(sha256sum <"$HOME/crlf.toml")
  run --separate-stderr libsh 'set_line "$HOME/crlf.toml" "^theme\\s*=" "theme = \"y\""
    printf "b1\nb2\n" | block_upsert "$HOME/crlf.toml"'
  assert_success
  run cat "$HOME/crlf.toml"
  assert_output "$(printf 'a\r\ntheme = "y"\r\n%s\r\nb1\r\nb2\r\n%s\r' "$BEGIN" "$END")"
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  [[ $(sha256sum <"$HOME/crlf.toml") == "$orig" ]]
}

@test "ext_enable adds once and removes from disabled list" {
  local u=gjsosk-theme-sync@nadelacruz-00.github.io
  dconf_put /org/gnome/shell/disabled-extensions "['other@x', '$u']"
  run --separate-stderr libsh 'ext_enable '"$u"'; RUN_ID=second; ext_enable '"$u"'; module_changes test'
  assert_success
  assert_output 2
  [[ $(dconf_get /org/gnome/shell/enabled-extensions) == "['$u']" ]]
  [[ $(dconf_get /org/gnome/shell/disabled-extensions) == "['other@x']" ]]
  assert_dir_not_exists "$STATE_DIR/backups/second"
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  [[ -z $(dconf_get /org/gnome/shell/enabled-extensions) ]]
  [[ $(dconf_get /org/gnome/shell/disabled-extensions) == "['other@x', '$u']" ]]
}

@test "ext_enable appends to an existing list" {
  dconf_put /org/gnome/shell/enabled-extensions "['a@b']"
  run --separate-stderr libsh 'ext_enable c@d'
  assert_success
  [[ $(dconf_get /org/gnome/shell/enabled-extensions) == "['a@b', 'c@d']" ]]
}
