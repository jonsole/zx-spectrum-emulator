"""Check fast3d's Z80 routines against model.py, and time them.

The routines (output/checks.bin, from checks.s) run in SkoolKit's simulator,
and every result is compared with the model's:

1. mul8s, for every one of the 65,536 pairs of signed bytes.
2. make_matrix, for every x angle against a spread of y and z (and the nine
   entries it keeps), and rotate with each matrix, on vertices that include
   every corner of the cube of signed bytes -- the largest sums.
3. divide, on the edges of what fits a byte and a random spread between.
4. project and transform, on random vertices, matrices and distances.
5. draw_line, every pixel of every byte of the screen, against model.line,
   on lines every way and length and on both screens, $4000 and $C000; and
   clear_box.
6. Clipping: divide_wide, project_wide and transform_wide against the model;
   clip_line on 60,000 lines across random windows, from inside the window
   to 16,000 pixels out, against model.clip_line, every end; and
   draw_line_clipped, every pixel. (model.clip_line is itself checked
   against exact geometry by clip_geometry.py.)
7. Objects and the camera: set_camera, then cull_object, object_matrix and
   transform_object on objects all round the camera, near and far, against
   the model -- the camera's matrix and constant, T, whether culled, M, and
   every point. (cull_geometry.py holds the model to exact geometry.)
8. The near plane: cut_edges on objects straddling it, from cameras all
   round, against model.object_lines -- every point and every cut line.
   (near_geometry.py holds the model to exact geometry.)
9. The demo: draw_frame, frame after frame for each object through a whole
   swing in and out, on the screen at $4000 (and so clearing its own last
   box), against model.py's picture of the same frame -- clipped to the
   window, frame and all; and timed. Every other frame goes to
   output/demo.gif. Then again with the camera jumping about, now and then
   close enough to an object to cut it at the near plane.
10. A world that wraps (WORLD_WRAP, output/checks_wrap.bin and
   demo_wrap.bin): the objects-and-camera check with cameras by the world's
   edges and corners and objects across them, against the model's answers
   for the same scene moved from the edges; and the demo with jumps again,
   the whole world moved by 32,768 on each axis, so that the flight
   straddles every edge, against the model's picture of it where it was.
   (cull_geometry.py holds the wrapping model to the scene moved.)
11. Back faces: facing_edges on objects of one part, of three and of none,
   from cameras all round, near, far and straddling the near plane, against
   model.facing_edges -- every edge kept or left out -- and cut_edges after
   it, on just those; the faces and the edges timed apart.
   (face_geometry.py holds the model to exact geometry.)

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
    def __init__(self, build: str = "checks") -> None:
        """build: checks, or checks_wrap (with WORLD_WRAP)."""
        memory = bytearray(65536)
        image = (OUT / f"{build}.bin").read_bytes()
        memory[0x8000:0x8000 + len(image)] = image
        self.sim = (CSimulator or Simulator)(memory, state={"iff": 0, "im": 1, "tstates": 0})
        self.memory = self.sim.memory
        self.sld = OUT / f"{build}.sld"
        self.labels: dict[str, int] = {}

    def label(self, name: str) -> int:
        if name not in self.labels:
            self.labels[name] = find_label(self.sld, name)
        return self.labels[name]

    def call(self, name: str, **registers: int) -> int:
        """Run a routine to its RET; the T-states it took."""
        return sum(self.call_until(name, None, **registers))

    def call_until(self, name: str, until: str | None, **registers: int) -> tuple[int, int]:
        """Run a routine to its RET: the T-states to the label until, and
        from there to the RET (all in the second, with no until)."""
        regs = self.sim.registers
        for reg, value in registers.items():
            regs[{"A": A, "B": B, "C": C, "D": D, "E": E, "H": H, "L": L}[reg]] = value & 0xFF
        regs[SP] = STACK
        self.memory[STACK] = RETURN & 0xFF
        self.memory[STACK + 1] = RETURN >> 8
        start = middle = regs[T]
        pc = self.label(name)
        if until:
            self.sim.run(pc, self.label(until))
            middle, pc = regs[T], self.label(until)
        self.sim.run(pc, RETURN)
        return middle - start, regs[T] - middle

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


def render(lines: list, base: int) -> bytes:
    screen = bytearray(6144)
    for line in lines:
        for x, y in model.line(*line):
            screen[model.screen_address(x, y, base) - base] |= 0x80 >> (x & 7)
    return bytes(screen)


def check_lines(m: Machine) -> list[str]:
    failures, times, per_pixel_x, per_pixel_y = [], [], [], []
    rng = random.Random(6)
    lines = [(0, 0, 255, 191), (255, 0, 0, 191), (0, 191, 255, 0), (5, 9, 5, 9), (0, 100, 255, 100),
             (255, 50, 0, 50), (17, 0, 17, 191), (200, 191, 200, 0), (0, 0, 191, 191), (255, 0, 64, 191)]
    for _ in range(3000):
        x0, x1 = rng.randrange(256), rng.randrange(256)
        y0, y1 = rng.randrange(192), rng.randrange(192)
        if rng.randrange(4) == 0:   # short ones, every way
            x1 = max(0, min(255, x0 + rng.randrange(-9, 10)))
            y1 = max(0, min(191, y0 + rng.randrange(-9, 10)))
        lines.append((x0, y0, x1, y1))
    for i, (base, high) in enumerate(((0x4000, 0x00), (0xC000, 0x80))):
        m.poke(m.label("screen_high"), bytes([high]))
        for start in range(0, len(lines), 8 if i == 0 else 500):
            batch = lines[start:start + 8] if i == 0 else lines[start:start + 3]
            m.poke(base, bytes(6144))
            for line in batch:
                x0, y0, x1, y1 = line
                t = m.call("draw_line", B=x0, C=y0, D=x1, E=y1)
                times.append(t)
                pixels = len(model.line(*line))
                if pixels > 40:
                    (per_pixel_x if abs(x1 - x0) >= abs(y1 - y0) else per_pixel_y).append(t / pixels)
            got = bytes(m.memory[base:base + 6144])
            if got != render(batch, base):
                failures.append(f"draw_line at ${base:04X}: {batch} differ from the model")
                if len(failures) > 5:
                    return failures
    report("draw_line", times)
    print(f"  {'':14} {sum(per_pixel_x) / len(per_pixel_x):.0f} T-states a pixel along x, "
          f"{sum(per_pixel_y) / len(per_pixel_y):.0f} along y (lines over 40 pixels)")

    # clear_box: a full screen, blank a box, the rest untouched
    clear_times = []
    for _ in range(200):
        rows, top = rng.randrange(1, 193), 0
        top = rng.randrange(0, 193 - rows)
        width = rng.randrange(1, 33)
        left = rng.randrange(0, 33 - width)
        m.poke(0x4000, bytes([0xFF]) * 6144)
        m.poke(m.label("screen_high"), bytes([0]))
        clear_times.append(m.call("clear_box", B=rows, C=top, D=left, E=width))
        want = bytearray([0xFF]) * 6144
        for y in range(top, top + rows):
            for col in range(left, left + width):
                want[model.screen_address(col * 8, y) - 0x4000] = 0
        if bytes(m.memory[0x4000:0x5800]) != bytes(want):
            failures.append(f"clear_box rows {top}+{rows} columns {left}+{width}")
    report("clear_box", clear_times)
    return failures


def window_lines(rng: random.Random, count: int) -> list:
    """(window, line) pairs: random windows, and lines from inside them to far
    out, half of them aimed through the window so that most need clipping."""
    cases = []
    for _ in range(count):
        w = sorted(rng.sample(range(256), 2))
        h = sorted(rng.sample(range(192), 2))
        window = (w[0], h[0], w[1], h[1])
        far = rng.choice((40, 300, 2000, 16000))
        line = [rng.randint(-far, far + 255), rng.randint(-far, far + 191),
                rng.randint(-far, far + 255), rng.randint(-far, far + 191)]
        if rng.random() < 0.5:
            line[2] = 2 * rng.randint(window[0], window[2]) - line[0]
            line[3] = 2 * rng.randint(window[1], window[3]) - line[1]
        cases.append((window, tuple(line)))
    return cases


def check_clipping(m: Machine) -> list[str]:
    failures = []
    rng = random.Random(8)

    times = []
    for _ in range(20000):
        n, c = rng.randrange(-32768, 32768), rng.randrange(1, 256)
        if rng.random() < 0.3:
            c = rng.randrange(1, 8)
        times.append(m.call("divide_wide", H=(n >> 8) & 0xFF, L=n & 0xFF, C=c))
        got, want = model.to_signed16(m.pair("H", "L")), model.divide_wide(n, c)
        if got != want and len(failures) < 10:
            failures.append(f"divide_wide {n} / {c}: {got}, not {want}")
    report("divide_wide", times)

    times = []
    for _ in range(20000):
        rotated = tuple(rng.randrange(-28672, 28673) for _ in range(3))
        zoff = rng.randrange(0, 65536)
        if not 0 <= rotated[2] + zoff < 65536:
            continue    # outside what project_wide is for
        for name, value in zip(("rot_x", "rot_y", "rot_z"), rotated):
            m.poke_word(name, value)
        m.poke_word("zoff", zoff)
        times.append(m.call("project_wide"))
        carry = m.sim.registers[1] & 1
        got = None if carry else (model.to_signed16(m.pair("H", "L")), model.to_signed16(m.pair("D", "E")))
        want = model.project_wide(rotated, zoff)
        if got != want and len(failures) < 10:
            failures.append(f"project_wide {rotated} zoff {zoff}: {got}, not {want}")
    report("project_wide", times)

    # transform_wide, close enough that points land far off the screen
    vertex_at, point_at = m.label("checks_vertex"), m.label("checks_points")
    for _ in range(200):
        x, y, z = (rng.randrange(256) for _ in range(3))
        set_angles(m, x, y, z)
        m.call("make_matrix")
        matrix = model.make_matrix(x, y, z)
        zoff = rng.randrange(28800, 36000)
        m.poke_word("zoff", zoff)
        vertices = [tuple(rng.randrange(-128, 128) for _ in range(3)) for _ in range(8)]
        m.poke(vertex_at, bytes(c & 0xFF for v in vertices for c in v))
        m.call("transform_wide", H=vertex_at >> 8, L=vertex_at, D=point_at >> 8, E=point_at, B=8)
        for i, vertex in enumerate(vertices):
            want = model.project_wide(model.rotate(matrix, vertex), zoff)
            words = [model.to_signed16(m.memory[point_at + 4 * i + k] | m.memory[point_at + 4 * i + k + 1] << 8)
                     for k in (0, 2)]
            got = None if words[0] == -32768 else tuple(words)
            if got != want and len(failures) < 10:
                failures.append(f"transform_wide {vertex} at {x},{y},{z}: {got}, not {want}")

    kinds = {"inside": [], "outside": [], "clipped once": [], "clipped twice or more": []}
    for window, line in window_lines(rng, 60000):
        m.call("set_window", B=window[0], C=window[1], D=window[2], E=window[3])
        for name, value in zip(("clip_x0", "clip_y0", "clip_x1", "clip_y1"), line):
            m.poke_word(name, value)
        t = m.call("clip_line")
        carry = m.sim.registers[1] & 1
        got = None if carry else (m.reg("B"), m.reg("C"), m.reg("D"), m.reg("E"))
        want = model.clip_line(*line, window)
        if got != want and len(failures) < 10:
            failures.append(f"clip_line {line} to {window}: {got}, not {want}")
        if want is None:
            kinds["outside"].append(t)
        else:
            moved = sum(a != b for a, b in zip(want, line))
            kinds["inside" if moved == 0 else "clipped once" if moved <= 2 and (want[:2] == line[:2] or want[2:] == line[2:]) else "clipped twice or more"].append(t)
    for kind, times in kinds.items():
        report(f"clip_line, {kind}", times)

    # draw_line_clipped: the pixels
    m.poke(m.label("screen_high"), bytes([0]))
    for window, line in window_lines(rng, 2000):
        m.poke(0x4000, bytes(6144))
        m.call("set_window", B=window[0], C=window[1], D=window[2], E=window[3])
        for name, value in zip(("clip_x0", "clip_y0", "clip_x1", "clip_y1"), line):
            m.poke_word(name, value)
        m.call("draw_line_clipped")
        clipped = model.clip_line(*line, window)
        if bytes(m.memory[0x4000:0x5800]) != render([clipped] if clipped else [], 0x4000):
            failures.append(f"draw_line_clipped {line} to {window} differs from the model")
            break
    m.call("set_window", B=0, C=0, D=255, E=191)
    return failures


def rough_out(t: tuple, r: int) -> bool:
    """Whether cull_object's rough step settles it: the exact T less the low
    bytes' rotation, tested with the radii a margin bigger. (Only for the
    report: whatever the step, the answer is model.culled's.)"""
    return rough_culled(t, r)


