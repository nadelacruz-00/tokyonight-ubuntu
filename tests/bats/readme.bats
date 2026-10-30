#!/usr/bin/env bats
# README.md: images, flag coverage and PII.

bats_require_minimum_version 1.5.0

load ../test_helper

SHOTS_DIR() { printf '%s/docs/screenshots\n' "$TNU_ROOT"; }

_pngs() {
  find "$(SHOTS_DIR)" -maxdepth 1 -name '*.png' 2>/dev/null | LC_ALL=C sort
}

@test "every image referenced in README exists" {
  local img n=0
  while IFS= read -r img; do
    n=$((n + 1))
    [[ -f $TNU_ROOT/$img ]] || fail "missing image: $img"
  done < <(grep -oE '\]\(docs/[^)]+\.png\)' "$TNU_ROOT/README.md" | sed -E 's/^\]\(//; s/\)$//')
  ((n >= 7)) || fail "README references only $n images"
}

@test "README references the seven expected screenshots" {
  local f
  for f in desktop-tokyonight desktop-storm overview quick-settings ptyxis-tokyonight ptyxis-storm osk; do
    grep -q "docs/screenshots/$f.png" "$TNU_ROOT/README.md" || fail "README does not reference $f.png"
  done
}

@test "every image is at most 1.5 MB" {
  local f
  while IFS= read -r f; do
    ((($(stat -c %s "$f")) <= 1572864)) || fail "$f is over 1.5 MB"
  done < <(_pngs)
}

@test "no PNG metadata chunks in screenshots" {
  [[ -n $(_pngs) ]] || skip "no screenshots yet"
  run python3 -I "$TNU_ROOT/helpers/pii_scan.py" "$(SHOTS_DIR)"
  assert_success
}

@test "README documents every install.sh flag" {
  TNU_EUID=1000 run --separate-stderr "$TNU_ROOT/install.sh" --help
  assert_success
  local flags f
  flags=$(grep -oE '(^|[ ,])--?[a-zA-Z][a-zA-Z-]*' <<<"$output" | tr -d ' ,' | LC_ALL=C sort -u)
  [[ -n $flags ]]
  while IFS= read -r f; do
    grep -qE -- "\`([^\`]* )?$f([ ,|\`][^\`]*)?\`" "$TNU_ROOT/README.md" || fail "README does not document $f"
  done <<<"$flags"
}

@test "README has no PII" {
  run python3 -I "$TNU_ROOT/helpers/pii_scan.py" "$TNU_ROOT/README.md"
  assert_success
}

@test "README states Wayland only and that the flathub remote is kept on uninstall" {
  run grep -n 'X11' "$TNU_ROOT/README.md"
  assert_failure
  grep -q 'GNOME 50 on a running Wayland session' "$TNU_ROOT/README.md"
  grep -q 'kept, and so is the user-level `flathub` flatpak remote' "$TNU_ROOT/README.md"
}
