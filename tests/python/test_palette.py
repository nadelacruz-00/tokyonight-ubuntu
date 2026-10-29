import os
import tempfile
import unittest

import _path
import palette


def fx(name):
    return os.path.join(_path.FIXTURES, name)


class PaletteTest(unittest.TestCase):
    def test_parse_both_variants(self):
        for name, bg in (("gtk4-tokyonight.css", "#1a1b26"), ("gtk4-storm.css", "#24283b")):
            with open(fx(name), encoding="utf-8") as fh:
                pal = palette.parse(fh.read())
            self.assertEqual(pal["bg"], bg)
            self.assertEqual(pal["fg"], "#c0caf5")  # lowercased
            self.assertEqual(pal["accent"], "#7aa2f7")
            self.assertEqual(
                set(pal), {"bg", "fg", "card", "dark", "border", "accent", "accent_fg"}
            )

    def test_cli_lines_and_json(self):
        r = _path.run("palette", fx("gtk4-storm.css"))
        self.assertEqual(r.returncode, 0)
        self.assertIn("bg=#24283b\n", r.stdout)
        self.assertIn("accent_fg=#1a1b26\n", r.stdout)
        r = _path.run("palette", fx("gtk4-storm.css"), "--json")
        self.assertEqual(r.returncode, 0)
        self.assertIn('"card": "#1f2335"', r.stdout)

    def test_missing_key_names_it(self):
        with open(fx("gtk4-tokyonight.css"), encoding="utf-8") as fh:
            text = "".join(ln for ln in fh if "--card-bg-color" not in ln)
        with self.assertRaises(KeyError) as cm:
            palette.parse(text)
        self.assertEqual(cm.exception.args[0], "card")
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "x.css")
            with open(p, "w", encoding="utf-8") as fh:
                fh.write(text)
            r = _path.run("palette", p)
        self.assertEqual(r.returncode, 1)
        self.assertIn("card", r.stderr)

    def test_usage_and_unreadable(self):
        self.assertEqual(_path.run("palette").returncode, 2)
        self.assertEqual(_path.run("palette", "/nonexistent/x.css").returncode, 1)


if __name__ == "__main__":
    unittest.main()
