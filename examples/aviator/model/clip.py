"""Clipping lines to the canopy view, and handing them on to be drawn.

DrawCanopyView passes DrawClippedLine each visible line as two point IDs,
whose points have already been projected into screen coordinates: 16-bit
signed numbers, which can be far off the screen, with x across the screen
in Mode 5 pixels and y up from the bottom of the canopy. The canopy is the
region lines are clipped to: x from 4 to 155 (the frame and its rivets take
the four pixels at each side of the 160) and y from 0 to 151 (19 character
rows, the bottom one just above the dashboard).

The drawer, DrawCanopyLine, does not draw between two points. It draws from
one on-screen point, in a direction and with a slope, until it reaches a
limit: for a line that is wholly on the screen the far end's row or column,
otherwise the edge of the canopy. So clipping here is a matter of finding an
on-screen point to draw from, in these steps:

1. The line's deltas are taken as magnitudes, and their signs kept as the
   line's direction: bit 7 of the direction byte V for x falling from start
   to end, bit 6 for y falling.

2. Each end is classified with a code like Cohen and Sutherland's: bit 4 if
   it is below the canopy (y < 0), bit 5 above (y > 151), bit 6 left of it
   (x < 4), bit 7 right of it (x > 155), all clear if it is on the screen.

3. An end behind the plane (its z negative) projects to the wrong side of
   the screen, so the line is drawn from the other end, pointing away from
   that projection, to the edge of the canopy, the end being clipped first
   if it is off the screen. With both ends in front: a line wholly on the
   screen is drawn from start to end; one with a single end off the screen
   is drawn from the other end towards it, to the edge; one with both off
   is clipped.

4. Clipping moves an off-screen end along the line until it meets one of the
   canopy's diagonals. With 4 added to y, the canopy is the square from 4 to
   155 on both axes, and any line through it crosses the diagonal running
   across its slope inside the square: x + y = 159 for a line rising to the
   right, y = x for one falling to the right. A line that misses the canopy
   meets that diagonal outside it, so the one test both finds the point to
   draw from and throws away lines that cannot be seen. The line is then
   drawn from that point both ways, to the edges. Before any of that, an end
   off one side of the canopy with the line heading away from that side is
   dropped.

5. The clipped point comes from the distance d of the end from the diagonal,
   measured along an axis (|x + y - 159| or |y - x|). Each pixel along x
   changes x + y (or y - x) by (dx + dy) / dx, so the end has to move
   d * dx / (dx + dy) pixels along x -- or, for a steep line, which moves
   the coordinate that changes fastest, d * dy / (dx + dy) along y. The
   original uses dx + 1 and dx + dy + 2 so as never to divide by zero,
   works the fraction out to 1/256 by shift-and-subtract long division, and
   rounds it to the nearest pixel. The other coordinate comes from the
   diagonal. If the point is not inside the canopy the line is dropped.

6. When both ends are off the screen, a line with both off the same side is
   dropped at once, and otherwise the end nearer the canopy is clipped, as
   the error in the computed point grows with the distance moved. Nearness
   is judged by the coordinates' high bytes: the start is clipped unless
   both of the end's are smaller than the larger of the start's.

7. The deltas are halved together until they fit in a byte (and once more
   if either is 255: one is then added to each, to keep them from being
   zero, and 256 would not fit), giving the slope, and the line is recorded
   in the line buffer for the current colour (see the "line buffers" deep
   dive) -- its start, slope, direction and limits -- before it is drawn.
   EraseCanopyLines draws the buffered lines again later to rub them out,
   so the buffers are state the game reads; this module writes them exactly
   as the original does.

The port does not draw on the BBC's screen. It works out where
DrawCanopyLine's line would end, by stepping its slope error as that does
(trace_canopy_line), and hands the line to draw_hook as a CanopyLine. The
stepping matters: a line run to an edge goes at the buffered slope
(dy + 1) / (dx + 1) from the point it is drawn from, not to the true far
end, and can finish some pixels from where the true line would. Everything
else DrawCanopyLine changes is the screen, the zero-page temporaries, or
SELF_MODIFIED, bytes of its own code that it rewrites for each line's
direction before drawing it.
"""

from typing import NamedTuple

