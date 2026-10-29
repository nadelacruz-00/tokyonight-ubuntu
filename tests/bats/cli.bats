#!/usr/bin/env bats
# install.sh option parsing, validation and exit codes.

bats_require_minimum_version 1.5.0

load ../test_helper

setup() {
  setup_sandbox
  export NO_COLOR=1 TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
}

@test "--help exits 0 and lists every flag" {
  TNU_EUID=1000 run --separate-stderr "$TNU_ROOT/install.sh" --help
  assert_success
  local f
  assert_output --partial "--variant tokyonight|storm"
  for f in --variant --system --only --skip --dry-run --uninstall \
    --backup --purge --status --offline --strict --force -y --yes -v --verbose \
    -h --help --version; do
    [[ $output == *" $f"* ]] || {
      echo "missing $f" >&2
      return 1
    }
  done
  assert_output --partial "Usage: install.sh"
  assert_output --partial "1 a module failed (or the confirmation prompt was"
  assert_output --partial "declined)"
  [[ -z $stderr ]]
}

@test "-h is --help and writes nothing" {
  run_install -h
  assert_success
  assert_output --partial "Usage: install.sh"
  assert_dir_not_exists "$XDG_STATE_HOME"
}

@test "unknown flag exits 2" {
  run_install --bogus
  assert_failure 2
  assert_output --partial "unknown option: --bogus"
  run_install stray
  assert_failure 2
  run_install --dry-run=1
  assert_failure 2
}

@test "--only with --skip exits 2" {
  run_install --only preflight --skip preflight
  assert_failure 2
  assert_output --partial "cannot be combined"
}

@test "--variant bogus exits 2" {
  run_install --variant bogus
  assert_failure 2
  run_install --variant
  assert_failure 2
  assert_output --partial "needs a value"
  run_install --variant=storm --dry-run
  assert_success
}

@test "--purge without --uninstall exits 2" {
  run_install --purge
  assert_failure 2
  run_install --backup 20260101T000000Z
  assert_failure 2
  run_install --status --uninstall
  assert_failure 2
}

@test "--only nosuch exits 2" {
  run_install --only nosuch
  assert_failure 2
  assert_output --partial "unknown module: nosuch"
  run_install --skip ","
  assert_failure 2
  run_install --skip preflight
  assert_failure 2
}

@test "--uninstall --backup of a missing backup exits 2" {
  run_install --uninstall --backup 20260101T000000Z
  assert_failure 2
  run_install --uninstall --backup ../x
  assert_failure 2
}

@test "--version prints 0.1.0" {
  TNU_EUID=1000 run --separate-stderr "$TNU_ROOT/install.sh" --version
  assert_success
  assert_output "0.1.0"
}

@test "--dry-run writes nothing" {
  local home_snap="$BATS_TEST_TMPDIR/home.snap" root_snap="$BATS_TEST_TMPDIR/root.snap"
  printf 'unrelated\n' >"$HOME/.zshrc"
  tree_snapshot "$HOME" >"$home_snap"
  tree_snapshot "$SYS_ROOT" >"$root_snap"
  run_install --dry-run
  assert_success
  assert_line --regexp '^preflight +OK$'
  refute_output --partial "log:"
  assert_tree_unchanged "$home_snap" "$HOME"
  assert_tree_unchanged "$root_snap" "$SYS_ROOT"
  assert_dir_not_exists "$XDG_STATE_HOME/tokyonight-ubuntu"
  # Also with modules that would change things, including system ones.
  stub_enable sudo
  TNU_MODULES_DIR="$TNU_ROOT/tests/fixtures/modules" run_install --dry-run --system
  assert_line --regexp '^alpha +CHANGED 2$'
  assert_tree_unchanged "$home_snap" "$HOME"
  assert_tree_unchanged "$root_snap" "$SYS_ROOT"
  refute_stub_called sudo
  refute_stub_called dconf '(write|reset)'
  run find "$TMPDIR" -mindepth 1
  assert_output ""
}

@test "non-TTY run without -y proceeds without asking" {
  TNU_MODULES_DIR="$TNU_ROOT/tests/fixtures/modules" run_install --only alpha </dev/null
  assert_success
  refute_output --partial "Proceed?"
  assert_file_exists "$HOME/alpha.txt"
}
