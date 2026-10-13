"""Checks spectrum/visibility.s against the Python port, on the moments
recorded during the tour and theme flights: the whole game state after
each routine must match.

    python tests/test_zx_visibility.py [tour|theme]
"""

import sys

from harness import Check
import recorder
import zx
from model import memory, visibility as v
from model import names as n

ROUTINES = [
    ("NextObjectGroup", "next_object_group", lambda s: dict(af=s.y << 8), lambda s: v.next_object_group(s.y)),
    ("SetObjectCoords", "set_object_coords", lambda s: dict(af=s.mem[n.GG] << 8),
     lambda s: v.set_object_coords(s.mem[n.GG])),
    ("ProcessHorizonLine", "process_horizon_line", lambda s: dict(hl=(s.mem[n.M] << 8) | s.mem[n.L]),
     lambda s: v.process_horizon_line(s.mem[n.L], s.mem[n.M])),
    ("ProcessRunwayLine", "process_runway_line", lambda s: {}, lambda s: v.process_runway_line()),
    ("ProcessLine", "process_line", lambda s: dict(af=s.mem[n.lineId] << 8, bc=0 if s.mem[n.HH] else 1),
     lambda s: v.process_line(s.mem[n.lineId], check_distance=not s.mem[n.HH])),
    ("ShowOrHideLine", "show_or_hide_line", lambda s: dict(af=s.mem[n.lineId] << 8),
     lambda s: v.show_or_hide_line(s.mem[n.lineId])),
    ("UpdateLinesToShow", "update_lines_to_show", lambda s: {}, lambda s: v.update_lines_to_show()),
    ("ProcessLinesToHide", "process_lines_to_hide", lambda s: {}, lambda s: v.process_lines_to_hide()),
    ("ProcessLinesToShow", "process_lines_to_show", lambda s: {}, lambda s: v.process_lines_to_show()),
]


def check_line_distance(z, flight):
    c = Check(f"check_line_distance ({flight})")
    for snap in recorder.recordings(flight, ["CheckLineDistance"])["CheckLineDistance"]:
        z.put_state(snap.mem)
        out = z.call("check_line_distance", af=snap.y << 8, bc=snap.x)
        memory.load(snap.mem)
        c.compare((snap.x, snap.y), v.check_line_distance(snap.x, snap.y), out["a"])
    return c.report()


def main():
    flight = sys.argv[1] if len(sys.argv) > 1 else "tour"
    print(f"Z80 visibility ({flight})")
    recorder.recordings(flight, [r[0] for r in ROUTINES] + ["CheckLineDistance"])
    ok = True
    with zx.Spectrum() as z:
        ok = check_line_distance(z, flight)
        for name, label, regs, py in ROUTINES:
            ok = zx.check_recorded(z, flight, name, label, regs, py) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
