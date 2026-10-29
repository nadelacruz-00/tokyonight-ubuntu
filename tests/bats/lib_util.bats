#!/usr/bin/env bats
# shellcheck disable=SC2016 # libsh scripts are single-quoted on purpose

bats_require_minimum_version 1.5.0

load ../test_helper
load ../lib_test_helper

setup() {
  lib_setup
}

# checksums NAME SHA URL: write a one-entry checksum file and point TNU_CHECKSUMS at it.
checksums() {
  export TNU_CHECKSUMS="$BATS_TEST_TMPDIR/checksums.sha256"
  {
    printf '%s  %s\n' 0000000000000000000000000000000000000000000000000000000000000000 assets/vendored.css
    printf '%s  %s  %s\n' "$2" "$1" "$3"
  } >"$TNU_CHECKSUMS"
}

@test "libs are safe to source twice" {
  run --separate-stderr libsh 'source "$TNU_ROOT/tests/lib_loader.bash"; have_cmd bash && echo ok'
  assert_success
  assert_output ok
}

@test "run in dry-run does not execute" {
  run --separate-stderr env DRY_RUN=1 bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"; run touch "$BATS_TEST_TMPDIR/marker"'
  assert_success
  assert_file_not_exists "$BATS_TEST_TMPDIR/marker"
  [[ $stderr == *"[dry-run]"* ]]
  [[ $stderr == *touch* ]]
}

@test "run executes the command when not in dry-run" {
  run --separate-stderr libsh 'run touch "$BATS_TEST_TMPDIR/marker"'
  assert_success
  assert_file_exists "$BATS_TEST_TMPDIR/marker"
}

@test "die exits with the given code and logs the message" {
  run --separate-stderr libsh 'die "boom here" 7; echo unreachable'
  assert_failure 7
  assert_output ""
  [[ $stderr == *"boom here"* ]]
}

@test "require_cmd dies 3 listing every missing command" {
  run --separate-stderr libsh 'require_cmd bash nosuch-a nosuch-b'
  assert_failure 3
  [[ $stderr == *nosuch-a* && $stderr == *nosuch-b* ]]
}

@test "log_debug prints only when VERBOSE=1" {
  run --separate-stderr libsh 'log_debug hidden'
  assert_success
  [[ $stderr != *hidden* ]]
  run --separate-stderr env VERBOSE=1 bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"; log_debug shown'
  [[ $stderr == *shown* ]]
}

@test "log_init writes messages to the log file too" {
  run --separate-stderr libsh 'log_init "$BATS_TEST_TMPDIR/logs/run.log"; log_info "hello log"; log_warn "careful"'
  assert_success
  [[ $stderr == *"hello log"* ]]
  run grep -c -e 'hello log' -e careful "$BATS_TEST_TMPDIR/logs/run.log"
  assert_output 2
}

@test "log output has no colour when stderr is not a TTY" {
  run --separate-stderr env -u NO_COLOR bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"; log_warn plain'
  [[ $stderr != *$'\033'* ]]
}

@test "note_change appends MODULE<TAB>DESC also in dry-run and module_changes counts" {
  run --separate-stderr env DRY_RUN=1 bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"
    note_change "one"; MODULE=other note_change "two"; note_change "three"
    module_changes test; module_changes other; module_changes none'
  assert_success
  assert_output $'2\n1\n0'
  run cat "$RUN_DIR/changes"
  assert_line --index 0 $'test\tone'
}

@test "sha256_of prints the bare hash" {
  printf 'abc' >"$BATS_TEST_TMPDIR/f"
  run --separate-stderr libsh 'sha256_of "$BATS_TEST_TMPDIR/f"'
  assert_output ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
}

@test "install_file is a no-op when identical" {
  mkdir -p "$HOME/.config/gtk-4.0"
  echo same >"$HOME/.config/gtk-4.0/gtk.css"
  echo same >"$BATS_TEST_TMPDIR/src.css"
  run --separate-stderr libsh 'install_file "$BATS_TEST_TMPDIR/src.css" "$HOME/.config/gtk-4.0/gtk.css"; module_changes test'
  assert_success
  assert_output 0
  assert_file_not_exists "$BACKUP/manifest.tsv"
  assert_dir_not_exists "$STATE_DIR/backups"
}