ROUGH = 28380                                                   # objects.s


def rough_t(position, camera_position, camera) -> tuple:
    d = [p - c for p, c in zip(position, camera_position)]
    seen = model.transpose(camera)
    return tuple(256 * a + k for a, k in zip(model.rotate(seen, tuple(v >> 8 for v in d)),
                                             model.camera_constant(camera)))


def rough_culled(t, r: int) -> bool:
    tx, ty, tz = t
    r_view, r5 = model.cull_radii(r)
    r_view, r5 = r_view + ROUGH, r5 + 3 * ROUGH
    if tz + r_view < model.NEAR * 127 or tz - r_view > model.FAR * 128:
        return True
    return any(2 * s * v - tz > r5 for v in (tx, ty) for s in (1, -1))


def check_objects(m: Machine, wrap: bool = False) -> list[str]:
    """With wrap, on the WORLD_WRAP build: cameras by the world's edges and
    corners, objects across them, and the model's answers those for the
    same scene moved from the edges -- the camera at the origin, the object
    where it is from the camera -- with no wrapping."""
    from build import models
    failures = []
    rng = random.Random(9)
    objects, across, corner = 0, 0, 0                 # (with wrap)
    if wrap:
        print("  with WORLD_WRAP, cameras and objects by the world's edges:")
    shapes = [(m.label(f"{name}_model"), vertices) for name, (vertices, faces) in models().items()]
    signed24 = lambda b: (b[0] | b[1] << 8 | b[2] << 16) - ((1 << 24) if b[2] & 0x80 else 0)
    times = {"set_camera": [], "cull_object, out of the box": [], "cull_object, out roughly": [], "cull_object, culled": [],
             "cull_object, in view": [], "object_matrix": [], "transform_object": []}
    obj_at = m.label("checks_object")
    point_at = m.label("checks_points_far")     # four tables of 64: x low, x high, y low, y high
    for _ in range(400):
        cam_a = [rng.randrange(256) for _ in range(3)]
        camera = model.make_matrix(*cam_a)
        cam_p = [rng.randrange(-30000, 30000) for _ in range(3)]
        if wrap:                                # most axes within 3,000 of an edge
            cam_p = [model.to_signed16(rng.choice((-32768, 32767)) + rng.randint(-3000, 3000))
                     if rng.random() < 0.7 else c for c in cam_p]
        for name, value in zip(("camera_x", "camera_y", "camera_z"), cam_p):
            m.poke_word(name, value)
        m.poke(m.label("camera_angles"), bytes(cam_a))
        times["set_camera"].append(m.call("set_camera"))
        seen = [signed8(v) for v in m.memory[m.label("camera_seen"):m.label("camera_seen") + 9]]
        k = [signed24(m.memory[m.label("camera_k") + 3 * i:m.label("camera_k") + 3 * i + 3]) for i in range(3)]
        if seen != model.transpose(camera) or tuple(k) != model.camera_constant(camera):
            failures.append(f"set_camera {cam_a}: {seen} {k}")
            return failures
        for _ in range(20):
            reach = rng.choice((150, 600, 3000, 10000, 20000))
            pos = [max(-32768, min(32767, c + rng.randint(-reach, reach))) for c in cam_p]
            seen_p, seen_c = pos, cam_p         # what the model is given
            if wrap:
                pos = [model.to_signed16(c + rng.randint(-reach, reach)) for c in cam_p]
                seen_p, seen_c = [model.to_signed16(p - c) for p, c in zip(pos, cam_p)], [0, 0, 0]
                crossed = sum(abs(p - c) > 32767 for p, c in zip(pos, cam_p))
                objects, across, corner = objects + 1, across + (crossed > 0), corner + (crossed > 1)
            obj_a = [rng.randrange(256) for _ in range(3)]
            model_at, vertices = shapes[rng.randrange(len(shapes))]
            record = (b"".join((v & 0xFFFF).to_bytes(2, "little") for v in pos) + bytes(obj_a)
                      + model_at.to_bytes(2, "little") + bytes(8))           # (no spin; room to skip)
            m.poke(obj_at, record)
            m.sim.registers[8], m.sim.registers[9] = obj_at >> 8, obj_at & 0xFF      # IX
            t = m.call("cull_object")
            got = bool(m.sim.registers[1] & 1)
            want_t = model.view_centre(seen_p, seen_c, camera)
            r = model.bounding_radius(vertices)
            want = want_t is None or model.culled(want_t, r)
            if got != want:
                failures.append(f"cull_object {pos} {obj_a} from {cam_p} {cam_a}: {'culled' if got else 'kept'}")
            if not want:
                got_t = tuple(signed24(m.memory[m.label("view_t") + 3 * i:m.label("view_t") + 3 * i + 3]) for i in range(3))
                if got_t != want_t:
                    failures.append(f"cull_object T {got_t}, not {want_t}")
            elif got:
                # CULL_SKIP: the margin it leaves must be one some culling test allows,
                # and the size and limit what the model makes of P - C
                skip, dist, limit = m.word("cull_skip"), m.memory[m.label("cull_dist")], m.word("cull_limit")
                if want_t is None:
                    if skip:
                        failures.append(f"cull_object {pos} from {cam_p}: out of the box, but a margin of {skip}")
                else:
                    k, q, room = model.skip_size([p - c for p, c in zip(seen_p, seen_c)])
                    want_dist = (m.label("skip_bounds") + 2 * model.skip_index(k, q)) & 0xFF
                    want_limit = (m.word("skip_odometer") + room) & 0xFFFF
                    if skip > model.skip_margin(want_t, r) or dist != want_dist or limit != want_limit:
                        failures.append(f"cull_object {pos} {obj_a} from {cam_p} {cam_a}: margin {skip} (at most "
                                        f"{model.skip_margin(want_t, r)}), size at {dist} ({want_dist}), limit {limit} ({want_limit})")
            rough = want_t is not None and rough_out(rough_t(seen_p, seen_c, camera), r)
            if rough and not want:
                failures.append(f"the rough step would cull {pos} from {cam_p}, which is in view")
            times["cull_object, out of the box" if want_t is None else "cull_object, out roughly" if rough
                  else "cull_object, culled" if want else "cull_object, in view"].append(t)
            if want:
                continue
            m.sim.registers[8], m.sim.registers[9] = obj_at >> 8, obj_at & 0xFF
            times["object_matrix"].append(m.call("object_matrix"))
            want_m = model.view_matrix(camera, model.make_matrix(*obj_a))
            got_m = [signed8(v) for v in m.memory[m.label("view_m"):m.label("view_m") + 9]]
            if got_m != want_m:
                failures.append(f"object_matrix {obj_a} from {cam_a}: {got_m}, not {want_m}")
                continue
            m.sim.registers[8], m.sim.registers[9] = obj_at >> 8, obj_at & 0xFF
            times["transform_object"].append(m.call("transform_object", D=point_at >> 8, E=0) / len(vertices))
            for i, v in enumerate(vertices):
                want_p = model.project_far(model.rotate(want_m, v), want_t)
                words = [model.to_signed16(m.memory[point_at + k + i] | m.memory[point_at + k + 64 + i] << 8) for k in (0, 128)]
                got_p = None if words[0] == -32768 else tuple(words)
                if got_p != want_p:
                    failures.append(f"transform_object {v} of {pos} {obj_a} from {cam_p} {cam_a}: {got_p}, not {want_p}")
        if len(failures) > 10:
            return failures
    for name, ts in times.items():
        report(name, [round(x) for x in ts])
    print(f"  {'':14} (transform_object: per vertex)")
    if wrap:
        print(f"  {'':14} {across:,} of {objects:,} objects across an edge from the camera, {corner:,} across "
              f"a corner, all as the same scene away from the edges")
    return failures


