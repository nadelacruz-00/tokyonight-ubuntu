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

BK="$(mktemp -d)"
declare -A DCONF_BEFORE=()

restore() {
  local i f
  for i in "${!FILES[@]}"; do
    f="${FILES[$i]}"
    if [[ -f $BK/$i ]]; then
      mkdir -p "${f%/*}"
      cp -p -- "$BK/$i" "$f"
    elif [[ -e $BK/absent.$i ]]; then
      rm -f -- "$f"
    fi
  done
  local k
  for k in "${DCONF_KEYS[@]}"; do
    if [[ -n ${DCONF_BEFORE[$k]+x} && $(dconf read "$k") != "${DCONF_BEFORE[$k]}" ]]; then
      if [[ -n ${DCONF_BEFORE[$k]} ]]; then
        dconf write "$k" "${DCONF_BEFORE[$k]}"
      else
        dconf reset "$k"
      fi
      echo "restored dconf $k" >&2
    fi
  done
  rm -rf -- "$BK"
}
trap restore EXIT
trap 'exit 130' INT TERM

command -v flatpak >/dev/null || {
  echo "flatpak not found" >&2
  exit 1
}
flatpak info "$APP" >/dev/null 2>&1 || {
  echo "$APP is not installed" >&2
  exit 1
}

for i in "${!FILES[@]}"; do
  if [[ -f ${FILES[$i]} ]]; then cp -p -- "${FILES[$i]}" "$BK/$i"; else : >"$BK/absent.$i"; fi
done
if command -v dconf >/dev/null; then
  for k in "${DCONF_KEYS[@]}"; do DCONF_BEFORE[$k]="$(dconf read "$k")"; done
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
