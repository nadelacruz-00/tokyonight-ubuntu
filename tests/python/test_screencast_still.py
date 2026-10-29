import importlib.util
import os
import sys
import types
import unittest

import _path

SCRIPT = os.path.join(_path.ROOT, "tools", "screencast_still.py")


def load():
    """Import the tool with fake gi modules (no GStreamer / D-Bus needed)."""
    gi = types.ModuleType("gi")
    gi.require_version = lambda *a: None
    repo = types.ModuleType("gi.repository")
    for n in ("Gio", "GLib", "Gst"):
        setattr(repo, n, types.SimpleNamespace())
    saved = {k: sys.modules.get(k) for k in ("gi", "gi.repository")}
    sys.modules["gi"], sys.modules["gi.repository"] = gi, repo
    try:
        spec = importlib.util.spec_from_file_location("screencast_still", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        for k, v in saved.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v
    return mod


class PipelineTest(unittest.TestCase):
    def test_description_has_no_path_or_quotes(self):
        d = load().pipeline_description(42)
        self.assertIn("pipewiresrc path=42 ", d)
        self.assertIn("filesink name=sink", d)
        self.assertNotIn("location", d)
        for ch in "'\"\\":
            self.assertNotIn(ch, d)


if __name__ == "__main__":
    unittest.main()
