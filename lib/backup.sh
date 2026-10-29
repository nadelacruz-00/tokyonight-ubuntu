#!/usr/bin/env bash
# shellcheck shell=bash
# Per-run backups: $STATE_DIR/backups/$RUN_ID/{manifest.tsv,files/N,files.idx}.
# manifest.tsv is append-only, one TAB-separated row per change, written
# (and synced) BEFORE the change it describes, so an interrupted run replays.
#
# Rows (replayed newest first by backup_replay):
#   file    PATH  files/N|ABSENT  INSTALLED_SHA
#   sysfile PATH  files/N|ABSENT  INSTALLED_SHA   (restored via as_root)
#   dconf   KEY   OLD|UNSET       NEW
#   dir     PATH                                  (created by us)
#   pkg     flatpak|fontdir|bin|sysdir  NAME_OR_PATH   (replayed only with PURGE=1)
#   alt     NAME  PATH                            (update-alternatives --remove)
#   block   FILE  CREATED(0|1)                    (handler lives in lib/edit.sh)
#   line    FILE  MATCH_REGEX  OLD_LINE|ABSENT  NEW_LINE   (handler lives in lib/edit.sh)
#
# Row TYPE is replayed by the function `_replay_TYPE DIR PURGE FIELD...`
# (DIR = backup dir, FIELD... = the row's fields after TYPE). Handlers may be
# defined in any sourced file. They run in an `if` context, so errexit is off
# inside them: check every command and `return 1` on failure. Use `run` /
# `as_root` for changes so dry-run is honoured.
#
# Drift rule: file/sysfile/dconf/line rows restore only when the current value
# still equals the one we installed; otherwise log_warn "kept X (changed since install)".
#
# Sourced, never executed; safe to source twice; sets no shell options.
# Globals read: STATE_DIR RUN_ID DRY_RUN SYSTEM HOME SYS_ROOT.

# backup_dir: create (on first use) and echo this run's backup dir.
backup_dir() {
  local d=${STATE_DIR:?STATE_DIR not set}/backups/${RUN_ID:?RUN_ID not set}
  if [[ ! -f $d/manifest.tsv ]]; then
    (umask 077 && mkdir -p -- "$d" && : >>"$d/manifest.tsv") || die "cannot create backup dir $d"
  fi
  printf '%s\n' "$d"
}

# _backup_append FILE LINE: append LINE (+ newline) and sync. A torn last line
# (no trailing newline, e.g. after SIGKILL) is terminated first so it stays
# isolated and is skipped on replay.
_backup_append() {
  local f=$1 line=$2
  if [[ -s $f && -n $(tail -c 1 -- "$f") ]]; then
    printf '\n' >>"$f" || return 1
  fi
  printf '%s\n' "$line" >>"$f" || return 1
  # Best effort: the row is already appended; a failed fsync must not abort the run.
  sync -- "$f" 2>/dev/null || true
}

_join_tab() {
  local IFS=$'\t'
  printf '%s' "$*"
}

