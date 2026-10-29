#!/usr/bin/env bash
# shellcheck shell=bash
# gdm: build a GDM login theme (erhai or Yaru base + wallpaper + Tokyo Night
# overrides, via helpers/gresource.py) and register it as the gdm-theme.gresource
# alternative with priority 160. System-only: needs --system and sudo.
# The wallpaper is installed by the wallpaper module (order 50) under --system.
# Globals read: TNU_ROOT VARIANT RUN_DIR SYS_ROOT DRY_RUN SYSTEM.

register_module gdm 90 1

_GDM_THEME_DIR=/usr/share/gnome-shell/theme
_GDM_DEST_DIR=$_GDM_THEME_DIR/tokyonight-ubuntu
_GDM_DEST=$_GDM_DEST_DIR/gnome-shell-theme.gresource
_GDM_ALT_LINK=/usr/share/gnome-shell/gdm-theme.gresource
_GDM_ALT_NAME=gdm-theme.gresource
_GDM_WALLPAPER=/usr/share/backgrounds/osselo-Ask_a_friend.jpg

gdm_applies() {
  return 0
}

# _gdm_base: echo the base gresource (erhai theme when present, else Yaru).
_gdm_base() {
  local b
  for b in "$_GDM_THEME_DIR/erhai/gnome-shell-theme.gresource" \
    "$_GDM_THEME_DIR/Yaru/gnome-shell-theme.gresource"; do
    b=$(sys_path "$b")
    if [[ -f $b ]]; then
      printf '%s\n' "$b"
      return 0
    fi
  done
  return 1
}

# _gdm_tools: glib-compile-resources and gresource available (installing them if not).
_gdm_tools() {
  have_cmd glib-compile-resources && have_cmd gresource && return 0
  as_root apt-get install -y libglib2.0-dev-bin
  have_cmd glib-compile-resources && have_cmd gresource
}

# _gdm_alt_registered: our file is already an alternative of gdm-theme.gresource.
_gdm_alt_registered() {
  local f
  f=$(sys_path /var/lib/dpkg/alternatives/$_GDM_ALT_NAME)
  [[ -f $f ]] && grep -qxF -- "$_GDM_DEST" "$f"
}

_gdm_register_alt() {
  # Real paths on purpose: update-alternatives is not redirected by SYS_ROOT.
  backup_record alt "$_GDM_ALT_NAME" "$_GDM_DEST"
  as_root update-alternatives --install "$_GDM_ALT_LINK" "$_GDM_ALT_NAME" "$_GDM_DEST" 160
  note_change "alternative $_GDM_ALT_NAME -> $_GDM_DEST"
}

gdm_apply() {
  local base wall pal out dest destdir ref
  base=$(_gdm_base) || die "no base GDM theme (looked for erhai and Yaru gnome-shell-theme.gresource)"
  wall=$(sys_path "$_GDM_WALLPAPER")
  if [[ ! -f $wall ]]; then
    die "wallpaper $_GDM_WALLPAPER is missing (the wallpaper module installs it under --system and runs earlier)"
  fi
  pal=$TNU_ROOT/assets/rewaita/${VARIANT:-tokyonight}/gtk4.css
  if ! _gdm_tools; then
    if _dry; then
      note_change "install libglib2.0-dev-bin"
      return 0
    fi
    die "glib-compile-resources/gresource not available (apt package libglib2.0-dev-bin)"
  fi

  mkdir -p -- "$RUN_DIR/gdm"
  out=$RUN_DIR/gdm/gnome-shell-theme.gresource
  python3 -I "$TNU_ROOT/helpers/gresource.py" build \
    --base "$base" --palette "$pal" --wallpaper "$wall" --out "$out" ||
    die "building the GDM theme failed"

  dest=$(sys_path "$_GDM_DEST")
  destdir=$(sys_path "$_GDM_DEST_DIR")
  if [[ -f $dest ]] && cmp -s -- "$out" "$dest"; then
    log_debug "GDM theme unchanged"
    if ! _gdm_alt_registered; then _gdm_register_alt; fi
    return 0
  fi

  if _dry; then
    note_change "install $_GDM_DEST"
  else
    if [[ ! -d $destdir ]]; then backup_record dir "$destdir"; fi
    ref=$(backup_copy "$dest")
    backup_record sysfile "$dest" "$ref" "$(sha256_of "$out")"
  fi
  as_root install -D -m 0644 -- "$out" "$dest"
  if ! _dry; then
    note_change "install $_GDM_DEST"
    log_info "installed $_GDM_DEST"
  fi
  _gdm_register_alt
  log_info "GDM theme applies at next GDM start (log out or reboot)"
}