from .memory import M, signed16
from .names import (colourCycle, colourLogic, dlin20, dlin21, dlin33, dlin35, dlin36, dlin37,
                    dlin38, dlin52, dlin53, dlin54, dlin55, dlin56, lineBuffer1Count,
                    lineBuffer2Count, lineBufferG, lineBufferR, lineBufferS, lineBufferT,
                    lineBufferU, lineBufferV, lineBufferW, maxCoord, xTemp1Lo, yTemp1Lo, zPointHi)
from .points import point

# The canopy, in the original's screen coordinates.
CANOPY_LEFT = 4
CANOPY_RIGHT = 155
CANOPY_BOTTOM = 0
CANOPY_TOP = 151

# Bits of an end's clipping code (TT for the start, UU for the end).
OFF_BOTTOM = 0x10
OFF_TOP = 0x20
OFF_LEFT = 0x40
OFF_RIGHT = 0x80

# Bits of the direction byte V.
LEFTWARDS = 0x80             # x falls along the line
DOWNWARDS = 0x40             # y falls along the line
REVERSE = LEFTWARDS | DOWNWARDS
HORIZON = 0x02               # drawn by DrawClippedHorizon
CLIPPED = 0x01               # drawn from a clipped point, both ways

# Clipping works on the square from 4 to 155 on both axes, so y is raised by
# 4 while it is worked out; the diagonal from top left to bottom right is
# then x + y = 159.
Y_RAISE = 4
ANTI_DIAGONAL = 159

# The line buffers: buffer 1 is slots 0-47 and its count is 255 when it is
# empty; buffer 2 is slots 48-95 and its count is 47 when it is empty. Each
# count is the last slot used.
BUFFER1_FULL = 47
BUFFER2_FULL = 95

# The bytes of DrawCanopyLine's code that it rewrites for each line before
# drawing it: branch targets for the x direction, the colour table's address
# for it, and INY/DEY and the row step for the y direction. Only the drawing
# code reads them, and each pass sets every one it then runs, so none of them
# carries anything from one line to the next. The port, which does not draw
# on the BBC's screen, leaves them alone, and its tests leave them out.
SELF_MODIFIED = (dlin20 + 1, dlin21 + 1, dlin33 + 1, dlin35, dlin36, dlin37 + 1, dlin38 + 1,
                 dlin52 + 1, dlin53, dlin54, dlin55 + 1, dlin56 + 1)


class CanopyLine(NamedTuple):
    """A line as DrawCanopyLine would draw it: from (x0, y0) to (x1, y1) in
    the original's screen coordinates (x 4-155 from the left of the screen,
    y 0-151 up from the bottom of the canopy, so Mode 5 pixel row 159 - y),
    both ends being pixels it lights. (x_from, y_from) is the point on it
    that it is drawn from: (x0, y0), unless the line was clipped, when it is
    the clipped point, drawn from both ways.

    slot is its entry in the line buffers (0-47 buffer 1, 48-95 buffer 2),
    which EraseCanopyLines will rub out when it next erases that buffer;
    colour is the logical colour it is drawn in, 1 or 2, set by colourLogic
    (0 would be erasing). horizon and clipped are bits 1 and 0 of its
    direction byte.

    A clipped horizon half is not quite straight on the BBC: both its halves
    start their slope error at 255 (see _trace_pass), so each steps sideways
    at once, and the line jogs by two pixels at the clipped point. A line
    drawn from end to end misses that; one drawn out from (x_from, y_from)
    to each end keeps it, near enough."""
    x0: int
    y0: int
    x1: int
    y1: int
    x_from: int
    y_from: int
    slot: int
    colour: int
    horizon: bool
    clipped: bool


def _no_drawing(line):
    pass


draw_hook = _no_drawing
"""Called with each CanopyLine that DrawClippedLine draws. The Spectrum's
renderer sets it; by default nothing is drawn."""


class Line:
    """A line while it is being clipped: what the original keeps in zero
    page. The start is (RR R), (SS S) with its code in TT, the end (QQ W),
    (H G) with UU; dx and dy are the magnitudes of the deltas, (I T) and
    (J U); v is the direction byte V. Coordinates are 16-bit, unsigned."""
    __slots__ = ("x0", "y0", "code0", "x1", "y1", "code1", "dx", "dy", "v")

    def __init__(self, x0, y0, code0, x1, y1, code1, dx, dy, v):
        self.x0, self.y0, self.code0 = x0, y0, code0
        self.x1, self.y1, self.code1 = x1, y1, code1
        self.dx, self.dy, self.v = dx, dy, v


