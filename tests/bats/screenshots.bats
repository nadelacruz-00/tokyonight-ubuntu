#!/usr/bin/env bats
# tools/screenshots.sh: the pure parts only (no capture is ever started).

bats_require_minimum_version 1.5.0

load ../test_helper

setup() {
  # shellcheck source=/dev/null
  source "$TNU_ROOT/tools/screenshots.sh"
}

@test "--help prints usage and exits 0" {
  run "$TNU_ROOT/tools/screenshots.sh" --help
  assert_success
  assert_output --partial "--variant tokyonight|storm"
}

@test "no arguments is a usage error (exit 2) and captures nothing" {
  run -2 "$TNU_ROOT/tools/screenshots.sh"
  assert_output --partial "no SHOT given"
}

@test "parse_args accepts shots and a variant" {
  parse_args --variant storm desktop osk
  [[ $VARIANT == storm ]]
  [[ ${#SHOTS[@]} == 2 && ${SHOTS[0]} == desktop && ${SHOTS[1]} == osk ]]
}

@test "parse_args defaults to tokyonight" {
  parse_args ptyxis
  [[ $VARIANT == tokyonight ]]
}

@test "parse_args rejects unknown shots, variants and options" {
  run -2 parse_args wifi-menu
  assert_output --partial "unknown shot"
  run -2 parse_args --variant mauve desktop
  assert_output --partial "unknown variant"
  run -2 parse_args --bogus desktop
  assert_output --partial "unknown option"
  run -2 parse_args --variant
  assert_output --partial "needs a value"
}

@test "out_path: variant only on desktop and ptyxis" {
  [[ $(out_path desktop storm) == "$TNU_ROOT/docs/screenshots/desktop-storm.png" ]]
  [[ $(out_path ptyxis tokyonight) == "$TNU_ROOT/docs/screenshots/ptyxis-tokyonight.png" ]]
  [[ $(out_path overview storm) == "$TNU_ROOT/docs/screenshots/overview.png" ]]
  [[ $(out_path osk tokyonight) == "$TNU_ROOT/docs/screenshots/osk.png" ]]
}

@test "the omp segments print no user, host or session" {
  run python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
bad = [s["type"] for b in d["blocks"] for s in b["segments"]
       if s["type"] in ("session", "os", "shell") or any(k in (s.get("template") or "") for k in ("UserName", "HostName"))]
print(bad)
sys.exit(1 if bad else 0)' "$TNU_ROOT/assets/omp/tokyonight_storm.omp.json"
  assert_success
}

@test "quick-settings is a shot without a variant suffix" {
  parse_args quick-settings
  [[ ${SHOTS[0]} == quick-settings ]]
  [[ $(out_path quick-settings storm) == "$TNU_ROOT/docs/screenshots/quick-settings.png" ]]
}
