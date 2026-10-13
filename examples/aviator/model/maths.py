"""Aviator's arithmetic routines, in Python.

Each one gives exactly the original's result, rounding and truncation
included, since the flight model and the 3D maths are built on them and a
difference of one in a low byte grows. The original does most of its
multiplying with a 16x16 table of nibble products (timesTable) and the
nibble tables beside it; those tables are pure functions -- the product of a
byte's two nibbles, its low nibble, its high nibble, the byte shifted four
places -- so the Python works them out rather than reading them (tests/
test_maths.py checks the tables really are those functions). What cannot be
worked out, such as the sine table, is read from the original's memory.

Arguments and results that the original passes in zero-page temporaries are
plain arguments and return values here. A 16-bit pair such as (S R) is one
int, high byte first in the name: sr = S << 8 | R.

Several numbers keep their sign in bit 0 of the low byte rather than in bit 7
of the high byte (see the "multi-byte variables" deep dive): the magnitude is
the whole 16-bit value with bit 0 taken as part of it, so +5 and -5 differ
only in that bit. The routines with Bit0 in their names work on those.
"""

from .memory import M
from .names import mult1, sinLo, sinHi, xTurnHi, xTurnTop


def multiply8x8(x, y):
    """(A V) = X * Y: unsigned, exact. The original builds it from four
    nibble products, which come to the same thing."""
    return x * y


def multiply4x16(sr, v, k):
    """(G W) = V * (S R) >> 8, or >> 7 if bit 7 of K is set; V is a 4-bit
    magnitude with its sign in bit 7.

    The original multiplies the 4-bit V by each nibble of (S R) and keeps
    only the parts that land above the bottom byte, so the result is
    truncated rather than rounded, and the bits of V * R that would carry
    past the fraction are lost -- except when doubling, when the bottom byte
    is worked out after all, to carry its overflow into the result."""
    s, r = sr >> 8, sr & 0xFF
    vm = v & 0x0F
    sh, sl = s >> 4, s & 0x0F
    rh, rl = r >> 4, r & 0x0F
    t = vm * rh                                   # %vvvv * %RRRR
    y = vm * sh                                   # %vvvv * %SSSS
    w = ((t >> 4) | ((y << 4) & 0xFF)) + vm * sl
    g = (y >> 4) + (w >> 8)
    gw = ((g & 0xFF) << 8) | (w & 0xFF)
    if k & 0x80:
        low = ((t << 4) & 0xFF) + vm * rl
        if low > 0xFF:
            gw = (gw + 1) & 0xFFFF                # round up the overflow
        gw = ((gw << 1) | ((low >> 7) & 1)) & 0xFFFF
    if v & 0x80:
        gw = (-gw) & 0xFFFF
    return gw


def multiply16x16(ji, sr):
    """(H A) = (J I) * (S R) >> 16, unsigned, returned as (h, a, c).

    The I * R product is never worked out, and 128 is added below the result
    to round it -- unless ApplyAerodynamics has rewritten that 128 in the
    code, which the original does to switch rounding off and on; the
    operand is read from where the original keeps it, at mult1 + 1.

    The last carry is not added to H: the original returns it in C and
    leaves the caller to increment H, which every caller does."""
    j, i = ji >> 8, ji & 0xFF
    s, r = sr >> 8, sr & 0xFF
    rounding = M[mult1 + 1]
    gw = j * r + rounding                         # (G W), at most 16 bits
    hg = s * j + (gw >> 8)                        # (H G)
    total = s * i + ((hg & 0xFF) << 8) + (gw & 0xFF)
    a = (total >> 8) & 0xFF
    c = total >> 16
    return (hg >> 8) & 0xFF, a, c


def multiply16x16_bit0(ji, sr):
    """(H G) = (J I) * (S R) >> 16 for two numbers with their signs in bit 0,
    with the result's sign in bit 0 of G. Returns (hg, k), K being the sign."""
    k = (sr ^ ji) & 1
    h, a, c = multiply16x16(ji, sr)
    g = (a & 0xFE) | k
    if c:
        h = (h + 1) & 0xFF
    return (h << 8) | g, k


