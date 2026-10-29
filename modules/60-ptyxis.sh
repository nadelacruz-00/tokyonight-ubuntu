#!/usr/bin/env bash
# shellcheck shell=bash
# ptyxis: Tokyo Night palette, Nerd Font and dark interface for Ptyxis.
# Reuses the default profile (else the first profile); only when there is none
# is a "Tokyo Night" profile created. Palette names are Ptyxis built-ins.
# Globals read: HAS_PTYXIS VARIANT.

register_module ptyxis 60 0

_PTYXIS=/org/gnome/Ptyxis

ptyxis_applies() {
  if [[ ${HAS_PTYXIS:-0} != 1 ]]; then
    printf 'ptyxis not installed\n'
    return 1
  fi
}

# _ptyxis_unquote LITERAL: the text of a GVariant string literal ('x' or "x").
_ptyxis_unquote() {
  local s=$1
  s=${s#@s }
  s=${s#[\'\"]}
  printf '%s\n' "${s%[\'\"]}"
}

# _ptyxis_first_uuid LITERAL: first element of a string-array literal, or nothing.
_ptyxis_first_uuid() {
  python3 -I -c '
import sys
sys.path.insert(0, sys.argv[1] + "/helpers")
import gvlist
try:
    items = gvlist.parse(sys.argv[2])
except gvlist.GVError:
    items = []
if items:
    print(items[0])
' "${TNU_ROOT:?TNU_ROOT not set}" "$1"
}

# _ptyxis_profile_uuid: set _PTYXIS_UUID to the profile to theme and _PTYXIS_NEW=1
# when it must be created (globals: this runs in the module's own shell).
_ptyxis_profile_uuid() {
  local u list
  _PTYXIS_NEW=0 _PTYXIS_UUID=
  u=$(dget "$_PTYXIS/default-profile-uuid") || die "cannot read default-profile-uuid"
  u=$(_ptyxis_unquote "$u")
  if [[ -z $u ]]; then
    list=$(dget "$_PTYXIS/profile-uuids") || die "cannot read profile-uuids"
    if [[ -n $list ]]; then u=$(_ptyxis_first_uuid "$list"); fi
  fi
  if [[ -z $u ]]; then
    u=$(python3 -I -c 'import uuid;print(uuid.uuid4().hex)') || die "cannot generate a UUID"
    _PTYXIS_NEW=1
  fi
  _PTYXIS_UUID=$u
}

ptyxis_apply() {
  local u palette
  _ptyxis_profile_uuid
  u=$_PTYXIS_UUID
  if ((_PTYXIS_NEW)); then
    gvlist_add "$_PTYXIS/profile-uuids" "$u"
    dset "$_PTYXIS/default-profile-uuid" "$(gv_str "$u")"
    dset "$_PTYXIS/Profiles/$u/label" "$(gv_str 'Tokyo Night')"
  fi
  if [[ ${VARIANT:-tokyonight} == storm ]]; then palette='Tokyo Night Storm'; else palette='Tokyo Night'; fi
  dset "$_PTYXIS/Profiles/$u/palette" "$(gv_str "$palette")"
  dset "$_PTYXIS/font-name" "$(gv_str 'JetBrainsMono Nerd Font 10')"
  dset "$_PTYXIS/use-system-font" false
  dset "$_PTYXIS/interface-style" "$(gv_str dark)"
}
