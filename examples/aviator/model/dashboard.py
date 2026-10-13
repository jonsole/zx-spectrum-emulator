"""The dashboard: the dials, the joystick display, the rudder and thrust bars,
the radar and the fuel gauge.

Each routine is split in two. The game's arithmetic -- the value each
indicator shows, the hand vectors, the radar positions, and the line buffers
that remember what is on screen so it can be rubbed out -- is ported
exactly, on M, at the original's addresses. The drawing goes to `hook`, a
module-level callable that does nothing unless something is put there. The
BBC draws the dashboard into its Mode 5 screen; the Spectrum will draw its
own picture of the same layout, scaled, so the hook is told what the BBC
would draw, in the BBC's coordinates, and each renderer turns that into its
own pixels.

The hook
--------

hook(event) receives one of two kinds of event, in the order the original
draws:

- Line: one call of DrawVectorLine, which plots every hand, the horizon,
  the bars, the joystick cross, the radar blips and the fuel pixels. It
  carries `what` (which part of the dashboard: one of INDICATOR_NAMES,
  RADAR_RUNWAY, RADAR_ALIEN or FUEL), `erase`, the first pixel `x, y`, and the original's vector: `t` and `u`
  (the x and y lengths) and `v` (bit 7 set: leftwards, bit 6 set: downwards
  on the screen). `count` is how many pixels it plots, `end` the last one,
  and pixels() every one of them, worked out the way the original steps
  along a line, so a renderer can reproduce the BBC's picture exactly or
  just scale the two ends.
- Pattern: one screen byte written whole, four pixels side by side: the
  fixed marks that the original rewrites after a line may have rubbed part
  of them out (the horizon's centre marker, the joystick display's axes, the
  radar's cross, the slip-and-turn indicator's centre), and the upside-down
  bar. It carries `what` ("horizon centre", "joystick axes", "radar
  cross", "slip centre" or "upside-down bar"), `x, y` (its left pixel) and
  `byte` (the Mode 5 byte); colours() gives the four logical colours, left to right. Writing it
  replaces whatever those four pixels held.

Coordinates are the BBC's Mode 5 screen: x from 0 to 159 from the left, y
from 0 to 255 from the top of the screen. The dashboard is rows 160 to 255;
the canopy is above it. Mode 5 pixels are twice as wide as they are tall,
which is why every x-distance below is about half the y-distance it goes
with.

Drawing sets a pixel to logical colour 3, white, whatever it was (the
original ORs both of the pixel's bits in); erasing sets it to colour 0,
black (the original ANDs with the inverted pixel mask). The source's
annotation calls the erase "EOR logic", but it is not an exclusive or: a
pixel that was already black stays black, and a mark under a hand is rubbed
out along with it, which is why the fixed marks are rewritten afterwards.
The upside-down bar is the only thing drawn in another colour, logical
colour 1: one of the two colours the canopy's colour cycling swaps between
white and black every frame, so on the BBC the bar is lit only on
alternate frames.

The game reads two of these screen bytes back as state, so the port keeps
them in M at their screen addresses, written as the original writes them:

- UPSIDE_DOWN_BAR (&77A9, row25_char13_1) is written by
  show_upside_down_bar, and read by CheckFlyingSkills to tell whether the
  plane is flying upside down under the bridge or along the main street. No
  line on the dashboard reaches it (the horizon stays within y 177 to 199),
  so it only ever holds 0 or %00001110.
- JOYSTICK_ENABLED (&7CE4, row29_char20_4) is toggled by ToggleJoystick and
  read by ReadJoystick, neither of them here; nothing in this module writes
  it or draws over it.

The Spectrum version will need a variable for each.

The indicators
--------------

UpdateIndicator takes an indicator number. Numbers 0 to 6 are dials with a
hand, drawn from a fixed centre; 7 is the artificial horizon; 8 and 10 are
both the joystick display (so it is updated twice as often); 9 is the rudder
and 11 the thrust. UpdateDashboard updates one of 0 to 6 and one of 7 to 10
each time it is called, and UpdateFlightModel, once a pass of the main loop,
calls it and then UpdateDash7To11 for one more of 7 to 10: so each dial is
redrawn every seventh iteration, the horizon and the rudder every other one
and the joystick display every iteration. Despite its name UpdateDash7To11 never reaches 11
(it wraps from 10 to 7): the thrust indicator is redrawn by the flight model
whenever the thrust changes.

A dial's value is the game value scaled to "hand units" (by an unrolled
shift-and-add multiplication, whose truncations are kept), plus the dial's
base from indicatorBase, clipped to indicatorMin and indicatorMax (as
unsigned bytes, so a value that wraps past 0 clips to the maximum). A whole
turn of the hand is 4 * dialQuadrant + 2 units, and the hand turns
clockwise from 12 o'clock as the value grows:

  0 compass, centre (54, 231): yRotationHi * 37/128 (0 to 73); 74 units a
    turn, which is 256 * 37/128, so a turn of heading is a turn of the hand.
  1 airspeed, centre (21, 182): zVelocityP / 128 (0 if flying backwards),
    plus 48, clipped to 57-122; 90 units a turn.
  2 altimeter, hour hand, centre (22, 227): (yPlane / 4) * 53/2048; 66
    units a turn, so one turn per about 2,550 units of yPlane / 4.
  3 altimeter, minute hand, same centre: the low byte of yPlane / 4 times
    53/128 (0 to 105); 106 units a turn, so the hand goes round once for
    every 256 units of yPlane / 4, about ten times as fast as the hour hand.
    Part 4 works this out for part 5 and keeps it in altitudeMinutes.
  4 vertical speed, centre (106, 183): |yVelocity| / 8, at most 255, times
    35/128, at most 40, with yVelocity's sign, plus 67, clipped to 30-104;
    90 units a turn, and 67 is 9 o'clock, so climbing turns the hand up.
  5 turn, centre (106, 229): |yTurn|, at most 140, times 19/128 (0 to 20),
    with the opposite sign, plus 53, clipped to 33-72; 106 units a turn, and
    53 is 6 o'clock: the hand hangs down, the lower half of the
    slip-and-turn indicator, and a positive yTurn swings it towards 3
    o'clock.
  6 slip, same centre: slipRate plus 106, clipped to 91-120; 106 units a
    turn, so 106 is 12 o'clock: the upper half.

The hand is a line from the centre, made by GetHandVector without any
trigonometry. The value is reduced to a quadrant and a position x within it
by taking off a quarter-dial at a time; the first and third quarters take
dialQuadrant + 1 units and the second and fourth dialQuadrant, and in the
second and fourth x is counted backwards, so x always runs from 0 at 12 or
6 o'clock to dialQuadrant at 3 or 9 o'clock. The hand's vector is then
(x / 2, dialQuadrant - x) -- the edge of a diamond, halved across for Mode 5's
wide pixels -- each capped by xDeltaMax and yDeltaMax, which blunts the
diamond's points into something rounder, plus one each because a line of n
pixels covers n - 1 steps; the quadrant gives the signs. The caps per dial
(x, y): compass 7, 12; airspeed 9, 10; hour hand 5, 10; minute hand 10, 14;
vertical speed 8, 12; turn and slip 9, 14.

The other indicators are drawn otherwise:

  7 artificial horizon, centre (53, 188), where a fixed marker (a 7-pixel
    bar with a 2-pixel stub on top) is redrawn after each erase: a line
    whose ends ArtificialHorizon works out from matrix 4 (the roll and
    pitch rotation). Its x-coordinates come from entries 0 and 2, at 1/64
    of their high bytes, its y-coordinates from entries 3 and 4 at 1/32;
    entries 0 and 3 give the line's slope and length, and entries 2 and 4
    shift it. In level flight it is 9 pixels across the centre (x 57 to
    49); pitching moves it up and down, and rolling turns it, up to 17
    pixels long on end. Over every attitude it stays within x 47 to 59 and
    y 177 to 199.
  8, 10 joystick display, centre (80, 199): a cross, a 3-pixel horizontal
    bar and a 5-pixel vertical one, centred on (80 + aileronPosition / 16, 199 +
    elevatorPosition / 4) (ScaleSigned, so -8..8 across and -32..32 down);
    the axes' dots are rewritten after each erase.
  9 rudder, a bar 11 pixels tall from y 242 to 252, at x = 80 +
    rudderPosition / 16 (-8..8).
  11 thrust, a bar 7 pixels tall from y 166 to 172, at x = 125 + thrust *
    3/64 (0 to 30 for thrust 0 to 1280, which the flight model keeps it
    within; from 1488 the bar would be off the right of the screen, and the
    original's pixels would land in its own code).

The radar, centred on the cross at (140, 207), shows the runway as a short
line pointing along the compass heading, and the flying alien as a dot. An
object's position relative to the plane is rotated by matrix 1, so straight
ahead is up, and shown at (140 + x / 32, 207 - z / 16) if that is within
12 pixels across and 25 up or down; x and z here are in units of 256, as
only the high bytes of the positions take part. Only the low byte of each
scaled coordinate is compared with the radar's edges (the high byte gives
just the sign), so the radar wraps round: something 2^21 units off to the
side, or 2^20 ahead, would show as if it were close. Objects' positions are
16-bit, so only a plane far outside the world could see that.

The fuel gauge is a column of pixels at x = 2, one for each 65th of a tank:
fuel level n is shown by the pixels from y = 231 up to 232 - n.
"""

