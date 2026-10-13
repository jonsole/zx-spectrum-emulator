"""Checks spectrum/maths.s against model/maths.py, which matches the
original: the same inputs, on random values weighted towards the edges,
must give the same results. Reports each routine's T-states.

    python tests/test_zx_maths.py
"""

import statistics
import sys

from harness import Check, booted, interesting16, interesting8, rng
from model import maths, memory
from model import names as n
import zx

CASES = 3000


def run(z, name, cases, setup, z80, python):
    """setup(r) -> inputs; z80(z, inputs) -> (result, t); python(inputs) -> result."""
    r = rng()
    c = Check(name)
    times = []
    for _ in range(cases):
        inputs = setup(r)
        got, t = z80(z, inputs)
        times.append(t)
        c.compare(inputs, python(inputs), got)
    ok = c.report()
    print(f"      {statistics.mean(times):.0f} T-states on average, {max(times)} at most")
    return ok


def main():
    booted()                                    # the port's memory: the sine table
    ok = True
    with zx.Spectrum() as z:
        z.put_state(memory.M)

        def mul8(z, i):
            out = z.call("mul8", af=i[0] << 8, de=i[1])
            return out["hl"], out["t"]
        ok = run(z, "mul8", CASES, lambda r: (interesting8(r), interesting8(r)), mul8,
                 lambda i: maths.multiply8x8(*i)) and ok

        def rounding(r):
            v = r.choice([0, 128])
            memory.M[n.mult1 + 1] = v
            return v

        def mul16(z, i):
            ji, sr, rnd = i
            z.poke("mult1_round", [rnd])
            out = z.call("mul16", de=ji, bc=sr)
            return out["hl"], out["t"]

        def py_mul16(i):
            ji, sr, rnd = i
            memory.M[n.mult1 + 1] = rnd
            h, a, c = maths.multiply16x16(ji, sr)
            return (((h + c) & 0xFF) << 8) | a
        ok = run(z, "mul16", CASES, lambda r: (interesting16(r), interesting16(r), rounding(r)), mul16,
                 py_mul16) and ok

        def mul16_bit0(z, i):
            ji, sr, rnd = i
            z.poke("mult1_round", [rnd])
            out = z.call("mul16_bit0", de=ji, bc=sr)
            return (out["hl"], out["a"]), out["t"]

        def py_bit0(i):
            ji, sr, rnd = i
            memory.M[n.mult1 + 1] = rnd
            return maths.multiply16x16_bit0(ji, sr)
        ok = run(z, "mul16_bit0", CASES, lambda r: (interesting16(r), interesting16(r), rounding(r)),
                 mul16_bit0, py_bit0) and ok

        def mul16_mix(z, i):
            ji, sr, rnd = i
            z.poke("mult1_round", [rnd])
            out = z.call("mul16_mix", de=ji, bc=sr)
            return out["hl"], out["t"]

        def py_mix(i):
            ji, sr, rnd = i
            memory.M[n.mult1 + 1] = rnd
            return maths.multiply16x16_mix(ji, sr, 0)[0]
        ok = run(z, "mul16_mix", CASES, lambda r: (interesting16(r), interesting16(r), rounding(r)),
                 mul16_mix, py_mix) and ok

        def add(z, i):
            out = z.call("add16_bit0", hl=i[0], de=i[1])
            return out["hl"], out["t"]
        ok = run(z, "add16_bit0", CASES, lambda r: (interesting16(r), interesting16(r)), add,
                 lambda i: maths.add16x16_bit0(*i)[0]) and ok

        def sine(z, i):
            out = z.call("sine16", hl=i)
            return out["hl"], out["t"]
        ok = run(z, "sine16", CASES, lambda r: r.randrange(0x10000), sine, maths.sine16) and ok

        # Multiply4x16's two halves, without the sign (set_obj_point_coords
        # sees to that): V positive, and k picking the half.
        for name, k in (("product_plain", 0), ("product_doubled", 0x80)):
            def product(z, i):
                sr, v = i
                out = z.call(name, bc=sr, de=(v << 8) | (v << 4))
                return out["hl"], out["t"]
            ok = run(z, name, CASES, lambda r: (interesting16(r), r.randrange(16)),
                     product, lambda i, k=k: maths.multiply4x16(i[0], i[1], k)) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
