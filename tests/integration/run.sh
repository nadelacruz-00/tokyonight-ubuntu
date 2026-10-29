#!/usr/bin/env bash
# Integration run: the real install.sh against real dconf/gsettings, isolated
# from the desktop session. HOME (with a space) and every XDG dir live in a
# fresh `mktemp -d`; the run happens inside `dbus-run-session` (a private bus,
# so dconf writes go to the temp HOME), started from a clean environment with
# DBUS_SESSION_BUS_ADDRESS unset.
#
#   tests/integration/run.sh [--system] [--real-network]
#
#   --system        also the root parts (sudo); container only: refused unless
#                   TNU_IN_CONTAINER=1. Run as a non-root user with NOPASSWD sudo.
#   --real-network  also fonts and prompt, downloading for real; the last
#                   uninstall uses --purge. With TNU_REAL_REWAITA=1 Rewaita is
#                   installed from Flathub too (needs flatpak).
#
# Steps: seed a .zshrc line, a gtk.css and two dconf keys; snapshot HOME and
# `dconf dump /`; install; read the settings back with gsettings (catches wrong
# GVariant types); a second install must change nothing; --variant storm;
# --uninstall; HOME and `dconf dump /` must equal the snapshots. Not compared:
# our own state and download cache, the dconf database file (its content is
# compared via `dconf dump`) and, with --real-network, the fontconfig cache and
# flatpak's own installation dir. Prints INTEGRATION PASS on success.
#
# Env: TNU_IT_CACHE=DIR seeds the download cache from DIR and copies new
# downloads back (CI cache); TNU_IT_KEEP=1 keeps the temp dir.
# Exit: 0 pass, 1 a check failed, 2 refused (usage, unsafe environment).
set -Eeuo pipefail
shopt -s inherit_errexit
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
SELF=$ROOT/tests/integration/run.sh
SYSTEM=0 NET=0
ARGS=("$@")

refuse() {
  printf 'run.sh: refused: %s\n' "$1" >&2
  exit 2
}
fail() {
  local IFS=' '
  printf 'INTEGRATION FAIL: %s\n' "$*" >&2
  exit 1
}
say() {
  local IFS=' '
  printf '==> %s\n' "$*" >&2
}
skip() {
  local IFS=' '
  printf 'skip: %s\n' "$*" >&2
}

while (($#)); do
  case $1 in
    --system) SYSTEM=1 ;;
    --real-network) NET=1 ;;
    -h | --help)
      sed -n '2,/^set -E/{/^set -E/d;s/^# \{0,1\}//;p}' "$SELF"
      exit 0
      ;;
    *) refuse "unknown argument: $1 (use --system and/or --real-network)" ;;
  esac
  shift
done
# in_container: a container runtime marker is present (docker, podman, systemd's view).
in_container() {
  [[ -e /.dockerenv || -e /run/.containerenv ]] && return 0
  command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -q -c
}
if ((SYSTEM)); then
  if [[ ${TNU_IN_CONTAINER:-} != 1 ]]; then
    refuse "--system changes the real system: it only runs in a container (TNU_IN_CONTAINER=1)"
  fi
  in_container || refuse "--system: TNU_IN_CONTAINER=1 is set, but this is not a container"
fi
if [[ ${TNU_REAL_REWAITA:-0} == 1 ]] && ((! NET)); then refuse "TNU_REAL_REWAITA=1 needs --real-network"; fi
if [[ $EUID == 0 ]]; then refuse "run as a non-root user (install.sh refuses root)"; fi

# _resolve PATH: physical absolute path of an existing directory.
_resolve() {
  (cd -- "$1" 2>/dev/null && pwd -P)
}