from .maths import scale_signed
from .memory import M
from .names import (aileronPosition, alien, altitudeMinutes, dialQuadrant, elevatorPosition,
                    fuelLevel, indicator0To6, indicator7To11, indicatorBase, indicatorLineI,
                    indicatorLineJ, indicatorLineT, indicatorLineU, indicatorLineV, indicatorMax,
                    indicatorMin, joyCoord, mainLoopCounter, matrix4Hi, matrix4Lo, matrixNumber,
                    nextAxis, previousCompass, rudderPosition, slipRate, thrustHi, thrustLo,
                    xDeltaMax, xJoyCoord, xObjectHi, xPlaneHi, xPlaneTop, xPointHi, xPointLo,
                    xRadarBuffer, xTemp2Hi, xTemp2Lo, xTurnHi, yDeltaMax, yJoyCoord, yPlaneHi,
                    yPlaneLo, yRadarBuffer, yRotationHi, yTurnHi, yTurnTop, yVelocityHi,
                    yVelocityTop, zPointHi, zPointLo, zRotationHi, zVelocityPHi, zVelocityPLo)
from .points import copy_work_to_point, set_object_to_origin, set_point_coords

# ---- the hook --------------------------------------------------------------

SCREEN = 0x5800              # Mode 5 screen memory, 320 bytes a character row


