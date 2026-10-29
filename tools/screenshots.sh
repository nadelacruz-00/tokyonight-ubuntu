#!/usr/bin/env bash
# Maintainer tool: capture the README screenshots in the CURRENT desktop session.
#
#   tools/screenshots.sh [--variant tokyonight|storm] [--delay N] SHOT...
#   tools/screenshots.sh --auto [--with-storm] [--delay N] [SHOT...]
#
# SHOT is one of: desktop overview quick-settings ptyxis osk. Output goes to
# docs/screenshots/<shot>[-<variant>].png (desktop and ptyxis carry the
# variant, overview and osk do not). Capture order of preference:
#   1. org.gnome.Shell.Screenshot over D-Bus (no cursor, no flash)
#   2. Mutter ScreenCast, one frame (tools/screencast_still.py)
#   3. manual: the tool says what to capture; the newest PNG from
#      ~/Pictures/Screenshots (Print Screen) is picked up, or you put the file
#      at the printed path.
# Run from a terminal, the terminal itself would be in the picture and pressing
# Enter there would close menus. With --delay N (seconds) the tool never reads
# from the terminal: it prints what to do, counts down on stderr (minimise this
# terminal, open the menu) and then captures. The demo terminal of the ptyxis
# shot is closed automatically afterwards.
# Every capture is the WHOLE monitor: before you start, close or minimise other
# windows and clear notifications (window titles, Wi-Fi names and user names
# can leak). The tool reminds you before each shot.
# Afterwards each PNG is shrunk to <= 1.5 MB with ffmpeg when needed, stripped
# of metadata chunks (helpers/png_strip.py) and scanned with
# `helpers/pii_scan.py --ocr`. Review every image yourself before committing.
#
# --auto: no prompts at all. One countdown (default 10 s) to minimise the
# terminal, a switch to the empty last workspace (dynamic workspaces; back to
# workspace 1 at the end), then every SHOT (default: all) in a fixed order:
# desktop; overview (org.gnome.Shell OverviewActive); quick-settings (its keybinding, injected via
# Mutter RemoteDesktop by tools/inject_keys.py, closed again with Escape);
# ptyxis (demo window, closed by typing `exit`); osk (gjsosk's indicator
# keyboard-visible, back to its previous state). Each step checks that its state
# is undone before the next one starts.
# --with-storm (only with --auto) then switches the session to Tokyo Night
# Storm with Rewaita, captures desktop-storm and ptyxis-storm, and restores the
# theme files and dconf keys byte-for-byte (tools/live_state.sh, sha256
# verified). Everything a step opens or changes is undone by an EXIT/INT/TERM
# trap, so a failure midway leaves nothing open.
# SHOT_DIR (environment) overrides the output directory.
#
# The ptyxis shot opens a sanitised terminal: empty environment, a temporary
# HOME, USER=demo, HOSTNAME=ubuntu, a throwaway git repo, so the prompt shows
# no real names or paths.
set -Eeuo pipefail
shopt -s inherit_errexit
IFS=$'\n\t'

ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
SHOT_DIR="${SHOT_DIR:-$ROOT/docs/screenshots}"
MAX_BYTES=1572864
VARIANTS=(tokyonight storm)
ALL_SHOTS=(desktop overview quick-settings ptyxis osk)

REWAITA=io.github.swordpuffin.rewaita
OSK_SCHEMADIR="${SYS_ROOT:-}/usr/share/gnome-shell/extensions/gjsosk@vishram1123.com/schemas"
OSK_SCHEMA=org.gnome.shell.extensions.gjsosk.indicator

VARIANT=tokyonight
DELAY=0
AUTO=0
WITH_STORM=0
SHOTS=()
OUTS=()
TMP_DEMO=""
OMP_DIR=""
# what is currently open / changed (undone by cleanup)
OVERVIEW_OPEN=0
QS_OPEN=0
OSK_SET=0
OSK_PREV=""
STORM_ON=0

# shellcheck source=tools/live_state.sh
source "$ROOT/tools/live_state.sh"

die() {
  printf 'screenshots: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: tools/screenshots.sh [--variant tokyonight|storm] [--delay N] SHOT...
       tools/screenshots.sh --auto [--with-storm] [--delay N] [SHOT...]

--delay N     seconds to wait (counting down) before each capture instead of
              waiting for Enter; lets you minimise this terminal first.
--auto        no prompts: one countdown (--delay, default 10), then every SHOT
              (default all) opens, is captured and is closed by itself.
--with-storm  with --auto: afterwards switch to Tokyo Night Storm (Rewaita),
              capture desktop and ptyxis again, restore the theme exactly.
SHOT: desktop | overview | quick-settings | ptyxis | osk
SHOT_DIR (environment) overrides the output directory.
Writes docs/screenshots/<shot>[-<variant>].png (the variant suffix applies to
desktop and ptyxis only). Run it in the session you want pictured, with the
theme already installed (./install.sh --variant <variant>).
USAGE
}

