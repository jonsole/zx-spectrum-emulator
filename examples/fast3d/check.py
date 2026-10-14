"""Check fast3d's Z80 routines against model.py, and time them.

The routines (output/checks.bin, from checks.s) run in SkoolKit's simulator,
and every result is compared with the model's:

1. mul8s, for every one of the 65,536 pairs of signed bytes.
2. make_matrix, for every x angle against a spread of y and z (and the nine
   entries it keeps), and rotate with each matrix, on vertices that include
   every corner of the cube of signed bytes -- the largest sums.
3. divide, on the edges of what fits a byte and a random spread between.
4. project and transform, on random vertices, matrices and distances.

The T-states come from the simulator's clock, so the timings are exact; the
routines run from uncontended memory ($8000 up), as they should on a real
Spectrum.

    python build.py && python check.py
"""
from __future__ import annotations

import itertools
import random
import sys
from pathlib import Path

from skoolkit import CSimulator
from skoolkit.simulator import Simulator
from skoolkit.simutils import A, B, C, D, E, H, L, PC, SP, T

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import model                                                      # noqa: E402
from build import OUT, find_label                                # noqa: E402

RETURN = 0x5B00     # a return address nothing else runs: the printer buffer
STACK = 0x7FF0


class Machine:
    def __init__(self) -> None:
        memory = bytearray(65536)
        image = (OUT / "checks.bin").read_bytes()
        memory[0x8000:0x8000 + len(image)] = image
        self.sim = (CSimulator or Simulator)(memory, state={"iff": 0, "im": 1, "tstates": 0})
        self.memory = self.sim.memory
        self.sld = OUT / "checks.sld"
        self.labels: dict[str, int] = {}

    def label(self, name: str) -> int:
        if name not in self.labels:
            self.labels[name] = find_label(self.sld, name)
        return self.labels[name]

    def call(self, name: str, **registers: int) -> int:
        """Run a routine to its RET; the T-states it took."""
        regs = self.sim.registers
        for reg, value in registers.items():
            regs[{"A": A, "B": B, "C": C, "D": D, "E": E, "H": H, "L": L}[reg]] = value & 0xFF
        regs[SP] = STACK
        self.memory[STACK] = RETURN & 0xFF
        self.memory[STACK + 1] = RETURN >> 8
        start = regs[T]
        self.sim.run(self.label(name), RETURN)
        return regs[T] - start

    def reg(self, name: str) -> int:
        return self.sim.registers[{"A": A, "B": B, "C": C, "D": D, "E": E, "H": H, "L": L}[name]]

    def pair(self, high: str, low: str) -> int:
        return self.reg(high) << 8 | self.reg(low)

    def word(self, name: str) -> int:
        address = self.label(name)
        return self.memory[address] | self.memory[address + 1] << 8

    def poke_word(self, name: str, value: int) -> None:
        address = self.label(name)
        self.memory[address] = value & 0xFF
        self.memory[address + 1] = (value >> 8) & 0xFF

    def poke(self, address: int, data: bytes) -> None:
        for i, byte in enumerate(data):
            self.memory[address + i] = byte


def signed8(value: int) -> int:
    return value - 256 if value & 0x80 else value


def report(name: str, times: list[int]) -> None:
    low, high = min(times), max(times)
    spread = f"{low:,}" if low == high else f"{low:,}..{high:,}, mean {sum(times) / len(times):,.0f}"
    print(f"  {name:<14} {spread} T-states ({len(times):,} runs)")


def check_mul8s(m: Machine) -> list[str]:
    failures, times = [], []
    for a, b in itertools.product(range(-128, 128), repeat=2):
        times.append(m.call("mul8s", B=a, C=b))
        got = model.to_signed16(m.pair("H", "L"))
        if got != a * b and len(failures) < 10:
            failures.append(f"mul8s {a} * {b}: {got}, not {a * b}")
    report("mul8s", times)
    return failures


def set_angles(m: Machine, x: int, y: int, z: int) -> None:
    m.poke(m.label("angle_x"), bytes([x, y, z]))