def screen_y(j):
    """The screen row of DrawVectorLine's y-coordinate J. J counts up the
    screen from the bottom of the canopy (0 is screen row 159) and, taken as
    signed, below it into the dashboard (-1 is row 160, -96 row 255): the
    screen lookup tables, yLookupLo and yLookupHi, are built so that this is
    simply 159 - J in eight bits."""
    return (159 - j) & 0xFF


def vector_line_pixels(i, j, t, u, v):
    """The pixels DrawVectorLine plots for a line from (I, J) with lengths T
    and U and direction V, as (I, J) pairs in the order it plots them.

    It walks along the longer axis a pixel at a time, max(T, U) pixels in
    all (256 if both are 0), keeping a running remainder of the shorter
    axis and stepping along that too each time the remainder reaches the
    longer length. The sums are eight-bit, like everything else here."""
    left = v & 0x80
    down = v & 0x40
    steep = t < u
    count = u if steep else t
    remainder = 0
    out = []
    while True:
        out.append((i, j))
        count = (count - 1) & 0xFF
        if count == 0:
            return out
        if steep:
            a = (remainder + t) & 0xFF
            if a >= u:
                a -= u
                i = (i - 1 if left else i + 1) & 0xFF
            remainder = a
            j = (j - 1 if down else j + 1) & 0xFF
        else:
            a = (remainder + u) & 0xFF
            if a >= t:
                a -= t
                j = (j - 1 if down else j + 1) & 0xFF
            remainder = a
            i = (i - 1 if left else i + 1) & 0xFF


class Line:
    """One line, bar or pixel, as DrawVectorLine is asked to draw it (see the
    module docstring). i and j are the original's own coordinates for the
    first pixel; x and y the screen's."""
    __slots__ = ("what", "erase", "i", "j", "t", "u", "v")

    def __init__(self, what, erase, i, j, t, u, v):
        self.what, self.erase = what, erase
        self.i, self.j, self.t, self.u, self.v = i, j, t, u, v

    @property
    def x(self):
        return self.i

    @property
    def y(self):
        return screen_y(self.j)

    @property
    def count(self):
        n = max(self.t, self.u)
        return n if n else 256

    def pixels(self):
        """Every pixel plotted, as screen (x, y), first to last."""
        return [(i, screen_y(j)) for i, j in vector_line_pixels(self.i, self.j, self.t, self.u, self.v)]

    @property
    def end(self):
        return self.pixels()[-1]

    def __repr__(self):
        verb = "erase" if self.erase else "draw"
        return f"Line({self.what!r}, {verb} from ({self.x}, {self.y}), t={self.t} u={self.u} v=&{self.v:02X})"


class Pattern:
    """Four pixels written whole from one Mode 5 screen byte (see the module
    docstring)."""
    __slots__ = ("what", "x", "y", "byte")

    def __init__(self, what, x, y, byte):
        self.what, self.x, self.y, self.byte = what, x, y, byte

    def colours(self):
        """The four logical colours, left to right: pixel n takes bit 7 - n
        as its high colour bit and bit 3 - n as its low one."""
        b = self.byte
        return tuple((((b >> (7 - n)) & 1) << 1) | ((b >> (3 - n)) & 1) for n in range(4))

    def __repr__(self):
        return f"Pattern({self.what!r}, ({self.x}, {self.y}), &{self.byte:02X})"


def _no_hook(event):
    pass


