#!/usr/bin/env bats
# shellcheck disable=SC2016 # libsh scripts are single-quoted on purpose

bats_require_minimum_version 1.5.0

load ../test_helper
load ../lib_test_helper

setup() {
  lib_setup
}

@test "backup_file without a row creates no manifest and nothing to list" {
  echo x >"$HOME/f"
  run --separate-stderr libsh 'backup_file "$HOME/f"; backup_list'
  assert_success
  assert_output ""
  assert_file_exists "$BACKUP/files/1"
  assert_file_not_exists "$BACKUP/manifest.tsv"
}

@test "no rows means no backup dir" {
  echo same >"$HOME/f"
  echo same >"$BATS_TEST_TMPDIR/src"
  run --separate-stderr libsh 'install_file "$BATS_TEST_TMPDIR/src" "$HOME/f"
    DRY_RUN=1 backup_record dir "$HOME/x"; DRY_RUN=1 backup_file "$HOME/f"; backup_list'
  assert_success
  assert_output ""
  assert_dir_not_exists "$STATE_DIR"
}

@test "field with tab is rejected" {
  run --separate-stderr libsh 'backup_record file "$HOME/a"$'"'"'\t'"'"'b files/1 x'
  assert_failure
  [[ $stderr == *tab* ]]
  run --separate-stderr libsh 'backup_record dir "$HOME/a"$'"'"'\n'"'"'b'
  assert_failure
  assert_file_not_exists "$BACKUP/manifest.tsv"
}

@test "backup_record appends TAB-separated rows and backup_dir echoes the dir" {
  run --separate-stderr libsh 'backup_record dconf /org/x/a UNSET "'"'"'v w'"'"'"; backup_dir'
  assert_success
  assert_output "$BACKUP"
  run cat "$BACKUP/manifest.tsv"
  assert_output $'dconf\t/org/x/a\tUNSET\t\'v w\''
}

@test "append after a torn row poisons it with TORN and starts a new line" {
  run --separate-stderr libsh 'backup_record dir "$HOME/one"'
  printf 'file\t/torn' >>"$BACKUP/manifest.tsv"
  run --separate-stderr libsh 'backup_record dir "$HOME/two"'
  run tail -n 2 "$BACKUP/manifest.tsv"
  assert_line --index 0 $'file\t/torn\tTORN'
  assert_line --index 1 "$(printf 'dir\t%s' "$HOME/two")"
}

@test "a torn well-formed pkg row is never replayed, even with purge" {
  mkdir -p "$HOME/.local/share"
  echo precious >"$HOME/.local/share/data"
  # Even with a dir row for it (so only the TORN poison protects it).
  run --separate-stderr libsh 'backup_record dir "$HOME/.local"'
  # Crash mid-write: the cut-off row happens to have the right field count.
  printf 'pkg\tfontdir\t%s' "$HOME/.local" >>"$BACKUP/manifest.tsv"
  run --separate-stderr libsh 'backup_record pkg bin "$HOME/nonexistent-bin"'
  run --separate-stderr libsh 'backup_replay "$BACKUP" 1'
  assert_success
  [[ $stderr == *"torn row"* ]]
  assert_file_exists "$HOME/.local/share/data"
}

@test "purge removes only dirs this manifest created" {
  mkdir -p "$HOME/.local/share/fonts/JetBrainsMonoNerd"
  echo user >"$HOME/.local/share/fonts/JetBrainsMonoNerd/user.ttf"
  run --separate-stderr libsh 'backup_record pkg fontdir "$HOME/.local/share/fonts/JetBrainsMonoNerd"'
  run --separate-stderr libsh 'backup_replay "$BACKUP" 1'
  assert_success
  [[ $stderr == *"not created by this install"* ]]
  assert_file_exists "$HOME/.local/share/fonts/JetBrainsMonoNerd/user.ttf"
}

@test "backup copies and atomic_write temp files are fsynced" {
  printf '#!/usr/bin/env bash\nprintf "sync\\t%%s\\n" "$*" >>"$STUB_LOG"\nexec /usr/bin/sync "$@"\n' >"$BATS_TEST_TMPDIR/bin/sync"
  chmod +x "$BATS_TEST_TMPDIR/bin/sync"
  echo orig >"$HOME/f"
  echo new >"$BATS_TEST_TMPDIR/src"
  run --separate-stderr libsh 'install_file "$BATS_TEST_TMPDIR/src" "$HOME/f"'
  assert_success
  assert_stub_called sync '-- .*/files/1$'
  assert_stub_called sync '-- .*/\.tnu\.tmp\.'
  assert_stub_called sync '-- .*/manifest\.tsv$'
}

