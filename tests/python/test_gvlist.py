import unittest

import _path
import gvlist


class GvlistTest(unittest.TestCase):
    def cli(self, *a):
        r = _path.run("gvlist", *a)
        return r.returncode, r.stdout.strip()

    def test_add(self):
        self.assertEqual(self.cli("add", "@as []", "a"), (0, "['a']"))
        self.assertEqual(self.cli("add", "['a']", "b"), (0, "['a', 'b']"))
        self.assertEqual(self.cli("add", "[]", "a"), (0, "['a']"))

    def test_add_idempotent(self):
        self.assertEqual(self.cli("add", "['a', 'b']", "a"), (3, "['a', 'b']"))

    def test_remove(self):
        self.assertEqual(self.cli("remove", "['a', 'b']", "a"), (0, "['b']"))
        self.assertEqual(self.cli("remove", "['a']", "a"), (0, "@as []"))
        self.assertEqual(self.cli("remove", "@as []", "a"), (3, "@as []"))

    def test_has(self):
        self.assertEqual(self.cli("has", "['a']", "a")[0], 0)
        self.assertEqual(self.cli("has", "['a']", "z")[0], 3)

    def test_apostrophe_round_trip(self):
        code, out = self.cli("add", "@as []", "Synthwave '84")
        self.assertEqual((code, out), (0, "['Synthwave \\'84']"))
        self.assertEqual(gvlist.parse(out), ["Synthwave '84"])
        self.assertEqual(self.cli("remove", out, "Synthwave '84"), (0, "@as []"))
        self.assertEqual(gvlist.parse('["it\'s", \'b\\\\c\']'), ["it's", "b\\c"])

    def test_rejects_non_string_arrays(self):
        for bad in ("[1, 2]", "'a'", "['a'", "['a' 'b']", "['a'] x", "{}", ""):
            self.assertEqual(self.cli("add", bad, "z")[0], 1, bad)

    def test_usage(self):
        self.assertEqual(_path.run("gvlist", "add", "[]").returncode, 2)
        self.assertEqual(_path.run("gvlist", "nope", "[]", "a").returncode, 2)


if __name__ == "__main__":
    unittest.main()
