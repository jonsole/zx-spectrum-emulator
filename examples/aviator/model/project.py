"""Projecting points onto the screen: ProjectPoint, and the floating-point
style division it is built from (ScaleUp, DivideScaled and ScaleDown).

What it works out
-----------------

By the time a point is projected it is in the viewer's frame of reference
(SetPointCoords has rotated it by matrix 1): x to the right, y up, z straight
ahead. ProjectPoint replaces its x- and y-coordinates with where it appears in
the canopy view,

    screen x = 80 + 256 * x / z
    screen y = 96 + 512 * y / z

rounded to the nearest pixel. The canopy view is 160 x 192 Mode 5 pixels with
its origin at the bottom left, so (80, 96) is its centre, straight ahead. The
two scale factors differ because a Mode 5 pixel is twice as wide as it is
high: 256 pixels across and 512 pixels up are the same distance on the
monitor, so the picture is not squashed. The edges of the view are at
x / z = 80 / 256 and y / z = 96 / 512, about 17 degrees to either side and 11
degrees up and down. On a screen with square pixels the two factors would be
equal; a different size of view changes the centre, (80, 96), and perhaps the
factors -- the 256 is set by the + 1 in ScaleDown's shifts, and can only be a
power of two without a multiplication, and the 2 is the doubling of |y| at
the start of ProjectPoint.

How it divides
--------------

The 6502 cannot divide, and a long division for both coordinates of every
point every frame would be far too slow, so the division is done the way a
floating-point unit would, on magnitudes, with the signs put back at the end:

1. ScaleUp splits |z| into an exponent and a mantissa,
   |z| = 2^UU * (1 + m / 65536), m being the 16 bits after the leading 1.
   A z of 0 is taken as 1, so there is always something to divide by.

2. The top byte of m indexes the division table, whose entry is the
   reciprocal of the mantissa, 65536 / (1 + i / 256), less 256 so that the
   reciprocal of 1 fits in 16 bits (the table is accurate to within 4 of
   that; its bottom three bits hold the log2 table ScaleUp uses, and are
   masked off).

3. DivideScaled splits the numerator the same way, n = 2^e * (1 + j / 65536),
   and multiplies the two mantissas, putting back the 256 the table leaves
   out and using the top two bits of m's low byte to step a quarter, a half
   or three-quarters of the way towards the next table entry. Its result is
   the ratio of the mantissas with 32768 standing for 1: since that ratio is
   between 1/2 and 2, (Q P) is between &4000 and &FFFF (&FFF9 at most, from
   the table's reciprocals), never needing more than 16 bits.

4. ScaleDown puts the exponents back. x / z is (Q P) * 2^(e - UU - 15), so
   256 * x / z is (Q P) shifted left by e - UU + 1 places with its bottom
   byte as the fraction, which decides the rounding.

The two divisions share the one reciprocal, which is why the work is split
this way rather than into two calls of one divide routine. The quotient is
good to about one part in a thousand, and usually a little high: on the
canopy a coordinate is always within 0.6 of a pixel of the exact projection,
and about one in eighty differs from it by a pixel after rounding.

The results
-----------

Each projected offset from the centre is at most &3FFF. When either offset
would be too big for that -- the original judges it by the shift: 7 places
or more, an offset of 2^13 pixels or more, a point nearly level with the
viewer, though 7 is allowed when the larger-shifted quotient is below &8000
-- both shifts are brought down together instead. That keeps the ratio
between the offsets, and so the direction of the point from the centre of
the screen: the point is pulled in along that line, which is all the line
clipper needs. The results are 16-bit two's complement numbers in xPoint and
yPoint; anything outside 0-159 and 0-191 is off the canopy and is clipped by
the line drawing.

The signs come from the true quotient: an offset is added to the centre when
the coordinate and z have the same sign and taken away when they differ. So a
point behind the viewer (z negative) is not treated specially: it lands where
the projection through the eye puts it, mirrored through the centre of the
screen. zPoint is left as it was so that the line routines can tell: a line
with both ends behind the viewer is hidden, and one with only one end behind
is drawn from its other end in the opposite direction, which undoes the
mirroring.

Who calls it, and what it writes
--------------------------------

ProjectPoint has one caller, ProcessLinesToShow, which projects the start
point and then the end point of each line still to be shown, passing the
point ID in GG. There are no other entry points into these routines (the
JSR ScaleUp just before DivideScaled is never reached). ProjectPoint writes
only the point's own entries: xPoint and yPoint (the screen coordinates) and
pointStatus, where it sets

    bit 0  the point has been projected: if it is set already, ProjectPoint
           returns at once, so a point shared by several lines is projected
           only once
    bit 2  y is negative
    bit 3  x is negative
    bit 4  2 |y| >= |z|, more than about 27 degrees above or below the view
    bit 5  |x| >= |z|, more than 45 degrees to the left or right

so that ProcessLinesToShow can drop a line whose ends are both well off the
same side of the view before drawing it. The bits are added to the byte, not
written over it.
"""