hook = _no_hook

# What each indicator number draws, as Line.what.
INDICATOR_NAMES = ("compass", "airspeed", "altimeter hours", "altimeter minutes", "vertical speed",
                   "turn", "slip", "horizon", "joystick", "rudder", "joystick", "thrust")
RADAR_RUNWAY, RADAR_ALIEN, FUEL = "radar runway", "radar alien", "fuel"


def block(row, char, line):
    """The screen position (x, y) of the byte the source calls
    row<row>_char<char>_<line>: character row, character block (four pixels
    wide) and pixel line within the block."""
    return char * 4, row * 8 + line


def block_address(row, char, line):
    return SCREEN + row * 320 + char * 8 + line


# The fixed marks rewritten after an erase, as (row, block, line, byte) in
# the order the original writes them, from the source's screen constants.
HORIZON_CENTRE = ((23, 13, 4, 0b11111111), (23, 13, 3, 0b01000100), (23, 13, 2, 0b01000100),
                  (23, 12, 4, 0b00110011), (23, 14, 4, 0b10001000))
JOYSTICK_AXES = ((24, 18, 7, 0b00100010), (24, 21, 7, 0b00100010), (24, 19, 7, 0b01000100),
                 (24, 20, 7, 0b10011001),
                 (21, 20, 7, 0b10001000), (22, 20, 7, 0b10001000), (23, 20, 7, 0b10001000),
                 (25, 20, 7, 0b10001000), (26, 20, 7, 0b10001000), (27, 20, 7, 0b10001000))
RADAR_CROSS = ((25, 35, 6, 0b10001000), (26, 35, 0, 0b10001000), (26, 35, 1, 0b10001000),
               (25, 34, 7, 0b00010001), (25, 35, 7, 0b11001100))
SLIP_CENTRE = (28, 26, 5, 0b01110111)

# The two screen bytes the game reads back as state (see the module
# docstring), and the upside-down bar's pattern: three pixels in colour 1.
UPSIDE_DOWN_BLOCK = (25, 13, 1)
UPSIDE_DOWN_BAR = block_address(*UPSIDE_DOWN_BLOCK)              # &77A9
JOYSTICK_ENABLED = block_address(29, 20, 4)                      # &7CE4
UPSIDE_DOWN_PATTERN = 0b00001110


def _patterns(what, marks):
    for row, char, line, byte in marks:
        x, y = block(row, char, line)
        hook(Pattern(what, x, y, byte))


# ---- lines -----------------------------------------------------------------

def draw_vector_line(i, j, t, u, v, erase, what=None):
    """DrawVectorLine: draw or erase the line from (I, J) with lengths T, U
    and direction V. All of it is drawing, so all of it goes to the hook."""
    hook(Line(what, bool(erase), i, j, t, u, v))


def draw_ortho_line(along, joy, s, t, u, erase, what=None):
    """DrawOrthoLine: a line going right and up from a start point given as
    two coordinates, `along` (H + W in the original) and `joy` (joyCoord):
    bit 7 of S clear puts `joy` across and `along` up, set the other way
    round. T and U are the lengths, as for draw_vector_line."""
    if s & 0x80:
        i, j = along, joy
    else:
        i, j = joy, along
    draw_vector_line(i, j, t, u, 0, erase, what)


def erase_ortho_line(along, joy, s, t, u, what=None):
    """EraseOrthoLine: draw_ortho_line, always erasing; the original's entry
    takes G + W rather than H + W as `along`."""
    draw_ortho_line(along, joy, s, t, u, True, what)


# ---- the dials ------------------------------------------------------------

def get_hand_vector(a, x):
    """GetHandVector: the vector of dial x's hand for value a, as (W, G, R):
    the x and y lengths for draw_vector_line and the direction (bit 7: x
    goes left, bit 6: y goes down). See the module docstring for the
    quadrant method."""
    quarter = M[dialQuadrant + x]
    k = (quarter + 1) & 0xFF
    r = 0
    while True:
        a -= k
        if a < 0:
            a += k                                 # 12 to 3 o'clock
            break
        a -= quarter
        if a < 0:
            # 3 to 6 o'clock, counted back from 6: having taken off one
            # more than the quarter, inverting the bits negates exactly.
            r = 0x40
            a = (a & 0xFF) ^ 0xFF
            break
        a -= k
        if a < 0:
            a += k                                 # 6 to 9 o'clock
            r = 0xC0
            break
        a -= quarter
        if a < 0:
            r = 0x80                               # 9 to 12 o'clock, backwards
            a = (a & 0xFF) ^ 0xFF
            break
    position = a
    dy = (quarter - position) & 0xFF
    if dy >= M[yDeltaMax + x]:
        dy = M[yDeltaMax + x]
    dx = ((position + 1) & 0xFF) >> 1              # halved for Mode 5's wide pixels
    if dx >= M[xDeltaMax + x]:
        dx = M[xDeltaMax + x]
    return (dx + 1) & 0xFF, (dy + 1) & 0xFF, r


