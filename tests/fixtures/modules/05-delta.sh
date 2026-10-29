#!/usr/bin/env bash
# shellcheck shell=bash
# Fixture: never applies.
register_module delta 40 0

delta_applies() {
  echo "delta tool missing"
  return 1
}

delta_apply() {
  printf 'delta\n' | write_file "$HOME/delta.txt"
}
