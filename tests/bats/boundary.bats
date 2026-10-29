#!/usr/bin/env bats
# Boundary guard: without --system nothing outside $HOME is written and no root
# tool runs; --dry-run writes nothing at all. Every module runs, on a "full"
# machine (every optional component present) and a "bare" one (none of them).

bats_require_minimum_version 1.5.0

load ../test_helper

ROOT_TOOLS=(sudo apt-get update-alternatives)
HOST_PATH=$PATH

# fresh full|bare: a new sandbox (wiping the previous one) seeded as that machine.
fresh() {
  export PATH=$HOST_PATH
  rm -rf "$BATS_TEST_TMPDIR/home dir" "$BATS_TEST_TMPDIR/root" "$BATS_TEST_TMPDIR/stub-state" \
    "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/sysbin" "$BATS_TEST_TMPDIR/tmp" "$BATS_TEST_TMPDIR/work"
  setup_sandbox
  export NO_COLOR=1 TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  # Root tools are stubs, so any call shows up in the stub log.
  stub_enable "${ROOT_TOOLS[@]}"
  fake_downloads
  fake_gresource_tools
  machine "$1"
}

# fake_downloads: both pinned downloads in the curl stub, with a checksum file.
fake_downloads() {
  local w="$BATS_TEST_TMPDIR/work" s1 s2
  mkdir -p "$w/pack"
  printf 'fake regular\n' >"$w/pack/JetBrainsMonoNerdFont-Regular.ttf"
  tar -C "$w/pack" -cJf "$STUB_STATE/downloads/JetBrainsMono.tar.xz" .
  printf '#!/bin/sh\necho 31.8.0\n' >"$STUB_STATE/downloads/posh-linux-arm64"
  s1=$(sha256sum <"$STUB_STATE/downloads/JetBrainsMono.tar.xz")
  s2=$(sha256sum <"$STUB_STATE/downloads/posh-linux-arm64")
  {
    printf '%s  JetBrainsMono.tar.xz  https://example.invalid/JetBrainsMono.tar.xz\n' "${s1%% *}"
    printf '%s  posh-linux-arm64  https://example.invalid/posh-linux-arm64\n' "${s2%% *}"
  } >"$w/sums"
  export TNU_CHECKSUMS="$w/sums"
}

# fake_gresource_tools: deterministic gresource tools (logging like the stubs)
# so the gdm module can build its theme in a --system dry run.
fake_gresource_tools() {
  local hdr='printf "%s\t%s\n" "${0##*/}" "$(printf "%q " "$@")" >>"$STUB_LOG"'
  cat >"$BATS_TEST_TMPDIR/bin/gresource" <<EOS
#!/usr/bin/env bash
$hdr
case \$1 in
  list) echo /org/gnome/shell/theme/gdm.css ;;
  extract) echo "body {}" ;;
esac
EOS
  cat >"$BATS_TEST_TMPDIR/bin/glib-compile-resources" <<EOS
#!/usr/bin/env bash
$hdr
while (( \$# )); do
  case \$1 in
    --sourcedir) src=\$2; shift 2 ;;
    --target) tgt=\$2; shift 2 ;;
    *) shift ;;
  esac
done
find "\$src" -type f | sort | xargs cat >"\$tgt"
EOS
  chmod +x "$BATS_TEST_TMPDIR/bin/gresource" "$BATS_TEST_TMPDIR/bin/glib-compile-resources"
}

# machine full|bare: seed SYS_ROOT and HOME. "full" has every optional component
# (erhai, user-theme, gjsosk, wallpaper, flatpak, ptyxis, zsh, zellij, lig, the
# OSK keycode cache, pre-existing user files); "bare" only the Yaru GDM base.
machine() {
  local s=$SYS_ROOT/usr/share
  mkdir -p "$s/gnome-shell/theme/Yaru"
  printf 'base-yaru' >"$s/gnome-shell/theme/Yaru/gnome-shell-theme.gresource"
  if [[ $1 == bare ]]; then return 0; fi
  stub_enable flatpak ptyxis zsh zellij lig
  mkdir -p "$s/gnome-shell/theme/erhai" "$s/backgrounds" \
    "$s/gnome-shell/extensions/user-theme@gnome-shell-extensions.gcampax.github.com" \
    "$s/gnome-shell/extensions/gjsosk@vishram1123.com" \
    "$HOME/.config/gtk-4.0" "$HOME/.config/zellij" "$HOME/.config/lig" \
    "$XDG_CACHE_HOME/gjs-osk/keycodes"
  printf 'base-erhai' >"$s/gnome-shell/theme/erhai/gnome-shell-theme.gresource"
  printf 'jpeg' >"$s/backgrounds/osselo-Ask_a_friend.jpg"
  printf 'console.log("upstream");\n' >"$s/gnome-shell/extensions/gjsosk@vishram1123.com/extension.js"
  cp "$TNU_ROOT/tests/fixtures/osk/us.json" "$XDG_CACHE_HOME/gjs-osk/keycodes/us.json"
  printf 'export EDITOR=vi\n' >"$HOME/.zshrc"
  printf 'alias ll="ls -l"\n' >"$HOME/.bashrc"
  printf 'window { margin: 0; }\n' >"$HOME/.config/gtk-4.0/gtk.css"
  printf 'theme "default"\n' >"$HOME/.config/zellij/config.kdl"
  printf '[ui]\ntheme = "default"\n' >"$HOME/.config/lig/config.toml"
}