def draw_indicator_line(x, w, g, r, s=0, h=0):
    """DrawIndicatorLine: replace indicator x's line (a hand, or the horizon
    for x = 7) with the one of lengths W, G and direction R. The old one is
    erased from what the line buffers say was drawn, and the new one is
    remembered there. A hand starts from its dial's centre, which the
    buffers hold and never change; the horizon starts from (S, H), which
    replace them."""
    what = INDICATOR_NAMES[x]
    draw_vector_line(M[indicatorLineI + x], M[indicatorLineJ + x], M[indicatorLineT + x],
                     M[indicatorLineU + x], M[indicatorLineV + x], True, what)
    if x == 7:
        _patterns("horizon centre", HORIZON_CENTRE)
        M[indicatorLineI + 7] = s
        M[indicatorLineJ + 7] = h
    M[indicatorLineT + x] = w
    M[indicatorLineU + x] = g
    M[indicatorLineV + x] = r
    draw_vector_line(M[indicatorLineI + x], M[indicatorLineJ + x], w, g, r, False, what)


def draw_indicator_hand(a, x):
    """DrawIndicatorHand: show value a on dial x (0 to 6): add the dial's
    base, clip it to the dial's range, and redraw the hand."""
    a = (a + M[indicatorBase + x]) & 0xFF
    if a < M[indicatorMin + x]:
        a = M[indicatorMin + x]
    elif a >= M[indicatorMax + x]:
        a = M[indicatorMax + x]
    w, g, r = get_hand_vector(a, x)
    draw_indicator_line(x, w, g, r)


def _times_fraction(value, steps):
    """The unrolled shift-and-add multiplications of UpdateIndicator: for
    each step, 0 halves the running value and 1 adds `value` to it and
    halves the nine-bit sum, so each step keeps its own truncation."""
    a = value
    for add in steps:
        a = (a + value) >> 1 if add else a >> 1
    return a


# The steps of each hard-coded multiplication, lowest bit first, as the
# original's code runs them.
COMPASS_STEPS = (0, 0, 1, 0, 0, 1, 0)            # 37/128
ALTITUDE_STEPS = (0, 0, 1, 0, 1, 1, 0)           # 53/128
VERTICAL_SPEED_STEPS = (0, 1, 0, 0, 0, 1, 0)     # 35/128
TURN_STEPS = (0, 1, 0, 0, 1, 0, 0)               # 19/128

# Where the horizon is drawn and the bars and the cross sit, from
# UpdateIndicator's parts 11 to 15 and DrawJoystickCross, in the original's
# (I, J) coordinates (J = 159 - screen row, in eight bits).
HORIZON_X, HORIZON_J = 53, 227                   # J 227 is -29: screen row 188
RUDDER_X, RUDDER_TOP_J, RUDDER_HEIGHT = 80, 163, 11
THRUST_X, THRUST_TOP_J, THRUST_HEIGHT = 125, 243, 7
JOYSTICK_X, JOYSTICK_J = 80, 216                 # J 216 is -40: screen row 199


def _altimeter_hours():
    """Part 4: the hour hand's value, keeping the minute hand's in
    altitudeMinutes on the way.

    The altitude (S R) is yPlane / 4, and both hands are (S R) * 53/128:
    the minute hand that of the low byte alone, and the hour hand all of
    it, divided by 16. The high byte's product is worked out to 16 bits,
    the bits shifted out at the bottom kept as a fraction byte, and the
    minute hand's value added to that fraction."""
    altitude = (M[yPlaneHi] << 8 | M[yPlaneLo]) >> 2
    s, r = altitude >> 8, altitude & 0xFF
    minutes = _times_fraction(r, ALTITUDE_STEPS)
    M[altitudeMinutes] = minutes
    # The same multiplication on S, with the bits shifted out of the
    # bottom caught in a fraction byte: as a 16-bit (U T), each step either
    # halves it or adds S to the high byte and halves.
    ut = s << 8
    for add in ALTITUDE_STEPS:
        if add:
            ut += s << 8
        ut >>= 1
    total = ut + minutes
    return (total >> 4) & 0xFF


def _signed_magnitude(top, hi):
    """|(top hi)| for a 16-bit two's complement value, as the original
    makes it positive: (high, low)."""
    value = top << 8 | hi
    if top & 0x80:
        value = (-value) & 0xFFFF
    return value >> 8, value & 0xFF


