#!/usr/bin/env bash
# shellcheck shell=bash
# Core helpers: die, commands, dry-run aware run, change notes, atomic writes,
# verified downloads, root actions.
# Sourced, never executed; safe to source twice; sets no shell options.
# Globals read: DRY_RUN SYSTEM OFFLINE MODULE RUN_DIR CACHE_DIR TNU_ROOT SYS_ROOT
# TNU_CHECKSUMS (override for assets/checksums.sha256).
# Functions here never rely on errexit: each failure is handled explicitly, so
# they behave the same when called from an `if` or `||` context.

# die MSG [CODE=1]
die() {
  log_error "${1:-fatal error}"
  exit "${2:-1}"
}

have_cmd() {
  command -v -- "$1" >/dev/null 2>&1
}

# require_cmd NAME...: die 3 listing every missing command.
require_cmd() {
  local c missing=()
  for c in "$@"; do
    if ! have_cmd "$c"; then missing+=("$c"); fi
  done
  if ((${#missing[@]})); then
    local IFS=' '
    die "missing required commands: ${missing[*]}" 3
  fi
}

_dry() {
  [[ ${DRY_RUN:-0} == 1 ]]
}

# _quote_cmd CMD...: shell-quoted command line for log messages.
_quote_cmd() {
  local s
  s=$(printf '%q ' "$@")
  printf '%s' "${s% }"
}

# run CMD...: execute, or in dry-run only log it and return 0.
run() {
  if _dry; then
    log_dry "$(_quote_cmd "$@")"
    return 0
  fi
  log_debug "run: $(_quote_cmd "$@")"
  "$@"
}

# note_change DESC: append "MODULE<TAB>DESC" to $RUN_DIR/changes (also in dry-run).
note_change() {
  local desc=${1//[$'\t\n']/ }
  printf '%s\t%s\n' "${MODULE:-}" "$desc" >>"${RUN_DIR:?RUN_DIR not set}/changes"
  log_debug "change: $desc"
}

# module_changes MODULE: number of note_change calls for MODULE this run.
module_changes() {
  local want=$1 m _rest n=0 f=${RUN_DIR:?RUN_DIR not set}/changes
  if [[ -f $f ]]; then
    while IFS=$'\t' read -r m _rest; do
      if [[ $m == "$want" ]]; then n=$((n + 1)); fi
    done <"$f"
  fi
  printf '%s\n' "$n"
}

# sha256_of FILE: bare hex digest (read via stdin so odd names are not escaped).
sha256_of() {
  local out
  out=$(sha256sum <"$1") || return 1
  printf '%s\n' "${out%% *}"
}

# _abs_path PATH: die unless PATH is absolute (manifest rows must be replayable from anywhere).
_abs_path() {
  if [[ $1 != /* ]]; then die "not an absolute path: $1"; fi
}

# _octal_mode MODE: validate an octal mode and print it without leading zeros.
_octal_mode() {
  if [[ ! $1 =~ ^[0-7]{3,4}$ ]]; then die "invalid file mode: $1"; fi
  printf '%o\n' "$((8#$1))"
}

# _ensure_parent_dirs PATH: create missing parents of PATH, outermost first,
# recording each one with `backup_record dir` before creating it.
_ensure_parent_dirs() {
  local d=${1%/*} missing=() i
  while [[ -n $d && ! -d $d ]]; do
    missing=("$d" "${missing[@]}")
    d=${d%/*}
  done
  for i in "${missing[@]}"; do
    backup_record dir "$i" || return 1
    mkdir -- "$i" || return 1
  done
}

# atomic_write DEST [MODE]: stdin -> temp file in DEST's dir -> mv over DEST.
# Without MODE keeps DEST's existing mode (new files: 0666 & ~umask).
atomic_write() {
  local dest=$1 mode=${2:-} dir tmp
  _abs_path "$dest"
  if [[ -n $mode ]]; then mode=$(_octal_mode "$mode") || return 1; fi
  if _dry; then
    cat >/dev/null
    log_dry "write $dest"
    return 0
  fi
  _ensure_parent_dirs "$dest" || return 1
  dir=${dest%/*}
  dir=${dir:-/}
  if [[ -z $mode ]]; then
    if [[ -e $dest ]]; then
      mode=$(stat -L -c %a -- "$dest") || return 1
    else
      mode=$(printf '%o' "$((0666 & ~8#$(umask)))")
    fi
  fi
  tmp=$(mktemp "$dir/.tnu.tmp.XXXXXXXX") || return 1
  # fsync the content before the rename so a crash never leaves an empty DEST.
  if ! cat >"$tmp" || ! chmod "$mode" -- "$tmp" || ! sync -- "$tmp" ||
    ! mv -fT -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    log_error "failed to write $dest"
    return 1
  fi
}

# _same_file SRC DEST [MODE]: DEST already has SRC's content (and MODE, if given).
_same_file() {
  local src=$1 dest=$2 mode=${3:-}
  [[ -f $dest ]] || return 1
  cmp -s -- "$src" "$dest" || return 1
  if [[ -n $mode ]]; then
    local want
    want=$(_octal_mode "$mode") || return 1
    [[ $(stat -L -c %a -- "$dest") == "$want" ]] || return 1
  fi
}

# install_file SRC DEST [MODE]: no-op when content (and MODE) already match;
# else back up DEST, record it, write atomically and note the change.
install_file() {
  local src=$1 dest=$2 mode=${3:-} sha
  _abs_path "$dest"
  if [[ ! -f $src ]]; then die "install_file: no such file: $src"; fi
  if [[ -n $mode ]]; then _octal_mode "$mode" >/dev/null; fi
  if _same_file "$src" "$dest" "$mode"; then
    log_debug "unchanged $dest"
    return 0
  fi
  if _dry; then
    log_dry "install $dest"
    note_change "install $dest"
    return 0
  fi
  sha=$(sha256_of "$src") || die "cannot read $src"
  # Parent dir rows must precede the file row so reverse replay removes the
  # file before trying the (then empty) dirs.
  _ensure_parent_dirs "$dest" || die "cannot create parent dirs of $dest"
  backup_file "$dest" "$sha"
  atomic_write "$dest" "$mode" <"$src" || die "cannot write $dest"
  note_change "install $dest"
  log_info "installed $dest"
}

# write_file DEST [MODE]: install_file with stdin as the source.
write_file() {
  local dest=$1 mode=${2:-} tmp rc=0
  tmp=$(mktemp "${RUN_DIR:?RUN_DIR not set}/write.XXXXXXXX") || die "mktemp failed"
  if ! cat >"$tmp"; then
    rm -f -- "$tmp"
    die "cannot read stdin for $dest"
  fi
  install_file "$tmp" "$dest" "$mode" || rc=$?
  rm -f -- "$tmp"
  return "$rc"
}

# _checksum_entry NAME: print "SHA URL" for NAME from the checksum file.
# Lines: "<sha256>  <name>  <url>" (downloads) or "<sha256>  <relpath>" (vendored, ignored).
_checksum_entry() {
  local name=$1 sums=${TNU_CHECKSUMS:-${TNU_ROOT:?TNU_ROOT not set}/assets/checksums.sha256}
  local s n u _rest
  if [[ ! -r $sums ]]; then die "checksum file not readable: $sums"; fi
  while IFS=' ' read -r s n u _rest || [[ -n $s ]]; do
    if [[ $s != \#* && $n == "$name" && -n $u ]]; then
      printf '%s %s\n' "$s" "$u"
      return 0
    fi
  done <"$sums"
  die "no download entry for $name in $sums"
}

# TNU_DRY_NOT_CACHED: download_verified's status in dry-run when NAME is not cached.
TNU_DRY_NOT_CACHED=10

# download_verified NAME: echo the path of a cached, checksum-verified copy of NAME.
# Contract:
#   status 0  -> stdout is the cached path (verified against the checksum file).
#   status 10 ($TNU_DRY_NOT_CACHED) -> DRY_RUN=1 and no valid cached copy: logs
#             "[dry-run] download ...", prints nothing, downloads nothing. Callers
#             in dry-run should note_change instead of using the file.
#   otherwise it dies (status 1): unknown NAME, bad checksum entry, OFFLINE=1
#             without a valid cache, download failure, "checksum mismatch for NAME".
download_verified() {
  local name=$1 entry sha url cache tmp
  if [[ ! $name =~ ^[A-Za-z0-9._+-]+$ || $name == . || $name == .. ]]; then
    die "download_verified: bad name: $name"
  fi
  entry=$(_checksum_entry "$name") || exit 1
  sha=${entry%% *}
  url=${entry#* }
  if [[ ! $sha =~ ^[0-9a-f]{64}$ ]]; then die "bad checksum for $name: $sha"; fi
  cache=${CACHE_DIR:?CACHE_DIR not set}/$name
  if [[ -f $cache ]]; then
    if [[ $(sha256_of "$cache") == "$sha" ]]; then
      log_debug "using cached $cache"
      printf '%s\n' "$cache"
      return 0
    fi
    log_warn "cached $name does not match its checksum; downloading again"
  fi
  if [[ ${OFFLINE:-0} == 1 ]]; then die "$name is not cached and --offline is set"; fi
  if _dry; then
    log_dry "download $name from $url"
    return "$TNU_DRY_NOT_CACHED"
  fi
  mkdir -p -- "$CACHE_DIR" || die "cannot create $CACHE_DIR"
  tmp=$(mktemp "$CACHE_DIR/.$name.part.XXXXXXXX") || die "mktemp failed in $CACHE_DIR"
  log_info "downloading $url"
  if ! curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -o "$tmp" "$url"; then
    rm -f -- "$tmp"
    die "download failed for $name ($url)"
  fi
  if [[ $(sha256_of "$tmp") != "$sha" ]]; then
    rm -f -- "$tmp" "$cache"
    die "checksum mismatch for $name"
  fi
  if ! mv -fT -- "$tmp" "$cache"; then
    rm -f -- "$tmp"
    die "cannot move download into $cache"
  fi
  printf '%s\n' "$cache"
}

# as_root CMD...: run CMD via sudo; refused unless --system (SYSTEM=1).
as_root() {
  if [[ ${SYSTEM:-0} != 1 ]]; then die "needs --system: $(_quote_cmd "$@")"; fi
  run sudo -- "$@"
}

# apt_install PKG...: `apt-get install -y PKG...` via as_root, after one
# `apt-get update` per run (flag file in RUN_DIR, as modules run in subshells).
# A failed update only warns: the install may still work from current lists.
apt_install() {
  local flag=${RUN_DIR:?RUN_DIR not set}/apt-updated
  if [[ ! -e $flag ]]; then
    as_root apt-get update || log_warn "apt-get update failed; installing from the current package lists"
    : >"$flag" || die "cannot write $flag"
  fi
  as_root apt-get install -y "$@"
}

# sys_path PATH: PATH under SYS_ROOT (empty outside tests).
sys_path() {
  printf '%s\n' "${SYS_ROOT:-}$1"
}