@test "backup_list prints backup dirs newest first, excluding .restored" {
  local b=$STATE_DIR/backups
  mkdir -p "$b/20261029T000001Z" "$b/20261029T000003Z" "$b/20261029T000002Z" "$b/.restored/20261029T000000Z" \
    "$b/20261029T000004Z" "$b/20261029T000005Z"
  local d
  for d in 20261029T000001Z 20261029T000003Z 20261029T000002Z .restored/20261029T000000Z; do
    printf 'dir\t/x\n' >"$b/$d/manifest.tsv"
  done
  # 000004Z: empty manifest, 000005Z: none (backup_file without a row) -> not listed.
  : >"$b/20261029T000004Z/manifest.tsv"
  run --separate-stderr libsh backup_list
  assert_success
  assert_output "$(printf '%s\n' "$b/20261029T000003Z" "$b/20261029T000002Z" "$b/20261029T000001Z")"
}

@test "replay restores file byte-for-byte" {
  mkdir -p "$HOME/.config"
  printf 'orig\r\nbytes\x01 no newline' >"$HOME/.config/x.css"
  chmod 640 "$HOME/.config/x.css"
  cp -a "$HOME/.config/x.css" "$BATS_TEST_TMPDIR/orig"
  echo new >"$BATS_TEST_TMPDIR/src"
  run --separate-stderr libsh 'install_file "$BATS_TEST_TMPDIR/src" "$HOME/.config/x.css" 0644'
  assert_success
  cmp "$BATS_TEST_TMPDIR/src" "$HOME/.config/x.css"
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  cmp "$BATS_TEST_TMPDIR/orig" "$HOME/.config/x.css"
  run stat -c %a "$HOME/.config/x.css"
  assert_output 640
  run find "$HOME" -name '*.tmp*'
  assert_output ""
}

@test "replay deletes file that was ABSENT" {
  mkdir -p "$HOME/.config"
  echo new >"$BATS_TEST_TMPDIR/src"
  run --separate-stderr libsh 'install_file "$BATS_TEST_TMPDIR/src" "$HOME/.config/new.css"'
  assert_success
  assert_file_contains "$BACKUP/manifest.tsv" $'\tABSENT\t'
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  assert_file_not_exists "$HOME/.config/new.css"
  assert_dir_exists "$HOME/.config"
}

@test "replay keeps file changed since install" {
  echo orig >"$HOME/f.css"
  echo new >"$BATS_TEST_TMPDIR/src"
  run --separate-stderr libsh 'install_file "$BATS_TEST_TMPDIR/src" "$HOME/f.css"'
  echo user-edit >"$HOME/f.css"
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  [[ $stderr == *"kept $HOME/f.css (changed since install)"* ]]
  assert_file_contains "$HOME/f.css" '^user-edit$'
}

@test "replay of a path written twice in one run restores the original without warnings" {
  echo orig >"$HOME/f.css"
  echo one >"$BATS_TEST_TMPDIR/s1"
  echo two >"$BATS_TEST_TMPDIR/s2"
  run --separate-stderr libsh 'install_file "$BATS_TEST_TMPDIR/s1" "$HOME/f.css"'
  run --separate-stderr libsh 'install_file "$BATS_TEST_TMPDIR/s2" "$HOME/f.css"'
  run ls "$BACKUP/files"
  assert_output 1
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  [[ $stderr != *kept* ]]
  assert_file_contains "$HOME/f.css" '^orig$'
}

@test "backup_file with a hash records an in-place edit" {
  echo '{"a":1}' >"$HOME/prefs.json"
  cp "$HOME/prefs.json" "$BATS_TEST_TMPDIR/orig"
  run --separate-stderr libsh 'backup_file "$HOME/prefs.json"
    echo "{\"a\":2}" >"$HOME/prefs.json"
    backup_file "$HOME/prefs.json" "$(sha256_of "$HOME/prefs.json")"'
  assert_success
  run grep -c . "$BACKUP/manifest.tsv"
  assert_output 1
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  cmp "$BATS_TEST_TMPDIR/orig" "$HOME/prefs.json"
}

@test "replay removes empty created dir but not non-empty one" {
  echo x >"$BATS_TEST_TMPDIR/src"
  run --separate-stderr libsh 'install_file "$BATS_TEST_TMPDIR/src" "$HOME/a/empty/f"
    install_file "$BATS_TEST_TMPDIR/src" "$HOME/b/full/f"'
  assert_success
  echo mine >"$HOME/b/full/user-file"
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  assert_dir_not_exists "$HOME/a"
  assert_file_not_exists "$HOME/b/full/f"
  assert_file_exists "$HOME/b/full/user-file"
}