def classify(x, y):
    """An end's clipping code: which sides of the canopy it is off, if any."""
    code = 0
    if signed16(y) < CANOPY_BOTTOM:
        code |= OFF_BOTTOM
    elif signed16(y) > CANOPY_TOP:
        code |= OFF_TOP
    if signed16(x) < CANOPY_LEFT:
        code |= OFF_LEFT
    elif signed16(x) > CANOPY_RIGHT:
        code |= OFF_RIGHT
    return code


def edges(v):
    """(W, G): the canopy's edge in each direction a line runs, as the limits
    for drawing it to the edge."""
    return (CANOPY_LEFT if v & LEFTWARDS else CANOPY_RIGHT,
            CANOPY_BOTTOM if v & DOWNWARDS else CANOPY_TOP)


def swap_line_points(line):
    """SwapLinePoints: make the end the start, coordinates and code, so that
    clipping, which only works on the start, can work on the end. The end is
    left as it is; the caller reverses the direction if the line is to keep
    pointing the same way along itself."""
    line.x0, line.y0, line.code0 = line.x1, line.y1, line.code1


def clip_start_of_line(line):
    """ClipStartOfLine: move the line's start along it to where it crosses
    the canopy's diagonal (steps 4 and 5 in the module's description).
    Returns False if the line cannot be on the screen (the original's
    AbortLine, which returns from DrawClippedLine too). Otherwise the start
    becomes the clipped point, the direction gets the CLIPPED bit, and the
    point is copied to xTemp1Lo and yTemp1Lo, where DrawCanopyLine finds it
    to draw the second half of the line from."""
    x, y = line.x0, (line.y0 + Y_RAISE) & 0xFFFF
    code, v, dx, dy = line.code0, line.v, line.dx, line.dy

    # A start off one side of the canopy with the line heading away from
    # that side cannot reach it.
    if code & (OFF_LEFT if v & LEFTWARDS else OFF_RIGHT):
        return False
    if code & (OFF_BOTTOM if v & DOWNWARDS else OFF_TOP):
        return False

    # The distance from the diagonal across the line's slope, along an axis:
    # a line whose x and y run opposite ways ("\") crosses y = x, one whose
    # run the same way ("/") crosses x + y = 159.
    falling = bool((v ^ (v << 1)) & 0x80)
    if falling:
        distance = (y - x) & 0xFFFF
    else:
        distance = (x + y - ANTI_DIAGONAL) & 0xFFFF
    if distance & 0x8000:
        distance = (-distance) & 0xFFFF
    span = (dx + dy + 2) & 0xFFFF

    # The point moves along the axis the line changes fastest on; for a
    # steep line that is y, which is worked on in x's place.
    steep = dx < dy
    if steep:
        run = (dy + 1) & 0xFFFF
        backwards = v & DOWNWARDS
        x = y
    else:
        run = (dx + 1) & 0xFFFF
        backwards = v & LEFTWARDS

    # The distance's sign is dropped: the point moves the way the line runs.
    # A start that got past the checks above is heading into the canopy, so
    # if the line crosses it at all, that is towards the diagonal.
    delta = _scale(distance, run, span)
    moved = (x - delta if backwards else x + delta) & 0xFFFF
    if falling:
        x = y = moved
    elif steep:
        x, y = (ANTI_DIAGONAL - moved) & 0xFFFF, moved
    else:
        x, y = moved, (ANTI_DIAGONAL - moved) & 0xFFFF

    # Only the low byte of y is checked: on the diagonal, an x inside the
    # canopy puts y inside it too.
    if x >> 8 or not CANOPY_LEFT <= x <= CANOPY_RIGHT:
        return False
    s = (y & 0xFF) - Y_RAISE
    if s < 0 or s > CANOPY_TOP:
        return False
    line.x0, line.y0 = x, s
    line.v = v | CLIPPED
    M[xTemp1Lo] = x
    M[yTemp1Lo] = s
    return True


