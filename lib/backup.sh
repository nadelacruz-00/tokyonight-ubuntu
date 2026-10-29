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
#   line    FILE  MATCH_REGEX  OLD_LINE|ABSENT  NEW_LINE  SECTION   (handler in lib/edit.sh;
#           the last four fields are escaped with _tnu_esc; SECTION empty = none)
#
# Row TYPE is replayed by the function `_replay_TYPE DIR PURGE FIELD...`
# (DIR = backup dir, FIELD... = the row's fields after TYPE). Handlers may be
# defined in any sourced file. They run in an `||` context, so errexit is off
# inside them: check every command and `return 1` on failure (2 = deferred, see
# backup_replay). Use `run` / `as_root` / `dconf_run` so dry-run is honoured.
# Rows whose last field is TORN were cut by a crash and are never replayed.
#
# Drift rule: file/sysfile/dconf/line rows restore only when the current value
# still equals the one we installed; otherwise log_warn "kept X (changed since install)".
#
# Sourced, never executed; safe to source twice; sets no shell options.
# Globals read: STATE_DIR RUN_ID DRY_RUN SYSTEM HOME SYS_ROOT.

# backup_dir: create (on first use) and echo this run's backup dir. manifest.tsv
# appears with the first row, so a dir without rows is never listed or replayed.
backup_dir() {
  local d=${STATE_DIR:?STATE_DIR not set}/backups/${RUN_ID:?RUN_ID not set}
  if [[ ! -d $d ]]; then
    (umask 077 && mkdir -p -- "$d") || die "cannot create backup dir $d"
  fi
  printf '%s\n' "$d"
}

# _backup_append FILE LINE: append LINE (+ newline) and sync. A torn last line
# (no trailing newline, e.g. after SIGKILL) is first terminated with a poison
# field, TAB TORN, so it can never be read back as a well-formed row.
_backup_append() {
  local f=$1 line=$2
  if [[ ! -e $f ]]; then
    (umask 077 && : >>"$f") || return 1
  fi
  if [[ -s $f && -n $(tail -c 1 -- "$f") ]]; then
    printf '\tTORN\n' >>"$f" || return 1
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
  if [[ ${!#} == TORN ]]; then die "backup_record: last field may not be TORN"; fi
  if _dry; then return 0; fi
  dir=$(backup_dir) || exit 1
  _backup_append "$dir/manifest.tsv" "$(_join_tab "$@")" || die "cannot write $dir/manifest.tsv"
}

# backup_copy PATH: copy PATH into this run's files/N (fsynced) and echo
# "files/N", or echo ABSENT when PATH does not exist. Symlinks stay symlinks.
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
  if [[ ! -L $dir/files/$n ]]; then
    sync -- "$dir/files/$n" || die "cannot sync backup of $path"
  fi
  printf 'files/%s\n' "$n"
}

# _backup_index_get DIR PATH: echo the files/N|ABSENT ref already taken for PATH this run.
_backup_index_get() {
  local p r rest
  [[ -f $1/files.idx ]] || return 1
  while IFS=$'\t' read -r p r rest; do
    if [[ $p == "$2" && -z $rest && $r =~ ^(files/[0-9]+|ABSENT)$ ]]; then
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

# backup_list: backup dirs with a non-empty manifest, newest first, excluding .restored.
backup_list() {
  local root=${STATE_DIR:?STATE_DIR not set}/backups d dirs=()
  [[ -d $root ]] || return 0
  for d in "$root"/*/; do
    d=${d%/}
    if [[ ${d##*/} != .restored && -s $d/manifest.tsv ]]; then dirs+=("$d"); fi
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
    line) echo 5 ;;
    *) echo any ;;
  esac
}

# _replay_mark DIR LINENO: remember that manifest line LINENO is undone.
_replay_mark() {
  if _dry; then return 0; fi
  _backup_append "$1/replayed" "$2" || log_warn "cannot write $1/replayed"
}

