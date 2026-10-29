#!/usr/bin/env python3
"""Scan files (and optionally git history) for personal identifiers."""

import argparse
import fnmatch
import ipaddress
import os
import re
import shutil
import struct
import subprocess
import sys

PNG_SIG = b"\x89PNG\r\n\x1a\n"
PNG_META = {b"tEXt", b"iTXt", b"zTXt", b"eXIf"}

EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})\b")
EMAIL_OK = {
    "noreply@anthropic.com",
    # public GNOME extension UUIDs (name@domain shaped, not mailboxes)
    "gjsosk@vishram1123.com",
    "gjsosk-theme-sync@nadelacruz-00.github.io",
    "user-theme@gnome-shell-extensions.gcampax.github.com",
}
# users.noreply.github.com plus RFC 2606 reserved names (documentation examples)
EMAIL_DOMAIN_OK = re.compile(
    r"(^|\.)(users\.noreply\.github\.com|example\.(com|net|org|invalid)|invalid|example|test)$",
    re.IGNORECASE,
)
HOME_UNIX = re.compile(r"/home/([a-z_][a-z0-9_.-]*)")
HOME_MAC = re.compile(r"/Users/([A-Za-z][\w.-]*)")
HOME_OK = {"user", "someone", "example", "runner", "tester", "demo"}
UUID = re.compile(
    r"(?<![0-9A-Fa-f-])(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    r"|[0-9A-Fa-f]{32})(?![0-9A-Fa-f-])"
)
MAC = re.compile(r"(?<![0-9A-Fa-f:-])(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:-])")
IPV4 = re.compile(r"(?<![\w.])(\d{1,3}(?:\.\d{1,3}){3})(?![\w]|\.\d)")
IP_OK_NETS = [
    ipaddress.ip_network(n)
    for n in ("127.0.0.0/8", "0.0.0.0/32", "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")
]
PRAGMA = "pii-scan: allow"

# Relative-path patterns skipped during directory walks.
SKIP_GLOBS = [".superpowers", ".superpowers/*", ".venv*", ".venv*/*", "*/__pycache__", "__pycache__", ".ruff_cache", ".ruff_cache/*", ".git", ".git/*", "*/.git", "*/.git/*", "tests/bats/bats-*", "tests/fixtures/pii", "tests/fixtures/pii/*"]


def skipped(rel):
    rel = rel.replace(os.sep, "/")
    return any(fnmatch.fnmatch(rel, g) for g in SKIP_GLOBS)


def scan_line(line, path, denylist):
    """Yield (rule, excerpt) for one text line."""
    if PRAGMA in line:
        return
    for m in EMAIL.finditer(line):
        if m.group(0).lower() in EMAIL_OK or EMAIL_DOMAIN_OK.search(m.group(1)):
            continue
        yield "email", m.group(0)
    for rx in (HOME_UNIX, HOME_MAC):
        for m in rx.finditer(line):
            if m.group(1).lower() not in HOME_OK:
                yield "home-path", m.group(0)
    if "sha256" not in line.lower() and not path.endswith("checksums.sha256"):
        for m in UUID.finditer(line):
            yield "uuid", m.group(0)
    for m in MAC.finditer(line):
        yield "mac", m.group(0)
    for m in IPV4.finditer(line):
        try:
            ip = ipaddress.ip_address(m.group(1))
        except ValueError:
            continue
        if not any(ip in n for n in IP_OK_NETS):
            yield "ipv4", m.group(0)
    low = line.lower()
    for term in denylist:
        if term in low:
            yield "denylist", term


def scan_text(text, path, denylist):
    hits = []
    for n, line in enumerate(text.splitlines(), 1):
        for rule, ex in scan_line(line, path, denylist):
            hits.append((path, n, rule, ex))
    return hits


def png_chunks(data):
    pos = 8
    while pos + 8 <= len(data):
        length, ctype = struct.unpack(">I4s", data[pos : pos + 8])
        yield ctype
        pos += 12 + length


def scan_file(path, denylist, ocr=False):
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as exc:
        print(f"pii_scan: cannot read {path}: {exc}", file=sys.stderr)
        return []
    if data.startswith(PNG_SIG):
        hits = [(path, 1, "png-metadata", c.decode("ascii", "replace")) for c in png_chunks(data) if c in PNG_META]
        if ocr and shutil.which("tesseract"):
            r = subprocess.run(["tesseract", path, "stdout"], capture_output=True, text=True, check=False)
            hits += scan_text(r.stdout, path, denylist)
        return hits
    if b"\0" in data[:8192]:
        return []
    return scan_text(data.decode("utf-8", errors="replace"), path, denylist)


