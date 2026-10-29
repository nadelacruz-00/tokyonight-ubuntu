#!/usr/bin/env bash
# shellcheck shell=bash
# rewaita: the Rewaita flatpak (user install) and its Tokyo Night preferences.
# Needs flatpak (or --system, which installs it with apt) and network access.
# Globals read: HAS_FLATPAK SYSTEM OFFLINE VARIANT HOME DRY_RUN RUN_DIR TNU_ROOT.

register_module rewaita 20 0

_REWAITA_APP=io.github.swordpuffin.rewaita

rewaita_applies() {
  if [[ ${OFFLINE:-0} == 1 ]]; then
    echo "offline: the Rewaita flatpak cannot be installed"
    return 1
  fi
  if [[ ${HAS_FLATPAK:-0} != 1 && ${SYSTEM:-0} != 1 ]]; then
    echo "flatpak is not installed (use --system to install it)"
    return 1
  fi
}

# _rewaita_prefs: merge our keys into Rewaita's prefs.json (backed up first).
_rewaita_prefs() {
  local prefs=$HOME/.var/app/$_REWAITA_APP/data/prefs.json dark rc=0 sha tmp
  local -a pairs
  if [[ $VARIANT == storm ]]; then dark="Tokyonight Storm 🌪️.css"; else dark="Tokyonight 🗼.css"; fi
  pairs=(
    "dark-theme=\"$dark\""
    'light-theme="Tokyonight 🗼.css"'
    'window-controls="mint"'
    "accent=\"'blue'\""
    'modify-gtk3-theme=true'
    'modify-gnome-shell=true'
  )
  if _dry; then
    # Merge into a scratch copy to learn whether anything would change.
    tmp=$(mktemp "$RUN_DIR/prefs.XXXXXXXX") || die "mktemp failed"
    if [[ -f $prefs ]]; then cp -- "$prefs" "$tmp"; else rm -f -- "$tmp"; fi
    python3 -I "$TNU_ROOT/helpers/prefs.py" merge "$tmp" "${pairs[@]}" || rc=$?
    rm -f -- "$tmp" "$tmp".invalid-*
    case $rc in
      0) note_change "update $prefs" ;;
      3) ;;
      *) die "prefs.py failed ($rc) for $prefs" ;;
    esac
    return 0
  fi
  backup_file "$prefs"
  if [[ ! -e $prefs ]]; then _ensure_parent_dirs "$prefs" || die "cannot create parent dirs of $prefs"; fi
  python3 -I "$TNU_ROOT/helpers/prefs.py" merge "$prefs" "${pairs[@]}" || rc=$?
  case $rc in
    0)
      sha=$(sha256_of "$prefs") || die "cannot read $prefs"
      backup_file "$prefs" "$sha"
      note_change "update $prefs"
      log_info "updated $prefs"
      ;;
    3) log_debug "unchanged $prefs" ;;
    *) die "prefs.py failed ($rc) for $prefs" ;;
  esac
}

rewaita_apply() {
  if [[ ${HAS_FLATPAK:-0} != 1 ]]; then
    apt_install flatpak
    note_change "apt-get install flatpak"
  fi
  run flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  if ! flatpak info --user "$_REWAITA_APP" >/dev/null 2>&1; then
    # Row first (crash-safe): purge checks `flatpak info` before uninstalling.
    backup_record pkg flatpak "$_REWAITA_APP"
    run flatpak install --user -y --noninteractive flathub "$_REWAITA_APP"
    note_change "install flatpak $_REWAITA_APP"
  fi
  _rewaita_prefs
}
