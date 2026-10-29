#!/usr/bin/env bats
# Module runner, lock, status and uninstall, with the fixture modules
# (tests/fixtures/modules): alpha changes a file and a dconf key, beta fails,
# gamma is system-only, delta does not apply.

bats_require_minimum_version 1.5.0

load ../test_helper

setup() {
  setup_sandbox
  export TNU_MODULES_DIR="$TNU_ROOT/tests/fixtures/modules" NO_COLOR=1
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  STATE="$XDG_STATE_HOME/tokyonight-ubuntu"
}

teardown() {
  if [[ -n ${BG_PID:-} ]]; then kill "$BG_PID" 2>/dev/null || true; fi
}

# drop_state: remove the state dir and the (then empty) parents mkdir -p made.
drop_state() {
  rm -rf "$STATE"
  rmdir "$XDG_STATE_HOME" "$HOME/.local"
}

# sleeper_running: some process is still running alpha's `sleep 47.3`.
sleeper_running() {
  local f c
  for f in /proc/[0-9]*/cmdline; do
    c=$(tr '\0' ' ' 2>/dev/null <"$f") || continue
    if [[ $c == "sleep 47.3 " ]]; then return 0; fi
  done
  return 1
}

backup_count() {
  local n=0 d
  for d in "$STATE"/backups/*/; do
    if [[ -f $d/manifest.tsv ]]; then n=$((n + 1)); fi
  done
  echo "$n"
}

@test "summary shows CHANGED/FAILED/SKIPPED in ORDER, not file name order" {
  run_install -y
  assert_failure 1
  assert_line --regexp '^preflight +OK$'
  assert_line --regexp '^alpha +CHANGED 2$'
  assert_line --regexp '^beta +FAILED$'
  assert_line --regexp '^gamma +SKIPPED needs --system$'
  assert_line --regexp '^delta +SKIPPED delta tool missing$'
  assert_line --regexp "^log: $STATE/logs/.*\.log$"
  # delta's file sorts first (05-) but its ORDER is 40.
  [[ $output == *alpha*beta*gamma*delta* ]]
  assert_file_not_exists "$HOME/delta.txt"
  # The ERR trap names module, file and line of the failing command.
  assert_line --regexp '^error: beta: tests/fixtures/modules/20-beta.sh:[0-9]+: false'
  refute_output --partial "beta not reached"
  # RUN_DIR is removed on exit.
  run find "$TMPDIR" -mindepth 1
  assert_output ""
}

@test "summary and log go to stderr; stdout stays clean" {
  TNU_EUID=1000 run --separate-stderr "$TNU_ROOT/install.sh" -y
  assert_failure 1
  assert_output ""
  [[ $stderr == *"alpha"*"CHANGED 2"* ]]
}

@test "failure does not stop later modules" {
  stub_enable sudo
  run_install -y --system
  assert_failure 1
  assert_line --regexp '^beta +FAILED$'
  assert_line --regexp '^gamma +CHANGED 1$'
  assert_file_exists "$HOME/gamma.txt"
  assert_stub_called sudo '-v'
}

@test "--strict stops after beta" {
  stub_enable sudo
  run_install -y --system --strict
  assert_failure 1
  assert_line --regexp '^beta +FAILED$'
  assert_line --regexp '^gamma +NOT RUN \(--strict\)$'
  assert_file_not_exists "$HOME/gamma.txt"
}

@test "exit 1 when a module failed, 0 otherwise" {
  run_install -y --only beta
  assert_failure 1
  run_install -y --skip beta
  assert_success
}

@test "second run reports OK 0 changes and creates no backup" {
  run_install -y --skip beta
  assert_success
  [[ $(backup_count) == 1 ]]
  run_install -y --skip beta
  assert_success
  assert_line --regexp '^alpha +OK$'
  [[ $(backup_count) == 1 ]]
}

@test "--dry-run reports changes without making them" {
  run_install --dry-run --skip beta
  assert_success
  assert_line --regexp '^alpha +CHANGED 2$'
  assert_file_not_exists "$HOME/alpha.txt"
  assert_dir_not_exists "$STATE"
  [[ -z $(dconf_get /org/tnu/test/alpha) ]]
}

@test "--status reports drifted then applied" {
  TNU_EUID=1000 run --separate-stderr "$TNU_ROOT/install.sh" --status --skip beta
  assert_success
  assert_line --index 0 --regexp '^alpha +drifted \(2\)$'
  assert_line --index 1 --regexp '^gamma +n/a: needs --system$'
  assert_line --index 2 --regexp '^delta +n/a: delta tool missing$'
  assert_dir_not_exists "$STATE"
  run_install -y --skip beta
  assert_success
  TNU_EUID=1000 run --separate-stderr "$TNU_ROOT/install.sh" --status --skip beta
  assert_success
  assert_line --index 0 --regexp '^alpha +applied$'
  printf 'edited\n' >"$HOME/alpha.txt"
  TNU_EUID=1000 run --separate-stderr "$TNU_ROOT/install.sh" --status --only alpha
  assert_success
  assert_output --regexp '^alpha +drifted \(1\)$'
}

@test "--status shows a failing module as error and exits 1" {
  TNU_EUID=1000 run --separate-stderr "$TNU_ROOT/install.sh" --status --only beta
  assert_failure 1
  assert_output --regexp '^beta +error: tests/fixtures/modules/20-beta.sh:[0-9]+: false'
}

@test "lock held exits 4" {
  mkdir -p "$STATE"
  flock "$STATE/lock" sleep 30 3>&- &
  BG_PID=$!
  local i
  for ((i = 0; i < 50; i++)); do
    if ! flock -n "$STATE/lock" bash -c :; then break; fi
    sleep 0.1
  done
  run_install -y --skip beta
  assert_failure 4
  assert_output --partial "another install is running"
  assert_file_not_exists "$HOME/alpha.txt"
  # Dry-run and status do not take the lock.
  run_install --dry-run --skip beta
  assert_success
}

@test "SIGTERM mid-module releases lock and re-run converges" {
  printf 'original\n' >"$HOME/alpha.txt"
  local snap="$BATS_TEST_TMPDIR/snap" out="$BATS_TEST_TMPDIR/out" i rc=0
  tree_snapshot "$HOME" >"$snap"
  ALPHA_SLEEP=47.3 ALPHA_MARK="$BATS_TEST_TMPDIR/mark" TNU_EUID=1000 \
    "$TNU_ROOT/install.sh" -y --only alpha >"$out" 2>&1 3>&- &
  BG_PID=$!
  for ((i = 0; i < 100; i++)); do
    if [[ -e $BATS_TEST_TMPDIR/mark ]]; then break; fi
    sleep 0.1
  done
  assert_file_exists "$BATS_TEST_TMPDIR/mark"
  kill -TERM "$BG_PID"
  wait "$BG_PID" || rc=$?
  BG_PID=""
  [[ $rc == 130 ]]
  assert_file_contains "$out" "interrupted"
  # Lock released, module's sleep killed with it, temp dir gone.
  flock -n "$STATE/lock" bash -c :
  refute sleeper_running
  run find "$TMPDIR" -mindepth 1
  assert_output ""
  # The file was written before the kill; the dconf key was not.
  assert_file_contains "$HOME/alpha.txt" '^alpha v1$'
  [[ -z $(dconf_get /org/tnu/test/alpha) ]]
  run_install -y --only alpha
  assert_success
  assert_line --regexp '^alpha +CHANGED 1$'
  [[ $(dconf_get /org/tnu/test/alpha) == "'alpha v1'" ]]
  run_install -y --uninstall
  assert_success
  drop_state
  assert_tree_unchanged "$snap" "$HOME"
  [[ -z $(dconf_get /org/tnu/test/alpha) ]]
}

@test "uninstall after two runs with different content restores original" {
  printf 'original\n' >"$HOME/alpha.txt"
  dconf_put /org/tnu/test/alpha "'before'"
  local snap="$BATS_TEST_TMPDIR/snap"
  tree_snapshot "$HOME" >"$snap"
  ALPHA_CONTENT="alpha v1" run_install -y --skip beta
  assert_success
  ALPHA_CONTENT="alpha v2" run_install -y --skip beta
  assert_success
  assert_file_contains "$HOME/alpha.txt" '^alpha v2$'
  [[ $(backup_count) == 2 ]]
  run_install -y --uninstall
  assert_success
  [[ $(dconf_get /org/tnu/test/alpha) == "'before'" ]]
  [[ $(backup_count) == 0 ]]
  run find "$STATE/backups/.restored" -mindepth 1 -maxdepth 1 -type d
  [[ ${#lines[@]} == 2 ]]
  drop_state
  assert_tree_unchanged "$snap" "$HOME"
  # Nothing left to undo.
  run_install -y --uninstall
  assert_success
  assert_output --partial "nothing to uninstall"
}

@test "uninstall --backup TS replays only that one" {
  ALPHA_CONTENT="alpha v1" run_install -y --skip beta
  assert_success
  ALPHA_CONTENT="alpha v2" run_install -y --skip beta
  assert_success
  local newest
  newest=$(find "$STATE/backups" -mindepth 1 -maxdepth 1 -type d ! -name .restored | sort | tail -n 1)
  run_install -y --uninstall --backup "${newest##*/}"
  assert_success
  assert_file_contains "$HOME/alpha.txt" '^alpha v1$'
  [[ $(dconf_get /org/tnu/test/alpha) == "'alpha v1'" ]]
  [[ $(backup_count) == 1 ]]
  assert_dir_exists "$STATE/backups/.restored/${newest##*/}"
  # An already restored backup is not a valid --backup.
  run_install -y --uninstall --backup "${newest##*/}"
  assert_failure 2
}

