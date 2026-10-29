#!/usr/bin/env bats

load ../test_helper

UUID="gjsosk-theme-sync@nadelacruz-00.github.io"

setup() {
  setup_sandbox
  A="$TNU_ROOT/assets"
}

@test "vendored checksums verify" {
  cd "$A"
  grep -Ev '^[0-9a-f]{64}  [^ ]+  https://' checksums.sha256 >"$BATS_TEST_TMPDIR/vendored.sums"
  [ -s "$BATS_TEST_TMPDIR/vendored.sums" ]
  run sha256sum -c "$BATS_TEST_TMPDIR/vendored.sums"
  assert_success
}

@test "checksums pin both downloads" {
  run grep -c -E '^[0-9a-f]{64}  [^ ]+  https://' "$A/checksums.sha256"
  assert_output 2
  run grep -F '04d5e8f903693f9dd13e16f867e994834e681eb3c72c0d337a770dcda09010cf  JetBrainsMono.tar.xz  https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/JetBrainsMono.tar.xz' "$A/checksums.sha256"
  assert_success
  run grep -F 'c7ee6d1075b625a4f151bf177defbaed55995b2fcd98e410c7990d2394c3fd80  posh-linux-arm64  https://github.com/JanDeDobbeleer/oh-my-posh/releases/download/v31.8.0/posh-linux-arm64' "$A/checksums.sha256"
  assert_success
}

@test "tokyonight gtk4 has #1a1b26 window bg" {
  run grep -F '#1a1b26' "$A/rewaita/tokyonight/gtk4.css"
  assert_success
}

@test "storm gtk4 has #24283b window bg" {
  run grep -F '#24283b' "$A/rewaita/storm/gtk4.css"
  assert_success
}

@test "variants differ" {
  run cmp -s "$A/rewaita/tokyonight/gtk4.css" "$A/rewaita/storm/gtk4.css"
  assert_failure
}

@test "all rewaita files exist for both variants" {
  for v in tokyonight storm; do
    for f in gtk4.css gtk3.css gnome-shell.css; do
      [ -s "$A/rewaita/$v/$f" ]
    done
  done
}

@test "palette.py parses both variants" {
  [ -f "$TNU_ROOT/helpers/palette.py" ] || skip "helpers/palette.py not merged yet"
  for v in tokyonight storm; do
    run python3 -I "$TNU_ROOT/helpers/palette.py" "$A/rewaita/$v/gtk4.css"
    assert_success
  done
}

@test "theme-sync metadata uuid matches dir name" {
  d="$A/osk/$UUID"
  [ -f "$d/metadata.json" ]
  run python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8"))["uuid"])' "$d/metadata.json"
  assert_success
  assert_output "$UUID"
}

@test "split-flush hook files are vendored" {
  [ -f "$A/osk/gjsosk-split-flush" ]
  [ -f "$A/osk/99erhai-gjsosk-split-flush" ]
}

@test "assets contain no PII" {
  if [ -f "$TNU_ROOT/helpers/pii_scan.py" ]; then
    run python3 -I "$TNU_ROOT/helpers/pii_scan.py" "$A"
    assert_success
  else
    run bash -c "grep -rIE '/home/|/Users/|[A-Za-z0-9._-]+@[A-Za-z0-9-]+\\.[A-Za-z]{2,}' '$A' --exclude=SOURCES.md --exclude=checksums.sha256 | grep -vF -e '@nadelacruz-00.github.io' -e '@vishram1123.com'"
    assert_failure
  fi
  run grep -rIiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$A"
  assert_failure
}

@test "omp json is valid JSON" {
  run python3 -I -c 'import json,sys; json.load(open(sys.argv[1],encoding="utf-8"))' "$A/omp/tokyonight_storm.omp.json"
  assert_success
}

@test "gjs theme-sync test" {
  command -v gjs >/dev/null 2>&1 || skip "gjs not installed"
  run gjs -m "$TNU_ROOT/tests/gjs/theme-sync.test.js"
  assert_success
  refute_output --partial FAIL
}
