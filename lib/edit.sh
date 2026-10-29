#!/usr/bin/env bash
# shellcheck shell=bash
# In-place edits of user files that never back up the whole file:
#   block_upsert FILE            marked block (body on stdin)  -> `block` row
#   block_remove FILE            remove the marked block (no row)
#   set_line FILE RE LINE [SEC]  replace/add one key line      -> `line` row
# plus the `block` / `line` replay handlers used by backup_replay.
# Edits are computed on a scratch copy in RUN_DIR first, so an unchanged file
# gets no row and no write, and dry-run sees exactly what would change.
# A symlinked FILE is edited at its target, keeping the link.
# Sourced, never executed; safe to source twice; sets no shell options.
# Globals read: TNU_ROOT RUN_DIR DRY_RUN MODULE.

TNU_MARK_BEGIN='# >>> tokyonight-ubuntu >>>'
TNU_MARK_END='# <<< tokyonight-ubuntu <<<'

_textedit() {
  python3 -I "${TNU_ROOT:?TNU_ROOT not set}/helpers/textedit.py" "$@"
}

# _tnu_esc / _tnu_unesc: reversible escaping of a manifest field (\ -> \\, TAB -> \t).
_tnu_esc() {
  local s=${1//\\/\\\\}
  printf '%s' "${s//$'\t'/\\t}"
}

_tnu_unesc() {
  local s=$1 out=""
  while [[ $s == *\\* ]]; do
    out+=${s%%\\*}
    s=${s#*\\}
    case ${s:0:1} in
      t) out+=$'\t' ;;
      *) out+=${s:0:1} ;;
    esac
    s=${s:1}
  done
  printf '%s' "$out$s"
}

# _edit_target FILE: FILE, or what a symlink FILE resolves to.
_edit_target() {
  local f=$1 t
  _abs_path "$f"
  if [[ -L $f ]]; then
    t=$(readlink -f -- "$f") || die "cannot resolve symlink $f"
    f=$t
  fi
  if [[ $f == *[$'\t\n']* ]]; then die "path contains a tab or newline: ${f//[$'\t\n']/?}"; fi
  if [[ -e $f && ! -f $f ]]; then die "not a regular file: $f"; fi
  printf '%s\n' "$f"
}

# _edit_scratch FILE: copy FILE (or nothing, when absent) to a new scratch file; echo its path.
_edit_scratch() {
  local tmp
  tmp=$(mktemp "${RUN_DIR:?RUN_DIR not set}/edit.XXXXXXXX") || die "mktemp failed in $RUN_DIR"
  if [[ -e $1 ]] && ! cp -- "$1" "$tmp"; then
    rm -f -- "$tmp"
    die "cannot read $1"
  fi
  printf '%s\n' "$tmp"
}

# _edit_once KEY: succeed the first time KEY is seen this run (shared by subshells).
_edit_once() {
  local idx=${RUN_DIR:?RUN_DIR not set}/edit.idx k
  if [[ -f $idx ]]; then
    while IFS= read -r k; do
      if [[ $k == "$1" ]]; then return 1; fi
    done <"$idx"
  fi
  printf '%s\n' "$1" >>"$idx" || die "cannot write $idx"
}

# _edit_seen KEY: KEY was recorded by _edit_once this run.
_edit_seen() {
  local idx=${RUN_DIR:?RUN_DIR not set}/edit.idx k
  [[ -f $idx ]] || return 1
  while IFS= read -r k; do
    if [[ $k == "$1" ]]; then return 0; fi
  done <"$idx"
  return 1
}

# block_upsert FILE: insert or replace our marked block in FILE with stdin
# (the body, without markers). The first change to FILE this run records
# `block FILE CREATED` (CREATED=1 when FILE did not exist).
block_upsert() {
  local file tmp rc=0 created=0
  file=$(_edit_target "${1:?block_upsert: FILE required}") || exit 1
  if [[ ! -e $file ]]; then created=1; fi
  tmp=$(_edit_scratch "$file") || exit 1
  _textedit block-upsert --begin="$TNU_MARK_BEGIN" --end="$TNU_MARK_END" -- "$tmp" || rc=$?
  case $rc in
    0) ;;
    3)
      rm -f -- "$tmp"
      log_debug "unchanged block in $file"
      return 0
      ;;
    *)
      rm -f -- "$tmp"
      die "cannot update the tokyonight-ubuntu block in $file"
      ;;
  esac
  if _dry; then
    rm -f -- "$tmp"
    log_dry "update block in $file"
    note_change "block $file"
    return 0
  fi
  # Parent dir rows first, so reverse replay removes the file before the dirs.
  _ensure_parent_dirs "$file" || die "cannot create parent dirs of $file"
  if _edit_once "block $file"; then backup_record block "$file" "$created"; fi
  if ! atomic_write "$file" <"$tmp"; then
    rm -f -- "$tmp"
    die "cannot write $file"
  fi
  rm -f -- "$tmp"
  note_change "block $file"
  log_info "updated block in $file"
}

