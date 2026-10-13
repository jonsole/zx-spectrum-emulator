"""A model of edges.s and compose.s: from the Z80's own verge point lists to
the bytes on the screen, with the objects' parts (objects.s) painted over
each line as compose paints them.

It is written from what the two stages are meant to do, not from how they do
it -- a line between two points stepped with a remainder, markers sorted by
x, every run filled with its colour's pattern -- so a mismatch is the Z80
doing something other than that. The geometry that comes before it is
checked against view_model.py instead.

The layout comes from the build's symbols (the list addresses, the view's
size, the patterns' table), so it follows the code when that moves.
"""

from probe import signed16

# Colours, as the verge lists and patterns.s number them.
GRASS, ROAD, VERGE_BLACK, VERGE_RED, VERGE_WHITE, SKY = range(6)
COLOURS = 6
# The size of a point in a verge list, and where its fields are.
POINT_SIZE = 8


def rotate2(p: int) -> int:
    """A pattern as odd lines use it: rotated right two places."""
    return ((p >> 2) | (p << 6)) & 0xFF


def row_address(y: int) -> int:
    return 0x4000 | ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2)


class Layout:
    def __init__(self, symbols: dict[str, int], memory: bytes):
        self.view_lines = symbols["VIEW_LINES"]
        self.view_top = symbols["VIEW_TOP"]
        self.horizon = symbols["HORIZON"]
        self.max_marks = symbols["MAX_MARKS"]
        self.verge_r = symbols["VERGE_R"]
        self.verge_l = symbols["VERGE_L"]
        self.vr_count = symbols["vr_count"]
        self.vl_count = symbols["vl_count"]
        self.obj_count = symbols["obj_count"]
        self.obj_parts = symbols["obj_parts"]
        self.part_size = symbols["PART_SIZE"]
        base = symbols["patterns"]
        self.patterns = [(memory[base + c], rotate2(memory[base + c])) for c in range(COLOURS)]


def object_parts(layout: Layout, memory: bytes) -> list[tuple]:
    """The objects' parts, in the order compose paints them: (lowest line,
    highest line, first byte, bytes after it, first byte's mask, last byte's
    mask, pattern on an even line, on an odd one, the edges' patterns both
    ways, the left edge's bit in the first byte, the right edge's in the
    last, whether it has edges, then spare bytes)."""
    return [tuple(memory[layout.obj_parts + layout.part_size * i:
                         layout.obj_parts + layout.part_size * (i + 1)])
            for i in range(memory[layout.obj_count])]


def part_extent(part: tuple) -> tuple[int, int]:
    """A part's first and last x, from its bytes and masks."""
    lo, hi, first, more, fmask, lmask = part[:6]
    lead = 8 - fmask.bit_length()               # the first byte's pixels before it
    last_mask = fmask if more == 0 else lmask
    trail = (last_mask & -last_mask).bit_length() - 1
    return first * 8 + lead, (first + more) * 8 + 7 - trail


def paint_parts(row: bytearray, y: int, parts: list[tuple]) -> None:
    """Paints the parts on line y over the 32 bytes of its row: each its
    fill, then a pixel at each end in its edges' pattern."""
    def mix(i, pattern, m):
        row[i] = (row[i] & ~m & 0xFF) | (pattern & m)
    for part in parts:
        lo, hi, first, more, fmask, lmask, even, odd, eeven, eodd, fedge, ledge, edges = part[:13]
        if not lo <= y <= hi:
            continue
        pattern = odd if y & 1 else even
        masks = [fmask] if more == 0 else [fmask] + [0xFF] * (more - 1) + [lmask]
        for i, m in enumerate(masks):
            mix(first + i, pattern, m)
        if edges:
            edge = eodd if y & 1 else eeven
            mix(first + more, edge, ledge)
            mix(first, edge, fedge)


def verge_lists(layout: Layout, memory: bytes) -> dict[str, list]:
    """Per side, (inner x, outer x, line, colour) from far to near. A side's
    last point can be below the view, with a negative line."""
    out = {}
    for side, base, count in (("R", layout.verge_r, layout.vr_count),
                              ("L", layout.verge_l, layout.vl_count)):
        pts = []
        for i in range(memory[count]):
            a = base + POINT_SIZE * i
            pts.append((signed16(memory[a] | memory[a + 1] << 8),
                        signed16(memory[a + 2] | memory[a + 3] << 8),
                        memory[a + 4] - (256 if memory[a + 4] >= 128 else 0),
                        memory[a + 5]))
        out[side] = pts
    return out