from .maths import multiply8x8
from .memory import M
from .names import divisionHi, divisionLo, pointStatus, xPointHi, xPointLo, yPointHi, yPointLo
from .points import point

# The bits of pointStatus that ProjectPoint sets.
PROJECTED = 0x01
Y_NEGATIVE = 0x04
X_NEGATIVE = 0x08
Y_WIDE = 0x10                # 2 |y| >= |z|
X_WIDE = 0x20                # |x| >= |z|

# The centre of the canopy view, 160 x 192 Mode 5 pixels.
CENTRE_X = 80
CENTRE_Y = 96

# The division table's low bytes keep a log2 table in their bottom three bits.
RECIPROCAL_LOW_MASK = 0xF8

# ScaleDown's limit on the shift that puts a quotient's exponent back: 6
# places at most leaves an offset below &4000 for any quotient, and 7 does
# for a quotient below &8000.
SHIFT_LIMIT = 7
LARGEST_OFFSET = 0x3FFF


def scale_up(v):
    """Split a positive 16-bit number into its mantissa and exponent: returns
    (mantissa, ww), where v = 2^ww * (1 + mantissa / 65536). The mantissa is
    v shifted left until its leading 1 falls out of the top, and ww + 1 is
    the number of binary digits v has.

    The original finds ww from the log2 table in the bottom bits of
    divisionLo, and shifts by whichever is quicker: a bit at a time until the
    leading 1 reaches bit 12, then four places at once by the nibble tables.
    The result is the same either way.

    v must not be 0: given 0, the original drops its own return address and
    returns straight out of DivideScaled, which divide_scaled does instead
    (ProjectPoint never asks it to scale a zero denominator)."""
    if v == 0:
        raise ValueError("ScaleUp is never given 0 except through DivideScaled")
    ww = v.bit_length() - 1
    return (v << (16 - ww)) & 0xFFFF, ww


def reciprocal(index):
    """The division table's entry for a mantissa whose top byte is index:
    about 65536 / (1 + index / 256) - 256, as (TT S)."""
    return (M[divisionHi + index] << 8) | (M[divisionLo + index] & RECIPROCAL_LOW_MASK)


def _nibble_product(b):
    """What timesTable holds: the product of a byte's two nibbles."""
    return (b >> 4) * (b & 0x0F)


