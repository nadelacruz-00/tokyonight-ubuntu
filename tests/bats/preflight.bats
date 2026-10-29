#!/usr/bin/env bats
# shellcheck disable=SC2016 # libsh scripts are single-quoted on purpose
# modules/00-preflight.sh and lib/detect.sh.

bats_require_minimum_version 1.5.0

load ../test_helper
load ../lib_test_helper

setup() {
  setup_sandbox
  export NO_COLOR=1 TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
}

@test "passes on the supported platform" {
  run_install -y
  assert_success
  assert_line --regexp '^preflight +OK$'
}

@test "refuses root" {
  TNU_EUID=0 run "$TNU_ROOT/install.sh" -y
  assert_failure 3
  assert_output --partial "do not run as root"
  assert_dir_not_exists "$XDG_STATE_HOME"
}

@test "rejects 24.04" {
  printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$SYS_ROOT/etc/os-release"
  run_install -y
  assert_failure 3
  assert_output --partial "unsupported OS: ubuntu 24.04"
  printf 'ID=debian\nVERSION_ID="26.04"\n' >"$SYS_ROOT/etc/os-release"
  run_install -y
  assert_failure 3
}

@test "rejects x86_64" {
  STUB_UNAME_M=x86_64 run_install -y
  assert_failure 3
  assert_output --partial "unsupported architecture: x86_64"
}

@test "--force allows 24.04 with warning" {
  printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$SYS_ROOT/etc/os-release"
  STUB_UNAME_M=x86_64 run_install -y --force
  assert_success
  assert_output --partial "warning: preflight: unsupported OS: ubuntu 24.04"
  assert_output --partial "warning: preflight: unsupported architecture"
}

@test "--force never allows root" {
  TNU_EUID=0 run "$TNU_ROOT/install.sh" -y --force
  assert_failure 3
}

@test "--force never allows a missing python3" {
  rm "$BATS_TEST_TMPDIR/sysbin/python3"
  run_install -y --force
  assert_failure 3
  assert_output --partial "python3 is required"
}

@test "missing required tools fail even with --force" {
  stub_disable curl
  run_install -y --force
  assert_failure 3
  assert_output --partial "missing required commands: curl"
}

@test "rejects non-GNOME desktop" {
  XDG_CURRENT_DESKTOP=KDE run_install -y
  assert_failure 3
  assert_output --partial "unsupported desktop: KDE"
  # No session: gnome-shell must be installed.
  XDG_CURRENT_DESKTOP="" run_install -y
  assert_failure 3
  mkdir -p "$SYS_ROOT/usr/bin"
  printf '#!/bin/sh\n' >"$SYS_ROOT/usr/bin/gnome-shell"
  chmod +x "$SYS_ROOT/usr/bin/gnome-shell"
  XDG_CURRENT_DESKTOP="" run_install -y
  assert_success
}

@test "detect sets IS_ERHAI from gresource file" {
  lib_setup
  run --separate-stderr libsh 'detect_env; echo "$IS_ERHAI"'
  assert_success
  assert_output 0
  mkdir -p "$SYS_ROOT/usr/share/gnome-shell/theme/erhai"
  : >"$SYS_ROOT/usr/share/gnome-shell/theme/erhai/gnome-shell-theme.gresource"
  run --separate-stderr libsh 'detect_env; echo "$IS_ERHAI"'
  assert_output 1
}

@test "detect sets IS_ERHAI from the erhai package" {
  lib_setup
  : >"$STUB_STATE/pkgs/oneplus-erhai-desktop"
  run --separate-stderr libsh 'detect_env; echo "$IS_ERHAI"'
  assert_output 1
}

@test "detect sets tool, extension and bus flags" {
  lib_setup
  run --separate-stderr libsh 'detect_env
    echo "$HAS_ZSH $HAS_PTYXIS $HAS_FLATPAK $HAS_ZELLIJ $HAS_LIG $HAS_GJSOSK $HAS_USER_THEME $HAS_SESSION_BUS $HAS_BASH_RC"'
  assert_output "0 0 0 0 0 0 0 1 0"
  stub_enable zsh ptyxis flatpak zellij lig
  mkdir -p "$HOME/.local/share/gnome-shell/extensions/gjsosk@vishram1123.com" \
    "$SYS_ROOT/usr/share/gnome-shell/extensions/user-theme@gnome-shell-extensions.gcampax.github.com"
  : >"$HOME/.bashrc"
  run --separate-stderr libsh 'unset DBUS_SESSION_BUS_ADDRESS; detect_env
    echo "$HAS_ZSH $HAS_PTYXIS $HAS_FLATPAK $HAS_ZELLIJ $HAS_LIG $HAS_GJSOSK $HAS_USER_THEME $HAS_SESSION_BUS $HAS_BASH_RC"'
  assert_output "1 1 1 1 1 1 1 0 1"
}

@test "preflight exports detection to modules" {
  stub_enable zsh
  mkdir -p "$BATS_TEST_TMPDIR/mods"
  ln -s "$TNU_ROOT/modules/00-preflight.sh" "$BATS_TEST_TMPDIR/mods/00-preflight.sh"
  cat >"$BATS_TEST_TMPDIR/mods/10-probe.sh" <<'EOF'
register_module probe 10 0
probe_applies() { return 0; }
probe_apply() { log_info "probe sees zsh=$HAS_ZSH erhai=$IS_ERHAI"; }
EOF
  TNU_MODULES_DIR="$BATS_TEST_TMPDIR/mods" run_install -y
  assert_success
  assert_output --partial "probe sees zsh=1 erhai=0"
}
