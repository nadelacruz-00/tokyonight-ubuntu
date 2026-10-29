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

@test "--delay: valid values parse, invalid ones exit 2" {
  parse_args --delay 7 desktop
  [[ $DELAY == 7 ]]
  parse_args desktop
  [[ $DELAY == 0 ]]
  run -2 parse_args --delay abc desktop
  assert_output --partial "--delay needs"
  run -2 parse_args --delay -3 desktop
  run -2 parse_args --delay
  run -2 "$TNU_ROOT/tools/screenshots.sh" --delay 1.5 desktop
}

# A fake capture: writes a minimal PNG; `read` is replaced by a recorder.
_delay_run() {
  export SHOT_DIR="$BATS_TEST_TMPDIR/shots" READ_LOG="$BATS_TEST_TMPDIR/read.log"
  : >"$READ_LOG"
  cat >"$BATS_TEST_TMPDIR/fake-capture" <<'FAKE'
#!/usr/bin/env bash
python3 -I -c 'import sys,zlib,struct
def c(t,b): return struct.pack(">I",len(b))+t+b+struct.pack(">I",zlib.crc32(t+b)&0xffffffff)
open(sys.argv[1],"wb").write(b"\x89PNG\r\n\x1a\n"+c(b"IHDR",struct.pack(">IIBBBBB",1,1,8,2,0,0,0))+c(b"IDAT",zlib.compress(b"\x00\xff\x00\x00"))+c(b"IEND",b""))' "$1"
FAKE
  chmod +x "$BATS_TEST_TMPDIR/fake-capture"
  export TNU_SHOT_CAPTURE="$BATS_TEST_TMPDIR/fake-capture"
  read() { echo READ >>"$READ_LOG"; }
  parse_args "$@"
  countdown() { echo "COUNTDOWN $1" >>"$READ_LOG"; }
  capture_shot "${SHOTS[0]}"
}

@test "--delay > 0: never reads from the terminal, counts down, captures" {
  _delay_run --delay 3 quick-settings
  [[ -s $SHOT_DIR/quick-settings.png ]]
  run cat "$READ_LOG"
  assert_output "COUNTDOWN 3"
}

@test "delay 0: waits for Enter" {
  _delay_run quick-settings
  run cat "$READ_LOG"
  assert_output "READ"
}

@test "--delay 1 desktop: counts down and never reads" {
  _delay_run --delay 1 desktop
  [[ -s $SHOT_DIR/desktop-tokyonight.png ]]
  run cat "$READ_LOG"
  assert_output "COUNTDOWN 1"
}

@test "TNU_SHOT_CAPTURE refuses the real docs/screenshots (exit 2) and announces itself" {
  run -2 env TNU_SHOT_CAPTURE=/bin/true "$TNU_ROOT/tools/screenshots.sh" desktop
  assert_output --partial "TEST HOOK ACTIVE: TNU_SHOT_CAPTURE=/bin/true"
  assert_output --partial "refusing"
}
