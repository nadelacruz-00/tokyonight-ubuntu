import os
import struct
import tempfile
import unittest
import zlib

import _path  # noqa: F401
import png_strip
from pii_scan import png_chunks

SIG = png_strip.PNG_SIG


def chunk(ctype, body=b""):
    crc = zlib.crc32(ctype + body) & 0xFFFFFFFF
    return struct.pack(">I", len(body)) + ctype + body + struct.pack(">I", crc)


def make_png(extra=()):
    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
    idat = zlib.compress(b"\x00\xff\x00\x00")
    parts = [chunk(b"IHDR", ihdr), chunk(b"sRGB", b"\x00")]
    parts += [chunk(t, b) for t, b in extra]
    parts += [chunk(b"IDAT", idat), chunk(b"IEND")]
    return SIG + b"".join(parts)


class StripTest(unittest.TestCase):
    def test_drops_metadata_keeps_image_chunks(self):
        src = make_png([(b"tEXt", b"Author\x00someone"), (b"eXIf", b"x"), (b"tIME", b"1234567"), (b"iCCP", b"p\x00\x00z")])
        out = png_strip.strip_png(src)
        self.assertEqual([c for c in png_chunks(out)], [b"IHDR", b"sRGB", b"IDAT", b"IEND"])
        self.assertNotIn(b"someone", out)

    def test_clean_png_is_unchanged(self):
        src = make_png()
        self.assertEqual(png_strip.strip_png(src), src)

    def test_rejects_non_png_and_truncated(self):
        with self.assertRaises(png_strip.PngError):
            png_strip.strip_png(b"GIF89a")
        with self.assertRaises(png_strip.PngError):
            png_strip.strip_png(make_png()[:-5])
        with self.assertRaises(png_strip.PngError):
            png_strip.strip_png(SIG + chunk(b"IHDR", b"\0" * 13))

    def test_cli_rewrites_in_place(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "a.png")
            with open(p, "wb") as fh:
                fh.write(make_png([(b"tEXt", b"k\x00v")]))
            self.assertEqual(png_strip.main([p]), 0)
            with open(p, "rb") as fh:
                self.assertNotIn(b"tEXt", fh.read())
            self.assertEqual(png_strip.main([os.path.join(d, "missing.png")]), 1)


if __name__ == "__main__":
    unittest.main()
