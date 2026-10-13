"""Points in 3D space: rotating them by the matrices, adding vectors, and the
little copies between the point tables and the variable workspace.

Aviator keeps every point it is working on in the point tables, indexed by
point ID: xPoint(Hi Lo), yPoint(Hi Lo) and zPoint(Hi Lo), 256 of each, with
IDs 252 to 255 kept for working vectors (xLinear, xGravity, xTempPoint1 and
xTempPoint2). Coordinates there are ordinary 16-bit two's complement numbers.
Matrix entries are 16-bit with their sign in bit 0 (see matrices.py).

The original passes the point to work on in GG and the matrix in
matrixNumber (0, 9, 18 or 27 for matrices 1 to 4); here they are arguments.
Both routines that rotate a point leave the rotated vector in xTemp1 (Hi Lo)
and its two neighbours as well as writing it to a point, so they write it
there too: other routines read it.

A rotation that overflows 16 bits means the point is outside the world, and
sets bit 6 of showLine (by storing %01000000 there) so the line it is on is
not drawn.
"""

from .maths import multiply16x16_mix, multiply4x16
from .memory import M
from .names import (matrix1Hi, matrix1Lo, objectAnchorPoint, showLine, xObjectHi, xObjectLo,
                    xObjectPoint, xPointHi, xPointLo, xTemp1Hi, xTemp1Lo, xTurnHi, xTurnTop,
                    yObjectHi, yObjectLo, yObjectPoint, yPointHi, yPointLo, yTemp1Hi, yTemp1Lo,
                    yTurnHi, yTurnTop, zObjectHi, zObjectLo, zObjectPoint, zPointHi, zPointLo,
                    zTemp1Hi, zTemp1Lo, zTurnHi, zTurnTop)

HIDDEN = 0x40                # bit 6 of showLine: the line is outside the world

# The point tables, as (low, high) address pairs for x, y and z.
POINT_AXES = ((xPointLo, xPointHi), (yPointLo, yPointHi), (zPointLo, zPointHi))
TEMP1_AXES = ((xTemp1Lo, xTemp1Hi), (yTemp1Lo, yTemp1Hi), (zTemp1Lo, zTemp1Hi))
OBJECT_AXES = ((xObjectLo, xObjectHi), (yObjectLo, yObjectHi), (zObjectLo, zObjectHi))


def point(pid):
    """A point's (x, y, z), each an unsigned 16-bit value."""
    return tuple(M[lo + pid] | (M[hi + pid] << 8) for lo, hi in POINT_AXES)


def set_point(pid, xyz):
    for (lo, hi), v in zip(POINT_AXES, xyz):
        M[lo + pid] = v & 0xFF
        M[hi + pid] = (v >> 8) & 0xFF


def temp1():
    return tuple(M[lo] | (M[hi] << 8) for lo, hi in TEMP1_AXES)


def set_temp1(xyz):
    for (lo, hi), v in zip(TEMP1_AXES, xyz):
        M[lo] = v & 0xFF
        M[hi] = (v >> 8) & 0xFF


def matrix_entry(i):
    return M[matrix1Lo + i] | (M[matrix1Hi + i] << 8)


def _overflows(a, b):
    """Whether adding two 16-bit two's complement numbers overflows, as the
    6502's V flag after adding the high bytes (with the low bytes' carry)."""
    total = (a & 0xFFFF) + (b & 0xFFFF)
    result = total & 0xFFFF
    return bool(~(a ^ b) & (a ^ result) & 0x8000)


def set_point_coords(pid, matrix):
    """Rotate point pid by a matrix, in place: each new coordinate is the dot
    product of a matrix row with the old (x, y, z).

    An entry whose magnitude is 4 or less -- the high byte 0 and the low byte
    below 5, which covers +0 and -0 and the two smallest values either way --
    is taken as zero and its product skipped. The sums are 16-bit, and an
    overflow in any of the nine additions hides the line."""
    coords = point(pid)
    result = [0, 0, 0]
    for row in range(3):
        # The original sums each row from the last column to the first, and
        # the order decides which addition, if any, is seen to overflow.
        for col in (2, 1, 0):
            e = matrix_entry(matrix + row * 3 + col)
            if (e >> 8) == 0 and (e & 0xFF) < 5:
                continue
            product, _ = multiply16x16_mix(coords[col], e, 0)
            if _overflows(result[row], product):
                M[showLine] = HIDDEN
            result[row] = (result[row] + product) & 0xFFFF
    set_temp1(result)
    set_point(pid, result)


