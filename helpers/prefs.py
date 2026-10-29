#!/usr/bin/env python3
"""Merge keys into a Rewaita preferences JSON file."""

import argparse
import json
import os
import sys
import time


def load(path):
    """Load a JSON object from path; missing -> {}; invalid -> backup + {}."""
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
    except FileNotFoundError:
        return {}
    try:
        data = json.loads(raw)
        if not isinstance(data, dict):
            raise TypeError("not a JSON object")
        return data
    except (ValueError, TypeError) as exc:
        bak = f"{path}.invalid-{time.strftime('%Y%m%d%H%M%S')}"
        with open(bak, "w", encoding="utf-8") as fh:
            fh.write(raw)
        print(f"prefs: {path} invalid ({exc}); saved as {bak}", file=sys.stderr)
        return {}


def dump(data):
    return json.dumps(data, indent=4, ensure_ascii=True)


def merge(path, updates):
    """Apply updates; return True if the file content changed."""
    data = load(path)
    before = dict(data)
    data.update(updates)
    try:
        with open(path, encoding="utf-8") as fh:
            current = fh.read()
    except FileNotFoundError:
        current = None
    new = dump(data)
    if current is not None and data == before and current.rstrip("\n") == new:
        return False
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = f"{path}.tmp-{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(new)
    os.replace(tmp, path)
    return True


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("merge")
    m.add_argument("file")
    m.add_argument("pairs", nargs="+", metavar="KEY=JSON")
    args = ap.parse_args(argv)
    updates = {}
    for pair in args.pairs:
        key, sep, val = pair.partition("=")
        if not sep or not key:
            print(f"prefs: bad KEY=JSON: {pair}", file=sys.stderr)
            return 2
        try:
            updates[key] = json.loads(val)
        except ValueError as exc:
            print(f"prefs: bad JSON for {key}: {exc}", file=sys.stderr)
            return 2
    try:
        changed = merge(args.file, updates)
    except OSError as exc:
        print(f"prefs: {exc}", file=sys.stderr)
        return 1
    return 0 if changed else 3


if __name__ == "__main__":
    sys.exit(main())
