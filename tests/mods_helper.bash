#!/usr/bin/env bash
# Shared by mod_*.bats: run real modules/ files through install.sh in the sandbox.

# mods_setup MODULE_FILE...: sandbox plus a modules dir with preflight and the given files.
mods_setup() {
  setup_sandbox
  export NO_COLOR=1 TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR" "$BATS_TEST_TMPDIR/mods"
  ln -s "$TNU_ROOT/modules/00-preflight.sh" "$BATS_TEST_TMPDIR/mods/00-preflight.sh"
  local f
  for f in "$@"; do ln -s "$TNU_ROOT/modules/$f" "$BATS_TEST_TMPDIR/mods/$f"; done
  export TNU_MODULES_DIR="$BATS_TEST_TMPDIR/mods"
}
