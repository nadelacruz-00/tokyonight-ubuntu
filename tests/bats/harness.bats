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

@test "stub log distinguishes one spaced arg from two args" {
  dconf write /a/b "x y"
  dconf write /a/c x y
  run grep -c . "$STUB_LOG"
  assert_output 2
  run cat "$STUB_LOG"
  assert_line --index 0 $'dconf\twrite /a/b x\\ y'
  assert_line --index 1 $'dconf\twrite /a/c x y'
  assert_stub_called dconf 'write /a/b x\\ y'
  refute_stub_called dconf 'write /a/b x y$'
}

@test "flatpak info --user APP flips after install --user -y flathub APP" {
  stub_enable flatpak
  run flatpak info --user org.example.App
  assert_failure
  flatpak install --user -y flathub org.example.App
  run flatpak info --user org.example.App
  assert_success
}

@test "dpkg-query -W -f prints package and version when present" {
  run dpkg-query -W -f='${Version}' pkgx
  assert_failure
  touch "$STUB_STATE/pkgs/pkgx"
  run dpkg-query -W -f='${Version}' pkgx
  assert_success
  assert_output $'pkgx\t1.0'
}

@test "curl handles --retry 3 --output F URL" {
  echo data >"$STUB_STATE/downloads/file.bin"
  run curl -fsSL --retry 3 --retry-delay 2 --proto '=https' --tlsv1.2 \
    --output "$BATS_TEST_TMPDIR/F" https://example.invalid/dir/file.bin
  assert_success
  assert_equal "$(cat "$BATS_TEST_TMPDIR/F")" data
}

@test "dconf reset -f DIR/ and dump DIR/" {
  dconf write /d/a/k1 "'v1'"
  dconf write /d/a/k2 "2"
  dconf write /d/top "true"
  dconf write /other/k "1"
  run dconf dump /d/
  assert_success
  assert_output $'[/]\ntop=true\n[a]\nk1=\'v1\'\nk2=2'
  dconf reset -f /d/a/
  run dconf dump /d/
  assert_output $'[/]\ntop=true'
  assert_equal "$(dconf_get /other/k)" 1
}

@test "sudo stub strips options and execs the command" {
  stub_enable sudo
  run sudo -u root -E -n -- basename /x/hi
  assert_output hi
  run sudo -v
  assert_success
}

@test "tree_snapshot detects a new empty dir and a symlink" {
  mkdir -p "$BATS_TEST_TMPDIR/t"
  echo hi >"$BATS_TEST_TMPDIR/t/f"
  tree_snapshot "$BATS_TEST_TMPDIR/t" >"$BATS_TEST_TMPDIR/snap"
  mkdir "$BATS_TEST_TMPDIR/t/empty"
  run assert_tree_unchanged "$BATS_TEST_TMPDIR/snap" "$BATS_TEST_TMPDIR/t"
  assert_failure
  rm -r "$BATS_TEST_TMPDIR/t/empty"
  ln -s f "$BATS_TEST_TMPDIR/t/l"
  run assert_tree_unchanged "$BATS_TEST_TMPDIR/snap" "$BATS_TEST_TMPDIR/t"
  assert_failure
}
