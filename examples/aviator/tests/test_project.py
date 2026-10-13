"""Checks model/project.py against the original's projection routines, run
on the 6502.

ScaleUp is checked on every input it can be given; DivideScaled on every
table entry with each setting of the two bits of the denominator's low byte
it uses, on random inputs over the full ranges ProjectPoint gives it, and on
random reciprocals outside the table, to exercise every carry; ScaleDown on
every combination of exponents ProjectPoint can produce and on random bytes
beyond them; ProjectPoint on random points, including the edges (z = 0,
coordinates of -32768, already projected). Then all three of the routines
with recorded moments are replayed from the tour flight (tests/recorder.py),
comparing what they return as well as every byte of memory they leave.

    python tests/test_project.py
"""

import sys
import types

from harness import Check, booted, get_pair, interesting16, interesting8, rng, set_pair, zp
import recorder
import replay
from model import memory, project
from model import names as n
from model.memory import M

FLIGHT = "tour"
RANDOM_CASES = 20_000
SCALE_UP_STOP_BIT = 0x10     # ProjectPoint leaves %00010000 in R for ScaleUp's BIT R


def check_division_table():
    """The bottom three bits of divisionLo are log2 of the index, as
    scale_up takes them to be, and the reciprocals are within 4 of
    65536 / (1 + i / 256) - 256, as the module docstring says."""
    booted()
    c = Check("division table")
    for i in range(256):
        log2 = i.bit_length() - 1 if i > 1 else 0
        ideal = 65536 * 256 / (256 + i) - 256
        close = abs(project.reciprocal(i) - ideal) <= 4
        c.compare(i, (log2, True), (M[n.divisionLo + i] & 7, close))
    return c.report()


def _set_scale_up_inputs(m, v):
    m.cpu.x, m.cpu.y = v >> 8, v & 0xFF
    m.cpu.z = 1 if v >> 8 == 0 else 0           # the callers' LDX sets Z
    m.mem[zp("R")] = SCALE_UP_STOP_BIT


def check_scale_up():
    """Every non-zero 16-bit number (zero is DivideScaled's, below)."""
    m = booted()
    c = Check("ScaleUp")
    for v in range(1, 0x10000):
        _set_scale_up_inputs(m, v)
        m.call("ScaleUp")
        c.compare(hex(v), ((m.cpu.a << 8) | m.cpu.y, m.mem[zp("WW")]), project.scale_up(v))
    return c.report()


def _divide_on_6502(m, num, tts, k, uu):
    _set_scale_up_inputs(m, num)
    set_pair(m, "TT", "S", tts)
    m.mem[zp("K")] = k
    m.mem[zp("UU")] = uu
    m.call("DivideScaled")
    return get_pair(m, "Q", "P"), m.mem[zp("WW")]


def _numerator(r):
    """A numerator as ProjectPoint gives them: |x| or 2|y|, any 16-bit
    magnitude, sometimes 0."""
    if r.random() < 0.05:
        return 0
    return interesting16(r)


def check_divide_scaled_table():
    """Every reciprocal in the table, with each of the four settings of the
    bits of K that matter (the rest random), against 24 numerators each."""
    m = booted()
    r = rng()
    c = Check("DivideScaled (table)")
    for index in range(256):
        tts = project.reciprocal(index)
        for quarters in (0x00, 0x40, 0x80, 0xC0):
            for _ in range(24):
                num = _numerator(r)
                k = quarters | r.randrange(0x40)
                uu = r.randrange(16)
                c.compare((hex(num), hex(tts), hex(k), uu), _divide_on_6502(m, num, tts, k, uu),
                          project.divide_scaled(num, tts, k, uu))
    return c.report()


def check_divide_scaled_random():
    """Random inputs over the full ranges ProjectPoint produces: the
    reciprocal and K both from one random denominator."""
    m = booted()
    r = rng(1984)
    c = Check("DivideScaled (random)")
    for _ in range(RANDOM_CASES):
        num = _numerator(r)
        den = interesting16(r) or 1
        mantissa, uu = project.scale_up(den)
        tts = project.reciprocal(mantissa >> 8)
        k = mantissa & 0xFF
        c.compare((hex(num), hex(den)), _divide_on_6502(m, num, tts, k, uu),
                  project.divide_scaled(num, tts, k, uu))
    return c.report()


def check_divide_scaled_any():
    """Any 16-bit reciprocal at all, not only the table's, so that the carries
    out of the high byte are exercised from both sides."""
    m = booted()
    r = rng(1985)
    c = Check("DivideScaled (any)")
    for _ in range(RANDOM_CASES):
        num = _numerator(r)
        tts = interesting16(r)
        k = interesting8(r)
        uu = r.randrange(16)
        c.compare((hex(num), hex(tts), hex(k), uu), _divide_on_6502(m, num, tts, k, uu),
                  project.divide_scaled(num, tts, k, uu))
    return c.report()


def _scale_down_on_6502(m, uu, vv, ww, qx, qy):
    m.mem[zp("UU")], m.mem[zp("VV")], m.mem[zp("WW")] = uu, vv, ww
    set_pair(m, "QQ", "PP", qx)
    set_pair(m, "Q", "P", qy)
    m.call("ScaleDown")
    return get_pair(m, "SS", "QQ"), get_pair(m, "RR", "Q")