# full_install ARGS...: every module, no confirmation; no module may fail.
full_install() {
  run_install -y "$@"
  assert_success
  refute_output --regexp 'FAILED'
}

refute_root_tools() {
  local t
  for t in "${ROOT_TOOLS[@]}"; do refute_stub_called "$t"; done
}

# root_paths_in_stub_log: stub log lines naming /usr/, /etc/ or /var/ outside
# SYS_ROOT. The wallpaper URI stored as a dconf value is a reference, not a file
# access, so it is allowed.
root_paths_in_stub_log() {
  local q_root q_tmp line
  q_root=$(printf '%q' "$SYS_ROOT")
  q_tmp=$(printf '%q' "$BATS_TEST_TMPDIR")
  while IFS= read -r line; do
    line=${line//"$q_root"\//SYSROOT:}
    line=${line//"$q_tmp"/TMP:}
    if [[ $line == dconf$'\t'* ]]; then line=${line//file:\/\/\/usr\/share\/backgrounds\//URI:}; fi
    if [[ $line =~ /(usr|etc|var)/ ]]; then printf '%s\n' "$line"; fi
  done <"$STUB_LOG"
}

@test "user-level full install never calls sudo/apt-get/update-alternatives" {
  local m
  for m in full bare; do
    fresh "$m"
    full_install
    assert_output --regexp 'gdm +SKIPPED needs --system'
    full_install --variant storm
    refute_root_tools
    # undoing it needs no root either
    run_install -y --uninstall --purge
    assert_success
    refute_root_tools
  done
}

@test "user-level install leaves SYS_ROOT unchanged" {
  local m snap="$BATS_TEST_TMPDIR/sysroot.snap"
  for m in full bare; do
    fresh "$m"
    tree_snapshot "$SYS_ROOT" >"$snap"
    full_install
    assert_tree_unchanged "$snap" "$SYS_ROOT"
    full_install --variant storm
    assert_tree_unchanged "$snap" "$SYS_ROOT"
    run_install -y --uninstall --purge
    assert_success
    assert_tree_unchanged "$snap" "$SYS_ROOT"
  done
}

@test "no stub argv contains /usr/, /etc/ or /var/ paths outside SYS_ROOT reads" {
  local m
  fresh bare
  # the detector flags a root path and ignores SYS_ROOT ones
  printf 'cp\t/usr/share/x %s/usr/share/y\n' "$SYS_ROOT" >"$STUB_LOG"
  run root_paths_in_stub_log
  assert_output $'cp\t/usr/share/x SYSROOT:usr/share/y'
  for m in full bare; do
    fresh "$m"
    full_install
    assert_stub_called dconf "write "
    full_install --variant storm
    run_install -y --uninstall --purge
    assert_success
    run root_paths_in_stub_log
    assert_output ''
  done
}

@test "dry-run full install mutates nothing" {
  local m args snap_home="$BATS_TEST_TMPDIR/home.snap" snap_sys="$BATS_TEST_TMPDIR/sys.snap"
  local -a extra
  for m in full bare; do
    for args in "" "--system" "--variant storm"; do
      fresh "$m"
      IFS=' ' read -r -a extra <<<"$args"
      tree_snapshot "$HOME" >"$snap_home"
      tree_snapshot "$SYS_ROOT" >"$snap_sys"
      full_install --dry-run "${extra[@]}"
      assert_output --regexp 'CHANGED'
      assert_tree_unchanged "$snap_home" "$HOME"
      assert_tree_unchanged "$snap_sys" "$SYS_ROOT"
      refute_stub_called dconf '(write|reset) '
      refute_root_tools
    done
  done
  # dry runs over an existing install change nothing either
  fresh full
  full_install
  tree_snapshot "$HOME" >"$snap_home"
  : >"$STUB_LOG"
  full_install --dry-run --variant storm
  assert_tree_unchanged "$snap_home" "$HOME"
  full_install --uninstall --dry-run --purge
  assert_tree_unchanged "$snap_home" "$HOME"
  refute_stub_called dconf '(write|reset) '
  refute_root_tools
}
