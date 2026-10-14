"""The arithmetic of fast3d, exactly as the Z80 does it: the checks compare
every result the assembled routines leave with what these functions say.

Numbers
-------
- An angle is a byte: 256 to the turn.
- A vertex is three signed bytes, -128..127.
- A matrix entry is a signed byte, -127..127, with 127 standing for 1.0.
- A rotated coordinate is the exact 16-bit sum of three products,
  S = m0*x + m1*y + m2*z: 128 times the vertex's coordinate (times 127/128).
- A projected coordinate is S / Z, where Z = (Sz + zoff) >> 8: with zoff =
  128 * distance, that is 256 * x / (z + distance), a 256-unit focal length.
"""
from __future__ import annotations

import math

# The quarter-square tables: a*b = f(a+b) - f(a-b), f(n) = floor(n*n/4).
# (The floors cancel: a+b and a-b are both odd or both even.)


def quarter_square(n: int) -> int:
    return n * n // 4


# The sine table make_matrix sums: 2032 = 16 * 127, so that four of them, the
# most any entry adds up to, come to 127 * 64 at most -- an entry can never
# round past 127, and nothing needs clamping.
SINE_SCALE = 2032


def sine(angle: int) -> int:
    return round(SINE_SCALE * math.sin(2 * math.pi * (angle & 255) / 256))


def s(a: int) -> int:
    return sine(a)


def c(a: int) -> int:
    return sine(a + 64)


def matrix_sums(x: int, y: int, z: int) -> list[int]:
    """The nine entries of Rz(z) Ry(y) Rx(x), each as 4 * 2032 * entry, made
    from sines of sums of angles alone (cos A cos B = (cos(A-B) + cos(A+B)) / 2
    and its relatives) -- no multiplications. Row-major."""
    return [
        2 * (c(y - z) + c(y + z)),
        c(x - y - z) + c(x - y + z) - c(x + y - z) - c(x + y + z) - 2 * (s(z + x) + s(z - x)),
        s(x + y + z) + s(x + y - z) - s(x - y + z) - s(x - y - z) + 2 * (c(x - z) - c(x + z)),
        2 * (s(z + y) + s(z - y)),
        s(z + x - y) + s(z - x + y) - s(z + x + y) - s(z - x - y) + 2 * (c(x - z) + c(x + z)),
        c(x + y - z) - c(x + y + z) - c(x - y - z) + c(x - y + z) - 2 * (s(x + z) + s(x - z)),
        -4 * s(y),
        2 * (s(x + y) + s(x - y)),
        2 * (c(x - y) + c(x + y)),
    ]


def make_matrix(x: int, y: int, z: int) -> list[int]:
    """The nine entries, signed bytes with 127 for 1.0: (sum + 32) >> 6."""
    return [(q + 32) >> 6 for q in matrix_sums(x, y, z)]


def to_signed16(value: int) -> int:
    value &= 0xFFFF
    return value - 0x10000 if value & 0x8000 else value


def rotate(matrix: list[int], vertex: tuple[int, int, int]) -> tuple[int, int, int]:
    """S = M v, each 16-bit."""
    return tuple(sum(matrix[3 * row + col] * vertex[col] for col in range(3)) for row in range(3))


def divide(s: int, z: int) -> int | None:
    """S / Z, truncated toward zero; None when |S| >= 256 * Z (no byte holds it)."""
    if z <= 0:
        raise ValueError("Z must be 1..255")
    q = abs(s) // z
    if q > 255:
        return None
    return -q if s < 0 else q


def project(rotated: tuple[int, int, int], zoff: int,
            centre_x: int = 128, centre_y: int = 96, height: int = 192) -> tuple[int, int] | None:
    """The screen pixel a rotated vertex lands on, or None if it is off the
    screen (256 x height, y down)."""
    sx, sy, sz = rotated
    z = (sz + zoff) >> 8
    if not 1 <= z <= 255:
        return None
    qx, qy = divide(sx, z), divide(sy, z)
    if qx is None or qy is None:
        return None
    px, py = centre_x + qx, centre_y - qy
    if not (0 <= px <= 255 and 0 <= py < height):
        return None
    return px, py


