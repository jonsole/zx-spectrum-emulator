"""Checks model/canopy.py against the original on moments recorded during the
tour flight, leaving out the BBC's own drawing code bytes (clip.SELF_MODIFIED
and canopy.DRAWING_CODE), which only its line drawer reads.

DrawGunSights reads the I key; it is checked with I up and down at random,
the same on both sides.

    python tests/test_canopy.py
"""

import sys

from harness import Check, booted, rng
import beeb
import recorder
import replay
from model import canopy, clip, hardware, memory

FLIGHT = "tour"
EXCLUDED = [(a, a + 1) for a in clip.SELF_MODIFIED + canopy.DRAWING_CODE]

CHECKS = {
    "DrawCanopyView": canopy.draw_canopy_view,
    "DrawHalfHorizon": canopy.draw_half_horizon,
    "EraseCanopyLines": canopy.erase_canopy_lines,
    "FlipColours": canopy.flip_colours,
}


def check(name, run, with_keys=False):
    m = booted()
    samples = recorder.recordings(FLIGHT, [name])[name]
    r = rng()
    c = Check(f"{name} ({FLIGHT})")
    for snap in samples:
        held = {"I"} if with_keys and r.random() < 0.5 else set()
        m.keys = held
        codes = {hardware.KEY_CODES[k] for k in held}
        hardware.keys = lambda code: code in codes
        expected = replay.replay(m, beeb.Snapshot(snap.mem, snap.a, snap.x, snap.y, snap.s, snap.pc, snap.p))
        memory.load(snap.mem)
        run()
        diffs = replay.compare(snap, expected, bytes(memory.M[:len(snap.mem)]), EXCLUDED)
        c.compare(f"keys {sorted(held)}", [], diffs)
    m.keys = set()
    hardware.keys = hardware._no_keys
    return c.report()


def main():
    print("canopy")
    recorder.recordings(FLIGHT, list(CHECKS) + ["DrawGunSights"])
    ok = True
    for name, run in CHECKS.items():
        ok = check(name, run) and ok
    ok = check("DrawGunSights", canopy.draw_gun_sights, with_keys=True) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