def check_near_cut(m: Machine) -> list[str]:
    """cut_edges on objects straddling the near plane, seen from cameras all
    round: set_camera, cull_object, object_matrix and transform_object as
    the demo calls them, then cut_edges, against model.object_lines -- every
    point, and every cut line's ends, how many and where they end."""
    from build import check_models, models
    failures = []
    rng = random.Random(13)
    shapes = ([(m.label(f"{name}_model"), vertices, model.faces_to_edges(faces))
               for name, (vertices, faces) in models().items()] +
              [(m.label(f"{name}_model"), vertices, model.part_edges(faces, parts)[0])
               for name, (vertices, faces, parts) in check_models().items()])
    obj_at = m.label("checks_object")
    point_at = m.label("checks_points_far")
    cuts_at = m.label("checks_cuts")
    times = {"cut_edges, nothing behind": [], "cut_edges, a line": []}
    counts, objects = 0, 0
    for _ in range(300):
        cam_a = [rng.randrange(256) for _ in range(3)]
        camera = model.make_matrix(*cam_a)
        ideal = model.ideal_matrix(*cam_a)
        cam_p = [rng.randrange(-30000, 30000) for _ in range(3)]
        for name, value in zip(("camera_x", "camera_y", "camera_z"), cam_p):
            m.poke_word(name, value)
        m.poke(m.label("camera_angles"), bytes(cam_a))
        m.call("set_camera")
        for _ in range(20):
            model_at, vertices, edges = shapes[rng.randrange(len(shapes))]
            r = model.bounding_radius(vertices)
            # where it is to be seen: its centre within r of the near plane
            want = [rng.uniform(-r, r), rng.uniform(-r, r), model.NEAR_PLANE / 127 + rng.uniform(-r, r)]
            pos = [c + round(sum(ideal[3 * i + j] * want[j] for j in range(3))) for i, c in enumerate(cam_p)]
            obj_a = [rng.randrange(256) for _ in range(3)]
            t = model.view_centre(pos, cam_p, camera)
            if t is None or model.culled(t, r):
                continue
            objects += 1
            record = (b"".join((v & 0xFFFF).to_bytes(2, "little") for v in pos) + bytes(obj_a)
                      + model_at.to_bytes(2, "little") + bytes(8))
            m.poke(obj_at, record)
            for routine in ("cull_object", "object_matrix"):
                m.sim.registers[8], m.sim.registers[9] = obj_at >> 8, obj_at & 0xFF      # IX
                m.call(routine)
            first = rng.randrange(65 - len(vertices))
            m.sim.registers[8], m.sim.registers[9] = obj_at >> 8, obj_at & 0xFF
            m.call("transform_object", D=point_at >> 8, E=first)
            mat = model.view_matrix(camera, model.make_matrix(*obj_a))
            want_points, want_cuts = model.object_lines(vertices, edges, mat, t)
            for i, want_p in enumerate(want_points):
                words = [model.to_signed16(m.memory[point_at + k + first + i] | m.memory[point_at + k + 64 + first + i] << 8)
                         for k in (0, 128)]
                got_p = None if words[0] == -32768 else tuple(words)
                if got_p != want_p:
                    failures.append(f"transform_object {vertices[i]} of {pos} {obj_a} from {cam_p} {cam_a}: {got_p}, not {want_p}")
            m.sim.registers[8], m.sim.registers[9] = obj_at >> 8, obj_at & 0xFF
            took = m.call("cut_edges", H=point_at >> 8, L=first, D=cuts_at >> 8, E=cuts_at & 0xFF)
            count, end = m.reg("A"), m.pair("D", "E")
            got_cuts = [tuple(model.to_signed16(m.memory[cuts_at + 8 * n + 2 * k] | m.memory[cuts_at + 8 * n + 2 * k + 1] << 8)
                              for k in range(4)) for n in range(count)]
            if count != len(want_cuts) or end != cuts_at + 8 * count or got_cuts != want_cuts:
                failures.append(f"cut_edges of {pos} {obj_a} from {cam_p} {cam_a}: {count} lines to {end:04X}, "
                                f"{got_cuts}, not {want_cuts}")
            if count:
                times["cut_edges, a line"].append(took / count)
            elif None not in want_points:
                times["cut_edges, nothing behind"].append(took)
            counts += count
        if len(failures) > 10:
            return failures
    for name, ts in times.items():
        report(name, [round(x) for x in ts])
    print(f"  {'':14} {objects:,} objects straddling the near plane, {counts:,} edges cut, every point as the model")
    return failures


