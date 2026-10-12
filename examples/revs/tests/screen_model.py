"""A model of edges.s and compose.s: from the Z80's own verge point lists to
the bytes on the screen.

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
        base = symbols["patterns"]
        self.patterns = [(memory[base + c], rotate2(memory[base + c])) for c in range(COLOURS)]


def verge_lists(layout: Layout, memory: bytes) -> dict[str, list]:
    """Per side, (inner x, outer x, line, colour) from far to near."""
    out = {}
    for side, base, count in (("R", layout.verge_r, layout.vr_count),
                              ("L", layout.verge_l, layout.vl_count)):
        pts = []
        for i in range(memory[count]):
            a = base + POINT_SIZE * i
            pts.append((signed16(memory[a] | memory[a + 1] << 8),
                        signed16(memory[a + 2] | memory[a + 3] << 8),
                        memory[a + 4], memory[a + 5]))
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

    def raster(ax, al, bx, bl, c, last):
        if al == bl:
            if last:
                mark(bx, bl, c)
            return
        n = abs(bl - al)
        ys = 1 if bl > al else -1
        dx = bx - ax
        q, r = divmod(abs(dx), n)
        xs = 1 if dx >= 0 else -1
        err = n // 2
        x, y = ax, al
        for k in range(n + 1 if last else n):
            mark(x, y, c)
            if k == n:
                break
            y += ys
            err += r
            step = q
            if err >= n:
                err -= n
                step += 1
            x += xs * step

    def edge(pts, field, colour, left):
        if not pts:
            return
        p = [(pt[field], pt[2], pt[3] if colour is None else colour) for pt in pts]
        low, low_colour = p[0][1], p[0][2]
        for k, ((ax, al, _), (bx, bl, c)) in enumerate(zip(p, p[1:])):
            if bl < low:
                low, low_colour = bl, c
            raster(ax, al, bx, bl, c, k == len(p) - 2)
        if left:
            # Below its lowest point a left edge has gone off the left of
            # the view, and still sets the colour those lines start with.
            for y in range(min(low, layout.view_lines)):
                mark(-32767, y, low_colour)

    left, right = lists["L"], lists["R"]
    edge(left, 1, None, True)      # left verge's outer edge: the verge's colour
    edge(left, 0, ROAD, True)      # its inner edge: road from here
    edge(right, 0, None, False)    # right verge's inner edge
    edge(right, 1, GRASS, False)   # its outer edge: grass beyond
    return recs


def compose(layout: Layout, recs: list) -> bytes:
    """The view as it should be on the screen, top row first."""
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
    return bytes(out)


def screen_view(layout: Layout, memory: bytes) -> bytes:
    """The view as it is on the screen, top row first."""
    out = bytearray()
    for r in range(layout.view_lines):
        a = row_address(layout.view_top + r)
        out += memory[a:a + 32]
    return bytes(out)
