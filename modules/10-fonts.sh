#!/usr/bin/env bash
# shellcheck shell=bash
# fonts: JetBrainsMono Nerd Font (pinned release, checksum verified) into the
# user font directory. fc-cache runs only when a file changed. The directory is
# recorded as a `pkg fontdir` row only when we created it, so --uninstall
# --purge never removes a font directory the user already had.
# Globals read: HOME RUN_DIR DRY_RUN.

register_module fonts 10 0

fonts_applies() {
  return 0
}

fonts_apply() {
  local dest=$HOME/.local/share/fonts/JetBrainsMonoNerd
  local tarball="" rc=0 tmp f before after existed=1
  tarball=$(download_verified JetBrainsMono.tar.xz) || rc=$?
  if ((rc == TNU_DRY_NOT_CACHED)); then
    note_change "download JetBrainsMono"
    return 0
  elif ((rc != 0)); then
    return "$rc"
  fi
  if [[ ! -d $dest ]]; then existed=0; fi
  tmp=$(mktemp -d "${RUN_DIR:?RUN_DIR not set}/fonts.XXXXXXXX") || die "mktemp failed in $RUN_DIR"
  if ! tar -xJf "$tarball" -C "$tmp"; then
    rm -rf -- "$tmp"
    die "cannot unpack JetBrainsMono.tar.xz"
  fi
  before=$(module_changes "$MODULE")
  while IFS= read -r -d '' f; do
    if ((! existed)) && [[ ! -d $dest ]]; then backup_record pkg fontdir "$dest"; fi
    install_file "$f" "$dest/${f##*/}" 0644
  done < <(find "$tmp" -type f -name '*.ttf' -print0 | LC_ALL=C sort -z)
  rm -rf -- "$tmp"
  after=$(module_changes "$MODULE")
  if ((after > before)); then
    run fc-cache -f "$dest"
  else
    log_info "fonts are up to date"
  fi
}
