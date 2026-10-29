#!/usr/bin/env bash
# Maintainer tool: capture the README screenshots in the CURRENT desktop session.
#
#   tools/screenshots.sh [--variant tokyonight|storm] [--delay N] SHOT...
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
# The ptyxis shot opens a sanitised terminal: empty environment, a temporary
# HOME, USER=demo, HOSTNAME=ubuntu, a throwaway git repo, so the prompt shows
# no real names or paths.
set -Eeuo pipefail
shopt -s inherit_errexit
IFS=$'\n\t'

ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
SHOT_DIR="$ROOT/docs/screenshots"
MAX_BYTES=1572864
VARIANTS=(tokyonight storm)
ALL_SHOTS=(desktop overview quick-settings ptyxis osk)

VARIANT=tokyonight
DELAY=0
SHOTS=()
TMP_DEMO=""
OMP_DIR=""

die() {
  printf 'screenshots: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: tools/screenshots.sh [--variant tokyonight|storm] [--delay N] SHOT...

--delay N   seconds to wait (counting down) before each capture instead of
            waiting for Enter; lets you minimise this terminal first.
SHOT: desktop | overview | quick-settings | ptyxis | osk
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

# parse_args ARGS...: sets VARIANT and SHOTS; returns 2 on a usage error
# (message on stderr), 3 for --help.
parse_args() {
  VARIANT=tokyonight
  DELAY=0
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
        shift 2
        ;;
      --delay)
        if (($# < 2)) || [[ ! $2 =~ ^[0-9]+$ ]]; then
          echo "--delay needs a whole number of seconds" >&2
          return 2
        fi
        DELAY=$((10#$2))
        shift 2
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
    read -r -p "$1, then press Enter... " _ || true
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

capture_manual() {
  local dest=$1 shot=$2 stamp newest
  stamp=$(mktemp)
  printf '\nAutomatic capture is not available. Manual capture for "%s":\n' "$shot"
  printf '  press Print Screen (saves to ~/Pictures/Screenshots)\n'
  if ((DELAY > 0)); then
    countdown "$DELAY" "  press Print Screen within the countdown (or save the image as $dest)"
  else
    printf '  and then Enter here, or save the image yourself as: %s\n' "$dest"
    read -r -p 'Press Enter when done... ' _ || true
  fi
  if [[ ! -s $dest ]]; then
    newest=$(find "$HOME/Pictures/Screenshots" -maxdepth 1 -name '*.png' -newer "$stamp" 2>/dev/null | LC_ALL=C sort | tail -n 1)
    # -newer the stamp made before the wait: only shots taken meanwhile
    if [[ -n $newest ]]; then cp -- "$newest" "$dest"; fi
  fi
  rm -f -- "$stamp"
  [[ -s $dest ]] || echo "no screenshot found; expected it at $dest" >&2
  [[ -s $dest ]]
}

# check_test_hook: loudly announce TNU_SHOT_CAPTURE and never let it write into
# the repo's real docs/screenshots (exit 2).
check_test_hook() {
  echo "TEST HOOK ACTIVE: TNU_SHOT_CAPTURE=$TNU_SHOT_CAPTURE" >&2
  mkdir -p "$SHOT_DIR"
  if [[ $(cd "$SHOT_DIR" && pwd -P) == "$(cd "$ROOT/docs/screenshots" 2>/dev/null && pwd -P)" ]]; then
    echo "screenshots: refusing to use TNU_SHOT_CAPTURE with the real docs/screenshots (set SHOT_DIR)" >&2
    exit 2
  fi
}

capture() {
  local dest=$1 shot=$2
  mkdir -p "$SHOT_DIR"
  rm -f -- "$dest"
  if [[ -n ${TNU_SHOT_CAPTURE:-} ]]; then
    check_test_hook
    # test hook: an executable that writes the PNG to $1
    "$TNU_SHOT_CAPTURE" "$dest" && [[ -s $dest ]]
    return
  fi
  if command -v gdbus >/dev/null 2>&1 && capture_shell "$dest"; then return 0; fi
  rm -f -- "$dest"
  if command -v gst-launch-1.0 >/dev/null 2>&1 && capture_screencast "$dest"; then return 0; fi
  rm -f -- "$dest"
  capture_manual "$dest" "$shot"
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
}

# --- shot setup -----------------------------------------------------------------

demo_cleanup() {
  # Close the demo terminal (also when a capture failed): end its shell, found by
  # its unique ZDOTDIR, and Ptyxis closes the window. Then drop the temp HOME.
  if [[ -n $TMP_DEMO ]]; then
    local e p
    for e in /proc/[0-9]*/environ; do
      if tr '\0' '\n' <"$e" 2>/dev/null | grep -qxF "ZDOTDIR=$TMP_DEMO/home"; then
        p=${e%/environ}
        kill "${p#/proc/}" 2>/dev/null || true
      fi
    done
  fi
  if [[ -n $TMP_DEMO && -d $TMP_DEMO ]]; then rm -rf -- "$TMP_DEMO"; fi
  TMP_DEMO=""
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
  cat >"$home/.zshrc" <<RC
eval "\$($omp init zsh --config "$home/omp.json")"
cd "$home/projects/demo"
ls --color=always -lh --time-style=+ . | sed 1d
RC
  (
    cd "$home/projects/demo"
    export HOME=$home GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
    git init -q -b main .
    printf '# demo\n' >README.md
    printf '#!/bin/sh\necho hello\n' >run.sh
    chmod +x run.sh
    mkdir src docs
    git -c user.name=demo -c user.email=demo@example.com add -A
    git -c user.name=demo -c user.email=demo@example.com commit -q -m init
  )
}

shot_ptyxis() {
  command -v ptyxis >/dev/null 2>&1 || die "ptyxis is not installed"
  command -v zsh >/dev/null 2>&1 || die "zsh is not installed"
  demo_prepare
  local home=$TMP_DEMO/home demo_path=/usr/local/bin:/usr/bin:/bin
  demo_path=$demo_path:${OMP_DIR:?}
  ptyxis --new-window -- env -i "HOME=$home" "ZDOTDIR=$home" USER=demo LOGNAME=demo \
    HOSTNAME=ubuntu "PATH=$demo_path" TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 zsh -d -i &
  sleep 4
  if ((DELAY > 0)); then
    countdown "$DELAY" "The demo terminal is open. Minimise this terminal and leave the demo window in front."
  fi
}

shot_overview() {
  if ((DELAY > 0)); then
    countdown "$DELAY" "Minimise this terminal; the overview opens by itself."
  fi
  if busctl --user call org.gnome.Shell /org/gnome/Shell org.gnome.Shell FocusSearch >/dev/null 2>&1; then
    sleep 2
  elif ((DELAY == 0)); then
    read -r -p 'Open the Activities overview (Super key), then press Enter... ' _ || true
  else
    die "could not open the overview (FocusSearch failed); open it yourself with --delay 0 or run without --delay"
  fi
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
  postprocess "$dest"
  printf 'saved %s (%s bytes)\n' "${dest#"$ROOT"/}" "$(file_size "$dest")"
  if [[ $shot == ptyxis ]]; then
    if ((DELAY == 0)); then
      read -r -p 'Close the demo terminal window, then press Enter... ' _ || true
    fi
    demo_cleanup
  fi
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
  trap demo_cleanup EXIT
  local -a outs=()
  for shot in "${SHOTS[@]}"; do
    capture_shot "$shot"
    outs+=("$(out_path "$shot" "$VARIANT")")
  done
  command -v tesseract >/dev/null 2>&1 || echo "warning: tesseract not installed; the PII scan skips OCR (read every image yourself)" >&2
  python3 -I "$ROOT/helpers/pii_scan.py" --ocr "${outs[@]}"
  echo "pii scan clean. Now review each image by eye before committing."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
