"""The rotation matrices, from the plane's three rotation angles.

ProjectAxisAngle turns each angle into a sine and a cosine (mx1, mx2 for the
x-axis, and likewise y and z), and SetMatrices builds four 3x3 matrices from
them (see the "rotation matrices" deep dive):

- matrix 1 rotates by roll, then pitch, then yaw: the world as the plane
  sees it;
- matrix 2 is its transpose, the inverse: from the plane's frame of
  reference to the world's;
- matrix 3 rotates by the roll angle alone;
- matrix 4 is the roll-and-pitch rotation, without the yaw.

Every value is a 16-bit number with its sign in bit 0 of the low byte.
matrix1 to matrix4 are kept where the original keeps them, nine entries a
matrix, low and high bytes in separate tables.
"""

from .maths import add16x16_bit0, multiply16x16_bit0, sine16
from .memory import M
from .names import (matrix1Hi, matrix1Lo, matrix2Hi, matrix2Lo, matrix3Hi, matrix3Lo, matrix4Hi,
                    matrix4Lo, mx1Hi, mx1Lo, xRotationHi, xRotationLo, xTemp1Hi, xTemp1Lo)

# The six values ProjectAxisAngle works out, as offsets from mx1: mx1, my1
# and mz1 are the cosines (with the sign the matrices want), mx2, my2 and mz2
# the sines.
MX1, MY1, MZ1, MX2, MY2, MZ2 = range(6)


def axis_value(i):
    return M[mx1Lo + i] | (M[mx1Hi + i] << 8)


def entry(lo, hi, i):
    return M[lo + i] | (M[hi + i] << 8)


def set_entry(lo, hi, i, value):
    M[lo + i] = value & 0xFF
    M[hi + i] = (value >> 8) & 0xFF


def project_axis_angle(axis):
    """Set the sine and cosine for one axis (0 = x, 1 = y, 2 = z) from its
    rotation angle, xRotation(Hi Lo) + axis.

    A full circle is 0 to 65535. The top two bits pick the quadrant, and the
    rest, shifted up to fill 16 bits, is the angle within it, whose sine and
    -- by inverting it -- cosine come from Sine16Bit. The quadrant then
    decides which of the two goes where and with what signs."""
    hi, lo = M[xRotationHi + axis], M[xRotationLo + axis]
    angle = (((hi << 8) | lo) << 2) & 0xFFFF
    sine = sine16(angle)
    cosine = sine16(angle ^ 0xFFFF)
    quadrant = hi & 0xC0
    if quadrant == 0x00:
        v2, v1 = sine & 0xFFFE, cosine & 0xFFFE
    elif quadrant == 0x80:
        v2, v1 = sine | 1, cosine | 1
    elif quadrant == 0x40:
        v2, v1 = cosine & 0xFFFE, sine | 1
    else:
        v2, v1 = cosine | 1, sine & 0xFFFE
    set_entry(mx1Lo, mx1Hi, MX2 + axis, v2)
    set_entry(mx1Lo, mx1Hi, MX1 + axis, v1)


def set_matrices():
    """Build matrices 1 to 4 from mx1 ... mz2.

    The order of the multiplications, and which results are reused for the
    next, are the original's: each product is rounded, so working the same
    matrix out another way would give slightly different numbers."""
    mx1, my1, mz1 = axis_value(MX1), axis_value(MY1), axis_value(MZ1)
    mx2, my2, mz2 = axis_value(MX2), axis_value(MY2), axis_value(MZ2)

    def m1(i):
        return entry(matrix1Lo, matrix1Hi, i)

    def set_m1(i, value):
        set_entry(matrix1Lo, matrix1Hi, i, value)

    def mul(a, b):
        return multiply16x16_bit0(a, b)[0]

    def add(a, b):
        return add16x16_bit0(a, b)[0]

    neg = 1                                       # flipping bit 0 negates

    set_m1(1, mul(mx1 ^ neg, mz2))                # -mx1 * mz2
    set_m1(3, mul(my1, mz2))                      # my1 * mz2, finished below
    set_m1(2, mul(mx2, mz2))                      # mx2 * mz2, used below
    set_m1(0, mul(my2, mz2))                      # my2 * mz2, used below
    set_m1(6, mul(my2, mx1))                      # mx1 * my2
    set_m1(8, mul(my1, mx1))                      # mx1 * my1
    set_m1(4, mul(mz1, mx1))                      # mx1 * mz1
    m5 = mul(mz1, mx2 ^ neg)                      # -mx2 * mz1
    set_m1(5, m5)

    # Matrices 3 and 4 take their simple entries straight from the values.
    for i in (0, 4):
        set_entry(matrix3Lo, matrix3Hi, i, mz1)
    set_entry(matrix4Lo, matrix4Hi, 0, mz1)
    set_entry(matrix3Lo, matrix3Hi, 3, mz2)
    set_entry(matrix4Lo, matrix4Hi, 3, mz2)
    set_entry(matrix3Lo, matrix3Hi, 1, mz2 ^ neg)
    set_entry(matrix4Lo, matrix4Hi, 8, mx1)
    set_entry(matrix4Lo, matrix4Hi, 7, mx2)
    # Matrix 4's m1, m2, m4 and m5 are matrix 1's as they stand now, before
    # the yaw is folded into them.
    for i in (5, 4, 2, 1):
        set_entry(matrix4Lo, matrix4Hi, i, m1(i))

    set_m1(3, add(mul(m5, my2), m1(3)))           # -(mx2 * my2 * mz1) + (my1 * mz2)
    set_m1(5, add(mul(m1(5), my1), m1(0) ^ neg))  # -(mx2 * my1 * mz1) - (my2 * mz2)
    set_m1(0, mul(mz1, my1))                      # my1 * mz1
    m2_before = m1(2)                             # mx2 * mz2
    M[xTemp1Lo] = m2_before & 0xFF
    M[xTemp1Hi] = m2_before >> 8
    set_m1(2, mul(mz1, my2 ^ neg))                # -my2 * mz1
    set_m1(0, add(mul(m2_before, my2), m1(0)))    # (mx2 * my2 * mz2) + (my1 * mz1)
    set_m1(2, add(mul(my1, m2_before), m1(2)))    # (mx2 * my1 * mz2) - (my2 * mz1)
    set_m1(7, mx2)

    # Matrix 2 is matrix 1 transposed.
    for row in range(3):
        for col in range(3):
            set_entry(matrix2Lo, matrix2Hi, col * 3 + row, m1(row * 3 + col))
