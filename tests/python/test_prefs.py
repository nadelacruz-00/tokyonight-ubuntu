import glob
import json
import os
import tempfile
import unittest

import _path
import prefs


class PrefsTest(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        self.path = os.path.join(self._td.name, "sub", "prefs.json")

    def read(self):
        with open(self.path, encoding="utf-8") as fh:
            return fh.read()

    def test_create_preserve_and_idempotent(self):
        r = _path.run("prefs", "merge", self.path, 'a="x"', "n=3")
        self.assertEqual(r.returncode, 0)
        data = json.loads(self.read())
        data["unknown"] = {"keep": [1, 2]}
        with open(self.path, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        self.assertEqual(_path.run("prefs", "merge", self.path, 'a="y"').returncode, 0)
        self.assertEqual(_path.run("prefs", "merge", self.path, 'a="y"').returncode, 3)
        data = json.loads(self.read())
        self.assertEqual(data["unknown"], {"keep": [1, 2]})
        self.assertEqual((data["a"], data["n"]), ("y", 3))

    def test_invalid_json_backed_up(self):
        os.makedirs(os.path.dirname(self.path))
        with open(self.path, "w", encoding="utf-8") as fh:
            fh.write("{not json")
        r = _path.run("prefs", "merge", self.path, "k=1")
        self.assertEqual(r.returncode, 0)
        self.assertIn("invalid", r.stderr)
        baks = glob.glob(self.path + ".invalid-*")
        self.assertEqual(len(baks), 1)
        with open(baks[0], encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "{not json")
        self.assertEqual(json.loads(self.read()), {"k": 1})

    def test_emoji_round_trip_and_format(self):
        r = _path.run("prefs", "merge", self.path, 'icon="\U0001f5fc"')
        self.assertEqual(r.returncode, 0)
        text = self.read()
        self.assertIn("\\ud83d\\uddfc", text)  # ensure_ascii surrogate pair
        self.assertTrue(text.startswith('{\n    "icon"'))  # indent=4
        self.assertEqual(json.loads(text)["icon"], "\U0001f5fc")
        self.assertEqual(prefs.merge(self.path, {"icon": "\U0001f5fc"}), False)

    def test_usage(self):
        self.assertEqual(_path.run("prefs", "merge", self.path, "nokv").returncode, 2)
        self.assertEqual(_path.run("prefs", "merge", self.path, "k={bad").returncode, 2)
        self.assertEqual(_path.run("prefs").returncode, 2)


if __name__ == "__main__":
    unittest.main()
