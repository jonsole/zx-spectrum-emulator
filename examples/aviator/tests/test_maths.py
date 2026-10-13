"""Checks model/maths.py against the original's maths routines, run on the 6502.

Each routine is called on the 6502 with its inputs in the registers and zero
page where the original expects them, and the Python version with the same
inputs; their results must be identical. The two exhaustive cases cover all
65,536 inputs; the rest take 20,000 random ones each, weighted towards the
edges (0, &7F/&80, &FF, small and nearly-wrapping values).

    python tests/test_maths.py
"""

import sys

from harness import Check, booted, get_pair, interesting16, interesting8, rng, set_pair, zp
from model import maths
from model import names as n
from model.memory import M

RANDOM_CASES = 20_000


def check_tables():
    """The nibble tables are the functions maths.py takes them to be."""
    booted()
    c = Check("nibble tables")
    for i in range(256):
        c.compare(i, (i >> 4, (i << 4) & 0xFF, i & 0x0F, i & 0xF0, (i >> 4) * (i & 0x0F)),
                  (M[n.shift4Right + i], M[n.shift4Left + i], M[n.lowNibble + i], M[n.highNibble + i],
                   M[n.timesTable + i]))
    return c.report()


def check_multiply8x8():
    m = booted()
    c = Check("Multiply8x8")
    for x in range(256):
        for y in range(256):
            m.cpu.x, m.cpu.y = x, y
            m.call("Multiply8x8")
            c.compare((x, y), (m.cpu.a << 8) | m.mem[zp("V")], maths.multiply8x8(x, y))
    return c.report()


def check_multiply4x16():
    m = booted()
    r = rng()
    c = Check("Multiply4x16")
    for _ in range(RANDOM_CASES):
        sr = interesting16(r)
        v = r.randrange(16) | (0x80 if r.random() < 0.5 else 0)
        k = r.choice([0, 0x80, r.randrange(256)])
        set_pair(m, "S", "R", sr)
        m.mem[zp("V")] = v
        m.mem[zp("K")] = k
        m.call("Multiply4x16")
        c.compare((hex(sr), hex(v), hex(k)), get_pair(m, "G", "W"), maths.multiply4x16(sr, v, k))
    return c.report()


def _set_rounding(m, r):
    rounding = r.choice([0, 128])
    m.mem[n.mult1 + 1] = rounding
    M[n.mult1 + 1] = rounding
    return rounding


def check_multiply16x16():
    m = booted()
    r = rng()
    c = Check("Multiply16x16")
    for _ in range(RANDOM_CASES):
        ji, sr = interesting16(r), interesting16(r)
        rounding = _set_rounding(m, r)
        set_pair(m, "J", "I", ji)
        set_pair(m, "S", "R", sr)
        m.call("Multiply16x16")
        c.compare((hex(ji), hex(sr), rounding), (m.mem[zp("H")], m.cpu.a, m.cpu.c),
                  maths.multiply16x16(ji, sr))
    return c.report()


def check_multiply16x16_bit0():
    m = booted()
    r = rng()
    c = Check("Multiply16x16Bit0")
    for _ in range(RANDOM_CASES):
        ji, sr = interesting16(r), interesting16(r)
        rounding = _set_rounding(m, r)
        set_pair(m, "J", "I", ji)
        set_pair(m, "S", "R", sr)
        m.call("Multiply16x16Bit0")
        c.compare((hex(ji), hex(sr), rounding), (get_pair(m, "H", "G"), m.mem[zp("K")]),
                  maths.multiply16x16_bit0(ji, sr))
    return c.report()


def check_multiply16x16_mix():
    m = booted()
    r = rng()
    c = Check("Multiply16x16Mix")
    for _ in range(RANDOM_CASES):
        ji, sr = interesting16(r), interesting16(r)
        k = r.choice([0, 0x80])
        rounding = _set_rounding(m, r)
        set_pair(m, "J", "I", ji)
        set_pair(m, "S", "R", sr)
        m.mem[zp("K")] = k
        m.call("Multiply16x16Mix")
        c.compare((hex(ji), hex(sr), k, rounding), (get_pair(m, "H", "G"), m.mem[zp("K")]),
                  maths.multiply16x16_mix(ji, sr, k))
    return c.report()


