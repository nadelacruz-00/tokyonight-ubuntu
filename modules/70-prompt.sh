#!/usr/bin/env bash
# shellcheck shell=bash
# prompt: oh-my-posh binary (kept when a new enough one is installed), the
# Tokyo Night Storm prompt config, shell rc blocks, and the zellij / lig themes.
# Globals read: HOME TNU_ROOT HAS_ZSH HAS_ZELLIJ HAS_LIG.

register_module prompt 70 0

TNU_OMP_MIN=31.8.0

prompt_applies() {
  return 0
}

# _prompt_version_ok: oh-my-posh on PATH reports a version >= TNU_OMP_MIN.
# Unparsable output counts as older.
_prompt_version_ok() {
  local v first
  have_cmd oh-my-posh || return 1
  v=$(oh-my-posh version 2>/dev/null) || return 1
  first=${v%%$'\n'*}
  first=${first#v}
  [[ $first =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  [[ $(printf '%s\n%s\n' "$TNU_OMP_MIN" "$first" | sort -V | head -n 1) == "$TNU_OMP_MIN" ]]
}

_prompt_binary() {
  local dest=$HOME/.local/bin/oh-my-posh src rc=0
  if _prompt_version_ok; then
    log_info "keeping installed oh-my-posh ($(oh-my-posh version 2>/dev/null | head -n 1))"
    return 0
  fi
  src=$(download_verified posh-linux-arm64) || rc=$?
  if ((rc == TNU_DRY_NOT_CACHED)); then
    note_change "download oh-my-posh"
    return 0
  elif ((rc != 0)); then
    return "$rc"
  fi
  if [[ ! -e $dest ]]; then backup_record pkg bin "$dest"; fi
  install_file "$src" "$dest" 0755
}

# _prompt_has_foreign_init FILE: an uncommented `oh-my-posh init` line outside our block.
_prompt_has_foreign_init() {
  awk -v b="$TNU_MARK_BEGIN" -v e="$TNU_MARK_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    skip { next }
    /^[[:space:]]*#/ { next }
    /oh-my-posh init/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$1"
}

# _prompt_rc_block FILE SHELL
_prompt_rc_block() {
  local file=$1 sh=$2 tpl
  if [[ -f $file ]] && _prompt_has_foreign_init "$file"; then
    log_info "$file: already configured (oh-my-posh init found)"
    return 0
  fi
  # shellcheck disable=SC2016 # the block body is shell code, expanded by the user's shell
  tpl='if command -v oh-my-posh >/dev/null 2>&1; then _omp=oh-my-posh; else _omp="$HOME/.local/bin/oh-my-posh"; fi
[ -x "$(command -v "$_omp")" ] && eval "$("$_omp" init @SH@ --config "$HOME/.config/oh-my-posh/tokyonight_storm.omp.json")"
unset _omp'
  printf '%s\n' "${tpl//@SH@/$sh}" | block_upsert "$file"
}

prompt_apply() {
  local f
  _prompt_binary
  install_file "$TNU_ROOT/assets/omp/tokyonight_storm.omp.json" \
    "$HOME/.config/oh-my-posh/tokyonight_storm.omp.json" 0644
  if [[ ${HAS_ZSH:-0} == 1 || -e $HOME/.zshrc ]]; then
    _prompt_rc_block "$HOME/.zshrc" zsh
  fi
  if [[ -e $HOME/.bashrc ]]; then
    _prompt_rc_block "$HOME/.bashrc" bash
  fi
  f=$HOME/.config/zellij/config.kdl
  if [[ ${HAS_ZELLIJ:-0} == 1 && -f $f ]]; then
    set_line "$f" '^theme\s+"' 'theme "tokyo-night-storm"'
  fi
  f=$HOME/.config/lig/config.toml
  if [[ ${HAS_LIG:-0} == 1 && -f $f ]]; then
    set_line "$f" '^theme\s*=' 'theme = "tokyonight"' ui
  fi
}