def _vertical_speed():
    """Part 7: |yVelocity| / 8, capped at 255, scaled and capped at 40, with
    yVelocity's sign."""
    high, low = _signed_magnitude(M[yVelocityTop], M[yVelocityHi])
    t = (high << 8 | low) >> 3
    t = 255 if t > 255 else t
    a = _times_fraction(t, VERTICAL_SPEED_STEPS)
    if a >= 40:
        a = 40
    if M[yVelocityTop] & 0x80:
        a = (-a) & 0xFF
    return a


def _turn():
    """Part 9: |yTurn|, capped at 140, scaled, with the opposite sign to
    yTurn, because the hand hangs down from the centre: taking from its
    value of 6 o'clock swings its end towards 3 o'clock."""
    high, low = _signed_magnitude(M[yTurnTop], M[yTurnHi])
    t = low if high == 0 and low < 140 else 140
    a = _times_fraction(t, TURN_STEPS)
    if not M[yTurnTop] & 0x80:
        a = (-a) & 0xFF
    return a


def _horizon():
    """Part 11: the artificial horizon's new line, from four calls of
    ArtificialHorizon (start x, start y, end x, end y, relative to the
    dial's centre), turned into a start point and a vector."""
    s = artificial_horizon(0, 0)
    h = artificial_horizon(0, 3)
    r = 0
    dx = (artificial_horizon(1, 0) - s) & 0xFF
    if dx & 0x80:
        r = 0x80
        dx = (-dx) & 0xFF
    w = (dx + 1) & 0xFF
    dy = (artificial_horizon(1, 3) - h) & 0xFF
    if dy & 0x80:
        r |= 0x40
        dy = (-dy) & 0xFF
    g = (dy + 1) & 0xFF
    draw_indicator_line(7, w, g, r, (s + HORIZON_X) & 0xFF, (h + HORIZON_J) & 0xFF)


def _joystick():
    """Part 14: move the joystick display's cross. The old cross is erased,
    the axes it may have crossed rewritten, and the new one drawn.
    elevatorPosition's sign is flipped, so a positive value moves the cross
    down."""
    draw_joystick_cross(True)
    _patterns("joystick axes", JOYSTICK_AXES)
    M[xJoyCoord] = scale_signed(M[aileronPosition], True)
    M[yJoyCoord] = (-scale_signed(M[elevatorPosition], False)) & 0xFF
    draw_joystick_cross(False)


def _thrust_bar():
    """Part 15: thrust * 3/64, as (thrust / 16) * 1.5, rounded, then / 4."""
    a = ((M[thrustHi] << 8 | M[thrustLo]) >> 4) & 0xFF
    a = (((a >> 1) + a + (a & 1)) & 0xFF) >> 2
    draw_indicator_bar(THRUST_HEIGHT, 3, THRUST_X, THRUST_TOP_J, a, "thrust")


def update_indicator(x):
    """UpdateIndicator: redraw indicator x (0 to 11) from the game's current
    values."""
    if x == 0:
        draw_indicator_hand(_times_fraction(M[yRotationHi], COMPASS_STEPS), 0)
    elif x == 1:
        hi = M[zVelocityPHi]
        a = 0 if hi & 0x80 else ((hi << 1) | (M[zVelocityPLo] >> 7)) & 0xFF
        draw_indicator_hand(a, 1)
    elif x == 2:
        draw_indicator_hand(_altimeter_hours(), 2)
    elif x == 3:
        draw_indicator_hand(M[altitudeMinutes], 3)
    elif x == 4:
        draw_indicator_hand(_vertical_speed(), 4)
    elif x == 5:
        draw_indicator_hand(_turn(), 5)
    elif x == 6:
        draw_indicator_hand(M[slipRate], 6)
    elif x == 7:
        _horizon()
    elif x == 8 or x == 10:
        _joystick()
    elif x == 9:
        draw_indicator_bar(RUDDER_HEIGHT, 1, RUDDER_X, RUDDER_TOP_J,
                           scale_signed(M[rudderPosition], True), "rudder")
    elif x == 11:
        _thrust_bar()


def update_dashboard():
    """UpdateDashboard: update the next of indicators 0 to 6, then fall
    through into update_dash_7_to_11."""
    x = (M[indicator0To6] + 1) & 0xFF
    if x >= 7:
        x = 0
    M[indicator0To6] = x
    update_indicator(x)
    update_dash_7_to_11()


def update_dash_7_to_11():
    """UpdateDash7To11: update the next of indicators 7 to 10 (not 11: see
    the module docstring), and rewrite the slip-and-turn indicator's centre,
    which both its hands start from and so rub out."""
    x = (M[indicator7To11] + 1) & 0xFF
    if x >= 11:
        x = 7
    M[indicator7To11] = x
    update_indicator(x)
    _patterns("slip centre", (SLIP_CENTRE,))


