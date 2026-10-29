#!/usr/bin/env bash
# Shared setup for lib_*.bats: sandbox plus the globals install.sh normally sets.

lib_setup() {
  setup_sandbox
  export DRY_RUN=0 SYSTEM=0 OFFLINE=0 VERBOSE=0 MODULE=test NO_COLOR=1
  export RUN_ID=20261029T000000Z
  export STATE_DIR="$XDG_STATE_HOME/tokyonight-ubuntu"
  export CACHE_DIR="$XDG_CACHE_HOME/tokyonight-ubuntu"
  export RUN_DIR="$BATS_TEST_TMPDIR/run"
  export BACKUP="$STATE_DIR/backups/$RUN_ID"
  mkdir -p "$RUN_DIR"
}

# libsh SCRIPT: run SCRIPT in a fresh bash with the global shell options and
# every lib/*.sh sourced (via tests/lib_loader.bash).
libsh() {
  bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"; eval "$1"' libsh "$1"
}
