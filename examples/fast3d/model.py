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


# ---------------------------------------------------------------------------
# Skipping the cull (CULL_SKIP in objects.s). An object the cull leaves out
# was some way past a plane of the view: its margin. T, its centre in camera
# space, can only move so far from one picture to the next, and exactly how
# far follows from the matrices as they are, nothing assumed about the
# camera: with M the camera's installed matrix (Rc^T, 127 for 1.0) and C its
# position, T' - T = (M' - M)(P - C) + M'(C - C'), so on any axis
#
#     |T' - T| <= E D + 127 m
#
# with E the largest sum over a row of |M' - M|, D the largest |P - C| on an
# axis, and m the sum of |C' - C| over the axes. Each picture the margin is
# cut by that, in its units of 256, and the object is skipped while something
# is left. D is held as one of the sizes Q = q 2^k (q 4..7, k 5..11), chosen
# above D with room to spare (a quarter at least), and a limit on the
# odometer -- the camera's moves summed -- says when it could have travelled
# that room, so that D could have reached Q: the object is tested again
# then, as it is when its margin is gone, or when a move too big to sum
# (JUMP or more) voids every margin. The side tests' 2t -+ z can move three
# times as far as T, so a quarter of their margin is kept. None of this
# changes what is drawn: an object skipped would have been culled, and
# check.py's demo checks hold the Z80 to that, jumps and all.

JUMP = 16384            # a move (the sum over the axes) this big voids every margin
SKIP_K_LEAST = 5        # the smallest k a size Q = q 2^k has
SKIP_K_COUNT = 7        # k = 5..11: Q up to 7 * 2048, past VIEW_BOX + its room
SKIP_ROOM_SHIFT = 2     # the room above D a size must leave: D >> this, a quarter