def ideal_matrix(x: int, y: int, z: int) -> list[float]:
    """Rz Ry Rx in floating point, to measure make_matrix against."""
    ax, ay, az = (2 * math.pi * a / 256 for a in (x, y, z))
    sx, cx, sy, cy, sz, cz = (math.sin(ax), math.cos(ax), math.sin(ay), math.cos(ay),
                              math.sin(az), math.cos(az))
    return [cy * cz, sx * sy * cz - cx * sz, cx * sy * cz + sx * sz,
            cy * sz, sx * sy * sz + cx * cz, cx * sy * sz - sx * cz,
            -sy, sx * cy, cx * cy]


def line(x0: int, y0: int, x1: int, y1: int) -> list[tuple[int, int]]:
    """The pixels draw_line sets: Bresenham, drawn downwards (the ends
    swapped if need be), stepping along the longer axis with the error
    starting at half of it."""
    if y1 < y0:
        x0, y0, x1, y1 = x1, y1, x0, y0
    dx, dy = abs(x1 - x0), y1 - y0
    sx = 1 if x1 >= x0 else -1
    x, y, pixels = x0, y0, []
    if dx >= dy:
        err = dx >> 1
        for _ in range(dx + 1):
            pixels.append((x, y))
            err -= dy
            if err < 0:
                err += dx
                y += 1
            x += sx
    else:
        err = dy >> 1
        for _ in range(dy + 1):
            pixels.append((x, y))
            err -= dx
            if err < 0:
                err += dy
                x += sx
            y += 1
    return pixels


def screen_address(x: int, y: int, base: int = 0x4000) -> int:
    """The byte holding pixel (x, y) of a Spectrum screen at base."""
    return base | ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2) | (x >> 3)


# ---------------------------------------------------------------------------
# Clipping: projected points as 16-bit screen coordinates, on the screen or
# not, and lines cut to a window.

WIDE_LIMIT = 16383      # the most a wide projection moves from the centre