@test "pkg rows replay only with purge" {
  stub_enable flatpak
  touch "$STUB_STATE/flatpak/io.example.App"
  mkdir -p "$HOME/.local/bin"
  echo bin >"$HOME/.local/bin/oh-my-posh"
  run --separate-stderr libsh 'backup_record dir "$HOME/fonts"; mkdir "$HOME/fonts"; echo f >"$HOME/fonts/a.ttf"
    backup_record pkg fontdir "$HOME/fonts"
    backup_record pkg bin "$HOME/.local/bin/oh-my-posh"
    backup_record pkg flatpak io.example.App'
  assert_success
  run --separate-stderr libsh 'backup_replay "$BACKUP" 0'
  assert_success
  assert_file_exists "$HOME/.local/bin/oh-my-posh"
  assert_file_exists "$HOME/fonts/a.ttf"
  refute_stub_called flatpak
  run --separate-stderr libsh 'backup_replay "$BACKUP" 1'
  assert_success
  assert_file_not_exists "$HOME/.local/bin/oh-my-posh"
  assert_dir_not_exists "$HOME/fonts"
  assert_stub_called flatpak 'uninstall --user .*io.example.App$'
}

@test "a dir listed in a pkg row is removed recursively on purge even if the pkg row comes first" {
  run --separate-stderr libsh 'backup_record pkg fontdir "$HOME/fonts"; backup_record dir "$HOME/fonts"'
  mkdir -p "$HOME/fonts/sub"
  echo f >"$HOME/fonts/sub/a.ttf"
  run --separate-stderr libsh 'backup_replay "$BACKUP" 1'
  assert_success
  assert_dir_not_exists "$HOME/fonts"
}

@test "manifest survives kill mid-write" {
  echo orig >"$HOME/f.css"
  echo new >"$BATS_TEST_TMPDIR/src"
  run --separate-stderr libsh 'install_file "$BATS_TEST_TMPDIR/src" "$HOME/f.css"'
  assert_success
  bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"
    i=0; while :; do i=$((i + 1)); backup_record dir "$HOME/gone $i"; done' 2>/dev/null &
  local pid=$!
  local n=0 tries=0
  while ((n < 20 && tries < 500)); do
    n=$(grep -c . "$BACKUP/manifest.tsv")
    tries=$((tries + 1))
    sleep 0.05
  done
  kill -9 "$pid"
  wait "$pid" || true
  # A row torn mid-write (no trailing newline) must not break replay.
  printf 'file\t%s\tfil' "$HOME/f.css" >>"$BACKUP/manifest.tsv"
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  assert_file_contains "$HOME/f.css" '^orig$'
  run find "$HOME" -maxdepth 1 -name 'gone *'
  assert_output ""
}

@test "emoji path round-trips" {
  export LANG=C LC_ALL=C
  local d="$HOME/.var/app/io.github.swordpuffin.rewaita/data/themes"
  mkdir -p "$d"
  printf 'storm original\n' >"$d/Tokyonight Storm 🌪️.css"
  printf 'replacement\n' >"$BATS_TEST_TMPDIR/src 🗼.css"
  run --separate-stderr env D="$d" bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"
    install_file "$BATS_TEST_TMPDIR/src 🗼.css" "$D/Tokyonight Storm 🌪️.css"
    install_file "$BATS_TEST_TMPDIR/src 🗼.css" "$D/Tokyonight 🗼.css"'
  assert_success
  assert_file_contains "$BACKUP/manifest.tsv" "Tokyonight Storm 🌪️.css"
  cmp "$BATS_TEST_TMPDIR/src 🗼.css" "$d/Tokyonight Storm 🌪️.css"
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_success
  assert_file_contains "$d/Tokyonight Storm 🌪️.css" '^storm original$'
  assert_file_not_exists "$d/Tokyonight 🗼.css"
}

@test "rows without a handler warn as unsupported and stay pending" {
  run --separate-stderr libsh 'unset -f _replay_block _replay_line
    backup_record block "$HOME/.zshrc" 1
    backup_record line "$HOME/.config/x" "^theme " ABSENT "theme \"tokyonight\"" ""
    backup_replay "$BACKUP"'
  # Not reported as done.
  assert_failure
  [[ $stderr == *"unsupported row type"* ]]
  assert_file_not_exists "$BACKUP/replayed"
}

@test "replay dispatches a row type to _replay_<type>" {
  run --separate-stderr libsh '_replay_block() { printf "handler:%s|%s|%s\n" "$2" "$3" "$4"; }
    backup_record block "$HOME/.zshrc" 1
    backup_replay "$BACKUP" 1'
  assert_success
  assert_output "handler:1|$HOME/.zshrc|1"
}

@test "replay applies rows in reverse order" {
  run --separate-stderr libsh '_replay_block() { echo "$3"; }
    backup_record block first 0; backup_record block second 0; backup_record block third 0
    backup_replay "$BACKUP"'
  assert_output $'third\nsecond\nfirst'
}

