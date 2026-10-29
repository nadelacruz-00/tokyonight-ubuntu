#!/usr/bin/env bats

load ../test_helper

setup() {
  setup_sandbox
}

@test "sandbox HOME contains a space and is empty" {
  [[ $HOME == *" "* ]]
  run ls -A "$HOME"
  assert_output ""
}

@test "dconf stub round-trips 'Synthwave '\"'\"'84'" {
  dconf_put /org/x/name "'Synthwave '\\''84'"
  run dconf read /org/x/name
  assert_success
  assert_output "'Synthwave '\\''84'"
  run dconf_get /org/x/name
  assert_output "'Synthwave '\\''84'"
}

@test "disabled stub is not on PATH" {
  stub_enable zsh
  command -v zsh
  stub_disable zsh
  refute command -v zsh
}

@test "curl stub fails with 22 when download missing" {
  run curl -fsSL -o "$BATS_TEST_TMPDIR/out" https://example.invalid/nope.tar.xz
  assert_failure 22
}

@test "tree_snapshot detects a mode change" {
  mkdir -p "$BATS_TEST_TMPDIR/t"
  echo hi >"$BATS_TEST_TMPDIR/t/f"
  tree_snapshot "$BATS_TEST_TMPDIR/t" >"$BATS_TEST_TMPDIR/snap"
  assert_tree_unchanged "$BATS_TEST_TMPDIR/snap" "$BATS_TEST_TMPDIR/t"
  chmod 755 "$BATS_TEST_TMPDIR/t/f"
  run assert_tree_unchanged "$BATS_TEST_TMPDIR/snap" "$BATS_TEST_TMPDIR/t"
  assert_failure
}