# check_inside ROOT NAME PATH: PATH resolves strictly inside ROOT, else refuse.
check_inside() {
  local r
  r=$(_resolve "$3") || refuse "$2 ($3) does not exist"
  if [[ $r != "$1"/* ]]; then refuse "$2 ($r) is not inside the temp dir $1"; fi
}

# check_home ROOT HOME REAL_HOME PW_HOME: HOME is inside ROOT and is neither real home.
check_home() {
  local h
  check_inside "$1" HOME "$2"
  h=$(_resolve "$2")
  if [[ -n $3 && $h == "$3" ]] || [[ -n $4 && $h == "$4" ]]; then
    refuse "HOME ($h) is the real home directory"
  fi
}

# ---------------------------------------------------------------- outer stage
outer() {
  local c real_home="" pw_home="" tmp token rc=0 bus_sha=""
  for c in dconf dbus-run-session gsettings; do
    command -v "$c" >/dev/null 2>&1 || refuse "needs $c (real, not a stub)"
  done
  if [[ -n ${HOME:-} ]]; then real_home=$(_resolve "$HOME" || true); fi
  pw_home=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)
  if [[ -n $pw_home ]]; then pw_home=$(_resolve "$pw_home" || printf '%s' "$pw_home"); fi
  # Never talk to the desktop session's bus, from here on or in any child. Only
  # its hash goes to the inner stage, which refuses to run on that same bus.
  if [[ -n ${DBUS_SESSION_BUS_ADDRESS:-} ]]; then
    bus_sha=$(printf '%s' "$DBUS_SESSION_BUS_ADDRESS" | sha256sum | cut -d' ' -f1)
  fi
  unset DBUS_SESSION_BUS_ADDRESS

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/tnu-integration.XXXXXXXX") || refuse "mktemp -d failed"
  tmp=$(_resolve "$tmp") || refuse "cannot resolve $tmp"
  if [[ ${TNU_IT_KEEP:-0} != 1 ]]; then
    # shellcheck disable=SC2064 # expand now (quoted with %q): tmp is local
    trap "rm -rf -- $(printf '%q' "$tmp")" EXIT
  fi
  if [[ -n $(find "$tmp" -mindepth 1 -print -quit) ]]; then refuse "$tmp is not a fresh directory"; fi
  if [[ -n $real_home && ($tmp == "$real_home" || $real_home == "$tmp"/*) ]] ||
    [[ -n $pw_home && ($tmp == "$pw_home" || $pw_home == "$tmp"/*) ]]; then
    refuse "temp dir $tmp contains the real home"
  fi
  token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  printf '%s\n' "$token" >"$tmp/.tnu-integration"
  mkdir -p "$tmp/home dir" "$tmp/tmp" "$tmp/logs"
  mkdir -m 0700 "$tmp/runtime"
  check_home "$tmp" "$tmp/home dir" "$real_home" "$pw_home"
  say "temp dir: $tmp"

  # A clean environment: nothing from the session (bus, DCONF_PROFILE,
  # GSETTINGS_BACKEND, ...) or the real HOME reaches the run.
  env -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    HOME="$tmp/home dir" \
    XDG_CONFIG_HOME="$tmp/home dir/.config" \
    XDG_DATA_HOME="$tmp/home dir/.local/share" \
    XDG_STATE_HOME="$tmp/home dir/.local/state" \
    XDG_CACHE_HOME="$tmp/home dir/.cache" \
    XDG_RUNTIME_DIR="$tmp/runtime" \
    XDG_DATA_DIRS=/usr/local/share:/usr/share \
    XDG_CURRENT_DESKTOP=ubuntu:GNOME \
    TMPDIR="$tmp/tmp" \
    LANG=C.UTF-8 \
    USER="${USER:-$(id -un)}" LOGNAME="${LOGNAME:-$(id -un)}" \
    PYTHONDONTWRITEBYTECODE=1 NO_COLOR=1 \
    TNU_IT_STAGE=inner TNU_IT_ROOT="$tmp" TNU_IT_TOKEN="$token" \
    TNU_IT_REAL_HOME="$real_home" TNU_IT_PW_HOME="$pw_home" TNU_IT_REAL_BUS_SHA="$bus_sha" \
    TNU_IN_CONTAINER="${TNU_IN_CONTAINER:-}" TNU_REAL_REWAITA="${TNU_REAL_REWAITA:-0}" \
    TNU_IT_CACHE="${TNU_IT_CACHE:-}" \
    dbus-run-session -- bash "$SELF" "${ARGS[@]}" || rc=$?
  return "$rc"
}

# ---------------------------------------------------------------- inner stage

# snapshot DIR EXCLUDE...: one line per entry ("sha mode path", "symlink path ->
# target", "dir mode path/"), skipping the EXCLUDE subtrees. The line format
# must match tree_snapshot in tests/test_helper.bash (this copy adds EXCLUDE;
# that file needs bats, so it cannot be sourced here).
snapshot() {
  local dir=$1 e
  local -a prune=()
  shift
  for e in "$@"; do prune+=(-path "./${e#"$dir"/}" -prune -o); done
  (
    cd -- "$dir" || exit 1
    find . -mindepth 1 "${prune[@]}" -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' f; do
      if [[ -L $f ]]; then
        printf 'symlink  %s -> %s\n' "${f#./}" "$(readlink -- "$f")"
      elif [[ -d $f ]]; then
        printf 'dir  %s  %s/\n' "$(stat -c %a -- "$f")" "${f#./}"
      else
        printf '%s  %s  %s\n' "$(sha256sum <"$f" | cut -d' ' -f1)" "$(stat -c %a -- "$f")" "${f#./}"
      fi
    done
  )
}

# run_install NAME ARGS...: ./install.sh -y ARGS (+ --system), output in logs/NAME.log;
# the module summary goes to logs/NAME.summary. Fails on a non-zero exit.
run_install() {
  local name=$1 rc=0 IFS=' '
  local -a sys=()
  shift
  if ((SYSTEM)); then sys=(--system); fi
  say "install.sh -y ${sys[*]} $*"
  "$ROOT/install.sh" -y "${sys[@]}" "$@" >"$LOGS/$name.log" 2>&1 || rc=$?
  sed 's/^/    /' "$LOGS/$name.log" >&2
  awk '/^module +result/ { f = 1; next } /^log: / { f = 0 } f && NF' "$LOGS/$name.log" >"$LOGS/$name.summary"
  if ((rc != 0)); then fail "install.sh $* exited $rc"; fi
  if [[ " $* " == *" --uninstall "* ]]; then return 0; fi # no module summary
  # An unparsed summary would make the FAILED / CHANGED checks pass vacuously.
  [[ -s $LOGS/$name.summary ]] || fail "no module summary in the output of install.sh $*"
  grep -Eq '^gtk +(OK|CHANGED)' "$LOGS/$name.summary" || fail "no gtk result in the summary of install.sh $*"
  if grep -q 'FAILED' "$LOGS/$name.summary"; then fail "a module failed in: install.sh $*"; fi
}

# ran NAME: module NAME was applied (not SKIPPED) in the first install.
ran() {
  awk -v m="$1" '$1 == m && $2 != "SKIPPED" { found = 1 } END { exit !found }' "$LOGS/first.summary"
}

# _gs_has SCHEMA [SCHEMADIR]: SCHEMA (relocatable or not) is installed.
_gs_has() {
  local all
  local -a gs=(gsettings)
  if [[ -n ${2:-} ]]; then
    [[ -d $2 ]] || return 1
    gs+=(--schemadir "$2")
  fi
  # Collected first: `grep -q` closing the pipe early would fail it under pipefail.
  all=$({ "${gs[@]}" list-schemas && "${gs[@]}" list-relocatable-schemas; } 2>/dev/null) || return 1
  grep -qxF -- "$1" <<<"$all"
}

# gs_expect SCHEMA[:PATH] KEY WANT [SCHEMADIR]: `gsettings get` prints WANT and
# so does `dconf read` of the key's path. gsettings reads a value of the wrong
# GVariant type back as the schema default, so the dconf read proves our own
# write is there (a default equal to WANT cannot pass for it). The path is
# PATH for a relocatable schema, else the schema id with dots as slashes
# (true for every schema checked here; a wrong path reads empty and fails).
gs_expect() {
  local schema=$1 key=$2 want=$3 dir=${4:-} got path raw
  local -a gs=(gsettings)
  if [[ -n $dir ]]; then gs+=(--schemadir "$dir"); fi
  if [[ $schema == *:* ]]; then path=${schema#*:}; else path=/${schema//.//}/; fi
  raw=$(dconf read "$path$key") || fail "dconf read $path$key failed"
  if [[ $raw != "$want" ]]; then fail "dconf read $path$key: got '$raw', want $want"; fi
  got=$("${gs[@]}" get "$schema" "$key") || fail "gsettings get $schema $key failed"
  if [[ $got != "$want" ]]; then fail "gsettings get $schema $key: got $got, want $want"; fi
  printf '    ok %s %s = %s\n' "$schema" "$key" "$got" >&2
}

# check_settings VARIANT: read every module's settings back through gsettings.
check_settings() {
  local variant=$1 uri u palette=$'\'Tokyo Night\'' osk_dir
  local ifc=org.gnome.desktop.interface
  local ut=user-theme@gnome-shell-extensions.gcampax.github.com
  local osk=gjsosk-theme-sync@nadelacruz-00.github.io
  if [[ $variant == storm ]]; then palette=$'\'Tokyo Night Storm\''; fi
  ran gtk || fail "the gtk module did not run"
  _gs_has $ifc || fail "schema $ifc is not installed (package gsettings-desktop-schemas)"
  gs_expect $ifc color-scheme "'prefer-dark'"
  gs_expect $ifc accent-color "'purple'"
  gs_expect $ifc gtk-theme "'Yaru-purple-dark'"
  gs_expect $ifc icon-theme "'Yaru-purple-dark'"
  cmp -s -- "$HOME/.config/gtk-4.0/gtk.css" "$ROOT/assets/rewaita/$variant/gtk4.css" ||
    fail "gtk-4.0/gtk.css is not the $variant CSS"

  if ! ran shell-theme; then
    skip "shell-theme module did not run (no user-theme extension)"
  else
    if _gs_has org.gnome.shell.extensions.user-theme; then
      gs_expect org.gnome.shell.extensions.user-theme name "'rewaita'"
    else
      skip "schema org.gnome.shell.extensions.user-theme not installed"
    fi
    if _gs_has org.gnome.shell; then
      if ran osk; then
        gs_expect org.gnome.shell enabled-extensions "['foreign@example.com', '$ut', '$osk']"
      else
        gs_expect org.gnome.shell enabled-extensions "['foreign@example.com', '$ut']"
      fi
    else
      skip "schema org.gnome.shell not installed"
    fi
  fi

  if ! ran wallpaper; then
    skip "wallpaper module did not run (wallpaper file missing)"
  else
    uri="'file:///usr/share/backgrounds/osselo-Ask_a_friend.jpg'"
    gs_expect org.gnome.desktop.background picture-uri "$uri"
    gs_expect org.gnome.desktop.background picture-uri-dark "$uri"
    gs_expect org.gnome.desktop.background picture-options "'zoom'"
    gs_expect org.gnome.desktop.screensaver picture-uri "$uri"
  fi

  if ! ran ptyxis; then
    skip "ptyxis module did not run (ptyxis not installed)"
  elif ! _gs_has org.gnome.Ptyxis || ! _gs_has org.gnome.Ptyxis.Profile; then
    skip "Ptyxis schemas not installed"
  else
    u=$(gsettings get org.gnome.Ptyxis default-profile-uuid)
    u=${u//\'/}
    [[ $u =~ ^[0-9a-f]{32}$ ]] || fail "Ptyxis default-profile-uuid is not a profile uuid: $u"
    gs_expect org.gnome.Ptyxis profile-uuids "['$u']"
    gs_expect "org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/$u/" palette "$palette"
    gs_expect "org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/$u/" label "'Tokyo Night'"
    gs_expect org.gnome.Ptyxis font-name "'JetBrainsMono Nerd Font 10'"
    gs_expect org.gnome.Ptyxis use-system-font false
    gs_expect org.gnome.Ptyxis interface-style "'dark'"
  fi

  osk_dir=/usr/share/gnome-shell/extensions/gjsosk@vishram1123.com/schemas
  if ! ran osk; then
    skip "osk module did not run (GJS OSK not installed)"
  elif ! _gs_has org.gnome.shell.extensions.gjsosk "$osk_dir"; then
    skip "schema org.gnome.shell.extensions.gjsosk not found in $osk_dir"
  else
    local k v
    for k in landscape-width-percent=48 landscape-height-percent=28 portrait-width-percent=100 \
      portrait-height-percent=35 outer-spacing-px=6 border-spacing-px=2 font-size-px=16 \
      font-bold=true round-key-corners=false show-icons=false system-accent-col=false; do
      v=${k#*=}
      gs_expect org.gnome.shell.extensions.gjsosk "${k%%=*}" "$v" "$osk_dir"
    done
  fi

  if ((NET)); then
    compgen -G "$HOME/.local/share/fonts/JetBrainsMonoNerd/*.ttf" >/dev/null ||
      fail "no JetBrainsMono Nerd Font files installed"
    "$HOME/.local/bin/oh-my-posh" version >/dev/null || fail "oh-my-posh does not run"
    grep -qxF '# >>> tokyonight-ubuntu >>>' "$HOME/.zshrc" || fail ".zshrc has no tokyonight-ubuntu block"
    grep -qxF 'export TNU_SEEDED=1' "$HOME/.zshrc" || fail ".zshrc lost its own line"
    printf '    ok fonts, oh-my-posh and the .zshrc block\n' >&2
  fi
  if [[ $TNU_REAL_REWAITA == 1 ]]; then
    flatpak info --user io.github.swordpuffin.rewaita >/dev/null || fail "Rewaita flatpak not installed"
    grep -q 'Tokyonight' "$HOME/.var/app/io.github.swordpuffin.rewaita/data/prefs.json" ||
      fail "Rewaita prefs.json has no Tokyonight theme"
    printf '    ok Rewaita flatpak and prefs.json\n' >&2
  fi
}

# gdm_alt: the gdm-theme.gresource alternative's current Value (empty if none).
gdm_alt() {
  update-alternatives --query gdm-theme.gresource 2>/dev/null | sed -n 's/^Value: //p' || true
}

inner() {
  local tok="" rc=0 snap_home snap_sys="" alt_before="" db
  local -a skip_mods skips excl
  local tnu_dest=/usr/share/gnome-shell/theme/tokyonight-ubuntu/gnome-shell-theme.gresource

  # Re-check everything the outer stage set up: refuse on any doubt.
  local v
  for v in TNU_IT_ROOT TNU_IT_TOKEN TNU_IT_REAL_HOME TNU_IT_PW_HOME TNU_IT_REAL_BUS_SHA HOME XDG_CONFIG_HOME \
    XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR TMPDIR TNU_REAL_REWAITA; do
    declare -g "$v=${!v:-}"
  done
  [[ $TNU_IT_ROOT == /?* && -f $TNU_IT_ROOT/.tnu-integration ]] || refuse "no integration temp dir"
  IFS= read -r tok <"$TNU_IT_ROOT/.tnu-integration" || true
  [[ -n $tok && $tok == "$TNU_IT_TOKEN" ]] || refuse "temp dir token mismatch"
  [[ $(_resolve "$TNU_IT_ROOT") == "$TNU_IT_ROOT" ]] || refuse "temp dir moved"
  check_home "$TNU_IT_ROOT" "$HOME" "$TNU_IT_REAL_HOME" "$TNU_IT_PW_HOME"
  [[ $HOME == *' '* ]] || refuse "HOME has no space in it"
  for v in XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR TMPDIR; do
    # Lexically inside first (so mkdir never creates anything outside), then resolved.
    [[ ${!v} == "$TNU_IT_ROOT"/?* ]] || refuse "$v (${!v:-unset}) is not inside the temp dir $TNU_IT_ROOT"
    mkdir -p -- "${!v}"
    check_inside "$TNU_IT_ROOT" "$v" "${!v}"
  done
  [[ -n ${DBUS_SESSION_BUS_ADDRESS:-} ]] || refuse "not inside dbus-run-session"
  if [[ -n $TNU_IT_REAL_BUS_SHA &&
    $(printf '%s' "$DBUS_SESSION_BUS_ADDRESS" | sha256sum | cut -d' ' -f1) == "$TNU_IT_REAL_BUS_SHA" ]]; then
    refuse "this is the desktop session's bus, not a private one"
  fi
  LOGS=$TNU_IT_ROOT/logs

  # Isolation canary, before any real key is written: a throwaway key holding
  # the token must create the temp HOME's dconf db and be found in it.
  db=$XDG_CONFIG_HOME/dconf/user
  [[ ! -e $db ]] || refuse "$db exists before the first write: not a fresh dconf"
  dconf write /org/tokyonight-ubuntu/it-canary "'$TNU_IT_TOKEN'"
  [[ -s $db ]] || refuse "dconf did not write to the temp HOME: not isolated"
  grep -qaF -- "$TNU_IT_TOKEN" "$db" || refuse "the canary is not in $db: not isolated"
  [[ $(dconf read /org/tokyonight-ubuntu/it-canary) == "'$TNU_IT_TOKEN'" ]] ||
    refuse "dconf read-back differs: not the private dconf"
  dconf reset /org/tokyonight-ubuntu/it-canary
  [[ -z $(dconf read /org/tokyonight-ubuntu/it-canary) ]] || refuse "cannot reset the canary"

  # Seed a user who already has some settings.
  dconf write /org/gnome/desktop/interface/gtk-theme "'Adwaita'"
  dconf write /org/gnome/shell/enabled-extensions "['foreign@example.com']"
  printf 'export TNU_SEEDED=1\n' >"$HOME/.zshrc"
  mkdir -p "$HOME/.config/gtk-4.0"
  printf '/* my own tweaks */\nwindow { margin: 1px; }\n' >"$HOME/.config/gtk-4.0/gtk.css"
  if [[ -n ${TNU_IT_CACHE:-} && -d $TNU_IT_CACHE ]]; then
    mkdir -p "$XDG_CACHE_HOME/tokyonight-ubuntu"
    find "$TNU_IT_CACHE" -maxdepth 1 -type f ! -name '.*' -exec cp -t "$XDG_CACHE_HOME/tokyonight-ubuntu" -- {} +
  fi

  skips=(rewaita fonts prompt)
  excl=("$XDG_STATE_HOME/tokyonight-ubuntu" "$XDG_CACHE_HOME/tokyonight-ubuntu" "$XDG_CONFIG_HOME/dconf")
  if ((NET)); then
    skips=(rewaita)
    excl+=("$XDG_CACHE_HOME/fontconfig")
  fi
  if [[ $TNU_REAL_REWAITA == 1 ]]; then
    skips=()
    excl+=("$XDG_DATA_HOME/flatpak")
  fi
  # --system must exercise wallpaper and gdm: their inputs are required packages.
  if ((SYSTEM)); then
    [[ -f /usr/share/backgrounds/osselo-Ask_a_friend.jpg ]] ||
      fail "--system: the wallpaper is missing (install ubuntu-wallpapers-resolute)"
    [[ -f /usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource ||
      -f /usr/share/gnome-shell/theme/erhai/gnome-shell-theme.gresource ]] ||
      fail "--system: no base GDM theme (install yaru-theme-gnome-shell)"
  fi
  skip_mods=()
  if ((${#skips[@]})); then
    local IFS=,
    skip_mods=(--skip "${skips[*]}")
    IFS=$'\n\t'
  fi

  snap_home=$LOGS/home.before
  snapshot "$HOME" "${excl[@]}" >"$snap_home"
  dconf dump / >"$LOGS/dconf.before"
  if ((SYSTEM)); then
    alt_before=$(gdm_alt)
    snap_sys=$LOGS/system.before
    snapshot /usr/share/gnome-shell >"$snap_sys"
  fi

  run_install first "${skip_mods[@]}"
  if ((SYSTEM)); then
    ran wallpaper || fail "--system: the wallpaper module did not run"
    ran gdm || fail "--system: the gdm module did not run"
  fi
  say "checking settings (tokyonight)"
  check_settings tokyonight
  if ((SYSTEM)); then
    [[ $(gdm_alt) == "$tnu_dest" ]] || fail "gdm-theme.gresource Value is $(gdm_alt), want $tnu_dest"
    printf '    ok gdm-theme.gresource -> %s\n' "$tnu_dest" >&2
  fi

  run_install second "${skip_mods[@]}"
  if grep -q CHANGED "$LOGS/second.summary"; then fail "the second install changed something"; fi
  printf '    ok second run changed nothing\n' >&2

  run_install storm --variant storm "${skip_mods[@]}"
  say "checking settings (storm)"
  check_settings storm

  if ((NET)); then run_install uninstall --uninstall --purge; else run_install uninstall --uninstall; fi

  say "comparing HOME and dconf with the snapshots"
  snapshot "$HOME" "${excl[@]}" >"$LOGS/home.after"
  dconf dump / >"$LOGS/dconf.after"
  diff -u "$snap_home" "$LOGS/home.after" >&2 || fail "HOME differs after --uninstall"
  diff -u "$LOGS/dconf.before" "$LOGS/dconf.after" >&2 || fail "dconf differs after --uninstall"
  if ((SYSTEM)); then
    [[ $(gdm_alt) == "$alt_before" ]] ||
      fail "gdm-theme.gresource Value is $(gdm_alt) after --uninstall, want ${alt_before:-none}"
    snapshot /usr/share/gnome-shell >"$LOGS/system.after"
    diff -u "$snap_sys" "$LOGS/system.after" >&2 || fail "/usr/share/gnome-shell differs after --uninstall"
    printf '    ok gdm-theme.gresource restored to %s\n' "${alt_before:-none}" >&2
  fi

  if [[ -n ${TNU_IT_CACHE:-} && -d $TNU_IT_CACHE && -d $XDG_CACHE_HOME/tokyonight-ubuntu ]]; then
    find "$XDG_CACHE_HOME/tokyonight-ubuntu" -maxdepth 1 -type f ! -name '.*' \
      -exec cp -n -t "$TNU_IT_CACHE" -- {} + || true
  fi
  printf 'INTEGRATION PASS\n'
}

if [[ ${TNU_IT_STAGE:-} == inner ]]; then
  inner
else
  outer
fi