in_list() {
  local needle=$1 x
  shift
  for x in "$@"; do
    if [[ $x == "$needle" ]]; then return 0; fi
  done
  return 1
}

# parse_args ARGS...: sets VARIANT DELAY AUTO WITH_STORM SHOTS; returns 2 on a
# usage error (message on stderr), 3 for --help.
parse_args() {
  local delay_set=0 variant_set=0
  VARIANT=tokyonight
  DELAY=0
  AUTO=0
  WITH_STORM=0
  SHOTS=()
  while (($#)); do
    case $1 in
      --variant)
        if (($# < 2)); then
          echo "--variant needs a value" >&2
          return 2
        fi
        if ! in_list "$2" "${VARIANTS[@]}"; then
          echo "unknown variant: $2 (tokyonight or storm)" >&2
          return 2
        fi
        VARIANT=$2
        variant_set=1
        shift 2
        ;;
      --delay)
        if (($# < 2)) || [[ ! $2 =~ ^[0-9]+$ ]]; then
          echo "--delay needs a whole number of seconds" >&2
          return 2
        fi
        DELAY=$((10#$2))
        delay_set=1
        shift 2
        ;;
      --auto)
        AUTO=1
        shift
        ;;
      --with-storm)
        WITH_STORM=1
        shift
        ;;
      -h | --help) return 3 ;;
      -*)
        echo "unknown option: $1" >&2
        return 2
        ;;
      *)
        if ! in_list "$1" "${ALL_SHOTS[@]}"; then
          echo "unknown shot: $1 (one of: ${ALL_SHOTS[*]})" >&2
          return 2
        fi
        SHOTS+=("$1")
        shift
        ;;
    esac
  done
  if ((WITH_STORM && ! AUTO)); then
    echo "--with-storm needs --auto" >&2
    return 2
  fi
  if ((AUTO)); then
    if ((variant_set)); then
      echo "--auto captures the installed theme as tokyonight (add --with-storm for storm); drop --variant" >&2
      return 2
    fi
    if ((! delay_set)); then DELAY=10; fi
    if ((${#SHOTS[@]} == 0)); then SHOTS=("${ALL_SHOTS[@]}"); fi
    if ((WITH_STORM)) && ! in_list desktop "${SHOTS[@]}" && ! in_list ptyxis "${SHOTS[@]}"; then
      echo "--with-storm only re-takes desktop and ptyxis; include at least one" >&2
      return 2
    fi
  fi
  if ((${#SHOTS[@]} == 0)); then
    echo "no SHOT given (one of: ${ALL_SHOTS[*]})" >&2
    return 2
  fi
}

# out_path SHOT VARIANT: the output file for a shot.
out_path() {
  case $1 in
    desktop | ptyxis) printf '%s/%s-%s.png\n' "$SHOT_DIR" "$1" "$2" ;;
    *) printf '%s/%s.png\n' "$SHOT_DIR" "$1" ;;
  esac
}

file_size() {
  stat -c %s -- "$1"
}

# ask PROMPT: wait for Enter on the terminal (never used by --auto or --delay).
ask() {
  read -r -p "$1" _ || true
}

# pause SECONDS: let the shell settle after opening something.
pause() {
  sleep "$1"
}

# countdown N MSG: MSG, then a visible countdown on stderr.
countdown() {
  local n=$1 msg=$2
  printf '%s\n' "$msg" >&2
  while ((n > 0)); do
    printf '\r  capturing in %2d s ' "$n" >&2
    sleep 1
    n=$((n - 1))
  done
  printf '\r  capturing now        \n' >&2
}

# wait_for_setup INSTRUCTION: with --delay a countdown, else wait for Enter.
wait_for_setup() {
  if ((DELAY > 0)); then
    countdown "$DELAY" "Minimise this terminal, then: $1"
  else
    ask "$1, then press Enter... "
  fi
}

# --- capture -----------------------------------------------------------------

capture_shell() {
  local out
  out=$(gdbus call --session --dest org.gnome.Shell.Screenshot \
    --object-path /org/gnome/Shell/Screenshot \
    --method org.gnome.Shell.Screenshot.Screenshot false false "$1" 2>&1) || {
    echo "Shell.Screenshot refused: ${out:0:160}" >&2
    return 1
  }
  [[ $out == "(true,"* && -s $1 ]]
}

capture_screencast() {
  python3 -I "$ROOT/tools/screencast_still.py" "$1" && [[ -s $1 ]]
}

# capture_manual TMP SHOT DEST: the user presses Print Screen (picked up from
# ~/Pictures/Screenshots) or saves the image as DEST; the result goes to TMP.
capture_manual() {
  local tmp=$1 shot=$2 dest=$3 stamp newest
  if ((AUTO)); then
    echo "automatic capture failed for $shot (Shell.Screenshot and ScreenCast); --auto never falls back to manual" >&2
    return 1
  fi
  stamp=$(mktemp)
  printf '\nAutomatic capture is not available. Manual capture for "%s":\n' "$shot"
  printf '  press Print Screen (saves to ~/Pictures/Screenshots)\n'
  if ((DELAY > 0)); then
    countdown "$DELAY" "  press Print Screen within the countdown (or save the image as $dest)"
  else
    printf '  and then Enter here, or save the image yourself as: %s\n' "$dest"
    ask 'Press Enter when done... '
  fi
  # -newer the stamp made before the wait: only images saved meanwhile
  if [[ -s $dest && $dest -nt $stamp ]]; then
    cp -- "$dest" "$tmp"
  else
    newest=$(find "$HOME/Pictures/Screenshots" -maxdepth 1 -name '*.png' -newer "$stamp" 2>/dev/null | LC_ALL=C sort | tail -n 1)
    if [[ -n $newest ]]; then cp -- "$newest" "$tmp"; fi
  fi
  rm -f -- "$stamp"
  [[ -s $tmp ]] || echo "no new screenshot found; expected it at $dest" >&2
  [[ -s $tmp ]]
}

# check_test_hook: loudly announce TNU_SHOT_CAPTURE and never let it write into
# (or delete from) the repo's real docs/screenshots (exit 2). Runs before any
# file is touched.
HOOK_CHECKED=0
check_test_hook() {
  ((HOOK_CHECKED)) && return 0
  echo "TEST HOOK ACTIVE: TNU_SHOT_CAPTURE=$TNU_SHOT_CAPTURE" >&2
  mkdir -p "$SHOT_DIR"
  if [[ $(cd "$SHOT_DIR" && pwd -P) == "$(cd "$ROOT/docs/screenshots" 2>/dev/null && pwd -P)" ]]; then
    echo "screenshots: refusing to use TNU_SHOT_CAPTURE with the real docs/screenshots (set SHOT_DIR)" >&2
    exit 2
  fi
  HOOK_CHECKED=1
}

# capture_into TMP SHOT DEST: write a new screenshot to TMP.
capture_into() {
  local tmp=$1 shot=$2 dest=$3
  if [[ -n ${TNU_SHOT_CAPTURE:-} ]]; then
    # test hook: an executable that writes the PNG to $1 ($2: target name)
    "$TNU_SHOT_CAPTURE" "$tmp" "${dest##*/}" && [[ -s $tmp ]]
    return
  fi
  rm -f -- "$tmp"
  if command -v gdbus >/dev/null 2>&1 && capture_shell "$tmp"; then return 0; fi
  rm -f -- "$tmp"
  if command -v gst-launch-1.0 >/dev/null 2>&1 && capture_screencast "$tmp"; then return 0; fi
  rm -f -- "$tmp"
  capture_manual "$tmp" "$shot" "$dest"
}

# capture DEST SHOT: capture into a temp file next to DEST; DEST is replaced
# only by a non-empty new image, so a failed capture keeps the old file.
# CAP_TMP: the temp file of the capture in progress (removed by cleanup).
CAP_TMP=""
capture() {
  local dest=$1 shot=$2
  if [[ -n ${TNU_SHOT_CAPTURE:-} ]]; then check_test_hook; fi
  mkdir -p "$SHOT_DIR"
  CAP_TMP=$(mktemp --suffix=.png "$SHOT_DIR/.$shot.XXXXXX")
  if capture_into "$CAP_TMP" "$shot" "$dest" && [[ -s $CAP_TMP ]]; then
    chmod 0644 -- "$CAP_TMP" # mktemp creates 0600
    mv -f -- "$CAP_TMP" "$dest"
    CAP_TMP=""
    return 0
  fi
  rm -f -- "$CAP_TMP"
  CAP_TMP=""
  return 1
}

# --- post-processing -----------------------------------------------------------

shrink() {
  local f=$1 tries=0 tmp
  while (($(file_size "$f") > MAX_BYTES)); do
    if ! command -v ffmpeg >/dev/null 2>&1; then
      echo "warning: $f is over 1.5 MB and ffmpeg is missing; shrink it by hand" >&2
      return 0
    fi
    if ((++tries > 4)); then
      echo "warning: $f is still over 1.5 MB after shrinking" >&2
      return 0
    fi
    tmp="$f.tmp.png"
    ffmpeg -v error -y -i "$f" -vf 'scale=trunc(iw*0.75/2)*2:-2:flags=lanczos' -map_metadata -1 -fflags +bitexact "$tmp"
    mv -- "$tmp" "$f"
  done
}

postprocess() {
  local f=$1
  shrink "$f"
  python3 -I "$ROOT/helpers/png_strip.py" "$f"
  chmod 0644 -- "$f" # png_strip rewrites it with the umask's mode
}

# --- shot setup -----------------------------------------------------------------

# demo_pids: pids of the demo shell, found by its unique ZDOTDIR.
demo_pids() {
  [[ -n $TMP_DEMO ]] || return 0
  local e
  for e in /proc/[0-9]*/environ; do
    if tr '\0' '\n' 2>/dev/null <"$e" | grep -qxF "ZDOTDIR=$TMP_DEMO/home"; then
      e=${e%/environ}
      printf '%s\n' "${e#/proc/}"
    fi
  done
}

# demo_signal SIG PID...: signal the demo shell.
demo_signal() {
  local sig=$1
  shift
  kill "-$sig" "$@" 2>/dev/null || true
}

# demo_wait_gone N: wait up to N tenths of a second for the demo shell to end.
demo_wait_gone() {
  local i
  for ((i = 0; i < $1; i++)); do
    if [[ -z $(demo_pids) ]]; then return 0; fi
    pause 0.1
  done
  [[ -z $(demo_pids) ]]
}

# demo_cleanup [type]: close the demo terminal (also when a capture failed).
# With "type" (--auto, right after the capture, while the demo window is the
# focused window on the empty workspace) `exit` is typed into it; otherwise,
# and as a fallback, its shell gets TERM (the zshrc exits 0 on it, so Ptyxis
# closes the window), then KILL. Afterwards the Ptyxis dconf keys the window
# changed (window-size, ...) are put back and the temp HOME is removed.
DEMO_LEFT=0
demo_cleanup() {
  local how=${1:-} ran=0
  local -a pids
  if [[ -n $TMP_DEMO ]]; then
    mapfile -t pids < <(demo_pids)
    if ((${#pids[@]})); then
      ran=1
      if [[ $how == type ]]; then
        inject_keys e x i t Return || true
        demo_wait_gone 30 || true
        mapfile -t pids < <(demo_pids)
      fi
    fi
    if ((${#pids[@]})); then
      demo_signal TERM "${pids[@]}"
      if ! demo_wait_gone 20; then
        mapfile -t pids < <(demo_pids)
        if ((${#pids[@]})); then demo_signal KILL "${pids[@]}"; fi
        demo_wait_gone 10 || true
      fi
    fi
    if [[ -n $(demo_pids) ]]; then
      echo "warning: the demo shell is still running" >&2
      DEMO_LEFT=1
    fi
    if ((ran)); then pause 1; fi # Ptyxis saves the window state as it closes
  fi
  ptyxis_restore || true
  if [[ -n $TMP_DEMO && -d $TMP_DEMO ]]; then rm -rf -- "$TMP_DEMO"; fi
  TMP_DEMO=""
}

# Ptyxis writes /org/gnome/Ptyxis/ keys (window-size, ...) for the demo
# window: snapshot the whole dir before it opens, put back what changed.
PTYXIS_DIR=/org/gnome/Ptyxis/
PTYXIS_DUMP=""
PTYXIS_SNAP=0
# DCONF_DIFF DIR BEFORE AFTER: "write<TAB>key<TAB>value" / "reset<TAB>key"
# lines that turn the AFTER dump back into BEFORE.
DCONF_DIFF='
import sys
def keys(base, text):
    out, sec = {}, None
    for line in text.splitlines():
        if line.startswith("[") and line.endswith("]"):
            sec = line[1:-1]
        elif "=" in line and sec is not None:
            k, v = line.split("=", 1)
            out[base + ("" if sec == "/" else sec + "/") + k] = v
    return out
base = sys.argv[1]
before, after = keys(base, sys.argv[2]), keys(base, sys.argv[3])
for k in sorted(set(before) | set(after)):
    if after.get(k) != before.get(k):
        if k in before:
            print("write\t%s\t%s" % (k, before[k]))
        else:
            print("reset\t%s" % k)
'

ptyxis_snapshot() {
  PTYXIS_DUMP=$(dconf dump "$PTYXIS_DIR") || die "cannot read $PTYXIS_DIR"
  PTYXIS_SNAP=1
}

ptyxis_restore() {
  ((PTYXIS_SNAP)) || return 0
  local now op key val rc=0
  now=$(dconf dump "$PTYXIS_DIR") || return 1
  if [[ $now != "$PTYXIS_DUMP" ]]; then
    while IFS=$'\t' read -r op key val; do
      case $op in
        write) dconf write "$key" "$val" || rc=1 ;;
        reset) dconf reset "$key" || rc=1 ;;
      esac
      echo "restored dconf $key" >&2
    done < <(python3 -I -c "$DCONF_DIFF" "$PTYXIS_DIR" "$PTYXIS_DUMP" "$now")
    if [[ $(dconf dump "$PTYXIS_DIR") != "$PTYXIS_DUMP" ]]; then
      echo "!!! RESTORE MISMATCH: $PTYXIS_DIR differs from before the demo window" >&2
      rc=1
    fi
  fi
  if ((rc == 0)); then PTYXIS_SNAP=0; fi
  return "$rc"
}

# demo_prepare: a temp HOME with a throwaway git repo and a zshrc that starts
# oh-my-posh with the repo's prompt config. Everything the prompt can print
# (path, git branch, language versions) comes from here; the config has no
# user / host / session segment.
demo_prepare() {
  local home omp
  TMP_DEMO=$(mktemp -d)
  home=$TMP_DEMO/home
  mkdir -p "$home/projects/demo"
  omp=$(command -v oh-my-posh || true)
  if [[ -z $omp && -x $HOME/.local/bin/oh-my-posh ]]; then omp=$HOME/.local/bin/oh-my-posh; fi
  [[ -n $omp ]] || die "oh-my-posh not found (run ./install.sh --only prompt first)"
  OMP_DIR=${omp%/*}
  cp -- "$ROOT/assets/omp/tokyonight_storm.omp.json" "$home/omp.json"
  # No long listing (`ls -l` prints the real owner: env -i keeps the uid) and
  # nothing else that prints user or host names. TERM/HUP end the shell with
  # status 0, so Ptyxis closes the window instead of showing an exited tab.
  cat >"$home/.zshrc" <<RC
TRAPTERM() { exit 0 }
TRAPHUP() { exit 0 }
eval "\$($omp init zsh --config "$home/omp.json")"
cd "$home/projects/demo"
ls --color=always -C
RC
  (
    cd "$home/projects/demo"
    export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
    HOME=$home git init -q -b main .
    printf '# demo\n' >README.md
    printf '#!/bin/sh\necho hello\n' >run.sh
    chmod +x run.sh
    mkdir src docs
    HOME=$home git -c user.name=demo -c user.email=demo@example.com add -A
    HOME=$home git -c user.name=demo -c user.email=demo@example.com commit -q -m init
  )
}

# demo_open: the sanitised Ptyxis demo window (closed by demo_cleanup).
demo_open() {
  command -v ptyxis >/dev/null 2>&1 || die "ptyxis is not installed"
  command -v zsh >/dev/null 2>&1 || die "zsh is not installed"
  demo_prepare
  ptyxis_snapshot
  local home=$TMP_DEMO/home demo_path=/usr/local/bin:/usr/bin:/bin
  demo_path=$demo_path:${OMP_DIR:?}
  ptyxis --new-window -- env -i "HOME=$home" "ZDOTDIR=$home" USER=demo LOGNAME=demo \
    HOSTNAME=ubuntu "PATH=$demo_path" TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 zsh -d -i &
  pause 4
}

shot_ptyxis() {
  demo_open
  if ((DELAY > 0)); then
    countdown "$DELAY" "The demo terminal is open. Minimise this terminal and leave the demo window in front."
  fi
}

# overview_set true|false: org.gnome.Shell's OverviewActive property (applied
# asynchronously, within about a second).
overview_set() {
  busctl --user set-property org.gnome.Shell /org/gnome/Shell org.gnome.Shell OverviewActive b "$1" >/dev/null 2>&1
}

overview_open() {
  overview_set true || return 1
  OVERVIEW_OPEN=1
}

# overview_closed: OverviewActive reads false within ~2 s (unreadable: warn, 0).
overview_closed() {
  local i v
  for ((i = 0; i < 20; i++)); do
    if ! v=$(busctl --user get-property org.gnome.Shell /org/gnome/Shell org.gnome.Shell OverviewActive 2>/dev/null); then
      echo "warning: cannot read OverviewActive; assuming the overview is closed" >&2
      return 0
    fi
    if [[ $v == "b false" ]]; then return 0; fi
    pause 0.1
  done
  return 1
}

overview_close() {
  if ((OVERVIEW_OPEN)); then
    OVERVIEW_OPEN=0
    overview_set false || echo "warning: could not close the overview (OverviewActive false failed)" >&2
  fi
  return 0
}

shot_overview() {
  if ((DELAY > 0)); then
    countdown "$DELAY" "Minimise this terminal; the overview opens by itself."
  fi
  if overview_open; then
    pause 1
  elif ((DELAY == 0)); then
    ask 'Open the Activities overview (Super key), then press Enter... '
  else
    die "could not open the overview (setting org.gnome.Shell OverviewActive failed); run without --delay and open it yourself"
  fi
}

# inject_keys ACCEL: press a key combination in the session (Mutter
# RemoteDesktop). TNU_INJECT_KEYS (test only) replaces the injector.
inject_keys() {
  if [[ -n ${TNU_INJECT_KEYS:-} ]]; then
    echo "TEST HOOK ACTIVE: TNU_INJECT_KEYS=$TNU_INJECT_KEYS" >&2
    "$TNU_INJECT_KEYS" "$@"
  else
    python3 -I "$ROOT/tools/inject_keys.py" "$@"
  fi
}

# binding SCHEMA KEY DEFAULT: the first accelerator of a keybinding setting.
binding() {
  local v a=""
  if v=$(gsettings get "$1" "$2" 2>/dev/null); then
    a=$(sed -n "s/^\['\([^']*\)'.*/\1/p" <<<"$v")
  fi
  printf '%s\n' "${a:-$3}"
}

# ws_enter / ws_leave: --auto works on the (always empty) last workspace of
# dynamic workspaces, so none of the operator's windows are in the pictures;
# back to workspace 1 at the end (and in cleanup).
WS_MOVED=0
ws_enter() {
  [[ $(gsettings get org.gnome.mutter dynamic-workspaces 2>/dev/null) == true ]] ||
    die "--auto needs dynamic workspaces (org.gnome.mutter dynamic-workspaces true) for an empty workspace"
  inject_keys "$(binding org.gnome.desktop.wm.keybindings switch-to-workspace-last '<Super>End')" ||
    die "could not switch to an empty workspace (key injection failed)"
  WS_MOVED=1
  pause 0.7
}

ws_leave() {
  if ((WS_MOVED)); then
    WS_MOVED=0
    inject_keys "$(binding org.gnome.desktop.wm.keybindings switch-to-workspace-1 '<Super>Home')" ||
      echo "warning: could not switch back to workspace 1" >&2
  fi
  return 0
}

qs_open() {
  inject_keys "$(binding org.gnome.shell.keybindings toggle-quick-settings '<Super>s')" || return 1
  QS_OPEN=1
}

qs_close() {
  if ((QS_OPEN)); then
    QS_OPEN=0
    inject_keys Escape || echo "warning: could not close Quick Settings (press Escape)" >&2
  fi
  return 0
}

# gjsosk: `indicator opened` is a one-shot toggle command (the extension
# resets it to false at once, so writing false back closes nothing);
# `indicator keyboard-visible` is the state: an outside write that differs from
# the keyboard's state opens or closes it, and the extension writes it back
# itself (false when it refuses to open).
osk_get() {
  gsettings --schemadir "$OSK_SCHEMADIR" get "$OSK_SCHEMA" keyboard-visible
}

osk_set() {
  gsettings --schemadir "$OSK_SCHEMADIR" set "$OSK_SCHEMA" keyboard-visible "$1"
}

# osk_is VALUE: keyboard-visible reads VALUE within ~2 s.
osk_is() {
  local i
  for ((i = 0; i < 20; i++)); do
    if [[ $(osk_get 2>/dev/null) == "$1" ]]; then return 0; fi
    pause 0.1
  done
  return 1
}

# osk_open: remember keyboard-visible and show the keyboard. Returns 2 when
# the gjsosk schema is not installed (shot skipped), 1 on failure.
osk_open() {
  [[ -d $OSK_SCHEMADIR ]] || return 2
  OSK_PREV=$(osk_get) || return 1
  if [[ $OSK_PREV == true ]]; then return 0; fi # already shown: leave it so
  OSK_SET=1
  osk_set true || return 1
  osk_is true || return 1
}

# osk_close: back to the remembered state (hides it if it was hidden).
osk_close() {
  if ((OSK_SET)); then
    OSK_SET=0
    osk_set "$OSK_PREV" || echo "warning: could not restore $OSK_SCHEMA keyboard-visible=$OSK_PREV" >&2
  fi
  return 0
}

shot_quick_settings() {
  echo 'Note: Quick Settings can show the Wi-Fi network name and your user name.'
  echo 'They will be reviewed (and the image redone or dropped) before commit.'
  wait_for_setup 'open the Quick Settings menu in the top bar'
}

shot_osk() {
  wait_for_setup 'focus a text field in another window and open the on-screen keyboard'
}

capture_shot() {
  local shot=$1 dest
  echo "Close or minimise other windows and clear notifications: the whole monitor is captured."
  dest=$(out_path "$shot" "$VARIANT")
  case $shot in
    ptyxis) shot_ptyxis ;;
    overview) shot_overview ;;
    quick-settings) shot_quick_settings ;;
    osk) shot_osk ;;
    desktop)
      if ((DELAY > 0)); then wait_for_setup 'the desktop is captured (minimise any other windows too)'; fi
      ;;
  esac
  capture "$dest" "$shot" || die "no screenshot produced for $shot"
  overview_close
  postprocess "$dest"
  printf 'saved %s (%s bytes)\n' "${dest#"$ROOT"/}" "$(file_size "$dest")"
  if [[ $shot == ptyxis ]]; then
    if ((DELAY == 0)); then
      ask 'Close the demo terminal window, then press Enter... '
    fi
    demo_cleanup
  fi
}

# --- --auto ---------------------------------------------------------------------

# auto_shot SHOT: open, capture, close; no prompts. Appends the file to OUTS.
# assert_nothing_open: every earlier shot undid its state (abort otherwise).
assert_nothing_open() {
  if ((OVERVIEW_OPEN || QS_OPEN || OSK_SET || DEMO_LEFT)) || [[ -n $TMP_DEMO ]]; then
    die "an earlier shot left something open; stopping"
  fi
  overview_closed || die "the overview is still open; stopping"
}

# assert_undone SHOT: SHOT's own state is back to how it was before it.
assert_undone() {
  case $1 in
    overview) overview_closed || die "the overview did not close; stopping" ;;
    ptyxis) ((! DEMO_LEFT)) || die "the demo terminal did not close; stopping" ;;
    osk) osk_is "$OSK_PREV" || die "the on-screen keyboard is not back to keyboard-visible=$OSK_PREV; stopping" ;;
  esac
}

auto_shot() {
  local shot=$1 dest rc=0
  dest=$(out_path "$shot" "$VARIANT")
  assert_nothing_open
  echo "auto: $shot -> ${dest#"$ROOT"/}" >&2
  case $shot in
    overview)
      overview_open || die "could not open the overview (setting org.gnome.Shell OverviewActive failed)"
      pause 1
      ;;
    quick-settings)
      qs_open || die "could not open Quick Settings (key injection failed)"
      pause 1
      ;;
    ptyxis) demo_open ;;
    osk)
      osk_open || rc=$?
      if ((rc == 2)); then
        echo "warning: gjsosk schema not found ($OSK_SCHEMADIR); osk shot skipped" >&2
        return 0
      fi
      ((rc == 0)) || die "could not open the on-screen keyboard ($OSK_SCHEMA keyboard-visible; refused?)"
      pause 1.5
      ;;
  esac
  capture "$dest" "$shot" || die "no screenshot produced for $shot"
  case $shot in
    overview) overview_close ;;
    quick-settings) qs_close ;;
    ptyxis) demo_cleanup type ;;
    osk) osk_close ;;
  esac
  assert_undone "$shot"
  postprocess "$dest"
  printf 'saved %s (%s bytes)\n' "${dest#"$ROOT"/}" "$(file_size "$dest")"
  OUTS+=("$dest")
}