@test "uninstall with nothing exits 0" {
  run_install -y --uninstall
  assert_success
  assert_output --partial "nothing to uninstall"
}

@test "uninstall with rows pending (no --system) keeps the backup and exits 1" {
  stub_enable sudo
  local ts=20260101T000000Z f="$SYS_ROOT/etc/tnu.conf" sha
  mkdir -p "$STATE/backups/$ts"
  printf 'ours\n' >"$f"
  sha=$(sha256sum <"$f" | cut -d' ' -f1)
  printf 'sysfile\t%s\tABSENT\t%s\n' "$f" "$sha" >"$STATE/backups/$ts/manifest.tsv"
  run_install -y --uninstall
  assert_failure 1
  assert_output --partial "rerun with --system"
  assert_file_exists "$f"
  assert_file_exists "$STATE/backups/$ts/manifest.tsv"
  run_install -y --uninstall --system
  assert_success
  assert_file_not_exists "$f"
  assert_dir_exists "$STATE/backups/.restored/$ts"
}

@test "dry-run uninstall changes nothing" {
  ALPHA_CONTENT="alpha v1" run_install -y --skip beta
  assert_success
  local snap="$BATS_TEST_TMPDIR/snap"
  tree_snapshot "$HOME" >"$snap"
  run_install --uninstall --dry-run
  assert_success
  assert_output --partial "[dry-run]"
  assert_tree_unchanged "$snap" "$HOME"
  [[ $(dconf_get /org/tnu/test/alpha) == "'alpha v1'" ]]
}

