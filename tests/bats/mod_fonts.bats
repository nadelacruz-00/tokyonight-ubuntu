#!/usr/bin/env bats
# modules/10-fonts.sh

bats_require_minimum_version 1.5.0

load ../test_helper
load ../lib_test_helper

setup() {
  setup_sandbox
  export NO_COLOR=1 TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  make_font_tarball
  DEST="$HOME/.local/share/fonts/JetBrainsMonoNerd"
}

# make_font_tarball: fake 2-ttf tarball in the curl stub's downloads + matching checksum file.
make_font_tarball() {
  local w="$BATS_TEST_TMPDIR/work" sha
  mkdir -p "$w/pack"
  printf 'fake regular\n' >"$w/pack/JetBrainsMonoNerdFont-Regular.ttf"
  printf 'fake bold\n' >"$w/pack/JetBrainsMonoNerdFont-Bold.ttf"
  printf 'not a font\n' >"$w/pack/README.md"
  tar -C "$w/pack" -cJf "$STUB_STATE/downloads/JetBrainsMono.tar.xz" .
  sha=$(sha256sum <"$STUB_STATE/downloads/JetBrainsMono.tar.xz")
  printf '%s  JetBrainsMono.tar.xz  https://example.invalid/JetBrainsMono.tar.xz\n' "${sha%% *}" \
    >"$w/sums"
  export TNU_CHECKSUMS="$w/sums"
}

manifest() {
  cat "$XDG_STATE_HOME"/tokyonight-ubuntu/backups/*/manifest.tsv
}

@test "fonts install into empty HOME and fc-cache runs" {
  run_install -y --only fonts
  assert_success
  assert_file_exists "$DEST/JetBrainsMonoNerdFont-Regular.ttf"
  assert_file_exists "$DEST/JetBrainsMonoNerdFont-Bold.ttf"
  assert_file_not_exists "$DEST/README.md"
  [ "$(stat -c %a "$DEST/JetBrainsMonoNerdFont-Regular.ttf")" = 644 ]
  assert_stub_called fc-cache '-f'
  run manifest
  assert_output --regexp $'pkg\tfontdir\t'
}

@test "fonts second run no change and no fc-cache" {
  run_install -y --only fonts
  assert_success
  : >"$STUB_LOG"
  run_install -y --only fonts
  assert_success
  refute_stub_called fc-cache
  refute_stub_called curl
}

@test "fonts existing identical dir -> 0 changes, no pkg row" {
  mkdir -p "$DEST"
  tar -xJf "$STUB_STATE/downloads/JetBrainsMono.tar.xz" -C "$DEST" --wildcards '*.ttf'
  chmod 644 "$DEST"/*.ttf
  run_install -y --only fonts
  assert_success
  refute_stub_called fc-cache
  run bash -c 'cat "$1"/tokyonight-ubuntu/backups/*/manifest.tsv 2>/dev/null' _ "$XDG_STATE_HOME"
  refute_output --regexp $'pkg\tfontdir'
}

@test "fonts checksum mismatch fails module" {
  printf 'tampered\n' >"$STUB_STATE/downloads/JetBrainsMono.tar.xz"
  run_install -y --only fonts
  assert_failure
  assert_output --partial "checksum mismatch for JetBrainsMono.tar.xz"
  assert_dir_not_exists "$DEST"
}

@test "fonts dry-run without cache notes the download" {
  run_install -y --dry-run --only fonts
  assert_success
  assert_dir_not_exists "$DEST"
  refute_stub_called curl
  assert_line --regexp '^fonts +CHANGED +1'
  assert_output --partial "download JetBrainsMono.tar.xz from"
}

@test "fonts uninstall --purge removes dir only when we created it" {
  run_install -y --only fonts
  assert_success
  printf 'extra\n' >"$DEST/extra.txt"
  run_install -y --uninstall
  assert_success
  assert_file_exists "$DEST/extra.txt"
  run_install -y --uninstall --purge
  assert_success
  assert_dir_not_exists "$DEST"

  mkdir -p "$DEST"
  printf 'mine\n' >"$DEST/mine.ttf"
  run_install -y --only fonts
  assert_success
  run_install -y --uninstall --purge
  assert_success
  assert_file_exists "$DEST/mine.ttf"
  assert_file_not_exists "$DEST/JetBrainsMonoNerdFont-Regular.ttf"
}

@test "fonts plain uninstall keeps the fonts, --purge removes them and refreshes the cache" {
  run_install -y --only fonts
  assert_success
  run_install -y --uninstall
  assert_success
  assert_file_exists "$DEST/JetBrainsMonoNerdFont-Regular.ttf"
  assert_file_exists "$DEST/JetBrainsMonoNerdFont-Bold.ttf"
  assert_output --partial "kept fontdir $DEST (uninstall with --purge to remove it)"
  refute_output --partial "removed $DEST"
  : >"$STUB_LOG"
  run_install -y --uninstall --purge
  assert_success
  assert_dir_not_exists "$DEST"
  assert_stub_called fc-cache '-f'
}

@test "fonts uninstall of files added to an existing dir removes them and runs fc-cache" {
  mkdir -p "$DEST"
  printf 'mine\n' >"$DEST/mine.ttf"
  run_install -y --only fonts
  assert_success
  : >"$STUB_LOG"
  run_install -y --uninstall
  assert_success
  assert_file_exists "$DEST/mine.ttf"
  assert_file_not_exists "$DEST/JetBrainsMonoNerdFont-Regular.ttf"
  assert_stub_called fc-cache '-f'
}
