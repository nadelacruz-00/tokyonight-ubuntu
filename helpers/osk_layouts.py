#!/usr/bin/env python3
"""Generate Gboard-style QWERTY custom layouts for gjs-osk.

The OSK emits physical keycodes, which the system keymap (for example
us+colemak) then translates. To get QWERTY on screen while the hardware
keyboard stays on another layout, each QWERTY character is placed using the
physical key that produces it under the active keymap (looked up from gjs-osk's
keycode cache, passed in as a file).

Usage:
  osk_layouts.py merge --keycodes FILE --current LITERAL [--field NAME]

LITERAL is the current `custom-layout` value as dconf prints it (a GVariant
string holding a JSON array of JSON-encoded layouts), or empty when unset.
Prints {"custom_layout": GVARIANT_LITERAL, "split_index": N, "portrait_index":
N+1}; with --field, only that field, unquoted.
"""

import argparse
import json
import sys
import unicodedata

NUM_BUILTIN = 10  # entries in gjs-osk's physicalLayouts.json
TAG = "gboard-qwerty"  # name prefix: older generated layouts are replaced
# Several physical keys can produce the same plain character ('-' on KPSU and
# LSGT, '=' on KPEQ, '/' on KPDV). Prefer the main-block key so Shift gives its
# shifted symbol ('/' -> '?'); keypad keys and the ISO extra key go last.
SECONDARY = ("KP", "LSGT")


class LayoutError(ValueError):
    pass


def char_map(keycodes):
    """Plain character -> physical key name, for the main-block keys first."""
    out = {}
    for name in sorted(keycodes, key=lambda n: n.startswith(SECONDARY)):
        out.setdefault(keycodes[name]["layers"]["default"], name)
    return out


def build(keycodes):
    """Return (landscape, portrait) layouts as JSON-ready lists."""
    char_to_key = char_map(keycodes)

    def k(spec, w=None, h=None):
        """A key by QWERTY character or by raw keycode name (ESC, SPCE, ...)."""
        if spec in keycodes or spec in ("SETTINGS", "CLOSE"):
            name = spec
        elif spec in char_to_key:
            name = char_to_key[spec]
        else:
            raise LayoutError(f"keymap has no key for {spec!r}")
        out = {"key": name}
        if w is not None:
            out["width"] = w
        if h is not None:
            out["height"] = h
        return out

    def keys(chars):
        return [k(c) for c in chars]

    def gap(w):
        return {"width": w}

    split = {"split": True}
    updown = [k("UP", 1, 0.5), k("DOWN", 1, 0.5)]

    # Landscape: split, each half 8 units wide. The left half's inner edge is
    # ragged like Gboard; the right half is flush so it shows no gaps.
    landscape = [
        # short toolbar row (row 0 renders at 3/4 height)
        [k("ESC", 2), *[k(f"FK0{i}") for i in range(1, 7)], split, *[k(f"FK{i:02}") for i in range(7, 13)], k("["), k("]")],
        [k("`", 1.5), *keys("12345"), gap(1.5), split, *keys("67890-="), k("\\")],
        [k("TAB", 1.5), *keys("qwert"), gap(1.5), split, *keys("yuiop"), k("BKSP", 3)],
        [k("LCTL", 2), *keys("asdfg"), gap(1), split, *keys("hjkl;'"), k("RTRN", 2)],
        [k("LFSH", 2.5), *keys("zxcv"), gap(1.5), split, *keys("bnm,./"), k("RTSH", 2)],
        [k("SETTINGS"), k("LWIN"), k("LALT"), k("SPCE", 4.5), gap(0.5), split, k("SPCE", 3), k("DELE"), k("LEFT"), updown, k("RGHT"), k("CLOSE")],
        {"split": True, "settings": False, "close": False, "topbar": False, "name": TAG + "-split"},
    ]

    # Portrait: single 10-unit block, Gboard rows plus a desktop toolbar and number row.
    portrait = [
        [k("ESC"), k("TAB"), k("LCTL"), k("LALT"), k("LWIN"), k("LEFT"), k("UP"), k("DOWN"), k("RGHT"), k("CLOSE")],
        keys("1234567890"),
        keys("qwertyuiop"),
        keys("asdfghjkl;"),
        [k("LFSH", 1.5), *keys("zxcvbnm"), k("BKSP", 1.5)],
        [k("-"), k("'"), k(","), k("SPCE", 3.5), k("."), k("/"), k("RTRN", 1.5)],
        {"split": False, "settings": False, "close": False, "topbar": False, "name": TAG + "-portrait"},
    ]
    return landscape, portrait


