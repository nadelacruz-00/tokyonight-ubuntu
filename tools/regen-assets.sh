#!/usr/bin/env bash
# Maintainer script: regenerate the vendored Rewaita CSS and the checksum list.
# Needs a desktop with the Rewaita flatpak (io.github.swordpuffin.rewaita).
# Rewaita rewrites the live theme files, so everything it can touch is backed
# up first and restored byte-for-byte on exit (success, failure or signal).
set -Eeuo pipefail
shopt -s inherit_errexit
IFS=$'\n\t'

ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
APP=io.github.swordpuffin.rewaita
GTK4="$HOME/.config/gtk-4.0/gtk.css"
GTK3="$HOME/.config/gtk-3.0/gtk.css"
SHELLCSS="$HOME/.local/share/themes/rewaita/gnome-shell/gnome-shell.css"
PREFS="$HOME/.var/app/$APP/data/prefs.json"
FILES=("$GTK4" "$GTK3" "$SHELLCSS" "$PREFS")
DCONF_KEYS=(/org/gnome/shell/extensions/user-theme/name /org/gnome/desktop/interface/accent-color)

# shellcheck source=tools/live_state.sh
source "$ROOT/tools/live_state.sh"

restore() {
  trap '' INT TERM HUP # a second Ctrl+C must not abort the restore
  live_state_restore || true
  if live_state_verify && live_state_reload_shell; then
    live_state_drop
  else
    echo "!!! live theme files NOT fully restored; backups kept in $LS_DIR" >&2
  fi
}
trap restore EXIT
trap 'exit 130' INT TERM HUP

command -v flatpak >/dev/null || {
  echo "flatpak not found" >&2
  exit 1
}
flatpak info "$APP" >/dev/null 2>&1 || {
  echo "$APP is not installed" >&2
  exit 1
}

if command -v dconf >/dev/null; then
  live_state_save "${FILES[@]}" -- "${DCONF_KEYS[@]}"
else
  live_state_save "${FILES[@]}" --
fi

gen() {
  local theme=$1 dir=$2
  timeout 60 flatpak run "$APP" --theme --theme="$theme" >&2
  mkdir -p "$ROOT/assets/rewaita/$dir"
  cp -- "$GTK4" "$ROOT/assets/rewaita/$dir/gtk4.css"
  cp -- "$GTK3" "$ROOT/assets/rewaita/$dir/gtk3.css"
  cp -- "$SHELLCSS" "$ROOT/assets/rewaita/$dir/gnome-shell.css"
}

gen tokyonight-storm storm
gen tokyonight tokyonight

# Refresh the vendored lines of checksums.sha256; keep the pinned-download lines.
cd "$ROOT/assets"
sums=checksums.sha256
{
  if [[ -f $sums ]]; then grep -E '^[0-9a-f]{64}  [^ ]+  https://' "$sums" || true; fi
  find . -type f ! -name "$sums*" ! -name '*.pyc' -printf '%P\n' | LC_ALL=C sort | xargs -d '\n' sha256sum
} >"$sums.new"
mv -- "$sums.new" "$sums"
echo "assets regenerated; live theme files restored"
