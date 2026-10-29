#!/usr/bin/env bash
# shellcheck shell=bash
# Fixture: writes $HOME/alpha.txt, then (after ALPHA_SLEEP seconds, touching
# ALPHA_MARK first) sets a dconf key. Content from ALPHA_CONTENT.
register_module alpha 10 0

alpha_applies() {
  return 0
}

alpha_apply() {
  local content=${ALPHA_CONTENT:-alpha v1}
  printf '%s\n' "$content" | write_file "$HOME/alpha.txt"
  if [[ -n ${ALPHA_MARK:-} ]]; then : >"$ALPHA_MARK"; fi
  if [[ ${ALPHA_SLEEP:-0} != 0 ]]; then sleep "$ALPHA_SLEEP"; fi
  dset /org/tnu/test/alpha "$(gv_str "$content")"
}
