#!/usr/bin/env bash
# Sourced by maintainer tools (tools/regen-assets.sh, tools/screenshots.sh):
# snapshot live theme files and dconf keys of the CURRENT session, restore them
# byte-for-byte later and verify the result.
#
#   live_state_save FILE... -- KEY...   copy files (or note them absent), read
#                                       the keys, record sha256s
#   live_state_restore                  write everything back (no-op when
#                                       nothing was saved); UNSET -> dconf reset
#   live_state_verify                   1 + loud message per mismatch
#   live_state_drop                     forget the snapshot (removes the copies)
#
# Globals: LS_DIR LS_FILES LS_KEYS LS_DCONF LS_SUM LS_ACTIVE.

LS_DIR=""
LS_ACTIVE=0
LS_FILES=()
LS_KEYS=()
declare -gA LS_DCONF=()
declare -gA LS_SUM=()

_ls_sum() {
  sha256sum <"$1" | cut -d' ' -f1
}

live_state_save() {
  local i f k
  LS_FILES=()
  LS_KEYS=()
  LS_DCONF=()
  LS_SUM=()
  while (($#)) && [[ $1 != -- ]]; do
    LS_FILES+=("$1")
    shift
  done
  if (($#)); then shift; fi
  LS_KEYS=("$@")
  LS_DIR=$(mktemp -d)
  for i in "${!LS_FILES[@]}"; do
    f=${LS_FILES[$i]}
    if [[ -f $f ]]; then
      cp -p -- "$f" "$LS_DIR/$i"
      LS_SUM[$i]=$(_ls_sum "$f")
    else
      : >"$LS_DIR/absent.$i"
    fi
  done
  if ((${#LS_KEYS[@]})); then
    for k in "${LS_KEYS[@]}"; do LS_DCONF[$k]=$(dconf read "$k"); done
  fi
  LS_ACTIVE=1
}

live_state_restore() {
  ((LS_ACTIVE)) || return 0
  local i f k now rc=0
  for i in "${!LS_FILES[@]}"; do
    f=${LS_FILES[$i]}
    if [[ -f $LS_DIR/$i ]]; then
      if ! mkdir -p -- "${f%/*}" || ! cp -p -- "$LS_DIR/$i" "$f"; then rc=1; fi
    elif [[ -e $LS_DIR/absent.$i ]]; then
      rm -f -- "$f" || rc=1
    fi
  done
  for k in "${!LS_DCONF[@]}"; do
    now=$(dconf read "$k") || now=""
    if [[ $now != "${LS_DCONF[$k]}" ]]; then
      if [[ -n ${LS_DCONF[$k]} ]]; then
        dconf write "$k" "${LS_DCONF[$k]}" || rc=1
      else
        dconf reset "$k" || rc=1
      fi
      echo "restored dconf $k" >&2
    fi
  done
  return "$rc"
}

live_state_verify() {
  ((LS_ACTIVE)) || return 0
  local i f k now bad=0
  for i in "${!LS_FILES[@]}"; do
    f=${LS_FILES[$i]}
    if [[ -n ${LS_SUM[$i]+x} ]]; then
      if [[ ! -f $f || $(_ls_sum "$f") != "${LS_SUM[$i]}" ]]; then
        echo "!!! RESTORE MISMATCH: $f differs from its backup ($LS_DIR/$i)" >&2
        bad=1
      fi
    elif [[ -e $f ]]; then
      echo "!!! RESTORE MISMATCH: $f did not exist before and still exists" >&2
      bad=1
    fi
  done
  for k in "${!LS_DCONF[@]}"; do
    now=$(dconf read "$k") || now="(unreadable)"
    if [[ $now != "${LS_DCONF[$k]}" ]]; then
      echo "!!! RESTORE MISMATCH: dconf $k is ${now:-UNSET}, was ${LS_DCONF[$k]:-UNSET}" >&2
      bad=1
    fi
  done
  return "$bad"
}

live_state_drop() {
  if [[ -n $LS_DIR && -d $LS_DIR ]]; then rm -rf -- "$LS_DIR"; fi
  LS_DIR=""
  LS_ACTIVE=0
}