def check_faces(m: Machine) -> list[str]:
    """facing_edges on objects of one part (a box, a strip), of three (an
    aeroplane) and of none (a frame), from cameras all round, near --
    straddling the near plane too -- and far, against model.facing_edges:
    the edges kept, in order, how many and where they end; then cut_edges
    on just those, against model.object_lines."""
    from build import check_models
    failures = []
    rng = random.Random(17)
    shapes = [(name, m.label(f"{name}_model"), vertices, faces, parts, *model.part_edges(faces, parts))
              for name, (vertices, faces, parts) in check_models().items()]
    obj_at = m.label("checks_object")
    point_at = m.label("checks_points_far")
    edges_at = m.label("checks_edges")
    cuts_at = m.label("checks_cuts")
    per_face, per_edge, faceless, kept, hidden = [], [], [], 0, 0
    objects = {name: 0 for name, *_ in shapes}
    for _ in range(300):
        cam_a = [rng.randrange(256) for _ in range(3)]
        camera = model.make_matrix(*cam_a)
        ideal = model.ideal_matrix(*cam_a)
        cam_p = [rng.randrange(-30000, 30000) for _ in range(3)]
        for name, value in zip(("camera_x", "camera_y", "camera_z"), cam_p):
            m.poke_word(name, value)
        m.poke(m.label("camera_angles"), bytes(cam_a))
        m.call("set_camera")
        for _ in range(20):
            name, model_at, vertices, faces, parts, edges, edge_faces = shapes[rng.randrange(len(shapes))]
            r = model.bounding_radius(vertices)
            depth = rng.choice((model.NEAR_PLANE / 127 + rng.uniform(-r, r), rng.uniform(r, 12 * r),
                                rng.uniform(12 * r, 3000)))
            want = [rng.uniform(-depth / 2, depth / 2), rng.uniform(-depth / 2, depth / 2), depth]
            pos = [c + round(sum(ideal[3 * i + j] * want[j] for j in range(3))) for i, c in enumerate(cam_p)]
            obj_a = [rng.randrange(256) for _ in range(3)]
            t = model.view_centre(pos, cam_p, camera)
            if t is None or model.culled(t, r) or any(abs(p) > 32767 for p in pos):
                continue
            objects[name] += 1
            m.poke(obj_at, b"".join((v & 0xFFFF).to_bytes(2, "little") for v in pos) + bytes(obj_a)
                   + model_at.to_bytes(2, "little") + bytes(8))
            for routine in ("cull_object", "object_matrix"):
                m.sim.registers[8], m.sim.registers[9] = obj_at >> 8, obj_at & 0xFF      # IX
                m.call(routine)
            first = rng.randrange(65 - len(vertices))
            m.sim.registers[8], m.sim.registers[9] = obj_at >> 8, obj_at & 0xFF
            m.call("transform_object", D=point_at >> 8, E=first)
            mat = model.view_matrix(camera, model.make_matrix(*obj_a))
            points = [model.project_far(model.rotate(mat, v), t) for v in vertices]
            want_edges = model.facing_edges(points, faces if parts else [], edges, edge_faces)
            m.sim.registers[8], m.sim.registers[9] = obj_at >> 8, obj_at & 0xFF
            if parts:
                took_faces, took_edges = m.call_until("facing_edges", "keep_facing_edges", H=point_at >> 8,
                                                      L=first, D=edges_at >> 8, E=edges_at & 0xFF)
            else:
                took = m.call("facing_edges", H=point_at >> 8, L=first, D=edges_at >> 8, E=edges_at & 0xFF)
            count, end = m.reg("A"), m.pair("D", "E")
            at, n = m.word("view_edges"), m.memory[m.label("view_edge_count")]
            got_edges = [(m.memory[at + 2 * i], m.memory[at + 2 * i + 1]) for i in range(n)]
            want_end = edges_at + 2 * len(want_edges) if parts else edges_at
            if got_edges != want_edges or count != len(want_edges) or end != want_end:
                failures.append(f"facing_edges, {name} at {pos} {obj_a} from {cam_p} {cam_a}: {count} edges "
                                f"to {end:04X}, {got_edges}, not {want_edges}")
                continue
            if parts:
                per_face.append(took_faces / len(faces))
                per_edge.append(took_edges / len(edges))
            else:
                faceless.append(took)
            kept, hidden = kept + len(want_edges), hidden + len(edges) - len(want_edges)
            m.sim.registers[8], m.sim.registers[9] = obj_at >> 8, obj_at & 0xFF
            m.call("cut_edges", H=point_at >> 8, L=first, D=cuts_at >> 8, E=cuts_at & 0xFF)
            count = m.reg("A")
            got_cuts = [tuple(model.to_signed16(m.memory[cuts_at + 8 * k + 2 * j] | m.memory[cuts_at + 8 * k + 2 * j + 1] << 8)
                              for j in range(4)) for k in range(count)]
            want_cuts = model.object_lines(vertices, want_edges, mat, t)[1]
            if got_cuts != want_cuts:
                failures.append(f"cut_edges after facing_edges, {name} at {pos} {obj_a} from {cam_p} {cam_a}: "
                                f"{got_cuts}, not {want_cuts}")
        if len(failures) > 10:
            return failures
    report("facing_edges, a face", [round(x) for x in per_face])
    report("  then an edge", [round(x) for x in per_edge])
    report("facing_edges, no faces", faceless)
    print(f"  {'':14} {', '.join(f'{n} {k:,}' for n, k in objects.items())} objects: {kept:,} edges "
          f"kept, {hidden:,} hidden, every one as the model, and cut at the near plane after")
    return failures