def check_matrix_and_rotate(m: Machine) -> list[str]:
    failures, matrix_times, rotate_times = [], [], []
    rng = random.Random(3)
    corners = list(itertools.product((-128, 127), repeat=3))
    vertex_at = m.label("checks_vertex")
    angles = [(x, y, z) for x in range(256) for y in range(0, 256, 37) for z in range(0, 256, 53)]
    angles += [(rng.randrange(256), rng.randrange(256), rng.randrange(256)) for _ in range(2000)]
    for x, y, z in angles:
        set_angles(m, x, y, z)
        matrix_times.append(m.call("make_matrix"))
        want = model.make_matrix(x, y, z)
        got = [signed8(v) for v in m.memory[m.label("matrix"):m.label("matrix") + 9]]
        if got != want:
            failures.append(f"make_matrix {x},{y},{z}: {got}, not {want}")
            if len(failures) > 10:
                return failures
            continue
        vertices = corners + [tuple(rng.randrange(-128, 128) for _ in range(3)) for _ in range(4)]
        for vertex in vertices:
            m.poke(vertex_at, bytes(v & 0xFF for v in vertex))
            rotate_times.append(m.call("rotate", H=vertex_at >> 8, L=vertex_at))
            got = tuple(model.to_signed16(m.word(n)) for n in ("rot_x", "rot_y", "rot_z"))
            want_r = model.rotate(want, vertex)
            if got != want_r:
                failures.append(f"rotate {vertex} by {want}: {got}, not {want_r}")
                if len(failures) > 10:
                    return failures
    report("make_matrix", matrix_times)
    report("rotate", rotate_times)
    return failures


def check_divide(m: Machine) -> list[str]:
    failures, times = [], []
    rng = random.Random(4)
    cases = []
    for c in list(range(1, 256)):
        for q in (0, 1, 127, 128, 254, 255, 256):
            for r in (0, c - 1):
                n = q * c + r
                cases += [(n, c), (-n, c)]
    cases += [(rng.randrange(-32768, 32768), rng.randrange(1, 256)) for _ in range(20000)]
    cases += [(-32768, c) for c in (1, 127, 128, 129, 255)] + [(32767, c) for c in (1, 128, 255)]
    for n, c in cases:
        if not -32768 <= n <= 32767:
            continue
        times.append(m.call("divide", H=(n >> 8) & 0xFF, L=n & 0xFF, C=c))
        carry = m.sim.registers[1] & 1
        want = model.divide(n, c)
        if want is None:
            if not carry:
                failures.append(f"divide {n} / {c}: no carry, but it does not fit a byte")
        elif carry or model.to_signed16(m.pair("H", "L")) != want:
            failures.append(f"divide {n} / {c}: {'carry' if carry else model.to_signed16(m.pair('H', 'L'))}, not {want}")
        if len(failures) > 10:
            break
    report("divide", times)
    return failures


def check_transform(m: Machine) -> list[str]:
    failures, project_times, transform_times = [], [], []
    rng = random.Random(5)
    vertex_at, point_at = m.label("checks_vertex"), m.label("checks_points")
    for _ in range(300):
        x, y, z = (rng.randrange(256) for _ in range(3))
        set_angles(m, x, y, z)
        m.call("make_matrix")
        matrix = model.make_matrix(x, y, z)
        zoff = rng.choice((rng.randrange(28800, 36000), rng.randrange(256, 65536 - 28800)))
        m.poke_word("zoff", zoff)
        vertices = [tuple(rng.randrange(-128, 128) for _ in range(3)) for _ in range(16)]
        # project, one vertex at a time: off the screen or not, as the model says
        for vertex in vertices:
            rotated = model.rotate(matrix, vertex)
            for name, value in zip(("rot_x", "rot_y", "rot_z"), rotated):
                m.poke_word(name, value)
            if not 1 <= (rotated[2] + zoff) >> 8 <= 255:
                continue    # outside what project is for
            project_times.append(m.call("project"))
            carry = m.sim.registers[1] & 1
            got = None if carry else (m.reg("B"), m.reg("C"))
            want = model.project(rotated, zoff)
            if got != want:
                failures.append(f"project {rotated} zoff {zoff}: {got}, not {want}")
        # transform, the list in one go
        if not all(1 <= (model.rotate(matrix, v)[2] + zoff) >> 8 <= 255 for v in vertices):
            continue
        m.poke(vertex_at, bytes(c & 0xFF for v in vertices for c in v))
        transform_times.append(m.call("transform", H=vertex_at >> 8, L=vertex_at,
                                      D=point_at >> 8, E=point_at, B=len(vertices)))
        for i, vertex in enumerate(vertices):
            want = model.project(model.rotate(matrix, vertex), zoff)
            got = tuple(m.memory[point_at + 2 * i:point_at + 2 * i + 2])
            if (want is None and got[1] != 0xFF) or (want is not None and got != want):
                failures.append(f"transform {vertex} at {x},{y},{z} zoff {zoff}: {got}, not {want}")
        if len(failures) > 10:
            break
    report("project", project_times)
    report("transform", [t // 16 for t in transform_times])
    print("                 (transform: per vertex, of 16)")
    return failures


def main() -> None:
    m = Machine()
    failures = []
    for check in (check_mul8s, check_matrix_and_rotate, check_divide, check_transform):
        failures += check(m)
    if failures:
        print("\n".join(failures[:20]))
        sys.exit(f"{len(failures)} failures")
    print("All match the model.")


if __name__ == "__main__":
    main()
