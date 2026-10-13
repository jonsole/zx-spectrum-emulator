"""Checks spectrum/matrices.s and points.s against the Python port, on the
moments recorded during the tour flight: the whole game state after each
routine must match.

    python tests/test_zx_points.py
"""

import sys

import recorder
import zx
from model import matrices, points
from model import names as n

FLIGHT = "tour"


def main():
    print("Z80 matrices and points")
    recorder.recordings(FLIGHT, ["ProjectAxisAngle", "SetMatrices", "SetPointCoords", "SetObjPointCoords",
                                 "AddTempToPoint", "CopyWorkToPoint", "CopyPointToWork", "SetPointToOrigin"])
    ok = True
    with zx.Spectrum() as z:
        checks = [
            ("ProjectAxisAngle", "project_axis_angle", lambda s: dict(af=s.y << 8),
             lambda s: matrices.project_axis_angle(s.y)),
            ("SetMatrices", "set_matrices", lambda s: {}, lambda s: matrices.set_matrices()),
            ("SetPointCoords", "set_point_coords",
             lambda s: dict(af=s.mem[n.GG] << 8, bc=s.mem[n.matrixNumber]),
             lambda s: points.set_point_coords(s.mem[n.GG], s.mem[n.matrixNumber])),
            ("SetObjPointCoords", "set_obj_point_coords",
             lambda s: dict(af=s.mem[n.GG] << 8, bc=s.mem[n.matrixNumber]),
             lambda s: points.set_obj_point_coords(s.mem[n.GG], s.mem[n.matrixNumber])),
            ("AddTempToPoint", "add_temp_to_point", lambda s: dict(af=s.x << 8, bc=s.y),
             lambda s: points.add_temp_to_point(s.x, s.y)),
            ("CopyWorkToPoint", "copy_work_to_point", lambda s: dict(af=s.y << 8, bc=s.x),
             lambda s: points.copy_work_to_point(s.x, s.y)),
            ("CopyPointToWork", "copy_point_to_work", lambda s: dict(af=s.y << 8, bc=s.x),
             lambda s: points.copy_point_to_work(s.y, s.x)),
            ("SetPointToOrigin", "set_point_to", lambda s: dict(af=0, hl=s.x),
             lambda s: points.set_point_to(s.x, 0)),
        ]
        for name, label, regs, py in checks:
            ok = zx.check_recorded(z, FLIGHT, name, label, regs, py) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
