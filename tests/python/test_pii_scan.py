import os
import shutil
import struct
import tempfile
import unittest
import zlib

import _path

PII = os.path.join(_path.FIXTURES, "pii")


def png(*chunks):
    out = b"\x89PNG\r\n\x1a\n"
    for ctype, body in chunks:
        out += struct.pack(">I", len(body)) + ctype + body
        out += struct.pack(">I", zlib.crc32(ctype + body))
    return out


IHDR = (b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 0, 0, 0, 0))
IDAT = (b"IDAT", zlib.compress(b"\x00\x00"))
IEND = (b"IEND", b"")


def scan(*args):
    r = _path.run("pii_scan", *args)
    return r.returncode, r.stdout


class PiiScanTest(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.addCleanup(self._td.cleanup)
        self.tmp = self._td.name

    def test_planted_positives(self):
        deny = os.path.join(self.tmp, "deny")
        with open(deny, "w", encoding="utf-8") as fh:
            fh.write("# comment\n\nzaphod BEEBLEBROX\n")
        cases = [
            ("email.txt", "email"),
            ("home.txt", "home-path"),
            ("uuid.txt", "uuid"),
            ("mac.txt", "mac"),
            ("ipv4.txt", "ipv4"),
            ("denylist.txt", "denylist"),
        ]
        for name, rule in cases:
            with self.subTest(name):
                code, out = scan("--denylist", deny, os.path.join(PII, name))
                self.assertEqual(code, 1, out)
                self.assertIn(f": {rule}: ", out)
                self.assertRegex(out, rf"{name}:\d+: {rule}")
        code, out = scan(os.path.join(PII, "home.txt"))
        self.assertEqual(out.count(": home-path:"), 2)  # /home/<x> and /Users/<x>
        code, out = scan(os.path.join(PII, "uuid.txt"))
        self.assertEqual(out.count(": uuid:"), 2)  # dashed and bare 32-hex

    def test_denylist_needs_flag(self):
        self.assertEqual(scan(os.path.join(PII, "denylist.txt"))[0], 0)

    def test_negatives_and_pragma(self):
        code, out = scan(os.path.join(PII, "negatives.txt"))
        self.assertEqual((code, out), (0, ""))

    def test_checksum_file_uuid_allowed(self):
        d = os.path.join(self.tmp, "assets")
        os.makedirs(d)
        with open(os.path.join(d, "checksums.sha256"), "w", encoding="utf-8") as fh:
            fh.write("04d5e8f903693f9dd13e16f867e994834e681eb3c72c0d337a770dcda09010cf  a.tar.xz\n")
            fh.write("123e4567e89b42d3a456426614174000  b\n")  # pii-scan: allow
        self.assertEqual(scan(d)[0], 0)

    def test_png_metadata(self):
        bad = os.path.join(self.tmp, "bad.png")
        good = os.path.join(self.tmp, "good.png")
        with open(bad, "wb") as fh:
            fh.write(png(IHDR, (b"tEXt", b"Author\x00someone"), IDAT, IEND))
        with open(good, "wb") as fh:
            fh.write(png(IHDR, IDAT, IEND))
        code, out = scan(bad)
        self.assertEqual(code, 1)
        self.assertIn("png-metadata: tEXt", out)
        self.assertEqual(scan(good)[0], 0)

    def test_binary_skipped_and_repo_skips(self):
        root = os.path.join(self.tmp, "repo")
        for sub in ("tests/fixtures/pii", "tests/bats/bats-core", ".git", "src"):
            os.makedirs(os.path.join(root, sub))
        for sub in ("tests/fixtures/pii", "tests/bats/bats-core", ".git"):
            shutil.copy(os.path.join(PII, "email.txt"), os.path.join(root, sub, "f.txt"))
        with open(os.path.join(root, "src", "blob.bin"), "wb") as fh:
            fh.write(b"\x00 /home/zed/x")  # pii-scan: allow
        self.assertEqual(scan(root), (0, ""))
        shutil.copy(os.path.join(PII, "email.txt"), os.path.join(root, "src", "f.txt"))
        code, out = scan(root)
        self.assertEqual(code, 1)
        self.assertIn(os.path.join("src", "f.txt") + ":1: email", out)

    def test_denylist_file_itself_skipped(self):
        for n, name in enumerate((".pii-denylist", "custom.txt")):
            root = os.path.join(self.tmp, f"r{n}")
            os.makedirs(root)
            deny = os.path.join(root, name)
            with open(deny, "w", encoding="utf-8") as fh:
                fh.write("secretword\n")
            with open(os.path.join(root, "ok.txt"), "w", encoding="utf-8") as fh:
                fh.write("fine\n")
            self.assertEqual(scan("--denylist", deny, root), (0, ""))

    def test_skips_relative_to_repo_root_for_subdir(self):
        import subprocess

        root = os.path.join(self.tmp, "g")
        for sub in ("tests/fixtures/pii", "tests/bats/bats-core", "tests/other"):
            os.makedirs(os.path.join(root, sub))
        subprocess.run(["git", "-C", root, "init", "-q"], check=True)
        for sub in ("tests/fixtures/pii", "tests/bats/bats-core"):
            shutil.copy(os.path.join(PII, "email.txt"), os.path.join(root, sub, "f.txt"))
        r = _path.run("pii_scan", "tests", cwd=root)
        self.assertEqual((r.returncode, r.stdout), (0, ""))
        r = _path.run("pii_scan", "tests/fixtures", cwd=root)
        self.assertEqual((r.returncode, r.stdout), (0, ""))
        shutil.copy(os.path.join(PII, "email.txt"), os.path.join(root, "tests", "other", "f.txt"))
        self.assertEqual(_path.run("pii_scan", "tests", cwd=root).returncode, 1)

    def test_history_removed_dash_lines(self):
        import subprocess

        def git(*a):
            subprocess.run(
                ["git", "-C", self.tmp, "-c", "user.name=T", "-c", "user.email=t@users.noreply.github.com", *a],
                check=True,
                capture_output=True,
            )

        git("init", "-q")
        p = os.path.join(self.tmp, "a.txt")
        with open(p, "wb") as fh:
            fh.write(b"-- mail jane.roe@corp-mail.io\n\xff\xfe bad bytes\n")  # pii-scan: allow
        git("add", "a.txt")
        git("commit", "-qm", "add")
        with open(p, "w", encoding="utf-8") as fh:
            fh.write("clean\n")
        git("commit", "-qam", "clean")
        code, out = scan("--history", self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("email", out)

    def test_no_git_on_path(self):
        import subprocess
        import sys

        d = os.path.join(self.tmp, "a")
        os.makedirs(d)
        shutil.copy(os.path.join(PII, "email.txt"), d)
        cmd = [sys.executable, "-I", os.path.join(_path.HELPERS, "pii_scan.py")]
        env = {"PATH": os.path.join(self.tmp, "empty")}
        r = subprocess.run([*cmd, d], env=env, capture_output=True, text=True, check=False)
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn(": email: ", r.stdout)
        self.assertNotIn("Traceback", r.stderr)
        r = subprocess.run([*cmd, "--history", d], env=env, capture_output=True, text=True, check=False)
        self.assertEqual(r.returncode, 1)
        self.assertIn("--history needs git", r.stderr)
        self.assertNotIn("Traceback", r.stderr)

    def test_usage(self):
        self.assertEqual(scan()[0], 2)
        self.assertEqual(scan("/nonexistent/path")[0], 2)

    def test_history(self):
        if shutil.which("git") is None:
            self.skipTest("git missing")
        import subprocess

        def git(*a):
            subprocess.run(
                ["git", "-C", self.tmp, "-c", "user.name=T", "-c", "user.email=t@users.noreply.github.com", *a],
                check=True,
                capture_output=True,
            )

        git("init", "-q")
        shutil.copy(os.path.join(PII, "email.txt"), os.path.join(self.tmp, "a.txt"))
        git("add", "a.txt")
        git("commit", "-qm", "add")
        os.remove(os.path.join(self.tmp, "a.txt"))
        git("add", "-A")
        git("commit", "-qm", "rm")
        self.assertEqual(scan(self.tmp)[0], 0)  # gone from the tree
        code, out = scan("--history", self.tmp)
        self.assertEqual(code, 1)
        self.assertIn("email", out)


if __name__ == "__main__":
    unittest.main()