def set_obj_point_coords(pid, matrix):
    """Work out where point pid of an object is: rotate its offset from the
    object's anchor (from the xObjectPoint tables) by a matrix, scale it, and
    add the anchor point (point objectAnchorPoint).

    The offsets are 4-bit and all positive (an object's anchor is its corner
    nearest the origin), and the top nibble of the z offset is a scale
    factor, a power of two from 2^0 to 2^9. Each product with a matrix entry is V * entry >> 8 -- or >> 7 when
    the scale is 9 or more -- and the sums are then shifted left by the scale
    and their bottom byte dropped."""
    px, py, pz = M[xObjectPoint + pid], M[yObjectPoint + pid], M[zObjectPoint + pid]
    scale = pz >> 4
    doubled = 0x80 if scale >= 9 else 0
    offsets = (px, py, pz)
    result = [0, 0, 0]
    for row in range(3):
        for col in range(3):
            v = offsets[col] & 0x0F
            if v == 0:
                continue
            e = matrix_entry(matrix + row * 3 + col)
            if e & 1:
                v ^= 0x80                         # the entry's sign, on V
            result[row] = (result[row] + multiply4x16(e, v, doubled)) & 0xFFFF
    for axis in range(3):
        v = result[axis]
        if scale == 0:
            # (R A) = (sign-extension, high byte): a shift right by 8.
            result[axis] = ((0xFF if v & 0x8000 else 0) << 8) | (v >> 8)
        elif scale < 8:
            # A 24-bit (R A P) from the sign-extended value, shifted left by
            # the scale, keeping the top two bytes.
            wide = v | (0xFF0000 if v & 0x8000 else 0)
            wide = (wide << scale) & 0xFFFFFF
            result[axis] = wide >> 8
        # A scale of 8 or more is already right: shifting left by 8 and
        # dropping the low byte leaves the value as it was, and the doubled
        # products have taken care of the rest.
    set_temp1(result)
    add_temp_to_point(pid, M[objectAnchorPoint])


def add_temp_to_point(dest, src):
    """Point dest = xTemp1 vector + point src, hiding the line if any axis
    overflows."""
    t = temp1()
    p = point(src)
    out = []
    for a, b in zip(t, p):
        if _overflows(a, b):
            M[showLine] = HIDDEN
        out.append((a + b) & 0xFFFF)
    set_point(dest, out)


def copy_temp_to_point(pid):
    set_point(pid, temp1())


# The variable workspace keeps its 16-bit vectors with the low bytes from
# xTurnHi + offset and the high bytes from xTurnTop + offset, x, y and z one
# after another (the original passes the offset in X).
WORK_AXES = ((xTurnHi, xTurnTop), (yTurnHi, yTurnTop), (zTurnHi, zTurnTop))


def copy_work_to_point(offset, pid):
    set_point(pid, [M[lo + offset] | (M[hi + offset] << 8) for lo, hi in WORK_AXES])


def copy_point_to_work(pid, offset):
    for (lo, hi), v in zip(WORK_AXES, point(pid)):
        M[lo + offset] = v & 0xFF
        M[hi + offset] = v >> 8


def set_point_to(pid, value):
    """Every byte of the point's coordinates set to value (SetPoint); 0 puts
    it at the origin (SetPointToOrigin)."""
    for lo, hi in POINT_AXES:
        M[lo + pid] = value
        M[hi + pid] = value


def add_point_to_object(pid, oid):
    """Move object oid by the vector in point pid."""
    for (olo, ohi), (plo, phi) in zip(OBJECT_AXES, POINT_AXES):
        total = (M[olo + oid] | (M[ohi + oid] << 8)) + (M[plo + pid] | (M[phi + pid] << 8))
        M[olo + oid] = total & 0xFF
        M[ohi + oid] = (total >> 8) & 0xFF


def set_object_to_origin(oid):
    for lo, hi in OBJECT_AXES:
        M[lo + oid] = 0
        M[hi + oid] = 0
