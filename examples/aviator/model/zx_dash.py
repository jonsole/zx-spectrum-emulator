"""The dashboard drawn for the Spectrum's own resolution, for model/zx.py.

The BBC's dashboard picture is 160 x 96 Mode 5 pixels, each twice as wide
as it is tall. Scaled whole to the Spectrum's 256 x 72 -- every Spectrum
pixel a lit BBC pixel covers being lit -- each of its one-pixel lines comes
out two or three pixels thick, and its 3 x 5 numerals turn into blobs. So
the Spectrum draws its own picture in the same layout:

- the lines (the dials' bezels, the boxes, the ticks) go through the mapped
  centres of the BBC's pixels, sx(x) = (8x + 4) // 5 and sy(row) = (3 row +
  1) // 4, as the hands do, each pixel joined to its neighbours: a line one
  Spectrum pixel thick, in the BBC's shape;
- the numerals and letters are a font of the Spectrum's own (GLYPHS), each
  centred where the BBC's was;
- the things the game draws itself -- the hands, the horizon, the joystick
  cross, the bars -- are left out of the picture and drawn as the game
  draws them (dashboard.Line through model/zx.py), so that its first erase
  of each rubs out exactly what is there;
- the marks the game rewrites whole bytes of (the horizon's aircraft, the
  joystick display's axes, the radar's cross, the slip indicator's centre,
  the upside-down bar) are drawn the same way as the lines, from the BBC
  pixels each lights (mark_plots).

The BBC picture is Acornsoft's, read at run time (acornsoft.py); what is
here is the method, and the font.
"""

from . import dashboard
from . import names as _n
from .memory import M
from .names import (indicatorLineI, indicatorLineJ, indicatorLineT, indicatorLineU,
                    indicatorLineV, xJoyCoord, yJoyCoord)

# A 3 x 5 font (W, M and N five wide), rows top to bottom.
GLYPHS = {
    "0": ("###", "#.#", "#.#", "#.#", "###"),
    "1": (".#", "##", ".#", ".#", ".#"),
    "2": ("##.", "..#", ".#.", "#..", "###"),
    "3": ("##.", "..#", ".#.", "..#", "##."),
    "4": ("#.#", "#.#", "###", "..#", "..#"),
    "5": ("###", "#..", "##.", "..#", "##."),
    "6": (".##", "#..", "###", "#.#", "###"),
    "7": ("###", "..#", ".#.", ".#.", ".#."),
    "8": ("###", "#.#", "###", "#.#", "###"),
    "9": ("###", "#.#", "###", "..#", "##."),
    "A": (".#.", "#.#", "###", "#.#", "#.#"),
    "B": ("##.", "#.#", "##.", "#.#", "##."),
    "E": ("###", "#..", "##.", "#..", "###"),
    "F": ("###", "#..", "##.", "#..", "#.."),
    "I": ("###", ".#.", ".#.", ".#.", "###"),
    "L": ("#..", "#..", "#..", "#..", "###"),
    "N": ("#...#", "##..#", "#.#.#", "#..##", "#...#"),
    "R": ("##.", "#.#", "##.", "#.#", "#.#"),
    "S": (".##", "#..", ".#.", "..#", "##."),
    "T": ("###", ".#.", ".#.", ".#.", ".#."),
    "U": ("#.#", "#.#", "#.#", "#.#", "###"),
    "V": ("#.#", "#.#", "#.#", "#.#", ".#."),
    "W": ("#...#", "#...#", "#.#.#", "##.##", "#...#"),
}