def object_picture(vertices, edges, mat, t, window, room: int) -> tuple[list, list, list]:
    """An object's lines in the demo, clipped to the window: each edge with
    both ends in front of the near plane, and each one cut at it -- unless,
    as compute_frame has it, there is room for fewer cut lines than the
    object has edges, when they are left out. And its points and its cuts."""
    points, cuts = model.object_lines(vertices, edges, mat, t)
    if len(edges) > room:
        cuts = []
    lines = [model.clip_line(*points[i], *points[j], window) for i, j in edges if points[i] and points[j]]
    lines += [model.clip_line(*cut, window) for cut in cuts]
    return [line for line in lines if line], points, cuts


def check_demo(m: Machine) -> list[str]:
    from PIL import Image
    from build import models, world
    failures = []
    memory = bytearray(65536)
    memory[0x4000:0xC000] = (OUT / "demo.bin").read_bytes()
    sim = (CSimulator or Simulator)(memory, state={"iff": 0, "im": 1, "tstates": 0})
    sld = OUT / "demo.sld"
    label = {name: find_label(sld, name) for name in
             ("draw_frame", "demo_setup", "drawn", "camera_x", "camera_angles",
              "CUT_LINES", "VIEW_LEFT", "VIEW_TOP", "VIEW_RIGHT", "VIEW_BOTTOM")}
    window = tuple(label[f"VIEW_{edge}"] for edge in ("LEFT", "TOP", "RIGHT", "BOTTOM"))
    left, top, right, bottom = window
    frame = [(left - 1, top - 1, right + 1, top - 1), (right + 1, top - 1, right + 1, bottom + 1),
             (right + 1, bottom + 1, left - 1, bottom + 1), (left - 1, bottom + 1, left - 1, top - 1)]

    def call(name: str) -> int:
        sim.registers[SP] = STACK
        sim.memory[STACK:STACK + 2] = RETURN.to_bytes(2, "little")
        start = sim.registers[T]
        sim.run(label[name], RETURN)
        return sim.registers[T] - start

    for address in range(0x4000, 0x5800):
        sim.memory[address] = 0
    call("demo_setup")                         # as start does: window and frame, $4000 to draw on

    shapes = {name: (vertices, model.faces_to_edges(faces), model.bounding_radius(vertices))
              for name, (vertices, faces) in models().items()}
    things = [[list(pos), list(angles), spin, name] for pos, angles, spin, name in world()]
    cam_p, cam_a = [0, 0, 0], [0, 0, 0]
    frames, times, counts = [], [], []
    behind = 0                                  # vertices behind the near plane
    for _ in range(256):
        times.append(call("draw_frame"))
        cam_p, cam_a, rc = model.fly(cam_p, cam_a)
        lines, drawn, cuts_now = list(frame), 0, 0
        for thing in things:
            pos, angles, spin, name = thing
            thing[1] = angles = [(a + s) & 255 for a, s in zip(angles, spin)]
            vertices, edges, r = shapes[name]
            t = model.view_centre(pos, cam_p, rc)
            if t is None or model.culled(t, r):
                continue
            drawn += 1
            mat = model.view_matrix(rc, model.make_matrix(*angles))
            picture, points, cuts = object_picture(vertices, edges, mat, t, window, label["CUT_LINES"] - cuts_now)
            lines, cuts_now, behind = lines + picture, cuts_now + len(cuts), behind + points.count(None)
        counts.append(drawn)
        got_drawn = sim.memory[label["drawn"]]
        got = bytes(sim.memory[0x4000:0x5800])
        if got_drawn != drawn or got != render(lines, 0x4000):
            failures.append(f"demo: frame {len(frames)}, camera at {cam_p} {cam_a}: "
                            f"{got_drawn} objects drawn ({drawn} in the model), the screen "
                            f"{'the same' if got == render(lines, 0x4000) else 'different'}")
            break
        frames.append(got)
    report("demo: a frame", times)
    print(f"  {'':14} {min(counts)}..{max(counts)} objects drawn a frame, of {len(things)}, "
          f"{sum(counts) / len(counts):.1f} on average, over a circle of the flight, "
          f"{behind} vertices behind the near plane")
    if behind:                                  # the world keeps clear of the flight
        failures.append(f"demo: {behind} vertices behind the near plane, so its pictures have changed")
    if not frames:
        return failures
    # the frames, as the Spectrum shows them: bright white on black, twice the size
    images = []
    for screen in frames:
        image = Image.new("1", (256, 192))
        image.putdata([1 if screen[model.screen_address(x, y) - 0x4000] & (0x80 >> (x & 7)) else 0
                       for y in range(192) for x in range(256)])
        images.append(image.convert("L").resize((512, 384), Image.NEAREST))
    images = images[::2]
    images[0].save(OUT / "demo.gif", save_all=True, append_images=images[1:], duration=80, loop=0)
    images[min(100, len(images) - 1)].save(OUT / "demo.png")
    print(f"  {len(frames)} frames to {OUT / 'demo.gif'}")
    return failures


