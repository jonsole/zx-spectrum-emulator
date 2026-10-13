"""Moments from the original game, recorded at routine entries during
scripted flights, for checking the port's stateful routines.

A flight is a key script for bbc/run.py's machine. Flying it with a trap on
each routine of interest records, for each, a sample of the moments it was
called: the memory below &8000 (the game and the screen) and the registers,
just as the routine was entered. A test then replays each moment through
the original routine and the Python one and compares what they leave.

The samples are picked evenly over the whole flight (reservoir sampling with
a fixed seed), so a routine called a thousand times an iteration is sampled
as fairly as one called once. They contain the game's own memory, so they
are cached in data/recordings/ (gitignored), not committed.

    python tests/recorder.py tour ProjectPoint SetPointCoords
"""

import gzip
import pickle
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / "bbc"))

import beeb  # noqa: E402

CACHE = ROOT / "data" / "recordings"
VERSION = 1
SAMPLES = 150
MEMORY_TOP = 0x8000

# Each flight: (key script, iterations). Key scripts as bbc/run.py takes them.
FLIGHTS = {
    # Refuel, start up, open the throttle, brakes off; the plane takes off by
    # itself at about iteration 650 and climbs. Then a dive and a roll to the
    # right on the ailerons, some rudder, and a bank to the left that turns
    # it over the countryside.
    "tour": ("270-271:T 272-360:E 345-346:B 900-902:L 1000-1006:A 1050-1056:; 1100-1105:S 1200-1205:D", 1500),
    # The tour with the Theme: firing on the runway at 300 starts it, and the
    # guns are fired in the air every 250 iterations from 1000. The first
    # aliens land by 700 and are feeding (states 1 to 8) by the end. The
    # plane comes down at about 1680, so the flight stops before then.
    "theme": ("270-271:T 272-360:E 300-302:SHIFT 345-346:B 900-902:L 1000-1006:A 1050-1056:; "
              "1100-1105:S 1200-1205:D 1000-1002:SHIFT 1250-1252:SHIFT 1500-1502:SHIFT", 1650),
    # Too little throttle: the plane runs off the end of the runway still on
    # the ground and crashes at about iteration 960. RETURN is held from 900
    # to 1250, so a new game starts at once, and the second flight takes off.
    "crash": ("270-271:T 272-340:E 345-346:B 900-1250:RETURN 1270-1271:T 1272-1360:E 1345-1346:B", 1700),
}


def parse_keys(spec):
    ranges = []
    for part in spec.split():
        span, keys = part.split(":")
        lo, hi = (int(v) for v in span.split("-"))
        ranges.append((lo, hi, keys.split("+")))
    return ranges


class Reservoir:
    def __init__(self, machine, size, seed):
        self.machine = machine
        self.size = size
        self.random = random.Random(seed)
        self.count = 0
        self.samples = []

    def __call__(self):
        self.count += 1
        if len(self.samples) < self.size:
            self.samples.append(self.take())
            return
        j = self.random.randrange(self.count)
        if j < self.size:
            self.samples[j] = self.take()

    def take(self):
        m = self.machine
        cpu = m.cpu
        return beeb.Snapshot(bytes(m.mem[:MEMORY_TOP]), cpu.a, cpu.x, cpu.y, cpu.s, cpu.pc, cpu.p())


def _cache_file(flight, routine):
    return CACHE / flight / f"{routine}.v{VERSION}.pickle.gz"


def fly(flight, routines, size=SAMPLES):
    """Fly a flight with every routine trapped, and cache what was recorded."""
    keys, iterations = FLIGHTS[flight]
    m = beeb.Beeb(clock="cycles")
    m.boot()
    reservoirs = {}
    for i, name in enumerate(routines):
        r = Reservoir(m, size, seed=hash((flight, name)) & 0xFFFF if False else 1000 + i)
        reservoirs[name] = r
        addr = m.label(name)
        if addr in m.cpu.traps:
            raise RuntimeError(f"{name} shares a trap address")
        m.cpu.traps[addr] = r
    ranges = parse_keys(keys)
    for n in range(iterations):
        held = [k for lo, hi, ks in ranges if lo <= n < hi for k in ks]
        m.iterate(held)
    (CACHE / flight).mkdir(parents=True, exist_ok=True)
    for name, r in reservoirs.items():
        with gzip.open(_cache_file(flight, name), "wb", compresslevel=6) as f:
            pickle.dump({"calls": r.count, "samples": r.samples}, f)
    return {name: r.samples for name, r in reservoirs.items()}


def recordings(flight, routines, size=SAMPLES):
    """The recorded moments for each routine, flying the flight once for any
    not yet cached. Returns {routine: [Snapshot, ...]}."""
    out = {}
    missing = []
    for name in routines:
        path = _cache_file(flight, name)
        if path.exists():
            with gzip.open(path, "rb") as f:
                out[name] = pickle.load(f)["samples"]
        else:
            missing.append(name)
    if missing:
        out.update(fly(flight, missing, size))
    return out


def main():
    flight, routines = sys.argv[1], sys.argv[2:]
    recs = recordings(flight, routines)
    for name, samples in recs.items():
        print(f"{name:24} {len(samples)} samples")


if __name__ == "__main__":
    sys.exit(main())
