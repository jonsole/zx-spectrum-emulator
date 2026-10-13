"""The Spectrum's screen for the Python port: what the Z80 version will show,
byte for byte.

The port's modules hand their drawing to hooks, in the BBC's Mode 5
coordinates (160 x 256, x from the left, rows from the top). This renderer
puts it on a Spectrum screen (256 x 192, its own bitmap layout), keeping the
picture's shape: x scales by 8/5 and rows by 3/4, so the BBC's 160-row
canopy becomes 120 rows (character rows 0 to 14) and its 96-row dashboard 72
(rows 15 to 23).

- Points the game draws between are mapped one by one, from the middle of
  their BBC pixel: sx(x) = (8x + 4) // 5 and sy(row) = (3 row + 1) // 4,
  and lines are drawn between them (draw_line) at the Spectrum's
  resolution, rather than scaling the BBC's pixels.
- The pictures that don't move -- the canopy's frame and rivets, and the
  dashboard -- are drawn in BBC pixels and then mapped whole, every
  Spectrum pixel that a lit BBC pixel covers being lit (scale_picture). The
  dashboard image is Acornsoft's, fetched by acornsoft.py, so it is only
  ever converted at run time and never stored here.

The canopy view is drawn into a buffer, not on the screen. The BBC hides its
redraw by swapping colours in the palette (see canopy.py); the Spectrum has
no palette, so each view is drawn into CANOPY_BUFFER -- 32 bytes a row, one
row for each screen row of the canopy -- and copied to the screen when the
BBC would swap. The frame's two sides and its diagonal top corners are
ORed into the buffer's first and last bytes first, the corners also clearing
whatever lies outside them, as the BBC's DrawCanopyCorners does.

The dashboard is drawn straight onto the screen, as on the BBC: a hand is
drawn by setting its pixels and rubbed out by clearing them.

What the BBC prints in the canopy -- the scores, TOO LATE! -- is put in the
canopy buffer each view while it shows, in the Spectrum ROM's character set
(roms/48.rom), at character positions scaled from the BBC's.
"""

from pathlib import Path

import acornsoft

from . import canopy, clip, dashboard, flight, scoring

WIDTH, HEIGHT = 256, 192
BBC_WIDTH, BBC_ROWS = 160, 256

CANOPY_TOP = 6               # sy(8): the first screen row of the canopy view
CANOPY_BOTTOM = 119          # sy(159)
CANOPY_ROWS = CANOPY_BOTTOM - CANOPY_TOP + 1
DASHBOARD_TOP = 120          # sy(160)
BBC_CANOPY_BOTTOM_ROW = 159  # the BBC row of canopy y = 0

ATTRIBUTE = 0x47             # bright white ink on black paper


def sx(x):
    return (8 * x + 4) // 5


def sy(row):
    return (3 * row + 1) // 4


def address(x, y):
    """The offset into the Spectrum's bitmap of the byte holding (x, y)."""
    return ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2) | (x >> 3)


def bresenham(x0, y0, x1, y1):
    """The pixels of a line from (x0, y0) to (x1, y1), both ends included,
    stepping along the longer axis and stepping the other when the error,
    which starts at half the longer length, runs out. This is the line the
    Z80 draws."""
    dx, dy = abs(x1 - x0), abs(y1 - y0)
    step_x = 1 if x1 >= x0 else -1
    step_y = 1 if y1 >= y0 else -1
    x, y = x0, y0
    out = []
    if dx >= dy:
        err = dx // 2
        for _ in range(dx + 1):
            out.append((x, y))
            err -= dy
            if err < 0:
                y += step_y
                err += dx
            x += step_x
    else:
        err = dy // 2
        for _ in range(dy + 1):
            out.append((x, y))
            err -= dx
            if err < 0:
                x += step_x
                err += dy
            y += step_y
    return out