def check_demo_jumps(m: Machine, wrap: bool = False) -> list[str]:
    """CULL_SKIP under a camera that jumps and swings: draw_frame frame after
    frame with the camera moved between them at random -- small steps mostly,
    now and then a leap or a half turn -- against the model's picture from
    the camera as it then stood; and skip_bounds against model.skip_bounds,
    or, for a jump, every object's margin cleared.

    With wrap, the same on the WORLD_WRAP build with the whole world -- every
    object, and the camera -- moved by 32,768 on each axis, so that the
    flight straddles every edge of the world and its corner, against the
    model's picture of the world where it was."""
    from build import models, world
    failures = []
    rng = random.Random(11)
    build = "demo_wrap" if wrap else "demo"
    shift = 32768 if wrap else 0
    memory = bytearray(65536)
    memory[0x4000:0xC000] = (OUT / f"{build}.bin").read_bytes()
    sim = (CSimulator or Simulator)(memory, state={"iff": 0, "im": 1, "tstates": 0})
    sld = OUT / f"{build}.sld"
    label = {name: find_label(sld, name) for name in
             ("draw_frame", "demo_setup", "drawn", "camera_x", "camera_angles", "camera_last", "skip_bounds", "world",
              "OBJECT_SIZE", "OBJECT_SKIP", "WORLD_OBJECTS", "CUT_LINES", "VIEW_LEFT", "VIEW_TOP", "VIEW_RIGHT", "VIEW_BOTTOM")}
    window = tuple(label[f"VIEW_{edge}"] for edge in ("LEFT", "TOP", "RIGHT", "BOTTOM"))
    left, top, right, bottom = window
    frame = [(left - 1, top - 1, right + 1, top - 1), (right + 1, top - 1, right + 1, bottom + 1),
             (right + 1, bottom + 1, left - 1, bottom + 1), (left - 1, bottom + 1, left - 1, top - 1)]

    def call(name: str) -> None:
        sim.registers[SP] = STACK
        sim.memory[STACK:STACK + 2] = RETURN.to_bytes(2, "little")
        sim.run(label[name], RETURN)

    def camera():                                # (where the model has it)
        at = label["camera_x"]
        pos = [model.to_signed16((sim.memory[at + 2 * i] | sim.memory[at + 2 * i + 1] << 8) - shift)
               for i in range(3)]
        return pos, list(sim.memory[label["camera_angles"]:label["camera_angles"] + 3])

    def set_camera(pos, angles) -> None:
        at = label["camera_x"]
        for i, v in enumerate(pos):
            sim.memory[at + 2 * i:at + 2 * i + 2] = ((v + shift) & 0xFFFF).to_bytes(2, "little")
        sim.memory[label["camera_angles"]:label["camera_angles"] + 3] = bytes(a & 255 for a in angles)

    for address in range(0x4000, 0x5800):
        sim.memory[address] = 0
    call("demo_setup")
    if shift:                                       # the world moved, and the camera
        for i in range(label["WORLD_OBJECTS"]):     # last seen where it now starts
            at = label["world"] + i * label["OBJECT_SIZE"]
            for axis in range(3):
                v = (sim.memory[at + 2 * axis] | sim.memory[at + 2 * axis + 1] << 8) + shift
                sim.memory[at + 2 * axis:at + 2 * axis + 2] = (v & 0xFFFF).to_bytes(2, "little")
        sim.memory[label["camera_last"]:label["camera_last"] + 6] = (shift & 0xFFFF).to_bytes(2, "little") * 3
        set_camera([0, 0, 0], [0, 0, 0])
    shapes = {name: (vertices, model.faces_to_edges(faces), model.bounding_radius(vertices))
              for name, (vertices, faces) in models().items()}
    things = [[list(pos), list(angles), spin, name] for pos, angles, spin, name in world()]
    last = ([0, 0, 0], [0] * 9)                        # as camera_last starts
    stale = None                                       # skip_bounds as last left
    kinds = {"step": 0, "swing": 0, "jump": 0, "leap": 0, "close": 0, "void": 0}
    cut, cuts_seen = 0, 0                              # edges cut, frames with any
    for i in range(240):
        pos, angles = camera()
        roll = rng.random()
        if roll < 0.03:
            kind = "leap"                               # far enough to void every margin
            pos = [rng.choice((-1, 1)) * rng.randint(12000, 30000) for _ in range(3)]
            angles = [rng.randrange(256) for _ in range(3)]
        elif roll < 0.1:
            kind = "jump"
            pos = [rng.randint(-3000, 3000), rng.randint(-600, 600), rng.randint(-3000, 3000)]
            angles = [rng.randrange(256) for _ in range(3)]
        elif roll < 0.25:
            kind = "close"                              # an object straddling the near
            angles = [rng.randrange(256) for _ in range(3)]     # plane, once the frame
            ahead = model.make_matrix(*angles)[2::3]            # has moved the camera on
            target = things[rng.randrange(len(things))][0]
            back = rng.uniform(-60, 140)
            pos = [round(p - back * f / 127) for p, f in zip(target, ahead)]
        elif roll < 0.4:
            kind = "swing"
            pos = [max(-32000, min(32000, p + rng.randint(-250, 250))) for p in pos]
            angles = [a + rng.randint(-24, 24) for a in angles]
        else:
            kind = "step"
            pos = [max(-32000, min(32000, p + rng.randint(-40, 40))) for p in pos]
            angles = [a + rng.randint(-3, 3) for a in angles]
        kinds[kind] += 1
        set_camera(pos, angles)
        call("draw_frame")                          # (which moves the camera on itself)
        cam_p, cam_a = camera()
        rc = model.make_matrix(*cam_a)
        lines, drawn, cut_before = list(frame), 0, cut
        for thing in things:
            tpos, tangles, spin, name = thing
            thing[1] = tangles = [(a + s) & 255 for a, s in zip(tangles, spin)]
            vertices, edges, r = shapes[name]
            t = model.view_centre(tpos, cam_p, rc, wrap=wrap)
            if t is None or model.culled(t, r):
                continue
            drawn += 1
            mat = model.view_matrix(rc, model.make_matrix(*tangles))
            picture, _, cuts = object_picture(vertices, edges, mat, t, window, label["CUT_LINES"] - (cut - cut_before))
            lines, cut = lines + picture, cut + len(cuts)
        cuts_seen += cut > cut_before
        got_drawn = sim.memory[label["drawn"]]
        if got_drawn != drawn or bytes(sim.memory[0x4000:0x5800]) != render(lines, 0x4000):
            failures.append(f"demo with jumps: frame {i} ({kind}), camera at {cam_p} {cam_a}: "
                            f"{got_drawn} objects drawn ({drawn} in the model), the screen "
                            f"{'the same' if bytes(sim.memory[0x4000:0x5800]) == render(lines, 0x4000) else 'different'}")
            break
        seen = model.transpose(rc)
        want = model.skip_bounds(last[1], seen, last[0], cam_p, wrap=wrap)
        at = label["skip_bounds"]
        got = {(k, q): sim.memory[at + 2 * model.skip_index(k, q)] | sim.memory[at + 2 * model.skip_index(k, q) + 1] << 8
               for k in range(model.SKIP_K_LEAST, model.SKIP_K_LEAST + model.SKIP_K_COUNT) for q in range(4, 8)}
        if want is None:
            kinds["void"] += 1                         # (every margin cleared, then every
            if got != stale:                           # object tested afresh: the picture
                failures.append(f"demo with jumps: frame {i}: a jump, but skip_bounds remade")
                break                                  # says so; the table is left alone)
        elif got != want:
            failures.append(f"demo with jumps: frame {i}: skip_bounds {got}, not {want}")
            break
        last, stale = (cam_p, seen), got
    print(f"  demo with jumps{', the world moved across its edges (WORLD_WRAP)' if wrap else ''}: {kinds['step']} steps, {kinds['swing']} swings, {kinds['jump']} jumps, "
          f"{kinds['leap']} leaps ({kinds['void']} frames voiding every margin), {kinds['close']} "
          f"close to an object ({cuts_seen} frames with edges cut at the near plane, {cut} edges), "
          f"all as the model")
    return failures


def main() -> None:
    m = Machine()
    failures = []
    for check in (check_mul8s, check_matrix_and_rotate, check_divide, check_transform, check_lines, check_clipping, check_objects, check_near_cut, check_faces, check_demo, check_demo_jumps):
        failures += check(m)
    failures += check_objects(Machine("checks_wrap"), wrap=True)
    failures += check_demo_jumps(m, wrap=True)
    if failures:
        print("\n".join(failures[:20]))
        sys.exit(f"{len(failures)} failures")
    print("All match the model.")


if __name__ == "__main__":
    main()
