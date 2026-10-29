#!/usr/bin/env bash
# Test-only: apply the project's global shell options, then source every lib.
# Usage (from bats): bash -c 'source "$TNU_ROOT/tests/lib_loader.bash"; CMD...'
set -Eeuo pipefail
shopt -s inherit_errexit
IFS=$'\n\t'
for _tnu_lib in "${TNU_ROOT:?}"/lib/*.sh; do
  # shellcheck source=/dev/null
  source "$_tnu_lib"
done
unset _tnu_lib
