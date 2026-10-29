#!/usr/bin/env bats
# shellcheck disable=SC2016 # rc file contents are single-quoted on purpose
# modules/70-prompt.sh

bats_require_minimum_version 1.5.0

load ../test_helper
load ../lib_test_helper

setup() {
  setup_sandbox
  export NO_COLOR=1 TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  local w="$BATS_TEST_TMPDIR/work" sha
  mkdir -p "$w"
  printf '#!/bin/sh\necho fake oh-my-posh\n' >"$STUB_STATE/downloads/posh-linux-arm64"
  sha=$(sha256sum <"$STUB_STATE/downloads/posh-linux-arm64")
  printf '%s  posh-linux-arm64  https://example.invalid/posh-linux-arm64\n' "${sha%% *}" >"$w/sums"
  export TNU_CHECKSUMS="$w/sums"
  OMP_BIN="$HOME/.local/bin/oh-my-posh"
  ZSHRC="$HOME/.zshrc"
  BASHRC="$HOME/.bashrc"
}

@test "prompt keeps newer oh-my-posh" {
  stub_enable oh-my-posh
  STUB_OMP_VERSION=31.9.0 run_install -y --only prompt
  assert_success
  refute_stub_called curl
  assert_file_not_exists "$OMP_BIN"
  assert_file_exists "$HOME/.config/oh-my-posh/tokyonight_storm.omp.json"
}

@test "prompt installs binary when absent" {
  run_install -y --only prompt
  assert_success
  assert_stub_called curl '.*posh-linux-arm64'
  assert_file_executable "$OMP_BIN"
  [ "$(stat -c %a "$OMP_BIN")" = 755 ]
  run_install -y --uninstall --purge
  assert_success
  assert_file_not_exists "$OMP_BIN"
}

@test "prompt replaces an older or unparsable oh-my-posh version" {
  stub_enable oh-my-posh
  STUB_OMP_VERSION=29.0.1 run_install -y --only prompt
  assert_success
  assert_file_executable "$OMP_BIN"
  rm -f "$OMP_BIN"
  STUB_OMP_VERSION=weird run_install -y --only prompt
  assert_success
  assert_file_executable "$OMP_BIN"
}

@test "prompt adds zsh block only when zsh present" {
  run_install -y --only prompt
  assert_success
  assert_file_not_exists "$ZSHRC"
  assert_file_not_exists "$BASHRC"

  stub_enable zsh
  run_install -y --only prompt
  assert_success
  assert_file_exists "$ZSHRC"
  run cat "$ZSHRC"
  assert_output --partial 'init zsh --config "$HOME/.config/oh-my-posh/tokyonight_storm.omp.json"'
  assert_output --partial '# >>> tokyonight-ubuntu >>>'
  run_install -y --uninstall
  assert_success
  assert_file_not_exists "$ZSHRC"
}

@test "prompt adds bash block only when .bashrc exists" {
  printf 'alias x=y\n' >"$BASHRC"
  run_install -y --only prompt
  assert_success
  run cat "$BASHRC"
  assert_output --partial 'init bash --config'
  assert_output --partial 'alias x=y'
}

@test "prompt skips rc with existing unmarked oh-my-posh init" {
  printf 'eval "$(oh-my-posh init zsh)"\n' >"$ZSHRC"
  printf '# eval "$(oh-my-posh init bash)"\n' >"$BASHRC"
  run_install -y --only prompt
  assert_success
  assert_output --partial 'already configured'
  run cat "$ZSHRC"
  refute_output --partial 'tokyonight-ubuntu'
  run cat "$BASHRC"
  assert_output --partial 'tokyonight-ubuntu'
}

@test "prompt block idempotent" {
  printf 'export A=1\n' >"$ZSHRC"
  run_install -y --only prompt
  assert_success
  local snap="$BATS_TEST_TMPDIR/snap" sum
  sum=$(sha256sum <"$ZSHRC")
  tree_snapshot "$HOME/.config" >"$snap"
  run_install -y --only prompt
  assert_success
  assert_tree_unchanged "$snap" "$HOME/.config"
  [ "$(sha256sum <"$ZSHRC")" = "$sum" ]
  run grep -c '>>> tokyonight-ubuntu' "$ZSHRC"
  assert_output 1
}

@test "prompt uninstall removes block and leaves user lines intact" {
  printf 'export A=1\n' >"$ZSHRC"
  printf 'export B=2\n' >"$BASHRC"
  run_install -y --only prompt
  assert_success
  run_install -y --uninstall
  assert_success
  [ "$(cat "$ZSHRC")" = 'export A=1' ]
  [ "$(cat "$BASHRC")" = 'export B=2' ]
  assert_file_not_exists "$HOME/.config/oh-my-posh/tokyonight_storm.omp.json"
}

@test "zellij theme line replaced, commented example untouched, uninstall restores old line" {
  stub_enable zellij
  mkdir -p "$HOME/.config/zellij"
  printf '// theme "dracula"\n# theme "nord"\ntheme "gruvbox"\nsimplified_ui true\n' \
    >"$HOME/.config/zellij/config.kdl"
  local before
  before=$(cat "$HOME/.config/zellij/config.kdl")
  run_install -y --only prompt
  assert_success
  run cat "$HOME/.config/zellij/config.kdl"
  assert_output --partial 'theme "tokyo-night-storm"'
  assert_output --partial '// theme "dracula"'
  assert_output --partial '# theme "nord"'
  refute_output --partial 'gruvbox'
  run_install -y --uninstall
  assert_success
  [ "$(cat "$HOME/.config/zellij/config.kdl")" = "$before" ]
}

@test "zellij absent -> config untouched" {
  stub_enable zellij
  run_install -y --only prompt
  assert_success
  assert_file_not_exists "$HOME/.config/zellij/config.kdl"
}

@test "lig theme set under [ui]" {
  stub_enable lig
  mkdir -p "$HOME/.config/lig"
  printf '[general]\ntheme = "other"\n[ui]\ntheme = "dark"\nx = 1\n' >"$HOME/.config/lig/config.toml"
  run_install -y --only prompt
  assert_success
  run cat "$HOME/.config/lig/config.toml"
  assert_output $'[general]\ntheme = "other"\n[ui]\ntheme = "tokyonight"\nx = 1'
  run_install -y --uninstall
  assert_success
  run cat "$HOME/.config/lig/config.toml"
  assert_output --partial 'theme = "dark"'
}

@test "prompt plain uninstall keeps the oh-my-posh binary, --purge removes it" {
  run_install -y --only prompt
  assert_success
  assert_file_executable "$OMP_BIN"
  run_install -y --uninstall
  assert_success
  assert_file_executable "$OMP_BIN"
  assert_output --partial "kept bin $OMP_BIN (uninstall with --purge to remove it)"
  assert_file_not_exists "$HOME/.config/oh-my-posh/tokyonight_storm.omp.json"
  run_install -y --uninstall --purge
  assert_success
  assert_file_not_exists "$OMP_BIN"
}