def _quotient(r, exponent, uu):
    """A quotient as DivideScaled returns them: 0 for a zero numerator
    (whose exponent is uu - 1), otherwise 16384 to 65535, with the edges."""
    if exponent == (uu - 1) & 0xFF and r.random() < 0.5:
        return 0
    if r.random() < 0.2:
        return r.choice([0x4000, 0x4001, 0x7FFF, 0x8000, 0x807F, 0x8080, 0xFF7F, 0xFF80, 0xFFFF])
    return r.randrange(0x4000, 0x10000)


def check_scale_down_exponents():
    """Every combination of exponents ProjectPoint can pass: the
    denominator's 0 to 15, and each numerator's 0 to 15 or, for a zero
    numerator, the denominator's less one; four pairs of quotients each."""
    m = booted()
    r = rng()
    c = Check("ScaleDown (exponents)")
    for uu in range(16):
        numerators = sorted(set(range(16)) | {(uu - 1) & 0xFF})
        for vv in numerators:
            for ww in numerators:
                for _ in range(4):
                    qx, qy = _quotient(r, vv, uu), _quotient(r, ww, uu)
                    c.compare((uu, vv, ww, hex(qx), hex(qy)), _scale_down_on_6502(m, uu, vv, ww, qx, qy),
                              project.scale_down(uu, vv, ww, qx, qy))
    return c.report()


def check_scale_down_any():
    """Any bytes and any quotients, well beyond what ProjectPoint passes,
    exercising long shifts both ways and the clamp."""
    m = booted()
    r = rng(1986)
    c = Check("ScaleDown (any)")
    for _ in range(RANDOM_CASES):
        uu = r.randrange(256)
        if r.random() < 0.7:
            # Shifts within a few places of the limits.
            vv = (uu + r.randrange(-24, 24)) & 0xFF
            ww = (uu + r.randrange(-24, 24)) & 0xFF
        else:
            vv, ww = r.randrange(256), r.randrange(256)
        qx, qy = interesting16(r), interesting16(r)
        c.compare((uu, vv, ww, hex(qx), hex(qy)), _scale_down_on_6502(m, uu, vv, ww, qx, qy),
                  project.scale_down(uu, vv, ww, qx, qy))
    return c.report()


def check_project_point_random():
    """Random points, with every byte of memory compared afterwards."""
    m = booted()
    r = rng(1987)
    c = Check("ProjectPoint (random)")
    stack = m.cpu.s
    for _ in range(RANDOM_CASES):
        pid = r.randrange(256)
        xyz = [interesting16(r) for _ in range(3)]
        if r.random() < 0.05:
            xyz[2] = 0
        if r.random() < 0.05:
            xyz[r.randrange(3)] = 0x8000
        status = r.randrange(256) & (0xFF if r.random() < 0.1 else 0xFE)
        for mem in (m.mem, M):
            for (lo, hi), v in zip(((n.xPointLo, n.xPointHi), (n.yPointLo, n.yPointHi),
                                    (n.zPointLo, n.zPointHi)), xyz):
                mem[lo + pid], mem[hi + pid] = v & 0xFF, v >> 8
            mem[n.pointStatus + pid] = status
            mem[n.GG] = pid
        m.cpu.s = stack
        m.call("ProjectPoint")
        project.project_point(pid)
        snap = types.SimpleNamespace(s=stack)
        diffs = replay.compare(snap, bytes(m.mem[:0x8000]), bytes(M[:0x8000]))
        c.compare((pid, [hex(v) for v in xyz], hex(status)), [], diffs)
        if diffs:
            # Put the port's memory back in step, so one failure is reported once.
            M[:0x8000] = m.mem[:0x8000]
    return c.report()


def check_recorded_results(name, run, results):
    """Replay the recorded moments of a routine whose results are left in
    the zero-page temporaries: compare those, from results(memory) after
    the original against what run(snap) returns, and every byte of memory
    outside the scratch as well."""
    m = booted()
    samples = recorder.recordings(FLIGHT, [name])[name]
    c = Check(f"{name} ({FLIGHT})")
    for snap in samples:
        expected = replay.replay(m, snap)
        memory.load(snap.mem)
        got = run(snap)
        diffs = replay.compare(snap, expected, bytes(M[:len(snap.mem)]))
        c.compare(f"pc &{snap.pc:04X} x={snap.x:02X} y={snap.y:02X}", (results(expected), []), (got, diffs))
    return c.report()


def _pair(mem, hi, lo):
    return (mem[zp(hi)] << 8) | mem[zp(lo)]


def _divide_recorded(s):
    mem = s.mem
    return project.divide_scaled((s.x << 8) | s.y, _pair(mem, "TT", "S"), mem[n.K], mem[n.UU])


def _scale_down_recorded(s):
    mem = s.mem
    return project.scale_down(mem[n.UU], mem[n.VV], mem[n.WW], _pair(mem, "QQ", "PP"), _pair(mem, "Q", "P"))


def main():
    print("project")
    recorder.recordings(FLIGHT, ["ProjectPoint", "DivideScaled", "ScaleDown"])
    ok = True
    for check in (check_division_table, check_scale_up, check_divide_scaled_table,
                  check_divide_scaled_random, check_divide_scaled_any, check_scale_down_exponents,
                  check_scale_down_any, check_project_point_random):
        ok = check() and ok
    ok = replay.check_recorded(FLIGHT, "ProjectPoint", lambda s: project.project_point(s.mem[n.GG])) and ok
    ok = check_recorded_results("DivideScaled", _divide_recorded,
                                lambda mem: (_pair(mem, "Q", "P"), mem[n.WW])) and ok
    ok = check_recorded_results("ScaleDown", _scale_down_recorded,
                                lambda mem: (_pair(mem, "SS", "QQ"), _pair(mem, "RR", "Q"))) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
