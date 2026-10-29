#!/usr/bin/env python3
"""Edit GVariant string-array ('as') literals."""

import argparse
import re
import sys


class GVError(ValueError):
    pass


_WS = re.compile(r"\s*")


def parse(literal):
    """Parse '@as []', '[]' or "['a', 'b']" into a list of str."""
    s = literal.strip()
    if s.startswith("@as"):
        s = s[3:].strip()
    pos = 0

    def ws():
        nonlocal pos
        pos = _WS.match(s, pos).end()

    if not s.startswith("["):
        raise GVError(f"not a string array: {literal!r}")
    pos = 1
    items = []
    ws()
    if pos < len(s) and s[pos] == "]":
        pos += 1
    else:
        while True:
            ws()
            if pos >= len(s) or s[pos] not in "'\"":
                raise GVError(f"expected string at offset {pos}: {literal!r}")
            q = s[pos]
            pos += 1
            buf = []
            while True:
                if pos >= len(s):
                    raise GVError(f"unterminated string: {literal!r}")
                c = s[pos]
                if c == "\\":
                    if pos + 1 >= len(s):
                        raise GVError(f"bad escape: {literal!r}")
                    n = s[pos + 1]
                    buf.append({"n": "\n", "t": "\t"}.get(n, n))
                    pos += 2
                elif c == q:
                    pos += 1
                    break
                else:
                    buf.append(c)
                    pos += 1
            items.append("".join(buf))
            ws()
            if pos < len(s) and s[pos] == ",":
                pos += 1
                ws()
                if pos < len(s) and s[pos] == "]":  # trailing comma
                    pos += 1
                    break
                continue
            if pos < len(s) and s[pos] == "]":
                pos += 1
                break
            raise GVError(f"expected , or ] at offset {pos}: {literal!r}")
    if s[pos:].strip():
        raise GVError(f"trailing data: {literal!r}")
    return items


def fmt(items):
    if not items:
        return "@as []"
    q = ["'" + i.replace("\\", "\\\\").replace("'", "\\'") + "'" for i in items]
    return "[" + ", ".join(q) + "]"


def add(items, item):
    return items if item in items else [*items, item]


def remove(items, item):
    return [i for i in items if i != item]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("op", choices=["add", "remove", "has"])
    ap.add_argument("literal")
    ap.add_argument("item")
    args = ap.parse_args(argv)
    try:
        items = parse(args.literal)
    except GVError as exc:
        print(f"gvlist: {exc}", file=sys.stderr)
        return 1
    if args.op == "has":
        return 0 if args.item in items else 3
    new = add(items, args.item) if args.op == "add" else remove(items, args.item)
    print(fmt(new))
    return 3 if new == items else 0


if __name__ == "__main__":
    sys.exit(main())
