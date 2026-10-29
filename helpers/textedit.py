#!/usr/bin/env python3
"""Marked-block and single-line edits that preserve CRLF and final newline."""

import argparse
import os
import re
import sys


class EditError(Exception):
    pass


class Doc:
    """A text file split into lines, remembering CRLF and final-newline state."""

    def __init__(self, path):
        self.path = path
        self.exists = os.path.exists(path)
        raw = b""
        if self.exists:
            with open(path, "rb") as fh:
                raw = fh.read()
        if b"\0" in raw:
            raise EditError(f"{path}: binary file (NUL byte)")
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise EditError(f"{path}: not UTF-8 ({exc})") from exc
        self.crlf = "\r\n" in text
        text = text.replace("\r\n", "\n")
        self.final_nl = text.endswith("\n") or text == ""
        self.lines = text.split("\n")
        if self.lines and self.lines[-1] == "":
            self.lines.pop()

    def render(self):
        text = "\n".join(self.lines)
        if self.lines and self.final_nl:
            text += "\n"
        if self.crlf:
            text = text.replace("\n", "\r\n")
        return text.encode("utf-8")

    def save(self):
        d = os.path.dirname(os.path.abspath(self.path))
        os.makedirs(d, exist_ok=True)
        tmp = f"{self.path}.tmp-{os.getpid()}"
        with open(tmp, "wb") as fh:
            fh.write(self.render())
        if self.exists:
            os.chmod(tmp, os.stat(self.path).st_mode & 0o7777)
        os.replace(tmp, self.path)

    def append(self, new_lines):
        if not self.lines:
            self.final_nl = True
        self.lines.extend(new_lines)


def _find_block(lines, begin, end):
    b = [i for i, ln in enumerate(lines) if ln == begin]
    e = [i for i, ln in enumerate(lines) if ln == end]
    if not b and not e:
        return None
    if len(b) != 1 or len(e) != 1:
        raise EditError(f"unbalanced or duplicate markers ({len(b)} begin, {len(e)} end)")
    if e[0] < b[0]:
        raise EditError("end marker precedes begin marker")
    return b[0], e[0]


def block_upsert(doc, begin, end, body):
    """Insert or replace the marked block; return True if changed."""
    body_lines = body.replace("\r\n", "\n").split("\n")
    if body_lines and body_lines[-1] == "":
        body_lines.pop()
    block = [begin, *body_lines, end]
    pos = _find_block(doc.lines, begin, end)
    if pos is None:
        doc.append(block)
        return True
    s, e = pos
    if doc.lines[s : e + 1] == block:
        return False
    doc.lines[s : e + 1] = block
    return True


def block_remove(doc, begin, end):
    pos = _find_block(doc.lines, begin, end)
    if pos is None:
        return False
    del doc.lines[pos[0] : pos[1] + 1]
    return True


def _is_comment(line):
    t = line.lstrip()
    return t.startswith(("//", "#"))


_SECTION = re.compile(r"^\s*\[([^\]]*)\]\s*$")


def _section_range(lines, name):
    """(header_index, end_exclusive) of [name], or None."""
    start = None
    for i, ln in enumerate(lines):
        m = _SECTION.match(ln)
        if m:
            if start is not None:
                return start, i
            if m.group(1) == name:
                start = i
    if start is not None:
        return start, len(lines)
    return None


def _search_range(doc, section):
    if section is None:
        return 0, len(doc.lines), None
    rng = _section_range(doc.lines, section)
    if rng is None:
        return 0, 0, None
    return rng[0] + 1, rng[1], rng


def _find_line(doc, regex, section):
    lo, hi, rng = _search_range(doc, section)
    for i in range(lo, hi):
        ln = doc.lines[i]
        if not _is_comment(ln) and regex.search(ln):
            return i, rng
    return None, rng


def set_line(doc, regex, line, section=None):
    """Return (old_line_or_None, changed)."""
    i, rng = _find_line(doc, regex, section)
    if i is not None:
        old = doc.lines[i]
        if old == line:
            return old, False
        doc.lines[i] = line
        return old, True
    if section is None:
        doc.append([line])
    elif rng is None:
        if doc.lines and doc.lines[-1].strip():
            doc.lines.append("")
        doc.append([f"[{section}]", line])
    else:
        at = rng[1]
        while at > rng[0] + 1 and not doc.lines[at - 1].strip():
            at -= 1
        doc.lines.insert(at, line)
    return None, True


def restore_line(doc, regex, old, section=None):
    """Put back old (or delete the line when old is None)."""
    i, rng = _find_line(doc, regex, section)
    if i is None:
        return False
    if old is not None:
        if doc.lines[i] == old:
            return False
        doc.lines[i] = old
        return True
    del doc.lines[i]
    if rng is not None:
        r2 = _section_range(doc.lines, section)
        if r2 and not any(ln.strip() for ln in doc.lines[r2[0] + 1 : r2[1]]):
            del doc.lines[r2[0] : r2[1]]
    return True


def build_parser():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("block-upsert", "block-remove"):
        p = sub.add_parser(name)
        p.add_argument("file")
        p.add_argument("--begin", required=True)
        p.add_argument("--end", required=True)
    p = sub.add_parser("set-line")
    p.add_argument("file")
    p.add_argument("--match", required=True)
    p.add_argument("--line", required=True)
    p.add_argument("--section")
    p = sub.add_parser("restore-line")
    p.add_argument("file")
    p.add_argument("--match", required=True)
    p.add_argument("--section")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--old")
    g.add_argument("--absent", action="store_true")
    return ap


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        doc = Doc(args.file)
        if args.cmd == "block-upsert":
            body = sys.stdin.buffer.read().decode("utf-8")
            changed = block_upsert(doc, args.begin, args.end, body)
        elif args.cmd == "block-remove":
            changed = block_remove(doc, args.begin, args.end)
        else:
            try:
                rx = re.compile(args.match)
            except re.error as exc:
                print(f"textedit: bad regex: {exc}", file=sys.stderr)
                return 2
            if args.cmd == "set-line":
                old, changed = set_line(doc, rx, args.line, args.section)
                print("ABSENT" if old is None else old)
            else:
                old = None if args.absent else args.old
                changed = restore_line(doc, rx, old, args.section)
        if changed:
            doc.save()
    except EditError as exc:
        print(f"textedit: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"textedit: {exc}", file=sys.stderr)
        return 1
    return 0 if changed else 3


if __name__ == "__main__":
    sys.exit(main())
