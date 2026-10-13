"""Where the Spectrum version's time goes: snapshot_probe's profile of the
stage 1 demo's iterations (from the HALT that starts each to the next),
put back on the source by routine and by line.

    python tests/zx_profile.py [--updates 100] [--lines 30] [--routine NAME ...]

A routine is the code from one non-local label to the next. --routine lists
one routine instruction by instruction, with the runs and T-states an
iteration of each.
"""

import argparse
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

import zx as zxprobe


def read_sld(sld):
    lines, labels = {}, {}
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--updates", type=int, default=100)
    ap.add_argument("--lines", type=int, default=30)
    ap.add_argument("--routine", nargs="+")
    args = ap.parse_args()
    source_of, labels = read_sld(zxprobe.SLD)
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "profile.txt"
        with zxprobe.Spectrum() as z:
            halt = z.address("fly_recorded.wait")
            z.request(f"runto {halt:X} 50")
            z.request(f"profile {halt + 1:X} {halt:X} {args.updates} {out.as_posix()}")
        counts = [tuple(int(v, 16) if i == 0 else int(v) for i, v in enumerate(row.split()))
                  for row in out.read_text().splitlines()]
    label_addrs = sorted(labels)
    by_routine = defaultdict(int)
    by_line = defaultdict(lambda: [0, 0])
    total = 0
    k = 0
    for addr, runs, t in sorted(counts):
        while k + 1 < len(label_addrs) and label_addrs[k + 1] <= addr:
            k += 1
        routine = labels[label_addrs[k]] if label_addrs[k] <= addr else "?"
        by_routine[routine] += t
        by_line[source_of.get(addr, ("?", addr))][0] += runs
        by_line[source_of.get(addr, ("?", addr))][1] += t
        total += t
    n = args.updates
    print(f"{n} iterations, {total / n:,.0f} T-states each ({total / n / 69888:.1f} frames)\n")
    if args.routine:
        named = {name: a for a, name in labels.items()}
        for routine in args.routine:
            first = named[routine]
            end = min([a for a in label_addrs if a > first] + [0x10000])
            print(f"{routine}\n{'addr':<6}{'runs/it':>10}{'T/it':>9}  source line")
            for addr, runs, t in sorted(counts):
                if first <= addr < end:
                    path, line = source_of.get(addr, ("?", 0))
                    print(f"{addr:04X}  {runs / n:>10.1f}{t / n:>9,.0f}  {Path(path).name}:{line}")
        return
    print(f"{'routine':<26}{'T/iteration':>12}{'share':>8}")
    for routine, t in sorted(by_routine.items(), key=lambda kv: -kv[1]):
        if t / n >= 200:
            print(f"{routine:<26}{t / n:>12,.0f}{100 * t / total:>7.1f}%")
    texts = {}
    print(f"\n{'source line':<24}{'runs/it':>9}{'T/it':>9}{'share':>7}  code")
    for (path, line), (runs, t) in sorted(by_line.items(), key=lambda kv: -kv[1][1])[:args.lines]:
        if path not in texts:
            try:
                texts[path] = Path(path).read_text().splitlines()
            except OSError:
                texts[path] = []
        code = texts[path][line - 1].strip() if 0 < line <= len(texts[path]) else ""
        print(f"{Path(path).name + ':' + str(line):<24}{runs / n:>9.1f}{t / n:>9,.0f}{100 * t / total:>6.1f}%  {code[:50]}")


if __name__ == "__main__":
    sys.exit(main())