def skip_size(d):
    """How cull_object holds D = max |d|, d being P - C: (k, q, room), Q = q 2^k
    the first size at or above D + D / 4 + 1, and room = Q - D. A quarter:
    a sixteenth had the camera travel it in a picture or two, so that the
    odometer ended most skips long before the margin did."""
    big = max(abs(v) for v in d)
    above = big + (big >> SKIP_ROOM_SHIFT) + 1
    k = SKIP_K_LEAST + (above >> 8).bit_length()
    q = max(4, -(-above // (1 << k)))
    if q == 8:
        q, k = 4, k + 1
    return k, q, (q << k) - big


def skip_index(k: int, q: int) -> int:
    """A size's place in skip_bounds, in words."""
    return (k - SKIP_K_LEAST) * 4 + (q - 4)


def skip_bounds(seen_before, seen_after, pos_before, pos_after, wrap: bool = False):
    """What cull_skip_bounds leaves in skip_bounds, by (k, q): the most a margin
    can have shrunk this picture, floor(E Q / 256) + m / 2 + 2 (the 2 covers
    the two floors), saturated at 65535; or None for a jump. With wrap
    (WORLD_WRAP), the move on each axis is taken modulo 65,536, as -32768..
    32767, like P - C: a camera crossing the world's edge moves a step. The
    bound still holds: a skipped object is tested again before the camera
    could have travelled its room, so its P - C never gets near 32768 and
    never wraps to the other side while it is skipped."""
    e = max(sum(abs(a - b) for a, b in zip(seen_after[3 * i:3 * i + 3], seen_before[3 * i:3 * i + 3]))
            for i in range(3))
    moves = [a - b for a, b in zip(pos_after, pos_before)]
    if wrap:
        moves = [to_signed16(v) for v in moves]
    m = sum(abs(v) for v in moves)
    if m >= JUMP:
        return None
    return {(k, q): min(65535, min(65535, (e * q << k) >> 8) + (m >> 1) + 2)
            for k in range(SKIP_K_LEAST, SKIP_K_LEAST + SKIP_K_COUNT) for q in range(4, 8)}


def skip_margin(t, r: int):
    """The most cull_object may leave as the margin for an object culled at T:
    the largest any culling test allows, in units of 256 (depth) or 1024 (the
    sides). A stored margin must be no more than this, since the Z80 works
    from one test, roughly or exactly."""
    tx, ty, tz = t
    r_view, r5 = cull_radii(r)
    margins = [(NEAR * VIEW_SCALE - (tz + r_view)) >> 8, ((tz - r_view) - FAR * 128) >> 8]
    margins += [(2 * sg * v - tz - r5) >> 10 for v in (tx, ty) for sg in (1, -1)]
    return max(margins)


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


def part_edges(faces: list[list[int]], parts: list[int]) -> tuple[list, list]:
    """A model's edges and, for each, the faces either side of it: (edges,
    edge_faces). parts says how many of the faces, in order, each convex part
    has. Each part has its own edges -- an edge two parts meet at is in both
    -- and an edge on one face only has that face twice. With no parts the
    model has no faces: its edges are faces_to_edges' and edge_faces is []."""
    if not parts:
        return faces_to_edges(faces), []
    edges, edge_faces, first = [], [], 0
    for count in parts:
        seen = {}
        for f in range(first, first + count):
            face = faces[f]
            for i, a in enumerate(face):
                b = face[(i + 1) % len(face)]
                key = (min(a, b), max(a, b))
                if key in seen:
                    edge_faces[seen[key]] = (edge_faces[seen[key]][0], f)
                else:
                    seen[key] = len(edges)
                    edges.append((a, b))
                    edge_faces.append((f, f))
        first += count
    return edges, edge_faces


def faces_front(points, faces: list[list[int]]) -> list[bool]:
    """Which faces look towards the eye, by a sign test on the projected
    face (facing_edges in Z80): the first three of its vertices, in its
    loop's order, that are in front of the near plane, (x0, y0), (x1, y1),
    (x2, y2) on the screen. A face is wound anticlockwise seen from outside,
    and the screen's y runs down, so it looks towards the eye if (x1 - x0)
    (y2 - y0) - (y1 - y0) (x2 - x0) > 0 -- or is 0, edge on, where its edges
    had better be kept. Three vertices of a convex face in front of the eye,
    in order, project to a triangle wound as the face is seen, so any three
    will do. A face without three in front counts as looking towards the
    eye: its edges are kept, and cut at the near plane as ever.

    The four differences are first shifted right together (floor, as SRA
    does) until each fits a signed byte, so that the products are two of
    mul8s: d ^ (d >> 15) is |d| (less one if negative), and the shift is
    what brings the largest of those under 128."""
    result = []
    for face in faces:
        corners = [points[v] for v in face if points[v] is not None][:3]
        if len(corners) < 3:
            result.append(True)
            continue
        (x0, y0), (x1, y1), (x2, y2) = corners
        d = [x1 - x0, y1 - y0, x2 - x0, y2 - y0]
        spread = 0
        for v in d:
            spread |= v ^ (v >> 15)
        shift = max(0, spread.bit_length() - 7)
        dx1, dy1, dx2, dy2 = (v >> shift for v in d)
        result.append(dx1 * dy2 >= dy1 * dx2)
    return result


def facing_edges(points, faces, edges, edge_faces, front=None) -> list[tuple[int, int]]:
    """The edges facing_edges keeps: those with a face either side that looks
    towards the eye, in order -- or, for a model with no faces, every one.
    front: which faces look towards the eye, if not faces_front's verdicts
    (faces_front_eye's, with FACE_EYE)."""
    if not faces:
        return list(edges)
    if front is None:
        front = faces_front(points, faces)
    return [e for e, (f1, f2) in zip(edges, edge_faces) if front[f1] or front[f2]]


# ---------------------------------------------------------------------------
# FACE_EYE: faces judged against the eye, carried into the model's space
# once an object, rather than by their projections. A face looks towards
# the eye when the eye is on the outer side of its plane, n . e > d: three
# products a face, and right for a face with corners behind the eye too.
#
# The eye in model space is -M^-1 T; M is 127 times a rotation, near
# enough, so -M^T T / 127^2. T is first shifted right by k until each part
# fits a signed byte, T', so that one rotate (with M^T installed) makes U =
# -M^T T', 16-bit; and U is shifted right by j to signed bytes too, U'. So
# U' is the eye times 127^2 / 2^(k + j), and n . e > d becomes
# n . U' > 127^2 d / 2^(k + j) -- for whole numbers on the left, the same
# as n . U' > (127^2 d) >> (k + j). Each face carries n, its outward normal
# as signed bytes 127 long, and D = 127^2 d, d the least n . v over its
# corners: with n rounded, its corners are not quite on one plane, and the
# least puts the plane where the face counts as looking towards the eye
# when in doubt. face_geometry.py says how near edge on a face must be to
# be misjudged.

EYE_SCALE = 127 * 127           # M^T M, near enough


def face_planes(vertices, faces) -> list[tuple[tuple[int, int, int], int]]:
    """Each face's (n, D) for FACE_EYE: n its outward normal, by its winding,
    as signed bytes 127 long (rounded), and D = EYE_SCALE d, d the least
    n . v over its corners."""
    planes = []
    for face in faces:
        a, b, c = (vertices[v] for v in face[:3])
        u, w = [q - p for p, q in zip(a, b)], [q - p for p, q in zip(a, c)]
        raw = (u[1] * w[2] - u[2] * w[1], u[2] * w[0] - u[0] * w[2], u[0] * w[1] - u[1] * w[0])
        length = math.sqrt(sum(x * x for x in raw))
        n = tuple(int(math.floor(127 * x / length + 0.5)) for x in raw)
        d = min(sum(p * q for p, q in zip(n, vertices[v])) for v in face)
        planes.append((n, EYE_SCALE * d))
    return planes


def eye_in_model(m: list[int], t) -> tuple[list[int], int]:
    """The eye in the model's space, as facing_edges works it out with
    FACE_EYE: (U', s), U' signed bytes that are the eye times EYE_SCALE /
    2^s. Each shift is the least that brings every part into a signed byte:
    d ^ (d >> bits) is |d| (less one if negative), as in faces_front."""
    spread = 0
    for v in t:
        spread |= v ^ (v >> 23)
    k = max(0, spread.bit_length() - 7)
    u = [-v for v in rotate(transpose(m), [v >> k for v in t])]
    spread = 0
    for v in u:
        spread |= v ^ (v >> 15)
    j = max(0, spread.bit_length() - 7, 8 - k)      # s at least 8, so that D >> s fits 24 bits
    return [v >> j for v in u], k + j


def faces_front_eye(planes, eye) -> list[bool]:
    """Which faces look towards the eye, with FACE_EYE: n . U' > D >> s."""
    u, s = eye
    return [sum(p * q for p, q in zip(n, u)) > (big_d >> s) for n, big_d in planes]


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


def view_centre(position, camera_position, camera: list[int], wrap: bool = False):
    """T = Rc^T (P - C), 127 times world units; None if P is outside the box
    of +-VIEW_BOX round the camera (or P - C will not fit 16 bits). With
    wrap (WORLD_WRAP), P - C is taken modulo 65,536 on each axis, as
    -32768..32767: the world wraps, and an object across its edge is seen
    from the other side."""
    d = [p - c for p, c in zip(position, camera_position)]
    if wrap:
        d = [to_signed16(v) for v in d]
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


def view_point(rotated, t):
    """c, a vertex in camera space: its rotation plus T, 24-bit."""
    return tuple(a + b for a, b in zip(rotated, t))


def to_signed24(value: int) -> int:
    return ((value + 0x800000) & 0xFFFFFF) - 0x800000


def project_far(rotated, t, centre_x: int = 128, centre_y: int = 96, fine: bool = False):
    """Where a vertex lands: c = its rotation plus T, 24-bit; then shifted
    right by just enough to bring its depth into 8 bits (Z = c_z >> (8 + s)),
    so that one quick divide by a byte will do at any distance. None if
    behind the near plane (c_z < NEAR_PLANE).

    With fine (PROJECT_FINE), a near depth is shifted left as far as a far
    one is right, so that Z is always 128..255: as it is, c_z >> 8 near the
    eye is a few units, and a point 20 units away lands up to a tenth out.
    x and y go left with it, in 24 bits; and the quotient is rounded,
    |v| + Z / 2 divided, rather than truncated."""
    cx, cy, cz = view_point(rotated, t)
    if cz < NEAR_PLANE:
        return None
    s = (cz >> 8).bit_length() - 8
    if not fine:
        s = max(0, s)
    z = cz >> (8 + s) if s >= 0 else (cz << -s) >> 8

    def divide(v: int) -> int:
        v = v >> s if s >= 0 else to_signed24(v << -s)  # floor, as SRA does
        q = min((abs(v) + (z >> 1 if fine else 0)) // z, WIDE_LIMIT)
        return -q if v < 0 else q
    return centre_x + divide(cx), centre_y - divide(cy)


# ---------------------------------------------------------------------------
# The near plane. An edge with one end in front of the near plane and the
# other behind it is cut where it crosses the plane, in camera space, and
# the part in front drawn; an edge wholly behind it is left out.
#
# The plane is at c_z = NEAR_PLANE = 1024, Z = 4 to the projection, so a
# point on it lands at c_x / 4, c_y / 4 from the centre: no divide. Seen
# from above, with x and z both in units of c / 4 -- pixels across, at the
# plane -- the cut is where a line crosses z = 256: t = (256 - a_z) / (b_z -
# a_z) of the way along, worked out once to 16 bits by a restoring
# division, and then x and y together, a + t (b - a), from t's bits the
# least first: each bit adds d = b - a or not, and halves, with a byte of
# fraction kept (near_crossing). Bringing c into those
# units, floor(c / 4), keeps the numbers in 16 bits: for an object
# cull_object lets through, with a vertex behind the plane, |T_z| is under
# 1024 + 127 r and 2 |T_x| under T_z + 128 r sqrt 5, so with r <= 222 (a
# signed byte's) |c_x| / 4 stays under 19,000, and an edge spans at most
# 127 * 255 sqrt 3 / 4, 14,000. Where the edge crosses the plane is nearer
# still: inside the sphere (radius R = 127 r) and on the plane, with the
# centre inside the side planes, x is at most 512 + sqrt 5 R -- under
# 16,000 once divided by 4. So the cut never needs holding to
# +-WIDE_LIMIT, as a far projected point does; it is held all the same, for
# a program that cuts what the cull has not passed, so that clip_line can
# always take the line. near_geometry.py holds this to exact geometry.
#
# The cull's own near test is NEAR * 127, a hair nearer than the plane
# (1024 is 8.06 units): an object it lets through between the two has
# every vertex behind the plane, and draws nothing.

NEAR_PLANE = NEAR * 128     # c_z of the near plane: 8.06 units, 1024 / 127
NEAR_SHIFT = 2              # c >> NEAR_SHIFT: units of a pixel at the plane


NEAR_T_BITS = 16           # the bits of t near_crossing works out


def near_crossing(behind, front) -> tuple[int, int]:
    """Where the edge from c = behind (c_z < NEAR_PLANE) to c = front (c_z
    >= NEAR_PLANE) crosses the near plane: x and y in units of c / 4, the
    offsets from the screen's centre there (y up).

    t = (256 - a_z) / (b_z - a_z), in 0..1, to NEAR_T_BITS bits by a
    restoring division (what is left, doubled; take b_z - a_z when it
    will go). Then, on each axis, a + d t with d = b - a: an offset with
    eight bits of fraction starts at half of d -- half the last bit of t,
    to centre its truncation -- and for each bit of t, the least first,
    d is added if the bit is set and the offset halved (floor, as SRA
    does): d t, in a 16-bit offset and a byte of fraction, never more than
    2 |d|. Rounded to the nearest at the end. Within 0.62 of a pixel of a
    + d t exactly: 0.11 for t's truncation, under 0.01 for the halvings,
    and the rounding."""
    a = [v >> NEAR_SHIFT for v in behind]
    b = [v >> NEAR_SHIFT for v in front]
    assert all(-32768 <= v <= 32767 for v in a + b)
    dz, left = b[2] - a[2], (NEAR_PLANE >> NEAR_SHIFT) - a[2]
    assert 0 < left <= dz < 32768 and all(abs(q - p) < 16384 for p, q in zip(a[:2], b[:2]))
    t = 0
    for _ in range(NEAR_T_BITS):
        left <<= 1
        t <<= 1
        if left >= dz:
            left -= dz
            t |= 1

    def along(p: int, q: int) -> int:
        d = q - p
        offset = d << 7
        for k in range(NEAR_T_BITS):
            if t >> k & 1:
                offset += d << 8
            offset >>= 1
        return p + ((offset + 128) >> 8)
    return along(a[0], b[0]), along(a[1], b[1])


def cut_edge(behind, front, centre_x: int = 128, centre_y: int = 96) -> tuple[int, int]:
    """The screen point near_crossing's crossing lands on, held to
    +-WIDE_LIMIT from the centre as project_far's are (which, for an object
    the cull lets through, it never needs: see above)."""
    x, y = (max(-WIDE_LIMIT, min(WIDE_LIMIT, v)) for v in near_crossing(behind, front))
    return centre_x + x, centre_y - y


def object_lines(vertices, edges, m, t, centre_x: int = 128, centre_y: int = 96, fine: bool = False,
                 nudges=None) -> tuple[list, list]:
    """An object's points (transform_object's: None behind the near plane)
    and its cut lines (cut_edges'): for each edge, in order, that crosses
    the near plane, its front end's point and where it is cut, x0, y0, x1,
    y1. The edges with both ends in front are drawn between the points.
    The centre is the engine's SCREEN_CENTRE_X and _Y. fine is
    PROJECT_FINE's projection; nudges (VERTEX_NUDGE), for each vertex, a
    small offset its T takes, the program's to give."""
    rotated = [rotate(m, v) for v in vertices]
    ts = [t if nudges is None else tuple(a + b for a, b in zip(t, nudge)) for nudge in (nudges or [None] * len(vertices))]
    points = [project_far(r, tk, centre_x, centre_y, fine) for r, tk in zip(rotated, ts)]
    cuts = []
    for i, j in edges:
        if (points[i] is None) != (points[j] is None):
            front, behind = (i, j) if points[j] is None else (j, i)
            cuts.append(points[front] + cut_edge(view_point(rotated[behind], ts[behind]),
                                                 view_point(rotated[front], ts[front]), centre_x, centre_y))
    return points, cuts


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