@test "dry-run: an uncached download (rc 10) counts as a change, not a failure" {
  mkdir -p "$BATS_TEST_TMPDIR/mods"
  ln -s "$TNU_ROOT/modules/00-preflight.sh" "$BATS_TEST_TMPDIR/mods/00-preflight.sh"
  cat >"$BATS_TEST_TMPDIR/mods/10-dl.sh" <<'MOD'
register_module dl 10 0
dl_applies() { return 0; }
dl_apply() {
  local p
  p=$(download_verified x.bin)
  install_file "$p" "$HOME/x.bin"
}
MOD
  printf '%064d  x.bin  https://example.invalid/x.bin\n' 0 >"$BATS_TEST_TMPDIR/sums"
  export TNU_CHECKSUMS="$BATS_TEST_TMPDIR/sums" TNU_MODULES_DIR="$BATS_TEST_TMPDIR/mods"
  run_install --dry-run
  assert_success
  assert_line --regexp '^dl +CHANGED 1$'
  refute_output --partial "error:"
  TNU_EUID=1000 run --separate-stderr "$TNU_ROOT/install.sh" --status
  assert_success
  assert_output --regexp '^dl +drifted \(1\)$'
  # A real run still fails on the missing download.
  run_install -y
  assert_failure 1
  assert_line --regexp '^dl +FAILED$'
}