def artificial_horizon(k, y):
    """ArtificialHorizon: one coordinate of the horizon line's ends,
    relative to the dial's centre. Y = 0 gives an x-coordinate, from matrix
    4's entries 0 and 2 (at 1/64 of the high byte), Y = 3 a y-coordinate,
    from entries 3 and 4 (at 1/32); K = 0 gives the start and K = 1 the
    end, the sign of the first entry's term flipped.

    Each term is the entry's high byte shifted down, negated by the
    entry's sign bit (bit 0 of its low byte); for x, entry 2's sign is
    inverted. Their eight-bit sum is divided by 8, keeping its sign and
    rounding to nearest."""
    shift = 3 if y == 0 else 2
    t = M[matrix4Hi + y] >> shift
    if (M[matrix4Lo + y] ^ k) & 1:
        t = (-t) & 0xFF
    u = M[matrix4Hi + 2 + y] >> shift
    sign = M[matrix4Lo + 2 + y]
    if y == 0:
        sign ^= 1
    if sign & 1:
        u = (-u) & 0xFF
    a = (t + u) & 0xFF
    rounding = (a >> 2) & 1                        # the last bit shifted out
    if a & 0x80:
        return (((a >> 3) | 0xE0) + rounding) & 0xFF
    return (a >> 3) + rounding


def show_upside_down_bar():
    """ShowUpsideDownBar: show the bar under the artificial horizon when the
    plane is upside down, which is when bits 6 and 7 of zRotationHi differ
    (a roll between a quarter and three quarters of a turn).

    The bar is also the game's record of being upside down, which
    CheckFlyingSkills reads from the screen, so the byte is written to M at
    its screen address as well as drawn."""
    a = M[zRotationHi]
    if a & 0x80:
        a ^= 0xC0
    byte = UPSIDE_DOWN_PATTERN if a & 0xC0 else 0
    M[UPSIDE_DOWN_BAR] = byte
    x, y = block(*UPSIDE_DOWN_BLOCK)
    hook(Pattern("upside-down bar", x, y, byte))


# ---- the bars and the joystick display ---------------------------------------

def draw_indicator_bar(height, x, w, top, h, what=None, s=0x80):
    """DrawIndicatorBar: move a bar of the given height, its top at `top`
    (in the original's J), to H + W across, erasing it from where yJoyCoord
    + X says it was (X = 1 for the rudder, 3 for the thrust, which is
    xJoyCoord + 1).

    joyCoord is left holding the top: it is the original's way of passing
    that to DrawOrthoLine, and it lies outside the temporaries."""
    M[joyCoord] = top
    old = M[yJoyCoord + x]
    M[yJoyCoord + x] = h
    erase_ortho_line((old + w) & 0xFF, top, s, 1, height, what)
    draw_ortho_line((h + w) & 0xFF, top, s, 1, height, False, what)


def draw_joystick_cross(erase):
    """DrawJoystickCross: draw or erase the cross at (xJoyCoord, yJoyCoord)
    from the joystick display's centre: three pixels across starting one to
    the left, then five up starting two below. joyCoord is left holding the
    second's start, as the original leaves it."""
    xj, yj = M[xJoyCoord], M[yJoyCoord]
    M[joyCoord] = (xj + JOYSTICK_X - 1) & 0xFF
    draw_ortho_line((yj + JOYSTICK_J) & 0xFF, M[joyCoord], 0, 3, 1, erase, "joystick")
    M[joyCoord] = (yj + JOYSTICK_J - 2) & 0xFF
    draw_ortho_line((xj + JOYSTICK_X) & 0xFF, M[joyCoord], 0x80, 1, 5, erase, "joystick")


# ---- the radar ---------------------------------------------------------------

RADAR_X, RADAR_J = 140, 208                      # J 208 is -48: screen row 207
RADAR_HALF_WIDTH, RADAR_HALF_HEIGHT = 13, 26     # a blip shows if |x| < 13 and |z| < 26
RUNWAY, ALIEN = 1, 33                            # the objects UpdateRadarBlip shows


def get_radar_vector(a, x):
    """GetRadarVector: the lengths and direction (T, U, V) of the radar's
    line for compass heading a: the runway for x = 0, the alien's dot
    otherwise. For the runway the heading is kept in previousCompass, so
    the line can be erased when the heading has changed.

    The runway is a short line from its position: four pixels nearly
    upright (T = 1, U = 4) or diagonal (2, 4, close to 45 degrees on Mode
    5's wide pixels), or two side by side (2, 1), depending on which eighth
    of a turn the heading plus a sixteenth is in. Its direction bits are
    bit 7 of the heading plus a sixteenth and bit 7 of the heading less
    three sixteenths, each inverted. The dot is a single pixel, whose
    direction the original leaves as it was and which does not matter; 0
    here."""
    if x != 0:
        return 1, 1, 0
    M[previousCompass] = a
    a1 = (a + 16) & 0xFF
    p = (a1 << 1) & 0xFF
    a2 = (a1 - 64) & 0xFF
    v = ((a1 & 0x80) | (a2 >> 1)) ^ 0xC0
    if p & 0x40:
        t, u = 2, 4
    elif not p & 0x80:
        t, u = 1, 4
    else:
        t, u = 2, 1
    return t, u, v


