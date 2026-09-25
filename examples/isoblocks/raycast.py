"""A second way to draw an isoblocks view: cast a ray per triangle, with no
overdraw -- after Tom Harte's Isometric-Ray-Cast
(https://github.com/TomHarte/Isometric-Ray-Cast), whose README describes the
method. His repository has no licence, so none of its code is used: this is
the method, worked out again for isoblocks' axes and written from scratch.

The screen is a fixed grid of triangles 8 pixels wide. A diamond is two of
them, left and right of a vertical edge; it is the top face of a cube, and a
cube's side faces are two triangles each of the same grid. So every triangle
shows exactly one thing: the top of a cube, a cube's left face, its right
face, or the floor.

Which one is a ray cast, made cheap by storing the map shifted: the cube at
(u, v, h) is bit h of cell (u + h, v - h). The cubes one behind another along
a line of sight differ by (+1, -1, -1), so they all share a cell, and the
highest bit set in it is the nearest. A triangle can show only three lines of
sight -- its diamond's own, the one a diamond above it on the screen, and the
one beside it -- and working out their depths gives each a nearness of 3h
plus 3, 1 or 2 respectively. Those are never equal, and the largest names what
is seen.

Diamonds are (c, r) with c + r even: the vertical edge at x = 8c, the top at
y = 4r, in screen pixels from the view's top left. Diamond (c, r) is the
shifted cell (U0 + (c - r) / 2, V0 + (c + r) / 2).
"""
from __future__ import annotations

import isogeom

FLOOR, TOP, LEFT_FACE, RIGHT_FACE = 0, 1, 2, 3

# The view on the screen: strips (8-pixel columns) 1-30 and character rows
# 1-16, as the painter shows it -- screen columns 1-30, lines 8-135.
FIRST_STRIP, STRIPS = 1, 30
FIRST_CHAR_ROW, CHAR_ROWS = 1, 16


def shift_map(cells: bytes) -> bytes:
    """The map shifted for view 0: cube (u, v, h) to bit h of (u + h, v - h).

    A cube that would land off the map is dropped; maps keep a border wide
    enough that none does."""
    size = isogeom.MAP_SIZE
    shifted = bytearray(size * size)
    for v in range(size):
        for u in range(size):
            bits = cells[v * size + u]
            for h in range(isogeom.HEIGHTS):
                if bits >> h & 1:
                    U, V = u + h, v - h
                    if 0 <= U < size and 0 <= V < size:
                        shifted[V * size + U] |= 1 << h
    return bytes(shifted)


def nearest(bits: int) -> int:
    """The height of the nearest cube in a shifted cell, or -1 for none."""
    return bits.bit_length() - 1


def origin(focus: tuple[int, int]) -> tuple[int, int]:
    """(U0, V0) for a focus, so the ray view shows what the painter's view 0 does.

    The painter reads its first cell at S = focus - (0, 16), and that cell's
    diamond works out at c = 1, r = -1 with (U, V) = S - (1, 0)."""
    sx, sy = isogeom.start_from_focus(0)
    return focus[0] + sx - 1, focus[1] + sy


def triangles(shifted: bytes, focus: tuple[int, int]) -> dict:
    """{(strip, band): colour} for every triangle the view shows.

    Strip s is the 8 pixels right of x = 8s; band k is the triangle there
    whose vertical edge spans y = 4k to 4k + 8. It is the right half of
    diamond (s, k) when s + k is even, and the left half of (s + 1, k)
    otherwise."""
    U0, V0 = origin(focus)
    size = isogeom.MAP_SIZE

    def cell(U: int, V: int) -> int:
        return shifted[V * size + U]

    def nearness(bits: int, offset: int) -> int:
        h = nearest(bits)
        return 3 * h + offset if h >= 0 else 0

    result = {}
    first_band = 2 * FIRST_CHAR_ROW - 1
    last_band = 2 * (FIRST_CHAR_ROW + CHAR_ROWS - 1) + 1
    for c in range(FIRST_STRIP, FIRST_STRIP + STRIPS + 1):
        for r in range(first_band, last_band + 1):
            if (c + r) % 2:
                continue
            U, V = U0 + (c - r) // 2, V0 + (c + r) // 2
            front = nearness(cell(U, V), 3)
            above = nearness(cell(U + 1, V - 1), 1)       # a diamond up the screen
            left = nearness(cell(U, V - 1), 2)            # up and to the left
            right = nearness(cell(U + 1, V), 2)           # up and to the right
            best = max(front, above)
            # The left triangle: its own top, the left neighbour's right
            # face, or the left face of the cube above.
            n = max(best, left)
            result[(c - 1, r)] = (FLOOR if n == 0 else TOP if n % 3 == 0
                                  else RIGHT_FACE if n % 3 == 2 else LEFT_FACE)
            # The right triangle: its own top, the right neighbour's left
            # face, or the right face of the cube above.
            n = max(best, right)
            result[(c, r)] = (FLOOR if n == 0 else TOP if n % 3 == 0
                              else LEFT_FACE if n % 3 == 2 else RIGHT_FACE)
    return result