def scale_picture(lit):
    """Map a BBC picture, a set of lit (x, row) pixels, to a set of Spectrum
    pixels: every Spectrum pixel a lit BBC pixel covers is lit, so thin
    lines don't disappear."""
    out = set()
    for x, row in lit:
        for px in range((8 * x) // 5, (8 * (x + 1) - 1) // 5 + 1):
            for py in range((3 * row) // 4, (3 * (row + 1) - 1) // 4 + 1):
                out.add((px, py))
    return out


# ---- where a canopy line ends ----------------------------------------------

def pass_end(x, y, w, g, t, u, v):
    """The last pixel of one run of the BBC's line drawer from (x, y)
    (clip._trace_pass), worked out rather than stepped.

    A shallow line (u < t) steps x every pixel and y whenever its slope
    error, which starts at e0 and gains u a pixel, reaches t; it stops on
    the pixel where y would pass row g, or at the canopy's side. So y has
    stepped floor((e0 + n u) / t) times by pixel n, the k-th step comes
    after pixel ceil((k t - e0) / u) - 1, and the run ends at whichever stop
    comes first. A steep line is the same with the axes swapped. e0 is 0, or
    one short of the major delta where the drawer steps at once (a clipped
    line's first half, and the horizon's halves; see _trace_pass).

    This is how the Z80 finds a line's ends: two divisions instead of a
    walk along up to 150 pixels."""
    step_x = -1 if v & clip.LEFTWARDS else 1
    step_y = -1 if v & clip.DOWNWARDS else 1
    early = v & (clip.HORIZON | clip.CLIPPED)
    if u < t:
        e0 = t - 1 if early and u >= 2 else 0
        n = clip.CANOPY_RIGHT - x if step_x > 0 else x - clip.CANOPY_LEFT
        rows = (g - y) * step_y
        if rows >= 0:
            n = min(n, -(-((rows + 1) * t - e0) // u) - 1)
        return x + n * step_x, y + ((e0 + n * u) // t) * step_y
    e0 = u - 1 if early and t >= 2 else 0
    n = clip.CANOPY_TOP - y if step_y > 0 else y - clip.CANOPY_BOTTOM
    columns = (w - x) * step_x
    if columns >= 0:
        n = min(n, -(-((columns + 1) * u - e0) // t) - 1)
    return x + ((e0 + n * t) // u) * step_x, y + n * step_y


def line_ends(r, s, w, g, t, u, v):
    """clip.canopy_line_ends, by pass_end: the far end of a clipped line's
    second half (or the start), and the far end of its first."""
    first = pass_end(r, s, w, g, t, u, v)
    if v & clip.CLIPPED:
        v2 = (v ^ clip.REVERSE) & ~clip.CLIPPED & 0xFF
        w2, g2 = clip.edges(v2)
        return pass_end(r, s, w2, g2, t, u, v2), first
    return (r, s), first


# ---- the static pictures --------------------------------------------------

def _bbc_frame():
    """The canopy's frame and rivets as DrawCanopy draws them with VDU calls
    (in BBC rows, the VDU's y turned upside down)."""
    lit = set()
    for x in (3, 156):
        for y in range(96, 240):
            lit.add((x, 255 - y))
    for x in range(8, 152):
        lit.add((x, 255 - 248))
    rivets = [(0, y) for y in (121, 169, 217)] + [(158, y) for y in (121, 169, 217)]
    rivets += [(x, 255) for x in range(19, 163, 24)]
    for x, y in rivets:
        for dx in (0, 1):
            for dy in range(4):
                lit.add((x + dx, 255 - (y - dy)))
    return lit


def _bbc_corners():
    """DrawCanopyCorners' two diagonals, as (lit, cleared) BBC pixels: each
    is a step of one pixel across per two rows, in the corner blocks at
    x 4-7 and 152-155 of character row 1 (rows 8 to 15), with everything
    outside it cleared. (The source calls the right-hand block's address
    row1_char39_0, but &5A70 is character 38.)"""
    lit, cleared = set(), set()
    for k in range(4):
        for row in (15 - 2 * k, 14 - 2 * k):
            lit.add((4 + k, row))
            cleared.update((4 + j, row) for j in range(k))
            lit.add((155 - k, row))
            cleared.update((155 - j, row) for j in range(k))
    return lit, cleared - lit


def _bbc_dashboard():
    """The dashboard image's lit pixels, in BBC rows 160 to 255."""
    data = acornsoft.read("DASHBD.bin")
    lit = set()
    for r in range(len(data) // 320):
        for c in range(40):
            for line in range(8):
                b = data[r * 320 + c * 8 + line]
                for n in range(4):
                    if (((b >> (7 - n)) & 1) << 1) | ((b >> (3 - n)) & 1):
                        lit.add((c * 4 + n, 160 + r * 8 + line))
    return lit


def _font():
    rom = Path(__file__).resolve().parents[3] / "roms" / "48.rom"
    return rom.read_bytes()[0x3D00:0x4000] if rom.exists() else bytes(768)


class Screen:
    """A Spectrum screen, and the renderer that draws the port's hooks on it."""

    def __init__(self):
        self.bitmap = bytearray(6144)
        self.attrs = bytearray([ATTRIBUTE]) * 768
        self.buffer = bytearray(32 * CANOPY_ROWS)
        self.font = _font()
        self.score_text = None
        self.too_late = False
        frame = scale_picture(_bbc_frame()) | scale_picture(_bbc_dashboard())
        corner_lit, corner_cleared = _bbc_corners()
        corner_lit = scale_picture(corner_lit)
        corner_cleared = scale_picture(corner_cleared) - corner_lit
        # The parts of the frame inside the canopy's rows are ORed into the
        # buffer each view; the rest is drawn once, on the screen.
        self.overlay_or = bytearray(32 * CANOPY_ROWS)
        self.overlay_keep = bytearray(b"\xff") * (32 * CANOPY_ROWS)
        for x, y in frame | corner_lit:
            if CANOPY_TOP <= y <= CANOPY_BOTTOM:
                self.overlay_or[(y - CANOPY_TOP) * 32 + (x >> 3)] |= 0x80 >> (x & 7)
            else:
                self.plot(x, y)
        for x, y in corner_cleared:
            if CANOPY_TOP <= y <= CANOPY_BOTTOM:
                self.overlay_keep[(y - CANOPY_TOP) * 32 + (x >> 3)] &= ~(0x80 >> (x & 7)) & 0xFF
        self.present()

    # ---- pixels ----------------------------------------------------------

    def plot(self, x, y, on=True):
        if 0 <= x < WIDTH and 0 <= y < HEIGHT:
            a = address(x, y)
            bit = 0x80 >> (x & 7)
            if on:
                self.bitmap[a] |= bit
            else:
                self.bitmap[a] &= ~bit & 0xFF

    def lit(self, x, y):
        return bool(self.bitmap[address(x, y)] & (0x80 >> (x & 7)))

    def plot_buffer(self, x, y):
        if 0 <= x < WIDTH and CANOPY_TOP <= y <= CANOPY_BOTTOM:
            self.buffer[(y - CANOPY_TOP) * 32 + (x >> 3)] |= 0x80 >> (x & 7)

    # ---- the canopy ------------------------------------------------------

    def canopy_line(self, line):
        """clip.draw_hook: a line of the view, in the BBC's canopy
        coordinates (y up from the bottom)."""
        for x, y in bresenham(sx(line.x0), sy(BBC_CANOPY_BOTTOM_ROW - line.y0),
                              sx(line.x1), sy(BBC_CANOPY_BOTTOM_ROW - line.y1)):
            self.plot_buffer(x, y)

    def canopy_event(self, event, *args):
        if event == "show":
            self.present()
        elif event == "sights":
            self._sights()
        elif event == "fill":
            colour, row, rows = args
            self._fill(colour, row, rows)
        # "erase", "corners" and "palette" need nothing: each view is drawn
        # afresh, and the corners are in the overlay.

    def _sights(self):
        """The gun sights: a vertical bar at x 80 from rows 48 to 63 and a
        horizontal one along row 64 from x 45 to 115, as the BBC draws them
        (in its character rows 6 to 8), mapped."""
        for x, y in bresenham(sx(80), sy(48), sx(80), sy(63)):
            self.plot_buffer(x, y)
        for x, y in bresenham(sx(45), sy(64), sx(115), sy(64)):
            self.plot_buffer(x, y)

    def _fill(self, colour, row, rows):
        """FillCanopyRows: BBC character rows row to row + rows - 1, inside
        the frame, set (any non-zero colour) or cleared, on the screen."""
        top, bottom = max(CANOPY_TOP, sy(row * 8)), min(CANOPY_BOTTOM, sy((row + rows) * 8) - 1)
        for y in range(top, bottom + 1):
            for x in range(sx(4), sx(156)):
                self.plot(x, y, bool(colour))

    def _text(self, col, row, text, plot):
        """Text at a BBC Mode 5 character position (20 columns of 8 pixels),
        in the Spectrum's font, by plot (into the buffer or the screen)."""
        x0, y0 = sx(col * 8), sy(row * 8)
        for i, ch in enumerate(text):
            glyph = self.font[(ord(ch) - 32) * 8:(ord(ch) - 31) * 8]
            for r, bits in enumerate(glyph):
                for c in range(8):
                    if bits & (0x80 >> c):
                        plot(x0 + i * 8 + c, y0 + r)

    def _messages(self, plot):
        """The scores and TOO LATE!, where the BBC prints them, while they
        show."""
        if self.score_text:
            high, score = self.score_text
            self._text(1, 3, f"HIGH SCORE:  {high:04X}0", plot)
            self._text(3, 10, f"SCORE:  {score:04X}0", plot)
        if self.too_late:
            self._text(6, 7, "TOO LATE!", plot)

    def present(self):
        """Copy the canopy buffer, with the frame laid over it, to the screen,
        and clear the buffer for the next view. Messages are drawn into each
        view while they show."""
        self._messages(self.plot_buffer)
        for row in range(CANOPY_ROWS):
            base = row * 32
            y = CANOPY_TOP + row
            for b in range(32):
                value = (self.buffer[base + b] & self.overlay_keep[base + b]) | self.overlay_or[base + b]
                self.bitmap[address(b * 8, y)] = value
        self.buffer[:] = bytes(len(self.buffer))

    # ---- the dashboard ---------------------------------------------------

    def dashboard_event(self, event):
        if isinstance(event, dashboard.Line):
            (x0, y0), (x1, y1) = (event.x, event.y), event.end
            for x, y in bresenham(sx(x0), sy(y0), sx(x1), sy(y1)):
                self.plot(x, y, not event.erase)
        else:
            for n, colour in enumerate(event.colours()):
                for x in range((8 * (event.x + n)) // 5, (8 * (event.x + n + 1) - 1) // 5 + 1):
                    for y in range((3 * event.y) // 4, (3 * (event.y + 1) - 1) // 4 + 1):
                        self.plot(x, y, colour != 0)

    def indicator(self, letter, lit):
        """The U, F, B and T lamps: the squares above the letters at the
        bottom of the dashboard, filled when lit."""
        x, row = {"T": (1, 242), "U": (129, 242), "F": (141, 242), "B": (149, 242)}[letter]
        for px in range(sx(x), sx(x + 3)):
            for py in range(sy(row), sy(row + 4)):
                edge = px in (sx(x), sx(x + 3) - 1) or py in (sy(row), sy(row + 4) - 1)
                self.plot(px, py, lit or edge)

    def scores(self, event, *args):
        """scoring.display_hook. The BBC prints straight onto its screen, so
        a message appears at once -- which matters when the game is over and
        no more views are drawn -- and then goes into every view while it
        is up."""
        if event == "show":
            self.score_text = args
        elif event == "remove":
            self.score_text = None
        elif event == "too late":
            self.too_late = True
        self._messages(self.plot)

    # ---- wiring ----------------------------------------------------------

    def install(self):
        clip.draw_hook = self.canopy_line
        canopy.hook = self.canopy_event
        dashboard.hook = self.dashboard_event
        flight.draw_indicator = self.indicator
        scoring.display_hook = self.scores

    # ---- output ----------------------------------------------------------

    def scr(self):
        """The screen as a 6,912-byte .scr file."""
        return bytes(self.bitmap) + bytes(self.attrs)

    def image(self, scale=2):
        from PIL import Image
        img = Image.new("1", (WIDTH, HEIGHT))
        px = img.load()
        for y in range(HEIGHT):
            for x in range(WIDTH):
                px[x, y] = 1 if self.lit(x, y) else 0
        img = img.convert("RGB")
        if scale != 1:
            img = img.resize((WIDTH * scale, HEIGHT * scale), Image.NEAREST)
        return img
