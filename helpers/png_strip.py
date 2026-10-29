#!/usr/bin/env python3
"""Rewrite PNG files keeping only the chunks needed to display them.

Kept: IHDR PLTE tRNS sRGB gAMA pHYs IDAT IEND. Everything else (tEXt, iTXt,
zTXt, eXIf, tIME, ICC profiles, ...) is dropped. Files are rewritten in place.
"""

import os
import struct
import sys

PNG_SIG = b"\x89PNG\r\n\x1a\n"
KEEP = {b"IHDR", b"PLTE", b"tRNS", b"sRGB", b"gAMA", b"pHYs", b"IDAT", b"IEND"}


class PngError(ValueError):
    pass


def strip_png(data):
    """Return data without metadata chunks. Raises PngError on malformed input."""
    if not data.startswith(PNG_SIG):
        raise PngError("not a PNG file")
    out = [PNG_SIG]
    pos = len(PNG_SIG)
    seen_end = False
    while pos < len(data):
        if pos + 12 > len(data):
            raise PngError("truncated chunk header")
        length, ctype = struct.unpack(">I4s", data[pos : pos + 8])
        end = pos + 12 + length
        if end > len(data):
            raise PngError("truncated chunk " + ctype.decode("ascii", "replace"))
        if ctype in KEEP:
            out.append(data[pos:end])
        if ctype == b"IEND":
            seen_end = True
            break
        pos = end
    if not seen_end:
        raise PngError("missing IEND")
    return b"".join(out)


def strip_file(path):
    with open(path, "rb") as fh:
        data = fh.read()
    new = strip_png(data)
    tmp = path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(new)
    os.replace(tmp, path)
    return len(data) - len(new)


def main(argv=None):
    paths = sys.argv[1:] if argv is None else argv
    if not paths:
        print("usage: png_strip.py FILE...", file=sys.stderr)
        return 2
    rc = 0
    for p in paths:
        try:
            strip_file(p)
        except (OSError, PngError) as exc:
            print(f"png_strip: {p}: {exc}", file=sys.stderr)
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
