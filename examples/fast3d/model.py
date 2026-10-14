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
