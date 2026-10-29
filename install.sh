#!/usr/bin/env bash
# tokyonight-ubuntu: reproduce the Rewaita Tokyo Night GNOME desktop on
# Ubuntu 26.04 aarch64. Idempotent; every change is recorded so --uninstall
# can undo it. Run ./install.sh --help for the options.
set -Eeuo pipefail
shopt -s inherit_errexit
IFS=$'\n\t'
umask 022

_tnu_self=${BASH_SOURCE[0]}
if [[ $_tnu_self != */* ]]; then _tnu_self=./$_tnu_self; fi
TNU_ROOT=$(cd -- "${_tnu_self%/*}" && pwd -P)
unset _tnu_self
export TNU_ROOT

for _tnu_lib in "$TNU_ROOT"/lib/*.sh; do
  # shellcheck source=/dev/null
  source "$_tnu_lib"
done
unset _tnu_lib

trap '_tnu_err_trap "$?" "${BASH_SOURCE[0]:-}" "$LINENO" "$BASH_COMMAND"' ERR

usage() {
  local IFS=' ' mods
  mods=$(module_names | grep -vx preflight | tr '\n' ' ' || true)
  cat <<EOF
Usage: install.sh [options]

Reproduce the Rewaita Tokyo Night GNOME desktop on Ubuntu 26.04 (aarch64).
Every change is backed up; --uninstall undoes it.

Options:
  --variant tokyonight|storm   colour variant (default: tokyonight)
  --system                     also run the root-level parts (uses sudo)
  --only a,b                   run only these modules
  --skip a,b                   run every module except these
  --dry-run                    show what would change, change nothing
  --status                     per module: applied, drifted (n) or n/a
  --uninstall                  undo every install, newest first
  --backup TS                  with --uninstall: undo only backup TS
  --purge                      with --uninstall: also remove the flatpak app,
                               fonts and oh-my-posh binary installed by us
  --offline                    use the download cache only
  --strict                     stop at the first module failure
  --force                      continue on an unsupported OS, architecture
                               or desktop
  -y, --yes                    do not ask for confirmation
  -v, --verbose                show debug messages
  -h, --help                   show this help
  --version                    print the version

Modules: ${mods% }

Exit status: 0 ok, 1 a module failed (or the confirmation prompt was
declined), 2 usage error, 3 preflight failed, 4 another install is running,
130 interrupted.
EOF
}

usage_error() {
  log_error "$1"
  printf 'Try: install.sh --help\n' >&2
  exit 2
}

# _add_list VAR VALUE: append comma-separated VALUE to VAR.
_add_list() {
  local -n _ref=$1
  _ref+="${_ref:+,}$2"
}

parse_args() {
  local opt val has
  VARIANT=tokyonight DRY_RUN=0 SYSTEM=0 OFFLINE=0 VERBOSE=0 STRICT=0 FORCE=0 YES=0
  PURGE=0 MODE=apply ONLY="" SKIP="" BACKUP_TS=""
  _opt_only=0 _opt_skip=0 _opt_backup=0 _opt_uninstall=0 _opt_status=0
  while (($#)); do
    opt=$1 val="" has=0
    shift
    if [[ $opt == --*=* ]]; then
      val=${opt#*=}
      opt=${opt%%=*}
      has=1
    fi
    case $opt in
      --variant | --only | --skip | --backup)
        if ((! has)); then
          if (($# == 0)); then usage_error "$opt needs a value"; fi
          val=$1
          shift
        fi
        case $opt in
          --variant) VARIANT=$val ;;
          --only)
            _add_list ONLY "$val"
            _opt_only=1
            ;;
          --skip)
            _add_list SKIP "$val"
            _opt_skip=1
            ;;
          --backup)
            BACKUP_TS=$val
            _opt_backup=1
            ;;
        esac
        continue
        ;;
    esac
    if ((has)); then usage_error "$opt takes no value"; fi
    case $opt in
      --system) SYSTEM=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --status) _opt_status=1 ;;
      --uninstall) _opt_uninstall=1 ;;
      --purge) PURGE=1 ;;
      --offline) OFFLINE=1 ;;
      --strict) STRICT=1 ;;
      --force) FORCE=1 ;;
      -y | --yes) YES=1 ;;
      -v | --verbose) VERBOSE=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      --version)
        printf '%s\n' "$(<"$TNU_ROOT/VERSION")"
        exit 0
        ;;
      -*) usage_error "unknown option: $opt" ;;
      *) usage_error "unexpected argument: $opt" ;;
    esac
  done
}

# _split_names LIST SETVAR: add each name of comma-separated LIST to the
# associative array SETVAR; usage error on an empty entry or unknown module.
_split_names() {
  local n
  local -a names=()
  local -n _set=$2
  IFS=',' read -r -a names <<<"$1"
  if [[ $1 == *, || ${#names[@]} -eq 0 ]]; then usage_error "empty module name in '$1'"; fi
  for n in "${names[@]}"; do
    if [[ -z $n ]]; then usage_error "empty module name in '$1'"; fi
    if ! is_module "$n"; then
      local IFS=' '
      usage_error "unknown module: $n (modules: $(module_names | tr '\n' ' '))"
    fi
    _set["$n"]=1
  done
}

validate_args() {
  local n
  local -A only=() skip=()
  case $VARIANT in
    tokyonight | storm) ;;
    *) usage_error "unknown variant: $VARIANT (use tokyonight or storm)" ;;
  esac
  if ((_opt_only && _opt_skip)); then usage_error "--only and --skip cannot be combined"; fi
  if ((_opt_status && _opt_uninstall)); then usage_error "--status and --uninstall cannot be combined"; fi
  if ((! _opt_uninstall)); then
    if ((PURGE)); then usage_error "--purge only works with --uninstall"; fi
    if ((_opt_backup)); then usage_error "--backup only works with --uninstall"; fi
  elif ((_opt_only || _opt_skip)); then
    usage_error "--only/--skip do not apply to --uninstall (it undoes whole backups)"
  fi
  if ((_opt_backup)); then
    if [[ ! $BACKUP_TS =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then usage_error "bad backup name: $BACKUP_TS"; fi
    if [[ ! -s $STATE_DIR/backups/$BACKUP_TS/manifest.tsv ]]; then
      usage_error "no backup named $BACKUP_TS in $STATE_DIR/backups"
    fi
  fi
  if ((_opt_only)); then _split_names "$ONLY" only; fi
  if ((_opt_skip)); then
    _split_names "$SKIP" skip
    if [[ -n ${skip[preflight]:-} ]]; then usage_error "preflight always runs; it cannot be skipped"; fi
  fi
  TNU_SELECTED=()
  for n in $(module_names); do
    if [[ $n == preflight ]]; then continue; fi
    if ((_opt_only)) && [[ -z ${only[$n]:-} ]]; then continue; fi
    if [[ -n ${skip[$n]:-} ]]; then continue; fi
    TNU_SELECTED+=("$n")
  done
  if ((_opt_uninstall)); then MODE=uninstall; fi
  if ((_opt_status)); then
    MODE=status
    DRY_RUN=1
  fi
}

# new_run_id: UTC timestamp, made unique against earlier backups and logs.
new_run_id() {
  local base id n=1
  base=$(date -u +%Y%m%dT%H%M%SZ)
  id=$base
  while [[ -e $STATE_DIR/backups/$id || -e $STATE_DIR/backups/.restored/$id ||
    -e $STATE_DIR/logs/$id.log ]]; do
    n=$((n + 1))
    id=$(printf '%s-%02d' "$base" "$n")
  done
  printf '%s\n' "$id"
}

# confirm: show the plan and ask, only when interactive and without -y.
confirm() {
  local IFS=' ' ans="" n
  if [[ $YES == 1 || $DRY_RUN == 1 ]] || [[ ! -t 0 || ! -t 2 ]]; then return 0; fi
  if [[ $MODE == uninstall ]]; then
    if [[ -n $BACKUP_TS ]]; then n=1; else n=$(backup_list | wc -l); fi
    printf 'Will undo %s backup(s)%s; purge: %s; system: %s\n' "$n" \
      "${BACKUP_TS:+ ($BACKUP_TS)}" "$( ((PURGE)) && echo yes || echo no)" \
      "$( ((SYSTEM)) && echo yes || echo no)" >&2
  else
    printf 'Will apply: %s\nVariant: %s; system (sudo) changes: %s\n' \
      "${TNU_SELECTED[*]:-(nothing)}" "$VARIANT" "$( ((SYSTEM)) && echo yes || echo no)" >&2
  fi
  read -r -p 'Proceed? [y/N] ' ans || true
  case $ans in
    y | Y | yes | YES | Yes) return 0 ;;
  esac
  log_info "aborted: nothing changed"
  exit 1
}

# shellcheck disable=SC2329 # EXIT trap
_tnu_cleanup() {
  if [[ -n ${RUN_DIR:-} && -d $RUN_DIR ]]; then rm -rf -- "$RUN_DIR"; fi
}

main() {
  : "${HOME:?HOME is not set}"
  STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/tokyonight-ubuntu
  CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/tokyonight-ubuntu
  export MODULE=""
  load_modules "${TNU_MODULES_DIR:-$TNU_ROOT/modules}"
  parse_args "$@"
  validate_args
  export VARIANT DRY_RUN SYSTEM OFFLINE VERBOSE STRICT FORCE YES PURGE MODE STATE_DIR CACHE_DIR

  RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tokyonight-ubuntu.XXXXXXXX")
  export RUN_DIR
  trap _tnu_cleanup EXIT
  trap _tnu_on_signal INT TERM

  run_preflight
  confirm
  if [[ $SYSTEM == 1 && $DRY_RUN == 0 ]]; then
    sudo -v || die "sudo failed: --system needs sudo rights" 3
  fi
  if [[ $DRY_RUN == 0 ]]; then
    acquire_lock
    RUN_ID=$(new_run_id)
    log_init "$STATE_DIR/logs/$RUN_ID.log"
  else
    RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
  fi
  export RUN_ID
  log_debug "run $RUN_ID: mode=$MODE variant=$VARIANT system=$SYSTEM dry-run=$DRY_RUN"

  case $MODE in
    apply) run_modules ;;
    status) run_status ;;
    uninstall) run_uninstall ;;
  esac
  exit "$TNU_RC"
}

main "$@"