def check_multiply8x16():
    m = booted()
    r = rng()
    c = Check("Multiply8x16")
    for _ in range(RANDOM_CASES):
        qp, rr = interesting16(r), interesting8(r)
        set_pair(m, "Q", "P", qp)
        m.mem[zp("R")] = rr
        m.call("Multiply8x16")
        gwv = (m.mem[zp("G")] << 16) | (m.mem[zp("W")] << 8) | m.mem[zp("V")]
        port = maths.multiply8x16(qp, rr)
        c.compare((hex(qp), rr), (gwv, m.cpu.a), (port, port >> 16))
    return c.report()


def check_negate16():
    m = booted()
    r = rng()
    c = Check("Negate16Bit")
    for _ in range(RANDOM_CASES):
        gw = interesting16(r)
        carry = r.randrange(2)
        set_pair(m, "G", "W", gw)
        m.cpu.c = carry
        m.call("Negate16Bit")
        port = maths.negate16(gw, carry)
        c.compare((hex(gw), carry), (get_pair(m, "G", "W"), m.cpu.a), (port, port >> 8))
    return c.report()


def check_add16x16_bit0():
    m = booted()
    r = rng()
    c = Check("Add16x16Bit0")
    for _ in range(RANDOM_CASES):
        hg, ji = interesting16(r), interesting16(r)
        set_pair(m, "H", "G", hg)
        set_pair(m, "J", "I", ji)
        m.call("Add16x16Bit0")
        c.compare((hex(hg), hex(ji)), (get_pair(m, "S", "R"), m.mem[zp("K")]), maths.add16x16_bit0(hg, ji))
    return c.report()


def check_add_scaled():
    m = booted()
    r = rng()
    c = Check("AddScaled")
    for _ in range(RANDOM_CASES):
        a = interesting8(r)
        x = r.choice([0x02, 0x6A, 0x6B, 0x6C, 0xEC, 0xEE])
        y = r.randrange(8)
        invert, subtract = r.randrange(2), r.randrange(2)
        lo, hi = n.xTurnHi + x, n.xTurnTop + x
        start = interesting16(r)
        m.mem[lo], m.mem[hi] = start & 0xFF, start >> 8
        M[lo], M[hi] = start & 0xFF, start >> 8
        m.cpu.a, m.cpu.x, m.cpu.y = a, x, y
        m.cpu.n, m.cpu.c = invert, subtract
        m.call("AddScaled")
        maths.add_scaled(a, x, y, invert, subtract)
        c.compare((a, hex(x), y, invert, subtract, hex(start)), (m.mem[lo], m.mem[hi]), (M[lo], M[hi]))
    return c.report()


def check_scale_signed():
    m = booted()
    c = Check("ScaleSigned")
    for a in range(256):
        for carry in (0, 1):
            m.cpu.a = a
            m.cpu.n = 1 if a & 0x80 else 0
            m.cpu.z = 1 if a == 0 else 0
            m.cpu.c = carry
            m.call("ScaleSigned")
            c.compare((a, carry), m.cpu.a, maths.scale_signed(a, carry))
    return c.report()


def check_sine16():
    m = booted()
    c = Check("Sine16Bit")
    for x in range(256):
        for w in range(256):
            m.cpu.x = x
            m.mem[zp("W")] = w
            m.call("Sine16Bit")
            c.compare((x, w), (m.cpu.a << 8) | m.cpu.y, maths.sine16((x << 8) | w))
    return c.report()


CHECKS = [check_tables, check_multiply8x8, check_multiply4x16, check_multiply16x16,
          check_multiply16x16_bit0, check_multiply16x16_mix, check_multiply8x16, check_negate16,
          check_add16x16_bit0, check_add_scaled, check_scale_signed, check_sine16]


def main():
    print("maths")
    ok = True
    for check in CHECKS:
        ok = check() and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