def divide_scaled(n, tts, k, uu):
    """Divide n, a 16-bit magnitude, by the denominator that ScaleUp split
    into exponent uu and a mantissa whose top byte gave the reciprocal tts
    (from the division table) and whose low byte is k. Returns (qp, ww): the
    ratio of the mantissas, 32768 standing for 1, and n's exponent, so that
    n / denominator = qp * 2^(ww - uu - 15).

    With j the numerator's mantissa as a fraction and R = tts + 256 the
    whole reciprocal, the result is (1 + j) * R / 2: R + R * j, halved. The
    original multiplies by nibbles, and the Python follows it step by step,
    because what it adds up is not quite that:

    - of R * j, only the products with the top byte of j's mantissa, J, and
      of TT with the top nibble of its low byte, I, are worked out, and of
      those, anything below the bottom byte is dropped;
    - the 256 the table leaves out of R is put back as 1 in the high byte,
      and its product with j as J in the low byte;
    - three carries out of the low byte are each counted twice, in the high
      byte and again in the next addition, so the sum can come out up to
      three units high before it is halved;
    - if the high byte overflows before TT is added, the overflow becomes the
      top bit and any carry from adding TT is lost, and a sum that overflows
      when I's product is added gives &FFFF; with the table's reciprocals
      neither loses anything (the largest result they give is &FFF9).

    Then the low byte of the denominator's mantissa is allowed for: its top
    two bits pick a quarter, a half or three-quarters of the way to the next
    table entry, and since the reciprocal falls by about TT / 65536 of itself
    from one entry to the next, the result is reduced by Q times that
    fraction of TT, over 256 -- a linear step along the table.

    A numerator of 0 gives (0, uu - 1): the exponent that makes ScaleDown
    leave the result at 0. In the original it is ScaleUp that notices, and
    returns from DivideScaled itself."""
    if n == 0:
        return 0, (uu - 1) & 0xFF
    mantissa, ww = scale_up(n)
    j, i = mantissa >> 8, mantissa & 0xFF
    tt, s = tts >> 8, tts & 0xFF
    th, tl = tt >> 4, tt & 0x0F
    jh, jl = j >> 4, j & 0x0F

    # (Q P) starts as the products that land on the bottom two bytes, with
    # the 1 of the missing 256 in Q; the carry from P goes into Q, which
    # cannot overflow.
    low = _nibble_product((s & 0xF0) | jh) + _nibble_product((tl << 4) | jl)
    p = low & 0xFF
    q = _nibble_product((tt & 0xF0) | jh) + 1 + (low >> 8)

    # The two cross products of the nibbles weigh 16, so their sum, nine
    # bits, is split across the bytes: its carry is 16 in the high byte.
    cross = _nibble_product((tt & 0xF0) | jl) + _nibble_product((tl << 4) | jh)
    carry = cross >> 8
    cross &= 0xFF
    high = 16 if carry else 0

    # The low nibble of the cross sum, then P, J and S, go into the low
    # byte. The carry into each addition is the one out of the last, which
    # for the first is the cross sum's own carry, already counted in the
    # high byte; and each carry out of the first two is counted in the high
    # byte as well as going into the next addition.
    total = ((cross << 4) & 0xFF) + p + carry
    carry = total >> 8
    high += carry
    total = (total & 0xFF) + j + carry
    carry = total >> 8
    high += carry
    total = (total & 0xFF) + s + carry
    p = total & 0xFF
    carry = total >> 8

    a = high + (cross >> 4) + carry + q
    if a > 0xFF:
        # The overflow becomes the top bit (the original sets the carry by
        # hand for the shift), and a carry from adding TT would be lost.
        a = (a + tt) & 0xFF
        top = 1
    else:
        a += tt
        top = a >> 8
        a &= 0xFF
    qp = ((top << 16) | (a << 8) | p) >> 1

    if i:
        # TT * I / 256, from the top nibble of I against both nibbles of
        # TT, halved to match the rest. The products with I's low nibble are
        # left out; in their place, the fraction of one product is added to
        # I itself, and its carry rounds the sum up.
        product = _nibble_product((i & 0xF0) | tl)
        c = (((product << 4) & 0xFF) + i) >> 8
        extra = (_nibble_product((i & 0xF0) | th) + (product >> 4) + c) >> 1
        total = (qp & 0xFF) + extra
        q = (qp >> 8) + (total >> 8)
        qp = 0xFFFF if q > 0xFF else (q << 8) | (total & 0xFF)

    quarters = k & 0xC0
    if quarters:
        w = (tt + 1) >> 1                         # half the slope
        step = 0
        if quarters & 0x40:
            step = w >> 1
        if quarters & 0x80:
            step += w
        q, p = qp >> 8, qp & 0xFF
        g = multiply8x8(q, step) >> 8
        if p < g:
            q = (q - 1) & 0xFF
        qp = (q << 8) | ((p - g) & 0xFF)
    return qp, ww


def _shift_and_round(quotient, places):
    """quotient * 2^(places - 8), rounded to the nearest whole number:
    quotient shifted left (or, for a negative byte, right) by places with its
    bottom byte as the fraction. The fraction's top bit rounds up; if that
    carries into the top byte and takes it to &40, the result is &3FFF.

    Shifting right, only the high byte is shifted, as the fraction will be
    dropped anyway, and the bit last shifted out does the rounding; shifting
    left, the original shifts a 24-bit number and so loses anything shifted
    past its top, though ScaleDown never shifts that far."""
    hi = 0
    lo = quotient >> 8
    if places & 0x80:
        count = (-places) & 0xFF
        if count <= 8:
            round_up = (lo >> (count - 1)) & 1
            lo >>= count
        else:
            round_up, lo = 0, 0
    else:
        wide = (quotient << places) & 0xFFFFFF
        hi, lo = wide >> 16, (wide >> 8) & 0xFF
        round_up = (wide >> 7) & 1
    if round_up:
        lo += 1
        if lo > 0xFF:
            lo = 0
            hi = (hi + 1) & 0xFF
            if hi >= 0x40:
                return LARGEST_OFFSET
    return (hi << 8) | lo


