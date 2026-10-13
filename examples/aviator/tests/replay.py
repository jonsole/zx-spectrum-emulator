"""Replaying recorded moments through the original and the port.

replay() takes one recorded moment, runs the original routine from it on the
6502 to its return, and gives back what it left; the test then runs the
Python version from the same moment (memory.load(snap.mem)) and compare()
lists every byte that differs, by label, outside the places that are only
scratch:

- the zero-page temporaries P to HH, which the original uses to pass
  arguments and results, and which the port keeps in Python variables;
- the stack, below where it stood when the routine was entered;
- the screen, which the port draws on the Spectrum's instead.
"""

import bisect

import harness  # noqa: F401  (sets up the paths)
import beeb
from model import names

SCRATCH = [(names.P, names.HH + 1)]
SCREEN = (0x5800, 0x8000)

_labels = None


def describe(addr):
    """An address as label+offset, using the nearest label at or below it."""
    global _labels
    if _labels is None:
        pairs = sorted((v, k) for k, v in vars(names).items() if isinstance(v, int) and k[0] != "_")
        _labels = ([v for v, _ in pairs], [k for _, k in pairs])
    values, keys = _labels
    i = bisect.bisect_right(values, addr) - 1
    if i < 0:
        return f"&{addr:04X}"
    off = addr - values[i]
    return f"{keys[i]}+{off}" if off else keys[i]


def replay(machine, snap):
    """Run the routine the moment was recorded at, on the 6502, from that
    moment until it returns. Returns the memory below &8000 afterwards."""
    machine.restore(beeb.Snapshot(snap.mem, snap.a, snap.x, snap.y, snap.s, snap.pc, snap.p))
    cpu = machine.cpu
    entry = snap.pc
    machine.call(entry)
    return bytes(machine.mem[:len(snap.mem)])


def excluded(snap, extra=()):
    ranges = list(SCRATCH) + [SCREEN] + list(extra)
    # The stack page from 64 bytes below where it stood to the top; the
    # page's lower part holds real variables (lineBufferU and the m values).
    ranges.append((0x100 + max(0, snap.s - 0x40), 0x200))
    return ranges


def compare(snap, expected, actual, extra=()):
    """The bytes that differ outside the excluded ranges, as a list of
    (label, original, port), at most 12 of them."""
    if expected == actual:
        return []
    skip = excluded(snap, extra)
    diffs = []
    for i, (e, a) in enumerate(zip(expected, actual)):
        if e != a and not any(lo <= i < hi for lo, hi in skip):
            diffs.append((describe(i), e, a))
            if len(diffs) >= 12:
                break
    return diffs


def check_recorded(flight, name, run, extra=()):
    """Replay every recorded moment of routine `name` from `flight` through the
    original and through run(snap), which calls the Python version with the
    arguments it takes from the snapshot; report any byte that differs."""
    from harness import Check, booted
    import recorder
    from model import memory
    m = booted()
    samples = recorder.recordings(flight, [name])[name]
    c = Check(f"{name} ({flight})")
    for snap in samples:
        expected = replay(m, snap)
        memory.load(snap.mem)
        run(snap)
        diffs = compare(snap, expected, bytes(memory.M[:len(snap.mem)]), extra)
        c.compare(f"pc &{snap.pc:04X} a={snap.a:02X} x={snap.x:02X} y={snap.y:02X}", [], diffs)
    return c.report()