# backup_replay DIR [PURGE=0]: undo DIR's manifest rows, newest first.
# Each undone row's line number is appended to DIR/replayed, and rows listed
# there are skipped, so a partial replay (e.g. system rows without --system)
# can be finished later without touching the rows already undone.
# Handler status: 0 = done (recorded), 1 = failed / still pending,
# 2 = deliberately deferred (pkg without PURGE: not recorded, not a failure).
# Returns 0 only when every row is done or deferred; else 1.
backup_replay() {
  local dir=${1:?backup_replay: DIR required} purge=${2:-0} m line type want key i n st rc=0
  local -a rows=() nums=() F=()
  local -A _replay_seen=() _replay_pkg_paths=() _replay_dir_paths=() _replay_done=() _replay_dconf_old=()
  m=$dir/manifest.tsv
  if [[ ! -f $m ]]; then
    log_error "no manifest in $dir"
    return 1
  fi
  # A torn last line (no newline) is never read: its change never happened.
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    if [[ -n $line ]]; then
      rows+=("$line")
      nums+=("$n")
    fi
  done <"$m"
  if [[ -f $dir/replayed ]]; then
    while IFS= read -r line; do
      if [[ $line =~ ^[0-9]+$ ]]; then _replay_done["$line"]=1; fi
    done <"$dir/replayed"
  fi
  for line in "${rows[@]}"; do
    _split_tab "$line"
    if [[ ${F[-1]} == TORN || ${#F[@]} -lt 2 ]]; then continue; fi
    if [[ ${F[0]} == pkg && ${#F[@]} -eq 3 ]]; then _replay_pkg_paths["${F[2]}"]=1; fi
    if [[ ${F[0]} == dir && ${#F[@]} -eq 2 ]]; then _replay_dir_paths["${F[1]}"]=1; fi
  done
  for ((i = ${#rows[@]} - 1; i >= 0; i--)); do
    n=${nums[i]}
    _split_tab "${rows[i]}"
    type=${F[0]}
    want=$(_backup_row_arity "$type")
    if [[ ${F[-1]} == TORN ]]; then
      log_warn "skipping torn row $n in $m"
      _replay_mark "$dir" "$n"
      continue
    fi
    if [[ ! $type =~ ^[a-z]+$ || ($want != any && $want != $((${#F[@]} - 1))) || -z ${F[1]:-} ]]; then
      log_warn "skipping malformed row $n in $m: ${rows[i]//$'\t'/ | }"
      _replay_mark "$dir" "$n"
      continue
    fi
    # Superseded rows (bookkeeping runs even for rows already undone):
    # - a path written twice in one run shares one original: only its newest row counts;
    # - dset's pre-write row is followed by its read-back row with the same OLD.
    key="$type ${F[1]}"
    if [[ $type == file || $type == sysfile ]]; then
      if [[ -n ${_replay_seen["$key"]:-} ]]; then
        _replay_mark "$dir" "$n"
        continue
      fi
      _replay_seen["$key"]=1
    elif [[ $type == dconf ]]; then
      if [[ -n ${_replay_dconf_old["$key"]+x} && ${_replay_dconf_old["$key"]} == "${F[2]}" ]]; then
        _replay_mark "$dir" "$n"
        continue
      fi
      _replay_dconf_old["$key"]=${F[2]}
    fi
    if [[ -n ${_replay_done["$n"]:-} ]]; then continue; fi
    if ! declare -F "_replay_$type" >/dev/null; then
      log_warn "unsupported row type '$type' in $m (left as is)"
      rc=1
      continue
    fi
    st=0
    "_replay_$type" "$dir" "$purge" "${F[@]:1}" || st=$?
    case $st in
      0) _replay_mark "$dir" "$n" ;;
      2) ;;
      *)
        log_warn "could not undo $type ${F[1]}"
        rc=1
        ;;
    esac
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

# _rm_ok PATH: PATH is a sane recursive-removal target that this manifest
# created (it has a `dir` row). Only valid inside backup_replay.
_rm_ok() {
  local p=$1
  if [[ $p != /?* || $p == */ || $p == *"/.."* || $p == "${HOME%/}" || $p == "${SYS_ROOT:-/}" ]]; then
    log_warn "refusing to remove $p"
    return 1
  fi
  if [[ -z ${_replay_dir_paths["$p"]:-} ]]; then
    log_warn "kept $p (not created by this install: no dir row)"
    return 1
  fi
}

# _as_owner PATH CMD...: run CMD directly, or via as_root when PATH's parent
# is not writable (system dirs); without --system that is reported as pending.
_as_owner() {
  local p=$1 parent
  shift
  parent=${p%/*}
  parent=${parent:-/}
  if [[ -w $parent ]]; then
    run "$@"
  else
    _need_system "$p" || return 1
    as_root "$@"
  fi
}

# _rm_tree PATH: rm -rf PATH, only when _rm_ok. A refused target is reported
# and counts as done (it can never become removable).
_rm_tree() {
  local p=$1
  if [[ ! -e $p && ! -L $p ]]; then return 0; fi
  _rm_ok "$p" || return 0
  _as_owner "$p" rm -rf -- "$p" || return 1
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
    _as_owner "$path" rmdir -- "$path" || return 1
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
    return 2
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
      _rm_tree "$name" || return 1
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
