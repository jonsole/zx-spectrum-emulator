"""Runs every check of the Python port against the original, and says which
failed.

    python tests/run_all.py            everything (about 25 minutes)
    python tests/run_all.py --quick    the routine checks, not the whole flights

The 6502 core's own test (test_m6502.py) is left out; run it after changing
bbc/m6502.py. The first run flies each recorded flight once to fill the
cache in data/recordings, which adds a few minutes.
"""

import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent

ROUTINES = ["maths", "matrices", "points", "project", "clip", "visibility", "theme", "controls",
            "canopy", "dashboard", "flight"]
FLIGHTS = ["tour", "theme", "crash"]


def run(args):
    started = time.time()
    result = subprocess.run([sys.executable] + args, cwd=HERE.parent, capture_output=True, text=True)
    out = result.stdout + result.stderr
    failed = result.returncode != 0
    print(f"{' '.join(Path(a).name for a in args):28} {'FAILED' if failed else 'ok':6} {time.time() - started:5.0f} s")
    if failed:
        print("\n".join("    " + line for line in out.splitlines()[-25:]))
    return not failed


def main():
    quick = "--quick" in sys.argv
    ok = True
    for name in ROUTINES:
        ok = run([str(HERE / f"test_{name}.py")]) and ok
    if not quick:
        for flight in FLIGHTS:
            ok = run([str(HERE / "test_game.py"), flight]) and ok
    print("all passed" if ok else "SOME FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
