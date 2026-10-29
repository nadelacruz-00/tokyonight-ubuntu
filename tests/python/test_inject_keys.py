import importlib.util
import os
import sys
import types
import unittest

import _path

SCRIPT = os.path.join(_path.ROOT, "tools", "inject_keys.py")


def load():
    """Import the tool with fake gi modules (no D-Bus, nothing is injected)."""
    gi = types.ModuleType("gi")
    repo = types.ModuleType("gi.repository")
    repo.Gio = types.SimpleNamespace()
    repo.GLib = types.SimpleNamespace(Error=type("Error", (Exception,), {}))
    saved = {k: sys.modules.get(k) for k in ("gi", "gi.repository")}
    sys.modules["gi"], sys.modules["gi.repository"] = gi, repo
    try:
        spec = importlib.util.spec_from_file_location("inject_keys", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        for k, v in saved.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v
    return mod


class AccelTest(unittest.TestCase):
    def setUp(self):
        self.m = load()

    def test_super_s(self):
        self.assertEqual(self.m.parse_accel("<Super>s"), ["Super", "s"])
        self.assertEqual(
            self.m.events("<Super>s"),
            [(0xFFEB, True), (0x73, True), (0x73, False), (0xFFEB, False)],
        )

    def test_escape_alone(self):
        self.assertEqual(self.m.events("Escape"), [(0xFF1B, True), (0xFF1B, False)])

    def test_aliases(self):
        self.assertEqual(self.m.parse_accel("<Primary><Alt>Left"), ["Control", "Alt", "Left"])

    def test_bad(self):
        for bad in ("", "<Super>", "<Super", "F13", "<Hyper>x"):
            with self.assertRaises(ValueError, msg=bad):
                self.m.events(bad)

    def test_sequence_types_exit(self):
        evs = self.m.sequence(["e", "x", "i", "t", "Return"])
        self.assertEqual(evs[:2], [(ord("e"), True), (ord("e"), False)])
        self.assertEqual(evs[-2:], [(0xFF0D, True), (0xFF0D, False)])
        self.assertEqual(len(evs), 10)

    def test_end_home(self):
        self.assertEqual(self.m.parse_accel("<Super>End"), ["Super", "End"])
        self.assertEqual(self.m.events("<Super>Home")[1], (0xFF50, True))

    def test_sigterm_becomes_systemexit(self):
        # SystemExit unwinds through inject()'s finally (keys released, session stopped)
        with self.assertRaises(SystemExit) as cm:
            self.m._on_term(15, None)
        self.assertEqual(cm.exception.code, 143)

    def test_main_usage_errors_need_no_bus(self):
        argv = sys.argv
        try:
            sys.argv = ["inject_keys.py"]
            self.assertEqual(self.m.main(), 2)
            sys.argv = ["inject_keys.py", "<Super>"]
            self.assertEqual(self.m.main(), 2)
            sys.argv = ["inject_keys.py", "e", "<Super>"]
            self.assertEqual(self.m.main(), 2)
        finally:
            sys.argv = argv


if __name__ == "__main__":
    unittest.main()