_ESC = {"a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v"}
_UNESC = {7: "a", 8: "b", 12: "f", 10: "n", 13: "r", 9: "t", 11: "v"}


def parse_gv_string(literal):
    """Parse a GVariant string literal ('..' or "..") into text."""
    s = literal.strip()
    if s.startswith("@s"):
        s = s[2:].strip()
    if len(s) < 2 or s[0] not in "'\"":
        raise LayoutError(f"not a GVariant string: {literal[:40]!r}")
    q = s[0]
    out = []
    i = 1
    while i < len(s):
        c = s[i]
        if c == "\\":
            e = s[i + 1 : i + 2]
            if e in _ESC:
                out.append(_ESC[e])
                i += 2
            elif e == "u":
                out.append(chr(int(s[i + 2 : i + 6], 16)))
                i += 6
            elif e == "U":
                out.append(chr(int(s[i + 2 : i + 10], 16)))
                i += 10
            else:
                out.append(e)
                i += 2
        elif c == q:
            if s[i + 1 :].strip():
                raise LayoutError("trailing data after string")
            return "".join(out)
        else:
            out.append(c)
            i += 1
    raise LayoutError("unterminated string")


def gv_string(text):
    """Print text the way GLib's g_variant_print does for a string."""
    q = '"' if "'" in text else "'"
    out = [q]
    for ch in text:
        c = ord(ch)
        if ch == q or ch == "\\":
            out.append("\\")
        if unicodedata.category(ch) not in ("Cc", "Cf", "Cn", "Cs"):
            out.append(ch)
        elif c in _UNESC:
            out.append("\\" + _UNESC[c])
        elif c < 0x10000:
            out.append(f"\\u{c:04x}")
        else:
            out.append(f"\\U{c:08x}")
    out.append(q)
    return "".join(out)


def layout_name(entry):
    """The options name of a JSON-encoded layout ('' when it has none)."""
    try:
        opts = json.loads(entry)[-1]
    except (ValueError, IndexError, TypeError, KeyError):
        return ""
    return opts.get("name", "") if isinstance(opts, dict) else ""


def merge(keycodes, current):
    """Replace our layouts in the current custom-layout; keep everything else."""
    if current.strip() == "":
        existing = []
    else:
        try:
            existing = json.loads(parse_gv_string(current))
        except ValueError as exc:
            raise LayoutError(f"cannot parse current custom-layout: {exc}") from exc
        if not isinstance(existing, list) or not all(isinstance(e, str) for e in existing):
            raise LayoutError("custom-layout is not a JSON array of strings")
    landscape, portrait = build(keycodes)
    keep = [e for e in existing if not layout_name(e).startswith(TAG)]
    layouts = [*keep, json.dumps(landscape), json.dumps(portrait)]
    return {
        # compact outer array, as gjs-osk itself writes it (JSON.stringify)
        "custom_layout": gv_string(json.dumps(layouts, separators=(",", ":"))),
        "split_index": NUM_BUILTIN + len(keep),
        "portrait_index": NUM_BUILTIN + len(keep) + 1,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("merge", help="merge our layouts into the current custom-layout")
    m.add_argument("--keycodes", required=True, help="gjs-osk keycode cache JSON for the active keymap")
    m.add_argument("--current", default="", help="current custom-layout GVariant literal, or empty")
    m.add_argument("--field", choices=["custom_layout", "split_index", "portrait_index"])
    args = ap.parse_args(argv)
    try:
        with open(args.keycodes, encoding="utf-8") as fh:
            keycodes = json.load(fh)
        result = merge(keycodes, args.current)
    except (OSError, ValueError, KeyError) as exc:
        print(f"osk_layouts: {exc}", file=sys.stderr)
        return 1
    if args.field:
        print(result[args.field])
    else:
        print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
