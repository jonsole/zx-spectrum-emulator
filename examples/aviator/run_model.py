"""Runs the Python port of Aviator and saves what the Spectrum would show.

    python run_model.py --iterations 1300 --keys "270-271:T 272-360:E 345-346:B" --every 100

The keys are a script, as bbc/run.py takes them. The screens are saved in
output/ as PNGs (and the last as a .scr). --bbc also saves what the
original shows at the same moments, run in bbc/ with the same keys, side by
side with the port's.
"""

import argparse
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "bbc"))

from model import game, hardware, zx  # noqa: E402


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
    ap.add_argument("--png", default=str(HERE / "output" / "zx.png"))
    ap.add_argument("--every", type=int, default=0)
    ap.add_argument("--bbc", action="store_true")
    args = ap.parse_args()

    screen = zx.Screen()
    screen.install()
    clock = [0]

    def tick():
        clock[0] += 3
        return clock[0]

    hardware.clock = tick
    beeb_machine = None
    if args.bbc:
        import beeb
        beeb_machine = beeb.Beeb()
        beeb_machine.boot()
    g = game.Game()
    ranges = parse_keys(args.keys)
    out = Path(args.png)
    out.parent.mkdir(exist_ok=True)
    started = time.time()

    def save(path):
        img = screen.image()
        if beeb_machine is not None:
            from PIL import Image
            other = beeb_machine.render(scale=2).resize((512, 384))
            both = Image.new("RGB", (1040, 384))
            both.paste(other, (0, 0))
            both.paste(img, (528, 0))
            img = both
        img.save(path)

    for n in range(args.iterations):
        held = [k for lo, hi, ks in ranges if lo <= n < hi for k in ks]
        codes = {hardware.KEY_CODES[k] for k in held}
        hardware.keys = lambda code: code in codes
        over = g.iterate()
        if beeb_machine is not None:
            beeb_machine.iterate(held)
        if over is not None:
            print(f"iteration {n}: {type(over).__name__}")
        if args.every and (n + 1) % args.every == 0:
            save(out.with_name(f"{out.stem}-{n + 1}{out.suffix}"))
    save(out)
    out.with_suffix(".scr").write_bytes(screen.scr())
    print(f"{args.iterations} iterations in {time.time() - started:.1f} s; saved {out}")


if __name__ == "__main__":
    sys.exit(main())
