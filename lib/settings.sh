#!/usr/bin/env bash
# shellcheck shell=bash
# dconf settings by key path, recorded in the backup manifest so uninstall can
# restore (or reset) them. Values are canonical GVariant literals.
# Without a session bus, dconf runs under `dbus-run-session` and a one-time
# warning says a re-login is needed.
# Sourced, never executed; safe to source twice; sets no shell options.
# Globals read: DBUS_SESSION_BUS_ADDRESS DRY_RUN RUN_DIR.

: "${_TNU_NOBUS_WARNED:=0}"

# Warn once per run; the marker in RUN_DIR also covers subshells such as $(dget ...).
_nobus_warn_once() {
  local marker=""
  if [[ -n ${RUN_DIR:-} && -d $RUN_DIR ]]; then marker=$RUN_DIR/.nobus-warned; fi
  if [[ $_TNU_NOBUS_WARNED == 1 || (-n $marker && -e $marker) ]]; then return 0; fi
  _TNU_NOBUS_WARNED=1
  if [[ -n $marker ]]; then : >"$marker" || true; fi
  log_warn "no session bus: log out and back in to see changes"
}

# _dconf ARGS...: dconf, under a private bus when there is no session bus.
_dconf() {
  if [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} ]]; then
    _nobus_warn_once
    dbus-run-session -- dconf "$@"
  else
    dconf "$@"
  fi
}

# dconf_run ARGS...: a changing dconf call (write/reset) that honours dry-run.
dconf_run() {
  if _dry; then
    log_dry "dconf $(_quote_cmd "$@")"
    return 0
  fi
  _dconf "$@"
}

_dconf_key() {
  if [[ $1 != /?* || $1 == */ || $1 == *[$'\t\n ']* ]]; then die "bad dconf key: $1"; fi
}

# dget KEY: print KEY's value, or nothing when unset.
dget() {
  _dconf_key "$1"
  _dconf read "$1"
}

# dset KEY VALUE: set KEY to the GVariant literal VALUE unless it already is.
# VALUE should be canonical (as `dconf read` prints it; gv_str output is).
# The row is recorded before the write (crash safety). After a real write the
# value is read back; if dconf canonicalised it differently, a second row with
# the same OLD and the read-back as NEW is appended, which supersedes the first
# on replay. Dry-run compares VALUE only and records nothing.
dset() {
  local key=$1 value=$2 cur rb
  _dconf_key "$key"
  if [[ -z $value ]]; then die "dset: empty value for $key"; fi
  cur=$(dget "$key") || die "cannot read $key"
  if [[ $cur == "$value" ]]; then
    log_debug "unchanged $key"
    return 0
  fi
  backup_record dconf "$key" "${cur:-UNSET}" "$value"
  dconf_run write "$key" "$value" || die "dconf write failed for $key"
  if _dry; then
    note_change "set $key $value"
    return 0
  fi
  rb=$(dget "$key") || die "cannot read back $key"
  if [[ -z $rb ]]; then die "dconf did not store $key"; fi
  if [[ $rb != "$value" ]]; then
    log_warn "dconf stores $key as $rb, not $value (pass canonical literals, e.g. from gv_str)"
    backup_record dconf "$key" "${cur:-UNSET}" "$rb"
  fi
  if [[ $rb == "$cur" ]]; then
    log_debug "unchanged $key (same value once canonicalised)"
    return 0
  fi
  note_change "set $key $rb"
  log_info "set $key = $rb"
}

# GLib's g_variant_print rules for one string, for text with non-ASCII or
# control characters (needs Unicode categories).
_TNU_GV_STR_PY='
import sys, unicodedata
s = sys.argv[1]
try:
    s.encode("utf-8")
except UnicodeEncodeError:
    sys.exit("error: gv_str: text is not valid UTF-8")
q = "\"" if "\x27" in s else "\x27"
esc = {7: "a", 8: "b", 12: "f", 10: "n", 13: "r", 9: "t", 11: "v"}
out = [q]
for ch in s:
    c = ord(ch)
    if ch == q or ch == "\\":
        out.append("\\")
    if unicodedata.category(ch) not in ("Cc", "Cf", "Cn", "Cs"):
        out.append(ch)
    elif c in esc:
        out.append("\\" + esc[c])
    elif c < 0x10000:
        out.append("\\u%04x" % c)
    else:
        out.append("\\U%08x" % c)
out.append(q)
sys.stdout.buffer.write(("".join(out) + "\n").encode("utf-8"))
'

# gv_str TEXT: TEXT as GLib prints a GVariant string (the form `dconf read`
# returns): double quotes when TEXT contains ' (escaping \ and "), otherwise
# single quotes (escaping \ and '); non-printables as \n, \t, ..., \uXXXX.
gv_str() {
  local s=${1-} q="'" LC_ALL=C
  if [[ $s == *[![:print:]]* ]]; then
    python3 -I -c "$_TNU_GV_STR_PY" "$s" || die "gv_str: cannot encode text"
    return 0
  fi
  if [[ $s == *"'"* ]]; then q='"'; fi
  s=${s//\\/\\\\}
  s=${s//"$q"/\\$q}
  printf '%s%s%s\n' "$q" "$s" "$q"
}
