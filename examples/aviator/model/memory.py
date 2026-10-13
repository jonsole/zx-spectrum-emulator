"""The memory the Python port works on: the BBC Micro's, at the original
addresses.

The port keeps every persistent variable and table where the original keeps
it, so its state can be compared byte for byte with the original's at any
moment, and a snapshot of the original can be dropped straight in. What
changes is how the routines are written: arguments and results that the
original passes through registers and zero-page temporaries (P, Q, R ... HH)
are plain Python arguments and return values here, and nothing is kept in
those temporaries between routines.

Every label in the original is available as an address constant:

    from model.memory import M
    from model.names import xObjectHi, nextAxis
    M[xObjectHi + i]

The tables the game reads (object points, lines, sines...) are Acornsoft's
and come from the original binary, which acornsoft.py fetches; nothing of
them is written into this code.
"""

M = bytearray(65536)


def load(image, base=0):
    """Copy an image of the original's memory (a snapshot, or its first part)
    into M."""
    M[base:base + len(image)] = image


def word(lo_addr, hi_addr, i=0):
    """An unsigned 16-bit value kept as separate low and high bytes."""
    return M[lo_addr + i] | (M[hi_addr + i] << 8)


def set_word(lo_addr, hi_addr, value, i=0):
    M[lo_addr + i] = value & 0xFF
    M[hi_addr + i] = (value >> 8) & 0xFF


def signed8(v):
    v &= 0xFF
    return v - 0x100 if v & 0x80 else v


def signed16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v