def divide_wide(s: int, z: int) -> int:
    """S / Z, truncated toward zero, held to +-WIDE_LIMIT."""
    q = min(abs(s) // z, WIDE_LIMIT)
    return -q if s < 0 else q


def project_wide(rotated: tuple[int, int, int], zoff: int,
                 centre_x: int = 128, centre_y: int = 96) -> tuple[int, int] | None:
    """Where a rotated vertex lands, on the screen or off it, as 16-bit
    coordinates; None if Z is 0 (at or behind the eye)."""
    sx, sy, sz = rotated
    z = (sz + zoff) >> 8
    if not 1 <= z <= 255:
        return None
    return centre_x + divide_wide(sx, z), centre_y - divide_wide(sy, z)


LEFT, RIGHT, TOP, BOTTOM = 1, 2, 4, 8


def outcode(x: int, y: int, window: tuple[int, int, int, int]) -> int:
    left, top, right, bottom = window
    return ((LEFT if x < left else RIGHT if x > right else 0) |
            (TOP if y < top else BOTTOM if y > bottom else 0))


CHOP_BITS = 7       # the fraction bits crossing keeps
CHOP_HALF = 1 << (CHOP_BITS - 1)


def crossing(a_p: int, a_q: int, b_p: int, b_q: int, edge: int) -> int:
    """a where the line from (a_p, b_p) to (a_q, b_q) crosses b = edge, by
    halving -- a binary chop. From P, a step toward Q is halved again and
    again, and taken whenever b stays short of the edge: each halving is a
    bit of how far along the line the edge is (a step of a division) and
    adds that much of the line's a (a step of a multiplication). The steps
    keep CHOP_BITS fraction bits, and halve until the larger is under half a
    pixel: as many halvings as the bits in the larger of |a_q - a_p| and
    |b_q - b_p|, plus one."""
    sign = 1 if b_q > b_p else -1
    r = sign * (b_p - edge) << CHOP_BITS          # <= 0: how far short of the edge
    db = abs(b_q - b_p) << CHOP_BITS              # the step along b
    da = (a_q - a_p) << CHOP_BITS                 # and along a
    gone = 0                                      # how far along a, so far
    for _ in range((abs(b_q - b_p) | abs(a_q - a_p)).bit_length() + 1):
        db >>= 1
        da >>= 1                                  # (floor, as SRA does)
        if r + db < 0:
            r += db
            gone += da
    return a_p + ((gone + (da >> 1) + CHOP_HALF) >> CHOP_BITS)


def clip_line(x0: int, y0: int, x1: int, y1: int,
              window: tuple[int, int, int, int]) -> tuple[int, int, int, int] | None:
    """Cohen-Sutherland: the line cut to the window (left, top, right,
    bottom, inclusive), or None if none of it is in the window. An end that
    is outside is moved to the edge it is outside of, first of left, right,
    top, bottom, the first end before the second. Every crossing is worked
    out from the line's own ends, never from an end already moved: a moved
    end is rounded, and on a shallow line the slope would multiply that."""
    left, top, right, bottom = window
    px, py, qx, qy = x0, y0, x1, y1             # the line itself
    for _ in range(8):
        c0, c1 = outcode(x0, y0, window), outcode(x1, y1, window)
        if not c0 | c1:
            return x0, y0, x1, y1
        if c0 & c1:
            return None
        code = c0 or c1
        if code & LEFT:
            x, y = left, crossing(py, qy, px, qx, left)
        elif code & RIGHT:
            x, y = right, crossing(py, qy, px, qx, right)
        elif code & TOP:
            x, y = crossing(px, qx, py, qy, top), top
        else:
            x, y = crossing(px, qx, py, qy, bottom), bottom
        if c0:
            x0, y0 = x, y
        else:
            x1, y1 = x, y
    return None     # never reached: each end moves at most twice (clip_line in Z80 gives up the same way)


# ---------------------------------------------------------------------------
# Objects and the camera.
#
# A model is a list of vertices (signed bytes) that its faces share: each face
# is a loop of indices into the list, so a vertex is transformed once a frame
# however many faces use it, and an edge two faces share is drawn once. An
# object is a model at a 16-bit world position, turned by three angles; the
# camera is a 16-bit position and three angles too. Camera space has x right,
# y up and z forward, as project has always taken it.
#
# With Rc the camera's matrix (camera to world) and Ro the object's (model to
# world), a vertex v of an object at P, seen from a camera at C, is at
#   Rc^T (P - C) + (Rc^T Ro) v
# in camera space: per object, one translation T and one matrix M.

NEAR = 8                # world units: nothing nearer the eye than this is drawn
FAR = 8191              # nor farther
VIEW_BOX = 10400        # an object whose centre is outside +-VIEW_BOX of the
                        # camera on any axis is culled without a rotation. In
                        # the view's corner, (1/2, 1/2, 1), a point is 1.225
                        # times as far as its depth: 1.225 (FAR + 256) < 10400.
                        # T is then within 127 sqrt 3 10400 = 2.3M, and the
                        # side tests' 2 T - T within 6.9M: 24 bits, signed
VIEW_SCALE = 127        # T and the rotated vertices are 127 times world units


def transpose(m: list[int]) -> list[int]:
    return [m[3 * c + r] for r in range(3) for c in range(3)]


def faces_to_edges(faces: list[list[int]]) -> list[tuple[int, int]]:
    """Each edge of the faces once, in the order the faces first meet it."""
    edges, seen = [], set()
    for face in faces:
        for i, a in enumerate(face):
            b = face[(i + 1) % len(face)]
            key = (min(a, b), max(a, b))
            if key not in seen:
                seen.add(key)
                edges.append((a, b))
    return edges


def bounding_radius(vertices: list[tuple[int, int, int]]) -> int:
    """The least whole r with every vertex within r of the model's origin."""
    r2 = max(x * x + y * y + z * z for x, y, z in vertices)
    r = math.isqrt(r2)
    return r if r * r == r2 else r + 1


def cull_radii(r: int) -> tuple[int, int]:
    """The radius in view units (128 r, a little over 127 r), and that times
    sqrt 5, rounded up: what the side planes compare against."""
    r_view = 128 * r
    r5 = math.isqrt(5 * r_view * r_view)
    if r5 * r5 < 5 * r_view * r_view:
        r5 += 1
    return r_view, r5


def camera_constant(camera: list[int]) -> tuple[int, int, int]:
    """128 Rc^T (1, 1, 1): what turns the low bytes of P - C back from
    signed to unsigned."""
    return tuple(128 * v for v in rotate(transpose(camera), (1, 1, 1)))


def view_centre(position, camera_position, camera: list[int]):
    """T = Rc^T (P - C), 127 times world units; None if P is outside the box
    of +-VIEW_BOX round the camera (or P - C will not fit 16 bits)."""
    d = [p - c for p, c in zip(position, camera_position)]
    if any(abs(v) > VIEW_BOX for v in d):
        return None
    high = tuple(v >> 8 for v in d)                   # signed
    low = tuple((v & 0xFF) - 128 for v in d)          # unsigned, as signed
    seen = transpose(camera)
    k = camera_constant(camera)
    return tuple(256 * a + b + c for a, b, c in
                 zip(rotate(seen, high), rotate(seen, low), k))


def culled(t, r: int) -> bool:
    """Whether the sphere of radius r at T is wholly outside the view: nearer
    than NEAR, farther than FAR, or beyond one of the planes |x| = z / 2,
    |y| = z / 2 -- a 90-degree view, the screen's width and a little more than
    its height, so that it never leaves out what the screen would show."""
    tx, ty, tz = t
    r_view, r5 = cull_radii(r)
    if tz + r_view < NEAR * VIEW_SCALE or tz - r_view > FAR * 128:
        return True
    return any(2 * s * v - tz > r5 for v in (tx, ty) for s in (1, -1))


def view_matrix(camera: list[int], obj: list[int]) -> list[int]:
    """M = Rc^T Ro, 127 for 1.0: each column is Rc^T times a column of Ro --
    a rotate of a vector of signed bytes -- and q / 127 is rounded as
    (q + (q >> 7) + 64) >> 7, held to +-127."""
    seen = transpose(camera)
    columns = [rotate(seen, (obj[j], obj[3 + j], obj[6 + j])) for j in range(3)]
    m = [0] * 9
    for j, column in enumerate(columns):
        for i, q in enumerate(column):
            m[3 * i + j] = max(-127, min(127, (q + (q >> 7) + 64) >> 7))
    return m


def project_far(rotated, t, centre_x: int = 128, centre_y: int = 96):
    """Where a vertex lands: c = its rotation plus T, 24-bit; then shifted
    right by just enough to bring its depth into 8 bits (Z = c_z >> (8 + s)),
    so that one quick divide by a byte will do at any distance. None if at
    or behind the eye."""
    cx, cy, cz = (a + b for a, b in zip(rotated, t))
    if cz < 256:
        return None
    s = max(0, (cz >> 8).bit_length() - 8)
    z = cz >> (8 + s)

    def divide(v: int) -> int:
        v >>= s                                         # floor, as SRA does
        q = min(abs(v) // z, WIDE_LIMIT)
        return -q if v < 0 else q
    return centre_x + divide(cx), centre_y - divide(cy)


def ideal_view(vertex, position, angles, camera_position, camera_angles):
    """Where a vertex of an object lands, in floating point."""
    rc, ro = ideal_matrix(*camera_angles), ideal_matrix(*angles)
    world = [position[i] + sum(ro[3 * i + j] * vertex[j] for j in range(3)) for i in range(3)]
    d = [w - c for w, c in zip(world, camera_position)]
    x, y, z = (sum(rc[3 * j + i] * d[j] for j in range(3)) for i in range(3))
    return x, y, z


# ---------------------------------------------------------------------------
# The demo's flight, as demo.s does it: a frame turns the camera, moves it a
# quarter of its forward column (about 32 units) along where it looks, and
# turns each object by its spin.

def fly(camera_position, camera_angles, turn: int = 1):
    """The camera after a frame: (position, angles, Rc)."""
    angles = [camera_angles[0], (camera_angles[1] + turn) & 255, camera_angles[2]]
    rc = make_matrix(*angles)
    position = [((p + (rc[3 * i + 2] >> 2) + 32768) & 0xFFFF) - 32768
                for i, p in enumerate(camera_position)]
    return position, angles, rc