def _scale(distance, run, span):
    """distance * run / span to the nearest whole number, as the original's
    long division (ClipStartOfLine part 4) works it out, to 1/256 and with
    its 16- and 24-bit registers' overflows.

    The divisor and the multiplier are doubled together until the divisor
    reaches the distance, then halved together a step at a time, and at each
    step the divisor is taken from the remainder, adding the multiplier to
    the total, as often as it goes. The total starts at a half, to round,
    and the division stops when the remainder is under 2/256."""
    divisor, multiplier = span, run
    while divisor < distance:
        # The distance is at most &8000, so the divisor reaches it before
        # its top bit can be shifted out.
        divisor = (divisor << 1) & 0xFFFF
        multiplier = (multiplier << 1) & 0xFFFF
    remainder = distance << 8
    divisor <<= 8
    multiplier <<= 8
    total = 0x80
    while True:
        divisor >>= 1
        multiplier >>= 1
        if divisor > remainder:
            continue
        while True:
            total = (total + multiplier) & 0xFFFFFF
            remainder -= divisor
            if remainder < 2:
                return ((total >> 8) + ((total >> 7) & 1)) & 0xFFFF
            if divisor > remainder:
                break


def clip_best_end_of_line(line):
    """ClipBestEndOfLine: for a line with both ends off the screen, drop it
    if both are off the same side, and otherwise clip the end nearer the
    canopy (step 6), swapping the ends and reversing the direction if that
    is the end. The nearness test's maximum is left in maxCoord. Returns
    what clip_start_of_line does."""
    if line.code0 & line.code1:
        return False

    def size(value):
        # The high byte, inverted if negative: its magnitude, near enough.
        high = value >> 8
        return high ^ 0xFF if high & 0x80 else high

    biggest = max(size(line.y0), size(line.x0))
    M[maxCoord] = biggest
    if size(line.x1) >= biggest or size(line.y1) >= biggest:
        return clip_start_of_line(line)
    swap_line_points(line)
    line.v ^= REVERSE
    return clip_start_of_line(line)


def draw_clipped_line(start, end, horizon=False):
    """DrawClippedLine (or DrawClippedHorizon, with horizon set): clip the
    line from point start to point end to the canopy, record it in the line
    buffer for the current colour, and hand it to draw_hook. Returns the
    CanopyLine drawn, or None if the line is not on the screen or the buffer
    is full."""
    v = HORIZON if horizon else 0
    x0, y0, _ = point(start)
    x1, y1, _ = point(end)
    dx = (x1 - x0) & 0xFFFF
    if dx & 0x8000:
        v |= LEFTWARDS
        dx = (-dx) & 0xFFFF
    dy = (y1 - y0) & 0xFFFF
    if dy & 0x8000:
        v |= DOWNWARDS
        dy = (-dy) & 0xFFFF
    line = Line(x0, y0, classify(x0, y0), x1, y1, classify(x1, y1), dx, dy, v)

    # Decide which point to draw from, and how far to draw (part 4).
    to_edge = True
    if M[zPointHi + end] & 0x80:
        # The end is behind: draw from the start, away from its projection.
        line.v ^= REVERSE
        if line.code0 and not clip_start_of_line(line):
            return None
    elif M[zPointHi + start] & 0x80:
        # The start is behind: draw from the end, onwards.
        swap_line_points(line)
        if line.code0 and not clip_start_of_line(line):
            return None
    elif line.code0 and line.code1:
        if not clip_best_end_of_line(line):
            return None
    elif line.code0:
        # Draw from the end, which is on the screen, back towards the start.
        line.v ^= REVERSE
        line.x0, line.y0 = line.x1, line.y1
    elif not line.code1:
        to_edge = False

    # The line's limits and slope (part 5). A line wholly on the screen runs
    # to its end, and its deltas already fit in a byte.
    r, s = line.x0 & 0xFF, line.y0 & 0xFF
    if to_edge:
        w, g = edges(line.v)
        while dx >> 8 or dy >> 8:
            dx >>= 1
            dy >>= 1
        if dx == 0xFF:
            dx >>= 1
            dy >>= 1
        if dy == 0xFF:
            dx >>= 1
            dy >>= 1
    else:
        w, g = x1 & 0xFF, y1 & 0xFF
        dx &= 0xFF
        dy &= 0xFF
    t, u = (dx + 1) & 0xFF, (dy + 1) & 0xFF

    # Record it in the line buffer for this colour, if there is room (part 6).
    if M[colourCycle] & 0x80:
        count, full = lineBuffer1Count, BUFFER1_FULL
    else:
        count, full = lineBuffer2Count, BUFFER2_FULL
    if M[count] == full:
        return None
    slot = (M[count] + 1) & 0xFF
    M[count] = slot
    v = line.v
    for table, value in ((lineBufferR, r), (lineBufferW, w), (lineBufferS, s), (lineBufferG, g),
                         (lineBufferT, t), (lineBufferU, u), (lineBufferV, v)):
        M[table + slot] = value

    (x_a, y_a), (x_b, y_b) = canopy_line_ends(r, s, w, g, t, u, v)
    logic = M[colourLogic]
    drawn = CanopyLine(x_a, y_a, x_b, y_b, r, s, slot,
                       1 if logic & 0x80 else 2 if logic & 0x40 else 0,
                       bool(v & HORIZON), bool(v & CLIPPED))
    draw_hook(drawn)
    return drawn


