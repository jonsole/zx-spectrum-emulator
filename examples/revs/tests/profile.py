"""Where the Revs engine's time goes, over one lap at the camera's speed.

    python examples/revs/tests/profile.py [--lines 40] [--no-build]
    python examples/revs/tests/profile.py --routine raster

--routine lists one routine instruction by instruction instead, with how
many times an update each ran: a macro's expansion all has the one source
line it was invoked from, so this is how to see inside VB_POINT or CS_LINE.

Runs the same lap as run_tests.py's `speed` check, through snapshot_probe's
`profile` command, which counts every instruction from the first after the
HALT to the next HALT by its address. This script puts those counts back on
the source: the T-states each routine took per update, and the source lines
that took the most, with how many times an update each ran.

A routine is the code from one non-local label to the next, so a `.loop`
counts towards the label above it. The frame interrupt's handler shows up
as the routine it is in; its acknowledge is charged to whatever instruction
it landed after.
"""

import argparse
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
REVS = HERE.parent
sys.path.insert(0, str(HERE))

from probe import Probe, find_probe, read_symbols  # noqa: E402

SNAPSHOT = REVS / "output" / "revs.z80"
SLD = REVS / "output" / "revs.sld"
STARTUP_FRAMES = 200


def read_sld(sld: Path):
    """The source line each code address was assembled from, and the code
    labels (not equates) by address."""
    lines = {}
    labels = {}
    for row in sld.read_text().splitlines():
        f = row.split("|")
        if len(f) < 8:
            continue
        if f[6] == "T":
            lines[int(f[5])] = (f[0], int(f[1]))
        elif f[6] == "L":
            parts = f[7].split(",")
            if len(parts) > 2 and "+equ" not in parts[3:] and not parts[2]:
                labels.setdefault(int(f[5]), parts[1])
    return lines, labels


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--lines", type=int, default=40, help="how many source lines to list")
    parser.add_argument("--no-build", action="store_true", help="use output/ as it is")
    parser.add_argument("--probe", help="the snapshot_probe executable")
    parser.add_argument("--updates", type=int, help="updates to profile (default: a lap)")
    parser.add_argument("--routine", nargs="+", help="list these routines instruction by instruction")
    args = parser.parse_args()

    exe = find_probe(args.probe)
    if exe is None:
        sys.exit("snapshot_probe not built -- run: cpp-core/build.ps1 -Release -Target snapshot_probe")
    if not args.no_build:
        if subprocess.run([sys.executable, str(REVS / "build.py"), "--define", "SYNCED"],
                          capture_output=True).returncode != 0:
            sys.exit("build.py failed")
    symbols = read_symbols(SLD)
    source_of, labels = read_sld(SLD)

    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "profile.txt"
        with Probe(exe, symbols) as probe:
            probe.load(SNAPSHOT)
            probe.runto("main_loop", STARTUP_FRAMES)
            halt = symbols["main_loop.wait_frame"]
            updates = args.updates or -(-symbols["TRACK_LEN"] * 256 // probe.byte("cam_speed"))
            probe.request(f"profile {halt + 1:X} {halt:X} {updates} {out}")
        counts = []
        for row in out.read_text().splitlines():
            a, runs, t = row.split()
            counts.append((int(a, 16), int(runs), int(t)))

    label_addrs = sorted(labels)
    by_routine = defaultdict(int)
    by_line = defaultdict(lambda: [0, 0])
    total = 0
    k = 0
    for addr, runs, t in counts:
        while k + 1 < len(label_addrs) and label_addrs[k + 1] <= addr:
            k += 1
        routine = labels[label_addrs[k]] if label_addrs and label_addrs[k] <= addr else "?"
        by_routine[routine] += t
        where = source_of.get(addr, ("?", addr))
        by_line[where][0] += runs
        by_line[where][1] += t
        total += t

    print(f"{updates} updates, {total / updates:,.0f} T-states an update on average\n")
    if args.routine:
        named = {name: addr for addr, name in labels.items()}
        for routine in args.routine:
            if routine not in named:
                sys.exit(f"no routine called {routine}")
            first = named[routine]
            later = [a for a in label_addrs if a > first]
            end = later[0] if later else 0x10000
            print(f"{routine}\n{'addr':<6}{'runs/upd':>10}{'T/upd':>9}  source line")
            for addr, runs, t in counts:
                if first <= addr < end:
                    path, line = source_of.get(addr, ("?", 0))
                    print(f"{addr:04X}  {runs / updates:>10.2f}{t / updates:>9,.0f}  {path}:{line}")
            print()
        return
    print(f"{'routine':<24}{'T/update':>10}{'share':>8}")
    for routine, t in sorted(by_routine.items(), key=lambda kv: -kv[1]):
        if t / updates < 50:
            continue
        print(f"{routine:<24}{t / updates:>10,.0f}{100 * t / total:>7.1f}%")

    texts = {}
    print(f"\n{'source line':<22}{'runs/upd':>9}{'T/upd':>8}{'share':>7}  code")
    for (path, line), (runs, t) in sorted(by_line.items(), key=lambda kv: -kv[1][1])[:args.lines]:
        if path not in texts:
            try:
                texts[path] = (REVS / path).read_text().splitlines()
            except OSError:
                texts[path] = []
        code = texts[path][line - 1].strip() if 0 < line <= len(texts[path]) else ""
        print(f"{path + ':' + str(line):<22}{runs / updates:>9.1f}{t / updates:>8,.0f}"
              f"{100 * t / total:>6.1f}%  {code[:60]}")


if __name__ == "__main__":
    main()