# The BBC's glyphs, as their pixel rows, and what they are.
BBC_GLYPHS = {
    ("###", "#.#", "#.#", "#.#", "###"): "0",
    ("#", "#", "#", "#", "#"): "1",
    ("##", ".#", "##", "#.", "##"): "2",
    ("##", ".#", "##", ".#", "##"): "3",
    ("#..", "#..", "###", ".#.", ".#."): "4",
    ("##", "#.", "##", ".#", "##"): "5",
    ("#..", "#..", "###", "#.#", "###"): "6",
    ("##", ".#", ".#", ".#", ".#"): "7",
    ("###", "#.#", "###", "#.#", "###"): "8",
    ("###", "#.#", "###", "..#", "..#"): "9",
    ("###", "#.#", "###", "#.#", "#.#"): "A",
    ("#.#", "#.#", "#.#", "#.#", ".#."): "V",
    ("#...#", "##..#", "#.#.#", "#..##", "#...#"): "N",
    ("#...#", "#.#.#", "#.#.#", "#.#.#", ".###."): "W",
    ("#####", "#....", "###..", "#....", "#####"): "E",
    ("#####", "#....", "#####", "....#", "#####"): "S",
    ("#..", "#..", "#..", "#..", "#..", "#..", "###"): "L",
    ("##.", "#.#", "#.#", "###", "##.", "#.#", "#.#"): "R",
    ("###", ".#.", ".#.", ".#.", ".#.", ".#.", ".#."): "T",
    ("#.#", "#.#", "#.#", "#.#", "#.#", "#.#", "###"): "U",
    ("###", "#..", "#..", "##.", "#..", "#..", "#.."): "F",
    ("##.", "#.#", "#.#", "##.", "#.#", "#.#", "##."): "B",
}

DASHBOARD_TOP = 160          # the BBC row the dashboard starts at

# The glyphs the BBC's font draws alike: S like 5 and I like 1, in the
# labels ASI and VSI (by the BBC glyph's top left corner).
LABELS = {(21, 193): "S", (24, 193): "I", (115, 181): "S", (118, 181): "I"}
LAMP_X = (1, 129, 139, 149)  # the T, U, F and B lamps, BBC x 3 wide
LAMP_ROWS = range(241, 246)


def sx(x):
    return (8 * x + 4) // 5


def sy(row):
    return (3 * row + 1) // 4


def _bresenham(x0, y0, x1, y1):
    from .zx import bresenham
    return bresenham(x0, y0, x1, y1)


def thin(pixels):
    """BBC pixels as a line one Spectrum pixel thick: each pixel at its
    mapped centre, joined to its lit neighbours (diagonal ones only where no
    side neighbour joins them already)."""
    out = set()
    lit = set(pixels)
    for x, row in lit:
        p = (sx(x), sy(row))
        out.add(p)
        for dx, dy in ((1, 0), (0, 1), (1, 1), (1, -1)):
            q = (x + dx, row + dy)
            if q not in lit:
                continue
            if dx and dy and ((x + dx, row) in lit or (x, row + dy) in lit):
                continue
            out.update(_bresenham(*p, sx(q[0]), sy(q[1])))
    return out


def _components(lit):
    seen = set()
    out = []
    for p in sorted(lit):
        if p in seen:
            continue
        stack, comp = [p], []
        seen.add(p)
        while stack:
            x, y = stack.pop()
            comp.append((x, y))
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    q = (x + dx, y + dy)
                    if q in lit and q not in seen:
                        seen.add(q)
                        stack.append(q)
        out.append(comp)
    return out


def _shape(comp):
    xs = [p[0] for p in comp]
    ys = [p[1] for p in comp]
    x0, y0 = min(xs), min(ys)
    s = set(comp)
    return x0, y0, tuple("".join("#" if (x, y) in s else "." for x in range(x0, max(xs) + 1))
                         for y in range(y0, max(ys) + 1))


def glyph_plots(ch, cx, cy):
    """A font glyph centred on Spectrum point (cx, cy)."""
    rows = GLYPHS[ch]
    w, h = len(rows[0]), len(rows)
    x0, y0 = round(cx - w / 2), round(cy - h / 2)
    return {(x0 + c, y0 + r) for r, row in enumerate(rows) for c, v in enumerate(row) if v == "#"}


SETTLE = 12                  # main-loop passes for every indicator to be drawn once


