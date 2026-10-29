import os
import shutil
import subprocess
import tempfile
import unittest

import _path
import gresource
import palette


def fx(name):
    return os.path.join(_path.FIXTURES, name)


def pal():
    with open(fx("gtk4-tokyonight.css"), encoding="utf-8") as fh:
        return palette.parse(fh.read())


class PureTest(unittest.TestCase):
    def test_overrides_golden_for_tokyonight_palette(self):
        with open(fx("gdm/expected-overrides-tokyonight.css"), encoding="utf-8") as fh:
            want = fh.read()
        self.assertEqual(gresource.overrides(pal(), "tokyonight-bg.jpg"), want)

    def test_apply_overrides_twice_equals_once(self):
        block = gresource.overrides(pal(), "tokyonight-bg.jpg")
        for css in ("a { b: c; }\n", "a { b: c; }", ""):
            once = gresource.apply_overrides(css, block)
            self.assertEqual(gresource.apply_overrides(once, block), once)
            self.assertTrue(once.endswith(block))
            self.assertEqual(once.count(gresource.MARK), 1)

    def test_apply_overrides_replaces_older_block(self):
        old = "x {}\n\n" + gresource.MARK + "\nold {}\n"
        block = gresource.overrides(pal(), "tokyonight-bg.png")
        new = gresource.apply_overrides(old, block)
        self.assertNotIn("old {}", new)
        self.assertTrue(new.startswith("x {}\n"))

    def test_resource_xml_lists_every_file_with_prefix(self):
        xml = gresource.resource_xml(["Yaru/a.css", "gdm.css"])
        self.assertIn('<gresource prefix="/org/gnome/shell/theme">', xml)
        self.assertIn("<file>Yaru/a.css</file>", xml)
        self.assertIn("<file>gdm.css</file>", xml)


@unittest.skipUnless(
    shutil.which("glib-compile-resources") and shutil.which("gresource"),
    "glib-compile-resources/gresource not installed",
)
class BuildTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = self.tmp.name
        src = os.path.join(t, "base", "Yaru")
        os.makedirs(src)
        for rel, text in (("Yaru/gnome-shell-dark.css", "stage { color: red; }\n"), ("gdm.css", "@import url('x');\n")):
            with open(os.path.join(t, "base", rel), "w", encoding="utf-8") as fh:
                fh.write(text)
        self.base = os.path.join(t, "base.gresource")
        xml = os.path.join(t, "base.xml")
        with open(xml, "w", encoding="utf-8") as fh:
            fh.write(gresource.resource_xml(["Yaru/gnome-shell-dark.css", "gdm.css"]))
        subprocess.run(
            ["glib-compile-resources", "--sourcedir", os.path.join(t, "base"), "--target", self.base, xml],
            check=True,
        )
        self.wall = os.path.join(t, "wall.jpg")
        with open(self.wall, "wb") as fh:
            fh.write(b"\xff\xd8fake-jpeg")

    def extract(self, gres, name):
        return subprocess.run(
            ["gresource", "extract", gres, gresource.PREFIX + "/" + name],
            capture_output=True, check=True,
        ).stdout.decode("utf-8")

    def test_build_end_to_end(self):
        out = os.path.join(self.tmp.name, "out", "t.gresource")
        r = _path.run("gresource", "build", "--base", self.base, "--palette", fx("gtk4-tokyonight.css"),
                      "--wallpaper", self.wall, "--out", out)
        self.assertEqual(r.returncode, 0, r.stderr)
        names = subprocess.run(["gresource", "list", out], capture_output=True, text=True, check=True).stdout
        self.assertIn("tokyonight-bg.jpg", names)
        for css in ("Yaru/gnome-shell-dark.css", "gdm.css"):
            text = self.extract(out, css)
            self.assertIn(gresource.MARK, text)
            self.assertIn("url(resource:///org/gnome/shell/theme/tokyonight-bg.jpg)", text)
        self.assertTrue(self.extract(out, "Yaru/gnome-shell-dark.css").startswith("stage { color: red; }\n"))
        # rebuilding is deterministic, and building from our own output is idempotent
        out2 = os.path.join(self.tmp.name, "out", "t2.gresource")
        out3 = os.path.join(self.tmp.name, "out", "t3.gresource")
        for src, dst in ((self.base, out2), (out, out3)):
            r = _path.run("gresource", "build", "--base", src, "--palette", fx("gtk4-tokyonight.css"),
                          "--wallpaper", self.wall, "--out", dst)
            self.assertEqual(r.returncode, 0, r.stderr)
        with open(out, "rb") as a, open(out2, "rb") as b, open(out3, "rb") as c:
            data = a.read()
            self.assertEqual(data, b.read())
            self.assertEqual(data, c.read())

    def test_bad_wallpaper_fails(self):
        r = _path.run("gresource", "build", "--base", self.base, "--palette", fx("gtk4-tokyonight.css"),
                      "--wallpaper", self.wall + ".gif", "--out", os.path.join(self.tmp.name, "o"))
        self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