def update_radar_blip(y):
    """UpdateRadarBlip: work out where object y (RUNWAY or ALIEN) is on the
    radar, and redraw it there.

    Only the objects' high bytes and the plane's high and top bytes take
    part: the vector from the plane to the object, in units of 256, goes
    into xTemp2 and point 0, is rotated by matrix 1 into the plane's frame,
    and is scaled down -- z by 16 and x by 32, rounded -- in the low bytes
    of point 0 alone. The high bytes keep the signs, unchanged."""
    M[alien] = 1 if y == ALIEN else 0
    for axis in range(3):
        low = M[xObjectHi + ((y + axis * nextAxis) & 0xFF)] - M[xPlaneHi + axis]
        M[xTemp2Lo + axis] = low & 0xFF
        M[xTemp2Hi + axis] = (0 - M[xPlaneTop + axis] - (1 if low < 0 else 0)) & 0xFF
    copy_work_to_point(xTemp2Lo - xTurnHi, 0)
    M[matrixNumber] = 0
    set_point_coords(0, 0)
    x16 = (M[xPointHi] << 8 | M[xPointLo]) >> 4
    z16 = (M[zPointHi] << 8 | M[zPointLo]) >> 4
    M[zPointLo] = z16 & 0xFF
    M[xPointLo] = (((x16 >> 1) & 0xFF) + (x16 & 1)) & 0xFF
    draw_radar_blip()


def _on_radar(low, high, limit):
    """Whether a radar coordinate's low byte, taken with the sign in bit 7
    of its high byte, is within the limit either way."""
    magnitude = (-low) & 0xFF if high & 0x80 else low
    return magnitude < limit


def draw_radar_blip():
    """DrawRadarBlip: erase the runway or the alien (as `alien` says) from
    where the radar buffers say it is, and draw it at point 0's low bytes,
    if they are on the radar. Erasing the runway may have rubbed out part
    of the cross in the middle, which is rewritten -- except for its top
    pixel, which the original leaves out."""
    x = M[alien]
    what = RADAR_ALIEN if x else RADAR_RUNWAY
    t, u, v = get_radar_vector(M[previousCompass], x)
    draw_vector_line(M[xRadarBuffer + x], M[yRadarBuffer + x], t, u, v, True, what)
    if x == 0:
        _patterns("radar cross", RADAR_CROSS)
    if not _on_radar(M[xPointLo], M[xPointHi], RADAR_HALF_WIDTH):
        return
    if not _on_radar(M[zPointLo], M[zPointHi], RADAR_HALF_HEIGHT):
        return
    i = (M[xPointLo] + RADAR_X) & 0xFF
    j = (M[zPointLo] + RADAR_J) & 0xFF
    M[xRadarBuffer + x] = i
    M[yRadarBuffer + x] = j
    t, u, v = get_radar_vector(M[yRotationHi], x)
    draw_vector_line(i, j, t, u, v, False, what)


def reset_radar():
    """ResetRadar: take the alien off the radar (by asking for it to be
    drawn at an x of 80, which is off the radar, after the old dot is
    erased) and move the flying alien, object 33, to the origin."""
    M[xPointLo] = 80
    M[alien] = 1
    M[xPointHi] = 1
    draw_radar_blip()
    set_object_to_origin(ALIEN)


# ---- the fuel gauge ----------------------------------------------------------

FUEL_X, FUEL_BOTTOM_J = 2, 184                   # J 184 is -72: screen row 231
FUEL_EVERY = 16                                  # main loop iterations between updates


def update_fuel_gauge():
    """UpdateFuelGauge: every 16th iteration of the main loop, erase the
    gauge's pixel at the fuel level, which is the one above the top of the
    column when fuel has just been used."""
    if M[mainLoopCounter] & (FUEL_EVERY - 1):
        return
    draw_fuel_pixel(M[fuelLevel], 0x80)


def draw_fuel_pixel(a, x):
    """DrawFuelPixel: draw (bit 7 of x clear) or erase (set) the fuel gauge's
    pixel for level a, 0 to 65: pixel n is level n + 1's top."""
    draw_vector_line(FUEL_X, (a + FUEL_BOTTOM_J) & 0xFF, 1, 1, 0, x & 0x80, FUEL)
