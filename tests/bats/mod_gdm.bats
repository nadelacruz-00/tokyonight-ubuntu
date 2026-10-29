#!/usr/bin/env bats
# modules/90-gdm.sh with fake gresource tools (the real ones are covered by
# tests/python/test_gresource.py).

bats_require_minimum_version 1.5.0

load ../test_helper

THEME=usr/share/gnome-shell/theme
DEST=usr/share/gnome-shell/theme/tokyonight-ubuntu/gnome-shell-theme.gresource

setup() {
  setup_sandbox
  export NO_COLOR=1 TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR" "$SYS_ROOT/$THEME/Yaru" "$SYS_ROOT/usr/share/backgrounds"
  printf 'base-yaru' >"$SYS_ROOT/$THEME/Yaru/gnome-shell-theme.gresource"
  printf 'jpeg' >"$SYS_ROOT/usr/share/backgrounds/osselo-Ask_a_friend.jpg"
  stub_enable sudo apt-get update-alternatives
  fake_tools
}

# Fakes that log like the stubs and produce deterministic output.
fake_tools() {
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

@test "skipped without --system" {
  run_install -y --only gdm
  assert_success
  assert_output --regexp 'gdm +SKIPPED.*--system'
  refute_stub_called sudo "-- "
}

@test "uses erhai base when present else Yaru" {
  run_install -y --system --only gdm
  assert_success
  assert_stub_called gresource "list .*/Yaru/gnome-shell-theme.gresource"
  : >"$STUB_LOG"
  mkdir -p "$SYS_ROOT/$THEME/erhai"
  printf 'base-erhai' >"$SYS_ROOT/$THEME/erhai/gnome-shell-theme.gresource"
  run_install -y --system --only gdm
  assert_success
  assert_stub_called gresource "list .*/erhai/gnome-shell-theme.gresource"
}

@test "fails cleanly when no base" {
  rm "$SYS_ROOT/$THEME/Yaru/gnome-shell-theme.gresource"
  run_install -y --system --only gdm
  assert_failure 1
  assert_output --partial "no base GDM theme"
  refute_stub_called update-alternatives
}

@test "fails cleanly when the wallpaper is missing" {
  rm "$SYS_ROOT/usr/share/backgrounds/osselo-Ask_a_friend.jpg"
  run_install -y --system --only gdm
  assert_failure 1
  assert_output --partial "osselo-Ask_a_friend.jpg is missing"
}

@test "installs missing build tools with apt-get" {
  rm "$BATS_TEST_TMPDIR/bin/gresource"
  run_install -y --system --only gdm
  assert_failure 1
  assert_stub_called apt-get "install -y libglib2.0-dev-bin"
  assert_stub_called apt-get 'update$'
}

@test "installs via sudo with priority 160" {
  run_install -y --system --only gdm
  assert_success
  assert_output --regexp 'gdm +CHANGED'
  assert_output --partial "applies at next GDM start"
  assert_file_exists "$SYS_ROOT/$DEST"
  assert_stub_called sudo "-- install -D -m 0644 -- .*/gnome-shell-theme.gresource .*tokyonight-ubuntu/gnome-shell-theme.gresource"
  assert_stub_called update-alternatives "--install /usr/share/gnome-shell/gdm-theme.gresource gdm-theme.gresource /usr/share/gnome-shell/theme/tokyonight-ubuntu/gnome-shell-theme.gresource 160"
  grep -q 'tokyonight-ubuntu overrides' "$SYS_ROOT/$DEST"
  m=$(cat "$XDG_STATE_HOME"/tokyonight-ubuntu/backups/*/manifest.tsv)
  [[ $m == *$'dir\t'*"/tokyonight-ubuntu"* ]]
  [[ $m == *$'sysfile\t'*"$DEST"$'\tABSENT\t'* ]]
  [[ $m == *$'alt\tgdm-theme.gresource\t/usr/share/gnome-shell/theme/tokyonight-ubuntu/gnome-shell-theme.gresource'* ]]
}

@test "second run no reinstall" {
  run_install -y --system --only gdm
  assert_success
  # a real update-alternatives would have written its admin file
  mkdir -p "$SYS_ROOT/var/lib/dpkg/alternatives"
  printf 'auto\n/usr/share/gnome-shell/gdm-theme.gresource\n/%s\n160\n' "$DEST" \
    >"$SYS_ROOT/var/lib/dpkg/alternatives/gdm-theme.gresource"
  : >"$STUB_LOG"
  run_install -y --system --only gdm
  assert_success
  assert_output --regexp 'gdm +OK'
  refute_stub_called sudo "-- "
  refute_stub_called update-alternatives
}

@test "dry-run changes nothing" {
  snap="$BATS_TEST_TMPDIR/snap"
  tree_snapshot "$SYS_ROOT" >"$snap"
  run_install -y --system --only gdm --dry-run
  assert_success
  assert_output --regexp 'gdm +CHANGED'
  assert_tree_unchanged "$snap" "$SYS_ROOT"
  refute_stub_called update-alternatives
}

@test "dry-run previews when the wallpaper is not installed yet" {
  rm "$SYS_ROOT/usr/share/backgrounds/osselo-Ask_a_friend.jpg"
  run_install -y --system --only gdm --dry-run
  assert_success
  assert_output --regexp 'gdm +CHANGED'
  refute_stub_called update-alternatives
}

@test "dry-run previews when the build tools are not installed yet" {
  rm "$BATS_TEST_TMPDIR/bin/gresource"
  run_install -y --system --only gdm --dry-run
  assert_success
  assert_output --regexp 'gdm +CHANGED'
  refute_stub_called gresource
}

@test "uninstall removes alternative and file" {
  snap="$BATS_TEST_TMPDIR/snap"
  tree_snapshot "$SYS_ROOT" >"$snap"
  run_install -y --system --only gdm
  assert_success
  : >"$STUB_LOG"
  run_install -y --system --uninstall
  assert_success
  assert_stub_called update-alternatives "--remove gdm-theme.gresource /usr/share/gnome-shell/theme/tokyonight-ubuntu/gnome-shell-theme.gresource"
  assert_file_not_exists "$SYS_ROOT/$DEST"
  assert_dir_not_exists "$SYS_ROOT/$THEME/tokyonight-ubuntu"
  assert_tree_unchanged "$snap" "$SYS_ROOT"
}

@test "warns when gdm-theme.gresource is pinned manually to another theme" {
  printf 'Name: gdm-theme.gresource\nLink: /usr/share/gnome-shell/gdm-theme.gresource\nStatus: manual\nBest: /%s\nValue: /usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource\n' "$DEST" \
    >"$STUB_STATE/ua-query.gdm-theme.gresource"
  run_install -y --system --only gdm
  assert_success
  assert_stub_called update-alternatives '--query gdm-theme.gresource'
  assert_output --partial "pinned manually"
  assert_output --partial "sudo update-alternatives --auto gdm-theme.gresource"
}

@test "no pin warning when the alternative is automatic or already ours" {
  printf 'Name: gdm-theme.gresource\nStatus: auto\nValue: /usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource\n' \
    >"$STUB_STATE/ua-query.gdm-theme.gresource"
  run_install -y --system --only gdm
  assert_success
  refute_output --partial "pinned manually"
  printf 'Name: gdm-theme.gresource\nStatus: manual\nValue: /%s\n' "$DEST" \
    >"$STUB_STATE/ua-query.gdm-theme.gresource"
  : >"$STUB_LOG"
  run_install -y --system --only gdm
  assert_success
  assert_stub_called update-alternatives '--query gdm-theme.gresource'
  refute_output --partial "pinned manually"
}
