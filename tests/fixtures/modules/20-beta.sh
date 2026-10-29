#!/usr/bin/env bash
# shellcheck shell=bash
# Fixture: always fails (a failing command under errexit).
register_module beta 20 0

beta_applies() {
  return 0
}

beta_apply() {
  log_info "beta about to fail"
  false
  log_info "beta not reached"
}
