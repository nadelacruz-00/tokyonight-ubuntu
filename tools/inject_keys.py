#!/usr/bin/env python3
"""Press key combinations in the current GNOME session via Mutter RemoteDesktop.

Used by tools/screenshots.sh --auto (Quick Settings, workspace switches, typing
`exit` into the demo terminal).

  tools/inject_keys.py ACCEL...   e.g. '<Super>s', Escape, or e x i t Return

Each ACCEL is a GTK accelerator: modifiers in <>, then one key; its keys are
pressed in order and released in reverse, one ACCEL after the other. Keys are
sent as keysyms, so Mutter maps them through the active layout. Needs python3-gi.
Exit status: 0 ok, 1 injection failed, 2 usage.
"""

import signal
import sys
import time

from gi.repository import Gio, GLib

RD = "org.gnome.Mutter.RemoteDesktop"

KEYSYMS = {
    "Return": 0xFF0D,
    "BackSpace": 0xFF08,
    "Tab": 0xFF09,
    "Escape": 0xFF1B,
    "Left": 0xFF51,
    "Up": 0xFF52,
    "Right": 0xFF53,
    "Down": 0xFF54,
    "Home": 0xFF50,
    "End": 0xFF57,
    "Shift": 0xFFE1,
    "Control": 0xFFE3,
    "Alt": 0xFFE9,
    "Super": 0xFFEB,
    "space": 0x20,
}
MOD_ALIASES = {"Primary": "Control", "Ctrl": "Control", "Meta": "Super"}


def keysym(name):
    if name in KEYSYMS:
        return KEYSYMS[name]
    if len(name) == 1 and 0x20 <= ord(name) <= 0xFF:
        return ord(name)  # Latin-1 keysyms equal their code point
    raise ValueError(f"unknown key {name!r}")


def parse_accel(accel):
    """'<Super>s' -> ['Super', 's']."""
    mods = []
    rest = accel.strip()
    while rest.startswith("<"):
        end = rest.find(">")
        if end < 0:
            raise ValueError(f"bad accelerator {accel!r}")
        m = rest[1:end]
        mods.append(MOD_ALIASES.get(m, m))
        rest = rest[end + 1 :]
    if not rest:
        raise ValueError(f"bad accelerator {accel!r}")
    return mods + [rest]


def events(accel):
    """[(keysym, pressed)]: press in order, release in reverse."""
    syms = [keysym(n) for n in parse_accel(accel)]
    return [(s, True) for s in syms] + [(s, False) for s in reversed(syms)]


def sequence(accels):
    """events() of several accelerators, one after the other."""
    out = []
    for a in accels:
        out.extend(events(a))
    return out


def call(bus, path, iface, method, params=None):
    r = bus.call_sync(RD, path, iface, method, params, None, Gio.DBusCallFlags.NONE, 5000, None)
    return r.unpack() if r is not None else ()


def inject(accels):
    evs = sequence(accels)
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    session = call(bus, "/org/gnome/Mutter/RemoteDesktop", RD, "CreateSession")[0]
    pressed = []
    try:
        call(bus, session, RD + ".Session", "Start")
        for sym, down in evs:
            call(bus, session, RD + ".Session", "NotifyKeyboardKeysym", GLib.Variant("(ub)", (sym, down)))
            if down:
                pressed.append(sym)
            else:
                pressed.remove(sym)
            time.sleep(0.04)
    finally:
        for sym in reversed(pressed):  # never leave a key held down
            try:
                call(bus, session, RD + ".Session", "NotifyKeyboardKeysym", GLib.Variant("(ub)", (sym, False)))
            except GLib.Error:
                pass
        try:
            call(bus, session, RD + ".Session", "Stop")
        except GLib.Error:
            pass


def _on_term(signum, _frame):
    sys.exit(128 + signum)  # SystemExit: the finally in inject() releases keys and stops


def main():
    signal.signal(signal.SIGTERM, _on_term)
    if len(sys.argv) < 2:
        print("usage: inject_keys.py ACCEL...", file=sys.stderr)
        return 2
    try:
        sequence(sys.argv[1:])
    except ValueError as exc:
        print(f"inject_keys: {exc}", file=sys.stderr)
        return 2
    try:
        inject(sys.argv[1:])
    except GLib.Error as exc:
        print(f"inject_keys: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