def multiply16x16_mix(ji, sr, k=0):
    """(H G) = (J I) * (S R) >> 16, where (J I) has its sign in bit 7 of J and
    (S R) in bit 0 of R; the result has its sign in bit 7 of H. Bit 7 of K
    negates the result. Returns (hg, k).

    Only the sign of (J I) is taken off before multiplying; (S R) goes in as
    it is, sign bit and all."""
    if ji & 0x8000:
        ji = (-ji) & 0xFFFF
        k ^= 0x80
    if sr & 1:
        k ^= 0x80
    h, g, c = multiply16x16(ji, sr)
    if c:
        h = (h + 1) & 0xFF
    hg = (h << 8) | g
    if k & 0x80:
        hg = (-hg) & 0xFFFF
    return hg, k


def multiply8x16(qp, r):
    """(G W V) = (Q P) * R, with (Q P) signed and R unsigned: a 24-bit two's
    complement result."""
    magnitude = qp if not qp & 0x8000 else (-qp) & 0xFFFF
    product = magnitude * r
    if qp & 0x8000:
        product = (-product) & 0xFFFFFF
    return product


def negate16(gw, c=1):
    """(G W) = -(G W), as the original's 0 - (G W) with the carry as given
    (it is always set by the callers, giving a true negation)."""
    return (0 - gw - (1 - c)) & 0xFFFF


def add16x16_bit0(hg, ji):
    """(S R) = (H G) + (J I) for two numbers with their signs in bit 0.
    Returns (sr, k), K being the result's sign.

    Adding two numbers of the same sign saturates at the largest magnitude;
    adding numbers of opposite signs subtracts the magnitudes and takes the
    sign of the larger. The sign bits take part in the low-byte arithmetic
    as ordinary bits, as they do in the original."""
    h, g = hg >> 8, hg & 0xFF
    j, i = ji >> 8, ji & 0xFF
    k = g & 1
    if not (k ^ i) & 1:
        low = g + i
        r = (low & 0xFE) | k
        high = h + j + (low >> 8)
        s = high & 0xFF
        if high > 0xFF:
            s, r = 0xFF, 0xFE | k
        return (s << 8) | r, k
    low = g - i
    borrow = 1 if low < 0 else 0
    r = low & 0xFF
    high = h - j - borrow
    s = high & 0xFF
    if high >= 0:
        r = (r & 0xFE) | k
        return (s << 8) | r, k
    # The magnitude of (J I) was the bigger: negate, and take the other sign.
    neg_low = 0 - r
    r2 = ((neg_low & 0xFE) | k) ^ 1
    s2 = (0 - s - (1 if neg_low < 0 else 0)) & 0xFF
    return (s2 << 8) | r2, k


def add_scaled(a, x, y, invert, subtract):
    """Add (A 0) >> (Y + 1) to the 16-bit variable whose low byte is at
    xTurnHi + X and high byte at xTurnTop + X; invert means A is inverted
    (the original's N flag), subtract that the amount is taken away instead
    (its C flag)."""
    if invert:
        a ^= 0xFF
    value = a << 8
    while True:
        value >>= 1
        y = (y - 1) & 0xFF
        if y & 0x80:
            break
    if subtract:
        value = negate16(value)
    lo_addr, hi_addr = xTurnHi + x, xTurnTop + x
    total = ((M[hi_addr] << 8) | M[lo_addr]) + value
    M[lo_addr] = total & 0xFF
    M[hi_addr] = (total >> 8) & 0xFF


def scale_signed(a, divide_by_16):
    """Scale an indicator value down by 4, or by 16, keeping its sign and
    rounding up, and turning 4 to 7 into 1 rather than 0 when dividing by 16
    so that small deflections still show on the dial."""
    negative = a & 0x80
    if negative:
        a = (-a) & 0xFF
    a >>= 1
    if divide_by_16:
        a >>= 1
        if a == 1:
            a = 2
        a >>= 1
    a = (a >> 1) + (a & 1)
    if negative:
        a = (-a) & 0xFF
    return a


def sine16(xw):
    """sin((X W)) as a 16-bit value, where 0 to 65535 is a quarter circle: the
    table entry for X, plus W/256 of the way to the next one. The step
    between entries is halved to fit a byte before it is scaled, so the
    interpolation loses its bottom bit."""
    x, w = xw >> 8, xw & 0xFF
    here = M[sinLo + x] | (M[sinHi + x] << 8)
    there = M[sinLo + x + 1] | (M[sinHi + x + 1] << 8)
    step = ((there - here) & 0xFFFF) >> 1 & 0xFF
    return (here + ((step * w) >> 7)) & 0xFFFF
