"""Make helpers/ importable under `python3 -I` and run helper CLIs."""

import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HELPERS = os.path.join(ROOT, "helpers")
FIXTURES = os.path.join(ROOT, "tests", "fixtures")
if HELPERS not in sys.path:
    sys.path.insert(0, HELPERS)


def run(helper, *args, stdin=None, cwd=None):
    """Run helpers/<helper>.py under -I; return CompletedProcess (text mode)."""
    return subprocess.run(
        [sys.executable, "-I", os.path.join(HELPERS, helper + ".py"), *args],
        input=stdin,
        capture_output=True,
        text=True,
        cwd=cwd,
        check=False,
    )