# The live files and keys Rewaita (and the Ptyxis palette) change; the same
# set tools/regen-assets.sh restores.
storm_files() {
  printf '%s\n' "$HOME/.config/gtk-4.0/gtk.css" "$HOME/.config/gtk-3.0/gtk.css" \
    "$HOME/.local/share/themes/rewaita/gnome-shell/gnome-shell.css" \
    "$HOME/.var/app/$REWAITA/data/prefs.json"
}

# storm_switch: snapshot, then switch the session to Tokyo Night Storm.
storm_switch() {
  local uuid key
  command -v flatpak >/dev/null 2>&1 || die "--with-storm needs flatpak"
  flatpak info "$REWAITA" >/dev/null 2>&1 || die "--with-storm needs the Rewaita flatpak ($REWAITA)"
  uuid=$(dconf read /org/gnome/Ptyxis/default-profile-uuid) || die "cannot read the Ptyxis default profile"
  uuid=${uuid//\'/}
  [[ $uuid =~ ^[A-Za-z0-9_-]+$ ]] || die "no Ptyxis default profile (run ./install.sh first)"
  key=/org/gnome/Ptyxis/Profiles/$uuid/palette
  local -a files
  mapfile -t files < <(storm_files)
  live_state_save "${files[@]}" -- /org/gnome/shell/extensions/user-theme/name \
    /org/gnome/desktop/interface/accent-color "$key"
  STORM_ON=1
  echo "switching to Tokyo Night Storm (restored afterwards)" >&2
  timeout 60 flatpak run "$REWAITA" --theme --theme=tokyonight-storm >&2 || die "Rewaita could not switch to tokyonight-storm"
  dconf write "$key" "'Tokyo Night Storm'"
  pause 2
}

# storm_restore: put the snapshot back, verify it (sha256 + dconf values) and
# make GNOME Shell reload its theme. INT/TERM/HUP are ignored meanwhile;
# STORM_ON is cleared only on success, so the EXIT trap retries otherwise
# (restore is idempotent).
storm_restore() {
  ((STORM_ON)) || return 0
  local rc=0
  trap '' INT TERM HUP
  live_state_restore || rc=1
  live_state_verify || rc=1
  if ((rc == 0)); then live_state_reload_shell || rc=1; fi
  if ((rc == 0)); then
    STORM_ON=0
    live_state_drop
    echo "restored the Tokyo Night theme files and settings (sha256 verified)" >&2
  else
    echo "!!! THEME NOT FULLY RESTORED: backups kept in $LS_DIR" >&2
  fi
  if ((! IN_CLEANUP)); then trap 'exit 130' INT TERM HUP; fi
  return "$rc"
}

run_auto() {
  local shot
  echo "Close other windows and clear notifications: the whole monitor is captured."
  if ((DELAY > 0)); then
    countdown "$DELAY" "minimise this terminal; capturing all shots in $DELAY s (on a new empty workspace)"
  fi
  ws_enter
  for shot in "${ALL_SHOTS[@]}"; do
    if in_list "$shot" "${SHOTS[@]}"; then auto_shot "$shot"; fi
  done
  if ((WITH_STORM)); then
    storm_switch
    VARIANT=storm
    for shot in desktop ptyxis; do
      if in_list "$shot" "${SHOTS[@]}"; then auto_shot "$shot"; fi
    done
    VARIANT=tokyonight
    storm_restore || die "the Tokyo Night theme was not fully restored (see above)"
  fi
  ws_leave
}

# cleanup: undo whatever is still open or changed (EXIT trap). Signals are
# ignored from here on so a second Ctrl+C cannot cut the restore short.
IN_CLEANUP=0
cleanup() {
  trap '' INT TERM HUP
  IN_CLEANUP=1
  if [[ -n $CAP_TMP ]]; then rm -f -- "$CAP_TMP" || true; fi
  overview_close || true
  qs_close || true
  osk_close || true
  demo_cleanup || true
  ws_leave || true
  if ! storm_restore; then exit 1; fi
}

main() {
  local rc=0 shot
  parse_args "$@" || rc=$?
  if ((rc == 3)); then
    usage
    return 0
  elif ((rc != 0)); then
    usage >&2
    return 2
  fi
  if [[ -n ${TNU_SHOT_CAPTURE:-} ]]; then check_test_hook; fi
  trap cleanup EXIT
  trap 'exit 130' INT TERM HUP
  OUTS=()
  if ((AUTO)); then
    run_auto
  else
    for shot in "${SHOTS[@]}"; do
      capture_shot "$shot"
      OUTS+=("$(out_path "$shot" "$VARIANT")")
    done
  fi
  ((${#OUTS[@]})) || die "no screenshot taken"
  command -v tesseract >/dev/null 2>&1 || echo "warning: tesseract not installed; the PII scan skips OCR (read every image yourself)" >&2
  python3 -I "$ROOT/helpers/pii_scan.py" --ocr "${OUTS[@]}"
  echo "pii scan clean. Now review each image by eye before committing."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
