import os
import tempfile
import unittest

import _path

B = "# >>> tokyonight-ubuntu >>>"
E = "# <<< tokyonight-ubuntu <<<"


class TexteditTest(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        self.path = os.path.join(self._td.name, "f.txt")

    def write(self, data):
        with open(self.path, "wb") as fh:
            fh.write(data)

    def read(self):
        with open(self.path, "rb") as fh:
            return fh.read()

    def upsert(self, body):
        return _path.run("textedit", "block-upsert", self.path, "--begin", B, "--end", E, stdin=body)

    def remove(self):
        return _path.run("textedit", "block-remove", self.path, "--begin", B, "--end", E)

    def test_upsert_creates_file(self):
        self.assertEqual(self.upsert("x=1\n").returncode, 0)
        self.assertEqual(self.read(), f"{B}\nx=1\n{E}\n".encode())

    def test_upsert_append_replace_unchanged_remove(self):
        self.write(b"keep\n")
        self.assertEqual(self.upsert("a\n").returncode, 0)
        self.assertEqual(self.read(), f"keep\n{B}\na\n{E}\n".encode())
        self.assertEqual(self.upsert("a\n").returncode, 3)
        self.assertEqual(self.upsert("b\nc\n").returncode, 0)
        self.assertEqual(self.read(), f"keep\n{B}\nb\nc\n{E}\n".encode())
        self.assertEqual(self.remove().returncode, 0)
        self.assertEqual(self.read(), b"keep\n")
        self.assertEqual(self.remove().returncode, 3)

    def test_replace_in_middle(self):
        self.write(f"top\n{B}\nold\n{E}\nbottom\n".encode())
        self.assertEqual(self.upsert("new\n").returncode, 0)
        self.assertEqual(self.read(), f"top\n{B}\nnew\n{E}\nbottom\n".encode())

    def test_crlf_preserved(self):
        self.write(b"a\r\nb\r\n")
        self.upsert("x\n")
        self.assertEqual(self.read(), f"a\r\nb\r\n{B}\r\nx\r\n{E}\r\n".encode())
        self.remove()
        self.assertEqual(self.read(), b"a\r\nb\r\n")

    def test_no_trailing_newline_preserved(self):
        self.write(b"a\nb")
        self.upsert("x\n")
        self.assertEqual(self.read(), f"a\nb\n{B}\nx\n{E}".encode())
        self.remove()
        self.assertEqual(self.read(), b"a\nb")

    def test_binary_refused(self):
        self.write(b"\x00\x01binary")
        for r in (self.upsert("x\n"), self.remove()):
            self.assertEqual(r.returncode, 1)
        self.assertEqual(self.read(), b"\x00\x01binary")

    def test_duplicate_or_unbalanced_markers(self):
        for content in (
            f"{B}\na\n{E}\n{B}\nb\n{E}\n",
            f"{B}\na\n",
            f"a\n{E}\n",
            f"{E}\na\n{B}\n",
        ):
            self.write(content.encode())
            for r in (self.upsert("x\n"), self.remove()):
                self.assertEqual(r.returncode, 1, content)
            self.assertEqual(self.read(), content.encode())

    def set_line(self, *extra, line='theme "tokyo"', match=r"^\s*theme\b"):
        return _path.run("textedit", "set-line", self.path, "--match", match, "--line", line, *extra)

    def test_set_line_replaces_and_prints_old(self):
        self.write(b'a = 1\ntheme "old"\nb = 2\n')
        r = self.set_line()
        self.assertEqual((r.returncode, r.stdout), (0, 'theme "old"\n'))
        self.assertEqual(self.read(), b'a = 1\ntheme "tokyo"\nb = 2\n')
        r = self.set_line()
        self.assertEqual((r.returncode, r.stdout), (3, 'theme "tokyo"\n'))

    def test_set_line_ignores_comments_and_appends(self):
        self.write(b'// theme "x"\n# theme "y"\nz = 1')
        r = self.set_line()
        self.assertEqual((r.returncode, r.stdout), (0, "ABSENT\n"))
        self.assertEqual(self.read(), b'// theme "x"\n# theme "y"\nz = 1\ntheme "tokyo"')

    def test_set_line_in_section(self):
        self.write(b'theme "top"\n[ui]\nfont = 1\n\n[other]\ntheme "o"\n')
        r = self.set_line("--section", "ui")
        self.assertEqual((r.returncode, r.stdout), (0, "ABSENT\n"))
        self.assertEqual(
            self.read(), b'theme "top"\n[ui]\nfont = 1\ntheme "tokyo"\n\n[other]\ntheme "o"\n'
        )
        r = self.set_line("--section", "other", line='theme "p"')
        self.assertEqual((r.returncode, r.stdout), (0, 'theme "o"\n'))

    def test_set_line_creates_section(self):
        self.write(b"a = 1\n")
        self.assertEqual(self.set_line("--section", "ui").returncode, 0)
        self.assertEqual(self.read(), b'a = 1\n\n[ui]\ntheme "tokyo"\n')

    def test_restore_line(self):
        self.write(b'a\ntheme "tokyo"\n')
        args = ("restore-line", self.path, "--match", r"^theme\b")
        r = _path.run("textedit", *args, "--old", 'theme "old"')
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.read(), b'a\ntheme "old"\n')
        r = _path.run("textedit", *args, "--absent")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.read(), b"a\n")
        self.assertEqual(_path.run("textedit", *args, "--absent").returncode, 3)

    def test_restore_absent_drops_empty_section(self):
        self.write(b'a = 1\n\n[ui]\ntheme "tokyo"\n')
        r = _path.run("textedit", "restore-line", self.path, "--match", "^theme", "--section", "ui", "--absent")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.read(), b"a = 1\n\n")

    def test_usage(self):
        self.assertEqual(_path.run("textedit").returncode, 2)
        self.assertEqual(_path.run("textedit", "restore-line", self.path, "--match", "x").returncode, 2)
        self.assertEqual(
            _path.run("textedit", "set-line", self.path, "--match", "(", "--line", "x").returncode, 2
        )


if __name__ == "__main__":
    unittest.main()