# block_remove FILE: remove our marked block from FILE (no manifest row).
block_remove() {
  local file rc=0
  file=$(_edit_target "${1:?block_remove: FILE required}") || return 1
  if [[ ! -e $file ]]; then return 0; fi
  if _dry; then
    log_dry "remove block from $file"
    return 0
  fi
  _textedit block-remove --begin="$TNU_MARK_BEGIN" --end="$TNU_MARK_END" -- "$file" || rc=$?
  case $rc in
    0) log_info "removed block from $file" ;;
    3) ;;
    *)
      log_warn "cannot remove the tokyonight-ubuntu block from $file"
      return 1
      ;;
  esac
}

# set_line FILE MATCH_REGEX NEW_LINE [SECTION]: replace the first uncommented
# line matching MATCH_REGEX (inside [SECTION] when given) with NEW_LINE, or add
# it. Records `line FILE MATCH OLD|ABSENT NEW SECTION` (fields escaped with
# _tnu_esc); no-op when the line is already NEW_LINE. A FILE that did not
# exist also gets a `file FILE ABSENT SHA` row, so uninstall can remove it.
set_line() {
  local file match=${2:?set_line: MATCH_REGEX required} new=${3:?set_line: NEW_LINE required}
  local section=${4:-} tmp old rc=0 created=0
  local -a sec=()
  file=$(_edit_target "${1:?set_line: FILE required}") || exit 1
  if [[ $new == *$'\n'* || $match == *$'\n'* || $section == *$'\n'* ]]; then
    die "set_line: newline in argument for $file"
  fi
  if [[ -n $section ]]; then sec=(--section="$section"); fi
  if [[ ! -e $file ]]; then created=1; fi
  tmp=$(_edit_scratch "$file") || exit 1
  old=$(_textedit set-line --match="$match" --line="$new" "${sec[@]}" -- "$tmp") || rc=$?
  case $rc in
    0) ;;
    3)
      rm -f -- "$tmp"
      log_debug "unchanged line in $file"
      return 0
      ;;
    *)
      rm -f -- "$tmp"
      die "cannot set line in $file"
      ;;
  esac
  if _dry; then
    rm -f -- "$tmp"
    log_dry "set line in $file: $new"
    note_change "line $file"
    return 0
  fi
  _ensure_parent_dirs "$file" || die "cannot create parent dirs of $file"
  backup_record line "$file" "$(_tnu_esc "$match")" "$(_tnu_esc "$old")" \
    "$(_tnu_esc "$new")" "$(_tnu_esc "$section")"
  if ((created)); then _edit_once "created $file" || true; fi
  # Keep the `file` row's hash current, so replay removes a file we created.
  if _edit_seen "created $file"; then backup_file "$file" "$(sha256_of "$tmp")"; fi
  if ! atomic_write "$file" <"$tmp"; then
    rm -f -- "$tmp"
    die "cannot write $file"
  fi
  rm -f -- "$tmp"
  note_change "line $file"
  log_info "set line in $file: $new"
}

# Replay `block FILE CREATED`: remove the block; delete FILE when we created
# it and nothing but the block was in it.
_replay_block() {
  local file=$3 created=$4
  if [[ ! -e $file ]]; then return 0; fi
  block_remove "$file" || return 1
  if _dry; then return 0; fi
  if [[ $created == 1 && -f $file && ! -s $file ]]; then
    rm -f -- "$file" || return 1
    log_info "removed $file"
  fi
}

# Replay `line FILE MATCH OLD|ABSENT NEW SECTION`: put OLD back (or delete the
# line), only while the matching line is still NEW (drift rule).
_replay_line() {
  local file=$3 match new old section tmp cur rc=0
  local -a sec=() how=()
  match=$(_tnu_unesc "$4")
  old=$(_tnu_unesc "$5")
  new=$(_tnu_unesc "$6")
  section=$(_tnu_unesc "$7")
  if [[ ! -f $file ]]; then return 0; fi
  if [[ -n $section ]]; then sec=(--section="$section"); fi
  # set-line on a scratch copy prints the current line and exits 3 iff it is NEW.
  tmp=$(mktemp "${RUN_DIR:?RUN_DIR not set}/edit.XXXXXXXX") || return 1
  if ! cp -- "$file" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  cur=$(_textedit set-line --match="$match" --line="$new" "${sec[@]}" -- "$tmp") || rc=$?
  rm -f -- "$tmp"
  case $rc in
    0)
      _drifted "$file" "$cur" "$new" || true
      return 0
      ;;
    3) ;;
    *) return 1 ;;
  esac
  if _dry; then
    log_dry "restore line in $file"
    return 0
  fi
  if [[ $old == ABSENT ]]; then how=(--absent); else how=(--old="$old"); fi
  rc=0
  _textedit restore-line --match="$match" "${sec[@]}" "${how[@]}" -- "$file" || rc=$?
  if ((rc != 0 && rc != 3)); then return 1; fi
  log_info "restored line in $file"
}