def canopy_line_ends(r, s, w, g, t, u, v):
    """The two ends of the line DrawCanopyLine draws for a line buffer entry
    -- start (r, s), limits (w, g), slope t:u, direction v -- as ((x, y),
    (x, y)): the start, or for a clipped line the far end of its second
    half, and the far end of its first half."""
    passes = trace_canopy_line(r, s, w, g, t, u, v)
    return passes[-1][-1] if len(passes) > 1 else passes[0][0], passes[0][-1]


def trace_canopy_line(r, s, w, g, t, u, v):
    """The pixels DrawCanopyLine lights for a line buffer entry, as a list of
    passes, each a list of (x, y) in the order it reaches them: one pass, or
    for a clipped line two from the same point, the second in the opposite
    direction to the edge.

    The second pass starts from xTemp1Lo and yTemp1Lo, which hold the start
    whenever DrawCanopyLine is called (ClipStartOfLine and EraseCanopyLines
    both put it there), so it is taken from r and s here. It runs without the
    CLIPPED bit, which changes how its slope error starts."""
    passes = [_trace_pass(r, s, w, g, t, u, v)]
    if v & CLIPPED:
        v = (v ^ REVERSE) & ~CLIPPED & 0xFF
        w, g = edges(v)
        passes.append(_trace_pass(r, s, w, g, t, u, v))
    return passes


def _trace_pass(x, y, w, g, t, u, v):
    """One run of DrawCanopyLine's stepping, from (x, y).

    A shallow line (u < t) lights a pixel at every x and steps y when its
    slope error overflows; it stops on stepping past row g, or on reaching
    the canopy's side. A steep one is the same with the axes swapped, except
    that it stops on stepping past column w, or on reaching the canopy's top
    or bottom. The error starts at 256 minus the major delta, so the last
    step lands on the far end of a line wholly on the screen.

    It starts at 255 instead, stepping at once, where a line is drawn on from
    a point another run has reached: the first half of a clipped line, whose
    second half (without CLIPPED) runs up to the clipped point as a single
    line would, and the half of the horizon that DrawClippedHorizon draws on
    from the end of the other. A clipped horizon half keeps HORIZON in its
    second pass, so both of its halves step at once."""
    step_x = -1 if v & LEFTWARDS else 1
    step_y = -1 if v & DOWNWARDS else 1
    early = v & (HORIZON | CLIPPED)
    pixels = []
    if u < t:
        error = 255 if early and u >= 2 else 256 - t
        while True:
            pixels.append((x, y))
            error += u
            if error > 255:
                error -= t
                y += step_y
                if y == g + step_y:
                    return pixels
            x += step_x
            if not CANOPY_LEFT <= x <= CANOPY_RIGHT:
                return pixels
    error = 255 if early and t >= 2 else 256 - u
    while True:
        pixels.append((x, y))
        error += t
        if error > 255:
            error -= u
            x += step_x
            if x == w + step_x:
                return pixels
        y += step_y
        if not CANOPY_BOTTOM <= y <= CANOPY_TOP:
            return pixels