def scale_down(uu, vv, ww, x_quotient, y_quotient):
    """Turn DivideScaled's two quotients back into screen offsets: returns
    (x_offset, y_offset), each 256 times the true quotient, rounded.

    uu is the denominator's exponent, vv and ww the numerators', so the
    quotients want shifting left by vv - uu + 1 and ww - uu + 1 places. When
    either shift is 7 or more, or either is negative, the two are first
    brought down together until neither is more than 6 -- or 7, if the
    quotient with the larger shift is below &8000 -- so that neither offset
    reaches &4000 and their ratio is kept.

    The test is the original's: it compares the shifts as unsigned bytes, so
    a right shift is taken as too large and sends it into the balancing, but
    the balancing only ever reduces a shift that is 7 or more, so that is
    harmless."""
    x = (vv - uu + 1) & 0xFF
    y = (ww - uu + 1) & 0xFF
    limit = SHIFT_LIMIT
    if x >= SHIFT_LIMIT or y >= SHIFT_LIMIT:
        # A shift of 7 is allowed if the quotient with the larger exponent
        # (both, if they are the same) is below &8000.
        difference = (vv - ww) & 0xFF
        if difference == 0:
            room = not (y_quotient & 0x8000) and not (x_quotient & 0x8000)
        elif difference < 0x80:
            room = not (x_quotient & 0x8000)
        else:
            room = not (y_quotient & 0x8000)
        if room:
            limit += 1
    # Bring both shifts down, together, until each is below the limit.
    if not y & 0x80:
        while y >= limit:
            x, y = (x - 1) & 0xFF, (y - 1) & 0xFF
    if not x & 0x80:
        while x >= limit:
            x, y = (x - 1) & 0xFF, (y - 1) & 0xFF
    return _shift_and_round(x_quotient, x), _shift_and_round(y_quotient, y)


def _magnitude(v):
    """|v| for a 16-bit two's complement v, as 16 bits (so -32768 stays
    &8000), and whether v was negative."""
    if v & 0x8000:
        return (-v) & 0xFFFF, True
    return v, False


def project_point(pid):
    """Project point pid onto the screen, replacing its x- and y-coordinates
    with the screen coordinates and setting its status bits (see the module
    docstring). Does nothing if the point has been projected already."""
    status = M[pointStatus + pid]
    if status & PROJECTED:
        return
    M[pointStatus + pid] = status | PROJECTED
    x, y, z = point(pid)
    flags = 0

    z_size, z_negative = _magnitude(z)
    if z_size == 0:
        z_size = 1
    x_size, x_negative = _magnitude(x)
    if x_negative:
        flags |= X_NEGATIVE
    y_size, y_negative = _magnitude(y)
    if y_negative:
        flags |= Y_NEGATIVE
    # Doubling |y| loses the top bit, so a y of -32768 comes out as 0.
    y_size = (y_size << 1) & 0xFFFF
    if x_size >= z_size:
        flags |= X_WIDE
    if y_size >= z_size:
        flags |= Y_WIDE

    mantissa, uu = scale_up(z_size)
    tts = reciprocal(mantissa >> 8)
    k = mantissa & 0xFF
    x_quotient, vv = divide_scaled(x_size, tts, k, uu)
    y_quotient, ww = divide_scaled(y_size, tts, k, uu)
    x_offset, y_offset = scale_down(uu, vv, ww, x_quotient, y_quotient)

    if x_negative != z_negative:
        sx = CENTRE_X - x_offset
    else:
        sx = CENTRE_X + x_offset
    if y_negative != z_negative:
        sy = CENTRE_Y - y_offset
    else:
        sy = CENTRE_Y + y_offset
    M[xPointLo + pid] = sx & 0xFF
    M[xPointHi + pid] = (sx >> 8) & 0xFF
    M[yPointLo + pid] = sy & 0xFF
    M[yPointHi + pid] = (sy >> 8) & 0xFF
    M[pointStatus + pid] |= flags