def repo_root(path):
    """Git toplevel containing path; else cwd when path is under it; else path."""
    p = os.path.abspath(path)
    d = p if os.path.isdir(p) else os.path.dirname(p)
    try:
        r = subprocess.run(
            ["git", "-C", d, "rev-parse", "--show-toplevel"], capture_output=True, text=True, errors="replace", check=False
        )
        if r.returncode == 0 and r.stdout.strip():
            return os.path.realpath(r.stdout.strip())
    except OSError:  # git missing or not executable
        pass
    cwd = os.path.realpath(os.getcwd())
    if os.path.realpath(p).startswith(cwd + os.sep) or os.path.realpath(p) == cwd:
        return cwd
    return d


def walk(root, base):
    """Yield files under root; skip rules match paths relative to base."""
    if os.path.isfile(root):
        yield root
        return
    for dirpath, dirnames, filenames in os.walk(root):

        def rel(name, dirpath=dirpath):
            return os.path.relpath(os.path.realpath(os.path.join(dirpath, name)), base)

        dirnames[:] = sorted(d for d in dirnames if not skipped(rel(d)))
        for f in sorted(filenames):
            if not skipped(rel(f)):
                yield os.path.join(dirpath, f)


class HistoryError(Exception):
    pass


def _git_log(root, *args):
    """stdout of `git -C root log ARGS`; HistoryError when git is missing or fails."""
    try:
        r = subprocess.run(["git", "-C", root, "log", *args], capture_output=True, text=True, errors="replace", check=False)
    except OSError as exc:
        raise HistoryError(f"pii_scan: --history needs git ({exc})") from exc
    if r.returncode != 0:
        detail = r.stderr.strip().splitlines()[-1:] or ["git log failed"]
        raise HistoryError(f"pii_scan: --history: {root} is not a git repository or git log failed ({detail[0]})")
    return r.stdout


def scan_history(root, denylist):
    hits = []
    # Author and committer names and addresses (names matter for the denylist).
    hits += scan_text(_git_log(root, "--all", "--format=%an%n%ae%n%cn%n%ce"), "history:authors", denylist)
    out = _git_log(root, "-p", "--all", "--format=%H")
    cur, skip, header = "history", False, False
    for n, line in enumerate(out.splitlines(), 1):
        if line.startswith("diff --git a/"):
            cur = line[len("diff --git a/") :].split(" b/")[0]
            skip, header = skipped(cur), True
            continue
        if header:
            if line.startswith("@@"):
                header = False
            continue
        if skip:
            continue
        # Drop the diff marker (+, - or space): "+@decorator" is not a mailbox.
        if line[:1] in ("+", "-", " "):
            line = line[1:]
        for rule, ex in scan_line(line, cur, denylist):
            hits.append((f"history:{cur}", n, rule, ex))
    return hits


def load_denylist(path):
    terms = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            t = line.strip()
            if t and not t.startswith("#"):
                terms.append(t.lower())
    return terms


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("paths", nargs="+", metavar="PATH")
    ap.add_argument("--history", action="store_true")
    ap.add_argument("--denylist")
    ap.add_argument("--ocr", action="store_true")
    args = ap.parse_args(argv)
    try:
        denylist = load_denylist(args.denylist) if args.denylist else []
    except OSError as exc:
        print(f"pii_scan: {exc}", file=sys.stderr)
        return 2
    hits = []
    deny_real = os.path.realpath(args.denylist) if args.denylist else None
    for p in args.paths:
        if not os.path.exists(p):
            print(f"pii_scan: no such path: {p}", file=sys.stderr)
            return 2
        for f in walk(p, repo_root(p)):
            if os.path.basename(f) == ".pii-denylist" or os.path.realpath(f) == deny_real:
                continue
            hits += scan_file(f, denylist, args.ocr)
        if args.history and os.path.isdir(p):
            try:
                hits += scan_history(p, denylist)
            except HistoryError as exc:
                print(exc, file=sys.stderr)
                return 1
    for path, n, rule, ex in hits:
        print(f"{path}:{n}: {rule}: {ex.strip()[:100]}")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
