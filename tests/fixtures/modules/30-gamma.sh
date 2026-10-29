#!/usr/bin/env bash
# shellcheck shell=bash
# Fixture: system-only; writes $HOME/gamma.txt when run.
register_module gamma 30 1

gamma_applies() {
  return 0
}

gamma_apply() {
  printf 'gamma\n' | write_file "$HOME/gamma.txt"
}