# Which triangle of a strip a pixel is in. Half a diamond is 8 pixels wide
# and its rows, from the vertical edge out, are 1, 3, 5, 7, 7, 5, 3, 1 pixels
# long -- the widths that make the triangles tile with no overlap and no gap.
HALF_WIDTHS = (1, 3, 5, 7, 7, 5, 3, 1)


def band_at(strip: int, x: int, y: int) -> int:
    """The band of strip `strip` holding pixel (x, y), x 0-7 across the strip."""
    for k in (y // 4 - 1, y // 4):
        top = 4 * k
        if not top <= y < top + 8:
            continue
        right_half = (strip + k) % 2 == 0      # the edge is on the strip's left
        reach = x if right_half else 7 - x      # pixels from the vertical edge
        if reach < HALF_WIDTHS[y - top]:
            return k
    raise AssertionError(f"pixel ({x}, {y}) of strip {strip} is in no triangle")


# The face patterns, by colour, as functions of the screen pixel. Each repeats
# every 2 pixels both ways, so a pattern lines up the same on every block.
PATTERNS = {
    FLOOR: lambda x, y: False,
    TOP: lambda x, y: x % 2 == 0 and y % 2 == 0,               # 25%
    LEFT_FACE: lambda x, y: (x + y) % 2 == 0,                  # 50%
    RIGHT_FACE: lambda x, y: not (x % 2 == 0 and y % 2 == 0),  # 75%
}


def render(shifted: bytes, focus: tuple[int, int]) -> list[bytes]:
    """The view as screen lines 8-135, columns 1-30, pixel by pixel."""
    colours = triangles(shifted, focus)
    lines = []
    for line in range(8 * FIRST_CHAR_ROW, 8 * (FIRST_CHAR_ROW + CHAR_ROWS)):
        row = bytearray()
        for strip in range(FIRST_STRIP, FIRST_STRIP + STRIPS):
            byte = 0
            for x in range(8):
                colour = colours[(strip, band_at(strip, x, line))]
                if PATTERNS[colour](8 * strip + x, line):
                    byte |= 0x80 >> x
            row.append(byte)
        lines.append(bytes(row))
    return lines


def flat_block() -> list:
    """A painter's block picture made of the same triangles and patterns.

    Rows of (mask, bits) byte pairs, as build.read_blocks gives them: the top
    diamond, the left face and the right face, each triangle of the grid in
    its face's pattern. Painted by the painter, it must give the picture the
    rays give -- which is what check_ray.py tests."""
    kind = {}
    # A block's picture is 16 wide, its top diamond's edge at x = 8, y = 0-8.
    for y in range(16):
        for x in range(16):
            # Which triangle of the grid, relative to the block: strip 0 is
            # x 0-7 (left of the edge), strip 1 is x 8-15.
            strip = x // 8
            local = x % 8
            for k in (y // 4 - 1, y // 4):
                top = 4 * k
                if not top <= y < top + 8:
                    continue
                # Diamond (1, 0) is the block's top: strip 0 holds its left
                # half in band 0, strip 1 its right half in band 0.
                right_half = (strip + k) % 2 == 1
                reach = local if right_half else 7 - local
                if reach >= HALF_WIDTHS[y - top]:
                    continue
                if k == 0:
                    kind[(x, y)] = TOP
                elif (strip, k) in ((0, 1), (0, 2)):
                    kind[(x, y)] = LEFT_FACE
                elif (strip, k) in ((1, 1), (1, 2)):
                    kind[(x, y)] = RIGHT_FACE
    rows = []
    for y in range(16):
        row = []
        for byte in range(2):
            mask = bits = 0
            for bit in range(8):
                x = 8 * byte + bit
                weight = 0x80 >> bit
                if (x, y) not in kind:
                    mask |= weight
                elif PATTERNS[kind[(x, y)]](x, y):
                    bits |= weight
            row.append((mask, bits))
        rows.append(row)
    return rows


# ---------------------------------------------------------------------------
# Sprites.
#
# A sprite stands in a cell at a height, like a cube, and its 16 x 16 picture
# goes where that cube's would. Depth is on one scale throughout: a cube at
# (u, v, h) is v - u + h deep, nearer the larger. A sprite's pixel shows in a
# triangle if the sprite is nearer than the face the rays found there (a
# block wins a tie), or the triangle is floor.
#
# In diamond terms that is one comparison. The face the rays found in a
# triangle of diamond (c, r), with n the winning nearness (3h + 3, + 1 or + 2
# by the line of sight it came from), is r + n - 3 deep, less the view's
# V0 - U0; a sprite whose top is diamond (c_s, r_s) at height h is r_s + 3h
# deep, less the same. So it shows where n is 0 or r_s + 3h > r + n - 3.
# ---------------------------------------------------------------------------

def triangle_nearness(shifted: bytes, focus: tuple[int, int], strip: int, band: int) -> tuple[int, int]:
    """(r, n) for a triangle: its diamond's band and the winning nearness."""
    U0, V0 = origin(focus)
    size = isogeom.MAP_SIZE
    if (strip + band) % 2 == 0:
        c, r, side = strip, band, "right"
    else:
        c, r, side = strip + 1, band, "left"
    U, V = U0 + (c - r) // 2, V0 + (c + r) // 2

    def nearness(bits: int, offset: int) -> int:
        h = nearest(bits)
        return 3 * h + offset if h >= 0 else 0

    front = nearness(shifted[V * size + U], 3)
    above = nearness(shifted[(V - 1) * size + U + 1], 1)
    beside = (nearness(shifted[(V - 1) * size + U], 2) if side == "left"
              else nearness(shifted[V * size + U + 1], 2))
    return r, max(front, above, beside)


def sprite_place(focus: tuple[int, int], u: int, v: int, h: int) -> tuple[int, int]:
    """(c, r): the diamond a sprite's top would be, for its picture's place."""
    U0, V0 = origin(focus)
    U, V = u + h - U0, v - h - V0
    return U + V, V - U


def render_with_sprites(shifted: bytes, focus: tuple[int, int], sprites: list) -> list[bytes]:
    """The view with sprites: (u, v, h, picture), the picture 16 rows of
    (opaque, ink) 16-bit pairs, bit 15 the leftmost pixel. Farthest first."""
    lines = [bytearray(row) for row in render(shifted, focus)]
    first_line = 8 * FIRST_CHAR_ROW
    depths = {}
    for u, v, h, picture in sorted(sprites, key=lambda s: s[1] - s[0] + s[2]):
        c, r = sprite_place(focus, u, v, h)
        deep = r + 3 * h
        for row in range(16):
            line = 4 * r + row
            if not first_line <= line < first_line + 8 * CHAR_ROWS:
                continue
            opaque, ink = picture[row]
            for x in range(16):
                if not opaque & (0x8000 >> x):
                    continue
                strip = c - 1 + x // 8
                if not FIRST_STRIP <= strip < FIRST_STRIP + STRIPS:
                    continue
                band = band_at(strip, x % 8, line)
                key = (strip, band)
                if key not in depths:
                    depths[key] = triangle_nearness(shifted, focus, strip, band)
                tr, n = depths[key]
                if n and deep <= tr + n - 3:
                    continue
                byte = lines[line - first_line]
                column = strip - FIRST_STRIP
                bit = 0x80 >> (x % 8)
                if ink & (0x8000 >> x):
                    byte[column] |= bit
                else:
                    byte[column] &= ~bit & 0xFF
    return [bytes(line) for line in lines]