def drawn_by_the_game():
    """The BBC pixels of what the game draws itself at rest: every hand,
    the horizon, the joystick cross, the bars and the fuel gauge, as they are
    once the game has started and each has been drawn once. The BBC's
    picture has the hands drawn in at those places; they are left out of
    the Spectrum's, which the game draws them on. Runs the port from its
    starting memory, and puts the memory back."""
    from . import game
    saved = bytes(M)
    hook = dashboard.hook
    shown = {}
    order = []

    def record(event):
        if isinstance(event, dashboard.Line) and event.what:
            key = (event.what, event.x if event.what in ("fuel",) else None)
            if event.erase:
                shown.pop((event.what, tuple(event.pixels())), None)
            else:
                shown[(event.what, tuple(event.pixels()))] = True
            order.append(key)

    from . import hardware
    clock = hardware.clock
    ticks = [0]

    def tick():
        ticks[0] += 3
        return ticks[0]

    dashboard.hook = record
    hardware.clock = tick
    try:
        game.load_image()
        g = game.Game()
        for _ in range(SETTLE):
            g.iterate()
    finally:
        dashboard.hook = hook
        hardware.clock = clock
        M[:] = saved
    return {p for (_, pixels) in shown for p in pixels}


def mark_pixels(marks):
    """The BBC pixels a run of dashboard Patterns lights, (row, block, line,
    byte) each."""
    out = set()
    for row, char, line, byte in marks:
        x0, y0 = dashboard.block(row, char, line)
        for n, colour in enumerate(dashboard.Pattern("", x0, y0, byte).colours()):
            if colour:
                out.add((x0 + n, y0))
    return out


MARKS = {"horizon centre": dashboard.HORIZON_CENTRE, "joystick axes": dashboard.JOYSTICK_AXES,
         "radar cross": dashboard.RADAR_CROSS, "slip centre": (dashboard.SLIP_CENTRE,)}


def mark_plots(what, byte=None):
    """The Spectrum pixels a mark sets: one of MARKS, or the upside-down bar
    (lit by its pattern byte, cleared by 0), as (x, y, on)."""
    if what == "upside-down bar":
        shown = mark_pixels((dashboard.UPSIDE_DOWN_BLOCK + (dashboard.UPSIDE_DOWN_PATTERN,),))
        return [(x, y, bool(byte)) for x, y in sorted(thin(shown))]
    return [(x, y, True) for x, y in sorted(thin(mark_pixels(MARKS[what])))]


def _spectrum_line(line):
    from .zx import bresenham
    (x0, y0), (x1, y1) = (line.x, line.y), line.end
    return set(bresenham(sx(x0), sy(y0), sx(x1), sy(y1)))


def dynamic_zone():
    """Every Spectrum pixel the game can draw or rub out on the dashboard:
    each dial's hand at every value, the rudder and thrust bars and the
    joystick cross at every position, the fuel gauge, the radar's blips;
    the horizon stays inside its window, where the picture has nothing but
    its centre mark. The picture keeps out of it (picture), since a hand or a
    bar rubbing a pixel out would leave a hole; on the BBC the 4 rows to 3
    of the Spectrum's don't make two things one row."""
    from .maths import scale_signed
    zone = set()
    for x in range(7):
        for a in range(256):
            v = (a + M[_n.indicatorBase + x]) & 0xFF
            if v < M[_n.indicatorMin + x]:
                v = M[_n.indicatorMin + x]
            elif v >= M[_n.indicatorMax + x]:
                v = M[_n.indicatorMax + x]
            w, g, r = dashboard.get_hand_vector(v, x)
            zone |= _spectrum_line(dashboard.Line("", False, M[indicatorLineI + x],
                                                  M[indicatorLineJ + x], w, g, r))
    # The stick and rudder positions reach -118 to +118 (the keys stop at
    # -116 and +118, the BBC's joystick at -118 and +116).
    positions = [p & 0xFF for p in range(-118, 119)]
    across = {scale_signed(p, True) for p in positions}
    down = {(-scale_signed(p, False)) & 0xFF for p in positions}
    for h in across:
        zone |= _spectrum_line(dashboard.Line("", False, (h + dashboard.RUDDER_X) & 0xFF,
                                              dashboard.RUDDER_TOP_J, 1, dashboard.RUDDER_HEIGHT, 0))
        for v in down:
            zone |= _spectrum_line(dashboard.Line("", False, (h + dashboard.JOYSTICK_X - 1) & 0xFF,
                                                  (v + dashboard.JOYSTICK_J) & 0xFF, 3, 1, 0))
            zone |= _spectrum_line(dashboard.Line("", False, (h + dashboard.JOYSTICK_X) & 0xFF,
                                                  (v + dashboard.JOYSTICK_J - 2) & 0xFF, 1, 5, 0))
    for h in range(31):
        zone |= _spectrum_line(dashboard.Line("", False, h + dashboard.THRUST_X,
                                              dashboard.THRUST_TOP_J, 1, dashboard.THRUST_HEIGHT, 0))
    for a in range(66):
        zone |= _spectrum_line(dashboard.Line("", False, dashboard.FUEL_X,
                                              (a + dashboard.FUEL_BOTTOM_J) & 0xFF, 1, 1, 0))
    for dx in range(-12, 13):
        for dz in range(-25, 26):
            i = (dx + dashboard.RADAR_X) & 0xFF
            j = (dz + dashboard.RADAR_J) & 0xFF
            zone |= _spectrum_line(dashboard.Line("", False, i, j, 1, 1, 0))
            for t, u in ((1, 4), (2, 4), (2, 1)):
                for v in (0x00, 0x40, 0x80, 0xC0):
                    zone |= _spectrum_line(dashboard.Line("", False, i, j, t, u, v))
    return zone