# backup_record TYPE FIELD...: append a manifest row (no-op in dry-run).
backup_record() {
  local f dir
  if (($# < 2)); then die "backup_record: TYPE and FIELD required"; fi
  if [[ ! $1 =~ ^[a-z]+$ ]]; then die "backup_record: bad row type: $1"; fi
  for f in "$@"; do
    if [[ $f == *[$'\t\n']* ]]; then
      die "backup_record: $1 field contains a tab or newline: ${f//[$'\t\n']/?}"
    fi
  done
  if _dry; then return 0; fi
  dir=$(backup_dir) || exit 1
  _backup_append "$dir/manifest.tsv" "$(_join_tab "$@")" || die "cannot write $dir/manifest.tsv"
}

# backup_copy PATH: copy PATH into this run's files/N and echo "files/N",
# or echo ABSENT when PATH does not exist. Symlinks are copied as symlinks.
backup_copy() {
  local path=$1 dir n=1
  _abs_path "$path"
  if [[ ! -e $path && ! -L $path ]]; then
    printf 'ABSENT\n'
    return 0
  fi
  if [[ -d $path && ! -L $path ]]; then die "cannot back up a directory: $path"; fi
  dir=$(backup_dir) || exit 1
  (umask 077 && mkdir -p -- "$dir/files") || die "cannot create $dir/files"
  while [[ -e $dir/files/$n || -L $dir/files/$n ]]; do n=$((n + 1)); done
  cp -P --preserve=mode,timestamps -- "$path" "$dir/files/$n" || die "cannot back up $path"
  printf 'files/%s\n' "$n"
}

# _backup_index_get DIR PATH: echo the files/N|ABSENT ref already taken for PATH this run.
_backup_index_get() {
  local p r
  [[ -f $1/files.idx ]] || return 1
  while IFS=$'\t' read -r p r; do
    if [[ $p == "$2" ]]; then
      printf '%s\n' "$r"
      return 0
    fi
  done <"$1/files.idx"
  return 1
}

# backup_file PATH [INSTALLED_SHA]: back up PATH's original once per run
# (later calls reuse that copy, also across subshells). With INSTALLED_SHA,
# append the `file PATH REF INSTALLED_SHA` row; install_file passes the hash
# of what it is about to write. For an in-place edit: `backup_file P` before,
# `backup_file P "$(sha256_of P)"` after. No-op in dry-run.
backup_file() {
  local path=$1 sha=${2:-} dir ref
  _abs_path "$path"
  if [[ $path == *[$'\t\n']* ]]; then die "backup_file: path contains a tab or newline"; fi
  if _dry; then return 0; fi
  dir=$(backup_dir) || exit 1
  if ! ref=$(_backup_index_get "$dir" "$path"); then
    ref=$(backup_copy "$path") || exit 1
    _backup_append "$dir/files.idx" "$path"$'\t'"$ref" || die "cannot write $dir/files.idx"
  fi
  if [[ -n $sha ]]; then backup_record file "$path" "$ref" "$sha"; fi
}

# backup_list: backup dirs (with a manifest) newest first, excluding .restored.
backup_list() {
  local root=${STATE_DIR:?STATE_DIR not set}/backups d dirs=()
  [[ -d $root ]] || return 0
  for d in "$root"/*/; do
    d=${d%/}
    if [[ ${d##*/} != .restored && -f $d/manifest.tsv ]]; then dirs+=("$d"); fi
  done
  ((${#dirs[@]})) || return 0
  printf '%s\n' "${dirs[@]}" | LC_ALL=C sort -r
}

# _split_tab LINE: split on every TAB (keeping empty fields) into the caller's F array.
_split_tab() {
  local s=$1
  F=()
  while [[ $s == *$'\t'* ]]; do
    F+=("${s%%$'\t'*}")
    s=${s#*$'\t'}
  done
  F+=("$s")
}

# _backup_row_arity TYPE: field count (after TYPE) for the built-in row types.
_backup_row_arity() {
  case $1 in
    file | sysfile | dconf) echo 3 ;;
    dir) echo 1 ;;
    pkg | alt | block) echo 2 ;;
    line) echo 4 ;;
    *) echo any ;;
  esac
}