@test "install_file backs up and replaces" {
  mkdir -p "$HOME/.config/gtk-4.0"
  printf 'original\nno-newline' >"$HOME/.config/gtk-4.0/gtk.css"
  cp "$HOME/.config/gtk-4.0/gtk.css" "$BATS_TEST_TMPDIR/orig"
  echo new >"$BATS_TEST_TMPDIR/src.css"
  run --separate-stderr libsh 'install_file "$BATS_TEST_TMPDIR/src.css" "$HOME/.config/gtk-4.0/gtk.css"; module_changes test'
  assert_success
  assert_output 1
  cmp "$BATS_TEST_TMPDIR/src.css" "$HOME/.config/gtk-4.0/gtk.css"
  run cut -f1-3 "$BACKUP/manifest.tsv"
  assert_output "$(printf 'file\t%s\tfiles/1' "$HOME/.config/gtk-4.0/gtk.css")"
  cmp "$BATS_TEST_TMPDIR/orig" "$BACKUP/files/1"
  run cut -f4 "$BACKUP/manifest.tsv"
  assert_output "$(sha256sum <"$BATS_TEST_TMPDIR/src.css" | cut -d' ' -f1)"
}

@test "install_file preserves existing mode" {
  echo old >"$HOME/f.conf"
  chmod 600 "$HOME/f.conf"
  echo new >"$BATS_TEST_TMPDIR/src"
  chmod 755 "$BATS_TEST_TMPDIR/src"
  run --separate-stderr libsh 'install_file "$BATS_TEST_TMPDIR/src" "$HOME/f.conf"'
  assert_success
  run stat -c %a "$HOME/f.conf"
  assert_output 600
}

@test "install_file applies an explicit mode and treats a mode change as a change" {
  echo same >"$HOME/bin-tool"
  chmod 644 "$HOME/bin-tool"
  echo same >"$BATS_TEST_TMPDIR/src"
  run --separate-stderr libsh 'install_file "$BATS_TEST_TMPDIR/src" "$HOME/bin-tool" 0755; module_changes test'
  assert_output 1
  run stat -c %a "$HOME/bin-tool"
  assert_output 755
  run --separate-stderr libsh 'install_file "$BATS_TEST_TMPDIR/src" "$HOME/bin-tool" 755; module_changes test'
  assert_output 1
}

@test "install_file in dry-run notes the change but writes nothing" {
  echo new >"$BATS_TEST_TMPDIR/src"
  tree_snapshot "$HOME" >"$BATS_TEST_TMPDIR/snap"
  run --separate-stderr env DRY_RUN=1 bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"
    install_file "$BATS_TEST_TMPDIR/src" "$HOME/.config/new/f"; module_changes test'
  assert_success
  assert_output 1
  assert_tree_unchanged "$BATS_TEST_TMPDIR/snap" "$HOME"
}

@test "write_file installs stdin and is idempotent" {
  run --separate-stderr libsh 'printf "a b\n" | write_file "$HOME/w.txt" 0640; printf "a b\n" | write_file "$HOME/w.txt" 0640; module_changes test'
  assert_success
  assert_output 1
  assert_file_contains "$HOME/w.txt" '^a b$'
  run stat -c %a "$HOME/w.txt"
  assert_output 640
}

@test "atomic_write leaves no temp file on failure" {
  mkdir -p "$HOME/ro"
  echo keep >"$HOME/ro/f"
  chmod 555 "$HOME/ro"
  run --separate-stderr libsh 'echo x | atomic_write "$HOME/ro/f"'
  chmod 755 "$HOME/ro"
  assert_failure
  assert_file_contains "$HOME/ro/f" '^keep$'
  run find "$HOME" -name '*.tmp*'
  assert_output ""
  # mv onto a directory fails after the temp file exists: it must be cleaned up.
  mkdir -p "$HOME/d/target"
  run --separate-stderr libsh 'echo x | atomic_write "$HOME/d/target"'
  assert_failure
  run find "$HOME" -name '*.tmp*'
  assert_output ""
  assert_dir_exists "$HOME/d/target"
}

@test "atomic_write creates parent dirs and records each one" {
  run --separate-stderr libsh 'printf "x" | atomic_write "$HOME/a/b c/f" 0600'
  assert_success
  run cat "$BACKUP/manifest.tsv"
  assert_output "$(printf 'dir\t%s\ndir\t%s' "$HOME/a" "$HOME/a/b c")"
  run stat -c %a "$HOME/a/b c/f"
  assert_output 600
}

@test "atomic_write default mode follows the umask, not mktemp's 0600" {
  run --separate-stderr libsh 'umask 022; printf "x" | atomic_write "$HOME/new"'
  assert_success
  run stat -c %a "$HOME/new"
  assert_output 644
}

