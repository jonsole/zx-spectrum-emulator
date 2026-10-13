"""Checks model/points.py against the original on moments recorded during
the tour flight (tests/recorder.py).

    python tests/test_points.py
"""

import sys

import recorder
from replay import check_recorded
from model import points
from model import names as n

FLIGHT = "tour"

CHECKS = {
    "SetPointCoords": lambda s: points.set_point_coords(s.mem[n.GG], s.mem[n.matrixNumber]),
    "SetObjPointCoords": lambda s: points.set_obj_point_coords(s.mem[n.GG], s.mem[n.matrixNumber]),
    "AddTempToPoint": lambda s: points.add_temp_to_point(s.x, s.y),
    "CopyWorkToPoint": lambda s: points.copy_work_to_point(s.x, s.y),
    "CopyPointToWork": lambda s: points.copy_point_to_work(s.y, s.x),
    "SetPointToOrigin": lambda s: points.set_point_to(s.x, 0),
    "AddPointToObject": lambda s: points.add_point_to_object(s.x, s.y),
    "SetObjectToOrigin": lambda s: points.set_object_to_origin(s.y),
}


def main():
    print("points")
    recorder.recordings(FLIGHT, list(CHECKS))       # fly once for any not cached
    ok = True
    for name, run in CHECKS.items():
        ok = check_recorded(FLIGHT, name, run) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