def edges(layout: Layout, lists: dict[str, list]) -> list:
    """Per track line: [markers (x, colour), the colour it starts in, and the
    x that colour was set at, off the left]."""
    recs = [[[], (GRASS if y < layout.horizon else SKY), -32768]
            for y in range(layout.view_lines)]

    def mark(x, y, c):
        if y >= layout.view_lines:
            return
        r = recs[y]
        if 0 <= x < 256:
            if len(r[0]) < layout.max_marks:
                r[0].append((x, c))
        elif x < 0:
            # Off the left, the edge furthest right (compared unsigned, as
            # the Z80 does) sets the colour the line starts in.
            if (x & 0xFFFF) >= (r[2] & 0xFFFF):
                r[2] = x
                r[1] = c

    def stepped(x, y, dx, n, ys, lines, c):
        """`lines` markers from (x, y), moving dx across every n lines."""
        q, r = divmod(abs(dx), n)
        xs = 1 if dx >= 0 else -1
        err = n // 2
        for k in range(lines):
            mark(x, y, c)
            y += ys
            err += r
            step = q
            if err >= n:
                err -= n
                step += 1
            x += xs * step

    def raster(ax, al, bx, bl, c, last):
        if al == bl:
            if last:
                mark(bx, bl, c)
            return
        n = abs(bl - al)
        if bl < 0:
            # A last point under the view: stepped towards it, marked down
            # to line 0.
            stepped(ax, al, bx - ax, n, -1, al + 1, c)
            return
        stepped(ax, al, bx - ax, n, 1 if bl > al else -1, n + 1 if last else n, c)

    def edge(pts, field, colour, left):
        if not pts:
            return
        p = [(pt[field], pt[2], pt[3] if colour is None else colour) for pt in pts]
        low, low_colour = p[0][1], p[0][2]
        for k, ((ax, al, _), (bx, bl, c)) in enumerate(zip(p, p[1:])):
            if 0 <= bl < low:
                low, low_colour = bl, c
            raster(ax, al, bx, bl, c, k == len(p) - 2)
            if bl < 0:
                low = 0                 # it reached the bottom
        if left:
            # Below its lowest point a left edge has gone off the left of
            # the view, and still sets the colour those lines start with.
            for y in range(min(low, layout.view_lines)):
                mark(-32767, y, low_colour)

    left, right = lists["L"], lists["R"]
    edge(left, 1, None, True)      # left verge's outer edge: the verge's colour
    edge(left, 0, ROAD, True)      # its inner edge: road from here
    if left and right:
        # The far end: where the left verge starts higher than the right, the
        # road ends at the line between their first points, grass beyond, on
        # the lines above the right's first one. Lines compared as the Z80's
        # bytes, so one under the view (negative) never counts as higher.
        ll, rl = left[0][2] & 0xFF, right[0][2] & 0xFF
        if ll < 128 and ll > rl:
            stepped(left[0][0], ll, right[0][0] - left[0][0], ll - rl, -1, ll - rl, GRASS)
    edge(right, 0, None, False)    # right verge's inner edge
    edge(right, 1, GRASS, False)   # its outer edge: grass beyond
    return recs


def compose(layout: Layout, recs: list, parts: list[tuple]) -> bytes:
    """The view as it should be on the screen, top row first: the road, then
    the objects' parts on each line over it, in order."""
    out = bytearray(layout.view_lines * 32)
    for y, (marks, start, _) in enumerate(recs):
        px = [0] * 256
        cur, pos = start, 0
        for x, c in sorted(marks, key=lambda m: m[0]):
            for i in range(pos, x):
                px[i] = cur
            pos, cur = x, c
        for i in range(pos, 256):
            px[i] = cur
        row = (layout.view_lines - 1 - y) * 32
        for b in range(32):
            v = 0
            for k in range(8):
                v = (v << 1) | ((layout.patterns[px[b * 8 + k]][y & 1] >> (7 - k)) & 1)
            out[row + b] = v
        line = bytearray(out[row:row + 32])
        paint_parts(line, y, parts)
        out[row:row + 32] = line
    return bytes(out)


def screen_view(layout: Layout, memory: bytes) -> bytes:
    """The view as it is on the screen, top row first."""
    out = bytearray()
    for r in range(layout.view_lines):
        a = row_address(layout.view_top + r)
        out += memory[a:a + 32]
    return bytes(out)