# backup_replay DIR [PURGE=0]: undo DIR's manifest rows, newest first.
# Returns 1 if any row could not be replayed (others are still attempted).
backup_replay() {
  local dir=${1:?backup_replay: DIR required} purge=${2:-0} m line type want seen_key i rc=0
  local -a rows=() F=()
  local -A _replay_seen=() _replay_pkg_paths=()
  m=$dir/manifest.tsv
  if [[ ! -f $m ]]; then
    log_error "no manifest in $dir"
    return 1
  fi
  # A torn last line (no newline) is never read: its change never happened.
  while IFS= read -r line; do
    if [[ -n $line ]]; then rows+=("$line"); fi
  done <"$m"
  for line in "${rows[@]}"; do
    _split_tab "$line"
    if [[ ${F[0]} == pkg && ${#F[@]} -eq 3 && -n ${F[2]} ]]; then _replay_pkg_paths["${F[2]}"]=1; fi
  done
  for ((i = ${#rows[@]} - 1; i >= 0; i--)); do
    _split_tab "${rows[i]}"
    type=${F[0]}
    want=$(_backup_row_arity "$type")
    if [[ ! $type =~ ^[a-z]+$ || ($want != any && $want != $((${#F[@]} - 1))) || -z ${F[1]:-} ]]; then
      log_warn "skipping malformed row in $m: ${rows[i]//$'\t'/ | }"
      continue
    fi
    # A path written twice in one run shares one original: only its newest row counts.
    if [[ $type == file || $type == sysfile ]]; then
      seen_key="$type ${F[1]}"
      if [[ -n ${_replay_seen["$seen_key"]:-} ]]; then continue; fi
      _replay_seen["$seen_key"]=1
    fi
    if ! declare -F "_replay_$type" >/dev/null; then
      log_warn "unsupported row type '$type' in $m (left as is)"
      continue
    fi
    if ! "_replay_$type" "$dir" "$purge" "${F[@]:1}"; then
      log_warn "could not undo $type ${F[1]}"
      rc=1
    fi
  done
  return "$rc"
}

# _current_sha PATH: sha256 of PATH, or ABSENT / OTHER (not a readable regular file).
_current_sha() {
  if [[ -f $1 ]]; then
    sha256_of "$1" 2>/dev/null || printf 'OTHER\n'
  elif [[ -e $1 || -L $1 ]]; then
    printf 'OTHER\n'
  else
    printf 'ABSENT\n'
  fi
}

# _backup_ref_ok DIR REF: REF is files/N and exists in DIR.
_backup_ref_ok() {
  if [[ $2 =~ ^files/[0-9]+$ ]] && [[ -e $1/$2 || -L $1/$2 ]]; then return 0; fi
  log_warn "backup copy $2 missing in $1"
  return 1
}

# _restore_copy SRC DEST: atomically replace DEST with a copy of SRC (mode, symlink kept).
_restore_copy() {
  local src=$1 dest=$2 tmp
  tmp=$(mktemp "${dest%/*}/.tnu.tmp.XXXXXXXX") || return 1
  if ! cp -P --preserve=mode,timestamps --remove-destination -- "$src" "$tmp" ||
    ! mv -fT -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# _drifted PATH|KEY CURRENT INSTALLED: warn and succeed when CURRENT != INSTALLED.
_drifted() {
  if [[ $2 == "$3" ]]; then return 1; fi
  log_warn "kept $1 (changed since install)"
}

_replay_file() {
  local dir=$1 path=$3 ref=$4 sha=$5 cur
  cur=$(_current_sha "$path")
  if [[ $cur == ABSENT && $ref == ABSENT ]]; then return 0; fi
  if _drifted "$path" "$cur" "$sha"; then return 0; fi
  if [[ $ref == ABSENT ]]; then
    run rm -f -- "$path" || return 1
    log_info "removed $path"
    return 0
  fi
  _backup_ref_ok "$dir" "$ref" || return 1
  run _restore_copy "$dir/$ref" "$path" || return 1
  log_info "restored $path"
}

_need_system() {
  if [[ ${SYSTEM:-0} == 1 ]]; then return 0; fi
  log_warn "skipped $1: rerun with --system to undo it"
  return 1
}

_replay_sysfile() {
  local dir=$1 path=$3 ref=$4 sha=$5 cur src mode
  cur=$(_current_sha "$path")
  if [[ $cur == ABSENT && $ref == ABSENT ]]; then return 0; fi
  if _drifted "$path" "$cur" "$sha"; then return 0; fi
  _need_system "$path" || return 1
  if [[ $ref == ABSENT ]]; then
    as_root rm -f -- "$path" || return 1
    log_info "removed $path"
    return 0
  fi
  _backup_ref_ok "$dir" "$ref" || return 1
  src=$dir/$ref
  if [[ -L $src ]]; then
    as_root ln -sfnT -- "$(readlink -- "$src")" "$path" || return 1
  else
    mode=$(stat -c %a -- "$src") || return 1
    as_root install -m "$mode" -- "$src" "$path" || return 1
  fi
  log_info "restored $path"
}

_replay_dconf() {
  local key=$3 old=$4 new=$5 cur
  cur=$(dget "$key") || return 1
  if _drifted "$key" "$cur" "$new"; then return 0; fi
  if [[ $old == UNSET ]]; then
    dconf_run reset "$key" || return 1
  else
    dconf_run write "$key" "$old" || return 1
  fi
  log_info "restored $key"
}

# _rm_ok PATH: reject obviously wrong recursive-removal targets.
_rm_ok() {
  local p=$1
  if [[ $p != /?* || $p == */ || $p == *"/.."* || $p == "${HOME%/}" || $p == "${SYS_ROOT:-/}" ]]; then
    log_warn "refusing to remove $p"
    return 1
  fi
}

# _rm_tree PATH: rm -rf PATH (guarded).
_rm_tree() {
  local p=$1
  _rm_ok "$p" || return 1
  if [[ ! -e $p && ! -L $p ]]; then return 0; fi
  run rm -rf -- "$p" || return 1
  log_info "removed $p"
}

_dir_empty() {
  local first
  first=$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) || return 1
  [[ -z $first ]]
}

_replay_dir() {
  local purge=$2 path=$3
  if [[ -L $path || ! -d $path ]]; then return 0; fi
  if _dir_empty "$path"; then
    run rmdir -- "$path" || return 1
    log_info "removed $path"
  elif [[ $purge == 1 && -n ${_replay_pkg_paths["$path"]:-} ]]; then
    _rm_tree "$path" || return 1
  else
    log_info "kept non-empty dir $path"
  fi
}

_replay_pkg() {
  local purge=$2 kind=$3 name=$4
  if [[ $purge != 1 ]]; then
    log_info "kept $kind $name (use --purge to remove)"
    return 0
  fi
  case $kind in
    flatpak)
      if have_cmd flatpak && flatpak info --user "$name" >/dev/null 2>&1; then
        run flatpak uninstall --user -y --noninteractive "$name" || return 1
        log_info "uninstalled flatpak $name"
      fi
      ;;
    fontdir)
      _rm_tree "$name" || return 1
      if have_cmd fc-cache; then run fc-cache -f >/dev/null 2>&1 || true; fi
      ;;
    bin)
      if [[ -e $name || -L $name ]]; then
        run rm -f -- "$name" || return 1
        log_info "removed $name"
      fi
      ;;
    sysdir)
      if [[ -e $name || -L $name ]]; then
        _rm_ok "$name" || return 1
        _need_system "$name" || return 1
        as_root rm -rf -- "$name" || return 1
        log_info "removed $name"
      fi
      ;;
    *)
      log_warn "unknown pkg kind '$kind' for $name (left as is)"
      ;;
  esac
}

_replay_alt() {
  local name=$3 path=$4
  _need_system "alternative $name -> $path" || return 1
  as_root update-alternatives --remove "$name" "$path" || return 1
  log_info "removed alternative $name -> $path"
}
