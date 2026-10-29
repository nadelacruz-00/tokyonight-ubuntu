#!/usr/bin/env python3
"""Save one still frame of the primary monitor via Mutter ScreenCast.

Fallback for tools/screenshots.sh when org.gnome.Shell.Screenshot refuses the
call. Creates a ScreenCast session (cursor left out), reads one buffer from the
PipeWire stream with GStreamer (copied out of shared memory by always-copy)
and writes it as a PNG.

  tools/screencast_still.py OUT.png

Needs python3-gi, gir1.2-gst-plugins-base-1.0 and gstreamer1.0-pipewire.
Exit status: 0 ok, 1 capture failed, 2 usage.
"""

import sys
import time

import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gio, GLib, Gst

SC = "org.gnome.Mutter.ScreenCast"
DC = "org.gnome.Mutter.DisplayConfig"


def primary_connector(bus):
    """Connector name (e.g. eDP-1) of the primary logical monitor, or None."""
    r = bus.call_sync(DC, "/org/gnome/Mutter/DisplayConfig", DC, "GetCurrentState", None, None, Gio.DBusCallFlags.NONE, 3000, None)
    _serial, _monitors, logical, _props = r.unpack()
    for _x, _y, _scale, _tr, primary, mons, _p in logical:
        if primary and mons:
            return mons[0][0]
    return None


def call(bus, path, iface, method, params=None):
    r = bus.call_sync(SC, path, iface, method, params, None, Gio.DBusCallFlags.NONE, 5000, None)
    return r.unpack() if r is not None else ()


def pipeline_description(node_id):
    """gst-launch description for one frame; the output path is set as a property, never interpolated."""
    return f"pipewiresrc path={int(node_id)} always-copy=true ! videoconvert ! pngenc snapshot=true ! filesink name=sink"


def capture(out):
    Gst.init(None)
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    conn = primary_connector(bus)
    if conn is None:
        raise RuntimeError("no primary monitor found")
    node = []
    session = call(bus, "/org/gnome/Mutter/ScreenCast", SC, "CreateSession", GLib.Variant("(a{sv})", ({},)))[0]
    stream = call(
        bus, session, SC + ".Session", "RecordMonitor", GLib.Variant("(sa{sv})", (conn, {"cursor-mode": GLib.Variant("u", 0)}))
    )[0]
    bus.signal_subscribe(None, SC + ".Stream", "PipeWireStreamAdded", stream, None, 0, lambda *a: node.append(a[5].unpack()[0]))
    call(bus, session, SC + ".Session", "Start")
    try:
        ctx = GLib.MainContext.default()
        deadline = time.monotonic() + 5
        while not node and time.monotonic() < deadline:
            ctx.iteration(False)
            time.sleep(0.02)
        if not node:
            raise RuntimeError("Mutter never announced a PipeWire stream")
        pipe = Gst.parse_launch(pipeline_description(node[0]))
        pipe.get_by_name("sink").set_property("location", out)
        pipe.set_state(Gst.State.PLAYING)
        msg = pipe.get_bus().timed_pop_filtered(8 * Gst.SECOND, Gst.MessageType.EOS | Gst.MessageType.ERROR)
        pipe.set_state(Gst.State.NULL)
        if msg is None or msg.type == Gst.MessageType.ERROR:
            raise RuntimeError("no frame received" if msg is None else msg.parse_error()[0].message)
    finally:
        try:
            call(bus, session, SC + ".Session", "Stop")
        except GLib.Error:
            pass


def main():
    if len(sys.argv) != 2:
        print("usage: screencast_still.py OUT.png", file=sys.stderr)
        return 2
    try:
        capture(sys.argv[1])
    except (RuntimeError, GLib.Error) as exc:
        print(f"screencast_still: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
