"""Runs the original BBC Micro Aviator in Python and saves what it shows.

    python bbc/run.py --iterations 40 --png output/bbc.png
    python bbc/run.py --iterations 1300 --keys "270-271:T 272-360:E 345-346:B" --every 100

--keys holds keys down for a range of iterations: "10-60:E" holds E (more
throttle) from iteration 10 to 59; several ranges are separated by spaces and
several keys by "+" ("0-5:S+A"). Key names are the BBC's (A, S, SHIFT, ",",
";" ...). That example refuels (the tank fills while the engine is off),
starts the engine with T, opens the throttle with E, lets the brakes off with
B, and the plane takes off by itself at about iteration 650.
--every N also saves every Nth iteration's screen as <png stem>-<n>.png.
--clock cycles runs the clock from the CPU's cycle count at 2 MHz instead of
advancing it a fixed step a read, so the hidden-line work is as on the real
machine.
"""

import argparse
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import beeb  # noqa: E402


def parse_keys(spec):
    ranges = []
    for part in spec.split():
        span, keys = part.split(":")
        lo, hi = (int(v) for v in span.split("-"))
        ranges.append((lo, hi, keys.split("+")))
    return ranges


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--iterations", type=int, default=30)
    ap.add_argument("--keys", default="")
    ap.add_argument("--png", default=str(HERE.parent / "output" / "bbc.png"))
    ap.add_argument("--every", type=int, default=0)
    ap.add_argument("--clock", choices=("per-read", "cycles"), default="per-read")
    args = ap.parse_args()

    machine = beeb.Beeb(clock=args.clock)
    started = time.time()
    boot = machine.boot()
    print(f"booted in {boot:,} cycles")
    ranges = parse_keys(args.keys)
    out = Path(args.png)
    out.parent.mkdir(exist_ok=True)
    total = 0
    for n in range(args.iterations):
        keys = [k for lo, hi, ks in ranges if lo <= n < hi for k in ks]
        cycles = machine.iterate(keys)
        total += cycles
        if args.every and (n + 1) % args.every == 0:
            machine.render().save(out.with_name(f"{out.stem}-{n + 1}{out.suffix}"))
    machine.render().save(out)
    seconds = time.time() - started
    if args.iterations:
        print(f"{args.iterations} iterations, {total / args.iterations:,.0f} cycles each on average "
              f"({total / args.iterations / beeb.CYCLES_PER_CS:.1f} cs at 2 MHz); {seconds:.1f} s here")
    print(f"saved {out}")


if __name__ == "__main__":
    sys.exit(main())
