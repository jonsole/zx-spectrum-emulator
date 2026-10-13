"""Checks model/visibility.py against the original on moments recorded during
the tour flight (tests/recorder.py).

    python tests/test_visibility.py
"""

import sys

import recorder
from replay import check_recorded
from model import visibility as v
from model import names as n

FLIGHT = "tour"


CHECKS = {
    "NextObjectGroup": lambda s: v.next_object_group(s.y),
    "SetObjectCoords": lambda s: v.set_object_coords(s.mem[n.GG]),
    "ProcessHorizonLine": lambda s: v.process_horizon_line(s.mem[n.L], s.mem[n.M]),
    "ProcessRunwayLine": lambda s: v.process_runway_line(),
    "ProcessLine": lambda s: v.process_line(s.mem[n.lineId], check_distance=not s.mem[n.HH]),
    "ShowOrHideLine": lambda s: v.show_or_hide_line(s.mem[n.lineId]),
    "UpdateLinesToShow": lambda s: v.update_lines_to_show(),
    "ProcessLinesToHide": lambda s: v.process_lines_to_hide(),
    "ProcessLinesToShow": lambda s: v.process_lines_to_show(),
}


def check_returns():
    """The two distance checks return their verdict in A, which the memory
    comparison doesn't see, so they are checked on their own."""
    from harness import Check, booted
    import replay
    from model import memory
    m = booted()
    recs = recorder.recordings(FLIGHT, ["CheckObjDistance", "CheckLineDistance"])
    ok = True
    for name, port in (("CheckObjDistance", lambda s: v.check_obj_distance(s.y, s.a, s.mem[n.T], s.mem[n.K])),
                       ("CheckLineDistance", lambda s: v.check_line_distance(s.x, s.y))):
        c = Check(f"{name} ({FLIGHT})")
        for snap in recs[name]:
            replay.replay(m, snap)
            memory.load(snap.mem)
            c.compare(f"a={snap.a:02X} x={snap.x:02X} y={snap.y:02X}", m.cpu.a, port(snap))
        ok = c.report() and ok
    return ok


def main():
    print("visibility")
    recorder.recordings(FLIGHT, list(CHECKS) + ["CheckObjDistance", "CheckLineDistance"])
    ok = check_returns()
    for name, run in CHECKS.items():
        ok = check_recorded(FLIGHT, name, run) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
