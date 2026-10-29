#!/usr/bin/env bash
# shellcheck shell=bash
# osk: GJS OSK colour sync extension, sizing, a Gboard-style split layout built
# for the active keymap and, on erhai with --system, the split-flush patch.
# Globals read: HAS_GJSOSK IS_ERHAI SYSTEM TNU_ROOT RUN_DIR XDG_DATA_HOME XDG_CACHE_HOME.

register_module osk 80 0

_OSK_UUID=gjsosk-theme-sync@nadelacruz-00.github.io
_OSK_KEY=/org/gnome/shell/extensions/gjsosk

osk_applies() {
  if [[ ${HAS_GJSOSK:-0} != 1 ]]; then
    printf 'GJS OSK extension not installed\n'
    return 1
  fi
}

# _osk_install_extension: copy the theme-sync extension; log once if its dir is new.
_osk_install_extension() {
  local src=$TNU_ROOT/assets/osk/$_OSK_UUID dest f created=0
  dest=${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/$_OSK_UUID
  if [[ ! -d $dest ]]; then created=1; fi
  while IFS= read -r -d '' f; do
    install_file "$src/$f" "$dest/$f"
  done < <(cd "$src" && find . -type f -printf '%P\0' | LC_ALL=C sort -z)
  if ((created)) && ! _dry; then
    log_info "log out and back in to load new extensions"
  fi
}

# _osk_keymap: the first xkb input source (e.g. us+colemak), default us.
_osk_keymap() {
  local sources km=us
  sources=$(dget /org/gnome/desktop/input-sources/sources) || sources=
  if [[ $sources =~ \(\'xkb\',\ \'([^\']+)\'\) ]]; then km=${BASH_REMATCH[1]}; fi
  if [[ ! $km =~ ^[A-Za-z0-9_+.-]+$ ]]; then km=us; fi
  printf '%s\n' "$km"
}

# _osk_layouts: merge our layouts into custom-layout and select them.
_osk_layouts() {
  local km cache cur out split lit
  local -a parsed
  km=$(_osk_keymap)
  cache=${XDG_CACHE_HOME:-$HOME/.cache}/gjs-osk/keycodes/$km.json
  if [[ ! -f $cache ]]; then
    log_warn "open the on-screen keyboard once, then re-run to apply the split layout"
    return 0
  fi
  cur=$(dget "$_OSK_KEY/custom-layout") || die "cannot read custom-layout"
  if ! out=$(python3 -I "$TNU_ROOT/helpers/osk_layouts.py" merge --keycodes "$cache" --current "$cur"); then
    log_warn "cannot build the split layout for keymap $km; leaving the layouts alone"
    return 0
  fi
  # line 1: split layout index, line 2: custom-layout literal
  mapfile -t parsed < <(python3 -I -c 'import json,sys;d=json.loads(sys.stdin.read());print(d["split_index"]);print(d["custom_layout"])' <<<"$out")
  split=${parsed[0]}
  lit=${parsed[1]}
  dset "$_OSK_KEY/custom-layout" "$lit"
  dset "$_OSK_KEY/layout-landscape" "$split"
  dset "$_OSK_KEY/layout-portrait" "$split"
}

# _osk_sizing: schema types (org.gnome.shell.extensions.gjsosk): all *-percent
# and *-px keys are `i` (printed as plain ints), the flags are `b`. Never
# default-monitor (`s`): it is per-machine.
_osk_sizing() {
  dset "$_OSK_KEY/landscape-width-percent" 48
  dset "$_OSK_KEY/landscape-height-percent" 28
  dset "$_OSK_KEY/portrait-width-percent" 100
  dset "$_OSK_KEY/portrait-height-percent" 35
  dset "$_OSK_KEY/outer-spacing-px" 6
  dset "$_OSK_KEY/border-spacing-px" 2
  dset "$_OSK_KEY/font-size-px" 16
  dset "$_OSK_KEY/font-bold" true
  dset "$_OSK_KEY/round-key-corners" false
  dset "$_OSK_KEY/show-icons" false
  dset "$_OSK_KEY/system-accent-col" false
}

# _osk_sys_install SRC DEST MODE: as_root install of one system file, with a
# sysfile row (and dir rows for missing parents) written first.
_osk_sys_install() {
  local src=$1 dest mode=$3 ref sha d missing=() i
  dest=$(sys_path "$2")
  if _same_file "$src" "$dest" "$mode"; then
    log_debug "unchanged $dest"
    return 0
  fi
  if _dry; then
    log_dry "install $dest"
    note_change "install $dest"
    return 0
  fi
  d=${dest%/*}
  while [[ -n $d && ! -d $d ]]; do
    missing=("$d" "${missing[@]}")
    d=${d%/*}
  done
  for i in "${missing[@]}"; do
    backup_record dir "$i"
  done
  sha=$(sha256_of "$src") || die "cannot read $src"
  ref=$(backup_copy "$dest")
  backup_record sysfile "$dest" "$ref" "$sha"
  as_root install -D -m "$mode" "$src" "$dest" || die "cannot install $dest"
  note_change "install $dest"
  log_info "installed $dest"
}

# _osk_backup_ext EXT: when the split-flush patch would change EXT, back it up
# with a sysfile row (installed sha from a patched scratch copy) first, so
# --uninstall --system restores the upstream file.
_osk_backup_ext() {
  local ext=$1 tmp sha ref
  if [[ ! -f $ext ]]; then return 0; fi
  tmp=$(mktemp -d "${RUN_DIR:?RUN_DIR not set}/osk.XXXXXXXX") || die "mktemp failed in $RUN_DIR"
  cp -p -- "$ext" "$tmp/extension.js" || die "cannot copy $ext"
  GJSOSK_EXT=$tmp/extension.js "$TNU_ROOT/assets/osk/gjsosk-split-flush" reapply >/dev/null 2>&1 || true
  sha=$(sha256_of "$tmp/extension.js") || die "cannot read the patched copy of $ext"
  rm -rf -- "$tmp"
  if [[ $sha == "$(sha256_of "$ext")" ]]; then return 0; fi
  if _dry; then
    note_change "patch $ext"
    return 0
  fi
  ref=$(backup_copy "$ext")
  backup_record sysfile "$ext" "$ref" "$sha"
  note_change "patch $ext"
}

_osk_split_flush() {
  local ext
  _osk_sys_install "$TNU_ROOT/assets/osk/gjsosk-split-flush" /usr/local/sbin/gjsosk-split-flush 755
  _osk_sys_install "$TNU_ROOT/assets/osk/99erhai-gjsosk-split-flush" /etc/apt/apt.conf.d/99erhai-gjsosk-split-flush 644
  ext=$(sys_path /usr/share/gnome-shell/extensions/gjsosk@vishram1123.com/extension.js)
  _osk_backup_ext "$ext"
  # No-op when already patched; GJSOSK_EXT keeps it inside SYS_ROOT in tests.
  as_root env "GJSOSK_EXT=$ext" "$(sys_path /usr/local/sbin/gjsosk-split-flush)" reapply
}

osk_apply() {
  _osk_install_extension
  ext_enable "$_OSK_UUID"
  _osk_layouts
  _osk_sizing
  if [[ ${SYSTEM:-0} == 1 && ${IS_ERHAI:-0} == 1 ]]; then _osk_split_flush; fi
}
