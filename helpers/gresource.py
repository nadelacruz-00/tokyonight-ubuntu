#!/usr/bin/env python3
"""Build a GDM theme gresource: a base shell theme plus a Tokyo Night override block.

    gresource.py build --base GRESOURCE --palette CSS --wallpaper IMG --out OUT

Extracts every resource under /org/gnome/shell/theme from the base gresource,
embeds the wallpaper as the login background, appends the override block
(login prompt, buttons, GNOME's on-screen keyboard) to each shell stylesheet
and recompiles with glib-compile-resources.  Ported from a personal build script.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import palette as palette_mod

PREFIX = "/org/gnome/shell/theme"
STYLESHEETS = ["Yaru/gnome-shell-dark.css", "Yaru/gnome-shell.css", "gdm.css"]
MARK = "/* tokyonight-ubuntu overrides */"


def rgba(hex_, a):
    n = int(hex_[1:], 16)
    return f"rgba({n >> 16 & 255}, {n >> 8 & 255}, {n & 255}, {a})"


def overrides(p, bg_name):
    """The override CSS block (starts with a newline, then MARK)."""
    pressed = rgba(p["accent"], 0.35)
    ring = rgba(p["accent"], 0.6)
    return f"""
{MARK}
#lockDialogGroup {{
  background: {p['bg']} url(resource://{PREFIX}/{bg_name});
  background-size: cover;
  background-position: center; }}

.login-dialog .login-dialog-prompt-entry,
.unlock-dialog .login-dialog-prompt-entry {{
  background-color: {p['card']};
  color: {p['fg']}; }}
.login-dialog .login-dialog-prompt-entry:hover,
.unlock-dialog .login-dialog-prompt-entry:hover {{
  background-color: {p['border']};
  color: {p['fg']}; }}
.login-dialog .login-dialog-prompt-entry:focus,
.unlock-dialog .login-dialog-prompt-entry:focus {{
  background-color: {p['card']};
  color: {p['fg']};
  box-shadow: inset 0 0 0 2px {ring} !important; }}
.login-dialog .login-dialog-prompt-entry StLabel.hint-text,
.unlock-dialog .login-dialog-prompt-entry StLabel.hint-text {{
  color: {rgba(p['fg'], 0.6)}; }}

.login-dialog-button.login-dialog-auth-menu-button, .login-dialog-button.a11y-button,
.login-dialog-button.cancel-button, .login-dialog-button.switch-user-button,
.login-dialog-button.login-dialog-session-list-button {{
  background-color: {p['card']};
  color: {p['fg']}; }}
.login-dialog-button.login-dialog-auth-menu-button:hover, .login-dialog-button.a11y-button:hover,
.login-dialog-button.cancel-button:hover, .login-dialog-button.switch-user-button:hover,
.login-dialog-button.login-dialog-session-list-button:hover {{
  background-color: {p['border']}; }}
.login-dialog .button.default, .unlock-dialog .button.default,
.login-dialog .button.default:hover, .unlock-dialog .button.default:hover {{
  background-color: {p['accent']};
  color: {p['accent_fg']}; }}

.login-dialog-user-list-view .login-dialog-user-list .login-dialog-user-list-item {{
  color: {p['fg']}; }}
.login-dialog-user-list-view .login-dialog-user-list .login-dialog-user-list-item:hover,
.login-dialog-user-list-view .login-dialog-user-list .login-dialog-user-list-item:focus,
.login-dialog-user-list-view .login-dialog-user-list .login-dialog-user-list-item:selected {{
  background-color: {rgba(p['card'], 0.85)}; }}

#keyboard {{
  background-color: {p['bg']};
  box-shadow: none; }}
.keyboard-key, .keyboard-key:hover, .keyboard-key:focus, .keyboard-key:focus:hover {{
  background-color: {p['card']};
  color: {p['fg']};
  box-shadow: 0 1px 0 0 rgba(0, 0, 0, 0.3); }}
