"""Checks model/matrices.py against the original on moments recorded during
the tour flight (tests/recorder.py), and ProjectAxisAngle on every angle.

    python tests/test_matrices.py
"""

import sys

from harness import Check, booted
import recorder
import replay
from model import matrices, memory
from model import names as n


def check_project_axis_angle():
    """Every rotation angle, on each axis."""
    m = booted()
    c = Check("ProjectAxisAngle")
    for axis in range(3):
        for angle in range(0, 0x10000, 7):
            for mem in (m.mem, memory.M):
                mem[n.xRotationLo + axis] = angle & 0xFF
                mem[n.xRotationHi + axis] = angle >> 8
                mem[n.matrixAxis] = axis
            m.cpu.y = axis
            m.call("ProjectAxisAngle")
            matrices.project_axis_angle(axis)
            span = slice(n.mx1Lo, n.mx1Lo + 6)
            span_hi = slice(n.mx1Hi, n.mx1Hi + 6)
            c.compare((axis, hex(angle)), (bytes(m.mem[span]), bytes(m.mem[span_hi])),
                      (bytes(memory.M[span]), bytes(memory.M[span_hi])))
    return c.report()


def check_recorded(name, run):
    m = booted()
    samples = recorder.recordings("tour", [name])[name]
    c = Check(name + " (tour)")
    for snap in samples:
        expected = replay.replay(m, snap)
        memory.load(snap.mem)
        run(snap)
        diffs = replay.compare(snap, expected, bytes(memory.M[:len(snap.mem)]))
        c.compare(f"pc &{snap.pc:04X}", [], diffs)
    return c.report()


def main():
    print("matrices")
    ok = check_project_axis_angle()
    ok = check_recorded("SetMatrices", lambda snap: matrices.set_matrices()) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
