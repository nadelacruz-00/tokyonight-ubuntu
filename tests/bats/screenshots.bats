#!/usr/bin/env bats
# tools/screenshots.sh: the pure parts only (no capture is ever started).

bats_require_minimum_version 1.5.0

load ../test_helper

setup() {
  unset SHOT_DIR
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
  ask() { echo READ >>"$READ_LOG"; }
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

# A copy of the tool in a throwaway tree, so guard tests never run against the
# repo's real docs/screenshots (a sentinel there must survive).
_fake_root() {
  FAKE_ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$FAKE_ROOT/tools" "$FAKE_ROOT/docs/screenshots"
  cp "$TNU_ROOT/tools/screenshots.sh" "$TNU_ROOT/tools/live_state.sh" "$FAKE_ROOT/tools/"
  printf 'keep me' >"$FAKE_ROOT/docs/screenshots/desktop-tokyonight.png"
}

@test "TNU_SHOT_CAPTURE refuses the real docs/screenshots (exit 2), announces itself, deletes nothing" {
  _fake_root
  run -2 env -u SHOT_DIR TNU_SHOT_CAPTURE=/bin/true "$FAKE_ROOT/tools/screenshots.sh" desktop
  assert_output --partial "TEST HOOK ACTIVE: TNU_SHOT_CAPTURE=/bin/true"
  assert_output --partial "refusing"
  [[ $(cat "$FAKE_ROOT/docs/screenshots/desktop-tokyonight.png") == "keep me" ]]
}

@test "TNU_SHOT_CAPTURE still refuses the real dir when SHOT_DIR spells it differently" {
  _fake_root
  run -2 env "SHOT_DIR=$FAKE_ROOT/docs/../docs/screenshots" TNU_SHOT_CAPTURE=/bin/true \
    "$FAKE_ROOT/tools/screenshots.sh" --auto --delay 0 desktop
  assert_output --partial "refusing"
  [[ $(cat "$FAKE_ROOT/docs/screenshots/desktop-tokyonight.png") == "keep me" ]]
}

@test "SHOT_DIR from the environment overrides docs/screenshots" {
  export SHOT_DIR="$BATS_TEST_TMPDIR/elsewhere"
  source "$TNU_ROOT/tools/screenshots.sh"
  [[ $(out_path desktop storm) == "$BATS_TEST_TMPDIR/elsewhere/desktop-storm.png" ]]
  [[ $(out_path overview storm) == "$BATS_TEST_TMPDIR/elsewhere/overview.png" ]]
}

# --- overview / --auto: everything with side effects is a stub ----------------
# Sandbox (fake HOME, curated PATH: stubs + sysbin only), fake capture and key
# injector that log to STUB_LOG; nothing reaches the real session.
_live_env() {
  setup_sandbox
  stub_enable busctl gsettings ptyxis zsh oh-my-posh flatpak
  local git
  git=$(PATH=/usr/bin:/bin command -v git)
  ln -sf "$git" "$BATS_TEST_TMPDIR/sysbin/git"
  export SHOT_DIR="$BATS_TEST_TMPDIR/shots" READ_LOG="$BATS_TEST_TMPDIR/read.log"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  : >"$READ_LOG"
  cat >"$BATS_TEST_TMPDIR/fake-capture" <<'FAKE'
#!/usr/bin/env bash
# $1: temp file to write, $2: the target's name
printf 'capture\t%s\n' "$2" >>"$STUB_LOG"
if [[ $2 == "${FAIL_ON:-}" ]]; then exit 1; fi
if [[ $2 == "${INT_ON:-}" ]]; then kill -INT "$PPID"; fi
python3 -I -c 'import sys,zlib,struct
def c(t,b): return struct.pack(">I",len(b))+t+b+struct.pack(">I",zlib.crc32(t+b)&0xffffffff)
open(sys.argv[1],"wb").write(b"\x89PNG\r\n\x1a\n"+c(b"IHDR",struct.pack(">IIBBBBB",1,1,8,2,0,0,0))+c(b"IDAT",zlib.compress(b"\x00\xff\x00\x00"))+c(b"IEND",b""))' "$1"
FAKE
  printf '#!/usr/bin/env bash\nprintf "inject\\t%%s\\n" "$1" >>"$STUB_LOG"\n' >"$BATS_TEST_TMPDIR/fake-inject"
  chmod +x "$BATS_TEST_TMPDIR/fake-capture" "$BATS_TEST_TMPDIR/fake-inject"
  export TNU_SHOT_CAPTURE="$BATS_TEST_TMPDIR/fake-capture" TNU_INJECT_KEYS="$BATS_TEST_TMPDIR/fake-inject"
  OSK_DIR="$SYS_ROOT/usr/share/gnome-shell/extensions/gjsosk@vishram1123.com/schemas"
  mkdir -p "$OSK_DIR"
  gsettings set org.gnome.shell.keybindings toggle-quick-settings "['<Super>s']"
  gsettings set org.gnome.shell.extensions.gjsosk.indicator opened false
  : >"$STUB_LOG"
}

# In-process: source after the sandbox (SYS_ROOT), record pauses and prompts.
_live_source() {
  # shellcheck source=/dev/null
  source "$TNU_ROOT/tools/screenshots.sh"
  pause() { printf 'pause\t%s\n' "$1" >>"$STUB_LOG"; }
  countdown() { printf 'countdown\t%s\n' "$1" >>"$STUB_LOG"; }
  ask() { echo READ >>"$READ_LOG"; }
}

# _assert_order ERE...: each pattern matches a STUB_LOG line after the previous.
_assert_order() {
  local re n=0 m
  for re in "$@"; do
    re=${re//\\t/$'\t'}
    m=$(tail -n +"$((n + 1))" "$STUB_LOG" | grep -nE -m1 -- "$re" | cut -d: -f1) || true
    if [[ -z $m ]]; then
      echo "expected (after line $n): $re" >&2
      cat -n "$STUB_LOG" >&2
      return 1
    fi
    n=$((n + m))
  done
}

OV='busctl\t--user set-property org.gnome.Shell /org/gnome/Shell org.gnome.Shell OverviewActive b'
OSKG='gsettings\t--schemadir .*gjsosk@vishram1123\.com/schemas'

@test "overview --delay: opens via OverviewActive after the countdown, waits 1 s, closes after capture" {
  _live_env
  _live_source
  parse_args --delay 2 overview
  capture_shot overview
  [[ -s $SHOT_DIR/overview.png ]]
  _assert_order '^countdown\t2$' "^$OV true$" '^pause\t1$' '^capture\toverview\.png$' "^$OV false$"
  refute_stub_called busctl ".*FocusSearch"
  run cat "$READ_LOG"
  assert_output ""
}

@test "overview without --delay: opens via OverviewActive, waits 1 s, no prompt, closes" {
  _live_env
  _live_source
  parse_args overview
  capture_shot overview
  _assert_order "^$OV true$" '^pause\t1$' '^capture\toverview\.png$' "^$OV false$"
  run cat "$READ_LOG"
  assert_output ""
}

@test "overview --delay: set-property failure dies and captures nothing" {
  _live_env
  _live_source
  export STUB_BUSCTL_RC=1
  parse_args --delay 1 overview
  run capture_shot overview
  assert_failure 1
  assert_output --partial "could not open the overview"
  refute_stub_called capture
  [[ ! -e $SHOT_DIR/overview.png ]]
}

@test "overview without --delay: set-property failure falls back to the Enter prompt" {
  _live_env
  _live_source
  export STUB_BUSCTL_RC=1
  parse_args overview
  capture_shot overview
  [[ -s $SHOT_DIR/overview.png ]]
  run cat "$READ_LOG"
  assert_output "READ"
  refute_stub_called busctl ".*b false"
}

@test "overview: closed again (OverviewActive false) by the EXIT trap when the capture fails" {
  _live_env
  export FAIL_ON=overview.png
  run "$TNU_ROOT/tools/screenshots.sh" --delay 0 overview
  assert_failure 1
  assert_output --partial "no screenshot produced for overview"
  _assert_order "^$OV true$" '^capture\toverview\.png$' "^$OV false$"
}

@test "--auto: parse defaults (all shots, delay 10) and usage errors" {
  parse_args --auto
  [[ $AUTO == 1 && $DELAY == 10 && ${#SHOTS[@]} == 5 ]]
  parse_args --auto --delay 3 osk desktop
  [[ $DELAY == 3 && ${#SHOTS[@]} == 2 && ${SHOTS[0]} == osk && ${SHOTS[1]} == desktop ]]
  run -2 "$TNU_ROOT/tools/screenshots.sh" --with-storm desktop
  assert_output --partial "--with-storm needs --auto"
  run -2 parse_args --auto --variant storm
  run -2 parse_args --auto --with-storm overview osk
  assert_output --partial "desktop and ptyxis"
}

@test "--auto: one countdown, then every shot in order, each opened and closed, no prompts" {
  _live_env
  _live_source
  parse_args --auto osk quick-settings ptyxis overview desktop
  run_auto
  _assert_order '^countdown\t10$' \
    '^capture\tdesktop-tokyonight\.png$' \
    "^$OV true$" '^pause\t1$' '^capture\toverview\.png$' "^$OV false$" \
    '^gsettings\tget org\.gnome\.shell\.keybindings toggle-quick-settings$' \
    '^inject\t<Super>s$' '^pause\t1$' '^capture\tquick-settings\.png$' '^inject\tEscape$' \
    '^pause\t4$' '^capture\tptyxis-tokyonight\.png$' \
    "^$OSKG get org\.gnome\.shell\.extensions\.gjsosk\.indicator opened$" \
    "^$OSKG set org\.gnome\.shell\.extensions\.gjsosk\.indicator opened true$" \
    '^pause\t1\.5$' '^capture\tosk\.png$' \
    "^$OSKG set org\.gnome\.shell\.extensions\.gjsosk\.indicator opened false$"
  run grep -c '^countdown' "$STUB_LOG"
  assert_output 1
  run cat "$READ_LOG"
  assert_output ""
  [[ ${#OUTS[@]} == 5 ]]
  assert_stub_called ptyxis '--new-window -- env -i'
  refute_stub_called busctl '.*FocusSearch' 
  # the gjsosk key is back to what it was
  run gsettings get org.gnome.shell.extensions.gjsosk.indicator opened
  assert_output false
  refute_stub_called flatpak
}

@test "--auto osk: skipped with a warning when the gjsosk schema is missing" {
  _live_env
  rm -rf "$OSK_DIR"
  _live_source
  parse_args --auto osk
  run_auto 2>"$BATS_TEST_TMPDIR/err"
  run cat "$BATS_TEST_TMPDIR/err"
  assert_output --partial "osk shot skipped"
  refute_stub_called capture
  refute_stub_called gsettings ".*opened"
}

@test "--auto: a manual fallback is a failure, never a prompt" {
  _live_source
  AUTO=1
  run capture_manual "$BATS_TEST_TMPDIR/tmp.png" desktop "$BATS_TEST_TMPDIR/x.png"
  assert_failure
  assert_output --partial "never falls back to manual"
}

@test "--auto: Quick Settings closed (Escape) by the trap when its capture fails" {
  _live_env
  export FAIL_ON=quick-settings.png
  run "$TNU_ROOT/tools/screenshots.sh" --auto --delay 0 quick-settings
  assert_failure 1
  _assert_order '^inject\t<Super>s$' '^capture\tquick-settings\.png$' '^inject\tEscape$'
}

@test "--auto: the osk key is restored by the trap when its capture fails" {
  _live_env
  gsettings set org.gnome.shell.extensions.gjsosk.indicator opened "'odd value'"
  : >"$STUB_LOG"
  export FAIL_ON=osk.png
  run "$TNU_ROOT/tools/screenshots.sh" --auto --delay 0 osk
  assert_failure 1
  _assert_order "opened true$" '^capture\tosk\.png$' "opened \\\\'odd\\\\ value\\\\'$"
  run gsettings get org.gnome.shell.extensions.gjsosk.indicator opened
  assert_output "'odd value'"
}

# --with-storm: a fake HOME with theme files, dconf stub state, and a fake
# Rewaita (flatpak run) that rewrites files and keys the way the real one does.
_storm_env() {
  _live_env
  REW=io.github.swordpuffin.rewaita
  : >"$STUB_STATE/flatpak/$REW"
  mkdir -p "$HOME/.config/gtk-4.0" "$HOME/.config/gtk-3.0" "$HOME/.var/app/$REW/data"
  printf '/* tokyonight gtk4 */\n' >"$HOME/.config/gtk-4.0/gtk.css"
  printf '/* tokyonight gtk3 */\n' >"$HOME/.config/gtk-3.0/gtk.css"
  printf '{"theme": "tokyonight"}\n' >"$HOME/.var/app/$REW/data/prefs.json"
  # gnome-shell.css is absent before: it must be absent again afterwards
  mkdir -p "$BATS_TEST_TMPDIR/before"
  cp -p "$HOME/.config/gtk-4.0/gtk.css" "$BATS_TEST_TMPDIR/before/gtk4"
  cp -p "$HOME/.config/gtk-3.0/gtk.css" "$BATS_TEST_TMPDIR/before/gtk3"
  cp -p "$HOME/.var/app/$REW/data/prefs.json" "$BATS_TEST_TMPDIR/before/prefs"
  dconf write /org/gnome/desktop/interface/accent-color "'blue'"
  dconf write /org/gnome/Ptyxis/default-profile-uuid "'demoprofile'"
  dconf write /org/gnome/Ptyxis/Profiles/demoprofile/palette "'Tokyo Night'"
  # user-theme/name is UNSET before
  cat >"$STUB_STATE/flatpak-run" <<'REWAITA'
#!/usr/bin/env bash
printf 'rewaita\t%s\n' "$*" >>"$STUB_LOG"
printf '/* storm gtk4 */\n' >"$HOME/.config/gtk-4.0/gtk.css"
printf '/* storm gtk3 */\n' >"$HOME/.config/gtk-3.0/gtk.css"
mkdir -p "$HOME/.local/share/themes/rewaita/gnome-shell"
printf 'storm shell\n' >"$HOME/.local/share/themes/rewaita/gnome-shell/gnome-shell.css"
printf '{"theme": "tokyonight-storm"}\n' >"$HOME/.var/app/io.github.swordpuffin.rewaita/data/prefs.json"
dconf write /org/gnome/desktop/interface/accent-color "'purple'"
if [[ -z ${KEEP_NAME:-} ]]; then dconf write /org/gnome/shell/extensions/user-theme/name "'rewaita'"; fi
REWAITA
  chmod +x "$STUB_STATE/flatpak-run"
  : >"$STUB_LOG"
}

_assert_storm_restored() {
  cmp "$BATS_TEST_TMPDIR/before/gtk4" "$HOME/.config/gtk-4.0/gtk.css"
  cmp "$BATS_TEST_TMPDIR/before/gtk3" "$HOME/.config/gtk-3.0/gtk.css"
  cmp "$BATS_TEST_TMPDIR/before/prefs" "$HOME/.var/app/$REW/data/prefs.json"
  [[ ! -e $HOME/.local/share/themes/rewaita/gnome-shell/gnome-shell.css ]]
  [[ $(dconf read /org/gnome/desktop/interface/accent-color) == "'blue'" ]]
  [[ $(dconf read /org/gnome/Ptyxis/Profiles/demoprofile/palette) == "'Tokyo Night'" ]]
  [[ -z $(dconf read /org/gnome/shell/extensions/user-theme/name) ]]
  assert_stub_called dconf 'reset /org/gnome/shell/extensions/user-theme/name$'
}

@test "--auto --with-storm: storm shots after the tokyonight ones, theme restored exactly" {
  _storm_env
  run "$TNU_ROOT/tools/screenshots.sh" --auto --with-storm --delay 0 desktop
  assert_success
  assert_output --partial "sha256 verified"
  _assert_order '^capture\tdesktop-tokyonight\.png$' \
    '^rewaita\tio\.github\.swordpuffin\.rewaita --theme --theme=tokyonight-storm$' \
    "^dconf\twrite /org/gnome/Ptyxis/Profiles/demoprofile/palette \\\\'Tokyo\\\\ Night\\\\ Storm\\\\'$" \
    '^capture\tdesktop-storm\.png$' \
    '^dconf\treset /org/gnome/shell/extensions/user-theme/name$'
  [[ -s $SHOT_DIR/desktop-tokyonight.png && -s $SHOT_DIR/desktop-storm.png ]]
  _assert_storm_restored
}

@test "--auto --with-storm: a failed storm capture still restores the theme (EXIT trap)" {
  _storm_env
  export FAIL_ON=desktop-storm.png
  run "$TNU_ROOT/tools/screenshots.sh" --auto --with-storm --delay 0 desktop
  assert_failure 1
  assert_output --partial "no screenshot produced for desktop"
  assert_output --partial "sha256 verified"
  _assert_storm_restored
}

@test "--with-storm: a restore mismatch is reported loudly and fails" {
  _storm_env
  _live_source
  parse_args --auto --with-storm --delay 0 desktop
  storm_switch
  dconf() { if [[ $1 == write || $1 == reset ]]; then return 0; fi; command dconf "$@"; }
  run storm_restore
  assert_failure
  assert_output --partial "!!! RESTORE MISMATCH: dconf /org/gnome/desktop/interface/accent-color"
  assert_output --partial "THEME NOT FULLY RESTORED"
  # backups live in the state dir (not /tmp) and the path is printed
  [[ $LS_DIR == "$XDG_STATE_HOME/tokyonight-ubuntu/live-state."* && -d $LS_DIR ]]
  assert_output --partial "kept in $LS_DIR"
}

@test "--with-storm: the shell theme is reloaded (name '' then back) when the name did not change" {
  _storm_env
  dconf write /org/gnome/shell/extensions/user-theme/name "'rewaita'"
  : >"$STUB_LOG"
  export KEEP_NAME=1
  run "$TNU_ROOT/tools/screenshots.sh" --auto --with-storm --delay 0 desktop
  assert_success
  assert_output --partial "reloaded the GNOME Shell theme"
  _assert_order '^capture\tdesktop-storm\.png$' \
    "^dconf\twrite /org/gnome/shell/extensions/user-theme/name \\\\'\\\\'$" \
    "^dconf\twrite /org/gnome/shell/extensions/user-theme/name \\\\'rewaita\\\\'$"
  [[ $(dconf read /org/gnome/shell/extensions/user-theme/name) == "'rewaita'" ]]
  [[ $(dconf read /org/gnome/desktop/interface/accent-color) == "'blue'" ]]
  cmp "$BATS_TEST_TMPDIR/before/gtk4" "$HOME/.config/gtk-4.0/gtk.css"
}

@test "--with-storm: Ctrl+C (INT) during a storm capture still restores the theme" {
  _storm_env
  export INT_ON=desktop-storm.png
  run "$TNU_ROOT/tools/screenshots.sh" --auto --with-storm --delay 0 desktop
  assert_failure 130
  assert_output --partial "sha256 verified"
  _assert_storm_restored
}

@test "--with-storm: an INT arriving during the restore does not cut it short" {
  _storm_env
  rm -f "$BATS_TEST_TMPDIR/bin/dconf"
  cat >"$BATS_TEST_TMPDIR/bin/dconf" <<WRAP
#!/usr/bin/env bash
if [[ \$1 == reset && -e $BATS_TEST_TMPDIR/int-once ]]; then
  rm -f "$BATS_TEST_TMPDIR/int-once"
  kill -INT "\$PPID"
fi
exec "$TNU_ROOT/tests/stubs/bin/dconf" "\$@"
WRAP
  chmod +x "$BATS_TEST_TMPDIR/bin/dconf"
  : >"$BATS_TEST_TMPDIR/int-once"
  run "$TNU_ROOT/tools/screenshots.sh" --auto --with-storm --delay 0 desktop
  [[ ! -e $BATS_TEST_TMPDIR/int-once ]]
  assert_success # the INT was ignored during the restore, the run finished
  assert_output --partial "sha256 verified"
  _assert_storm_restored
}

@test "capture failure keeps the existing target file (temp file, no leftovers)" {
  _live_env
  mkdir -p "$SHOT_DIR"
  printf 'old bytes' >"$SHOT_DIR/desktop-tokyonight.png"
  export FAIL_ON=desktop-tokyonight.png
  run "$TNU_ROOT/tools/screenshots.sh" --auto --delay 0 desktop
  assert_failure 1
  [[ $(cat "$SHOT_DIR/desktop-tokyonight.png") == "old bytes" ]]
  run find "$SHOT_DIR" -name '.desktop.*'
  assert_output ""
  unset FAIL_ON
  run "$TNU_ROOT/tools/screenshots.sh" --auto --delay 0 desktop
  assert_success
  [[ $(head -c 4 "$SHOT_DIR/desktop-tokyonight.png" | tail -c 3) == PNG ]]
}