.keyboard-key:hover, .keyboard-key:focus:hover {{
  background-color: {p['border']}; }}
.keyboard-key:active, .keyboard-key:active:hover, .keyboard-key:active:focus {{
  background-color: {pressed};
  color: {p['fg']}; }}
.keyboard-key:checked, .keyboard-key:checked:hover, .keyboard-key:checked:active {{
  background-color: {p['accent']};
  color: {p['accent_fg']}; }}
.keyboard-key.default-key, .keyboard-key.default-key:hover {{
  background-color: {p['dark']};
  color: {p['fg']}; }}
.keyboard-key.default-key:hover {{
  background-color: {p['border']}; }}
.keyboard-key.default-key:active, .keyboard-key.default-key:active:hover, .keyboard-key.default-key:active:focus {{
  background-color: {pressed};
  color: {p['fg']}; }}
.keyboard-key.default-key:checked, .keyboard-key.default-key:checked:hover,
.keyboard-key.default-key:checked:active, .keyboard-key.default-key:latched {{
  background-color: {p['accent']};
  color: {p['accent_fg']}; }}
.word-suggestions StButton {{
  color: {p['fg']}; }}
"""


def apply_overrides(css, block):
    """Replace everything from MARK to the end of css with block (idempotent)."""
    idx = css.find(MARK)
    base = css[:idx] if idx >= 0 else css
    return base.rstrip("\n") + "\n" + block


def resource_xml(files):
    """gresource XML listing every file under PREFIX."""
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n<gresources>\n'
        f'  <gresource prefix="{PREFIX}">\n'
        + "".join(f"    <file>{f}</file>\n" for f in files)
        + "  </gresource>\n</gresources>\n"
    )


def _capture(cmd):
    return subprocess.run(cmd, capture_output=True, check=True).stdout


def build(base, palette_css, wallpaper, out):
    with open(palette_css, encoding="utf-8") as fh:
        pal = palette_mod.parse(fh.read())
    ext = os.path.splitext(wallpaper)[1].lower()
    if ext not in (".jpg", ".jpeg", ".png") or not os.path.isfile(wallpaper):
        raise SystemExit(f"gresource: wallpaper {wallpaper} is not a jpg/png file")
    names = _capture(["gresource", "list", base]).decode("utf-8").split()
    names = [n for n in names if n.startswith(PREFIX + "/")]
    if not names:
        raise SystemExit(f"gresource: no {PREFIX} resources in {base}")
    with tempfile.TemporaryDirectory(prefix="tnu-gresource.") as tmp:
        src = os.path.join(tmp, "src")
        for name in names:
            dest = os.path.join(src, name[len(PREFIX) + 1 :])
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as fh:
                fh.write(_capture(["gresource", "extract", base, name]))
        bg_name = "tokyonight-bg" + ext
        shutil.copyfile(wallpaper, os.path.join(src, bg_name))
        block = overrides(pal, bg_name)
        for css in STYLESHEETS:
            path = os.path.join(src, css)
            if os.path.isfile(path):
                with open(path, encoding="utf-8") as fh:
                    text = fh.read()
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(apply_overrides(text, block))
        files = sorted(
            os.path.relpath(os.path.join(d, f), src)
            for d, _, fs in os.walk(src)
            for f in fs
        )
        xml = os.path.join(tmp, "theme.gresource.xml")
        with open(xml, "w", encoding="utf-8") as fh:
            fh.write(resource_xml(files))
        os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
        subprocess.run(
            ["glib-compile-resources", "--sourcedir", src, "--target", out, xml],
            check=True,
        )
    return len(files)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    for opt in ("base", "palette", "wallpaper", "out"):
        b.add_argument("--" + opt, required=True)
    args = ap.parse_args(argv)
    try:
        n = build(args.base, args.palette, args.wallpaper, args.out)
    except (OSError, KeyError, subprocess.CalledProcessError) as exc:
        print(f"gresource: {exc}", file=sys.stderr)
        return 1
    print(f"gresource: built {args.out} ({n} files)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
