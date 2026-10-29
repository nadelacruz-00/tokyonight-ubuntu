#!/usr/bin/env python3
"""Extract the Tokyo Night palette keys from a Rewaita-style GTK4 CSS file."""

import argparse
import json
import re
import sys

HEX = r"(#[0-9a-fA-F]{6})\b"

# key -> (css custom property, @define-color name)
KEYS = {
    "bg": ("--window-bg-color", "window_bg_color"),
    "fg": ("--window-fg-color", "window_fg_color"),
    "card": ("--card-bg-color", "card_bg_color"),
    "dark": ("--headerbar-bg-color", "headerbar_bg_color"),
    "border": ("--sidebar-border-color", "sidebar_border_color"),
    "accent": ("--accent-bg-color", "accent_bg_color"),
    "accent_fg": ("--accent-fg-color", "accent_fg_color"),
}
# Keys whose canonical source is @define-color; the others prefer the property.
DEFINE_FIRST = {"accent", "accent_fg"}


def _find(text, key):
    prop, name = KEYS[key]
    pats = [
        re.compile(re.escape(prop) + r"\s*:\s*" + HEX),
        re.compile(r"@define-color\s+" + re.escape(name) + r"\s+" + HEX),
    ]
    if key in DEFINE_FIRST:
        pats.reverse()
    for pat in pats:
        m = pat.search(text)
        if m:
            return m.group(1).lower()
    return None


def parse(text):
    """Return {key: '#rrggbb'}; raise KeyError naming the first missing key."""
    out = {}
    for key in KEYS:
        val = _find(text, key)
        if val is None:
            raise KeyError(key)
        out[key] = val
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("css_file")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    try:
        with open(args.css_file, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        print(f"palette: {exc}", file=sys.stderr)
        return 1
    try:
        pal = parse(text)
    except KeyError as exc:
        print(f"palette: missing key {exc.args[0]} in {args.css_file}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(pal, indent=2))
    else:
        for k, v in pal.items():
            print(f"{k}={v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