NUDGES = ((0, 0), (0, 1), (0, -1), (1, 0), (-1, 0), (1, 1), (-1, 1), (1, -1), (-1, -1))


def _keep_clear(pixels, zone, whole):
    """pixels moved clear of zone: as a whole (a glyph), by the first nudge
    that clears it; otherwise (a line) each row that touches it moved a row
    out, away from the rest."""
    if not pixels & zone:
        return pixels
    if whole:
        for dx, dy in NUDGES:
            moved = {(x + dx, y + dy) for x, y in pixels}
            if not moved & zone:
                return moved
        return pixels
    ys = [y for _, y in pixels]
    middle = (min(ys) + max(ys)) / 2
    out = set()
    for x, y in pixels:
        row_hits = any((px, y) in zone for px, py in pixels if py == y)
        if row_hits:
            step = -1 if y < middle else 1
            if (x, y + step) not in zone:
                out.add((x, y + step))
                continue
        out.add((x, y))
    return out


_pictures = {}


def picture(bbc_lit):
    """The Spectrum's dashboard picture, as a set of lit pixels, from the
    BBC's (bbc_lit, its lit pixels in BBC rows). Worked out once a run."""
    key = frozenset(bbc_lit)
    if key not in _pictures:
        _pictures[key] = _picture(bbc_lit)
    return set(_pictures[key])


def _picture(bbc_lit):
    # Both what the game draws and where it can draw come from the game as
    # its loader leaves it, whatever memory holds now.
    from . import game
    saved = bytes(M)
    try:
        game.load_image()
        zone = dynamic_zone()
    finally:
        M[:] = saved
    lit = set(bbc_lit) - drawn_by_the_game()
    # The lamps are model/zx.py's own squares.
    for x0 in LAMP_X:
        lit -= {(x, row) for x in range(x0, x0 + 3) for row in LAMP_ROWS}
    for marks in MARKS.values():
        lit -= mark_pixels(marks)
    out = set()
    for comp in _components(lit):
        x0, y0, shape = _shape(comp)
        ch = LABELS.get((x0, y0)) or BBC_GLYPHS.get(shape)
        if ch:
            cx = (sx(x0) + sx(x0 + len(shape[0]) - 1)) / 2 + 0.5
            cy = (sy(y0) + sy(y0 + len(shape) - 1)) / 2 + 0.5
            out |= _keep_clear(glyph_plots(ch, cx, cy), zone, True)
        else:
            out |= _keep_clear(thin(comp), zone, False)
    for marks in MARKS.values():
        out |= thin(mark_pixels(marks))
    return out