@test "sysfile and alt rows replay through sudo with --system" {
  stub_enable sudo update-alternatives
  local p="$SYS_ROOT/usr/share/gnome-shell/theme/tokyonight-ubuntu/gnome-shell-theme.gresource"
  mkdir -p "${p%/*}"
  echo built >"$p"
  run --separate-stderr env P="$p" bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"
    backup_record sysfile "$P" ABSENT "$(sha256_of "$P")"
    backup_record alt gdm-theme.gresource /usr/share/gnome-shell/theme/tokyonight-ubuntu/gnome-shell-theme.gresource'
  assert_success
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_failure
  [[ $stderr == *--system* ]]
  assert_file_exists "$p"
  refute_stub_called sudo
  run --separate-stderr env SYSTEM=1 bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"; backup_replay "$BACKUP"'
  assert_success
  assert_file_not_exists "$p"
  assert_stub_called sudo '-- update-alternatives --remove gdm-theme.gresource /usr/share/gnome-shell/theme/tokyonight-ubuntu/gnome-shell-theme.gresource$'
}

@test "sysfile replay restores a backed-up original" {
  stub_enable sudo
  local p="$SYS_ROOT/etc/x.conf"
  echo original >"$p"
  run --separate-stderr env P="$p" bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"
    ref=$(backup_copy "$P"); echo installed >"$P"
    backup_record sysfile "$P" "$ref" "$(sha256_of "$P")"'
  assert_success
  run --separate-stderr env SYSTEM=1 bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"; backup_replay "$BACKUP"'
  assert_success
  assert_file_contains "$p" '^original$'
}

@test "replay without --system finishes user rows, later --system finishes the rest" {
  stub_enable sudo update-alternatives
  echo orig >"$HOME/f.css"
  echo new >"$BATS_TEST_TMPDIR/src"
  dconf_put /org/x/k "'old'"
  local p="$SYS_ROOT/usr/share/tnu/theme.gresource"
  mkdir -p "${p%/*}"
  echo built >"$p"
  run --separate-stderr env P="$p" bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"
    install_file "$BATS_TEST_TMPDIR/src" "$HOME/f.css"
    dset /org/x/k "'"'"'new'"'"'"
    backup_record sysfile "$P" ABSENT "$(sha256_of "$P")"
    backup_record alt gdm-theme.gresource /usr/share/tnu/theme.gresource'
  assert_success
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  assert_failure
  [[ $stderr == *"--system"* ]]
  assert_file_contains "$HOME/f.css" '^orig$'
  run dconf_get /org/x/k
  assert_output "'old'"
  assert_file_exists "$p"
  refute_stub_called sudo
  # The user changes the restored file and setting before the --system replay.
  echo user >"$HOME/f.css"
  dconf_put /org/x/k "'user'"
  : >"$STUB_LOG"
  run --separate-stderr env SYSTEM=1 bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"; backup_replay "$BACKUP"'
  assert_success
  [[ $stderr != *kept* ]]
  [[ $stderr != *"$HOME/f.css"* ]]
  assert_file_contains "$HOME/f.css" '^user$'
  run dconf_get /org/x/k
  assert_output "'user'"
  refute_stub_called dconf 'write|reset'
  assert_file_not_exists "$p"
  assert_stub_called sudo '-- update-alternatives --remove gdm-theme.gresource'
  # Everything done: a third replay is a no-op that succeeds.
  : >"$STUB_LOG"
  run --separate-stderr env SYSTEM=1 bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"; backup_replay "$BACKUP"'
  assert_success
  refute_stub_called sudo
}

@test "pkg rows deferred without purge do not fail the replay and purge later" {
  mkdir -p "$HOME/.local/bin"
  echo bin >"$HOME/.local/bin/tool"
  run --separate-stderr libsh 'backup_record pkg bin "$HOME/.local/bin/tool"; backup_replay "$BACKUP"'
  assert_success
  assert_file_exists "$HOME/.local/bin/tool"
  run --separate-stderr libsh 'backup_replay "$BACKUP" 1'
  assert_success
  assert_file_not_exists "$HOME/.local/bin/tool"
}

@test "created dir in a non-writable parent needs --system to remove" {
  stub_enable sudo
  local parent="$SYS_ROOT/usr/share/gnome-shell/theme"
  mkdir -p "$parent"
  run --separate-stderr env P="$parent/tokyonight-ubuntu" bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"
    backup_record dir "$P"'
  mkdir "$parent/tokyonight-ubuntu"
  chmod 555 "$parent"
  run --separate-stderr libsh 'backup_replay "$BACKUP"'
  local st=$status err=$stderr
  run --separate-stderr env SYSTEM=1 bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"; backup_replay "$BACKUP"'
  chmod 755 "$parent"
  [[ $st == 1 && $err == *"--system"* ]]
  assert_stub_called sudo '-- rmdir -- .*/theme/tokyonight-ubuntu$'
}