@test "download_verified fetches, verifies and caches" {
  printf 'payload' >"$STUB_STATE/downloads/pkg.tar.xz"
  checksums pkg.tar.xz "$(sha256sum <"$STUB_STATE/downloads/pkg.tar.xz" | cut -d' ' -f1)" https://example.invalid/v1/pkg.tar.xz
  run --separate-stderr libsh 'download_verified pkg.tar.xz'
  assert_success
  assert_output "$CACHE_DIR/pkg.tar.xz"
  cmp "$STUB_STATE/downloads/pkg.tar.xz" "$CACHE_DIR/pkg.tar.xz"
  assert_stub_called curl "--fail --location --proto =https --tlsv1.2 --retry 3 --retry-delay 2 -o .* https://example.invalid/v1/pkg.tar.xz$"
}

@test "download_verified uses cache when hash matches" {
  mkdir -p "$CACHE_DIR"
  printf 'payload' >"$CACHE_DIR/pkg.tar.xz"
  checksums pkg.tar.xz "$(sha256sum <"$CACHE_DIR/pkg.tar.xz" | cut -d' ' -f1)" https://example.invalid/pkg.tar.xz
  run --separate-stderr libsh 'download_verified pkg.tar.xz'
  assert_success
  assert_output "$CACHE_DIR/pkg.tar.xz"
  refute_stub_called curl
}

@test "download_verified deletes file on checksum mismatch" {
  printf 'tampered' >"$STUB_STATE/downloads/pkg.tar.xz"
  checksums pkg.tar.xz ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad https://example.invalid/pkg.tar.xz
  run --separate-stderr libsh 'download_verified pkg.tar.xz'
  assert_failure
  [[ $stderr == *"checksum mismatch for pkg.tar.xz"* ]]
  assert_stub_called curl
  run find "$CACHE_DIR" -type f
  assert_output ""
}

@test "download_verified offline without cache dies" {
  printf 'payload' >"$STUB_STATE/downloads/pkg.tar.xz"
  checksums pkg.tar.xz "$(sha256sum <"$STUB_STATE/downloads/pkg.tar.xz" | cut -d' ' -f1)" https://example.invalid/pkg.tar.xz
  run --separate-stderr env OFFLINE=1 bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"; download_verified pkg.tar.xz'
  assert_failure
  [[ $stderr == *pkg.tar.xz* ]]
  refute_stub_called curl
  assert_file_not_exists "$CACHE_DIR/pkg.tar.xz"
}

@test "download_verified dies for a name missing from the checksum file" {
  checksums other.bin ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad https://example.invalid/other.bin
  run --separate-stderr libsh 'download_verified vendored.css; download_verified nope.bin'
  assert_failure
  refute_stub_called curl
}

@test "as_root refuses without --system" {
  stub_enable sudo
  run --separate-stderr libsh 'as_root touch "$BATS_TEST_TMPDIR/rootfile"'
  assert_failure
  [[ $stderr == *--system* ]]
  refute_stub_called sudo
  assert_file_not_exists "$BATS_TEST_TMPDIR/rootfile"
}

@test "as_root runs through sudo -- with --system" {
  stub_enable sudo
  run --separate-stderr env SYSTEM=1 bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"; as_root touch "$BATS_TEST_TMPDIR/root file"'
  assert_success
  assert_stub_called sudo '-- touch .*root\\ file$'
  assert_file_exists "$BATS_TEST_TMPDIR/root file"
}

@test "sys_path prefixes SYS_ROOT" {
  run --separate-stderr libsh 'sys_path /usr/share/x'
  assert_output "$SYS_ROOT/usr/share/x"
}

@test "HOME with a space works for install_file" {
  [[ $HOME == *" "* ]]
  printf 'body\n' >"$BATS_TEST_TMPDIR/src file.css"
  run --separate-stderr libsh 'install_file "$BATS_TEST_TMPDIR/src file.css" "$HOME/.config/gtk 3.0/gtk.css" 0644'
  assert_success
  cmp "$BATS_TEST_TMPDIR/src file.css" "$HOME/.config/gtk 3.0/gtk.css"
  run cut -f1,2 "$BACKUP/manifest.tsv"
  assert_line --index 0 "$(printf 'dir\t%s' "$HOME/.config")"
  assert_line --index 1 "$(printf 'dir\t%s' "$HOME/.config/gtk 3.0")"
  assert_line --index 2 "$(printf 'file\t%s' "$HOME/.config/gtk 3.0/gtk.css")"
}
