#!/usr/bin/env bash
# Shared bats helper: sandboxed HOME/PATH, command stubs, tree snapshots.

TNU_ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
export TNU_ROOT

load_libs() {
  load "$TNU_ROOT/tests/bats/bats-support/load"
  load "$TNU_ROOT/tests/bats/bats-assert/load"
  load "$TNU_ROOT/tests/bats/bats-file/load"
}
load_libs

SYSBIN_TOOLS=(bash env cat cp mv rm mkdir ln ls chmod stat touch mktemp date sleep
  sort uniq head tail tr cut wc grep sed awk find xargs cmp diff sha256sum tar xz
  python3 flock install readlink dirname basename id printf tee kill timeout sync rmdir)

DEFAULT_STUBS=(dconf curl fc-cache uname dpkg-query)

setup_sandbox() {
  export HOME="$BATS_TEST_TMPDIR/home dir"
  export XDG_CONFIG_HOME="$HOME/.config"
  export XDG_STATE_HOME="$HOME/.local/state"
  export XDG_CACHE_HOME="$HOME/.cache"
  export XDG_DATA_HOME="$HOME/.local/share"
  export SYS_ROOT="$BATS_TEST_TMPDIR/root"
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  export STUB_STATE="$BATS_TEST_TMPDIR/stub-state"
  export XDG_CURRENT_DESKTOP="ubuntu:GNOME"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=/dev/null"
  mkdir -p "$HOME" "$SYS_ROOT/etc" "$STUB_STATE/downloads" "$STUB_STATE/pkgs" \
    "$STUB_STATE/flatpak" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/sysbin"
  : >"$STUB_LOG"
  printf 'ID=ubuntu\nVERSION_ID="26.04"\n' >"$SYS_ROOT/etc/os-release"
  local t p
  for t in "${SYSBIN_TOOLS[@]}"; do
    p="$(PATH=/usr/bin:/bin command -v "$t" || true)"
    [[ -n $p ]] && ln -sf "$p" "$BATS_TEST_TMPDIR/sysbin/$t"
  done
  export PATH="$BATS_TEST_TMPDIR/bin:$BATS_TEST_TMPDIR/sysbin"
  stub_enable "${DEFAULT_STUBS[@]}"
}

stub_enable() {
  local n
  for n in "$@"; do
    ln -sf "$TNU_ROOT/tests/stubs/bin/$n" "$BATS_TEST_TMPDIR/bin/$n"
  done
}

stub_disable() {
  local n
  for n in "$@"; do
    rm -f "$BATS_TEST_TMPDIR/bin/$n"
  done
}

dconf_get() {
  local key=$1 k v
  [[ -f $STUB_STATE/dconf.tsv ]] || return 0
  while IFS=$'\t' read -r k v; do
    if [[ $k == "$key" ]]; then
      printf '%s\n' "$v"
    fi
  done <"$STUB_STATE/dconf.tsv" | tail -n 1
}

dconf_put() {
  dconf write "$1" "$2"
}

assert_stub_called() {
  local name=$1 re=${2:-}
  if ! grep -Eq -- "^${name}"$'\t'"${re}" "$STUB_LOG"; then
    echo "expected stub '$name' call matching '$re'; log:" >&2
    cat "$STUB_LOG" >&2
    return 1
  fi
}

refute_stub_called() {
  local name=$1 re=${2:-}
  if grep -Eq -- "^${name}"$'\t'"${re}" "$STUB_LOG"; then
    echo "unexpected stub '$name' call matching '$re'; log:" >&2
    cat "$STUB_LOG" >&2
    return 1
  fi
}

# One line per entry: "sha256  mode  path" (file), "symlink  path -> target",
# "dir  mode  path/".
tree_snapshot() {
  local dir=$1
  (
    cd "$dir" || exit 1
    find . -mindepth 1 -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' f; do
      if [[ -L $f ]]; then
        printf 'symlink  %s -> %s\n' "${f#./}" "$(readlink "$f")"
      elif [[ -d $f ]]; then
        printf 'dir  %s  %s/\n' "$(stat -c %a "$f")" "${f#./}"
      else
        printf '%s  %s  %s\n' "$(sha256sum <"$f" | cut -d' ' -f1)" "$(stat -c %a "$f")" "${f#./}"
      fi
    done
  )
}

assert_tree_unchanged() {
  local snap=$1 dir=$2
  if ! diff -u "$snap" <(tree_snapshot "$dir"); then
    echo "tree changed: $dir" >&2
    return 1
  fi
}

run_install() {
  TNU_EUID=1000 run "$TNU_ROOT/install.sh" "$@"
}
